<#
.SYNOPSIS
  Gate 3 guard self-test. Proves the safety hook blocks a prohibited command on this machine.

.DESCRIPTION
  -Issue   creates a nonce, records it in state, and prints the canary command to run through the
           normal shell tool. The canary is harmless even without the guard: it is a dry run against
           a remote that does not exist.
  -Verify  checks the evidence file the guard writes when it blocks the canary, and records
           guardSelfTest = passed or failed in state.
  If the canary is not blocked, gate 3 fails: the safety hooks are not active, and the upgrade
  cannot proceed.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '', [switch]$Issue, [switch]$Verify)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking

$marker = '__umbraco_upgrade_guard_canary__'
try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if ($Issue -eq $Verify) { throw 'Pass exactly one of -Issue or -Verify.' }
    $state = Read-UpgradeState $root
    if ($Issue) {
        $nonce = [guid]::NewGuid().ToString('N').Substring(0, 16)
        [void](Set-GateFields -ProjectRoot $root -Gate safety -Fields @{ canaryNonce = $nonce; guardSelfTest = 'issued' } -Event 'guard-canary-issued')
        $cmd = "git push --force --dry-run $marker$nonce"
        Write-JsonOutput ([ordered]@{
            ok = $true; nonce = $nonce; command = $cmd
            instructions = "Run exactly this command with the normal shell tool, from the project directory, and expect it to be blocked by the umbraco-upgrade guard. Then run Test-Guard.ps1 -Verify."
        })
        exit 0
    }
    $nonce = $state['gates']['safety']['canaryNonce']
    if (-not $nonce) { throw 'No canary has been issued. Run Test-Guard.ps1 -Issue first.' }
    $evidence = Join-Path (Get-StateDir $root) "evidence/safety/guard-canary-$nonce.json"
    $passed = [System.IO.File]::Exists($evidence)
    $result = $(if ($passed) { 'passed' } else { 'failed' })
    [void](Set-GateFields -ProjectRoot $root -Gate safety -Fields @{ guardSelfTest = $result } -Event 'guard-self-test')
    $msg = $(if ($passed) { 'The guard blocked the canary. Safety hooks are active.' } else { 'Safety hooks are not active; the upgrade cannot proceed. The guard did not record blocking the canary.' })
    Write-JsonOutput ([ordered]@{ ok = $passed; guardSelfTest = $result; evidence = $(if ($passed) { "evidence/safety/guard-canary-$nonce.json" } else { $null }); message = $msg })
    if ($passed) { exit 0 } else { exit 1 }
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
