# Verification.psm1 - gate 5 (A8): composes the verification checklist for a project from the rules in
# knowledge/planning/verification-rules.json and runs the automated checks. Manual checks are answered by the user
# and recorded through state.ps1 verify-check; this module never records a manual result.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NuGet.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Planning.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Reconcile.psm1') -DisableNameChecking

$script:PluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:MaxFilesPerPattern = 10

function Get-VerificationRules { return (ConvertTo-PlainObject (Read-JsonFile (Join-Path $script:PluginRoot 'knowledge/planning/verification-rules.json'))) }

function Get-FiredPatterns {
    # Customization patterns that discovery and the package check found, each with the files they were found in.
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $dir = Get-StateDir $ProjectRoot
    $out = [ordered]@{}
    $pf = Join-Path $dir 'evidence/discovery/patterns.json'
    if ([System.IO.File]::Exists($pf)) {
        $p = ConvertTo-PlainObject (Read-JsonFile $pf)
        foreach ($s in @($p['patterns'])) { if ($s) { $out[[string]$s['pattern']] = New-Object System.Collections.ArrayList } }
        foreach ($h in @($p['hits'])) {
            if (-not $h) { continue }
            $id = [string]$h['pattern']
            if ($out.Contains($id) -and -not $out[$id].Contains([string]$h['file'])) { [void]$out[$id].Add([string]$h['file']) }
        }
    }
    $cf = Join-Path $dir 'evidence/planning/package-compatibility.json'
    if ([System.IO.File]::Exists($cf)) {
        $c = ConvertTo-PlainObject (Read-JsonFile $cf)
        foreach ($s in @($c['patterns'])) {
            if (-not $s) { continue }
            $id = [string]$s['pattern']
            if (-not $out.Contains($id)) { $out[$id] = New-Object System.Collections.ArrayList }
            foreach ($pkg in @($s['packages'])) { if ($pkg) { [void]$out[$id].Add("package $pkg") } }
        }
    }
    return $out
}

function Test-RuleApplies {
    # Returns the reasons a rule applies (empty when it does not).
    param($Rule, $Fired)
    $when = $Rule['appliesWhen']
    if ($when.Contains('always') -and $when['always']) { return ,@('applies to every upgrade') }
    $reasons = New-Object System.Collections.ArrayList
    foreach ($id in @($Fired.Keys)) {
        $match = $false
        if ($when.Contains('patterns') -and @($when['patterns']) -contains $id) { $match = $true }
        if ($when.Contains('patternPrefixes')) { foreach ($pre in @($when['patternPrefixes'])) { if ($id.StartsWith([string]$pre)) { $match = $true } } }
        if (-not $match) { continue }
        $files = @($Fired[$id])
        $shown = @($files | Select-Object -First $script:MaxFilesPerPattern)
        $more = $(if ($files.Count -gt $shown.Count) { " and $($files.Count - $shown.Count) more" } else { '' })
        [void]$reasons.Add($(if ($shown.Count) { "detected $id in $($shown -join ', ')$more" } else { "detected $id" }))
    }
    return ,($reasons.ToArray())
}

function New-VerificationPlan {
    # The checklist for this project, in rule order, with ids V-01, V-02, ... (state shape).
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $rules = Get-VerificationRules
    $fired = Get-FiredPatterns -ProjectRoot $ProjectRoot
    $checks = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($r in @($rules['checks'])) {
        $why = Test-RuleApplies -Rule $r -Fired $fired
        if (@($why).Count -eq 0) { continue }
        $n++
        $c = [ordered]@{ id = ('V-{0:00}' -f $n); rule = $r['rule']; category = $r['category']; title = $r['title']; method = $r['method']
            how = $(if ($r.Contains('how')) { $r['how'] } else { $null }); steps = @($(if ($r.Contains('steps')) { $r['steps'] } else { @() }))
            appliesBecause = @($why); risk = $r['risk']; nextStep = $r['nextStep']; result = 'pending'; evidence = @(); note = $null; recovery = $null; recordedAt = $null }
        [void]$checks.Add($c)
    }
    return ,($checks.ToArray())
}

function ConvertTo-ManualChecklist {
    # The manual checklist as Markdown, from skills/verification/templates/manual-checklist.md.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Checks)
    $template = Read-TextFile (Join-Path $script:PluginRoot 'skills/verification/templates/manual-checklist.md')
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in @($Checks | Where-Object { $_['method'] -eq 'manual' })) {
        [void]$sb.Append("### $($c['id']) $($c['title'])`n`n")
        [void]$sb.Append("Applies because: $((@($c['appliesBecause'])) -join '; ').`n`n")
        $i = 0
        foreach ($s in @($c['steps'])) { $i++; [void]$sb.Append("$i. $s`n") }
        [void]$sb.Append("`nIf it fails: $($c['nextStep'])`n`nResult: verified / failed / not verified, and why: `n`n")
    }
    $target = [string]$State['target']['resolved']; if (-not $target) { $target = [string]$State['target']['requested'] }
    $text = $template.Replace('{{source}}', [string]$State['source']['umbraco']).Replace('{{target}}', $target)
    $text = $text.Replace('{{branch}}', [string]$State['gitBaseline']['upgradeBranch']).Replace('{{date}}', (Get-UtcTimestamp))
    $text = $text.Replace('{{checks}}', $sb.ToString().TrimEnd() + "`n")
    return (Protect-Text $text)
}

# ---------------------------------------------------------------- automated checks

function New-CheckResult {
    param([ValidateSet('verified', 'failed', 'not-verified', 'pending')][string]$Result, [string]$Note, $Detail = $null, [string[]]$ExtraEvidence = @())
    return [ordered]@{ result = $Result; note = $Note; detail = $Detail; extraEvidence = @($ExtraEvidence) }
}

function Get-LatestFinalBuild {
    # The newest build summary in evidence/final/ written after gate 5 started, or $null.
    param([string]$ProjectRoot, $State)
    $dir = Join-Path (Get-StateDir $ProjectRoot) 'evidence/final'
    if (-not [System.IO.Directory]::Exists($dir)) { return $null }
    $since = [string]$State['gates']['final']['at']
    $best = $null
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter 'build-*.json' -File | Sort-Object Name)) {
        try { $b = ConvertTo-PlainObject (Read-JsonFile $f.FullName) } catch { continue }
        if ($since -and [string]$b['at'] -lt $since) { continue }
        $best = [ordered]@{ summary = $b; path = "evidence/final/$($f.Name)" }
    }
    return $best
}

function Get-TestProjects {
    param([string]$Root)
    $found = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ProjectFiles -Root $Root)) {
        if ($f -notmatch '(?i)\.(cs|vb|fs)proj$') { continue }
        $t = Read-TextFile $f
        if ($t -match '(?i)Microsoft\.NET\.Test\.Sdk|<IsTestProject>\s*true\s*</IsTestProject>') { [void]$found.Add((Get-RelativePathCompat -BasePath $Root -Path $f)) }
    }
    return ,($found.ToArray())
}

function Test-FinalBuild {
    param([string]$ProjectRoot, $State)
    $b = Get-LatestFinalBuild -ProjectRoot $ProjectRoot -State $State
    $tests = Get-TestProjects -Root $ProjectRoot
    $out = [ordered]@{}
    if ($null -eq $b) {
        $out['build'] = New-CheckResult 'pending' 'No gate 5 build evidence yet: run Test-Build.ps1 -PhaseId final -Precompile first.'
        $out['tests'] = New-CheckResult 'pending' 'No gate 5 build evidence yet: run Test-Build.ps1 -PhaseId final -Precompile -Test first.'
        return $out
    }
    $s = $b.summary
    $ev = @($b.path) + @($s['evidence'] | Where-Object { $_ -and $_ -ne $b.path })
    $code = [int]$s['build']['exitCode']
    if ($code -ne 0) { $out['build'] = New-CheckResult 'failed' "The build failed (exit code $code, $($s['build']['errors']) error lines)." $s['build'] $ev }
    elseif (-not $s['precompiledViews']) { $out['build'] = New-CheckResult 'not-verified' 'The gate 5 build ran without view compilation; run Test-Build.ps1 -PhaseId final -Precompile.' $s['build'] $ev }
    else { $out['build'] = New-CheckResult 'verified' "The solution builds with views compiled ($($s['build']['warnings']) warning lines)." $s['build'] $ev }
    if ($tests.Count -eq 0) { $out['tests'] = New-CheckResult 'not-verified' 'The solution has no test projects (none references Microsoft.NET.Test.Sdk or sets IsTestProject).' ([ordered]@{ testProjects = @() }) }
    elseif ($s['tests'] -is [System.Collections.IDictionary]) {
        $tc = [int]$s['tests']['exitCode']
        if ($tc -eq 0) { $out['tests'] = New-CheckResult 'verified' "dotnet test passed for $($tests.Count) test project(s)." ([ordered]@{ testProjects = $tests; exitCode = $tc }) $ev }
        else { $out['tests'] = New-CheckResult 'failed' "dotnet test failed (exit code $tc)." ([ordered]@{ testProjects = $tests; exitCode = $tc }) $ev }
    } elseif ($code -ne 0) { $out['tests'] = New-CheckResult 'not-verified' 'The tests did not run because the build failed.' ([ordered]@{ testProjects = $tests }) $ev }
    else { $out['tests'] = New-CheckResult 'pending' "The solution has $($tests.Count) test project(s), but the gate 5 build ran without -Test." ([ordered]@{ testProjects = $tests }) }
    return $out
}

function Test-FinalCmsVersion {
    param([string]$ProjectRoot, $State)
    $v = Get-UmbracoVersionInfo -Root $ProjectRoot
    $want = [string]$State['target']['resolved']
    $tfm = [string]$State['target']['dotnet']
    $detail = [ordered]@{ expected = $want; detected = $v.resolved.version; confidence = $v.resolved.confidence; expectedFramework = $tfm; frameworks = @($v.targetFrameworks) }
    if (-not $want) { return (New-CheckResult 'not-verified' 'State records no resolved target version.' $detail) }
    if ($v.resolved.confidence -eq 'conflict') { return (New-CheckResult 'failed' "The project files name different CMS versions: $(@($v.resolved.candidates) -join ', ')." $detail) }
    if ($v.resolved.version -ne $want) { return (New-CheckResult 'failed' "The project references $($v.resolved.version), not the target $want." $detail) }
    if ($tfm -and @($v.targetFrameworks) -notcontains $tfm) { return (New-CheckResult 'failed' "The target frameworks are $(@($v.targetFrameworks) -join ', '), not $tfm." $detail) }
    return (New-CheckResult 'verified' "The project references $want on $tfm." $detail)
}

function Test-FinalPackageRanges {
    param([string]$ProjectRoot, $State, [string]$DataDir)
    $targetMajor = Get-VersionMajor ([string]$State['target']['resolved'])
    $rules = (Get-PhaseRules)['packages']
    $cmsId = New-Object System.Text.RegularExpressions.Regex([string]$rules['cmsPackageIdPattern'], 'IgnoreCase')
    $cmsDep = New-Object System.Text.RegularExpressions.Regex([string]$rules['cmsDependencyIdPattern'], 'IgnoreCase')
    $src = (Get-KnowledgeFile -Kind sources -DataDir $DataDir).data
    Set-NuGetEndpoints -FlatContainer $src['nuget']['flatContainer'] -Registration $src['nuget']['registration']
    $rows = New-Object System.Collections.ArrayList
    $depCache = @{}
    foreach ($ref in (Get-ProjectPackageReferences -Root $ProjectRoot)) {
        $id = [string]$ref.id
        $row = [ordered]@{ id = $id; version = $ref.version; file = $ref.file; status = $null; ranges = @() }
        if ($cmsId.IsMatch($id)) { $row.status = 'core'; [void]$rows.Add($row); continue }
        if (-not $ref.version) { $row.status = 'no-version'; [void]$rows.Add($row); continue }
        if ([string]$ref.version -match '[\*\[\(,]') { $row.status = 'floating-version'; [void]$rows.Add($row); continue }
        $ns = Get-NuGetNuspec -PackageId $id -Version ([string]$ref.version) -DataDir $DataDir
        if ($ns.status -eq 'http-404') { $row.status = 'not-found'; [void]$rows.Add($row); continue }
        if ($ns.status -ne 'ok' -or -not $ns.nuspec) { $row.status = 'unreachable'; [void]$rows.Add($row); continue }
        $deps = @($ns.nuspec.dependencies | Where-Object { $_ -and $cmsDep.IsMatch([string]$_.id) })
        $row.ranges = @($deps | ForEach-Object { "$($_.id) $($_.range)" } | Sort-Object -Unique)
        if ($deps.Count -eq 0) { $row.status = 'not-cms-specific' }
        else {
            # A range only counts when the dependency package has a release of the target major.
            $res = @($deps | ForEach-Object { Test-CmsDependencyAdmitsMajor -Dependency $_ -Major $targetMajor -DataDir $DataDir -Cache $depCache })
            if ($res -contains 'admits') { $row.status = 'admits-target' }
            elseif ($res -contains 'unknown') { $row.status = 'unreachable' }
            else { $row.status = 'excludes-target' }
        }
        [void]$rows.Add($row)
    }
    $bad = @($rows | Where-Object { $_.status -eq 'excludes-target' } | ForEach-Object { "$($_.id) $($_.version)" })
    $unknown = @($rows | Where-Object { $_.status -in @('not-found', 'unreachable', 'no-version', 'floating-version') } | ForEach-Object { "$($_.id) ($($_.status))" })
    $detail = [ordered]@{ targetMajor = $targetMajor; packages = @($rows) }
    if ($bad.Count -gt 0) { return (New-CheckResult 'failed' "These references declare CMS ranges that exclude $targetMajor`: $($bad -join ', ')." $detail) }
    if ($unknown.Count -gt 0) { return (New-CheckResult 'not-verified' "The metadata of these references could not be checked: $($unknown -join ', ')." $detail) }
    return (New-CheckResult 'verified' "$(@($rows).Count) package reference(s) checked; every CMS-specific one admits $targetMajor." $detail)
}

function Test-FinalPhaseCriteria {
    param($State)
    $rows = New-Object System.Collections.ArrayList
    $deferred = @(); $open = @(); $waived = @()
    foreach ($p in @($State['phases'])) {
        $crit = @($p['acceptanceCriteria'])
        $notDone = @($crit | Where-Object { $_['status'] -notin @('met', 'waived') } | ForEach-Object { $_['id'] })
        foreach ($c in $crit) { if ($c['status'] -eq 'waived') { $waived += $c['id'] } }
        if ($p['status'] -eq 'deferred') { $deferred += $p['id'] }
        elseif ($p['status'] -ne 'done' -or $notDone.Count -gt 0) { $open += $p['id'] }
        [void]$rows.Add([ordered]@{ phase = $p['id']; status = $p['status']; criteria = $crit.Count; met = @($crit | Where-Object { $_['status'] -eq 'met' }).Count; waived = @($crit | Where-Object { $_['status'] -eq 'waived' }).Count; open = $notDone })
    }
    $detail = [ordered]@{ phases = @($rows); waivedCriteria = $waived }
    if ($open.Count -gt 0) { return (New-CheckResult 'failed' "Phases not done with their criteria: $($open -join ', ')." $detail) }
    if ($deferred.Count -gt 0) { return (New-CheckResult 'not-verified' "Deferred phases: $($deferred -join ', '). Their work is not part of this upgrade's evidence." $detail) }
    $w = $(if ($waived.Count) { " Waived by the user: $($waived -join ', ')." } else { '' })
    return (New-CheckResult 'verified' "All $(@($rows).Count) phase(s) are done with their criteria met or waived.$w" $detail)
}

function Test-FinalCheckpoints {
    param([string]$ProjectRoot, $State)
    $problems = New-Object System.Collections.ArrayList
    $gb = $State['gitBaseline']
    $branch = Get-GitRepoInfo -Root $ProjectRoot
    if (-not $branch.isRepo) { return (New-CheckResult 'not-verified' 'The project is not a git repository.' $null) }
    if ($branch.branch -ne [string]$gb['upgradeBranch']) { [void]$problems.Add("on '$($branch.branch)', not on the upgrade branch '$($gb['upgradeBranch'])'") }
    foreach ($p in @($State['phases'])) {
        if ($p['status'] -ne 'done') { continue }
        $sha = [string]$p['checkpoint']['commit']
        if (-not $sha -or -not (Test-CommitExists $ProjectRoot $sha)) { [void]$problems.Add("checkpoint of $($p['id']) not found"); continue }
        if ((Test-IsAncestor $ProjectRoot $sha 'HEAD') -ne $true) { [void]$problems.Add("checkpoint of $($p['id']) is not part of HEAD") }
    }
    $all = Get-GitStatusEntries -Root $ProjectRoot -Prefix $branch.prefix
    $dirty = @($all | Where-Object { -not $_.inStateFolder } | ForEach-Object { $_.path })
    if ($dirty.Count -gt 0) { [void]$problems.Add("$($dirty.Count) uncommitted change(s) outside .umbraco-upgrade/: $(@($dirty | Select-Object -First 10) -join ', ')") }
    $detail = [ordered]@{ branch = $branch.branch; head = $branch.head; problems = @($problems) }
    if ($problems.Count -gt 0) { return (New-CheckResult 'failed' ($problems -join '; ') $detail) }
    return (New-CheckResult 'verified' 'Every done phase''s checkpoint is part of HEAD on the upgrade branch, and the tree is clean outside .umbraco-upgrade/.' $detail)
}

function Test-IgnoredUpgradePath { param([string]$Path) return ($Path -match '(?i)(^|/)\.umbraco-upgrade/' -or $Path -match '(?i)(^|/)(bin|obj)/') }

function Get-BranchChanges {
    # Changes from the base commit to HEAD, project-relative: deleted files and added lines (read-only git diff).
    param([string]$ProjectRoot, [string]$Base)
    $names = Invoke-GitCommand -Root $ProjectRoot -Arguments @('diff', '--relative', '--name-status', '--no-renames', $Base, 'HEAD', '--', '.') -TimeoutSeconds 300
    if ($names.exitCode -ne 0) { throw ('git diff failed: ' + (Protect-Text ([string]$names.stderr))) }
    $deleted = New-Object System.Collections.ArrayList
    foreach ($l in $names.stdout) { if ($l -match '^D\t(.+)$' -and -not (Test-IgnoredUpgradePath $Matches[1])) { [void]$deleted.Add($Matches[1]) } }
    $diff = Invoke-GitCommand -Root $ProjectRoot -Arguments @('diff', '--relative', '-U0', '--no-color', '--no-renames', $Base, 'HEAD', '--', '.') -TimeoutSeconds 300
    if ($diff.exitCode -ne 0) { throw ('git diff failed: ' + (Protect-Text ([string]$diff.stderr))) }
    $added = New-Object System.Collections.ArrayList
    $removedPerFile = @{}; $addedPerFile = @{}
    $file = $null
    foreach ($l in $diff.stdout) {
        if ($l.StartsWith('+++ ')) { $file = ($l.Substring(4) -replace '^b/', ''); if ($file -eq '/dev/null') { $file = $null }; continue }
        if ($l.StartsWith('--- ')) { continue }
        if (-not $file -or (Test-IgnoredUpgradePath $file)) { continue }
        if ($l.StartsWith('+')) { [void]$added.Add([ordered]@{ file = $file; text = $l.Substring(1) }); $addedPerFile[$file] = 1 + [int]$addedPerFile[$file] }
        elseif ($l.StartsWith('-')) { $removedPerFile[$file] = 1 + [int]$removedPerFile[$file] }
    }
    return [ordered]@{ deleted = @($deleted); added = @($added); removedPerFile = $removedPerFile; addedPerFile = $addedPerFile }
}

function Test-FinalNoRemoval {
    param([string]$ProjectRoot, $State, $Changes)
    $approvals = @(@($State['approvals']) | Where-Object { $_['action'] -eq 'remove-custom-feature' -and $_['decision'] -eq 'approved' })
    $uncovered = New-Object System.Collections.ArrayList
    $covered = New-Object System.Collections.ArrayList
    foreach ($d in @($Changes.deleted)) {
        $hit = $null
        foreach ($a in $approvals) {
            foreach ($s in (([string]$a['scope']) -split ';')) {
                $s2 = $s.Trim().Trim('/').Replace('\', '/')
                if ($s2 -and ($d -ieq $s2 -or $d.StartsWith($s2 + '/', [System.StringComparison]::OrdinalIgnoreCase))) { $hit = $a; break }
            }
            if ($hit) { break }
        }
        if ($hit) { [void]$covered.Add("$d ($($hit['id']))") } else { [void]$uncovered.Add($d) }
    }
    $stubs = New-Object System.Collections.ArrayList
    $review = New-Object System.Collections.ArrayList
    foreach ($a in @($Changes.added)) {
        if ($a.text -match '\bthrow\s+new\s+(?:System\.)?NotImplementedException\b' -or $a.text -match '^\s*#\s*if\s+false\b') { [void]$stubs.Add("$($a.file): $((Protect-Text $a.text).Trim())") }
        elseif ($a.text -match '^\s*(//|\*|@\*).*(;|\)|\})\s*$' -and $a.text -notmatch '^\s*///') { [void]$review.Add("possible disabled code in $($a.file): $((Protect-Text $a.text).Trim())") }
        elseif ($a.file -match '(?i)\.(csproj|vbproj|props|targets)$' -and $a.text -match '(?i)<Compile\s+Remove\s*=') { [void]$review.Add("files excluded from compilation in $($a.file): $((Protect-Text $a.text).Trim())") }
    }
    foreach ($f in $Changes.removedPerFile.Keys) { if ([int]$Changes.removedPerFile[$f] -ge 20 -and [int]$Changes.addedPerFile[$f] -lt 3) { [void]$review.Add("$f lost $($Changes.removedPerFile[$f]) lines and gained $([int]$Changes.addedPerFile[$f])") } }
    $detail = [ordered]@{ deletedWithApproval = @($covered); deletedWithoutApproval = @($uncovered); stubs = @($stubs); toReview = @($review | Select-Object -First 50) }
    if ($uncovered.Count -gt 0 -or $stubs.Count -gt 0) {
        $parts = @()
        if ($uncovered.Count -gt 0) { $parts += "deleted without an approval that names them: $(@($uncovered | Select-Object -First 10) -join ', ')" }
        if ($stubs.Count -gt 0) { $parts += "$($stubs.Count) stub line(s) added" }
        return (New-CheckResult 'failed' ($parts -join '; ') $detail)
    }
    $r = $(if ($review.Count) { " $($review.Count) change(s) listed for review in the evidence (commented-out code, excluded files, large removals)." } else { '' })
    return (New-CheckResult 'verified' "No unapproved deletion and no stub since the base commit ($($covered.Count) approved deletion(s)).$r" $detail)
}

function Test-FinalNoSecrets {
    param([string]$ProjectRoot, $State, $Changes)
    $branchFiles = @(@($Changes.added) | Where-Object { (Protect-Text $_.text) -ne $_.text } | ForEach-Object { $_.file } | Sort-Object -Unique)
    $stateFiles = New-Object System.Collections.ArrayList
    $dir = Get-StateDir $ProjectRoot
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.Length -gt 5MB) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($bytes -contains 0) { continue }
        $t = Read-TextFile $f.FullName
        if ((Protect-Text $t) -ne $t) { [void]$stateFiles.Add((Get-RelativePathCompat -BasePath $dir -Path $f.FullName)) }
    }
    $detail = [ordered]@{ branchFiles = @($branchFiles); stateFolderFiles = @($stateFiles) }
    if ($branchFiles.Count -gt 0 -or $stateFiles.Count -gt 0) {
        $parts = @()
        if ($branchFiles.Count) { $parts += "added lines look like secrets in: $($branchFiles -join ', ')" }
        if ($stateFiles.Count) { $parts += ".umbraco-upgrade/ files hold secret-looking values: $(@($stateFiles) -join ', ')" }
        return (New-CheckResult 'failed' ($parts -join '; ') $detail)
    }
    return (New-CheckResult 'verified' 'No secret-looking value in the lines added since the base commit or in .umbraco-upgrade/.' $detail)
}

function Test-FinalUnresolved {
    param($State)
    $items = @($State['unresolved'])
    $open = @($items | Where-Object { $_['status'] -in @('awaiting-user', 'decided') } | ForEach-Object { "$($_['id']) ($($_['status']))" })
    $deferred = @($items | Where-Object { $_['status'] -eq 'deferred' } | ForEach-Object { $_['id'] })
    $detail = [ordered]@{ open = $open; deferred = $deferred; resolved = @($items | Where-Object { $_['status'] -eq 'resolved' } | ForEach-Object { $_['id'] }) }
    if ($open.Count -gt 0) { return (New-CheckResult 'failed' "Open unresolved items: $($open -join ', ')." $detail) }
    $d = $(if ($deferred.Count) { " Deferred by the user: $($deferred -join ', ')." } else { '' })
    return (New-CheckResult 'verified' "No unresolved item is open ($(@($items).Count) recorded).$d" $detail)
}

function Invoke-AutomatedChecks {
    # Runs the automated rules; returns a map rule -> result. -Interim skips the build, version, and package
    # rules (they belong to gate 5) and checks what an in-progress upgrade can already prove.
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$State, [string]$DataDir = '', [switch]$Interim)
    $results = [ordered]@{}
    $base = [string]$State['gitBaseline']['baseCommit']
    $changes = $null
    if ($base -and (Test-CommitExists $ProjectRoot $base)) { $changes = Get-BranchChanges -ProjectRoot $ProjectRoot -Base $base }
    if (-not $Interim) {
        $b = Test-FinalBuild -ProjectRoot $ProjectRoot -State $State
        $results['build'] = $b['build']; $results['tests'] = $b['tests']
        $results['cms-version'] = Test-FinalCmsVersion -ProjectRoot $ProjectRoot -State $State
        try { $results['package-ranges'] = Test-FinalPackageRanges -ProjectRoot $ProjectRoot -State $State -DataDir $DataDir }
        catch { $results['package-ranges'] = New-CheckResult 'not-verified' ('The package metadata could not be read: ' + (Protect-Text $_.Exception.Message)) }
    }
    $results['phase-criteria'] = Test-FinalPhaseCriteria -State $State
    if ($Interim) {
        $done = @(@($State['phases']) | Where-Object { $_['status'] -notin @('done', 'deferred') } | ForEach-Object { $_['id'] })
        $results['phase-criteria'].note = "Interim: phases still open: $($done -join ', '). " + $results['phase-criteria'].note
    }
    $results['checkpoints'] = Test-FinalCheckpoints -ProjectRoot $ProjectRoot -State $State
    if ($null -eq $changes) {
        $results['no-removal'] = New-CheckResult 'not-verified' 'The base commit is not in this repository, so the branch could not be compared with it.'
        $results['no-secrets'] = New-CheckResult 'not-verified' 'The base commit is not in this repository, so the branch could not be compared with it.'
    } else {
        $results['no-removal'] = Test-FinalNoRemoval -ProjectRoot $ProjectRoot -State $State -Changes $changes
        $results['no-secrets'] = Test-FinalNoSecrets -ProjectRoot $ProjectRoot -State $State -Changes $changes
    }
    $results['unresolved'] = Test-FinalUnresolved -State $State
    return $results
}

function Get-VerificationSummary {
    # Counts for the report and the command output.
    param($State)
    $s = [ordered]@{ checks = 0; verifiedAutomatically = 0; verifiedManually = 0; failed = 0; notVerified = 0; pending = 0 }
    if (-not $State.Contains('verification')) { return $s }
    foreach ($c in @($State['verification']['checks'])) {
        $s.checks++
        switch ($c['result']) {
            'verified' { if ($c['method'] -eq 'automated') { $s.verifiedAutomatically++ } else { $s.verifiedManually++ } }
            'failed' { $s.failed++ }
            'not-verified' { $s.notVerified++ }
            default { $s.pending++ }
        }
    }
    return $s
}

Export-ModuleMember -Function Get-VerificationRules, Get-FiredPatterns, New-VerificationPlan, ConvertTo-ManualChecklist, Invoke-AutomatedChecks, Get-VerificationSummary, Get-BranchChanges, Get-TestProjects, Test-FinalPackageRanges
