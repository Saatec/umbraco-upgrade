<#
.SYNOPSIS
  Refreshes the version knowledge from primary sources into the plugin data directory, with a maintainer diff.

.DESCRIPTION
  Network: NuGet, the Umbraco docs site and GitHub docs branches, releases.umbraco.com, the .NET release metadata,
  the official LTS page (usually blocked), and endoflife.date (secondary). Writes only to <DataDir>/knowledge/:

    versions.json, paths.json, packages.json, sources.json   refreshed knowledge (same schema as the baseline)
    refresh-report.json, refresh-report.md                    what changed, what needs review, what failed
    maintainer.patch                                          unified diff from the shipped baseline, for git apply

  Never writes to the plugin root. What it does:
    - NuGet: latest release and target framework per major; new majors with a stable release are added with
      their framework verified and every other fact unverified
    - releases.umbraco.com: LTS labels of the current majors
    - every fact with an evidence phrase is re-checked against its source page: confirmed facts get a new
      verification date; facts whose phrase is gone become needs-review (values are never guessed)
    - end-of-support and end-of-life dates: from the secondary aggregator, always labelled secondary
    - .NET channel support dates from the official release metadata
    - docs spaces: which majors have a <n>.latest space on the docs site, and moves to the end-of-life branch
    - packages without a successor: flagged for review when a newer major appears
#>
[CmdletBinding()]
param([string]$DataDir = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Http.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/NuGet.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Docs.psm1') -DisableNameChecking

$today = Get-Today
$report = [ordered]@{
    startedAt = (Get-UtcTimestamp); dataDir = $null; fetches = New-Object System.Collections.ArrayList; valueChanges = New-Object System.Collections.ArrayList
    newMajors = New-Object System.Collections.ArrayList; upcoming = New-Object System.Collections.ArrayList; needsReview = New-Object System.Collections.ArrayList
    unreachable = New-Object System.Collections.ArrayList; reverified = [ordered]@{ confirmed = 0; missing = 0; unreachable = 0; 'not-checkable' = 0 }
    notes = New-Object System.Collections.ArrayList; errors = New-Object System.Collections.ArrayList
}
$fresh = @{}   # URLs already fetched fresh in this run

function Add-Fetch { param([string]$Url, [string]$Status) [void]$report.fetches.Add([ordered]@{ url = $Url; status = $Status }) }
function Copy-Plain { param($Value) return (ConvertTo-PlainObject (ConvertFrom-JsonText (ConvertTo-StableJson $Value))) }

function New-Fact {
    param($Value, [string]$Status, [string]$Source, [string]$SourceType, [string]$SourceVersion, [string]$AppliesTo, [string]$Evidence = '', [string]$Note = '')
    $f = [ordered]@{ value = $Value; status = $Status; source = $(if ($Source) { $Source } else { $null }); sourceType = $SourceType; sourceVersion = $SourceVersion; appliesTo = $AppliesTo
        verifiedAt = $(if ($Status -eq 'unverified') { $null } else { $today }); verifiedBy = $(if ($Status -eq 'unverified') { 'none' } else { 'update-knowledge' }) }
    if ($Evidence) { $f['evidence'] = $Evidence }
    if ($Note) { $f['note'] = $Note }
    return $f
}

function Set-FactValue {
    # Replaces a fact and records a value change when the value differs.
    param($Container, [string]$Key, $NewFact, [string]$Label)
    $old = $null
    if ($Container.Contains($Key)) { $old = $Container[$Key] }
    # An unchanged value keeps its maintainer-written note, so the maintainer diff shows only real changes.
    if ($old -and "$($old['value'])" -eq "$($NewFact['value'])" -and $old.Contains('note')) { $NewFact['note'] = $old['note'] }
    $Container[$Key] = $NewFact
    $oldValue = $null; if ($old) { $oldValue = $old['value'] }
    if ("$oldValue" -ne "$($NewFact['value'])") {
        [void]$report.valueChanges.Add([ordered]@{ fact = $Label; old = $oldValue; new = $NewFact['value']; status = $NewFact['status']; source = $NewFact['source'] })
    }
}

function Invoke-Fresh {
    # One fresh fetch per URL per run; later calls in the same run use that copy.
    param([string]$Url, [string]$Dd, [System.Collections.IDictionary]$Label = @{})
    $refresh = -not $fresh.ContainsKey($Url)
    $r = Invoke-CachedGet -Url $Url -DataDir $Dd -MaxAgeDays 1 -Refresh:$refresh -Label $Label
    $fresh[$Url] = $true
    Add-Fetch $Url $r.status
    return $r
}

try {
    $dd = Resolve-PluginDataDir -DataDir $DataDir
    if (-not $dd) { throw 'Give -DataDir (the plugin data directory, ${CLAUDE_PLUGIN_DATA}).' }
    $report.dataDir = $dd
    $pluginRoot = Get-KnowledgePluginRoot
    $outDir = Get-RefreshedKnowledgeDir $dd
    if (Test-PathUnder -Root $pluginRoot -Path $outDir) { throw 'Refusing to write knowledge inside the plugin root.' }

    $prev = Get-Knowledge -DataDir $dd
    $new = [ordered]@{}
    foreach ($kind in (Get-KnowledgeKinds)) { $new[$kind] = Copy-Plain $prev[$kind].data }
    $versions = $new['versions']; $packages = $new['packages']; $sources = $new['sources']; $paths = $new['paths']
    Set-NuGetEndpoints -FlatContainer $sources['nuget']['flatContainer'] -Registration $sources['nuget']['registration']
    $reached = 0

    # ---------------------------------------------------------------- NuGet: latest release and framework per major
    $maxKnown = (@($versions['majors'] | ForEach-Object { [int]$_['major'] }) | Measure-Object -Maximum).Maximum
    foreach ($cp in @($packages['corePackages'])) {
        $pkg = [string]$cp['id']
        $list = Get-NuGetVersionList -PackageId $pkg -DataDir $dd -Refresh
        Add-Fetch $list.url $list.status
        if ($list.status -ne 'ok' -or -not $list.found) { [void]$report.errors.Add("NuGet versions for ${pkg}: $($list.status) $($list.error)"); continue }
        $reached++
        $rows = @(Get-MajorSummary -Versions $list.versions)
        foreach ($row in $rows) {
            $m = [int]$row.major
            if ($m -lt [int]$cp['minMajor'] -or ($null -ne $cp['maxMajor'] -and $m -gt [int]$cp['maxMajor'])) { continue }
            $entry = Get-MajorEntry -Versions $versions -Major $m
            if (-not $row.latest) {
                if ($null -eq $entry -and $m -gt $maxKnown) { [void]$report.upcoming.Add([ordered]@{ major = $m; latestPrerelease = $row.latestPrerelease; note = 'Prereleases only; not added to the knowledge.' }) }
                continue
            }
            $isNew = ($null -eq $entry)
            if ($isNew) {
                if ($m -lt $maxKnown) { continue }
                $entry = [ordered]@{ major = $m; generation = $null; corePackage = $pkg }
                $reg = Get-NuGetRegistrationEntry -PackageId $pkg -Version "$m.0.0" -DataDir $dd -Refresh
                if ($reg.found -and $reg.published) {
                    $date = ([string]$reg.published).Substring(0, 10)
                    $entry['releaseDate'] = New-Fact $date 'verified' ($sources['nuget']['registration'] + $pkg.ToLowerInvariant() + "/$m.0.0.json") 'package-metadata' "$pkg $m.0.0" "$m" ('"published":"' + $date) "Publication date (UTC) of $pkg $m.0.0 on NuGet."
                } else { $entry['releaseDate'] = New-Fact $null 'unverified' $null 'none' 'n/a' "$m" '' 'Publication date not found in the registration index.' }
                $entry['lts'] = New-Fact $null 'unverified' $null 'none' 'n/a' "$m" '' 'New major: confirm the LTS status on the official page.'
                $entry['endOfSupport'] = New-Fact $null 'unverified' $null 'none' 'n/a' "$m" '' 'New major: not known yet.'
                $entry['endOfLife'] = New-Fact $null 'unverified' $null 'none' 'n/a' "$m" '' 'New major: not known yet.'
                $entry['dotnet'] = New-Fact $null 'unverified' $null 'none' 'n/a' "$m"
                $entry['latestKnown'] = New-Fact $null 'unverified' $null 'none' 'n/a' "$m"
                $entry['docsSpace'] = New-Fact $null 'unverified' $null 'none' 'n/a' "$m" '' 'New major: docs space set by the docs check below.'
                $entry['dataMigrations'] = @(); $entry['preparation'] = @()
                $versions['majors'] = @(@($versions['majors']) + $entry | Sort-Object { [int]$_['major'] })
                [void]$report.newMajors.Add([ordered]@{ major = $m; latest = $row.latest; note = 'Added from NuGet. LTS status, support dates, minimum upgrade-from version, data migrations, and path rules are unverified until a maintainer checks the official pages.' })
            }
            $latestFact = New-Fact ([string]$row.latest) 'verified' $list.url 'package-metadata' 'n/a' "$m" '' "Latest stable $m.x release on NuGet on $today. Resolve the current latest from NuGet at run time."
            Set-FactValue $entry 'latestKnown' $latestFact "versions[$m].latestKnown"
            if ($isNew -or [string]$entry['dotnet']['sourceType'] -eq 'package-metadata' -or [string]$entry['dotnet']['status'] -ne 'verified') {
                $ns = Get-NuGetNuspec -PackageId $pkg -Version ([string]$row.latest) -DataDir $dd
                Add-Fetch $ns.url $ns.status
                $fresh[$ns.url] = $true
                if ($ns.status -eq 'ok' -and @($ns.nuspec.targetFrameworks).Count -ge 1) {
                    $tfm = [string]@($ns.nuspec.targetFrameworks)[0]
                    $note = "Target framework of the latest $m release in its NuGet package metadata."
                    if ($entry['dotnet'].Contains('note') -and -not $isNew) { $note = [string]$entry['dotnet']['note'] }
                    Set-FactValue $entry 'dotnet' (New-Fact $tfm 'verified' $ns.url 'package-metadata' "$pkg $($row.latest)" "$m" ('targetFramework="' + $tfm + '"') $note) "versions[$m].dotnet"
                } else { [void]$report.unreachable.Add([ordered]@{ fact = "versions[$m].dotnet"; detail = "nuspec $($ns.status)" }) }
            }
        }
    }

    # ---------------------------------------------------------------- releases.umbraco.com: LTS labels of current majors
    $relUrl = [string]$sources['releases']['home']
    $rel = Invoke-Fresh -Url $relUrl -Dd $dd -Label ([ordered]@{ sourceType = 'official-release-notes' })
    if ($rel.status -eq 'ok') {
        $reached++
        $text = ConvertTo-EvidenceText -Text ([string]$rel.body) -Html
        $ms = [regex]::Matches($text, 'umbraco (\d+) (lts )?latest: (\d+\.\d+\.\d+)')
        if ($ms.Count -eq 0) { [void]$report.errors.Add('releases.umbraco.com: the current-releases layout was not recognized; LTS labels not refreshed.') }
        foreach ($mt in $ms) {
            $m = [int]$mt.Groups[1].Value; $isLts = $mt.Groups[2].Success
            $entry = Get-MajorEntry -Versions $versions -Major $m
            if ($null -eq $entry) { continue }
            $lts = $entry['lts']
            if ($isLts -and ($lts['value'] -ne $true -or $lts['status'] -ne 'verified')) {
                Set-FactValue $entry 'lts' (New-Fact $true 'verified' $relUrl 'official-release-notes' 'current releases' "$m" "Umbraco $m LTS" 'Labelled LTS on releases.umbraco.com.') "versions[$m].lts"
            } elseif (-not $isLts -and $lts['value'] -eq $true -and $lts['status'] -eq 'verified') {
                $lts['status'] = 'needs-review'
                [void]$report.needsReview.Add([ordered]@{ fact = "versions[$m].lts"; detail = 'releases.umbraco.com lists this major without an LTS label.'; source = $relUrl })
            } elseif (-not $isLts -and $null -eq $lts['value']) {
                [void]$report.notes.Add("Umbraco $m is listed on releases.umbraco.com without an LTS label. Not recorded as non-LTS: confirm on the official page.")
            }
        }
    } else { [void]$report.errors.Add("releases.umbraco.com: $($rel.status)") }

    # ---------------------------------------------------------------- docs spaces
    $llmsUrl = 'https://docs.umbraco.com/llms.txt'
    $llms = Invoke-Fresh -Url $llmsUrl -Dd $dd -Label ([ordered]@{ sourceType = 'official-docs' })
    if ($llms.status -eq 'ok') {
        $reached++
        $vset = @{}
        foreach ($mt in [regex]::Matches([string]$llms.body, 'https://docs\.umbraco\.com/umbraco-cms/(\d+)\.latest/')) { $vset[[int]$mt.Groups[1].Value] = $true }
        $eolT = Get-SpaceTemplate -Sources $sources -SpaceId 'eol'
        $mainT = Get-SpaceTemplate -Sources $sources -SpaceId 'github-main'
        foreach ($entry in @($versions['majors'])) {
            $m = [int]$entry['major']; $cur = [string]$entry['docsSpace']['value']
            if ($vset.ContainsKey($m)) {
                if ($cur -ne "$m.latest") {
                    Set-FactValue $entry 'docsSpace' (New-Fact "$m.latest" 'verified' $llmsUrl 'official-docs' 'all published versions' "$m" "https://docs.umbraco.com/umbraco-cms/$m.latest/") "versions[$m].docsSpace"
                }
                continue
            }
            if ($cur -match '^\d+\.latest$' -or ($cur -eq 'latest' -and $m -lt (@($versions['majors'] | ForEach-Object { [int]$_['major'] }) | Measure-Object -Maximum).Maximum) -or $entry['docsSpace']['status'] -eq 'unverified') {
                # The space is gone from the site (or never checked): end-of-life branch, or the newest major on main.
                $eolIdx = Expand-UrlTemplate -Template ([string]$eolT['indexTemplate']) -Product 'umbraco-cms' -Major $m -Path ''
                $er = Get-DocPage -Url $eolIdx -Sources $sources -DataDir $dd -AppliesTo 'probe' -Major $m -SpaceLabel 'eol' -MaxAgeDays 1 -Refresh
                Add-Fetch $eolIdx $er.status
                if ($er.ok) { Set-FactValue $entry 'docsSpace' (New-Fact 'eol' 'verified' $eolIdx 'official-docs' "$m" "$m" 'Version Specific Upgrades' 'Found on the umbraco-eol-versions branch.') "versions[$m].docsSpace"; continue }
                $mainIdx = Expand-UrlTemplate -Template ([string]$mainT['indexTemplate']) -Product 'umbraco-cms' -Major $m -Path ''
                $mr = Get-DocPage -Url $mainIdx -Sources $sources -DataDir $dd -AppliesTo 'probe' -Major $m -SpaceLabel 'github-main' -MaxAgeDays 1 -Refresh
                Add-Fetch $mainIdx $mr.status
                if ($mr.ok -and $cur -ne 'latest') {
                    Set-FactValue $entry 'docsSpace' (New-Fact 'latest' 'unverified' $mainIdx 'official-docs' "$m" "$m" '' 'Published on the main branch without a <n>.latest space: presumed to be the unversioned latest site. Confirm on docs.umbraco.com.') "versions[$m].docsSpace"
                    [void]$report.needsReview.Add([ordered]@{ fact = "versions[$m].docsSpace"; detail = 'Presumed latest docs space; confirm.'; source = $mainIdx })
                } elseif (-not $mr.ok -and $entry['docsSpace']['status'] -ne 'unverified') {
                    $entry['docsSpace']['status'] = 'needs-review'
                    [void]$report.needsReview.Add([ordered]@{ fact = "versions[$m].docsSpace"; detail = "No $m.latest space on the docs site and no folder on the eol or main branches."; source = $llmsUrl })
                }
            }
        }
    } else { [void]$report.errors.Add("llms.txt: $($llms.status)") }

    # ---------------------------------------------------------------- re-check every fact that has an evidence phrase
    foreach ($kind in (Get-KnowledgeKinds)) {
        foreach ($item in (Get-FactList $new[$kind])) {
            $f = $item.fact
            if (-not $f.Contains('evidence') -or -not $f['evidence'] -or -not $f['source'] -or $f['status'] -eq 'secondary') { $report.reverified['not-checkable']++; continue }
            $refresh = -not $fresh.ContainsKey([string]$f['source'])
            $res = Test-FactEvidence -Fact $f -Sources $sources -DataDir $dd -MaxAgeDays 1 -Refresh:$refresh
            if ($refresh) { $fresh[[string]$f['source']] = $true; Add-Fetch ([string]$f['source']) $res.result }
            $report.reverified[$res.result]++
            switch ($res.result) {
                'confirmed' {
                    if ($f['status'] -in @('verified', 'needs-review')) { $f['status'] = 'verified'; $f['verifiedAt'] = $today; $f['verifiedBy'] = 'update-knowledge' }
                }
                'missing' {
                    $f['status'] = 'needs-review'
                    [void]$report.needsReview.Add([ordered]@{ fact = "$kind$($item.path.Substring(1))"; detail = $res.detail; source = $f['source']; evidence = $f['evidence'] })
                }
                'unreachable' { [void]$report.unreachable.Add([ordered]@{ fact = "$kind$($item.path.Substring(1))"; detail = $res.detail; source = $f['source'] }) }
            }
        }
    }

    # ---------------------------------------------------------------- LTS and end-of-life dates (secondary)
    $officialUrl = [string]$sources['lts']['official']
    $off = Get-DocPage -Url $officialUrl -Sources $sources -DataDir $dd -AppliesTo 'lts-eol' -MaxAgeDays 1 -Refresh
    Add-Fetch $officialUrl $off.status
    if ($off.ok) { [void]$report.notes.Add('The official LTS and end-of-life page was reachable. Review the dates against it by hand; the plugin does not parse it.') }
    else { [void]$report.notes.Add("The official LTS and end-of-life page was not readable ($($off.status)). Dates come from the secondary aggregator and stay labelled secondary.") }
    $secUrl = [string]$sources['lts']['secondary']
    $sec = Invoke-Fresh -Url $secUrl -Dd $dd -Label ([ordered]@{ sourceType = 'secondary' })
    if ($sec.status -eq 'ok') {
        $reached++
        $eolNote = 'Secondary aggregator. Confirm the date on the official Umbraco LTS and end-of-life page in a browser before relying on it.'
        foreach ($row in @(ConvertFrom-JsonText ([string]$sec.body))) {
            $m = 0; if (-not [int]::TryParse([string]$row.cycle, [ref]$m)) { continue }
            $entry = Get-MajorEntry -Versions $versions -Major $m
            if ($null -eq $entry) { continue }
            if ($row.PSObject.Properties['support']) { Set-FactValue $entry 'endOfSupport' (New-Fact ([string]$row.support) 'secondary' $secUrl 'secondary' 'n/a' "$m" '' ($eolNote + ' Field: support.')) "versions[$m].endOfSupport" }
            if ($row.PSObject.Properties['eol']) { Set-FactValue $entry 'endOfLife' (New-Fact ([string]$row.eol) 'secondary' $secUrl 'secondary' 'n/a' "$m" '' ($eolNote + ' Field: eol.')) "versions[$m].endOfLife" }
            if ($row.PSObject.Properties['lts'] -and $entry['lts']['status'] -in @('secondary', 'unverified')) {
                Set-FactValue $entry 'lts' (New-Fact ([bool]$row.lts) 'secondary' $secUrl 'secondary' 'n/a' "$m" '' ($eolNote + ' Field: lts.')) "versions[$m].lts"
            }
        }
    } else { [void]$report.errors.Add("Secondary dates: $($sec.status)") }

    # ---------------------------------------------------------------- .NET channels
    $riUrl = [string]$sources['dotnet']['releasesIndex']
    $ri = Invoke-Fresh -Url $riUrl -Dd $dd -Label ([ordered]@{ sourceType = 'dotnet-metadata' })
    if ($ri.status -eq 'ok') {
        $reached++
        $idx = ConvertFrom-JsonText ([string]$ri.body)
        $wanted = @{}
        foreach ($c in @($versions['dotnetChannels'])) { $wanted[[string]$c['channel']] = $c }
        foreach ($e in @($versions['majors'])) {
            if ([string]$e['dotnet']['value'] -match '^net(\d+\.\d+)$' -and -not $wanted.ContainsKey($Matches[1])) {
                $ch = [ordered]@{ channel = $Matches[1] }
                $versions['dotnetChannels'] = @(@($versions['dotnetChannels']) + $ch)
                $wanted[$Matches[1]] = $ch
            }
        }
        foreach ($ch in $wanted.Keys) {
            $row = @($idx.'releases-index' | Where-Object { [string]$_.'channel-version' -eq $ch }) | Select-Object -First 1
            $c = $wanted[$ch]
            if ($null -eq $row) {
                if (-not $c.Contains('releaseType')) { $c['releaseType'] = New-Fact $null 'unverified' $null 'none' 'n/a' ".NET $ch"; $c['endOfLife'] = New-Fact $null 'unverified' $null 'none' 'n/a' ".NET $ch" }
                [void]$report.notes.Add(".NET $ch is not in the release metadata.")
                continue
            }
            Set-FactValue $c 'releaseType' (New-Fact ([string]$row.'release-type') 'verified' $riUrl 'dotnet-metadata' 'n/a' ".NET $ch" '' 'release-type in the official .NET release metadata.') "dotnetChannels[$ch].releaseType"
            $eolDate = $null; if ($row.PSObject.Properties['eol-date'] -and $row.'eol-date') { $eolDate = [string]$row.'eol-date' }
            Set-FactValue $c 'endOfLife' (New-Fact $eolDate $(if ($eolDate) { 'verified' } else { 'unverified' }) $(if ($eolDate) { $riUrl } else { $null }) $(if ($eolDate) { 'dotnet-metadata' } else { 'none' }) 'n/a' ".NET $ch" '' 'eol-date in the official .NET release metadata.') "dotnetChannels[$ch].endOfLife"
        }
        $versions['dotnetChannels'] = @($versions['dotnetChannels'] | Sort-Object { [version]$_['channel'] })
    } else { [void]$report.errors.Add(".NET release metadata: $($ri.status)") }

    # ---------------------------------------------------------------- packages without a successor
    foreach ($ns in @($packages['noSuccessor'])) {
        $l = Get-NuGetVersionList -PackageId ([string]$ns['id']) -DataDir $dd -Refresh
        Add-Fetch $l.url $l.status
        if ($l.status -ne 'ok' -or -not $l.found) { [void]$report.unreachable.Add([ordered]@{ fact = "packages.noSuccessor[$($ns['id'])]"; detail = $l.status }); continue }
        $newer = @($l.versions | Where-Object { -not $_.Contains('-') -and (Get-VersionMajor $_) -gt [int]$ns['lastMajor'] })
        if ($newer.Count -gt 0) {
            $ns['fact']['status'] = 'needs-review'
            [void]$report.needsReview.Add([ordered]@{ fact = "packages.noSuccessor[$($ns['id'])]"; detail = "Newer release(s) published: $($newer[-1])."; source = $l.url })
        } else { $ns['fact']['verifiedAt'] = $today; $ns['fact']['verifiedBy'] = 'update-knowledge' }
    }

    if ($reached -eq 0) { throw 'No source was reachable; nothing was written. Check the network and run again.' }

    # ---------------------------------------------------------------- headers, validation, write
    foreach ($kind in (Get-KnowledgeKinds)) {
        $new[$kind]['verifiedAt'] = $today; $new[$kind]['verifiedBy'] = 'update-knowledge'; $new[$kind]['knowledgeVersion'] = $today.Replace('-', '.')
        $errs = Test-KnowledgeDocument -Document $new[$kind] -Kind $kind
        if ($errs.Count -gt 0) { throw "Refreshed $kind.json failed validation; nothing was written: $($errs -join '; ')" }
    }
    $written = @()
    $patch = New-Object System.Text.StringBuilder
    foreach ($kind in (Get-KnowledgeKinds)) {
        $text = ConvertTo-StableJson $new[$kind]
        $path = Join-Path $outDir "$kind.json"
        Write-AtomicTextFile -Path $path -Content $text
        $written += $path
        $baseText = [System.IO.File]::ReadAllText((Get-BaselineKnowledgePath $kind)) -replace "`r`n", "`n"
        $d = New-UnifiedDiff -OldText $baseText -NewText $text -OldName "a/knowledge/$kind.json" -NewName "b/knowledge/$kind.json"
        if ($d) { [void]$patch.Append("diff --git a/knowledge/$kind.json b/knowledge/$kind.json`n"); [void]$patch.Append($d) }
    }
    $patchPath = Join-Path $outDir 'maintainer.patch'
    Write-TextFile -Path $patchPath -Content $patch.ToString()
    $baseDate = [string]$prev['versions'].baselineVerifiedAt
    $willUse = ($today -gt $baseDate)
    if (-not $willUse) { [void]$report.notes.Add("The refreshed data has the same verification date as the shipped baseline ($baseDate); the plugin keeps using the baseline until a later refresh (lookup order: newer wins).") }
    $report['finishedAt'] = Get-UtcTimestamp
    $report['written'] = $written
    $report['patch'] = $patchPath
    $report['refreshedDataInUse'] = $willUse
    Write-TextFile -Path (Join-Path $outDir 'refresh-report.json') -Content (ConvertTo-JsonText -InputObject $report)

    $md = New-Object System.Text.StringBuilder
    [void]$md.Append("# Knowledge refresh $today`n`n")
    [void]$md.Append("Refreshed files: $($outDir -replace '\\', '/'). Maintainer patch (git apply in the plugin repository): maintainer.patch.`n`n")
    [void]$md.Append("## Value changes ($($report.valueChanges.Count))`n`n")
    foreach ($c in $report.valueChanges) { [void]$md.Append("- $($c.fact): $($c.old) -> $($c.new) ($($c.status); $($c.source))`n") }
    [void]$md.Append("`n## New majors ($($report.newMajors.Count))`n`n")
    foreach ($c in $report.newMajors) { [void]$md.Append("- $($c.major) (latest $($c.latest)): $($c.note)`n") }
    [void]$md.Append("`n## Needs review ($($report.needsReview.Count))`n`n")
    foreach ($c in $report.needsReview) { [void]$md.Append("- $($c.fact): $($c.detail) ($($c.source))`n") }
    [void]$md.Append("`n## Not reachable ($($report.unreachable.Count))`n`n")
    foreach ($c in $report.unreachable) { [void]$md.Append("- $($c.fact): $($c.detail)`n") }
    [void]$md.Append("`n## Notes and errors`n`n")
    foreach ($c in @($report.notes) + @($report.errors)) { [void]$md.Append("- $c`n") }
    [void]$md.Append("`nRe-checked evidence: confirmed $($report.reverified.confirmed), missing $($report.reverified.missing), unreachable $($report.reverified.unreachable), not checkable $($report.reverified['not-checkable']).`n")
    Write-TextFile -Path (Join-Path $outDir 'refresh-report.md') -Content $md.ToString()

    Write-JsonOutput ([ordered]@{
        ok = $true; dataDir = $dd; written = $written; patch = $patchPath; report = (Join-Path $outDir 'refresh-report.md'); refreshedDataInUse = $willUse
        valueChanges = @($report.valueChanges); newMajors = @($report.newMajors); upcoming = @($report.upcoming); needsReview = @($report.needsReview)
        unreachable = @($report.unreachable); reverified = $report.reverified; notes = @($report.notes); errors = @($report.errors)
    })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message; errors = @($report.errors) })
    exit 1
}
