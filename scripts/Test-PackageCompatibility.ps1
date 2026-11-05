<#
.SYNOPSIS
  Classifies each direct package reference of the project for the target major from NuGet metadata.

.DESCRIPTION
  Read-only on the project; network reads go through the plugin cache (-DataDir). Classes: core, cms-dependency,
  platform, renamed (the package knowledge names its successor for the target), compatible (a release declares a CMS
  dependency range that includes the target major, on a dependency package that has a release of that major, directly
  or through packages of its own id family), no-target-version (also from the package knowledge's no-successor facts),
  framework-only, not-cms-specific, not-found (not on nuget.org), unreachable (metadata of a release line it needed
  could not be read, so it makes no claim). Reports the package-metadata patterns pkg.no-target-version,
  pkg.framework-only-libs, and pkg.renamed-community (renamed, or deprecated with an alternate package).
  With a state file in the project, the target and source majors come from state and the result is written to
  .umbraco-upgrade/evidence/planning/package-compatibility.json. Prints one JSON object.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [int]$TargetMajor = 0,
    [int]$SourceMajor = 0,
    [string]$DataDir = '',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/NuGet.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Planning.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Path '$root' is not a directory." }
    if ($DataDir -and (Test-PathUnder -Root (Get-KnowledgePluginRoot) -Path (Resolve-FullPath $DataDir))) { throw 'The data directory must not be inside the plugin root.' }
    $src = (Get-KnowledgeFile -Kind sources -DataDir $DataDir).data
    Set-NuGetEndpoints -FlatContainer $src['nuget']['flatContainer'] -Registration $src['nuget']['registration']
    $hasState = Test-StateExists $root
    if ($hasState) {
        $state = Read-UpgradeState $root
        if ($TargetMajor -le 0 -and $state['target']['resolved']) { $TargetMajor = Get-VersionMajor ([string]$state['target']['resolved']) }
        if ($TargetMajor -le 0 -and $state['target']['requested']) { $TargetMajor = Get-VersionMajor ([string]$state['target']['requested']) }
        if ($SourceMajor -le 0 -and $null -ne $state['source']['major']) { $SourceMajor = [int]$state['source']['major'] }
    }
    if ($TargetMajor -le 0) { throw 'Give -TargetMajor, or run in a project with upgrade state.' }
    $r = Get-PackageCompatibility -Root $root -TargetMajor $TargetMajor -SourceMajor $SourceMajor -DataDir $DataDir
    $r = Protect-Object -InputObject (ConvertTo-PlainObject $r)
    if (-not $OutFile -and $hasState) { $OutFile = Join-Path (Get-StateDir $root) 'evidence/planning/package-compatibility.json' }
    if ($OutFile) {
        Write-TextFile -Path $OutFile -Content (Protect-Text (ConvertTo-JsonText -InputObject $r))
        $r['outFile'] = $OutFile
    }
    Write-JsonOutput $r
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
