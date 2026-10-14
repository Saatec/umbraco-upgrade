<#
.SYNOPSIS
  Creates the dedicated upgrade branch from a clean tree and records it in state.

.DESCRIPTION
  Reversible. Refuses when: not upgrade mode, gates 1 and 2 have not passed, the tree has changes
  outside .umbraco-upgrade/, a git operation is in progress, HEAD is detached, or the branch exists.
  Default branch name: umbraco-upgrade/<source-major>-to-<target>.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '', [string]$Branch = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $state = Read-UpgradeState $root
    if ($state['mode'] -ne 'upgrade') { throw 'The upgrade branch is created only by /umbraco-upgrade:start (upgrade mode).' }
    foreach ($g in @('discovery', 'versionPath')) {
        if ($state['gates'][$g]['status'] -ne 'passed') { throw "Gate '$g' has not passed." }
    }
    if ($state['gitBaseline']['upgradeBranch']) { throw "An upgrade branch is already recorded: $($state['gitBaseline']['upgradeBranch'])." }
    $repo = Get-GitRepoInfo -Root $root
    if (-not $repo.isRepo) { throw 'Not a git repository.' }
    if ($repo.detached -or -not $repo.branch) { throw 'HEAD is detached; ask the user which branch to start from.' }
    if (Get-GitOperationInProgress -Root $root) { throw 'A git operation is in progress.' }
    $entries = Get-GitStatusEntries -Root $root -Prefix $repo.prefix
    $dirty = @($entries | Where-Object { -not $_.inStateFolder })
    if ($dirty.Count -gt 0) { throw "There are $($dirty.Count) uncommitted change(s) outside .umbraco-upgrade/. Stop and ask the user." }
    if (-not $Branch) {
        $src = $state['source']['major']; if ($null -eq $src) { $src = 'src' }
        $Branch = "umbraco-upgrade/$src-to-$($state['target']['requested'])"
    }
    $chk = Invoke-GitCommand -Root $root -Arguments @('check-ref-format', '--branch', $Branch)
    if ($chk.exitCode -ne 0) { throw "'$Branch' is not a valid branch name." }
    $exists = Invoke-GitCommand -Root $root -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")
    if ($exists.exitCode -eq 0) { throw "Branch '$Branch' already exists. Ask the user whether to use another name." }
    $baseBranch = $repo.branch; $baseCommit = $repo.head
    $sw = Invoke-GitCommand -Root $root -Arguments @('switch', '-c', $Branch)
    if ($sw.exitCode -ne 0) { $sw = Invoke-GitCommand -Root $root -Arguments @('checkout', '-b', $Branch) }
    if ($sw.exitCode -ne 0) { throw ('git could not create the branch: ' + $sw.stderr.Trim()) }
    [void](Update-StateSection -ProjectRoot $root -Section gitBaseline -Values ([ordered]@{ baseBranch = $baseBranch; baseCommit = $baseCommit; upgradeBranch = $Branch }))
    Write-JsonOutput ([ordered]@{ ok = $true; branch = $Branch; baseBranch = $baseBranch; baseCommit = $baseCommit })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
