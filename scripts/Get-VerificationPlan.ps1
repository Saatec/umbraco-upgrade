<#
.SYNOPSIS
  Composes the gate 5 verification checklist for the project (A8) and the manual checklist for the user.

.DESCRIPTION
  Refuses unless gate 5 is in progress. Applies the rules in knowledge/planning/verification-rules.json to what
  discovery and the package check found: every upgrade gets the build, version, package, test, integrity, database,
  content, backoffice, frontend, logs, deployment, and rollback checks; the extension, authentication, integration,
  and form checks apply when their patterns were detected. Writes:
    evidence/final/verification-plan.json   the checklist with the reasons each check applies
    evidence/final/manual-checklist.md      the manual checks as steps for the user
    tmp/verification.json                   the checklist for state.ps1 verification -JsonFile
  Prints a summary as JSON. Changes nothing outside .umbraco-upgrade/.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Execution.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Verification.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not (Test-StateExists $root)) { throw 'No upgrade state in this project.' }
    $state = Read-UpgradeState $root
    if ($state['gates']['final']['status'] -ne 'in-progress') { throw "Gate 5 is '$($state['gates']['final']['status'])'. Start it first: state.ps1 gate -Gate final -Status in-progress." }
    $checks = New-VerificationPlan -ProjectRoot $root
    $plan = [ordered]@{ composedAt = (Get-UtcTimestamp); rules = 'knowledge/planning/verification-rules.json'; checks = @($checks) }
    $ev = Write-RedactedEvidence -ProjectRoot $root -Folder 'final' -Name 'verification-plan.json' -Content (ConvertTo-JsonText -InputObject $plan)
    $md = Write-RedactedEvidence -ProjectRoot $root -Folder 'final' -Name 'manual-checklist.md' -Content (ConvertTo-ManualChecklist -State $state -Checks $checks)
    $tmp = Join-Path (Get-StateDir $root) 'tmp/verification.json'
    Write-TextFile -Path $tmp -Content (Protect-Text (ConvertTo-JsonText -InputObject @($checks)))
    Write-JsonOutput ([ordered]@{
        ok = $true
        checks = @($checks).Count
        automated = @($checks | Where-Object { $_['method'] -eq 'automated' } | ForEach-Object { "$($_['id']) $($_['rule'])" })
        manual = @($checks | Where-Object { $_['method'] -eq 'manual' } | ForEach-Object { "$($_['id']) $($_['title'])" })
        evidence = @($ev.path, $md.path)
        stateFile = $tmp
        next = "state.ps1 verification -ProjectRoot `"$root`" -JsonFile `"$tmp`""
    })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
