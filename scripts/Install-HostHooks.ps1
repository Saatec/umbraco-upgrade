<#
.SYNOPSIS
  Installs the umbraco-upgrade safety hooks into a project for GitHub Copilot or OpenAI Codex.

.DESCRIPTION
  Claude Code and Cursor load the plugin's hooks from the plugin itself. GitHub Copilot and OpenAI
  Codex do not give plugin hooks a reliable path to the plugin folder, so this script writes a
  project hook file that calls the hook scripts by their absolute path:
    copilot  .github/hooks/umbraco-upgrade.json (a file of its own)
    codex    .codex/hooks.json (merged: other hooks in the file are kept, earlier umbraco-upgrade
             entries are replaced)
  The file is added to .git/info/exclude, so it is never committed. A tracked hook file is not
  changed: the script stops and says so. Run it again after updating the plugin, because the
  plugin folder can change. The gate 3 guard self-test proves the hooks are active.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidateSet('copilot', 'codex')][string]$Tool, [string]$ProjectRoot = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Git.psm1') -DisableNameChecking

function Get-HookCommand {
    # A command line that works in cmd.exe and in PowerShell: an absolute, double-quoted script path.
    param([string]$Script, [string]$Shell)
    $path = Join-Path (Join-Path $PSScriptRoot 'hooks') $Script
    if ($Shell -eq 'windows') { return "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$path`" -HostTool $Tool" }
    return "pwsh -NoProfile -NonInteractive -File '$($path -replace '\\', '/')' -HostTool $Tool"
}

function New-CodexGroup {
    param([string]$Script, [string]$Matcher, [string]$Label)
    $hook = [ordered]@{ type = 'command'; command = (Get-HookCommand $Script 'posix'); command_windows = (Get-HookCommand $Script 'windows'); timeout = 30; statusMessage = $Label }
    $group = [ordered]@{}
    if ($Matcher) { $group['matcher'] = $Matcher }
    $group['hooks'] = @($hook)
    return $group
}

function Test-OurGroup {
    # A Codex matcher group this script wrote: every handler's statusMessage starts with "umbraco-upgrade".
    param($Group)
    $hooks = @($Group['hooks'])
    if ($hooks.Count -eq 0) { return $false }
    foreach ($h in $hooks) { if (-not ($h -is [System.Collections.IDictionary]) -or -not ([string]$h['statusMessage']).StartsWith('umbraco-upgrade')) { return $false } }
    return $true
}

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not [System.IO.Directory]::Exists($root)) { throw "Project folder not found: $root" }
    $rel = $(if ($Tool -eq 'copilot') { '.github/hooks/umbraco-upgrade.json' } else { '.codex/hooks.json' })
    $file = Join-Path $root $rel
    $repo = Get-GitRepoInfo -Root $root
    if ($repo.isRepo) {
        $tracked = Invoke-GitCommand -Root $root -Arguments @('ls-files', '--', $rel)
        if (@($tracked.stdout | Where-Object { $_ }).Count -gt 0) {
            throw "$rel is tracked in git, so the plugin does not change it. Add the umbraco-upgrade hooks to it yourself (see the plugin README), or remove it from the repository first."
        }
    }

    if ($Tool -eq 'copilot') {
        $entry = { param($s) [ordered]@{ type = 'command'; powershell = (Get-HookCommand $s 'windows'); bash = (Get-HookCommand $s 'posix'); timeoutSec = 30 } }
        $post = & $entry 'redact-output.ps1'
        $post['matcher'] = 'view|bash|powershell|grep'
        $config = [ordered]@{
            version = 1
            hooks = [ordered]@{
                sessionStart = @((& $entry 'session-context.ps1'))
                preToolUse = @((& $entry 'guard.ps1'))
                postToolUse = @($post)
            }
        }
        $nextSteps = @('Start a new Copilot session in the project if this one does not pick up the hooks.')
    } else {
        $config = [ordered]@{ hooks = [ordered]@{} }
        if ([System.IO.File]::Exists($file)) {
            $existing = ConvertTo-PlainObject (Read-JsonFile $file)
            if (-not ($existing -is [System.Collections.IDictionary])) { throw "$rel is not a JSON object." }
            $config = $existing
            if (-not $config.Contains('hooks') -or -not ($config['hooks'] -is [System.Collections.IDictionary])) { $config['hooks'] = [ordered]@{} }
        }
        $ours = [ordered]@{
            SessionStart = (New-CodexGroup 'session-context.ps1' '' 'umbraco-upgrade session context')
            PreToolUse = (New-CodexGroup 'guard.ps1' '*' 'umbraco-upgrade guard')
            PostToolUse = (New-CodexGroup 'redact-output.ps1' 'Bash' 'umbraco-upgrade redaction')
        }
        foreach ($ev in $ours.Keys) {
            $kept = @()
            if ($config['hooks'].Contains($ev)) { $kept = @(@($config['hooks'][$ev]) | Where-Object { $_ -and -not (Test-OurGroup $_) }) }
            $config['hooks'][$ev] = @($kept) + @($ours[$ev])
        }
        $nextSteps = @('In Codex, open /hooks and trust the three umbraco-upgrade hooks. Codex runs project hooks only in trusted projects, and skips changed hooks until they are trusted again.')
    }

    Write-TextFile -Path $file -Content (ConvertTo-JsonText -InputObject $config)

    $excluded = $false
    if ($repo.isRepo) {
        $gd = Invoke-GitCommand -Root $root -Arguments @('rev-parse', '--git-common-dir')
        $gitDir = $gd.stdout[0]; if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $root $gitDir }
        $exclude = Join-Path $gitDir 'info/exclude'
        $line = '/' + $repo.prefix + $rel
        $text = ''; if ([System.IO.File]::Exists($exclude)) { $text = Read-TextFile $exclude }
        if (($text -split "`r?`n") -notcontains $line) {
            if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
            Write-TextFile -Path $exclude -Content ($text + $line + "`n")
        }
        $excluded = $true
    }
    Write-JsonOutput ([ordered]@{ ok = $true; tool = $Tool; file = $rel; excludedFromGit = $excluded; nextSteps = $nextSteps })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
