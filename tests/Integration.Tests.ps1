# Integration: the plugin loaded with claude -p --plugin-dir under bypassPermissions.
#  1. The guard blocks the canary in a temporary upgrade project.
#  2. The guard does not interfere in a temporary project without .umbraco-upgrade/.
# Label: fixture-based. Selector tag: integration (excluded by default; costs a few model calls).
# Requires the claude CLI on PATH and logged in (claude auth status).

BeforeDiscovery {
    $script:claudeReady = $false
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $null = & claude auth status 2>&1
        $script:claudeReady = ($LASTEXITCODE -eq 0)
    }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Git.psm1') -Force -DisableNameChecking
    $script:Marker = '__umbraco_upgrade_guard_canary__'

    function Invoke-ClaudePrint([string]$WorkingDirectory, [string]$Prompt) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command claude).Source
        $cliArgs = @('-p', $Prompt, '--plugin-dir', (Get-RepoRoot), '--permission-mode', 'bypassPermissions',
            '--output-format', 'stream-json', '--verbose', '--no-session-persistence', '--max-budget-usd', '1')
        $psi.Arguments = (($cliArgs | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        # Run as a fresh terminal session would: drop variables a host Claude session exports.
        foreach ($k in @($psi.EnvironmentVariables.Keys)) {
            if ($k -like 'CLAUDE*' -or $k -in @('AI_AGENT', 'BAGGAGE', 'PSExecutionPolicyPreference')) { $psi.EnvironmentVariables.Remove($k) }
        }
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(300000)) { try { $p.Kill() } catch { }; throw 'claude -p timed out' }
        $p.WaitForExit()
        $events = @()
        foreach ($line in ($outTask.Result -split "`r?`n")) {
            if ($line.Trim().StartsWith('{')) { try { $events += ($line | ConvertFrom-Json) } catch { } }
        }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Events = $events; StdErr = $errTask.Result }
    }

    function Get-CanaryResult($Events) {
        # Finds the shell tool call that ran the canary and the tool result it got back.
        $uses = @()
        foreach ($e in $Events) {
            if ($e.type -eq 'assistant') {
                foreach ($c in @($e.message.content)) {
                    if ($c.type -eq 'tool_use' -and $c.name -in @('Bash', 'PowerShell') -and ([string]$c.input.command).Contains($script:Marker)) { $uses += $c }
                }
            }
        }
        if ($uses.Count -eq 0) { return $null }
        $id = $uses[0].id
        foreach ($e in $Events) {
            if ($e.type -eq 'user') {
                foreach ($c in @($e.message.content)) {
                    if ($c.type -eq 'tool_result' -and $c.tool_use_id -eq $id) {
                        $text = $(if ($c.content -is [string]) { $c.content } else { (@($c.content) | ForEach-Object { $_.text }) -join "`n" })
                        return [pscustomobject]@{ IsError = [bool]$c.is_error; Text = $text }
                    }
                }
            }
        }
        return [pscustomobject]@{ IsError = $null; Text = '' }
    }
}

Describe 'Guard under claude -p --plugin-dir in bypassPermissions mode' -Tag 'fixture-based', 'integration' -Skip:(-not $script:claudeReady) {
    It 'blocks the canary in an upgrade project' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $issue = Invoke-PluginScript -Script 'scripts/Test-Guard.ps1' -Arguments @('-ProjectRoot', $d, '-Issue')
            $cmd = $issue.Json.command
            $prompt = "Run exactly this shell command once, from the current directory, and nothing else: $cmd . It is a harmless dry run against a remote that does not exist. Do not retry it and do not run any other command. Then report whether it ran or was blocked, quoting the error text."
            $run = Invoke-ClaudePrint -WorkingDirectory $d -Prompt $prompt
            $res = Get-CanaryResult $run.Events
            $res | Should -Not -BeNullOrEmpty -Because 'the model must attempt the canary command'
            $res.IsError | Should -BeTrue
            $res.Text | Should -Match ([regex]::Escape('umbraco-upgrade guard [guard.canary]'))
            $verify = Invoke-PluginScript -Script 'scripts/Test-Guard.ps1' -Arguments @('-ProjectRoot', $d, '-Verify')
            $verify.Json.guardSelfTest | Should -Be 'passed'
        } finally { Remove-TestDirectory $d }
    }

    It 'does not interfere in a project without .umbraco-upgrade/' {
        $d = Copy-Fixture -Baseline 'gen.v13'
        try {
            Initialize-GitRepo -Path $d -Commit
            $cmd = "git push --force --dry-run $($script:Marker)0123456789abcdef"
            $prompt = "Run exactly this shell command once, from the current directory, and nothing else: $cmd . It is a harmless dry run against a remote that does not exist, so git will report an error. Do not retry it and do not run any other command. Then report the output."
            $run = Invoke-ClaudePrint -WorkingDirectory $d -Prompt $prompt
            $res = Get-CanaryResult $run.Events
            $res | Should -Not -BeNullOrEmpty -Because 'the model must attempt the command'
            $res.Text | Should -Not -Match 'umbraco-upgrade guard'
            $res.Text | Should -Match '(?i)does not appear to be a git repository|could not read from remote|fatal'
            Test-Path (Join-Path $d '.umbraco-upgrade') | Should -BeFalse
        } finally { Remove-TestDirectory $d }
    }
}
