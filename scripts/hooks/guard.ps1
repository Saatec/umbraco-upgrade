# guard.ps1 - PreToolUse safety hook for the umbraco-upgrade plugin.
#
# Outside upgrade projects it exits 0 with no output and changes nothing.
# In an upgrade project (a folder with .umbraco-upgrade/state.json, found from the hook cwd, the
# session's project directory, an active-session marker, or a directory the command names) it:
#   - blocks prohibited operations with exit code 2 and the reason on stderr
#   - returns permissionDecision "ask" for approval-tier operations
#   - blocks with "guard error" if anything inside the guard fails (fail-closed)
# Rules: scripts/hooks/rules.json. Logic: scripts/hooks/GuardCore.psm1.
#
# -HostTool copilot|codex|cursor runs the same rules for GitHub Copilot, OpenAI Codex, or Cursor:
# their input is converted to the Claude Code shape (HostAdapter.psm1), and decisions are written as
# that tool's JSON output with exit code 0. Without -HostTool the behavior is Claude Code's, unchanged.

param([ValidateSet('claude', 'copilot', 'codex', 'cursor')][string]$HostTool = 'claude')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

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

$hookInput = $null
try {
    $raw = Read-HookInput
    $hookInput = $raw | ConvertFrom-Json
} catch { $hookInput = $null }

# Other AI tools: convert their input to the Claude Code shape, and use the per-user data directory.
$hostKind = 'shell'
$hostPatchFiles = @()
if ($HostTool -ne 'claude') {
    Import-Module (Join-Path $PSScriptRoot 'HostAdapter.psm1') -DisableNameChecking
    $env:CLAUDE_PLUGIN_DATA = Get-HostDataDir -HostTool $HostTool
    $converted = $null
    try { $converted = ConvertFrom-HostHookInput -HostTool $HostTool -InputObject $hookInput } catch { $converted = $null }
    if ($null -ne $converted) { $hostKind = [string]$converted.host_kind; $hostPatchFiles = @($converted.host_patch_files) }
    $hookInput = $converted
}

function Get-InputValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
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

function Exit-Blocked {
    param([string]$Message)
    if ($HostTool -ne 'claude') {
        Write-HookText -To out -Text (Get-HostDecisionJson -HostTool $HostTool -Kind $hostKind -Decision deny -Message $Message)
        exit 0
    }
    Write-HookText -To err -Text $Message
    exit 2
}

function Exit-Allowed {
    if ($HostTool -ne 'claude') {
        $json = Get-HostDecisionJson -HostTool $HostTool -Kind $hostKind -Decision allow
        if ($json) { Write-HookText -To out -Text $json }
    }
    exit 0
}

$toolName = [string](Get-InputValue $hookInput 'tool_name')
$toolInput = Get-InputValue $hookInput 'tool_input'
$cwd = [string](Get-InputValue $hookInput 'cwd')
$sessionId = [string](Get-InputValue $hookInput 'session_id')

# ---- 1. Cheap scope check.
$root = $null
$candidates = @($cwd, $env:CLAUDE_PROJECT_DIR)
if ($HostTool -ne 'claude') { $candidates += (Get-Location).ProviderPath }
foreach ($candidate in $candidates) {
    $root = Find-UpgradeRoot $candidate
    if ($root) { break }
}
if (-not $root -and $sessionId -and $env:CLAUDE_PLUGIN_DATA -and $sessionId -match '^[A-Za-z0-9\-_]+$') {
    $marker = [System.IO.Path]::Combine($env:CLAUDE_PLUGIN_DATA, 'active-sessions', $sessionId + '.json')
    if ([System.IO.File]::Exists($marker)) {
        try {
            $m = [System.IO.File]::ReadAllText($marker) | ConvertFrom-Json
            $root = Find-UpgradeRoot ([string]$m.projectRoot)
        } catch { $root = $null }
    }
}
if (-not $root -and $null -ne $toolInput) {
    if ($toolName -in @('Write', 'Edit', 'NotebookEdit')) {
        foreach ($nm in @('file_path', 'notebook_path')) {
            $pv = [string](Get-InputValue $toolInput $nm)
            if ($pv) { $root = Find-UpgradeRoot $pv; if ($root) { break } }
        }
    } elseif ($toolName -eq 'Patch') {
        foreach ($pf in $hostPatchFiles) {
            $pv = [string]$pf.file_path
            if ($pv -and $cwd -and -not [System.IO.Path]::IsPathRooted($pv)) { $pv = [System.IO.Path]::Combine($cwd, $pv) }
            if ($pv) { $root = Find-UpgradeRoot $pv; if ($root) { break } }
        }
    } elseif ($toolName -in @('Bash', 'PowerShell', 'Shell')) {
        $cmd = [string](Get-InputValue $toolInput 'command')
        if ($cmd -match '(?i)(\bcd\b|\bchdir\b|\bpushd\b|set-location|push-location|\bsl\b|\s-C\s|--project|--startup-project|\s-p\s|\s-s\s)') {
            try {
                Import-Module (Join-Path $PSScriptRoot 'GuardCore.psm1') -DisableNameChecking
                # Shell (other AI tools) does not say which shell runs the command, so both dialects are read.
                $dialects = $(if ($toolName -eq 'PowerShell') { @('powershell') } elseif ($toolName -eq 'Shell') { @('bash', 'powershell') } else { @('bash') })
                foreach ($dialect in $dialects) {
                    $records = Get-AnalyzedCommands -Text $cmd -Dialect $dialect
                    foreach ($d in (Get-CommandDirectories -Records $records -Cwd $cwd)) {
                        $root = Find-UpgradeRoot $d
                        if ($root) { break }
                    }
                    if ($root) { break }
                }
            } catch {
                # Could not analyze the command. Outside known scope this stays non-blocking.
                $root = $null
            }
        }
    }
}

if (-not $root) {
    if ($null -eq $hookInput -and (Find-UpgradeRoot $env:CLAUDE_PROJECT_DIR)) {
        Exit-Blocked 'umbraco-upgrade guard error, blocking: the hook input could not be read in an upgrade project.'
    }
    if ($HostTool -ne 'claude' -and $null -eq $hookInput -and (Find-UpgradeRoot (Get-Location).ProviderPath)) {
        Exit-Blocked 'umbraco-upgrade guard error, blocking: the hook input could not be read in an upgrade project.'
    }
    Exit-Allowed
}

# ---- 2. In scope: evaluate rules. Any internal failure blocks.
try {
    if ($null -eq $hookInput) { throw 'the hook input could not be read' }
    Import-Module (Join-Path $PSScriptRoot 'GuardCore.psm1') -DisableNameChecking
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Compat.psm1') -DisableNameChecking
    $state = ConvertTo-PlainObject (Read-JsonFile ([System.IO.Path]::Combine($root, '.umbraco-upgrade', 'state.json')))
    $effectiveCwd = $cwd; if (-not $effectiveCwd) { $effectiveCwd = $root }
    $context = @{ projectRoot = $root; state = $state; cwd = $effectiveCwd; sessionId = $sessionId }
    $decision = $null
    if ($toolName -in @('Bash', 'PowerShell', 'Shell')) {
        $cmd = [string](Get-InputValue $toolInput 'command')
        $marker = [string](Get-GuardRules).canaryMarker
        if ($cmd.Contains($marker)) {
            [void](Write-CanaryEvidence -ProjectRoot $root -Command $cmd -SessionId $sessionId)
            $decision = New-GuardDecision 'guard.canary'
        } elseif ($toolName -eq 'Shell') {
            $decision = Get-StrongestDecision @(
                (Test-ShellToolInput -Command $cmd -ToolName 'Bash' -Context $context),
                (Test-ShellToolInput -Command $cmd -ToolName 'PowerShell' -Context $context))
        } else {
            $decision = Test-ShellToolInput -Command $cmd -ToolName $toolName -Context $context
        }
    } elseif ($toolName -in @('Write', 'Edit', 'NotebookEdit')) {
        $decision = Test-WriteToolInput -HookInput $hookInput -Context $context
    } elseif ($toolName -eq 'Patch') {
        if ($hostPatchFiles.Count -eq 0) { Exit-Blocked 'umbraco-upgrade guard: the files this patch changes could not be read, so it is blocked in an upgrade project.' }
        $decision = Get-StrongestDecision @(foreach ($pf in $hostPatchFiles) {
                Test-WriteToolInput -HookInput ([pscustomobject]@{ tool_input = [pscustomobject]@{ file_path = [string]$pf.file_path; content = [string]$pf.content } }) -Context $context
            })
    } elseif ($HostTool -eq 'claude' -or $hostKind -eq 'mcp') {
        $decision = Test-McpToolInput -Context $context
    }
    if ($null -eq $decision) { Exit-Allowed }
    $message = "umbraco-upgrade guard [$($decision.ruleId)]: $($decision.reason)"
    if ($decision.decision -eq 'deny') { Exit-Blocked $message }
    if ($HostTool -ne 'claude') {
        Write-HookText -To out -Text (Get-HostDecisionJson -HostTool $HostTool -Kind $hostKind -Decision ask -Message $message)
        exit 0
    }
    $out = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'ask'; permissionDecisionReason = $message } }
    Write-HookText -To out -Text (ConvertTo-Json -InputObject $out -Depth 5 -Compress)
    exit 0
} catch {
    Exit-Blocked ("umbraco-upgrade guard error, blocking: " + $_.Exception.Message)
}
