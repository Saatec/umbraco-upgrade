<#
.SYNOPSIS
  Package metadata from the NuGet v3 API: versions per major, target frameworks, dependency ranges,
  and (with -Registration) publication date, deprecation, and known vulnerabilities.

.DESCRIPTION
  Read-only network access to api.nuget.org; responses are cached in <DataDir>/doc-cache.
  Version selection: -Version (exact), or -Major [-Minor] (latest stable match), or the latest stable release.
  Prints one JSON object. Exit code 0 when the query ran (also when the package does not exist), 1 on errors.

.EXAMPLE
  Get-NuGetPackageInfo.ps1 -PackageId Umbraco.Cms -Major 17 -DataDir <plugin data>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageId,
    [string]$Version = '',
    [int]$Major = -1,
    [int]$Minor = -1,
    [switch]$IncludePrerelease,
    [switch]$Registration,
    [switch]$NoNuspec,
    [switch]$AllVersions,
    [string]$DataDir = '',
    [switch]$Refresh
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Http.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/NuGet.psm1') -DisableNameChecking

try {
    if ($PackageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._\-]*$') { throw "Invalid package id '$PackageId'." }
    $dd = Resolve-PluginDataDir -DataDir $DataDir
    $src = (Get-KnowledgeFile -Kind sources -DataDir $dd).data
    Set-NuGetEndpoints -FlatContainer $src['nuget']['flatContainer'] -Registration $src['nuget']['registration']
    $list = Get-NuGetVersionList -PackageId $PackageId -DataDir $dd -Refresh:$Refresh
    $out = [ordered]@{
        ok = ($list.status -eq 'ok'); packageId = $PackageId; found = $list.found; source = $list.url; sourceType = 'package-metadata'
        fetchedAt = $list.fetchedAt; fromCache = $list.fromCache; stale = $list.stale; cacheDir = $null; error = $list.error
    }
    if ($dd) { $out.cacheDir = Join-Path $dd 'doc-cache' }
    if ($list.status -ne 'ok') { $out.status = $list.status; Write-JsonOutput $out; exit 1 }
    if (-not $list.found) { $out.message = "Package '$PackageId' does not exist on NuGet."; Write-JsonOutput $out; exit 0 }
    $versions = @($list.versions)
    $out.versionCount = $versions.Count
    $out.latestStable = Select-LatestVersion -Versions $versions
    $out.latestPrerelease = Select-LatestVersion -Versions $versions -IncludePrerelease
    $out.majors = @(Get-MajorSummary -Versions $versions)
    if ($AllVersions) { $out.versions = $versions }
    $chosen = $null; $how = $null
    if ($Version) {
        $hit = @($versions | Where-Object { $_ -ieq $Version })
        if ($hit.Count -gt 0) { $chosen = [string]$hit[0]; $how = 'exact' } else { $out.message = "Version $Version of '$PackageId' is not published." }
    } elseif ($Major -ge 0) {
        $chosen = Select-LatestVersion -Versions $versions -Major $Major -Minor $Minor -IncludePrerelease:$IncludePrerelease
        $how = 'latest matching'
        if (-not $chosen) { $out.message = "No release of '$PackageId' matches $Major$(if ($Minor -ge 0) { ".$Minor" })." }
    } else {
        $chosen = Select-LatestVersion -Versions $versions -IncludePrerelease:$IncludePrerelease
        $how = 'latest'
    }
    $out.resolved = [ordered]@{ version = $chosen; how = $how }
    if ($chosen -and -not $NoNuspec) {
        $ns = Get-NuGetNuspec -PackageId $PackageId -Version $chosen -DataDir $dd -Refresh:$Refresh
        $out.nuspec = [ordered]@{ source = $ns.url; status = $ns.status; fetchedAt = $ns.fetchedAt; data = $ns.nuspec; error = $ns.error }
    }
    if ($chosen -and $Registration) {
        $reg = Get-NuGetRegistrationEntry -PackageId $PackageId -Version $chosen -DataDir $dd -Refresh:$Refresh
        $out.registration = $reg
    }
    Write-JsonOutput $out
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; packageId = $PackageId; error = $_.Exception.Message })
    exit 1
}
