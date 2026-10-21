<#
.SYNOPSIS
  Reads the version knowledge through the lookup order and prints it as JSON.

.DESCRIPTION
  Read-only. For each file (versions, paths, packages, sources): the refreshed copy in
  <DataDir>/knowledge/ is used when it parses, its schema major version matches, it validates, and its
  verifiedAt is newer than the baseline shipped in the plugin; otherwise the baseline is used. The output
  says which copy was used for each file and why.

  -Kind <name>   print that whole file
  -Major <n>     print one major's entry from versions.json (with every fact and its source)
  default        a summary: origin per file and one row per major
#>
[CmdletBinding()]
param(
    [string]$DataDir = '',
    [ValidateSet('versions', 'paths', 'packages', 'sources')][string]$Kind = '',
    [int]$Major = -1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Http.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking

try {
    $dd = Resolve-PluginDataDir -DataDir $DataDir
    $k = Get-Knowledge -DataDir $dd
    $out = [ordered]@{ ok = $true; dataDir = $dd; files = [ordered]@{} }
    foreach ($name in $k.Keys) {
        $f = $k[$name]
        $out.files[$name] = [ordered]@{ origin = $f.origin; path = $f.path; schemaVersion = $f.schemaVersion; knowledgeVersion = $f.knowledgeVersion; verifiedAt = $f.verifiedAt; baselineVerifiedAt = $f.baselineVerifiedAt; reason = $f.reason }
    }
    $versions = $k['versions'].data
    if ($Kind) {
        $out.data = $k[$Kind].data
    } elseif ($Major -ge 0) {
        $e = Get-MajorEntry -Versions $versions -Major $Major
        $out.major = $Major
        $out.known = ($null -ne $e)
        $out.data = $e
        if ($null -eq $e) {
            $known = @($versions['majors'] | ForEach-Object { [int]$_['major'] })
            $out.message = "Umbraco $Major is not in the version knowledge (known: $($known -join ', ')). Treat every fact about it as unverified; check NuGet with Get-NuGetPackageInfo.ps1 and run /umbraco-upgrade:update-knowledge."
        }
    } else {
        $rows = foreach ($m in @($versions['majors'])) {
            $min = $null; if ($m.Contains('minUpgradeFrom')) { $min = $m['minUpgradeFrom']['value'] }
            [ordered]@{
                major = $m['major']; lts = $m['lts']['value']; ltsStatus = $m['lts']['status']; dotnet = $m['dotnet']['value']
                latestKnown = $m['latestKnown']['value']; endOfLife = $m['endOfLife']['value']; endOfLifeStatus = $m['endOfLife']['status']
                docsSpace = $m['docsSpace']['value']; minUpgradeFrom = $min
            }
        }
        $out.majors = @($rows)
    }
    Write-JsonOutput $out
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
