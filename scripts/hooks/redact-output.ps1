# redact-output.ps1 - PostToolUse hook on Read for secret-bearing files (filtered by the hook's "if" rules),
# on Grep (search results show matching lines of any file), and on Bash and PowerShell (command output can
# show configuration, for example git show or git diff of a settings file).
#
# Outside upgrade projects it exits 0 with no output. In an upgrade project it replaces secret values
# in the result with ***REDACTED*** through updatedToolOutput, keeping the tool's output shape: for Read
# { type: "text", file: { filePath, content, numLines, startLine, totalLines } } (verified on Claude
# Code 2.1.296: the replacement is also what the session transcript stores); for the other tools the same
# object with every string value redacted, because a replacement that does not match the shape is ignored.
# A failure here never blocks: PostToolUse cannot undo the read, so the hook stays silent on errors.
#
# -HostTool copilot|codex|cursor, in an upgrade project, when the result holds secret values:
#   copilot  postToolUse: replaces the result with the redacted text (modifiedResult)
#   codex    PostToolUse: withholds the whole result (Codex cannot rewrite it) and says why
#   cursor   beforeReadFile: denies the read and points to Read-RedactedConfig.ps1 (Cursor cannot
#            rewrite what a read returns); every other read gets an explicit allow

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

if ($HostTool -ne 'claude') {
    $allow = $(if ($HostTool -eq 'cursor') { '{"permission":"allow"}' } else { '' })
    $result = $allow
    try {
        Import-Module (Join-Path $PSScriptRoot 'HostAdapter.psm1') -DisableNameChecking
        $env:CLAUDE_PLUGIN_DATA = Get-HostDataDir -HostTool $HostTool
        $n = ConvertFrom-HostHookInput -HostTool $HostTool -InputObject (Read-HookInput | ConvertFrom-Json)
        $root = $null
        if ($null -ne $n) {
            $readPath = [string]$n.host_read_path
            if ($readPath -and $n.cwd -and -not [System.IO.Path]::IsPathRooted($readPath)) { $readPath = [System.IO.Path]::Combine([string]$n.cwd, $readPath) }
            foreach ($c in @($readPath, [string]$n.cwd, (Get-Location).ProviderPath)) { $root = Find-UpgradeRoot $c; if ($root) { break } }
        }
        if ($root) {
            Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Redaction.psm1') -DisableNameChecking
            $note = 'umbraco-upgrade: secret values were found. Read configuration files with scripts/Read-RedactedConfig.ps1 from the plugin folder.'
            if ($HostTool -eq 'cursor') {
                $content = $n.host_read_content
                if ($null -eq $content -and $readPath -and [System.IO.File]::Exists($readPath)) { $content = [System.IO.File]::ReadAllText($readPath) }
                $content = [string]$content
                if ($content -and (Protect-Text $content) -ne $content) {
                    $result = ConvertTo-Json -Compress -InputObject ([ordered]@{ permission = 'deny'; user_message = $note; agent_message = $note })
                }
            } else {
                $text = [string]$n.host_output_text
                $redacted = Protect-Text $text
                if ($text -and $redacted -ne $text) {
                    if ($HostTool -eq 'copilot') {
                        $result = ConvertTo-Json -Compress -Depth 4 -InputObject ([ordered]@{ modifiedResult = [ordered]@{ resultType = 'success'; textResultForLlm = $redacted }; additionalContext = $note })
                    } else {
                        $result = ConvertTo-Json -Compress -InputObject ([ordered]@{ decision = 'block'; reason = 'umbraco-upgrade withheld this output because it contained secret values. Read configuration files with scripts/Read-RedactedConfig.ps1 from the plugin folder.' })
                    }
                }
            }
        }
    } catch { $result = $allow }
    if ($result) { Write-HookText -To out -Text $result }
    exit 0
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
    if ([string]$hookInput.tool_name -in @('Grep', 'Bash', 'PowerShell')) {
        $before = ConvertTo-Json -InputObject $tr -Depth 20 -Compress
        $safe = Protect-Tree $tr
        if ((ConvertTo-Json -InputObject $safe -Depth 20 -Compress) -eq $before) { exit 0 }
        $out = [ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName = 'PostToolUse'
                updatedToolOutput = $safe
                additionalContext = 'umbraco-upgrade: secret values in this tool output were replaced with ***REDACTED***. Use scripts/Read-RedactedConfig.ps1 for configuration files.'
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
