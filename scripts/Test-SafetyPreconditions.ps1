<#
.SYNOPSIS
  Gate 3 read-only checks: git repository, working tree status (ignoring .umbraco-upgrade/), operations in progress, remotes, stash.

.DESCRIPTION
  Prints one JSON object. "ok" is true only when the tree is clean outside the state folder, no git
  operation is in progress, and HEAD is on a branch with at least one commit. Never changes anything.
  Remote URLs are printed with any embedded credentials removed.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Git.psm1') -DisableNameChecking

function Remove-UrlCredentials { param([string]$Url) return ($Url -replace '(?i)^([a-z][a-z0-9+\-.]*://)[^/@]+@', '$1***@') }

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $problems = New-Object System.Collections.ArrayList
    $repo = Get-GitRepoInfo -Root $root
    $out = [ordered]@{ ok = $false; projectRoot = $root; gitAvailable = $repo.gitAvailable; isRepo = $repo.isRepo; repoRoot = $repo.repoRoot
        branch = $repo.branch; head = $repo.head; detached = $repo.detached; operationInProgress = $null; changes = @(); stateFolderChanges = 0
        remotes = @(); stashCount = 0; problems = @() }
    if (-not $repo.gitAvailable) {
        [void]$problems.Add([ordered]@{ code = 'git-missing'; message = 'git is not available on PATH. Install git; the upgrade needs a dedicated branch.' })
    } elseif (-not $repo.isRepo) {
        [void]$problems.Add([ordered]@{ code = 'not-a-repo'; message = 'The project is not in a git repository. Ask the user to put it under version control; never initialize or commit on their behalf without asking.' })
    } else {
        $entries = Get-GitStatusEntries -Root $root -Prefix $repo.prefix
        $outside = @($entries | Where-Object { -not $_.inStateFolder })
        $out.changes = @($outside | ForEach-Object { [ordered]@{ code = $_.code; path = $_.path } })
        $out.stateFolderChanges = @($entries | Where-Object { $_.inStateFolder }).Count
        if ($outside.Count -gt 0) {
            [void]$problems.Add([ordered]@{ code = 'uncommitted-changes'; message = "There are $($outside.Count) uncommitted change(s) outside .umbraco-upgrade/. Stop and ask the user. Never stash, reset, checkout, clean, or discard them." })
        }
        $op = Get-GitOperationInProgress -Root $root
        $out.operationInProgress = $op
        if ($op) { [void]$problems.Add([ordered]@{ code = 'operation-in-progress'; message = "A git $op is in progress. Ask the user to finish or abort it." }) }
        if ($repo.detached) { [void]$problems.Add([ordered]@{ code = 'detached-head'; message = 'HEAD is detached. Ask the user which branch the upgrade should start from.' }) }
        if (-not $repo.head) { [void]$problems.Add([ordered]@{ code = 'no-commits'; message = 'The repository has no commits yet.' }) }
        $rem = Invoke-GitCommand -Root $root -Arguments @('remote', '-v')
        $remotes = @{}
        foreach ($line in $rem.stdout) {
            if ($line -match '^(\S+)\s+(\S+)\s+\((fetch|push)\)$') { $remotes[$Matches[1]] = (Remove-UrlCredentials $Matches[2]) }
        }
        $out.remotes = @($remotes.Keys | Sort-Object | ForEach-Object { [ordered]@{ name = $_; url = $remotes[$_] } })
        $st = Invoke-GitCommand -Root $root -Arguments @('stash', 'list')
        $out.stashCount = @($st.stdout).Count
    }
    $out.problems = @($problems)
    $out.ok = ($problems.Count -eq 0)
    Write-JsonOutput $out
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
