# NuGet.psm1 - read-only NuGet v3 queries (flat container, nuspec, registration), cached in the plugin data directory.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Http.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Knowledge.psm1') -DisableNameChecking

$script:FlatContainer = 'https://api.nuget.org/v3-flatcontainer/'
$script:Registration = 'https://api.nuget.org/v3/registration5-gz-semver2/'

function Set-NuGetEndpoints {
    # Endpoints come from knowledge/sources.json when the caller has it.
    param([string]$FlatContainer, [string]$Registration)
    if ($FlatContainer) { $script:FlatContainer = $FlatContainer.TrimEnd('/') + '/' }
    if ($Registration) { $script:Registration = $Registration.TrimEnd('/') + '/' }
}

function Get-NuGetIndexUrl { param([Parameter(Mandatory)][string]$PackageId) return ($script:FlatContainer + $PackageId.ToLowerInvariant() + '/index.json') }
function Get-NuGetNuspecUrl {
    param([Parameter(Mandatory)][string]$PackageId, [Parameter(Mandatory)][string]$Version)
    $id = $PackageId.ToLowerInvariant(); $v = $Version.ToLowerInvariant()
    return ($script:FlatContainer + "$id/$v/$id.nuspec")
}

function Get-NuGetVersionList {
    # All published versions of a package. found = false when NuGet answers 404.
    param([Parameter(Mandatory)][string]$PackageId, [string]$DataDir = '', [double]$MaxAgeDays = 1, [switch]$Refresh)
    $url = Get-NuGetIndexUrl $PackageId
    $r = Invoke-CachedGet -Url $url -DataDir $DataDir -MaxAgeDays $MaxAgeDays -Refresh:$Refresh -Label ([ordered]@{ sourceType = 'package-metadata'; packageId = $PackageId })
    $out = [ordered]@{ packageId = $PackageId; url = $url; status = $r.status; found = $false; versions = @(); fromCache = $r.fromCache; stale = $r.stale; fetchedAt = $null; error = $r.error }
    if ($r.status -eq 'http-404') { $out.status = 'ok'; return $out }
    if ($r.status -ne 'ok') { return $out }
    $out.fetchedAt = $r.meta['fetchedAt']
    $json = ConvertFrom-JsonText ([string]$r.body)
    $out.found = $true
    $out.versions = @($json.versions | ForEach-Object { [string]$_ })
    return $out
}

function Select-LatestVersion {
    # Latest version matching a major (and optionally a minor). Stable only unless -IncludePrerelease.
    param([string[]]$Versions = @(), [int]$Major = -1, [int]$Minor = -1, [switch]$IncludePrerelease)
    $best = $null
    foreach ($v in $Versions) {
        if (-not $IncludePrerelease -and $v.Contains('-')) { continue }
        try { $p = ConvertTo-VersionParts $v } catch { continue }
        if ($Major -ge 0 -and $p[0] -ne $Major) { continue }
        if ($Minor -ge 0 -and $p[1] -ne $Minor) { continue }
        if ($null -eq $best -or (Compare-Version $v $best) -gt 0) { $best = $v }
    }
    return $best
}

function Get-MajorSummary {
    # One row per major: latest stable version, number of stable versions, and whether only prereleases exist.
    param([string[]]$Versions = @())
    $rows = [ordered]@{}
    foreach ($v in $Versions) {
        try { $maj = (ConvertTo-VersionParts $v)[0] } catch { continue }
        $key = [string]$maj
        if (-not $rows.Contains($key)) { $rows[$key] = [ordered]@{ major = $maj; latest = $null; stableCount = 0; latestPrerelease = $null } }
        if ($v.Contains('-')) {
            if ($null -eq $rows[$key].latestPrerelease -or (Compare-Version $v $rows[$key].latestPrerelease) -gt 0) { $rows[$key].latestPrerelease = $v }
        } else {
            $rows[$key].stableCount++
            if ($null -eq $rows[$key].latest -or (Compare-Version $v $rows[$key].latest) -gt 0) { $rows[$key].latest = $v }
        }
    }
    return @($rows.Values | Sort-Object { $_.major })
}

function ConvertFrom-Nuspec {
    param([Parameter(Mandatory)][string]$Xml)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($Xml)), $settings)
    try { $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null; $doc.Load($reader) } finally { $reader.Close() }
    $md = $null
    foreach ($n in $doc.DocumentElement.ChildNodes) { if ($n.LocalName -eq 'metadata') { $md = $n } }
    if ($null -eq $md) { throw 'nuspec has no metadata element' }
    $get = { param($name) foreach ($c in $md.ChildNodes) { if ($c.LocalName -eq $name) { return $c.InnerText.Trim() } }; return $null }
    $repo = $null
    foreach ($c in $md.ChildNodes) { if ($c.LocalName -eq 'repository') { $repo = $c.GetAttribute('url') } }
    $tfms = New-Object System.Collections.ArrayList
    $deps = New-Object System.Collections.ArrayList
    foreach ($c in $md.ChildNodes) {
        if ($c.LocalName -ne 'dependencies') { continue }
        foreach ($g in $c.ChildNodes) {
            if ($g.LocalName -eq 'group') {
                $tfm = $g.GetAttribute('targetFramework')
                if ($tfm -and -not $tfms.Contains($tfm)) { [void]$tfms.Add($tfm) }
                foreach ($d in $g.ChildNodes) { if ($d.LocalName -eq 'dependency') { [void]$deps.Add([ordered]@{ targetFramework = $tfm; id = $d.GetAttribute('id'); range = $d.GetAttribute('version') }) } }
            } elseif ($g.LocalName -eq 'dependency') {
                [void]$deps.Add([ordered]@{ targetFramework = $null; id = $g.GetAttribute('id'); range = $g.GetAttribute('version') })
            }
        }
    }
    $desc = & $get 'description'
    if ($desc -and $desc.Length -gt 400) { $desc = $desc.Substring(0, 400) + '...' }
    return [ordered]@{
        id = (& $get 'id'); version = (& $get 'version'); authors = (& $get 'authors'); projectUrl = (& $get 'projectUrl')
        repository = $repo; description = $desc; targetFrameworks = @($tfms); dependencies = @($deps)
    }
}

function Get-NuGetNuspec {
    param([Parameter(Mandatory)][string]$PackageId, [Parameter(Mandatory)][string]$Version, [string]$DataDir = '', [switch]$Refresh)
    $url = Get-NuGetNuspecUrl -PackageId $PackageId -Version $Version
    # A published nuspec never changes, so the cache is kept for a year.
    $r = Invoke-CachedGet -Url $url -DataDir $DataDir -MaxAgeDays 365 -Refresh:$Refresh -Label ([ordered]@{ sourceType = 'package-metadata'; packageId = $PackageId; version = $Version })
    $out = [ordered]@{ url = $url; status = $r.status; fromCache = $r.fromCache; fetchedAt = $null; nuspec = $null; error = $r.error }
    if ($r.status -ne 'ok') { return $out }
    $out.fetchedAt = $r.meta['fetchedAt']
    try { $out.nuspec = ConvertFrom-Nuspec ([string]$r.body) } catch { $out.status = 'parse-error'; $out.error = $_.Exception.Message }
    return $out
}

function Get-NuGetRegistrationEntry {
    # Published date, listing, deprecation, and vulnerabilities for one version, from the registration index.
    param([Parameter(Mandatory)][string]$PackageId, [Parameter(Mandatory)][string]$Version, [string]$DataDir = '', [switch]$Refresh)
    $id = $PackageId.ToLowerInvariant()
    $indexUrl = $script:Registration + "$id/index.json"
    $out = [ordered]@{ url = $indexUrl; status = 'ok'; found = $false; published = $null; listed = $null; deprecation = $null; vulnerabilities = @(); error = $null }
    $r = Invoke-CachedGet -Url $indexUrl -DataDir $DataDir -MaxAgeDays 1 -Refresh:$Refresh -Label ([ordered]@{ sourceType = 'package-metadata'; packageId = $PackageId })
    if ($r.status -ne 'ok') { $out.status = $r.status; $out.error = $r.error; return $out }
    $index = ConvertFrom-JsonText ([string]$r.body)
    $entry = $null
    foreach ($page in @($index.items)) {
        if ((Compare-Version $Version ([string]$page.lower)) -lt 0 -or (Compare-Version $Version ([string]$page.upper)) -gt 0) { continue }
        $items = $null
        if ($page.PSObject.Properties['items'] -and $null -ne $page.items) { $items = @($page.items) }
        else {
            $pr = Invoke-CachedGet -Url ([string]$page.'@id') -DataDir $DataDir -MaxAgeDays 1 -Refresh:$Refresh -Label ([ordered]@{ sourceType = 'package-metadata'; packageId = $PackageId })
            if ($pr.status -ne 'ok') { $out.status = $pr.status; $out.error = $pr.error; return $out }
            $items = @((ConvertFrom-JsonText ([string]$pr.body)).items)
        }
        foreach ($it in $items) { if ([string]$it.catalogEntry.version -ieq $Version) { $entry = $it.catalogEntry; break } }
        if ($entry) { break }
    }
    if ($null -eq $entry) { return $out }
    $out.found = $true
    if ($entry.PSObject.Properties['published']) { $out.published = [string]$entry.published }
    if ($entry.PSObject.Properties['listed']) { $out.listed = [bool]$entry.listed }
    if ($entry.PSObject.Properties['deprecation'] -and $null -ne $entry.deprecation) {
        $d = $entry.deprecation
        $alt = $null
        if ($d.PSObject.Properties['alternatePackage'] -and $d.alternatePackage) { $alt = [ordered]@{ id = [string]$d.alternatePackage.id; range = [string]$d.alternatePackage.range } }
        $msg = $null; if ($d.PSObject.Properties['message']) { $msg = [string]$d.message }
        $out.deprecation = [ordered]@{ reasons = @($d.reasons | ForEach-Object { [string]$_ }); message = $msg; alternatePackage = $alt }
    }
    if ($entry.PSObject.Properties['vulnerabilities'] -and $null -ne $entry.vulnerabilities) {
        $out.vulnerabilities = @($entry.vulnerabilities | ForEach-Object { [ordered]@{ advisoryUrl = [string]$_.advisoryUrl; severity = [string]$_.severity } })
    }
    return $out
}

Export-ModuleMember -Function Set-NuGetEndpoints, Get-NuGetIndexUrl, Get-NuGetNuspecUrl, Get-NuGetVersionList, Select-LatestVersion, Get-MajorSummary, ConvertFrom-Nuspec, Get-NuGetNuspec, Get-NuGetRegistrationEntry
