<#
.SYNOPSIS
  Proposes the plan phases from discovery and the selected path (design section 7.2).

.DESCRIPTION
  Read-only on the project. In a project with upgrade state it reads:
    - state: source major, resolved target, target framework, selected strategy
    - .umbraco-upgrade/evidence/discovery/patterns.json (detector results)
    - .umbraco-upgrade/evidence/version-path/path-selection.json (the candidate of the selected strategy)
    - .umbraco-upgrade/evidence/planning/package-compatibility.json (optional, from Test-PackageCompatibility.ps1)
  and writes the full proposal to evidence/planning/phase-composition.json and the phase list that
  state.ps1 phases accepts to tmp/phases.json. For tests, every input can be given as a file instead.
  The split thresholds and ordering rules are plugin heuristics in knowledge/planning/phase-rules.json.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$PatternsFile = '',
    [string]$PathSelectionFile = '',
    [string]$PackagesFile = '',
    [int]$SourceMajor = 0,
    [int]$TargetMajor = 0,
    [string]$Strategy = '',
    [string]$TargetFramework = '',
    [string]$OutFile = '',
    [string]$StateFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Planning.psm1') -DisableNameChecking

function Select-Candidate {
    param($Selection, [string]$Strategy)
    $cands = @($Selection.candidates)
    if ($Strategy) { $c = @($cands | Where-Object { $_.strategy -eq $Strategy }); if ($c.Count -gt 0) { return $c[0] } }
    $c = @($cands | Where-Object { $_.id -eq $Selection.recommended })
    if ($c.Count -gt 0) { return $c[0] }
    throw 'The path selection has no candidate for the selected strategy.'
}

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $stateDir = Get-StateDir $root
    $hasState = Test-StateExists $root
    if ($hasState) {
        $state = Read-UpgradeState $root
        if ($SourceMajor -le 0 -and $null -ne $state['source']['major']) { $SourceMajor = [int]$state['source']['major'] }
        if ($TargetMajor -le 0 -and $state['target']['resolved']) { $TargetMajor = Get-VersionMajor ([string]$state['target']['resolved']) }
        if (-not $Strategy -and $state['path']['strategy'] -ne 'pending') { $Strategy = [string]$state['path']['strategy'] }
        if (-not $TargetFramework -and $state['target']['dotnet']) { $TargetFramework = [string]$state['target']['dotnet'] }
        if (-not $PatternsFile) { $PatternsFile = Join-Path $stateDir 'evidence/discovery/patterns.json' }
        if (-not $PathSelectionFile) { $PathSelectionFile = Join-Path $stateDir 'evidence/version-path/path-selection.json' }
        if (-not $PackagesFile) { $p = Join-Path $stateDir 'evidence/planning/package-compatibility.json'; if ([System.IO.File]::Exists($p)) { $PackagesFile = $p } }
        if (-not $OutFile) { $OutFile = Join-Path $stateDir 'evidence/planning/phase-composition.json' }
        if (-not $StateFile) { $StateFile = Join-Path $stateDir 'tmp/phases.json' }
    }
    if (-not $PatternsFile -or -not [System.IO.File]::Exists($PatternsFile)) { throw 'Discovery results not found. Run gate 1 first, or give -PatternsFile.' }
    if (-not $PathSelectionFile -or -not [System.IO.File]::Exists($PathSelectionFile)) { throw 'Path selection not found. Run gate 2 first, or give -PathSelectionFile.' }
    if ($SourceMajor -le 0 -or $TargetMajor -le 0) { throw 'Source and target majors are unknown. Pass gate 2 first, or give -SourceMajor and -TargetMajor.' }
    $patterns = Read-JsonFile $PatternsFile
    $selection = Read-JsonFile $PathSelectionFile
    $cand = Select-Candidate -Selection $selection -Strategy $Strategy
    if (-not $Strategy) { $Strategy = [string]$cand.strategy }
    $packages = $null; if ($PackagesFile) { $packages = Read-JsonFile $PackagesFile }
    $comp = Get-PhaseComposition -PatternResult $patterns -Steps @($cand.steps) -SourceMajor $SourceMajor -TargetMajor $TargetMajor -Strategy $Strategy -PackageResult $packages -TargetFramework $TargetFramework
    $comp = Protect-Object -InputObject (ConvertTo-PlainObject $comp)
    if ($OutFile) { Write-TextFile -Path $OutFile -Content (Protect-Text (ConvertTo-JsonText -InputObject $comp)); $comp['outFile'] = $OutFile }
    if ($StateFile) { Write-TextFile -Path $StateFile -Content (ConvertTo-JsonText -InputObject @(ConvertTo-StatePhases $comp)); $comp['stateFile'] = $StateFile }
    Write-JsonOutput $comp
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
