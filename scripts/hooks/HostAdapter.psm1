# HostAdapter.psm1 - lets the hook scripts run under AI coding tools other than Claude Code.
#
# The hook scripts were written for Claude Code's hook input and output. GitHub Copilot, OpenAI Codex,
# and Cursor send different input (field names, tool names) and expect different output. This module
# converts their input to the Claude Code shape the hook scripts already understand, and converts a
# decision back to the tool's own output format. Claude Code itself never goes through this module.
#
# Output for the other tools is always JSON on stdout with exit code 0, because a shell wrapper around
# the hook command can turn exit code 2 into 1 (seen with Windows PowerShell -Command).

Set-StrictMode -Version 2.0

$script:DatabaseToolPattern = '([Ss][Qq][Ll]|[Dd]atabase|DATABASE|_db_|__db|_db$|[Pp]ostgres|[Mm]y[Ss]ql|[Mm]ongo)'

function Get-HostValue {
    # Returns the first property of $Object named in $Names that is present and not null.
    param($Object, [string[]]$Names)
    if ($null -eq $Object -or $Object -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    }
    return $null
}

function Get-HostDataDir {
    # The plugin data directory. Claude Code provides CLAUDE_PLUGIN_DATA. The other tools use one fixed
    # folder per user, so the skills and the hooks agree on it: UMBRACO_UPGRADE_DATA, else ~/.umbraco-upgrade/data.
    param([Parameter(Mandatory)][string]$HostTool)
    if ($HostTool -eq 'claude') { return $env:CLAUDE_PLUGIN_DATA }
    $d = $env:UMBRACO_UPGRADE_DATA
    if (-not $d) { $d = [System.IO.Path]::Combine($HOME, '.umbraco-upgrade', 'data') }
    return $d
}

function Get-PatchFiles {
    # Files named in an apply_patch text: "*** Add File: p", "*** Update File: p", "*** Delete File: p",
    # "*** Move to: p". Content is the added lines (prefix "+").
    param([string]$Text)
    $files = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\*\*\* (Add|Update|Delete) File:\s*(.+?)\s*$') {
            $cur = @{ op = $Matches[1].ToLowerInvariant(); file_path = $Matches[2]; content = '' }
            [void]$files.Add($cur)
            continue
        }
        if ($line -match '^\*\*\* Move to:\s*(.+?)\s*$') {
            $cur = @{ op = 'move'; file_path = $Matches[1]; content = '' }
            [void]$files.Add($cur)
            continue
        }
        if ($null -ne $cur -and $line.StartsWith('+') -and -not $line.StartsWith('+++')) { $cur.content += $line.Substring(1) + "`n" }
    }
    return ,($files.ToArray())
}

function ConvertTo-HostText {
    # A tool result as text: strings as they are, objects as compact JSON.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    return (ConvertTo-Json -InputObject $Value -Depth 20 -Compress)
}

function ConvertFrom-HostHookInput {
    # Converts a tool's parsed hook input to the Claude Code shape:
    #   tool_name   Shell (any shell command), Write, Patch, Read, Mcp, or Other
    #   tool_input  { command } for Shell, { file_path, content } for Write
    #   cwd, session_id
    # plus host_kind (shell, write, patch, read, mcp, other, session), host_patch_files, host_read_path,
    # host_read_content, and host_output_text (the tool result for post-tool hooks).
    param([Parameter(Mandatory)][string]$HostTool, $InputObject)
    if ($null -eq $InputObject -or $InputObject -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $o = $InputObject
    $cwd = [string](Get-HostValue $o @('cwd'))
    if (-not $cwd) { $roots = Get-HostValue $o @('workspace_roots'); if ($null -ne $roots) { $cwd = [string](@($roots)[0]) } }
    $session = [string](Get-HostValue $o @('session_id', 'sessionId', 'conversation_id'))
    $hookEvent = [string](Get-HostValue $o @('hook_event_name', 'hookEventName'))
    $name = [string](Get-HostValue $o @('tool_name', 'toolName'))
    $toolArgs = Get-HostValue $o @('tool_input', 'toolArgs')
    if ($toolArgs -is [string]) {
        $parsed = $null
        try { $parsed = $toolArgs | ConvertFrom-Json } catch { $parsed = $null }
        if ($parsed -is [System.Management.Automation.PSCustomObject]) { $toolArgs = $parsed } else { $toolArgs = [pscustomobject]@{ command = $toolArgs } }
    }
    $topCommand = Get-HostValue $o @('command')
    $topFile = [string](Get-HostValue $o @('file_path'))
    $output = Get-HostValue $o @('tool_response', 'toolResult', 'tool_output')
    if ($output -is [System.Management.Automation.PSCustomObject]) {
        $text = Get-HostValue $output @('textResultForLlm', 'text_result_for_llm')
        if ($null -ne $text) { $output = $text }
    }

    $kind = 'other'; $toolName = 'Other'; $toolInput = [pscustomobject]@{}
    $patchFiles = @(); $readPath = ''; $readContent = $null
    if ($hookEvent -eq 'beforeShellExecution' -or (-not $name -and $topCommand -is [string])) {
        $kind = 'shell'; $toolName = 'Shell'; $toolInput = [pscustomobject]@{ command = [string]$topCommand }
    } elseif ($hookEvent -eq 'beforeReadFile' -or (-not $name -and $topFile)) {
        $kind = 'read'; $toolName = 'Read'; $readPath = $topFile
        $readContent = Get-HostValue $o @('content')
        $toolInput = [pscustomobject]@{ file_path = $topFile }
    } elseif ($hookEvent -eq 'beforeMCPExecution' -or $hookEvent -eq 'sessionStart' -or $hookEvent -eq 'SessionStart' -or -not $name) {
        if ($hookEvent -eq 'beforeMCPExecution') {
            $server = [string](Get-HostValue $o @('server', 'server_name'))
            $toolName = 'mcp__' + $server + '__' + $name
            $kind = $(if ($toolName -match $script:DatabaseToolPattern) { 'mcp' } else { 'other' })
        } else {
            $kind = 'session'
        }
    } elseif ($name -match '^(?i)(bash|powershell|shell|exec_command|run_in_terminal|run_terminal_cmd)$') {
        $kind = 'shell'; $toolName = 'Shell'
        $toolInput = [pscustomobject]@{ command = [string](Get-HostValue $toolArgs @('command', 'cmd')) }
    } elseif ($name -eq 'apply_patch') {
        $kind = 'patch'; $toolName = 'Patch'
        $patchText = [string](Get-HostValue $toolArgs @('command', 'input', 'patch'))
        $patchFiles = Get-PatchFiles -Text $patchText
    } elseif ($name -match '^(?i)(write|edit|create|str_replace_editor|str_replace_based_edit_tool|multiedit|delete|notebookedit)$') {
        $kind = 'write'; $toolName = 'Write'
        $path = [string](Get-HostValue $toolArgs @('file_path', 'path', 'filePath', 'target_file', 'notebook_path'))
        $content = ''
        foreach ($n in @('content', 'contents', 'file_text', 'new_str', 'new_string', 'newString', 'code_edit', 'new_source')) {
            $v = Get-HostValue $toolArgs @($n)
            if ($null -ne $v) { $content += [string]$v + "`n" }
        }
        $toolInput = [pscustomobject]@{ file_path = $path; content = $content }
    } elseif ($name -match '^(?i)(read|view)$') {
        $kind = 'read'; $toolName = 'Read'
        $readPath = [string](Get-HostValue $toolArgs @('file_path', 'path', 'filePath', 'target_file'))
        $toolInput = [pscustomobject]@{ file_path = $readPath }
    } elseif ($name -match '^(?i)(grep|rg|glob)$') {
        $kind = 'search'; $toolName = 'Grep'
    } elseif ($name -match '^mcp__' -or $name -match '^MCP:') {
        $toolName = $name
        $kind = $(if ($name -match $script:DatabaseToolPattern) { 'mcp' } else { 'other' })
    }

    return [pscustomobject]@{
        tool_name = $toolName
        tool_input = $toolInput
        cwd = $cwd
        session_id = $session
        host_kind = $kind
        host_patch_files = $patchFiles
        host_read_path = $readPath
        host_read_content = $readContent
        host_output_text = (ConvertTo-HostText $output)
    }
}

function Get-HostDecisionJson {
    # The tool's output for a guard decision. Tools that cannot ask the user get a deny that says so.
    param(
        [Parameter(Mandatory)][string]$HostTool,
        [string]$Kind = 'shell',
        [Parameter(Mandatory)][ValidateSet('allow', 'deny', 'ask')][string]$Decision,
        [string]$Message = ''
    )
    $cannotAsk = ' This operation needs the user''s approval, and this tool cannot ask for it: ask the user to run it themselves.'
    switch ($HostTool) {
        'copilot' {
            if ($Decision -eq 'allow') { return '' }
            return (ConvertTo-Json -Compress -InputObject ([ordered]@{ permissionDecision = $Decision; permissionDecisionReason = $Message }))
        }
        'codex' {
            if ($Decision -eq 'allow') { return '' }
            $m = $Message; if ($Decision -eq 'ask') { $m += $cannotAsk }
            return (ConvertTo-Json -Compress -Depth 4 -InputObject ([ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $m } }))
        }
        'cursor' {
            # Cursor parses the output of permission hooks; an empty or invalid output can block, so allow is explicit.
            if ($Decision -eq 'allow') { return '{"continue":true,"permission":"allow"}' }
            $p = $Decision; $m = $Message
            if ($p -eq 'ask' -and $Kind -notin @('shell', 'mcp')) { $p = 'deny'; $m += $cannotAsk }
            return (ConvertTo-Json -Compress -InputObject ([ordered]@{ continue = $true; permission = $p; user_message = $m; agent_message = $m }))
        }
    }
    throw "Unknown host tool '$HostTool'."
}

function Get-HostContextJson {
    # The tool's session-start output that adds $Text to the conversation context.
    param([Parameter(Mandatory)][string]$HostTool, [Parameter(Mandatory)][string]$Text)
    switch ($HostTool) {
        'copilot' { return (ConvertTo-Json -Compress -InputObject ([ordered]@{ additionalContext = $Text })) }
        'codex' { return (ConvertTo-Json -Compress -Depth 4 -InputObject ([ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'SessionStart'; additionalContext = $Text } })) }
        'cursor' { return (ConvertTo-Json -Compress -InputObject ([ordered]@{ additional_context = $Text })) }
    }
    throw "Unknown host tool '$HostTool'."
}

Export-ModuleMember -Function Get-HostValue, Get-HostDataDir, Get-PatchFiles, ConvertFrom-HostHookInput, Get-HostDecisionJson, Get-HostContextJson
