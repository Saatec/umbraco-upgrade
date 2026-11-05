# Planning.psm1 - package compatibility from NuGet metadata, pattern guidance, and phase composition.
# Read-only on the project. The phase rules are plugin heuristics (knowledge/planning/phase-rules.json), not version facts.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NuGet.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1') -DisableNameChecking

$script:PluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:Difficulty = @{ low = 1; medium = 2; high = 3 }

function Get-PhaseRules {
    return (ConvertTo-PlainObject (Read-JsonFile (Join-Path $script:PluginRoot 'knowledge/planning/phase-rules.json')))
}

function Get-GenerationOfMajor {
    param([int]$Major)
    if ($Major -le 7) { return 'v7' }
    if ($Major -eq 8) { return 'v8' }
    if ($Major -le 13) { return 'v9-v13' }
    return 'v14+'
}

function Get-RegistryIndex {
    $idx = @{}
    foreach ($p in (Get-PatternRegistry)) { $idx[$p.id] = $p }
    return $idx
}

function Get-RelevantImpacts {
    # Impacts that apply to the upgrade: source major below the crossing, target major at or above it.
    param($Pattern, [int]$SourceMajor, [int]$TargetMajor)
    return @(@($Pattern.impact) | Where-Object { $null -ne $_ -and $SourceMajor -lt [int]$_.crosses -and [int]$_.crosses -le $TargetMajor })
}

function Get-MaxDifficulty {
    param($Impacts)
    $best = 'low'
    foreach ($i in @($Impacts)) { if ($null -ne $i -and $script:Difficulty[[string]$i.difficulty] -gt $script:Difficulty[$best]) { $best = [string]$i.difficulty } }
    return $best
}

# ---------------------------------------------------------------- NuGet version ranges

function ConvertFrom-NuGetRange {
    # "[13.0.0, 14.0.0)", "(,14)", "[17.0.0]", "13.0.0" (minimum, inclusive). Returns bounds or $null.
    param([string]$Range)
    if ([string]::IsNullOrWhiteSpace($Range)) { return $null }
    $r = $Range.Trim()
    if ($r -notmatch '^[\[\(]') { return [ordered]@{ min = $r; minInclusive = $true; max = $null; maxInclusive = $false } }
    if ($r -notmatch '^([\[\(])\s*([^,\]\)]*)\s*(?:,\s*([^\]\)]*))?\s*([\]\)])$') { return $null }
    $open = $Matches[1]; $a = $Matches[2].Trim(); $hasComma = $r.Contains(','); $b = $(if ($Matches[3]) { $Matches[3].Trim() } else { '' }); $close = $Matches[4]
    if (-not $hasComma) { return [ordered]@{ min = $a; minInclusive = $true; max = $a; maxInclusive = $true } }
    return [ordered]@{ min = $(if ($a) { $a } else { $null }); minInclusive = ($open -eq '['); max = $(if ($b) { $b } else { $null }); maxInclusive = ($close -eq ']') }
}

function Test-NuGetRangeAdmitsMajor {
    # True when some version of the major lies inside the range.
    param([string]$Range, [int]$Major)
    $b = ConvertFrom-NuGetRange $Range
    if ($null -eq $b) { return $false }
    $lo = "$Major.0.0"; $hi = "$($Major + 1).0.0"
    try {
        if ($b.max) {
            $c = Compare-Version ($b.max -replace '-.*$', '') $lo
            if ($c -lt 0 -or ($c -eq 0 -and -not $b.maxInclusive)) { return $false }
        }
        if ($b.min) {
            if ((Compare-Version ($b.min -replace '-.*$', '') $hi) -ge 0) { return $false }
        }
    } catch { return $false }
    return $true
}

function Test-CmsDependencyAdmitsMajor {
    # A CMS dependency admits the target major only when its range includes the major and the dependency package
    # itself has a release of that major: a range without an upper bound on a core package of an earlier generation
    # (for example one whose releases end at 8) never resolves on a later major. The dependency's version list comes
    # from NuGet through the cache; $Cache keeps the majors per dependency id for one run.
    # Returns 'admits', 'excludes', or 'unknown' (the version list could not be read).
    param([Parameter(Mandatory)]$Dependency, [Parameter(Mandatory)][int]$Major, [string]$DataDir = '', [hashtable]$Cache = @{})
    if (-not (Test-NuGetRangeAdmitsMajor -Range ([string]$Dependency.range) -Major $Major)) { return 'excludes' }
    $key = ([string]$Dependency.id).ToLowerInvariant()
    if (-not $Cache.ContainsKey($key)) {
        $l = Get-NuGetVersionList -PackageId ([string]$Dependency.id) -DataDir $DataDir
        if ($l.status -ne 'ok') { $Cache[$key] = $null }
        else {
            $set = @{}
            if ($l.found) { foreach ($v in @($l.versions)) { try { $set[[int](Get-VersionMajor ([string]$v))] = $true } catch { } } }
            $Cache[$key] = $set
        }
    }
    $majors = $Cache[$key]
    if ($null -eq $majors) { return 'unknown' }
    if ($majors.ContainsKey($Major)) { return 'admits' }
    return 'excludes'
}

function Get-FamilyCmsDependencies {
    # CMS dependencies that a release reaches through packages of its own id family: a product package can depend
    # only on its own core packages, which depend on the CMS. Follows at most $Depth levels and $MaxLookups nuspec
    # files (each at the minimum version of the range), through the cache.
    param([Parameter(Mandatory)][string]$PackageId, $Nuspec, [Parameter(Mandatory)]$CmsDep, [string]$DataDir = '', [int]$Depth = 2, [int]$MaxLookups = 6)
    $parts = $PackageId.Split('.')
    $prefix = $(if ($parts.Count -ge 2) { ($parts[0..1] -join '.') + '.' } else { $PackageId + '.' })
    $found = New-Object System.Collections.ArrayList
    $queue = @(@($Nuspec.dependencies) | Where-Object { $_ -and ([string]$_.id).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) })
    $seen = @{}; $lookups = 0
    for ($level = 0; $level -lt $Depth -and $queue.Count -gt 0; $level++) {
        $next = @()
        foreach ($d in $queue) {
            $key = ([string]$d.id).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $b = ConvertFrom-NuGetRange ([string]$d.range)
            if (-not $b -or -not $b.min -or $lookups -ge $MaxLookups) { continue }
            $lookups++
            $ns = Get-NuGetNuspec -PackageId ([string]$d.id) -Version ([string]$b.min) -DataDir $DataDir
            if ($ns.status -ne 'ok' -or -not $ns.nuspec) { continue }
            foreach ($dd in @($ns.nuspec.dependencies)) {
                if (-not $dd) { continue }
                if ($CmsDep.IsMatch([string]$dd.id)) { [void]$found.Add($dd) }
                elseif (([string]$dd.id).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $next += ,$dd }
            }
        }
        $queue = @($next)
    }
    return ,($found.ToArray())
}

# ---------------------------------------------------------------- package references and compatibility

function Get-ProjectPackageReferences {
    # Direct package references with their version and the file that declares them.
    param([Parameter(Mandatory)][string]$Root)
    $Root = Resolve-FullPath $Root
    $files = Get-ProjectFiles -Root $Root
    $central = @{}
    foreach ($f in ($files | Where-Object { [System.IO.Path]::GetFileName($_) -ieq 'Directory.Packages.props' })) {
        try { $doc = Read-XmlFile $f } catch { continue }
        foreach ($n in @($doc.SelectNodes("//*[local-name()='PackageVersion']"))) { $central[[string]$n.GetAttribute('Include')] = [string]$n.GetAttribute('Version') }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $name = [System.IO.Path]::GetFileName($f)
        $rel = Get-RelativePathCompat -BasePath $Root -Path $f
        try {
            if ($name -match '\.(cs|vb)proj$') {
                $doc = Read-XmlFile $f
                foreach ($n in @($doc.SelectNodes("//*[local-name()='PackageReference']"))) {
                    $id = [string]$n.GetAttribute('Include'); if (-not $id) { continue }
                    $v = [string]$n.GetAttribute('Version')
                    if (-not $v) { foreach ($c in $n.ChildNodes) { if ($c.LocalName -eq 'Version') { $v = $c.InnerText.Trim() } } }
                    if (-not $v -and $central.ContainsKey($id)) { $v = $central[$id] }
                    [void]$out.Add([ordered]@{ id = $id; version = $v; file = $rel })
                }
            } elseif ($name -ieq 'packages.config') {
                $doc = Read-XmlFile $f
                foreach ($n in @($doc.SelectNodes("//*[local-name()='package']"))) {
                    $id = [string]$n.GetAttribute('id'); if (-not $id) { continue }
                    [void]$out.Add([ordered]@{ id = $id; version = [string]$n.GetAttribute('version'); file = $rel })
                }
            }
        } catch { continue }
    }
    return ,($out.ToArray())
}

function Get-PackageCompatibility {
    # Classifies each direct package reference for the target major from NuGet metadata (cached; mockable).
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$TargetMajor, [int]$SourceMajor = 0, [string]$DataDir = '')
    $rules = (Get-PhaseRules)['packages']
    $refs = Get-ProjectPackageReferences -Root $Root
    $cmsId = New-Object System.Text.RegularExpressions.Regex([string]$rules['cmsPackageIdPattern'], 'IgnoreCase')
    $cmsDep = New-Object System.Text.RegularExpressions.Regex([string]$rules['cmsDependencyIdPattern'], 'IgnoreCase')
    $legacyToCore = ($SourceMajor -gt 0 -and $SourceMajor -le 8 -and $TargetMajor -ge 9)
    # Package knowledge: renamed first-party packages and packages without a successor (version facts as data).
    $pk = (Get-KnowledgeFile -Kind packages -DataDir $DataDir).data
    $mapped = @{}; foreach ($m in @($pk['mappings'])) { if ($m) { $mapped[([string]$m['from']).ToLowerInvariant()] = $m } }
    $ended = @{}; foreach ($n in @($pk['noSuccessor'])) { if ($n) { $ended[([string]$n['id']).ToLowerInvariant()] = $n } }
    $depCache = @{}
    # Packages the installed CMS core package, or a renamed first-party package, depends on (packages.config lists
    # them as direct references).
    $cmsProvided = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ref in @($refs | Where-Object { ($cmsId.IsMatch([string]$_.id) -or $mapped.ContainsKey(([string]$_.id).ToLowerInvariant())) -and $_.version })) {
        $ns = Get-NuGetNuspec -PackageId $ref.id -Version $ref.version -DataDir $DataDir
        if ($ns.status -eq 'ok' -and $ns.nuspec) { foreach ($d in @($ns.nuspec.dependencies)) { if ($d) { [void]$cmsProvided.Add([string]$d.id) } } }
    }
    $results = New-Object System.Collections.ArrayList
    $unreachable = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($ref in $refs) {
        $id = [string]$ref.id
        if ($seen.ContainsKey($id.ToLowerInvariant())) { continue }
        $seen[$id.ToLowerInvariant()] = $true
        $row = [ordered]@{ id = $id; version = $ref.version; file = $ref.file; class = $null; latest = $null; compatibleVersion = $null; cmsDependencies = @(); frameworks = @(); deprecation = $null; notes = @() }
        if ($cmsId.IsMatch($id)) { $row.class = 'core'; [void]$results.Add($row); continue }
        if ($cmsProvided.Contains($id)) { $row.class = 'cms-dependency'; [void]$results.Add($row); continue }
        if ($legacyToCore) {
            $isPlatform = $false
            foreach ($pfx in @($rules['platformPackagePrefixes'])) { if ($id.StartsWith([string]$pfx, [System.StringComparison]::OrdinalIgnoreCase)) { $isPlatform = $true } }
            if ($isPlatform) { $row.class = 'platform'; $row.notes = @([string]$rules['platformReason']); [void]$results.Add($row); continue }
        }
        $mk = $id.ToLowerInvariant()
        if ($mapped.ContainsKey($mk) -and $TargetMajor -ge [int]$mapped[$mk]['toMinMajor']) {
            $m = $mapped[$mk]
            $row.class = 'renamed'; $row['successor'] = [string]$m['to']
            $row.notes = @("From $($m['toMinMajor']) on, this package is published as $($m['to']) (package knowledge; source: $($m['fact']['source'])).")
            [void]$results.Add($row); continue
        }
        if ($ended.ContainsKey($mk) -and $TargetMajor -gt [int]$ended[$mk]['lastMajor']) {
            $n = $ended[$mk]
            $row.class = 'no-target-version'
            $why = "No release after $($n['lastMajor']) and no successor package (package knowledge; source: $($n['fact']['source']))."
            if ($n['fact'].Contains('note') -and $n['fact']['note']) { $why += ' ' + [string]$n['fact']['note'] }
            $row.notes = @($why)
            [void]$results.Add($row); continue
        }
        $list = Get-NuGetVersionList -PackageId $id -DataDir $DataDir
        if ($list.status -ne 'ok') { $row.class = 'unreachable'; [void]$unreachable.Add($id); [void]$results.Add($row); continue }
        if (-not $list.found) { $row.class = 'not-found'; $row.notes = @('Not on nuget.org: ask where the package comes from (private feed or local file).'); [void]$results.Add($row); continue }
        $row.latest = Select-LatestVersion -Versions $list.versions
        if (-not $row.latest) { $row.latest = Select-LatestVersion -Versions $list.versions -IncludePrerelease }
        # Candidate versions: the latest release of each package major, newest first.
        $candidates = @(Get-MajorSummary -Versions $list.versions | Sort-Object { $_.major } -Descending | ForEach-Object { if ($_.latest) { $_.latest } else { $_.latestPrerelease } } | Where-Object { $_ })
        $maxLookups = [int]$rules['maxNuspecLookupsPerPackage']
        $lookups = 0; $readable = 0; $unreadable = 0; $exhausted = $false; $cmsSpecific = $false; $admits = $null; $admitRange = $null; $latestTfms = @(); $latestDeps = @()
        $noRelease = @{}
        # A newer release line whose CMS range ends at or below the target major: then a range without an upper bound
        # on an older line, from an earlier major, is not evidence of support (the publisher's newer metadata stops
        # before the target).
        $newerBounded = $false; $staleOpen = $null
        foreach ($cv in $candidates) {
            if ($lookups -ge $maxLookups) { $exhausted = $true; break }
            $lookups++
            $ns = Get-NuGetNuspec -PackageId $id -Version $cv -DataDir $DataDir
            if ($ns.status -ne 'ok' -or -not $ns.nuspec) { $unreadable++; $row.notes = @($row.notes) + "nuspec of $cv not readable ($($ns.status))"; continue }
            $readable++
            $deps = @($ns.nuspec.dependencies | Where-Object { $_ -and $cmsDep.IsMatch([string]$_.id) })
            if ($deps.Count -eq 0) {
                $deps = Get-FamilyCmsDependencies -PackageId $id -Nuspec $ns.nuspec -CmsDep $cmsDep -DataDir $DataDir
                if ($deps.Count -gt 0 -and $readable -eq 1) { $row.notes = @($row.notes) + "The CMS dependency of its releases comes through packages of its own family ($(@(@($ns.nuspec.dependencies) | Where-Object { $_ } | ForEach-Object { $_.id }) -join ', '))." }
            }
            if ($readable -eq 1) { $latestTfms = @($ns.nuspec.targetFrameworks); $latestDeps = @($deps | ForEach-Object { "$($_.id) $($_.range)" }) }
            if ($deps.Count -eq 0) { continue }
            $cmsSpecific = $true
            foreach ($d in $deps) {
                $res = Test-CmsDependencyAdmitsMajor -Dependency $d -Major $TargetMajor -DataDir $DataDir -Cache $depCache
                if ($res -eq 'admits') {
                    $b = ConvertFrom-NuGetRange ([string]$d.range)
                    $fromEarlier = $false
                    if ($b -and $b.min) { try { $fromEarlier = ((Get-VersionMajor ([string]$b.min -replace '-.*$', '')) -lt $TargetMajor) } catch { $fromEarlier = $false } }
                    if ($newerBounded -and $b -and -not $b.max -and $fromEarlier) { if (-not $staleOpen) { $staleOpen = $cv }; continue }
                    $admits = $cv; $admitRange = [string]$d.range; break
                }
                if ($res -eq 'unknown') { $unreadable++; $row.notes = @($row.notes) + "versions of $($d.id) not readable" }
                elseif (Test-NuGetRangeAdmitsMajor -Range ([string]$d.range) -Major $TargetMajor) { $noRelease[[string]$d.id] = $true }
            }
            if ($admits) { break }
            foreach ($d in $deps) {
                $rb = ConvertFrom-NuGetRange ([string]$d.range)
                if ($rb -and $rb.max) { try { if ((Compare-Version ([string]$rb.max -replace '-.*$', '') "$TargetMajor.0.0") -le 0) { $newerBounded = $true } } catch { } }
            }
        }
        if (-not $admits -and $noRelease.Count -gt 0) {
            $row.notes = @($row.notes) + "The CMS dependency range of a release includes $TargetMajor, but $(@($noRelease.Keys | Sort-Object) -join ', ') has no $TargetMajor release: the package targets an earlier CMS generation."
        }
        if (-not $admits -and $staleOpen) {
            $row.notes = @($row.notes) + "Release $staleOpen declares a CMS range without an upper bound, which NuGet would allow with $TargetMajor, but the CMS ranges of newer releases end at or below ${TargetMajor}: no release shows support for $TargetMajor."
        }
        $row.frameworks = @($latestTfms)
        $row.cmsDependencies = @($latestDeps)
        if ($readable -eq 0 -or ($cmsSpecific -and -not $admits -and $unreadable -gt 0)) {
            # Without the metadata of every release line it checked, the plugin makes no compatibility claim.
            $row.class = 'unreachable'; [void]$unreachable.Add($id)
        } elseif ($cmsSpecific) {
            if ($admits) {
                $row.class = 'compatible'; $row.compatibleVersion = $admits
                $bounds = ConvertFrom-NuGetRange $admitRange
                if ($bounds -and -not $bounds.max) { $row.notes = @($row.notes) + "The CMS dependency range of $admits ($admitRange) has no upper bound: NuGet allows it with $TargetMajor, but that does not show the release was built for $TargetMajor. Check its release notes." }
            } else {
                $row.class = 'no-target-version'
                if ($exhausted) { $row.notes = @($row.notes) + "Only the newest $maxLookups release lines were checked; an older one could still support $TargetMajor." }
            }
        } else {
            $modern = @($latestTfms | Where-Object { $_ -match '(?i)^(?:\.?NETStandard|netstandard|\.?NETCoreApp|netcoreapp|net\d+\.\d+|net[5-9]\d*$)' })
            $legacy = @($latestTfms | Where-Object { $_ -match '(?i)^(?:\.NETFramework|net[1-4]\d*$)' })
            if ($modern.Count -gt 0 -or $latestTfms.Count -eq 0) { $row.class = 'not-cms-specific' } elseif ($legacy.Count -gt 0) { $row.class = 'framework-only' } else { $row.class = 'not-cms-specific' }
        }
        if ($ref.version) {
            $reg = Get-NuGetRegistrationEntry -PackageId $id -Version $ref.version -DataDir $DataDir
            if ($reg.status -eq 'ok' -and $reg.deprecation) { $row.deprecation = $reg.deprecation }
            elseif ($reg.status -ne 'ok') { $row.notes = @($row.notes) + "registration not readable ($($reg.status)); deprecation unknown" }
        }
        [void]$results.Add($row)
    }
    $patterns = New-Object System.Collections.ArrayList
    $map = [ordered]@{
        'pkg.no-target-version' = @($results | Where-Object { $_.class -eq 'no-target-version' } | ForEach-Object { $_.id })
        'pkg.framework-only-libs' = @($results | Where-Object { $_.class -eq 'framework-only' } | ForEach-Object { $_.id })
        'pkg.renamed-community' = @($results | Where-Object { $_.class -eq 'renamed' -or ($_.deprecation -and $_.deprecation.alternatePackage) } | ForEach-Object { $_.id })
    }
    foreach ($k in $map.Keys) { if (@($map[$k]).Count -gt 0) { [void]$patterns.Add([ordered]@{ pattern = $k; packages = @($map[$k]); files = @($map[$k]).Count; occurrences = @($map[$k]).Count }) } }
    return [ordered]@{
        ok = $true; targetMajor = $TargetMajor; sourceMajor = $SourceMajor
        packages = @($results); patterns = @($patterns); unreachable = @($unreachable)
        notFound = @($results | Where-Object { $_.class -eq 'not-found' } | ForEach-Object { $_.id })
        factStatus = 'package-metadata'
    }
}

# ---------------------------------------------------------------- pattern guidance

function Get-PatternGuidance {
    # The parts of a pattern record that matter for this upgrade: impacts it crosses, options for the target
    # generation, checks, the documentation to consult, and the hits from discovery.
    param([Parameter(Mandatory)][string]$PatternId, [Parameter(Mandatory)][int]$SourceMajor, [Parameter(Mandatory)][int]$TargetMajor, $Hits = @())
    $idx = Get-RegistryIndex
    if (-not $idx.ContainsKey($PatternId)) { throw "Unknown pattern '$PatternId'." }
    $p = $idx[$PatternId]
    $gen = Get-GenerationOfMajor $TargetMajor
    $impacts = Get-RelevantImpacts -Pattern $p -SourceMajor $SourceMajor -TargetMajor $TargetMajor
    $options = @(@($p.handling) | Where-Object { $null -ne $_ -and @($_.targets) -contains $gen })
    $docs = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($s in @(@($impacts | ForEach-Object { @($_.sources) }) + @($options | ForEach-Object { @($_.sources) }))) {
        if ($null -eq $s -or $seen.ContainsKey($s.url)) { continue }
        $seen[$s.url] = $true
        [void]$docs.Add([ordered]@{ url = $s.url; docsVersion = $s.docsVersion; appliesTo = $s.appliesTo; verifiedAt = $s.verifiedAt })
    }
    $involves = @(); if ($p.PSObject.Properties['involves']) { $involves = @($p.involves) }
    return [ordered]@{
        pattern = $p.id; title = $p.title; description = $p.description; kind = $p.kind; area = $p.area; owner = $p.owner; involves = $involves
        status = $p.status; flagOnly = [bool]$p.flagOnly; requiresDecision = [bool]$p.requiresDecision
        sourceMajor = $SourceMajor; targetMajor = $TargetMajor; targetGeneration = $gen
        difficulty = (Get-MaxDifficulty $impacts)
        impacts = @($impacts); options = @($options); otherOptions = @(@($p.handling) | Where-Object { $null -ne $_ -and @($_.targets) -notcontains $gen } | ForEach-Object { $_.id })
        checks = @($p.checks); docs = @($docs)
        hits = @($Hits | Where-Object { $_.pattern -eq $PatternId } | ForEach-Object { [ordered]@{ file = $_.file; line = $_.line; detector = $_.detector; count = $_.count; snippet = $_.snippet } })
        rule = 'Never remove, stub, or disable custom functionality. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.'
    }
}

# ---------------------------------------------------------------- phase composition

function Get-PatternGroup {
    param($Pattern, $Rules)
    $g = $Rules['groups']['backoffice']
    switch ([string]$Pattern.area) {
        'application-framework' { return 'application-framework' }
        'custom-code' { return 'custom-code' }
        'config-auth-integrations' { return 'config-auth-integrations' }
        'content-database' { return 'content-conversion' }
        'build-tests' { return 'functional-verification' }
        'functional-verification' { return 'functional-verification' }
        'deployment-rehearsal' { return 'deployment-rehearsal' }
        'packages-backoffice' {
            if (@($g['excludeIds']) -contains $Pattern.id) { return 'packages' }
            if (@($g['ids']) -contains $Pattern.id) { return 'backoffice' }
            foreach ($pfx in @($g['idPrefixes'])) { if (([string]$Pattern.id).StartsWith([string]$pfx)) { return 'backoffice' } }
            return 'packages'
        }
    }
    return 'custom-code'
}

$script:GroupMeta = @{
    'application-framework' = @{ area = 'application-framework'; owner = 'migrate-application-framework'; label = 'Application and framework' }
    'packages' = @{ area = 'packages-backoffice'; owner = 'migrate-packages-backoffice'; label = 'Packages' }
    'custom-code' = @{ area = 'custom-code'; owner = 'migrate-custom-code'; label = 'Custom code' }
    'backoffice' = @{ area = 'packages-backoffice'; owner = 'migrate-packages-backoffice'; label = 'Backoffice extensions' }
    'config-auth-integrations' = @{ area = 'config-auth-integrations'; owner = 'migrate-config-auth-integrations'; label = 'Configuration, authentication, and integrations' }
    'content-conversion' = @{ area = 'content-database'; owner = 'migrate-content-database'; label = 'Content and data' }
    'functional-verification' = @{ area = 'functional-verification'; owner = 'migrate-build-tests'; label = 'Functional verification' }
    'deployment-rehearsal' = @{ area = 'deployment-rehearsal'; owner = 'deployment-rehearsal'; label = 'Deployment rehearsal' }
}

function New-Criterion { param([string]$Text, [string]$Verification) return [ordered]@{ text = $Text; verification = $Verification } }

function Get-StepOfCrossing {
    param($Steps, [int]$Crosses)
    foreach ($s in $Steps) { if ([int]$s.fromMajor -lt $Crosses -and $Crosses -le [int]$s.toMajor) { return $s } }
    return $null
}

function Get-TargetSteps {
    # Steps that get work for a pattern. Content conversions go to every step whose crossing needs them. Other work
    # goes to every step whose crossing breaks it when the codebase is carried through (in place or staged), and to
    # the final codebase when the path builds a new one. Without a relevant crossing, the last step verifies it.
    param($Steps, $Impacts, [string]$Group, [bool]$HasNewCodebase)
    $last = $Steps[@($Steps).Count - 1]
    if ($Group -in @('functional-verification', 'deployment-rehearsal')) { return ,@($last) }
    if ($HasNewCodebase -and $Group -ne 'content-conversion') { return ,@($last) }
    $out = @()
    foreach ($i in @($Impacts | Sort-Object { [int]$_.crosses })) {
        $s = Get-StepOfCrossing -Steps $Steps -Crosses ([int]$i.crosses)
        if ($s -and @($out | Where-Object { $_.id -eq $s.id }).Count -eq 0) { $out += ,$s }
    }
    if ($out.Count -eq 0) { $out = @($last) }
    return ,$out
}

function Get-ItemVolume {
    # The files and occurrences that count toward the split thresholds: an item may list content-model, data, and
    # generated files (volumeFiles leaves them out); an item without volume fields counts everything.
    param($Item)
    if ($Item -is [System.Collections.IDictionary] -and $Item.Contains('volumeFiles')) { return @{ files = @($Item['volumeFiles']); occurrences = [int]$Item['volumeOccurrences'] } }
    return @{ files = @($Item.files); occurrences = [int]$Item.occurrences }
}

function Split-WorkItems {
    # Splits one group of a step into phases: high-difficulty patterns alone, the rest packed under the thresholds,
    # and a single pattern above the thresholds split into file chunks (at most maxPartsPerPattern of them).
    param($Items, $Rules)
    $maxOcc = [int]$Rules['split']['maxOccurrences']; $maxFiles = [int]$Rules['split']['maxFiles']
    $maxParts = 0; if ($Rules['split'].Contains('maxPartsPerPattern')) { $maxParts = [int]$Rules['split']['maxPartsPerPattern'] }
    $chunks = New-Object System.Collections.ArrayList
    $own = @(); $rest = @()
    foreach ($it in $Items) { if ($Rules['split']['highDifficultyOwnPhase'] -and $it.difficulty -eq 'high') { $own += ,$it } else { $rest += ,$it } }
    $addPatternChunks = {
        param($it, [string]$reason)
        $fileList = @($it.files)
        $vol = Get-ItemVolume $it
        $vFiles = @($vol.files); $vOcc = $vol.occurrences
        $dataFiles = @($fileList | Where-Object { $vFiles -notcontains $_ })
        if ($vFiles.Count -gt $maxFiles -or $vOcc -gt $maxOcc) {
            $parts = [Math]::Max([Math]::Ceiling($vFiles.Count / [double]$maxFiles), [Math]::Ceiling($vOcc / [double]$maxOcc))
            $parts = [Math]::Max(1, [Math]::Min($parts, [Math]::Max(1, $vFiles.Count)))
            $capped = ($maxParts -gt 0 -and $parts -gt $maxParts)
            if ($capped) { $parts = $maxParts }
            $size = [Math]::Ceiling($vFiles.Count / [double]$parts)
            $volume = "volume: $vOcc occurrences in $($vFiles.Count) files exceed $maxOcc occurrences or $maxFiles files"
            if ($capped) { $volume += "; split into the maximum of $maxParts parts" }
            if ($parts -eq 1) { $volume = "volume: $vOcc occurrences in one file; kept as one phase" }
            if ($dataFiles.Count -gt 0) { $volume += " (not counted: $($dataFiles.Count) content-model, data, or generated files, listed in part 1)" }
            for ($k = 0; $k -lt $parts; $k++) {
                $slice = @($vFiles | Select-Object -Skip ($k * $size) -First $size)
                if ($k -eq 0) { $slice = @($slice) + @($dataFiles) }
                [void]$chunks.Add([ordered]@{ items = @($it); files = $slice; part = ($k + 1); parts = $parts; reasons = @($reason, $volume) })
            }
        } else {
            [void]$chunks.Add([ordered]@{ items = @($it); files = $fileList; part = 1; parts = 1; reasons = @($reason) })
        }
    }
    foreach ($it in $own) { & $addPatternChunks $it "high difficulty: $($it.pattern)" }
    $current = @(); $occ = 0; $fileSet = @{}
    $flush = {
        if ($current.Count -gt 0) {
            $fs = @($current | ForEach-Object { @($_.files) } | Sort-Object -Unique)
            $why = 'detector fired'
            [void]$chunks.Add([ordered]@{ items = @($current); files = $fs; part = 1; parts = 1; reasons = @($why) })
        }
    }
    foreach ($it in @($rest | Sort-Object -Property @{ Expression = { (Get-ItemVolume $_).occurrences }; Descending = $true }, @{ Expression = { $_.pattern }; Descending = $false })) {
        $vol = Get-ItemVolume $it
        $itFiles = @($vol.files); $itOcc = $vol.occurrences
        if ($itFiles.Count -gt $maxFiles -or $itOcc -gt $maxOcc) {
            & $flush; $current = @(); $occ = 0; $fileSet = @{}
            & $addPatternChunks $it 'detector fired'
            continue
        }
        $union = @{}; foreach ($k in $fileSet.Keys) { $union[$k] = $true }; foreach ($f in $itFiles) { $union[$f] = $true }
        if ($current.Count -gt 0 -and (($occ + $itOcc) -gt $maxOcc -or $union.Count -gt $maxFiles)) {
            & $flush
            $current = @(); $occ = 0; $fileSet = @{}; $union = @{}; foreach ($f in $itFiles) { $union[$f] = $true }
            $current += ,$it; $occ = $itOcc; $fileSet = $union
            $chunks[$chunks.Count - 1].reasons = @($chunks[$chunks.Count - 1].reasons) + "split: the group exceeds $maxOcc occurrences or $maxFiles files"
            continue
        }
        $current += ,$it; $occ += $itOcc; $fileSet = $union
    }
    & $flush
    return ,($chunks.ToArray())
}

function Get-PhaseComposition {
    # Composes phases from discovery results and the selected path (plan 7.2). Inputs are plain objects:
    #   PatternResult: Find-PatternHits output (patterns, baselineSignals, hits)
    #   Steps: path steps (id, from, to, fromMajor, toMajor, type, kind, codebase, dataMigrations, removals, preparation)
    #   PackageResult: optional Get-PackageCompatibility output
    param([Parameter(Mandatory)]$PatternResult, [Parameter(Mandatory)]$Steps, [Parameter(Mandatory)][int]$SourceMajor, [Parameter(Mandatory)][int]$TargetMajor, [string]$Strategy = '', $PackageResult = $null, [string]$TargetFramework = '')
    $rules = Get-PhaseRules
    $idx = Get-RegistryIndex
    $steps = @($Steps | Where-Object { $null -ne $_ })
    if ($steps.Count -eq 0) { throw 'The selected path has no steps.' }
    $last = $steps[$steps.Count - 1]
    $hasNew = @($steps | Where-Object { $_.codebase -eq 'new' }).Count -gt 0
    # Fired customization patterns with their files.
    $fired = New-Object System.Collections.ArrayList
    # Hit files with their occurrences. Files matching split.volumeExcludeFiles (content-model serialization, data,
    # generated models) are listed but do not count toward the split thresholds.
    $volumeRx = $null; if ($rules['split'].Contains('volumeExcludeFiles')) { $volumeRx = New-GlobRegex @($rules['split']['volumeExcludeFiles']) }
    $hitFiles = @{}
    foreach ($h in @($PatternResult.hits)) {
        if ($null -eq $h) { continue }
        if (-not $hitFiles.ContainsKey($h.pattern)) { $hitFiles[$h.pattern] = @{} }
        $hf = [string]$h.file
        if (-not $hitFiles[$h.pattern].ContainsKey($hf)) { $hitFiles[$h.pattern][$hf] = 0 }
        # On a dictionary, .count would be the number of keys, so read the 'count' entry explicitly.
        $n = $(if ($h -is [System.Collections.IDictionary]) { [int]$h['count'] } else { [int]$h.count })
        $hitFiles[$h.pattern][$hf] += [Math]::Max(1, $n)
    }
    foreach ($p in @($PatternResult.patterns)) {
        if ($null -eq $p) { continue }
        $files = @(); $vFiles = @(); $vOcc = 0
        if ($hitFiles.ContainsKey($p.pattern)) {
            $files = @($hitFiles[$p.pattern].Keys | Sort-Object)
            foreach ($hf in $files) { if (-not ($volumeRx -and $volumeRx.IsMatch($hf))) { $vFiles += $hf; $vOcc += [int]$hitFiles[$p.pattern][$hf] } }
        }
        [void]$fired.Add([ordered]@{ pattern = [string]$p.pattern; files = $files; occurrences = [int]$p.occurrences; volumeFiles = $vFiles; volumeOccurrences = $vOcc })
    }
    if ($PackageResult) {
        foreach ($p in @($PackageResult.patterns)) {
            if (-not $p) { continue }
            $pf = @($p.packages | ForEach-Object { "package:$_" })
            [void]$fired.Add([ordered]@{ pattern = [string]$p.pattern; files = $pf; occurrences = [int]$p.occurrences; volumeFiles = $pf; volumeOccurrences = [int]$p.occurrences })
        }
    }
    $firedIds = @($fired | ForEach-Object { $_.pattern })
    $baselineIds = @(@($PatternResult.baselineSignals) | Where-Object { $_ } | ForEach-Object { [string]$_.pattern })
    # Assign work items to steps and groups.
    $work = @{}
    foreach ($s in $steps) { $work[$s.id] = @{} }
    $decisions = New-Object System.Collections.ArrayList
    foreach ($f in $fired) {
        if (-not $idx.ContainsKey($f.pattern)) { continue }
        $rec = $idx[$f.pattern]
        $rel = Get-RelevantImpacts -Pattern $rec -SourceMajor $SourceMajor -TargetMajor $TargetMajor
        $group = Get-PatternGroup -Pattern $rec -Rules $rules
        $targets = Get-TargetSteps -Steps $steps -Impacts $rel -Group $group -HasNewCodebase $hasNew
        foreach ($s in $targets) {
            $inStep = @($rel | Where-Object { [int]$s.fromMajor -lt [int]$_.crosses -and [int]$_.crosses -le [int]$s.toMajor })
            if ($group -ne 'content-conversion' -and $hasNew) { $inStep = $rel }
            $diff = Get-MaxDifficulty $inStep
            if (-not $work[$s.id].ContainsKey($group)) { $work[$s.id][$group] = @() }
            $work[$s.id][$group] += ,([ordered]@{ pattern = $f.pattern; title = $rec.title; difficulty = $diff; files = @($f.files); occurrences = $f.occurrences; volumeFiles = @($f.volumeFiles); volumeOccurrences = $f.volumeOccurrences })
        }
        if ($rec.requiresDecision -or $rec.flagOnly) {
            $gen = Get-GenerationOfMajor $TargetMajor
            [void]$decisions.Add([ordered]@{
                pattern = $rec.id; title = $rec.title; flagOnly = [bool]$rec.flagOnly
                question = "How should '$($rec.title)' be handled on the target? The plugin does not choose this alone."
                options = @(@($rec.handling) | Where-Object { $_ -and @($_.targets) -contains $gen } | ForEach-Object { [ordered]@{ id = $_.id; option = $_.option; status = $_.status } })
            })
        }
    }
    # Baseline signals join the framework phase of the step whose crossing affects them.
    $baselineByStep = @{}
    foreach ($s in $steps) { $baselineByStep[$s.id] = @() }
    foreach ($b in $baselineIds) {
        if (-not $idx.ContainsKey($b)) { continue }
        $rel = Get-RelevantImpacts -Pattern $idx[$b] -SourceMajor $SourceMajor -TargetMajor $TargetMajor
        foreach ($s in (Get-TargetSteps -Steps $steps -Impacts $rel -Group 'application-framework' -HasNewCodebase $hasNew)) { $baselineByStep[$s.id] += $b }
    }
    $phases = New-Object System.Collections.ArrayList
    $addPhase = {
        param([string]$Group, [string]$Title, $Step, $Patterns, $Criteria, $Reasons, $Files = @())
        $meta = $script:GroupMeta[$Group]
        [void]$phases.Add([ordered]@{ title = $Title; area = $meta.area; owner = $meta.owner; group = $Group; step = $Step.id; patterns = @($Patterns); files = @($Files); reasons = @($Reasons); acceptanceCriteria = @($Criteria) })
    }
    $generic = @(
        (New-Criterion 'The solution builds after this phase (Test-Build.ps1 evidence)' 'automated'),
        (New-Criterion 'No custom functionality was removed, stubbed, or disabled: every deleted project file has a recorded remove-custom-feature approval, and everything not migrated is an unresolved item (New-Checkpoint.ps1 scan)' 'automated'))
    $tfmText = $(if ($TargetFramework) { " for $TargetFramework" } else { '' })
    foreach ($s in $steps) {
        $isLast = ($s.id -eq $last.id)
        $kinds = @($s.kind)
        $range = "$($s.from) to $($s.to)"
        $stepWork = $work[$s.id]
        $hasWork = ($stepWork.Keys.Count -gt 0)
        # Framework criteria for the step.
        $afCriteria = @(
            (New-Criterion "The solution builds$tfmText with views precompiled (Test-Build.ps1 evidence)" 'automated'),
            (New-Criterion "CMS packages reference $($s.to) only" 'automated'))
        foreach ($rm in @($s.removals)) { if ($rm) { $afCriteria += ,(New-Criterion "Documented removal handled: $($rm.text) (source: $($rm.source))" 'manual') } }
        foreach ($pp in @($s.preparation)) { if ($pp) { $afCriteria += ,(New-Criterion "Documented preparation done: $($pp.text) (source: $($pp.source))" 'manual') } }
        $dbCriteria = @(
            (New-Criterion 'A snapshot of the declared local database copy exists from before this migration (Invoke-DatabaseSnapshot.ps1 evidence, approval db-snapshot-local)' 'automated'),
            (New-Criterion "The upgrade to $($s.to) ran on the declared local copy only, with a recorded db-migration-local approval, and the redacted log shows no migration errors" 'manual'))
        foreach ($dm in @($s.dataMigrations)) { if ($dm) { $dbCriteria += ,(New-Criterion "Documented data migration completed and content checked: $($dm.title) (source: $($dm.source))" 'manual') } }
        foreach ($rec in @($idx.Values | Where-Object { $_.detection -eq 'database-review' -and $_.PSObject.Properties['appliesWhen'] })) {
            $aw = $rec.appliesWhen; $ok = $true
            if ($aw.PSObject.Properties['pathHasDatabaseStep'] -and $aw.pathHasDatabaseStep -and $kinds -notcontains 'database') { $ok = $false }
            if ($aw.PSObject.Properties['maxSourceMajor'] -and $SourceMajor -gt [int]$aw.maxSourceMajor) { $ok = $false }
            if ($aw.PSObject.Properties['anyPattern'] -and @(@($aw.anyPattern) | Where-Object { $firedIds -contains $_ }).Count -eq 0) { $ok = $false }
            if ($ok) { foreach ($c in @($rec.checks)) { $dbCriteria += ,(New-Criterion "$($c.text) ($($rec.id))" $c.verification) } }
        }
        if ($s.type -eq 'minor-in-place' -and $rules['combineMinorSteps'] -and -not $hasWork -and -not $isLast) {
            & $addPhase 'application-framework' "Minor update to $($s.to): packages and database migration on the local copy" $s @() (@($afCriteria) + @($dbCriteria)) @("mandatory: path step $($s.id) ($($s.type))")
            continue
        }
        # 1. Framework (new project, or packages and startup in place).
        $afTitle = "Packages, framework, and startup: $range"
        if ($s.codebase -eq 'new' -and $s.type -eq 'content-migration-new-install') { $afTitle = "New $($s.to) installation for the content migration" }
        elseif ($s.codebase -eq 'new') { $afTitle = "New $($s.to) project that reuses the database" }
        $afPatterns = @(); $afReasons = @("mandatory: path step $($s.id) ($($s.type))")
        $afItems = @(); if ($stepWork.ContainsKey('application-framework')) { $afItems = @($stepWork['application-framework']) }
        $afCritAll = @($afCriteria)
        foreach ($it in $afItems) { $afPatterns += $it.pattern; foreach ($c in @($idx[$it.pattern].checks)) { $afCritAll += ,(New-Criterion $c.text $c.verification) } }
        foreach ($b in @($baselineByStep[$s.id])) {
            if (-not $b -or $afPatterns -contains $b) { continue }
            $afPatterns += $b
            foreach ($c in @($idx[$b].checks)) { $afCritAll += ,(New-Criterion "$($c.text) ($b)" $c.verification) }
        }
        $afHigh = @($afItems | Where-Object { $_.difficulty -eq 'high' })
        if ($afItems.Count -gt 0) { $afReasons += "detectors fired: $(@($afItems | ForEach-Object { $_.pattern }) -join ', ')" }
        & $addPhase 'application-framework' $afTitle $s $afPatterns $afCritAll $afReasons @($afItems | ForEach-Object { @($_.files) } | Sort-Object -Unique)
        $stepPhases = New-Object System.Collections.ArrayList
        # 2. Database early for a new codebase (the new project boots on the migrated copy before code is ported).
        $dbTitle = "Database migration on the local copy: $range"
        if ($s.type -eq 'content-migration-new-install') { $dbTitle = "Content migration into the new $($s.to) installation (local copy)" }
        $dbDone = $false
        if ($s.codebase -eq 'new' -and $kinds -contains 'database') {
            & $addPhase 'content-conversion' $dbTitle $s @() $dbCriteria @("mandatory: path step $($s.id) has a database migration")
            $dbDone = $true
        }
        # 3. Templates and views rebuilt where custom code is ported onto a new codebase.
        if ($isLast -and $hasNew) {
            & $addPhase 'custom-code' 'Templates, views, and configuration rebuilt on the new codebase' $s @() @(
                (New-Criterion 'Every template and partial view renders on the local site (compare pages before and after)' 'manual'),
                (New-Criterion 'Configuration is mapped to appsettings.json with secrets in a secret store' 'manual'),
                $generic[0], $generic[1]) @('mandatory: the path crosses to a new codebase; templates and custom code are reimplemented')
        }
        # 4. Pattern groups in dependency order.
        foreach ($g in @('packages', 'custom-code', 'backoffice', 'config-auth-integrations', 'content-conversion')) {
            if (-not $stepWork.ContainsKey($g)) { continue }
            $chunks = Split-WorkItems -Items @($stepWork[$g]) -Rules $rules
            foreach ($ch in $chunks) {
                $titles = @($ch.items | ForEach-Object { $_.title })
                $label = $script:GroupMeta[$g].label
                $name = $(if ($titles.Count -le 3) { $titles -join ', ' } else { (($titles | Select-Object -First 3) -join ', ') + " and $($titles.Count - 3) more" })
                $title = "${label}: $name"
                if ($ch.parts -gt 1) { $title += " (part $($ch.part) of $($ch.parts))" }
                if ($steps.Count -gt 1) { $title += " ($range)" }
                $crit = @()
                foreach ($it in $ch.items) {
                    foreach ($c in @($idx[$it.pattern].checks)) { $crit += ,(New-Criterion $c.text $c.verification) }
                    $r = $idx[$it.pattern]
                    if ($r.requiresDecision -or $r.flagOnly) { $crit += ,(New-Criterion "The user's decision for '$($r.title)' is recorded before any change" 'manual') }
                }
                $crit += $generic
                & $addPhase $g $title $s @($ch.items | ForEach-Object { $_.pattern }) $crit $ch.reasons $ch.files
            }
        }
        # 5. Database migration of an in-place step, after the code builds.
        if (-not $dbDone -and $kinds -contains 'database') {
            & $addPhase 'content-conversion' $dbTitle $s @() $dbCriteria @("mandatory: path step $($s.id) has a database migration")
        }
        if ($isLast) {
            # 6. Functional verification for projects with several customizations or runtime-only risks.
            $fvRule = $rules['functionalVerification']
            $involved = @($fired | Where-Object { $idx.ContainsKey($_.pattern) -and $idx[$_.pattern].PSObject.Properties['involves'] -and @($idx[$_.pattern].involves) -contains $fvRule['whenInvolves'] } | ForEach-Object { $_.pattern })
            $fvItems = @(); if ($stepWork.ContainsKey('functional-verification')) { $fvItems = @($stepWork['functional-verification']) }
            if ($fired.Count -ge [int]$fvRule['minCustomizationPatterns'] -or $involved.Count -gt 0 -or $fvItems.Count -gt 0) {
                $crit = @(
                    (New-Criterion 'A user of each backoffice group logs in and completes a typical task on the local site' 'manual'),
                    (New-Criterion 'A page of each content type renders on the local site, and media and forms work' 'manual'),
                    (New-Criterion 'The site log shows no new errors after a browse of the main pages' 'manual'),
                    (New-Criterion 'Automated tests of the solution pass, where they exist (Test-Build.ps1 -Test evidence)' 'automated'))
                foreach ($fvId in @($involved + @($fvItems | ForEach-Object { $_.pattern }) | Sort-Object -Unique)) { foreach ($c in @($idx[$fvId].checks)) { $crit += ,(New-Criterion "$($c.text) ($fvId)" $c.verification) } }
                $why = @(); if ($involved.Count -gt 0) { $why += "runtime-only risks: $($involved -join ', ')" }; if ($fired.Count -ge [int]$fvRule['minCustomizationPatterns']) { $why += "$($fired.Count) customization patterns" }
                & $addPhase 'functional-verification' 'Functional verification of content, media, backoffice, and front end' $s @($involved + @($fvItems | ForEach-Object { $_.pattern }) | Sort-Object -Unique) $crit $why
            }
            # 7. Deployment rehearsal when deployment-related patterns fired.
            if ($stepWork.ContainsKey('deployment-rehearsal')) {
                $items = @($stepWork['deployment-rehearsal'])
                $crit = @((New-Criterion 'The user rehearsed the deployment on a non-production target; the plugin deployed nothing' 'manual'))
                foreach ($it in $items) { foreach ($c in @($idx[$it.pattern].checks)) { $crit += ,(New-Criterion $c.text $c.verification) } }
                & $addPhase 'deployment-rehearsal' 'Deployment rehearsal and production readiness' $s @($items | ForEach-Object { $_.pattern }) $crit @("detectors fired: $(@($items | ForEach-Object { $_.pattern }) -join ', ')") @($items | ForEach-Object { @($_.files) } | Sort-Object -Unique)
            }
        }
    }
    # Number phases and criteria.
    $n = 0
    foreach ($p in $phases) {
        $n++
        $p.id = "P$n"
        $m = 0; $seenText = @{}
        $crit = New-Object System.Collections.ArrayList
        foreach ($c in @($p.acceptanceCriteria)) {
            if ($null -eq $c -or $seenText.ContainsKey($c.text)) { continue }
            $seenText[$c.text] = $true
            $m++
            [void]$crit.Add([ordered]@{ id = "P$n-AC$m"; text = $c.text; verification = $c.verification })
        }
        $p.acceptanceCriteria = @($crit)
    }
    $ordered = foreach ($p in $phases) { [ordered]@{ id = $p.id; title = $p.title; area = $p.area; owner = $p.owner; step = $p.step; patterns = @($p.patterns); files = @($p.files); reasons = @($p.reasons); acceptanceCriteria = @($p.acceptanceCriteria) } }
    return [ordered]@{
        ok = $true
        sourceMajor = $SourceMajor; targetMajor = $TargetMajor; strategy = $Strategy
        rules = [ordered]@{ maxOccurrences = $rules['split']['maxOccurrences']; maxFiles = $rules['split']['maxFiles']; highDifficultyOwnPhase = $rules['split']['highDifficultyOwnPhase']; codePort = $(if ($hasNew) { 'final-codebase' } else { 'each-breaking-step' }) }
        summary = [ordered]@{ phases = @($ordered).Count; customizationPatterns = $fired.Count; steps = $steps.Count; baselineSignals = @($baselineIds) }
        phases = @($ordered)
        decisions = @($decisions)
        notes = @('Phases are a proposal for the plan. The planning skill may merge or rename them, but must keep every pattern and every mandatory criterion, and must say why in plan.md.')
    }
}

function ConvertTo-StatePhases {
    # Only the fields state.json accepts for a phase.
    param($Composition)
    return @(@($Composition.phases) | ForEach-Object {
        [ordered]@{ id = $_.id; title = $_.title; area = $_.area; patterns = @($_.patterns); acceptanceCriteria = @(@($_.acceptanceCriteria) | ForEach-Object { [ordered]@{ id = $_.id; text = $_.text; verification = $_.verification } }) }
    })
}

Export-ModuleMember -Function Get-PhaseRules, Get-GenerationOfMajor, Get-RelevantImpacts, Get-MaxDifficulty, ConvertFrom-NuGetRange, Test-NuGetRangeAdmitsMajor, Test-CmsDependencyAdmitsMajor, Get-ProjectPackageReferences, Get-PackageCompatibility, Get-PatternGuidance, Get-PhaseComposition, ConvertTo-StatePhases, Split-WorkItems
