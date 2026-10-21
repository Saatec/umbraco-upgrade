<#
.SYNOPSIS
  Builds and ranks candidate upgrade paths from the version knowledge and discovery facts.

.DESCRIPTION
  Read-only (network: NuGet and, with -VerifyLive, the documentation pages the rules cite).
  Inputs come from the project's .umbraco-upgrade/ state and discovery evidence (-ProjectRoot), or from
  -Source, -Target, -Engine, and -Patterns. The script resolves exact versions from NuGet, builds candidates
  (in place, staged, rebuild with database migration, new install with content transfer), applies the documented
  rules and the scoring heuristics, and reports which facts each choice rests on and their status.
  The version-path skill makes and records the final choice.

  status: selected | needs-decision (close candidates or decisions on the recommended path) | future-unverified
  (target major not in the knowledge but published on NuGet) | unknown-target | no-valid-path | error.
  Exit code 0 for selected, needs-decision, and future-unverified; 1 otherwise.

  -UserLts, -UserDotnet, -UserMinFrom, -UserSource record facts the user confirmed from an official page.
  -VerifyLive re-checks every cited fact against its source page (evidence phrase) through the cache.
  -OutFile writes the result to a file inside a .umbraco-upgrade folder or the plugin data directory.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$Source = '',
    [string]$Target = '',
    [ValidateSet('', 'unknown', 'sqlserver', 'localdb', 'sqlce', 'sqlite', 'other')][string]$Engine = '',
    [string[]]$Patterns = @(),
    [string]$DataDir = '',
    [switch]$Offline,
    [ValidateSet('', 'true', 'false')][string]$UserLts = '',
    [string]$UserDotnet = '',
    [string]$UserMinFrom = '',
    [string]$UserSource = '',
    [switch]$VerifyLive,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Http.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/NuGet.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Docs.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/PathSelection.psm1') -DisableNameChecking

try {
    $dd = Resolve-PluginDataDir -DataDir $DataDir
    $k = Get-Knowledge -DataDir $dd
    $sources = $k['sources'].data
    Set-NuGetEndpoints -FlatContainer $sources['nuget']['flatContainer'] -Registration $sources['nuget']['registration']
    $inputs = [ordered]@{ from = 'parameters' }

    # Inputs from the project state and discovery evidence.
    if ($ProjectRoot) {
        $root = Resolve-FullPath $ProjectRoot
        $statePath = Join-Path $root '.umbraco-upgrade/state.json'
        if (-not [System.IO.File]::Exists($statePath)) { throw "No upgrade state at $statePath. Run discovery first." }
        $state = ConvertTo-PlainObject (Read-JsonFile $statePath)
        if (-not $Source -and $state['source']['umbraco']) { $Source = [string]$state['source']['umbraco'] }
        if (-not $Target) { $Target = [string]$state['target']['requested'] }
        if (-not $Engine -and $state['source'].Contains('database') -and $state['source']['database'].Contains('engine')) { $Engine = [string]$state['source']['database']['engine'] }
        $patFile = Join-Path $root '.umbraco-upgrade/evidence/discovery/patterns.json'
        if (@($Patterns).Count -eq 0 -and [System.IO.File]::Exists($patFile)) {
            $pf = Read-JsonFile $patFile
            $Patterns = @($pf.patterns | ForEach-Object { [string]$_.pattern })
        }
        $inputs = [ordered]@{ from = 'project state and discovery evidence'; projectRoot = $root }
    }
    $Patterns = @($Patterns | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $Engine) { $Engine = 'unknown' }
    if (-not $Source) { throw 'No source version: pass -Source, or -ProjectRoot after discovery recorded one (ask the user when signals conflict).' }
    if (-not $Target) { throw 'No target: pass -Target.' }
    $inputs.source = $Source; $inputs.target = $Target; $inputs.engine = $Engine; $inputs.patterns = @($Patterns)

    # NuGet version lists for the core packages.
    $pkgVersions = @{}; $pkgSources = @{}; $nugetNotes = New-Object System.Collections.ArrayList
    if (-not $Offline) {
        foreach ($cp in @($k['packages'].data['corePackages'])) {
            $l = Get-NuGetVersionList -PackageId ([string]$cp['id']) -DataDir $dd
            if ($l.status -eq 'ok' -and $l.found) {
                $pkgVersions[[string]$cp['id']] = @($l.versions)
                $pkgSources[[string]$cp['id']] = @{ url = $l.url; fetchedAt = $l.fetchedAt; stale = $l.stale }
            } else { [void]$nugetNotes.Add("NuGet lookup for $($cp['id']) failed ($($l.status)); versions fall back to the knowledge.") }
        }
    } else { [void]$nugetNotes.Add('Offline: exact versions come from the knowledge (latestKnown) and are not checked against NuGet.') }

    # Target nuspec, only when the target major is not in the knowledge (its framework is otherwise unknown).
    $nuspec = $null; $nuspecUrl = ''
    if ($Target -match '^\d+') {
        $tMajor = [int]($Target -split '\.')[0]
        $tPkg = Get-CorePackageId -Packages $k['packages'].data -Major $tMajor
        if ($null -eq (Get-MajorEntry -Versions $k['versions'].data -Major $tMajor) -and $tPkg -and $pkgVersions.ContainsKey($tPkg)) {
            $parts = @($Target -split '\.')
            $v = $null
            if ($parts.Count -eq 3) { $v = @($pkgVersions[$tPkg] | Where-Object { $_ -ieq $Target }) | Select-Object -First 1 }
            elseif ($parts.Count -eq 2) { $v = Select-LatestVersion -Versions $pkgVersions[$tPkg] -Major $tMajor -Minor ([int]$parts[1]) }
            else { $v = Select-LatestVersion -Versions $pkgVersions[$tPkg] -Major $tMajor }
            if ($v) {
                $ns = Get-NuGetNuspec -PackageId $tPkg -Version $v -DataDir $dd
                if ($ns.status -eq 'ok') { $nuspec = $ns.nuspec; $nuspecUrl = $ns.url }
            }
        }
    }

    $userFacts = @{}
    if ($UserLts) { $userFacts['lts'] = ($UserLts -eq 'true') }
    if ($UserDotnet) { $userFacts['dotnet'] = $UserDotnet }
    if ($UserMinFrom) {
        if ($UserMinFrom -notmatch '^\d+\.\d+(\.\d+)?$') { throw "-UserMinFrom must be a version such as 17.0.0." }
        $userFacts['minUpgradeFrom'] = $UserMinFrom
    }
    if ($userFacts.Count -gt 0) {
        if ($UserSource -notmatch '^https://') { throw 'User-confirmed facts need -UserSource with the https URL of the official page the user checked.' }
        $userFacts['source'] = $UserSource
    }

    $knowledge = @{ versions = $k['versions'].data; paths = $k['paths'].data; packages = $k['packages'].data }
    $r = Select-UpgradePathCore -Knowledge $knowledge -Source $Source -Target $Target -Engine $Engine -Patterns $Patterns `
        -PackageVersions $pkgVersions -PackageSources $pkgSources -TargetNuspec $nuspec -TargetNuspecUrl $nuspecUrl -UserFacts $userFacts
    $r.Insert(2, 'inputs', $inputs)
    $origins = [ordered]@{}
    foreach ($name in $k.Keys) { $origins[$name] = [ordered]@{ origin = $k[$name].origin; verifiedAt = $k[$name].verifiedAt; knowledgeVersion = $k[$name].knowledgeVersion; reason = $k[$name].reason } }
    $r['knowledge'] = $origins
    $r['nuget'] = [ordered]@{ checked = (-not $Offline); packages = $pkgSources; notes = @($nugetNotes) }

    if ($VerifyLive -and @($r.factsUsed).Count -gt 0) {
        $counts = [ordered]@{ confirmed = 0; missing = 0; unreachable = 0; 'not-checkable' = 0 }
        foreach ($f in @($r.factsUsed)) {
            $res = Test-FactEvidence -Fact $f -Sources $sources -DataDir $dd
            $f['live'] = $res.result
            $counts[$res.result] = [int]$counts[$res.result] + 1
            if ($res.result -eq 'missing') {
                $f['status'] = 'needs-review'
                $r.messages = @($r.messages) + "Fact $($f.id) could not be re-confirmed: $($res.detail) ($($f.source)). Treat it as unverified and check the page."
            }
        }
        $r.unverifiedFacts = @($r.factsUsed | Where-Object { $_['status'] -ne 'verified' })
        $r['liveCheck'] = [ordered]@{ checkedAt = (Get-UtcTimestamp); counts = $counts }
    }

    if ($OutFile) {
        $full = Resolve-FullPath $OutFile
        $okLocation = ($full -match '[\\/]\.umbraco-upgrade[\\/]') -or ($dd -and (Test-PathUnder -Root $dd -Path $full))
        if (-not $okLocation) { throw '-OutFile must be inside a .umbraco-upgrade folder or the plugin data directory.' }
        Write-TextFile -Path $full -Content (ConvertTo-JsonText -InputObject $r)
        $r['outFile'] = $full
    }
    Write-JsonOutput $r
    if ($r.ok) { exit 0 } else { exit 1 }
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; status = 'error'; error = $_.Exception.Message })
    exit 1
}
