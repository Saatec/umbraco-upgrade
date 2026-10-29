<#
.SYNOPSIS
  Prints the guidance for one or more detected patterns: impacts the upgrade crosses, handling options for the
  target generation (each cited or marked hypothesis), checks, documentation to consult, and the discovery hits.

.DESCRIPTION
  Read-only. Give -PatternId (one or more, comma-separated) or -PhaseId (all patterns of a phase in state).
  Source and target majors come from state unless given. Prints one JSON object.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string[]]$PatternId = @(),
    [string]$PhaseId = '',
    [int]$SourceMajor = 0,
    [int]$TargetMajor = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Planning.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $ids = @($PatternId | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $hits = @()
    if (Test-StateExists $root) {
        $state = Read-UpgradeState $root
        if ($SourceMajor -le 0 -and $null -ne $state['source']['major']) { $SourceMajor = [int]$state['source']['major'] }
        if ($TargetMajor -le 0 -and $state['target']['resolved']) { $TargetMajor = Get-VersionMajor ([string]$state['target']['resolved']) }
        if ($TargetMajor -le 0 -and $state['target']['requested']) { $TargetMajor = Get-VersionMajor ([string]$state['target']['requested']) }
        if ($PhaseId) {
            $ph = @($state['phases'] | Where-Object { $_['id'] -eq $PhaseId })
            if ($ph.Count -eq 0) { throw "Unknown phase '$PhaseId'." }
            $ids = @($ids + @($ph[0]['patterns'])) | Select-Object -Unique
        }
        $pf = Join-Path (Get-StateDir $root) 'evidence/discovery/patterns.json'
        if ([System.IO.File]::Exists($pf)) { $pr = Read-JsonFile $pf; $hits = @(@($pr.hits) + @($pr.baselineHits) | Where-Object { $_ }) }
    } elseif ($PhaseId) { throw 'No upgrade state in the project.' }
    if ($ids.Count -eq 0) { throw 'Give -PatternId or -PhaseId.' }
    if ($SourceMajor -le 0 -or $TargetMajor -le 0) { throw 'Source and target majors are unknown. Give -SourceMajor and -TargetMajor.' }
    $out = [ordered]@{ ok = $true; sourceMajor = $SourceMajor; targetMajor = $TargetMajor; patterns = @($ids | ForEach-Object { Get-PatternGuidance -PatternId $_ -SourceMajor $SourceMajor -TargetMajor $TargetMajor -Hits $hits }) }
    Write-JsonOutput (Protect-Object -InputObject (ConvertTo-PlainObject $out))
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
