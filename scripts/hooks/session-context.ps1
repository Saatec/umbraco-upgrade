# session-context.ps1 - SessionStart hook.
#
# Outside upgrade projects it exits 0 with no output. In an upgrade project it prints a short
# factual note that Claude Code adds to the session context: the upgrade's mode, target, gate
# status, and that the safety hooks are active. In upgrade mode it restates the no-removal rule and,
# after plan approval, the phase in progress. It also warns when Claude Code is older than the
# minimum version this plugin needs (2.1.295, for hook onFailure).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$minimum = [version]'2.1.295'

function Read-HookInput {
    # Reads stdin as UTF-8 bytes. Windows PowerShell would otherwise decode it with the console code page.
    $stream = [Console]::OpenStandardInput()
    $ms = New-Object System.IO.MemoryStream
    $stream.CopyTo($ms)
    return (New-Object System.Text.UTF8Encoding($false)).GetString($ms.ToArray()).TrimStart([char]0xFEFF)
}

function Write-HookText {
    param([ValidateSet('out', 'err')][string]$To, [string]$Text)
    $stream = $(if ($To -eq 'out') { [Console]::OpenStandardOutput() } else { [Console]::OpenStandardError() })
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Find-UpgradeRoot {
    param([string]$Start)
    if ([string]::IsNullOrWhiteSpace($Start)) { return $null }
    try { $dir = [System.IO.Path]::GetFullPath($Start) } catch { return $null }
    while ($dir) {
        if ([System.IO.File]::Exists([System.IO.Path]::Combine($dir, '.umbraco-upgrade', 'state.json'))) { return $dir }
        $parent = [System.IO.Path]::GetDirectoryName($dir)
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

try {
    $hookInput = $null
    try { $hookInput = Read-HookInput | ConvertFrom-Json } catch { }
    $cwd = $null; if ($hookInput -and $hookInput.PSObject.Properties['cwd']) { $cwd = [string]$hookInput.cwd }
    $root = $null
    foreach ($c in @($cwd, $env:CLAUDE_PROJECT_DIR)) { $root = Find-UpgradeRoot $c; if ($root) { break } }
    if (-not $root) { exit 0 }
    $s = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($root, '.umbraco-upgrade', 'state.json')) | ConvertFrom-Json
    $gates = foreach ($g in @('discovery', 'versionPath', 'safety', 'planApproval', 'final')) { "$g=$($s.gates.$g.status)" }
    $lines = @(
        "An Umbraco upgrade managed by the umbraco-upgrade plugin is in progress in $root.",
        "Mode: $($s.mode). Source: $($s.source.umbraco). Target requested: $($s.target.requested). Gates: $($gates -join ', ').",
        'The umbraco-upgrade safety hooks are active in this project: prohibited operations (force push, history rewrites, branch deletion, discarding changes, non-local databases, deployments, printing secrets) are blocked.',
        'State in .umbraco-upgrade/state.json changes only through the plugin state script. To continue an interrupted upgrade, run /umbraco-upgrade:resume: it compares the state with the repository and asks before anything continues.'
    )
    if ($s.mode -eq 'upgrade') {
        $stateScript = [System.IO.Path]::Combine((Split-Path (Split-Path $PSScriptRoot -Parent) -Parent), 'scripts', 'state.ps1')
        $lines += 'Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.'
        $lines += 'This holds when the user asks for a shortcut ("just make it build", "delete or stub it for now"): that is not a decision to retire the feature. Keep the code, record the item, say what the shortcut would lose, and ask.'
        $lines += "Record an unresolved item with: powershell -NoProfile -ExecutionPolicy Bypass -File `"$stateScript`" unresolved -ProjectRoot `"$root`" -Item `"<what and why>`" -Pattern <pattern id> -Proposal port|replace|redesign"
        if ($s.gates.planApproval.status -eq 'approved') {
            $current = @(@($s.phases) | Where-Object { $_ -and $_.status -eq 'in-progress' } | ForEach-Object { $_.id })
            $note = 'The plan is approved; it runs phase by phase through the umbraco-upgrade:upgrade-workflow skill (references/phase-execution.md).'
            if ($current.Count -gt 0) { $note += " Phase in progress: $($current -join ', ')." }
            $lines += $note
        }
    }
    try {
        $v = (& claude --version 2>$null | Select-Object -First 1)
        if ($v -match '(\d+\.\d+\.\d+)') {
            if ([version]$Matches[1] -lt $minimum) { $lines += "Claude Code $($Matches[1]) is older than $minimum, the minimum for this plugin. Hook failure blocking (onFailure) is not available; update Claude Code." }
        }
    } catch { }
    Write-HookText -To out -Text ($lines -join "`n")
    exit 0
} catch {
    exit 0
}
