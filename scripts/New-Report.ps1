<#
.SYNOPSIS
  Writes .umbraco-upgrade/report.md from state, the evidence folder, and decisions.md.

.DESCRIPTION
  Follows skills/upgrade-planning/templates/report.md: summary, phases, what was verified automatically, what the
  user verified manually, what was not verified (failed, not verified, open, waived, or deferred, each with the
  reason, the risk, and a next step), decisions with their sources, unresolved items, deviations from the plan,
  manual follow-ups, rollback, and an evidence index. Evidence is linked, never copied, and the text is redacted
  before it is written. Runs at any point (a plan-only run, an upgrade in progress, a finished one) and replaces an
  earlier report.md. Changes nothing else: state is only read. Prints JSON.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Report.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not (Test-StateExists $root)) { throw 'No upgrade state in this project.' }
    $r = New-UpgradeReport -ProjectRoot $root
    $path = Join-Path (Get-StateDir $root) 'report.md'
    Write-AtomicTextFile -Path $path -Content $r.text
    $missing = @([regex]::Matches($r.text, '\(missing\)')).Count
    Write-JsonOutput ([ordered]@{ ok = $true; path = $path; status = $r.status; counts = $r.counts; redacted = $r.redacted; missingEvidence = $missing
        note = $(if ($missing) { "$missing evidence path(s) in state point to files that do not exist; /umbraco-upgrade:resume reports them." } else { $null }) })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
