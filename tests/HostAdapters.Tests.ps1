# Hook scripts under GitHub Copilot, OpenAI Codex, and Cursor (-HostTool), with payloads in each tool's
# documented input shape. Claude Code behavior is covered by Guard.Tests.ps1 and Redaction.Tests.ps1.
# Label: fixture-based (synthetic upgrade projects, hook scripts run as child processes).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    $script:root = Get-RepoRoot
    $script:proj = New-UpgradeProject -Baseline 'gen.v13'
    $script:outside = New-TestDirectory
    $script:data = New-TestDirectory
    $script:env = @{ UMBRACO_UPGRADE_DATA = $script:data }

    function Invoke-HostHook {
        param([string]$Script, [string]$HostTool, $Payload, [string]$WorkingDirectory = '')
        $json = $(if ($Payload -is [string]) { $Payload } else { ConvertTo-Json -InputObject $Payload -Depth 8 -Compress })
        $wd = $(if ($WorkingDirectory) { $WorkingDirectory } else { $script:outside })
        return (Invoke-PluginScript -Script "scripts/hooks/$Script" -Arguments @('-HostTool', $HostTool) -StdIn $json -WorkingDirectory $wd -Environment $script:env)
    }
    function New-CopilotPre {
        param([string]$Tool, $ToolArgs, [string]$Cwd, [switch]$ArgsAsString)
        $a = $(if ($ArgsAsString) { ConvertTo-Json -InputObject $ToolArgs -Compress } else { $ToolArgs })
        return [ordered]@{ sessionId = 's1'; timestamp = 1; cwd = $Cwd; toolName = $Tool; toolArgs = $a }
    }
    function New-CodexPre {
        param([string]$Tool, $ToolInput, [string]$Cwd)
        return [ordered]@{ session_id = 's1'; transcript_path = $null; cwd = $Cwd; hook_event_name = 'PreToolUse'; model = 'm'; tool_name = $Tool; tool_use_id = 't1'; tool_input = $ToolInput }
    }
    function New-CursorShell {
        param([string]$Command, [string]$Cwd)
        return [ordered]@{ conversation_id = 'c1'; generation_id = 'g1'; hook_event_name = 'beforeShellExecution'; workspace_roots = @($Cwd); command = $Command; cwd = $Cwd }
    }
}

AfterAll {
    Remove-TestDirectory $script:proj
    Remove-TestDirectory $script:outside
    Remove-TestDirectory $script:data
}

Describe 'Guard under GitHub Copilot' -Tag 'fixture-based' {
    It 'denies a force push with permissionDecision deny and exit code 0' {
        $r = Invoke-HostHook guard.ps1 copilot (New-CopilotPre 'bash' @{ command = 'git push --force origin main' } $script:proj)
        $r.ExitCode | Should -Be 0
        $r.Json.permissionDecision | Should -Be 'deny'
        $r.Json.permissionDecisionReason | Should -Match 'git\.force-push'
    }
    It 'reads toolArgs given as a JSON string' {
        $r = Invoke-HostHook guard.ps1 copilot (New-CopilotPre 'powershell' @{ command = 'git push -f origin main' } $script:proj -ArgsAsString)
        $r.Json.permissionDecision | Should -Be 'deny'
    }
    It 'asks for a plain push' {
        $r = Invoke-HostHook guard.ps1 copilot (New-CopilotPre 'bash' @{ command = 'git push origin main' } $script:proj)
        $r.Json.permissionDecision | Should -Be 'ask'
    }
    It 'allows a harmless command with no output' {
        $r = Invoke-HostHook guard.ps1 copilot (New-CopilotPre 'bash' @{ command = 'git status' } $script:proj)
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeNullOrEmpty
    }
    It 'denies creating a project file before the plan is approved' {
        $r = Invoke-HostHook guard.ps1 copilot (New-CopilotPre 'create' @{ path = (Join-Path $script:proj 'src/New.cs'); file_text = 'class X {}' } $script:proj)
        $r.Json.permissionDecision | Should -Be 'deny'
        $r.Json.permissionDecisionReason | Should -Match 'project\.write-before-approval'
    }
    It 'does not check reads' {
        $r = Invoke-HostHook guard.ps1 copilot (New-CopilotPre 'view' @{ path = (Join-Path $script:proj 'README.md') } $script:proj)
        $r.StdOut | Should -BeNullOrEmpty
    }
    It 'is inactive outside an upgrade project' {
        $r = Invoke-HostHook guard.ps1 copilot (New-CopilotPre 'bash' @{ command = 'git push --force origin main' } $script:outside)
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeNullOrEmpty
    }
    It 'denies when the input cannot be read in an upgrade project' {
        $r = Invoke-HostHook guard.ps1 copilot 'not json' -WorkingDirectory $script:proj
        $r.ExitCode | Should -Be 0
        $r.Json.permissionDecision | Should -Be 'deny'
    }
}

Describe 'Guard under OpenAI Codex' -Tag 'fixture-based' {
    It 'denies a force push through hookSpecificOutput' {
        $r = Invoke-HostHook guard.ps1 codex (New-CodexPre 'Bash' @{ command = 'git push --force origin main' } $script:proj)
        $r.ExitCode | Should -Be 0
        $r.Json.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
        $r.Json.hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }
    It 'turns an ask into a deny that tells the user to run it' {
        $r = Invoke-HostHook guard.ps1 codex (New-CodexPre 'Bash' @{ command = 'git push origin main' } $script:proj)
        $r.Json.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        $r.Json.hookSpecificOutput.permissionDecisionReason | Should -Match 'cannot ask'
    }
    It 'checks every file in an apply_patch' {
        $patch = "*** Begin Patch`n*** Update File: README.md`n@@`n-old`n+new`n*** Add File: src/New.cs`n+class X {}`n*** End Patch"
        $r = Invoke-HostHook guard.ps1 codex (New-CodexPre 'apply_patch' @{ command = $patch } $script:proj)
        $r.Json.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        $r.Json.hookSpecificOutput.permissionDecisionReason | Should -Match 'project\.write-before-approval'
    }
    It 'blocks a patch whose files cannot be read' {
        $r = Invoke-HostHook guard.ps1 codex (New-CodexPre 'apply_patch' @{ command = 'not a patch' } $script:proj)
        $r.Json.hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }
    It 'denies a database MCP tool and allows another MCP tool' {
        (Invoke-HostHook guard.ps1 codex (New-CodexPre 'mcp__postgres__query' @{ sql = 'select 1' } $script:proj)).Json.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        (Invoke-HostHook guard.ps1 codex (New-CodexPre 'mcp__github__get_issue' @{ number = 1 } $script:proj)).StdOut | Should -BeNullOrEmpty
    }
    It 'records the gate 3 canary, so the guard self-test passes' {
        $issue = Invoke-PluginScript -Script 'scripts/Test-Guard.ps1' -Arguments @('-ProjectRoot', $script:proj, '-Issue')
        $issue.Json.ok | Should -BeTrue
        $r = Invoke-HostHook guard.ps1 codex (New-CodexPre 'Bash' @{ command = $issue.Json.command } $script:proj)
        $r.Json.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        (Invoke-PluginScript -Script 'scripts/Test-Guard.ps1' -Arguments @('-ProjectRoot', $script:proj, '-Verify')).Json.guardSelfTest | Should -Be 'passed'
    }
}

Describe 'Guard under Cursor' -Tag 'fixture-based' {
    It 'denies a force push in beforeShellExecution' {
        $r = Invoke-HostHook guard.ps1 cursor (New-CursorShell 'git push --force origin main' $script:proj)
        $r.ExitCode | Should -Be 0
        $r.Json.permission | Should -Be 'deny'
        $r.Json.agent_message | Should -Match 'git\.force-push'
    }
    It 'asks for a plain push' {
        (Invoke-HostHook guard.ps1 cursor (New-CursorShell 'git push origin main' $script:proj)).Json.permission | Should -Be 'ask'
    }
    It 'allows explicitly, inside and outside an upgrade project' {
        (Invoke-HostHook guard.ps1 cursor (New-CursorShell 'git status' $script:proj)).Json.permission | Should -Be 'allow'
        (Invoke-HostHook guard.ps1 cursor (New-CursorShell 'git push --force origin main' $script:outside)).Json.permission | Should -Be 'allow'
    }
    It 'denies a Write in preToolUse before the plan is approved' {
        $p = [ordered]@{ conversation_id = 'c1'; hook_event_name = 'preToolUse'; workspace_roots = @($script:proj); cwd = $script:proj; tool_name = 'Write'; tool_input = @{ file_path = (Join-Path $script:proj 'src/New.cs'); content = 'class X {}' } }
        $r = Invoke-HostHook guard.ps1 cursor $p
        $r.Json.permission | Should -Be 'deny'
    }
}

Describe 'Redaction under other AI tools' -Tag 'fixture-based' {
    BeforeAll {
        $script:secretFile = Join-Path $script:proj 'appsettings.Test.json'
        [System.IO.File]::WriteAllText($script:secretFile, '{ "ConnectionStrings": { "umbracoDbDSN": "Server=.;Database=x;User ID=u;Password=FAKE-SECRET-FOR-TESTS-9;" } }')
        $script:plainFile = Join-Path $script:proj 'notes.txt'
        [System.IO.File]::WriteAllText($script:plainFile, 'nothing secret')
    }
    It 'Cursor: denies reading a file with secrets and allows other reads' {
        $p = [ordered]@{ hook_event_name = 'beforeReadFile'; workspace_roots = @($script:proj); file_path = $script:secretFile; content = [System.IO.File]::ReadAllText($script:secretFile) }
        $r = Invoke-HostHook redact-output.ps1 cursor $p
        $r.Json.permission | Should -Be 'deny'
        $r.Json.agent_message | Should -Match 'Read-RedactedConfig'
        $r.StdOut | Should -Not -Match 'FAKE-SECRET'
        $p2 = [ordered]@{ hook_event_name = 'beforeReadFile'; workspace_roots = @($script:proj); file_path = $script:plainFile; content = 'nothing secret' }
        (Invoke-HostHook redact-output.ps1 cursor $p2).Json.permission | Should -Be 'allow'
    }
    It 'Cursor: allows reads outside an upgrade project and on unreadable input' {
        $p = [ordered]@{ hook_event_name = 'beforeReadFile'; workspace_roots = @($script:outside); file_path = (Join-Path $script:outside 'a.json'); content = '"ApiKey": "FAKE-SECRET-FOR-TESTS-3"' }
        (Invoke-HostHook redact-output.ps1 cursor $p).Json.permission | Should -Be 'allow'
        (Invoke-HostHook redact-output.ps1 cursor 'not json').Json.permission | Should -Be 'allow'
    }
    It 'Copilot: replaces a result that holds secrets with the redacted text' {
        $p = [ordered]@{ sessionId = 's1'; timestamp = 1; cwd = $script:proj; toolName = 'view'; toolArgs = @{ path = $script:secretFile }; toolResult = @{ resultType = 'success'; textResultForLlm = [System.IO.File]::ReadAllText($script:secretFile) } }
        $r = Invoke-HostHook redact-output.ps1 copilot $p
        $r.Json.modifiedResult.resultType | Should -Be 'success'
        $r.Json.modifiedResult.textResultForLlm | Should -Match 'REDACTED'
        $r.StdOut | Should -Not -Match 'FAKE-SECRET'
    }
    It 'Copilot: no output for a clean result' {
        $p = [ordered]@{ sessionId = 's1'; timestamp = 1; cwd = $script:proj; toolName = 'bash'; toolArgs = @{ command = 'git status' }; toolResult = @{ resultType = 'success'; textResultForLlm = 'nothing to commit' } }
        (Invoke-HostHook redact-output.ps1 copilot $p).StdOut | Should -BeNullOrEmpty
    }
    It 'Codex: withholds a result that holds secrets' {
        $p = [ordered]@{ session_id = 's1'; cwd = $script:proj; hook_event_name = 'PostToolUse'; tool_name = 'Bash'; tool_input = @{ command = 'type appsettings.Test.json' }; tool_response = [System.IO.File]::ReadAllText($script:secretFile) }
        $r = Invoke-HostHook redact-output.ps1 codex $p
        $r.Json.decision | Should -Be 'block'
        $r.StdOut | Should -Not -Match 'FAKE-SECRET'
    }
}

Describe 'Session context under other AI tools' -Tag 'fixture-based' {
    It 'Copilot: additionalContext' {
        $r = Invoke-HostHook session-context.ps1 copilot ([ordered]@{ sessionId = 's1'; timestamp = 1; cwd = $script:proj; source = 'startup' })
        $r.Json.additionalContext | Should -Match 'Umbraco upgrade'
        $r.Json.additionalContext | Should -Match 'other-tools\.md'
    }
    It 'Codex: hookSpecificOutput.additionalContext' {
        $r = Invoke-HostHook session-context.ps1 codex ([ordered]@{ session_id = 's1'; cwd = $script:proj; hook_event_name = 'SessionStart'; source = 'startup' })
        $r.Json.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        $r.Json.hookSpecificOutput.additionalContext | Should -Match 'Umbraco upgrade'
    }
    It 'Cursor: additional_context, from the workspace root' {
        $r = Invoke-HostHook session-context.ps1 cursor ([ordered]@{ conversation_id = 'c1'; hook_event_name = 'sessionStart'; workspace_roots = @($script:proj) })
        $r.Json.additional_context | Should -Match 'Umbraco upgrade'
    }
    It 'no output outside an upgrade project' {
        (Invoke-HostHook session-context.ps1 copilot ([ordered]@{ sessionId = 's1'; timestamp = 1; cwd = $script:outside; source = 'startup' })).StdOut | Should -BeNullOrEmpty
    }
}

Describe 'Install-HostHooks.ps1' -Tag 'fixture-based' {
    BeforeAll {
        function Invoke-ShellLine {
            # Runs a hook command line the way a tool might: through cmd.exe, or through PowerShell piping
            # the JSON in (as Cursor documents for Windows).
            param([ValidateSet('cmd', 'powershell')][string]$Shell, [string]$Line, [string]$StdIn, [string]$WorkingDirectory)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            if ($Shell -eq 'cmd') { $psi.FileName = 'cmd.exe'; $psi.Arguments = '/d /s /c "' + $Line + '"' }
            else {
                $psi.FileName = 'powershell.exe'
                $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes('$input | ' + $Line))
                $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + $enc
            }
            $psi.WorkingDirectory = $WorkingDirectory
            $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ($k -like 'CLAUDE*') { $psi.EnvironmentVariables.Remove($k) } }
            $psi.EnvironmentVariables['UMBRACO_UPGRADE_DATA'] = $script:data
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Write($StdIn); $p.StandardInput.Close()
            $out = $p.StandardOutput.ReadToEnd(); [void]$p.StandardError.ReadToEnd(); $p.WaitForExit()
            $json = $null; $t = $out.Trim(); if ($t.StartsWith('{')) { try { $json = $t | ConvertFrom-Json } catch { } }
            return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; Json = $json }
        }
        $script:force = 'git push --force origin main'
    }

    It 'Copilot: writes its own hook file with absolute paths and excludes it from git' {
        $r = Invoke-PluginScript -Script 'scripts/Install-HostHooks.ps1' -Arguments @('-Tool', 'copilot', '-ProjectRoot', $script:proj)
        $r.Json.ok | Should -BeTrue
        $file = Join-Path $script:proj '.github/hooks/umbraco-upgrade.json'
        $cfg = Get-Content -Raw $file | ConvertFrom-Json
        $cfg.version | Should -Be 1
        $cfg.hooks.preToolUse[0].powershell | Should -Match ([regex]::Escape((Join-Path $script:root 'scripts\hooks\guard.ps1')))
        $cfg.hooks.postToolUse[0].matcher | Should -Be 'view|bash|powershell|grep'
        (Get-Content -Raw (Join-Path $script:proj '.git/info/exclude')) | Should -Match ([regex]::Escape('/.github/hooks/umbraco-upgrade.json'))
        (& git -C $script:proj status --porcelain -- .github) | Should -BeNullOrEmpty
    }
    It 'Copilot: the installed command line blocks a force push through cmd.exe and PowerShell' {
        $cfg = Get-Content -Raw (Join-Path $script:proj '.github/hooks/umbraco-upgrade.json') | ConvertFrom-Json
        $payload = ConvertTo-Json -Compress -InputObject ([ordered]@{ sessionId = 's1'; timestamp = 1; cwd = $script:proj; toolName = 'bash'; toolArgs = @{ command = $script:force } })
        foreach ($shell in @('cmd', 'powershell')) {
            (Invoke-ShellLine $shell $cfg.hooks.preToolUse[0].powershell $payload $script:proj).Json.permissionDecision | Should -Be 'deny' -Because $shell
        }
    }
    It 'Codex: merges into an existing hooks.json, keeps other hooks, and does not duplicate on a rerun' {
        $file = Join-Path $script:proj '.codex/hooks.json'
        [void][System.IO.Directory]::CreateDirectory((Split-Path $file))
        [System.IO.File]::WriteAllText($file, '{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo mine", "statusMessage": "my hook" } ] } ] } }')
        foreach ($i in 1..2) { (Invoke-PluginScript -Script 'scripts/Install-HostHooks.ps1' -Arguments @('-Tool', 'codex', '-ProjectRoot', $script:proj)).Json.ok | Should -BeTrue }
        $cfg = Get-Content -Raw $file | ConvertFrom-Json
        @($cfg.hooks.PreToolUse).Count | Should -Be 2
        $cfg.hooks.PreToolUse[0].hooks[0].statusMessage | Should -Be 'my hook'
        $cfg.hooks.PreToolUse[1].matcher | Should -Be '*'
        @($cfg.hooks.SessionStart).Count | Should -Be 1
        $cfg.hooks.PostToolUse[0].matcher | Should -Be 'Bash'
        (& git -C $script:proj status --porcelain -- .codex) | Should -BeNullOrEmpty
    }
    It 'Codex: the installed Windows command line blocks a force push through cmd.exe and PowerShell' {
        $cfg = Get-Content -Raw (Join-Path $script:proj '.codex/hooks.json') | ConvertFrom-Json
        $payload = ConvertTo-Json -Compress -InputObject ([ordered]@{ session_id = 's1'; cwd = $script:proj; hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = $script:force } })
        foreach ($shell in @('cmd', 'powershell')) {
            (Invoke-ShellLine $shell $cfg.hooks.PreToolUse[1].hooks[0].command_windows $payload $script:proj).Json.hookSpecificOutput.permissionDecision | Should -Be 'deny' -Because $shell
        }
    }
    It 'refuses to change a hook file that is tracked in git' {
        $p2 = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $f = Join-Path $p2 '.codex/hooks.json'
            [void][System.IO.Directory]::CreateDirectory((Split-Path $f)); [System.IO.File]::WriteAllText($f, '{ "hooks": {} }')
            $null = & git -C $p2 add .codex/hooks.json 2>&1; $null = & git -C $p2 -c user.name=t -c user.email=t@example.invalid commit -q -m hooks 2>&1
            $r = Invoke-PluginScript -Script 'scripts/Install-HostHooks.ps1' -Arguments @('-Tool', 'codex', '-ProjectRoot', $p2)
            $r.Json.ok | Should -BeFalse
            $r.Json.error | Should -Match 'tracked'
            (Get-Content -Raw $f) | Should -Be '{ "hooks": {} }'
        } finally { Remove-TestDirectory $p2 }
    }
    It 'Cursor: the plugin hook command line, run from the plugin folder through PowerShell, blocks a force push' {
        $cfg = Get-Content -Raw (Join-Path $script:root 'hooks/cursor-hooks.json') | ConvertFrom-Json
        $payload = ConvertTo-Json -Compress -InputObject ([ordered]@{ conversation_id = 'c1'; hook_event_name = 'beforeShellExecution'; workspace_roots = @($script:proj); command = $script:force; cwd = $script:proj })
        (Invoke-ShellLine powershell $cfg.hooks.beforeShellExecution[0].command $payload $script:root).Json.permission | Should -Be 'deny'
    }
}

Describe 'Manifests for other AI tools' -Tag 'fixture-based' {
    BeforeAll {
        $script:claude = Get-Content -Raw (Join-Path $script:root '.claude-plugin/plugin.json') | ConvertFrom-Json
    }
    It '<_> has the same name and version as the Claude Code manifest' -ForEach @('.github/plugin/plugin.json', '.codex-plugin/plugin.json', '.cursor-plugin/plugin.json') {
        $m = Get-Content -Raw (Join-Path $script:root $_) | ConvertFrom-Json
        $m.name | Should -Be $script:claude.name
        $m.version | Should -Be $script:claude.version
    }
    It 'Copilot and Codex manifests replace the Claude Code hooks file with empty hooks' {
        $copilot = Get-Content -Raw (Join-Path $script:root '.github/plugin/plugin.json') | ConvertFrom-Json
        $copilot.hooks.version | Should -Be 1
        @($copilot.hooks.hooks.PSObject.Properties).Count | Should -Be 0
        @((Get-Content -Raw (Join-Path $script:root '.codex-plugin/plugin.json') | ConvertFrom-Json).hooks.hooks.PSObject.Properties).Count | Should -Be 0
    }
    It 'every Cursor hook runs an existing script with -HostTool cursor, and security hooks fail closed' {
        $m = Get-Content -Raw (Join-Path $script:root '.cursor-plugin/plugin.json') | ConvertFrom-Json
        $cfg = Get-Content -Raw (Join-Path $script:root ($m.hooks -replace '^\./', '')) | ConvertFrom-Json
        $cfg.version | Should -Be 1
        foreach ($ev in $cfg.hooks.PSObject.Properties) {
            foreach ($h in @($ev.Value)) {
                $h.command | Should -Match '-HostTool cursor$'
                $h.command -match '-File \./(\S+)' | Should -BeTrue
                Test-Path (Join-Path $script:root $Matches[1]) | Should -BeTrue
                if ($ev.Name -in @('beforeShellExecution', 'preToolUse', 'beforeMCPExecution')) { $h.failClosed | Should -BeTrue -Because $ev.Name }
            }
        }
    }
    It 'the Claude Code hooks file is unchanged: no -HostTool' {
        (Get-Content -Raw (Join-Path $script:root 'hooks/hooks.json')) | Should -Not -Match 'HostTool'
    }
    It 'command skill <_> is user-only in Codex and points to other-tools.md' -ForEach @('start', 'plan', 'resume', 'verify', 'report', 'feedback', 'update-knowledge') {
        (Get-Content -Raw (Join-Path $script:root "skills/$_/agents/openai.yaml")) | Should -Match 'allow_implicit_invocation: false'
        (Get-Content -Raw (Join-Path $script:root "skills/$_/SKILL.md")) | Should -Match ([regex]::Escape('(../upgrade-workflow/references/other-tools.md)'))
    }
}
