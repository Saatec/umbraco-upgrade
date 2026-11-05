<#
.SYNOPSIS
  Runs the automated gate 5 checks and records their results in state; with -Interim, checks an upgrade that is
  still in progress without recording anything.

.DESCRIPTION
  Gate 5 (default): refuses unless gate 5 is in progress and the checklist is recorded (state.ps1 verification).
  For each automated check of the checklist:
    build, tests      the newest gate 5 build evidence (Test-Build.ps1 -PhaseId final -Precompile [-Test])
    cms-version       the version and target frameworks in the project files against the target in state
    package-ranges    the CMS dependency ranges of each referenced package version (NuGet nuspec, cached)
    phase-criteria    every phase done with its criteria met or waived; deferred phases make it not verified
    checkpoints       branch, checkpoint commits in HEAD, no uncommitted change outside .umbraco-upgrade/
    no-removal        git diff from the base commit: deletions need a remove-custom-feature approval; no stubs
    no-secrets        redaction over the added lines and over the text files of .umbraco-upgrade/ (files only)
    unresolved        no unresolved item awaiting the user or decided but not done
  Writes evidence/final/automated-<stamp>.json and records each result that is not pending (the newest evidence
  wins; a result never goes back to pending). Manual checks are never recorded here.
  -Interim: needs an approved plan; skips build, version, and package checks; writes
  evidence/final/interim-<stamp>.json; changes nothing in state.
  Read-only on the project and the repository. Prints JSON.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '', [string]$DataDir = '', [switch]$Interim)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Execution.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Verification.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not (Test-StateExists $root)) { throw 'No upgrade state in this project.' }
    if ($DataDir -and (Test-PathUnder -Root (Get-KnowledgePluginRoot) -Path (Resolve-FullPath $DataDir))) { throw 'The data directory must not be inside the plugin root.' }
    $state = Read-UpgradeState $root
    if ($state['mode'] -ne 'upgrade') { throw 'This is a plan-only run: nothing was executed, so there is nothing to verify.' }
    if ($state['gates']['planApproval']['status'] -ne 'approved') { throw "The plan is not approved (gate 4 is '$($state['gates']['planApproval']['status'])'), so nothing was executed yet." }
    $stamp = Get-EvidenceStamp
    if ($Interim) {
        $res = Invoke-AutomatedChecks -ProjectRoot $root -State $state -DataDir $DataDir -Interim
        $rec = [ordered]@{ at = (Get-UtcTimestamp); interim = $true; results = $res }
        $ev = Write-RedactedEvidence -ProjectRoot $root -Folder 'final' -Name "interim-$stamp.json" -Content (ConvertTo-JsonText -InputObject $rec)
        Write-JsonOutput ([ordered]@{ ok = $true; interim = $true; evidence = $ev.path
            results = @($res.Keys | ForEach-Object { [ordered]@{ rule = $_; result = $res[$_].result; note = $res[$_].note } })
            note = 'Interim check of an upgrade in progress: nothing was recorded in state. Gate 5 starts when every phase is done or deferred.' })
        exit 0
    }
    if ($state['gates']['final']['status'] -ne 'in-progress') { throw "Gate 5 is '$($state['gates']['final']['status'])'. Start it first: state.ps1 gate -Gate final -Status in-progress." }
    if (-not $state.Contains('verification')) { throw 'No verification checklist is recorded. Run Get-VerificationPlan.ps1, then state.ps1 verification.' }
    $res = Invoke-AutomatedChecks -ProjectRoot $root -State $state -DataDir $DataDir
    $rec = [ordered]@{ at = (Get-UtcTimestamp); results = $res }
    $ev = Write-RedactedEvidence -ProjectRoot $root -Folder 'final' -Name "automated-$stamp.json" -Content (ConvertTo-JsonText -InputObject $rec)
    $rules = @{}
    foreach ($r in @((Get-VerificationRules)['checks'])) { $rules[[string]$r['rule']] = $r }
    $recorded = New-Object System.Collections.ArrayList
    $pending = New-Object System.Collections.ArrayList
    foreach ($c in @($state['verification']['checks'] | Where-Object { $_['method'] -eq 'automated' })) {
        $rule = [string]$c['rule']
        if (-not $res.Contains($rule)) { [void]$pending.Add([ordered]@{ id = $c['id']; rule = $rule; note = 'No automated implementation for this rule.' }); continue }
        $r = $res[$rule]
        if ($r.result -eq 'pending') { [void]$pending.Add([ordered]@{ id = $c['id']; rule = $rule; note = $r.note }); continue }
        $evidence = @($ev.path) + @($r.extraEvidence | Where-Object { $_ })
        $recovery = $(if ($r.result -eq 'failed') { [string]$rules[$rule]['nextStep'] } else { '' })
        [void](Set-VerificationResult -ProjectRoot $root -CheckId $c['id'] -Result $r.result -Evidence $evidence -Note (Protect-Text ([string]$r.note)) -Recovery $recovery -ByScript)
        [void]$recorded.Add([ordered]@{ id = $c['id']; rule = $rule; result = $r.result; note = (Protect-Text ([string]$r.note)) })
    }
    $after = Read-UpgradeState $root
    Write-JsonOutput ([ordered]@{
        ok = $true; evidence = $ev.path
        recorded = @($recorded); pending = @($pending)
        summary = (Get-VerificationSummary -State $after)
        manualOpen = @(@($after['verification']['checks']) | Where-Object { $_['method'] -eq 'manual' -and $_['result'] -eq 'pending' } | ForEach-Object { $_['id'] })
    })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
