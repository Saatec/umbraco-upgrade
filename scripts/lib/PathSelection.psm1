# PathSelection.psm1 - builds candidate upgrade paths from the knowledge files and discovery facts.
# Pure logic: package version lists, the target nuspec, and user-confirmed facts are passed in by the caller.
# Every rule, stop, and data migration in the output names the knowledge fact it rests on, with that fact's status.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NuGet.psm1') -DisableNameChecking

function Get-Rule {
    param($Paths, [string]$Kind, [scriptblock]$Where = { $true })
    foreach ($r in @($Paths['rules'])) { if ($r['kind'] -eq $Kind -and (& $Where $r)) { return $r } }
    return $null
}

function Get-RuleById { param($Paths, [string]$Id) foreach ($r in @($Paths['rules'])) { if ($r['id'] -eq $Id) { return $r } }; return $null }

function Get-CorePackageId {
    param($Packages, [int]$Major)
    foreach ($p in @($Packages['corePackages'])) {
        $min = $p['minMajor']; $max = $p['maxMajor']
        if ($Major -ge [int]$min -and ($null -eq $max -or $Major -le [int]$max)) { return [string]$p['id'] }
    }
    return $null
}

function New-FactRef {
    # Compact reference to a knowledge fact for the output.
    param([string]$Id, $Fact)
    if ($null -eq $Fact) { return [ordered]@{ id = $Id; value = $null; status = 'unverified'; source = $null; sourceType = 'none'; sourceVersion = $null; verifiedAt = $null; evidence = $null } }
    $ev = $null; if ($Fact.Contains('evidence')) { $ev = $Fact['evidence'] }
    return [ordered]@{ id = $Id; value = $Fact['value']; status = $Fact['status']; source = $Fact['source']; sourceType = $Fact['sourceType']; sourceVersion = $Fact['sourceVersion']; verifiedAt = $Fact['verifiedAt']; evidence = $ev }
}

function Select-UpgradePathCore {
    param(
        [Parameter(Mandatory)]$Knowledge,          # @{ versions = <plain>; paths = <plain>; packages = <plain> }
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [string]$Engine = 'unknown',
        [string[]]$Patterns = @(),
        [hashtable]$PackageVersions = @{},        # package id -> all published versions (from NuGet); empty = offline
        [hashtable]$PackageSources = @{},         # package id -> @{ url; fetchedAt }
        $TargetNuspec = $null,                    # nuspec of the resolved target when the target major is not in the knowledge
        [string]$TargetNuspecUrl = '',
        [hashtable]$UserFacts = @{}               # lts (bool), dotnet (string), minUpgradeFrom (string), source (URL), confirmedAt
    )
    $versions = $Knowledge['versions']; $paths = $Knowledge['paths']; $packages = $Knowledge['packages']
    $out = [ordered]@{
        ok = $true; status = 'selected'; messages = @(); source = $null; target = $null; candidates = @(); recommended = $null; close = $false
        alternatives = @(); constraints = @(); factsUsed = @(); unverifiedFacts = @(); gateBlockers = @(); suggestions = @()
    }
    $messages = New-Object System.Collections.ArrayList
    $facts = [ordered]@{}
    $useFact = { param([string]$id, $f) if (-not $facts.Contains($id)) { $facts[$id] = (New-FactRef -Id $id -Fact $f) } }

    # ------------------------------------------------------------ source
    try { $sParts = ConvertTo-VersionParts $Source } catch { $out.ok = $false; $out.status = 'error'; $out.messages = @("Source version '$Source' is not a version."); return $out }
    $sMajor = $sParts[0]
    $minKnown = (@($versions['majors'] | ForEach-Object { [int]$_['major'] }) | Measure-Object -Minimum).Minimum
    $maxKnown = (@($versions['majors'] | ForEach-Object { [int]$_['major'] }) | Measure-Object -Maximum).Maximum
    if ($sMajor -lt $minKnown) { $out.ok = $false; $out.status = 'error'; $out.messages = @("Umbraco $sMajor is older than any version in the knowledge (oldest: $minKnown). This plugin cannot plan that upgrade."); return $out }
    $out.source = [ordered]@{ version = $Source; major = $sMajor; known = ($null -ne (Get-MajorEntry -Versions $versions -Major $sMajor)); engine = $Engine; patterns = @($Patterns) }

    # ------------------------------------------------------------ version resolution helpers
    $resolveLatest = {
        param([int]$major, [int]$minor = -1)
        $pkg = Get-CorePackageId -Packages $packages -Major $major
        if ($pkg -and $PackageVersions.ContainsKey($pkg)) {
            $v = Select-LatestVersion -Versions @($PackageVersions[$pkg]) -Major $major -Minor $minor
            if ($v) {
                $src = $null; if ($PackageSources.ContainsKey($pkg)) { $src = $PackageSources[$pkg]['url'] }
                return [ordered]@{ version = $v; resolvedBy = 'nuget'; packageId = $pkg; source = $src }
            }
            return [ordered]@{ version = $null; resolvedBy = 'not-published'; packageId = $pkg; source = $null }
        }
        $e = Get-MajorEntry -Versions $versions -Major $major
        if ($minor -lt 0 -and $e) { return [ordered]@{ version = [string]$e['latestKnown']['value']; resolvedBy = 'knowledge'; packageId = $pkg; source = $e['latestKnown']['source'] } }
        $label = "$major.x"; if ($minor -ge 0) { $label = "$major.$minor.x" }
        return [ordered]@{ version = $label; resolvedBy = 'unresolved'; packageId = $pkg; source = $null }
    }

    # ------------------------------------------------------------ target
    if ($Target -notmatch '^\d+(\.\d+){0,2}$') { $out.ok = $false; $out.status = 'error'; $out.messages = @("Target '$Target' is not a version."); return $out }
    $tParts = @($Target -split '\.' | ForEach-Object { [int]$_ })
    $tMajor = $tParts[0]
    if ($tMajor -lt $sMajor) { $out.ok = $false; $out.status = 'error'; $out.messages = @("Target $Target is older than the source $Source. Downgrades are not supported."); return $out }
    $tEntry = Get-MajorEntry -Versions $versions -Major $tMajor
    $tPkg = Get-CorePackageId -Packages $packages -Major $tMajor
    $online = ($tPkg -and $PackageVersions.ContainsKey($tPkg))
    $resolved = $null
    if ($tParts.Count -eq 3) {
        if ($online) {
            $hit = @($PackageVersions[$tPkg] | Where-Object { $_ -ieq $Target })
            if ($hit.Count -eq 0) {
                $out.ok = $false; $out.status = 'error'
                $out.messages = @("Umbraco $Target is not published on NuGet ($tPkg). Use a published version or a major such as $tMajor.")
                return $out
            }
            $resolved = [ordered]@{ version = [string]$hit[0]; resolvedBy = 'nuget'; packageId = $tPkg; source = $PackageSources[$tPkg]['url'] }
        } else {
            $resolved = [ordered]@{ version = $Target; resolvedBy = 'requested-exact (not checked: offline)'; packageId = $tPkg; source = $null }
        }
    } elseif ($tParts.Count -eq 2) { $resolved = & $resolveLatest $tMajor $tParts[1] }
    else { $resolved = & $resolveLatest $tMajor }

    $future = $false
    if ($null -eq $tEntry) {
        if (-not $online) {
            $out.ok = $false; $out.status = 'unknown-target'
            $out.messages = @("Umbraco $tMajor is not in the version knowledge (newest known: $maxKnown), and NuGet could not be checked. Run /umbraco-upgrade:update-knowledge when online, or check that $tMajor is a released version.")
            $out.suggestions = @('/umbraco-upgrade:update-knowledge')
            return $out
        }
        if ($resolved.resolvedBy -ne 'nuget') {
            $pre = Select-LatestVersion -Versions @($PackageVersions[$tPkg]) -Major $tMajor -IncludePrerelease
            $msg = "Umbraco $tMajor is not in the version knowledge (newest known: $maxKnown) and has no stable release on NuGet ($tPkg)."
            if ($pre) { $msg += " Only prereleases exist (latest: $pre); prereleases are not supported targets." }
            $out.ok = $false; $out.status = 'unknown-target'; $out.messages = @($msg)
            return $out
        }
        $future = $true
    } elseif ($resolved.resolvedBy -eq 'not-published') {
        $out.ok = $false; $out.status = 'error'; $out.messages = @("No stable release matches '$Target' on NuGet ($tPkg).")
        return $out
    }
    $tVersion = [string]$resolved.version
    if ($tVersion -notmatch 'x$' -and $Source -match '^\d+\.\d+\.\d+' -and (Compare-Version $tVersion $Source) -le 0) {
        $out.ok = $false; $out.status = 'error'; $out.messages = @("Target $tVersion is not newer than the source $Source.")
        return $out
    }

    # Target facts: knowledge first; user confirmations fill gaps; the nuspec gives the framework of an unknown major.
    $tLts = $null; $tDotnet = $null; $tEol = $null; $tEos = $null; $tMin = $null
    if ($tEntry) {
        $tLts = $tEntry['lts']; $tDotnet = $tEntry['dotnet']; $tEol = $tEntry['endOfLife']; $tEos = $tEntry['endOfSupport']
        if ($tEntry.Contains('minUpgradeFrom')) { $tMin = $tEntry['minUpgradeFrom'] }
    } else {
        $today = Get-Today
        $mk = { param($v, [string]$st, [string]$src, [string]$stype, [string]$by, [string]$note)
            [ordered]@{ value = $v; status = $st; source = $src; sourceType = $stype; sourceVersion = "$tMajor"; appliesTo = "$tMajor"; verifiedAt = $(if ($st -eq 'unverified') { $null } else { $today }); verifiedBy = $by; note = $note } }
        $tfm = $null
        if ($TargetNuspec -and @($TargetNuspec['targetFrameworks']).Count -gt 0) { $tfm = [string]@($TargetNuspec['targetFrameworks'])[0] }
        if ($tfm) { $tDotnet = & $mk $tfm 'verified' $TargetNuspecUrl 'package-metadata' 'none' "Target framework of $tVersion from its nuspec." }
        else { $tDotnet = & $mk $null 'unverified' $null 'none' 'none' 'Not in the knowledge; the nuspec could not be read.' }
        $tLts = & $mk $null 'unverified' $null 'none' 'none' 'Not in the knowledge.'
        $tEol = & $mk $null 'unverified' $null 'none' 'none' 'Not in the knowledge.'
        $tEos = & $mk $null 'unverified' $null 'none' 'none' 'Not in the knowledge.'
        $tMin = & $mk $null 'unverified' $null 'none' 'none' 'Not in the knowledge: the minimum version it can upgrade from is unknown.'
    }
    $userSrc = $null; if ($UserFacts.ContainsKey('source')) { $userSrc = [string]$UserFacts['source'] }
    $confirm = { param($v, [string]$note) [ordered]@{ value = $v; status = 'verified'; source = $userSrc; sourceType = 'user-confirmed'; sourceVersion = "$tMajor"; appliesTo = "$tMajor"; verifiedAt = (Get-Today); verifiedBy = 'user'; note = $note } }
    if ($UserFacts.ContainsKey('lts') -and $null -ne $UserFacts['lts'] -and ($null -eq $tLts['value'] -or $tLts['status'] -ne 'verified')) { $tLts = & $confirm ([bool]$UserFacts['lts']) 'Confirmed by the user from the official page.' }
    if ($UserFacts.ContainsKey('dotnet') -and $UserFacts['dotnet'] -and ($null -eq $tDotnet['value'] -or $tDotnet['status'] -ne 'verified')) { $tDotnet = & $confirm ([string]$UserFacts['dotnet']) 'Confirmed by the user from an official page.' }
    if ($UserFacts.ContainsKey('minUpgradeFrom') -and $UserFacts['minUpgradeFrom'] -and ($null -eq $tMin -or $null -eq $tMin['value'])) { $tMin = & $confirm ([string]$UserFacts['minUpgradeFrom']) 'Confirmed by the user from the target version breaking-changes page.' }
    & $useFact "versions[$tMajor].lts" $tLts
    & $useFact "versions[$tMajor].dotnet" $tDotnet
    & $useFact "versions[$tMajor].endOfSupport" $tEos
    & $useFact "versions[$tMajor].endOfLife" $tEol
    if ($tMin) { & $useFact "versions[$tMajor].minUpgradeFrom" $tMin }
    $docsSpace = $null; if ($tEntry) { $docsSpace = $tEntry['docsSpace']['value'] }
    $out.target = [ordered]@{
        requested = $Target; resolved = $tVersion; resolvedBy = $resolved.resolvedBy; resolvedFrom = $resolved.source; major = $tMajor; known = (-not $future)
        lts = (New-FactRef "versions[$tMajor].lts" $tLts); dotnet = (New-FactRef "versions[$tMajor].dotnet" $tDotnet)
        endOfSupport = (New-FactRef "versions[$tMajor].endOfSupport" $tEos); endOfLife = (New-FactRef "versions[$tMajor].endOfLife" $tEol); docsSpace = $docsSpace
    }

    # ------------------------------------------------------------ chain builder (database-preserving route)
    $ltsRule = Get-Rule $paths 'lts-stop'
    $majorRule = Get-Rule $paths 'in-place-major'
    $steps = New-Object System.Collections.ArrayList
    $chainNotes = New-Object System.Collections.ArrayList
    $forcedStops = New-Object System.Collections.ArrayList
    $cur = $Source; $curMajor = $sMajor
    $addStep = {
        param([string]$from, [string]$to, [string]$type, [string[]]$kinds, [string]$codebase, $ruleIds, $resolvedBy, [string[]]$prereq = @())
        $fm = (ConvertTo-VersionParts ($from -replace '\.x$', '.0'))[0]
        $tm = (ConvertTo-VersionParts ($to -replace '(\.x)+$', '.0'))[0]
        [void]$steps.Add([ordered]@{
            id = ('S' + ($steps.Count + 1)); from = $from; to = $to; fromMajor = $fm; toMajor = $tm; type = $type; kind = @($kinds); codebase = $codebase
            rules = @($ruleIds); resolvedBy = $resolvedBy; prerequisites = @($prereq); dataMigrations = @(); removals = @(); preparation = @(); decisions = @()
        })
    }
    $norm = { param([string]$v) ($v -replace '(\.x)+$', '') }
    $isMinorRuleFor = { param($r, [int]$m) if ($r.Contains('fromMajor') -and $null -ne $r['fromMajor']) { return ([int]$r['fromMajor'] -eq $m) }; if ($r.Contains('minSourceMajor') -and $null -ne $r['minSourceMajor']) { return ($m -ge [int]$r['minSourceMajor']) }; return $false }
    $findMinorRule = { param([int]$m) foreach ($r in @($paths['rules'])) { if ($r['kind'] -eq 'in-place-minor' -and (& $isMinorRuleFor $r $m)) { return $r } }; return $null }
    $minorStep = {
        param([int]$m, [string]$why)
        $lat = & $resolveLatest $m
        $rule = & $findMinorRule $m
        $rid = @(); if ($rule) { $rid = @($rule['id']); & $useFact "rules[$($rule['id'])]" $rule['fact'] }
        if ($lat.version -and (Compare-Version ($lat.version -replace '\.x$', '.9999') (& $norm $cur)) -gt 0) {
            & $addStep $cur $lat.version 'minor-in-place' @('code', 'database') 'existing' $rid $lat.resolvedBy @($why)
            Set-Variable -Name cur -Value ([string]$lat.version) -Scope 1
        }
    }
    $legacyOk = $true
    try {
        # Legacy generations (7 and 8) to a newer major: documented boundaries, never in place.
        while ($curMajor -le 8 -and $tMajor -gt $curMajor) {
            if ($curMajor -eq 7) {
                $b = Get-Rule $paths 'generation-boundary' { param($r) [int]$r['fromMajor'] -eq 7 }
                & $useFact "rules[$($b['id'])]" $b['fact']
                $e8 = Get-MajorEntry -Versions $versions -Major 8
                if ($e8 -and $e8.Contains('minUpgradeFrom')) {
                    & $useFact 'versions[8].minUpgradeFrom' $e8['minUpgradeFrom']
                    $min = [string]$e8['minUpgradeFrom']['value']
                    if ((Compare-Version (& $norm $cur) $min) -lt 0) { & $minorStep 7 "The content migration to 8 needs at least $min." }
                }
                $landing = $null; $landBy = $null
                if ($b.Contains('landingMinor') -and $b['landingMinor']) {
                    & $useFact "rules[$($b['id'])].landing" $b['landingFact']
                    $lm = @([string]$b['landingMinor'] -split '\.')
                    $l = & $resolveLatest ([int]$lm[0]) ([int]$lm[1]); $landing = $l.version; $landBy = $l.resolvedBy
                } else { $l = & $resolveLatest 8; $landing = $l.version; $landBy = $l.resolvedBy }
                & $addStep $cur $landing 'content-migration-new-install' @('code', 'database', 'content') 'new' @($b['id']) $landBy @()
                $cur = $landing; $curMajor = 8
                continue
            }
            # From 8: the boundary rule with the largest landing major not above the target.
            $b = $null
            foreach ($r in @($paths['rules'])) {
                if ($r['kind'] -eq 'generation-boundary' -and [int]$r['fromMajor'] -eq 8 -and [int]$r['toMajor'] -le $tMajor) {
                    if ($null -eq $b -or [int]$r['toMajor'] -gt [int]$b['toMajor']) { $b = $r }
                }
            }
            if ($null -eq $b) { throw "No documented path from Umbraco 8 to $tMajor in the knowledge." }
            & $useFact "rules[$($b['id'])]" $b['fact']
            $land = [int]$b['toMajor']
            $eLand = Get-MajorEntry -Versions $versions -Major $land
            $needLatest = ($b.Contains('requiresLatestSourceMinor') -and $b['requiresLatestSourceMinor'])
            if ($needLatest) {
                if ($b.Contains('prerequisiteFact')) { & $useFact "rules[$($b['id'])].prerequisite" $b['prerequisiteFact'] }
                & $minorStep 8 'The database step needs the latest Umbraco 8 release.'
            }
            if ($eLand -and $eLand.Contains('minUpgradeFrom')) {
                & $useFact "versions[$land].minUpgradeFrom" $eLand['minUpgradeFrom']
                if ((Compare-Version (& $norm $cur) ([string]$eLand['minUpgradeFrom']['value'])) -lt 0) { & $minorStep 8 "Umbraco $land needs a database of at least $($eLand['minUpgradeFrom']['value'])." }
            }
            $to = $null; $toBy = $null
            if ($land -eq $tMajor) { $to = $tVersion; $toBy = $resolved.resolvedBy } else { $l = & $resolveLatest $land; $to = $l.version; $toBy = $l.resolvedBy }
            $pre = @(); foreach ($p in @($b['prerequisites'])) { if ($p) { $pre += [string]$p['text']; & $useFact "rules[$($b['id'])].prerequisite.$($p['id'])" $p['fact'] } }
            & $addStep $cur $to 'database-reuse-new-project' @('code', 'database') 'new' @($b['id']) $toBy $pre
            $cur = $to; $curMajor = $land
        }
        # Modern generations: documented hops, then mandatory LTS stops, then minimum-from constraints.
        $guard = 0
        while ($curMajor -lt $tMajor) {
            $guard++; if ($guard -gt 50) { throw 'Path builder did not converge.' }
            $next = $tMajor; $rid = @($majorRule['id']); $why = $null
            $hop = $null
            foreach ($r in @($paths['rules'])) { if ($r['kind'] -eq 'documented-hop' -and [int]$r['fromMajor'] -eq $curMajor -and [int]$r['toMajor'] -le $tMajor) { $hop = $r } }
            if ($hop) {
                $next = [int]$hop['toMajor']; $rid = @($hop['id']); & $useFact "rules[$($hop['id'])]" $hop['fact']
                if ($next -lt $tMajor) { [void]$forcedStops.Add([ordered]@{ major = $next; rule = $hop['id']; reason = [string]$hop['description'] }) }
            } elseif ($ltsRule -and $curMajor -ge [int]$ltsRule['minSourceMajor']) {
                $lts = $null
                foreach ($m in @($versions['majors'])) {
                    $mm = [int]$m['major']
                    if ($mm -gt $curMajor -and $mm -lt $tMajor -and $m['lts']['value'] -eq $true) { if ($null -eq $lts -or $mm -lt [int]$lts['major']) { $lts = $m } }
                }
                if ($lts) {
                    $next = [int]$lts['major']; $rid = @($ltsRule['id'])
                    & $useFact "rules[$($ltsRule['id'])]" $ltsRule['fact']
                    & $useFact "versions[$next].lts" $lts['lts']
                    [void]$forcedStops.Add([ordered]@{ major = $next; rule = $ltsRule['id']; reason = "Umbraco $next is the closest LTS major after $curMajor." })
                } else { & $useFact "rules[$($majorRule['id'])]" $majorRule['fact'] }
            } else { & $useFact "rules[$($majorRule['id'])]" $majorRule['fact'] }
            # Minimum version the next stop can upgrade from.
            $eNext = Get-MajorEntry -Versions $versions -Major $next
            $minFact = $null
            if ($eNext -and $eNext.Contains('minUpgradeFrom')) { $minFact = $eNext['minUpgradeFrom'] } elseif ($next -eq $tMajor -and $tMin -and $null -ne $tMin['value']) { $minFact = $tMin }
            if ($minFact -and $null -ne $minFact['value']) {
                & $useFact "versions[$next].minUpgradeFrom" $minFact
                $min = [string]$minFact['value']
                $curCmp = $cur -replace '\.x$', '.9999'
                if ((Compare-Version $curCmp $min) -lt 0) {
                    $minMajor = Get-VersionMajor $min
                    if ($minMajor -eq $curMajor) { & $minorStep $curMajor "Umbraco $next can upgrade only from $min or later." }
                    elseif ($minMajor -gt $curMajor -and $minMajor -lt $next) {
                        $next = $minMajor; $rid = @("versions[$minMajor]")
                        [void]$forcedStops.Add([ordered]@{ major = $next; rule = "minimum-from"; reason = "Umbraco $($eNext['major']) can upgrade only from $min or later." })
                        continue
                    }
                }
            } elseif ($next -eq $tMajor -and $future) {
                [void]$chainNotes.Add("The minimum version Umbraco $tMajor can upgrade from is not known. The step from $cur is unverified.")
            }
            $to = $null; $toBy = $null
            if ($next -eq $tMajor) { $to = $tVersion; $toBy = $resolved.resolvedBy } else { $l = & $resolveLatest $next; $to = $l.version; $toBy = $l.resolvedBy }
            & $addStep $cur $to 'major-in-place' @('code', 'database') 'existing' $rid $toBy @()
            $cur = $to; $curMajor = $next
        }
        # Same major (or landing below an exact target): minor update in place.
        if ($curMajor -eq $tMajor -and $tVersion -notmatch 'x$' -and $cur -notmatch 'x$' -and (Compare-Version $cur $tVersion) -lt 0) {
            $rule = & $findMinorRule $tMajor
            $rid = @(); if ($rule) { $rid = @($rule['id']); & $useFact "rules[$($rule['id'])]" $rule['fact'] }
            & $addStep $cur $tVersion 'minor-in-place' @('code', 'database') 'existing' $rid $resolved.resolvedBy @()
            $cur = $tVersion
        }
    } catch {
        $legacyOk = $false
        [void]$messages.Add("Database-preserving path: $($_.Exception.Message)")
    }

    # Data migrations, removals, and preparation per step.
    foreach ($st in $steps) {
        foreach ($m in @($versions['majors'])) {
            $mm = [int]$m['major']
            if ($mm -le [int]$st.fromMajor -or $mm -gt [int]$st.toMajor) { continue }
            foreach ($dm in @($m['dataMigrations'])) {
                if (-not $dm) { continue }
                if ($dm.Contains('whenFromMajor') -and $null -ne $dm['whenFromMajor'] -and [int]$dm['whenFromMajor'] -ne [int]$st.fromMajor) { continue }
                & $useFact "versions[$mm].dataMigrations[$($dm['id'])]" $dm['fact']
                $st.dataMigrations = @($st.dataMigrations) + [ordered]@{ id = $dm['id']; major = $mm; title = $dm['title']; runsWhen = $dm['runsWhen']; source = $dm['fact']['source']; status = $dm['fact']['status'] }
            }
            if ($mm -eq [int]$st.toMajor) {
                foreach ($pp in @($m['preparation'])) {
                    if (-not $pp) { continue }
                    & $useFact "versions[$mm].preparation[$($pp['id'])]" $pp['fact']
                    $st.preparation = @($st.preparation) + [ordered]@{ id = $pp['id']; text = $pp['text']; source = $pp['fact']['source']; status = $pp['fact']['status'] }
                }
            }
        }
        foreach ($r in @($paths['rules'])) {
            if ($r['kind'] -ne 'generation-boundary' -or -not $r.Contains('removals')) { continue }
            if ([int]$st.fromMajor -le [int]$r['fromMajor'] -and [int]$st.toMajor -ge [int]$r['toMajor']) {
                foreach ($rm in @($r['removals'])) {
                    & $useFact "rules[$($r['id'])].removals[$($rm['id'])]" $rm['fact']
                    $st.removals = @($st.removals) + [ordered]@{ id = $rm['id']; text = $rm['text']; source = $rm['fact']['source']; status = $rm['fact']['status'] }
                }
            }
        }
    }

    # ------------------------------------------------------------ candidates
    $strategies = @{}
    foreach ($s in @($paths['strategies'])) { $strategies[[string]$s['id']] = $s }
    $cands = New-Object System.Collections.ArrayList
    $sameMajor = ($sMajor -eq $tMajor)
    if ($legacyOk -and $steps.Count -gt 0) {
        $strategy = 'in-place'
        if (@($steps | Where-Object { $_.codebase -eq 'new' }).Count -gt 0) { $strategy = 'rebuild-with-database-migration' }
        elseif (@($steps | Where-Object { $_.type -eq 'major-in-place' }).Count -gt 1) { $strategy = 'staged' }
        [void]$cands.Add([ordered]@{ strategy = $strategy; steps = @($steps) })
    }
    if (-not $sameMajor) {
        $tr = [ordered]@{
            id = 'S1'; from = $Source; to = $tVersion; fromMajor = $sMajor; toMajor = $tMajor; type = 'content-transfer-new-install'; kind = @('code', 'content'); codebase = 'new'
            rules = @(); resolvedBy = $resolved.resolvedBy; prerequisites = @(); dataMigrations = @(); removals = @(); preparation = @()
            decisions = @("Choose how content moves from $Source to a new $tVersion installation (a content-transfer tool or manual transfer). No tool's support for this source and target is in the knowledge: verify it from the tool's own documentation or package metadata before relying on it.")
        }
        [void]$cands.Add([ordered]@{ strategy = 'new-install-with-content-transfer'; steps = @($tr) })
    }
    $closeThreshold = [int]$paths['closeThreshold']
    $constraints = New-Object System.Collections.ArrayList
    $mandatory = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($c in $cands) {
        $i++
        $s = $strategies[$c.strategy]
        $c.Insert(0, 'id', "C$i")
        $c['preservesDatabase'] = [bool]$s['preservesDatabase']; $c['preservesCode'] = [bool]$s['preservesCode']
        $c['description'] = [string]$s['description']
        $c['valid'] = $true; $c['invalidBecause'] = @(); $c['decisions'] = @(); $c['risk'] = [int]$s['baseRisk']; $c['riskDetail'] = @([ordered]@{ rule = "strategy:$($c.strategy)"; delta = [int]$s['baseRisk']; reason = 'base risk of the strategy' })
        foreach ($st in @($c.steps)) { foreach ($d in @($st.decisions)) { if ($d) { $c['decisions'] = @($c['decisions']) + $d } } }
        # Engine constraints.
        foreach ($r in @($paths['rules'] | Where-Object { $_['kind'] -eq 'engine-constraint' })) {
            if ($r.Contains('unsupportedFromMajor') -and $Engine -eq [string]$r['engine'] -and $c['preservesDatabase']) {
                $hitStep = @($c.steps | Where-Object { [int]$_.toMajor -ge [int]$r['unsupportedFromMajor'] -and [int]$_.fromMajor -lt [int]$r['unsupportedFromMajor'] }) | Select-Object -First 1
                if ($hitStep) {
                    & $useFact "rules[$($r['id'])]" $r['fact']
                    $opts = @($r['options']) -join '; '
                    $c['decisions'] = @($c['decisions']) + "The $Engine database must be converted before step $($hitStep.id) (to $($hitStep.to)): $($r['description']) Options from the documentation: $opts."
                    [void]$constraints.Add([ordered]@{ rule = $r['id']; candidate = $c.id; step = $hitStep.id; text = [string]$r['description'] })
                }
            }
            if ($r.Contains('allowedEngines')) {
                $hitStep = @($c.steps | Where-Object { $_.type -eq 'content-migration-new-install' -and [int]$_.toMajor -eq [int]$r['toMajor'] }) | Select-Object -First 1
                if ($hitStep) {
                    & $useFact "rules[$($r['id'])]" $r['fact']
                    $allowed = @($r['allowedEngines'])
                    if ($Engine -eq 'unknown') {
                        $c['decisions'] = @($c['decisions']) + "Confirm the database engine: the content migration to $($r['toMajor']) supports only $($allowed -join ', ')."
                    } elseif ($allowed -notcontains $Engine) {
                        $c['valid'] = $false; $c['invalidBecause'] = @($c['invalidBecause']) + "$($r['description']) (engine: $Engine)"
                        [void]$constraints.Add([ordered]@{ rule = $r['id']; candidate = $c.id; step = $hitStep.id; text = [string]$r['description'] })
                    }
                }
            }
        }
        if ($Engine -eq 'unknown' -and $c['preservesDatabase'] -and @($c['decisions'] | Where-Object { $_ -like 'Confirm the database engine*' }).Count -eq 0) {
            $c['decisions'] = @($c['decisions']) + 'Confirm the database engine (discovery could not determine it).'
        }
    }
    # Scoring heuristics and mandatory work from discovery facts.
    foreach ($sc in @($paths['scoring'])) {
        $w = $sc['when']
        $match = $true
        if ($w.Contains('pattern') -and $Patterns -notcontains [string]$w['pattern']) { $match = $false }
        if ($w.Contains('engine') -and $Engine -ne [string]$w['engine']) { $match = $false }
        if ($w.Contains('minTargetMajor') -and $tMajor -lt [int]$w['minTargetMajor']) { $match = $false }
        if ($w.Contains('maxSourceMajor') -and $sMajor -gt [int]$w['maxSourceMajor']) { $match = $false }
        if ($w.Contains('maxSourceMajorBelowTarget') -and $sMajor -ge $tMajor) { $match = $false }
        if (-not $match) { continue }
        if ($sc.Contains('mandatoryWork') -and $sc['mandatoryWork']) { [void]$mandatory.Add([ordered]@{ id = $sc['id']; text = $sc['mandatoryWork']; reason = $sc['reason'] }) }
        foreach ($adj in @($sc['adjust'])) {
            if (-not $adj) { continue }
            foreach ($c in $cands) {
                if ($c.strategy -ne [string]$adj['strategy']) { continue }
                $c['risk'] = [int]$c['risk'] + [int]$adj['risk']
                $c['riskDetail'] = @($c['riskDetail']) + [ordered]@{ rule = $sc['id']; delta = [int]$adj['risk']; reason = [string]$sc['reason'] }
            }
        }
    }
    $valid = @($cands | Where-Object { $_['valid'] } | Sort-Object { [int]$_['risk'] }, { $_['id'] })
    $best = $null
    $out.candidates = @($cands)
    $out.constraints = @($constraints)
    if ($valid.Count -eq 0) {
        $out.ok = $false; $out.status = 'no-valid-path'
        [void]$messages.Add('No candidate path satisfies the hard constraints. See invalidBecause on each candidate.')
    } else {
        $best = $valid[0]
        $out.recommended = $best['id']
        if ($valid.Count -gt 1 -and ([int]$valid[1]['risk'] - [int]$best['risk']) -le $closeThreshold) { $out.close = $true }
        foreach ($c in $cands) {
            if ($c['id'] -eq $best['id']) { continue }
            $why = "Higher risk ($($c['risk']) against $($best['risk']))."
            if (([int]$c['risk'] - [int]$best['risk']) -le $closeThreshold) { $why = "Close in risk ($($c['risk']) against $($best['risk'])): not rejected; the user chooses between them." }
            if (-not $c['valid']) { $why = ($c['invalidBecause'] -join ' ') }
            $out.alternatives = @($out.alternatives) + [ordered]@{ strategy = $c.strategy; rejectedBecause = $why }
        }
        # A direct jump that the rules forbid is an alternative too.
        if (@($forcedStops).Count -gt 0 -and -not $sameMajor -and $sMajor -ge 9) {
            $reasons = @($forcedStops | ForEach-Object { "stop at $($_.major): $($_.reason) [$($_.rule)]" }) -join ' '
            if ($tMin -and $null -ne $tMin['value'] -and (Compare-Version $Source ([string]$tMin['value'])) -lt 0) {
                $reasons += " Umbraco $tMajor can upgrade only from $($tMin['value']) or later [versions[$tMajor].minUpgradeFrom]."
            }
            $out.alternatives = @($out.alternatives) + [ordered]@{ strategy = 'in-place (direct, no intermediate stops)'; rejectedBecause = "The documented rules require intermediate stops: $reasons" }
        }
        if ($out.close) { [void]$messages.Add("Candidates $($valid[0]['id']) and $($valid[1]['id']) are close in risk; present both and ask the user.") }
        if (@($best['decisions']).Count -gt 0) { [void]$messages.Add("The recommended candidate needs user decisions before the plan can rely on it.") }
    }
    foreach ($n in $chainNotes) { [void]$messages.Add($n) }
    $out.mandatoryWork = @($mandatory)

    # ------------------------------------------------------------ verification summary and gate blockers
    $out.factsUsed = @($facts.Values)
    $out.unverifiedFacts = @($facts.Values | Where-Object { $_['status'] -ne 'verified' })
    $blockers = New-Object System.Collections.ArrayList
    if ($null -eq $tLts['value']) { [void]$blockers.Add("Confirm the LTS status of Umbraco $tMajor from the official long-term support page.") }
    if ($null -eq $tDotnet['value']) { [void]$blockers.Add("Confirm the .NET version Umbraco $tMajor requires from an official page or the package metadata.") }
    if ($future) {
        if ($null -eq $tMin -or $null -eq $tMin['value']) { [void]$blockers.Add("Confirm the minimum version Umbraco $tMajor can upgrade from, from its breaking-changes and upgrade pages.") }
        $gap = @(); for ($m = $maxKnown + 1; $m -lt $tMajor; $m++) { $gap += $m }
        if ($gap.Count -gt 0) { [void]$blockers.Add("Majors $($gap -join ', ') are not in the knowledge. If one of them is an LTS release, it is a mandatory stop: check the official pages.") }
        $out.suggestions = @('/umbraco-upgrade:update-knowledge')
        [void]$messages.Add("Umbraco $tMajor is not in the version knowledge. Every fact about it is unverified until confirmed from official pages; consider /umbraco-upgrade:update-knowledge.")
    }
    $out.gateBlockers = @($blockers)
    if ($out.ok) {
        if ($future) { $out.status = 'future-unverified' }
        elseif ($out.close -or ($null -ne $best -and @($best['decisions']).Count -gt 0)) { $out.status = 'needs-decision' }
    }
    $out.messages = @($messages)
    return $out
}

Export-ModuleMember -Function Select-UpgradePathCore, Get-CorePackageId
