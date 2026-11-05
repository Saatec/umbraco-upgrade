<#
.SYNOPSIS
  Resume reconciliation: compares .umbraco-upgrade/state.json with the repository, the project files, and the
  recorded evidence, and reports every difference.

.DESCRIPTION
  Read-only. It never changes state, files, refs, or the index, and it never connects to a database.
  Checks: the state file against its schema; the branch, HEAD, base commit, and every checkpoint commit; uncommitted
  changes outside .umbraco-upgrade/; a git operation in progress; plan.md against the approved hash; every file
  the state refers to (gate documents, evidence, decisions); the CMS version in the project files against what
  state implies after the done phases; whether the declared local database copy is still what the local
  configuration points to (without connecting, without printing the connection string).
  Prints one JSON object: position (where the workflow stands), consistent, mismatches, warnings, and checks, each
  with expected, actual, detail, and options for the user. Exit code 0 when the checks ran (consistent or not),
  1 when they could not run.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Reconcile.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $r = Test-StateReality -ProjectRoot $root
    Write-JsonOutput (Protect-Object -InputObject (ConvertTo-PlainObject $r))
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
