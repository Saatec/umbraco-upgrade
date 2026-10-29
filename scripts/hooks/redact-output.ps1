# redact-output.ps1 - PostToolUse hook on Read for secret-bearing files (filtered by the hook's "if" rules)
# and on Grep (search results show matching lines of any file).
#
# Outside upgrade projects it exits 0 with no output. In an upgrade project it replaces secret values
# in the result with ***REDACTED*** through updatedToolOutput, keeping the tool's output shape: for Read
# { type: "text", file: { filePath, content, numLines, startLine, totalLines } } (verified on Claude
# Code 2.1.296: the replacement is also what the session transcript stores); for Grep the same object
# with every string value redacted, because a replacement that does not match the shape is ignored.
# A failure here never blocks: PostToolUse cannot undo the read, so the hook stays silent on errors.

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

function Protect-Tree {
    # Redacts every string in a parsed JSON value and keeps its shape (property order, arrays, numbers, booleans).
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return (Protect-Text $Node) }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Node.PSObject.Properties) { $h[$p.Name] = Protect-Tree $p.Value }
        return $h
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Node) { [void]$list.Add((Protect-Tree $item)) }
        return ,($list.ToArray())
    }
    return $Node
}

try {
    $hookInput = Read-HookInput | ConvertFrom-Json
    $ti = $hookInput.tool_input
    $tr = $hookInput.tool_response
    $filePath = ''
    foreach ($nm in @('file_path', 'path')) { if ($ti -and $ti.PSObject.Properties[$nm] -and $ti.$nm) { $filePath = [string]$ti.$nm; break } }
    $root = $null
    foreach ($c in @($filePath, [string]$hookInput.cwd, $env:CLAUDE_PROJECT_DIR)) { $root = Find-UpgradeRoot $c; if ($root) { break } }
    if (-not $root -and $env:CLAUDE_PLUGIN_DATA -and $hookInput.session_id -match '^[A-Za-z0-9\-_]+$') {
        $marker = [System.IO.Path]::Combine($env:CLAUDE_PLUGIN_DATA, 'active-sessions', $hookInput.session_id + '.json')
        if ([System.IO.File]::Exists($marker)) { $root = Find-UpgradeRoot ([string]([System.IO.File]::ReadAllText($marker) | ConvertFrom-Json).projectRoot) }
    }
    if (-not $root) { exit 0 }
    if ($null -eq $tr) { exit 0 }
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Redaction.psm1') -DisableNameChecking
    if ([string]$hookInput.tool_name -eq 'Grep') {
        $before = ConvertTo-Json -InputObject $tr -Depth 20 -Compress
        $safe = Protect-Tree $tr
        if ((ConvertTo-Json -InputObject $safe -Depth 20 -Compress) -eq $before) { exit 0 }
        $out = [ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName = 'PostToolUse'
                updatedToolOutput = $safe
                additionalContext = 'umbraco-upgrade: secret values in these search results were replaced with ***REDACTED***. Use scripts/Read-RedactedConfig.ps1 for configuration files.'
            }
        }
        Write-HookText -To out -Text (ConvertTo-Json -InputObject $out -Depth 20 -Compress)
        exit 0
    }
    if ($tr.type -ne 'text' -or $null -eq $tr.file) { exit 0 }
    $content = [string]$tr.file.content
    $redacted = Protect-Text $content
    if ($redacted -eq $content) { exit 0 }
    $file = [ordered]@{}
    foreach ($p in $tr.file.PSObject.Properties) { $file[$p.Name] = $p.Value }
    $file['content'] = $redacted
    $out = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PostToolUse'
            updatedToolOutput = [ordered]@{ type = 'text'; file = $file }
            additionalContext = 'umbraco-upgrade: secret values in this file were replaced with ***REDACTED***. Use scripts/Read-RedactedConfig.ps1 for configuration files.'
        }
    }
    Write-HookText -To out -Text (ConvertTo-Json -InputObject $out -Depth 8 -Compress)
    exit 0
} catch {
    exit 0
}
