<#
.SYNOPSIS
  Compares an upgrade's plan with what changed in the project since the base commit, for /umbraco-upgrade:feedback.

.DESCRIPTION
  Read-only on the project. Compares the base commit recorded in state with the files as they are now (tracked
  changes with renames, and untracked files) and sorts each changed file:
    planned            a discovery hit of a pattern that a phase covers
    found-not-planned  a discovery hit of a pattern that no phase covers
    expected           project, solution, package, startup, and configuration files, or baseline signals
    flagged            unclassified CMS usage that discovery listed for the user
    added              a new file that no discovery hit explains
    not-found          a changed or deleted file that discovery did not report: a candidate miss
    generated          serialized content model, application data, generated models, build output (counted only)
  It also reports planned patterns none of whose files changed, the package references now against the gate 4
  package check, the phases, and the unresolved items. Every result is a candidate for the user to confirm.
  Writes the full result to .umbraco-upgrade/evidence/feedback/comparison.json (redacted) and prints a summary.
  With -ShowDiff <file>, prints the redacted diff of that one file instead and writes nothing.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '', [string]$ShowDiff = '', [int]$MaxDiffLines = 300)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Feedback.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not (Test-StateExists $root)) { throw "No upgrade state in '$root' (looked for .umbraco-upgrade/state.json)." }
    if ($ShowDiff) {
        $d = Get-ChangedFileDiff -Root $root -Path $ShowDiff -MaxLines $MaxDiffLines
        $d.Insert(0, 'ok', $true)
        Write-JsonOutput $d
        exit 0
    }
    $r = Get-UpgradeComparison -Root $root
    $outFile = Join-Path (Get-StateDir $root) 'evidence/feedback/comparison.json'
    Write-TextFile -Path $outFile -Content (Protect-Text (ConvertTo-JsonText -InputObject $r))
    $flagged = @($r.packages.items | Where-Object { $_['flag'] } | ForEach-Object { [ordered]@{ id = $_['id']; class = $_['class']; outcome = $_['outcome']; flag = $_['flag']; private = $_['private'] } })
    $summary = [ordered]@{
        ok = $true
        outFile = $outFile
        base = $r.base
        comparedWith = $r.comparedWith
        source = $r.source
        target = $r.target
        detectedNow = $r.detectedNow
        plugin = $r.plugin
        counts = $r.counts
        notFoundGroups = @($r.notFoundGroups | Select-Object -First 15 | ForEach-Object { [ordered]@{ group = $_['group']; count = $_['count']; files = @($_['files'] | Select-Object -First 3) } })
        notFoundGroupsTotal = @($r.notFoundGroups).Count
        plannedUnchanged = @($r.patterns.plannedUnchanged | ForEach-Object { [ordered]@{ pattern = $_['pattern']; phases = $_['phases']; hitFiles = $_['hitFiles'] } })
        foundNotPlannedChanged = @($r.patterns.foundNotPlanned | Where-Object { $_['changedFiles'] -gt 0 })
        packagesCompared = $r.packages.available
        packageFlags = $flagged
        packagesAdded = @($r.packages.added).Count
        phasesWithFailures = @($r.phases | Where-Object { @($_['failures']).Count -gt 0 } | ForEach-Object { [ordered]@{ id = $_['id']; title = $_['title']; status = $_['status']; failures = @($_['failures']).Count } })
        phasesNotDone = @($r.phases | Where-Object { $_['status'] -ne 'done' } | ForEach-Object { [ordered]@{ id = $_['id']; title = $_['title']; status = $_['status'] } })
        openUnresolved = @($r.unresolved | Where-Object { $_['status'] -in @('awaiting-user', 'decided') })
        warnings = $r.warnings
    }
    Write-JsonOutput (Protect-Object -InputObject $summary)
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
