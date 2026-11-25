# Feedback.psm1 - for /umbraco-upgrade:feedback. Compares an upgrade's plan with what changed in the project since
# the base commit, and checks a public feedback draft for names that identify the project. Read-only on the project.
# The file groups and word lists below are plugin heuristics for sorting files and catching names, not version facts.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Planning.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -DisableNameChecking

# Files every major upgrade touches: project, solution, and package files, startup, and configuration.
$script:FrameworkGlobs = @(
    '**/*.csproj', '**/*.vbproj', '**/*.sln', '**/*.slnx', '**/packages.config', '**/Directory.Packages.props',
    '**/Directory.Build.props', '**/Directory.Build.targets', '**/global.json', '**/nuget.config', '**/packages.lock.json',
    '**/Program.cs', '**/Startup.cs', '**/Global.asax', '**/Global.asax.cs', '**/web.config', '**/web.*.config',
    '**/appsettings*.json', '**/launchSettings.json', '**/*.pubxml'
)
# Build output and front-end build files: counted, not reviewed one by one. The phase rules' volume exclusions
# (serialized content model, application data, generated models) are added to these.
$script:GeneratedGlobs = @('**/bin/**', '**/obj/**', '**/node_modules/**', '**/package-lock.json', '**/yarn.lock', '**/*.map', '**/*.min.js', '**/*.min.css')
$script:Categories = @('planned', 'found-not-planned', 'expected', 'flagged', 'added', 'not-found', 'generated')
$script:StatusNames = @{ M = 'modified'; A = 'added'; D = 'deleted'; R = 'renamed'; C = 'copied'; T = 'modified'; U = 'untracked' }

# Words that appear in project, folder, and remote names without identifying anyone.
$script:GenericWords = @(
    'web', 'website', 'site', 'sites', 'www', 'core', 'common', 'shared', 'api', 'app', 'apps', 'application', 'data', 'dal', 'bll',
    'domain', 'infrastructure', 'business', 'logic', 'model', 'models', 'service', 'services', 'test', 'tests', 'unittests',
    'integrationtests', 'testing', 'ui', 'frontend', 'backend', 'front', 'back', 'end', 'main', 'master', 'develop', 'dev',
    'release', 'live', 'staging', 'qa', 'src', 'source', 'project', 'projects', 'solution', 'library', 'lib', 'libs', 'utils',
    'utilities', 'helpers', 'extensions', 'plugin', 'plugins', 'package', 'packages', 'sample', 'samples', 'samplesite',
    'net', 'dotnet', 'framework', 'mvc', 'cms', 'umbraco', 'umbracocms', 'content', 'forms', 'search', 'admin', 'client',
    'server', 'host', 'hosting', 'local', 'localhost', 'user', 'users', 'home', 'docs', 'git', 'scm', 'defaultcollection',
    '_git', 'azure', 'github', 'gitlab', 'bitbucket', 'visualstudio', 'ssh', 'vs-ssh', 'com', 'org', 'co', 'uk', 'io',
    'info', 'biz', 'the', 'and', 'for', 'new', 'old', 'upgrade', 'backoffice', 'examine', 'usync', 'deploy', 'grid',
    'blocks', 'theme', 'starter', 'starterkit', 'macros', 'delivery', 'console', 'tools', 'build', 'migrations', 'repo',
    'repos', 'repository', 'noreply', 'mail', 'email', 'contact', 'support', 'office', 'example', 'invalid', 'placeholder'
)
$script:PublicGitHosts = @('github.com', 'gitlab.com', 'bitbucket.org', 'dev.azure.com', 'ssh.dev.azure.com', 'vs-ssh.visualstudio.com')
$script:PublicMailDomains = @('gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'yahoo.com', 'icloud.com', 'me.com',
    'proton.me', 'protonmail.com', 'users.noreply.github.com', 'example.com', 'example.org', 'example.net', 'example.invalid')
# Hosts a public draft may name (and their subdomains): official documentation, package feeds, and placeholders.
$script:AllowedDraftHosts = @('umbraco.com', 'nuget.org', 'microsoft.com', 'github.com', 'githubusercontent.com', 'endoflife.date',
    'example.com', 'example.org', 'example.net', 'example.invalid', 'localhost')

function ConvertTo-PathKey { param([string]$Path) return ($Path -replace '\\', '/').ToLowerInvariant() }

function Get-PluginFolderKey {
    # The App_Plugins/<folder> part of a relative path, lower case, with any folders above it; $null outside App_Plugins.
    param([string]$Path)
    $p = $Path -replace '\\', '/'
    if ($p -match '(?i)^((?:.*/)?App_Plugins/[^/]+)/') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Add-ToIndex {
    param([hashtable]$Index, [string]$Key, [string]$Value)
    if (-not $Index.ContainsKey($Key)) { $Index[$Key] = New-Object System.Collections.ArrayList }
    if (-not $Index[$Key].Contains($Value)) { [void]$Index[$Key].Add($Value) }
}

function Test-InsideStateFolder { param([string]$Path) return ([string]$Path).StartsWith('.umbraco-upgrade/', [System.StringComparison]::OrdinalIgnoreCase) }

function Assert-BaseCommit {
    # The base commit recorded in state, checked to exist in the repository.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$State)
    $gb = $State['gitBaseline']
    $base = [string]$gb['baseCommit']
    if (-not $gb['isRepo'] -or -not $base) { throw 'The upgrade state has no base commit: the project was not a git repository with a commit when the upgrade started. Feedback compares the files with that commit, so it cannot run here.' }
    $c = Invoke-GitCommand -Root $Root -Arguments @('cat-file', '-e', ($base + '^{commit}'))
    if ($c.exitCode -ne 0) { throw "The base commit $base recorded in the state is not in this repository. Run feedback in the clone where the upgrade started, or fetch that commit." }
    return $base
}

function Get-ChangedFilesSinceBase {
    # Files that differ between the base commit and the working tree: tracked changes (renames detected) and untracked
    # files, relative to the project root, outside .umbraco-upgrade/.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$BaseCommit)
    $out = New-Object System.Collections.ArrayList
    $d = Invoke-GitCommand -Root $Root -Arguments @('diff', '--name-status', '-M', '--relative', $BaseCommit, '--') -TimeoutSeconds 300
    if ($d.exitCode -ne 0) { throw ('git diff failed: ' + $d.stderr) }
    foreach ($line in $d.stdout) {
        $parts = $line -split "`t"
        if ($parts.Count -lt 2 -or $parts[0].Length -lt 1) { continue }
        $code = $parts[0].Substring(0, 1).ToUpperInvariant()
        $old = $null
        if ($code -in @('R', 'C') -and $parts.Count -ge 3) { $old = $parts[1] }
        [void]$out.Add([ordered]@{ path = $parts[$parts.Count - 1]; oldPath = $old; status = $code })
    }
    $u = Invoke-GitCommand -Root $Root -Arguments @('ls-files', '--others', '--exclude-standard') -TimeoutSeconds 300
    if ($u.exitCode -ne 0) { throw ('git ls-files failed: ' + $u.stderr) }
    foreach ($line in $u.stdout) { [void]$out.Add([ordered]@{ path = $line; oldPath = $null; status = 'U' }) }
    $kept = @($out | Where-Object { -not (Test-InsideStateFolder $_['path']) -and -not ($_['oldPath'] -and (Test-InsideStateFolder $_['oldPath'])) })
    return ,$kept
}

function Get-UpgradeComparison {
    # Sorts every file changed since the base commit against discovery and the plan, and compares the package check
    # of gate 4 with the package references now. Every result is a candidate for the user to confirm.
    param([Parameter(Mandatory)][string]$Root)
    $Root = Resolve-FullPath $Root
    $state = Read-UpgradeState $Root
    $stateDir = Get-StateDir $Root
    $warnings = New-Object System.Collections.ArrayList
    $base = Assert-BaseCommit -Root $Root -State $state
    $patternsFile = Join-Path $stateDir 'evidence/discovery/patterns.json'
    if (-not [System.IO.File]::Exists((ConvertTo-IoPath $patternsFile))) { throw 'Discovery evidence is missing (.umbraco-upgrade/evidence/discovery/patterns.json). Feedback compares what discovery found with what changed, so discovery (gate 1) must have run.' }
    $disc = ConvertTo-PlainObject (Read-JsonFile $patternsFile)

    # Discovery hits by file, by App_Plugins folder, and by pattern.
    $hitIndex = @{}; $folderIndex = @{}; $patternFiles = @{}; $baselineIds = @{}
    foreach ($h in @($disc['baselineHits'])) { if ($null -ne $h -and $h['pattern']) { $baselineIds[[string]$h['pattern']] = $true } }
    foreach ($h in @(@($disc['hits']) + @($disc['baselineHits']))) {
        if ($null -eq $h) { continue }
        $f = [string]$h['file']; $p = [string]$h['pattern']
        if (-not $f -or -not $p) { continue }
        Add-ToIndex $hitIndex (ConvertTo-PathKey $f) $p
        Add-ToIndex $patternFiles $p $f
        $fk = Get-PluginFolderKey $f
        if ($fk) { Add-ToIndex $folderIndex $fk $p }
    }
    $unclassified = @{}
    if ($disc['unclassified']) { foreach ($f in @($disc['unclassified']['files'])) { if ($f) { $unclassified[(ConvertTo-PathKey $f)] = $true } } }
    $plannedBy = @{}
    foreach ($ph in @($state['phases'])) {
        if ($null -eq $ph) { continue }
        foreach ($p in @($ph['patterns'])) { if ($p) { Add-ToIndex $plannedBy ([string]$p) ([string]$ph['id']) } }
    }
    if (@($state['phases']).Count -eq 0) { [void]$warnings.Add([ordered]@{ code = 'no-plan'; message = 'No phases are recorded (the plan was not written), so no change counts as planned.' }) }

    $rules = Get-PhaseRules
    $volume = @()
    if ($rules['split'] -and $rules['split'].Contains('volumeExcludeFiles')) { $volume = @($rules['split']['volumeExcludeFiles']) }
    $genRx = New-GlobRegex @($volume + $script:GeneratedGlobs)
    $fwRx = New-GlobRegex $script:FrameworkGlobs

    # Changed files, sorted.
    $items = New-Object System.Collections.ArrayList
    $changedKeys = @{}; $changedFolders = @{}
    foreach ($e in (Get-ChangedFilesSinceBase -Root $Root -BaseCommit $base)) {
        $path = [string]$e['path']
        $match = $(if ($e['oldPath']) { [string]$e['oldPath'] } else { $path })
        $pats = @()
        if ($genRx.IsMatch($path) -or $genRx.IsMatch($match)) { $cat = 'generated' }
        else {
            $key = ConvertTo-PathKey $match
            $changedKeys[$key] = $true
            $fk = Get-PluginFolderKey $match
            if ($fk) { $changedFolders[$fk] = $true }
            $set = New-Object System.Collections.ArrayList
            if ($hitIndex.ContainsKey($key)) { foreach ($p in $hitIndex[$key]) { if (-not $set.Contains($p)) { [void]$set.Add($p) } } }
            if ($fk -and $folderIndex.ContainsKey($fk)) { foreach ($p in $folderIndex[$fk]) { if (-not $set.Contains($p)) { [void]$set.Add($p) } } }
            $pats = @($set | Sort-Object)
            $custom = @($pats | Where-Object { -not $baselineIds.ContainsKey($_) })
            if (@($pats | Where-Object { $plannedBy.ContainsKey($_) }).Count -gt 0) { $cat = 'planned' }
            elseif ($custom.Count -gt 0) { $cat = 'found-not-planned' }
            elseif ($pats.Count -gt 0 -or $fwRx.IsMatch($path)) { $cat = 'expected' }
            elseif ($unclassified.ContainsKey($key)) { $cat = 'flagged' }
            elseif ($e['status'] -in @('A', 'U')) { $cat = 'added' }
            else { $cat = 'not-found' }
        }
        [void]$items.Add([ordered]@{ path = $path; oldPath = $e['oldPath']; status = $script:StatusNames[[string]$e['status']]; category = $cat; patterns = @($pats) })
    }
    $counts = [ordered]@{}
    foreach ($c in $script:Categories) { $counts[$c] = @($items | Where-Object { $_['category'] -eq $c }).Count }

    # Candidate misses, grouped by folder and extension.
    $groups = [ordered]@{}
    foreach ($i in ($items | Where-Object { $_['category'] -eq 'not-found' })) {
        $p = [string]$i['path']
        $dir = $(if ($p.Contains('/')) { $p.Substring(0, $p.LastIndexOf('/')) } else { '.' })
        $g = $dir + '/*' + [System.IO.Path]::GetExtension($p).ToLowerInvariant()
        if (-not $groups.Contains($g)) { $groups[$g] = New-Object System.Collections.ArrayList }
        [void]$groups[$g].Add($p)
    }
    $notFoundGroups = @($groups.Keys | ForEach-Object { [ordered]@{ group = $_; count = $groups[$_].Count; files = @($groups[$_]) } } | Sort-Object -Property @{ Expression = { $_['count'] }; Descending = $true }, @{ Expression = { $_['group'] } })

    # Planned patterns none of whose files changed, and found patterns no phase covers.
    $plannedUnchanged = New-Object System.Collections.ArrayList
    $plannedWithChanges = 0
    foreach ($p in @($plannedBy.Keys | Sort-Object)) {
        if ($baselineIds.ContainsKey($p) -or -not $patternFiles.ContainsKey($p)) { continue }
        $files = @($patternFiles[$p] | Where-Object { -not $genRx.IsMatch([string]$_) })
        if ($files.Count -eq 0) { continue }
        $changed = 0
        foreach ($f in $files) {
            $fk = Get-PluginFolderKey $f
            if ($changedKeys.ContainsKey((ConvertTo-PathKey $f)) -or ($fk -and $changedFolders.ContainsKey($fk))) { $changed++ }
        }
        if ($changed -gt 0) { $plannedWithChanges++ }
        else { [void]$plannedUnchanged.Add([ordered]@{ pattern = $p; phases = @($plannedBy[$p]); hitFiles = $files.Count; sample = @($files | Select-Object -First 5) }) }
    }
    $foundNotPlanned = New-Object System.Collections.ArrayList
    foreach ($p in @($patternFiles.Keys | Sort-Object)) {
        if ($baselineIds.ContainsKey($p) -or $plannedBy.ContainsKey($p)) { continue }
        $files = @($patternFiles[$p] | Where-Object { -not $genRx.IsMatch([string]$_) })
        if ($files.Count -eq 0) { continue }
        $changed = @($files | Where-Object { $changedKeys.ContainsKey((ConvertTo-PathKey $_)) }).Count
        [void]$foundNotPlanned.Add([ordered]@{ pattern = $p; hitFiles = $files.Count; changedFiles = $changed })
    }

    # Packages: the gate 4 package check against the references now.
    $packages = [ordered]@{ available = $false; items = @(); added = @() }
    $compatFile = Join-Path $stateDir 'evidence/planning/package-compatibility.json'
    if ([System.IO.File]::Exists((ConvertTo-IoPath $compatFile))) {
        $compat = ConvertTo-PlainObject (Read-JsonFile $compatFile)
        $now = @{}; $nowIds = @{}
        foreach ($r in (Get-ProjectPackageReferences -Root $Root)) {
            $k = ([string]$r['id']).ToLowerInvariant()
            $nowIds[$k] = [string]$r['id']
            if (-not $now.ContainsKey($k)) { $now[$k] = New-Object System.Collections.ArrayList }
            if ($r['version'] -and -not $now[$k].Contains([string]$r['version'])) { [void]$now[$k].Add([string]$r['version']) }
        }
        $pkgItems = New-Object System.Collections.ArrayList
        $seen = @{}; $successors = @{}
        foreach ($b in @($compat['packages'])) {
            if ($null -eq $b -or -not $b['id']) { continue }
            $id = [string]$b['id']; $k = $id.ToLowerInvariant()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $cls = [string]$b['class']
            $succ = $null
            if ($b.Contains('successor') -and $b['successor']) { $succ = [string]$b['successor']; $successors[$succ.ToLowerInvariant()] = $true }
            $nowV = @(); if ($now.ContainsKey($k)) { $nowV = @($now[$k]) }
            $before = [string]$b['version']
            if (-not $now.ContainsKey($k)) { $outcome = 'removed' }
            elseif ($nowV.Count -gt 0 -and -not ($nowV -contains $before)) { $outcome = 'updated' }
            else { $outcome = 'unchanged' }
            $flag = $null
            switch ($cls) {
                'compatible' { if ($outcome -eq 'removed') { $flag = 'compatible-but-removed' } }
                'no-target-version' { if ($outcome -ne 'removed') { $flag = 'no-target-version-but-kept' } }
                'renamed' { if ($succ -and -not $now.ContainsKey($succ.ToLowerInvariant())) { $flag = 'successor-not-used' } }
                'unreachable' { $flag = 'no-claim' }
            }
            [void]$pkgItems.Add([ordered]@{ id = $id; versionBefore = $before; versionNow = ($nowV -join ', '); class = $cls; successor = $succ; outcome = $outcome; flag = $flag; private = ($cls -eq 'not-found') })
        }
        $added = @($now.Keys | Sort-Object | Where-Object { -not $seen.ContainsKey($_) -and -not $successors.ContainsKey($_) } | ForEach-Object { [ordered]@{ id = $nowIds[$_]; version = (@($now[$_]) -join ', ') } })
        $packages = [ordered]@{ available = $true; items = @($pkgItems); added = $added }
    } else {
        [void]$warnings.Add([ordered]@{ code = 'no-package-check'; message = 'The gate 4 package check is missing (evidence/planning/package-compatibility.json), so package outcomes are not compared.' })
    }

    $phases = @(foreach ($ph in @($state['phases'])) {
        if ($null -eq $ph) { continue }
        $fails = @(); if ($ph.Contains('failures')) { $fails = @($ph['failures'] | Where-Object { $_ } | ForEach-Object { [string]$_['summary'] }) }
        [ordered]@{ id = $ph['id']; title = $ph['title']; area = $ph['area']; status = $ph['status']; patterns = @($ph['patterns'] | Where-Object { $_ }); failures = $fails }
    })
    $unresolved = @($state['unresolved'] | Where-Object { $_ } | ForEach-Object { [ordered]@{ id = $_['id']; pattern = $_['pattern']; item = $_['item']; proposal = $_['proposal']; status = $_['status'] } })

    $target = [string]$state['target']['resolved']
    if (-not $target) { $target = [string]$state['target']['requested'] }
    $v = Get-UmbracoVersionInfo -Root $Root
    $nowMajor = $v.resolved.major
    if ($target -match '^(\d+)' -and ($null -eq $nowMajor -or [int]$nowMajor -lt [int]$Matches[1])) {
        [void]$warnings.Add([ordered]@{ code = 'target-not-reached'; message = "The project is not on Umbraco $target yet (detected now: $($v.resolved.version)). The comparison shows the work done so far." })
    }
    $untracked = @($items | Where-Object { $_['status'] -eq 'untracked' }).Count
    if ($untracked -gt 0) { [void]$warnings.Add([ordered]@{ code = 'untracked-files'; message = "$untracked untracked files are included as new files. Files git ignores are not compared." }) }

    return [ordered]@{
        base = [ordered]@{ commit = $base; branch = [string]$state['gitBaseline']['baseBranch'] }
        comparedWith = 'working-tree'
        mode = [string]$state['mode']
        strategy = [string]$state['path']['strategy']
        plugin = [ordered]@{ usedForUpgrade = [string]$state['plugin']['version']; now = (Get-PluginVersion) }
        knowledge = [string]$state['knowledge']['baselineVersion']
        source = [string]$state['source']['umbraco']
        target = $target
        detectedNow = [string]$v.resolved.version
        counts = $counts
        notFoundGroups = $notFoundGroups
        patterns = [ordered]@{ plannedWithChanges = $plannedWithChanges; plannedUnchanged = @($plannedUnchanged); foundNotPlanned = @($foundNotPlanned) }
        packages = $packages
        phases = $phases
        unresolved = $unresolved
        files = @($items)
        warnings = @($warnings)
    }
}

function Get-ChangedFileDiff {
    # The redacted diff of one file between the base commit and the working tree, cut after MaxLines lines.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path, [int]$MaxLines = 300)
    $Root = Resolve-FullPath $Root
    $state = Read-UpgradeState $Root
    $base = Assert-BaseCommit -Root $Root -State $state
    $rel = ($Path.Trim().Trim('"', "'") -replace '\\', '/')
    if ([System.IO.Path]::IsPathRooted($rel) -or $rel -match '(^|/)\.\.(/|$)' -or (Test-InsideStateFolder $rel)) { throw "Give the path of a changed file relative to the project root, as the comparison lists it (not '$Path')." }
    $d = Invoke-GitCommand -Root $Root -Arguments @('diff', '-M', '--relative', $base, '--', $rel) -TimeoutSeconds 120
    if ($d.exitCode -ne 0) { throw ('git diff failed: ' + $d.stderr) }
    $kind = 'diff'
    $lines = @($d.stdout)
    if ($lines.Count -eq 0) {
        $u = Invoke-GitCommand -Root $Root -Arguments @('ls-files', '--others', '--exclude-standard', '--', $rel)
        $kind = $(if ($u.exitCode -eq 0 -and @($u.stdout).Count -gt 0) { 'untracked' } else { 'unchanged' })
    }
    $truncated = ($lines.Count -gt $MaxLines)
    if ($truncated) { $lines = @($lines | Select-Object -First $MaxLines) }
    return [ordered]@{ file = $rel; kind = $kind; lines = $lines.Count; truncated = $truncated; diff = (Protect-Text ($lines -join "`n")) }
}

function Add-IdentityToken {
    # Adds a name and, with -Split, its parts. Nothing is added when every part is a generic word, unless -Always.
    param([hashtable]$Map, [string]$Text, [string]$Source, [switch]$Split, [switch]$Always)
    $t = ([string]$Text).Trim().Trim('"', "'")
    if ($t.Length -lt 3) { return }
    $parts = @($t)
    if ($Split) { $parts = @($t -split '[.\-_ /\\@+]+' | Where-Object { $_ }) }
    $useful = @($parts | Where-Object { Test-UsefulToken $_ })
    if ($useful.Count -eq 0 -and -not $Always) { return }
    foreach ($p in @(@($t) + $useful)) {
        $k = $p.ToLowerInvariant()
        if (-not $Map.ContainsKey($k)) { $Map[$k] = [ordered]@{ token = $p; source = $Source } }
    }
}

function Test-UsefulToken {
    param([string]$Text)
    $t = $Text.Trim()
    if ($t.Length -lt 3) { return $false }
    if ($t -match '^v?\d+([.\-]\d+)*$') { return $false }
    return -not ($script:GenericWords -contains $t.ToLowerInvariant())
}

function Get-ProjectIdentityTokens {
    # Names that identify the project: solution, project, and assembly names, the project and repository folders,
    # git remote hosts and paths, git authors, custom App_Plugins folders, and private package ids.
    param([Parameter(Mandatory)][string]$Root)
    $Root = Resolve-FullPath $Root
    $map = @{}
    foreach ($f in (Get-ProjectFiles -Root $Root)) {
        $name = [System.IO.Path]::GetFileName($f)
        if ($name -notmatch '(?i)\.(sln|slnx|csproj|vbproj)$') { continue }
        Add-IdentityToken $map ([System.IO.Path]::GetFileNameWithoutExtension($name)) 'solution or project name' -Split
        if ($name -match '(?i)proj$') {
            try {
                $doc = Read-XmlFile $f
                foreach ($tag in @('RootNamespace', 'AssemblyName')) {
                    foreach ($n in @($doc.SelectNodes("//*[local-name()='$tag']"))) { Add-IdentityToken $map $n.InnerText.Trim() 'assembly or namespace' -Split }
                }
            } catch { }
        }
    }
    Add-IdentityToken $map ([System.IO.Path]::GetFileName($Root.TrimEnd('\', '/'))) 'project folder' -Split
    $repo = Get-GitRepoInfo -Root $Root
    if ($repo.isRepo -and $repo.repoRoot) { Add-IdentityToken $map ([System.IO.Path]::GetFileName(([string]$repo.repoRoot).TrimEnd('\', '/'))) 'repository folder' -Split }
    if ($repo.isRepo) {
        $r = Invoke-GitCommand -Root $Root -Arguments @('remote', '-v')
        foreach ($line in @($r.stdout)) {
            $url = @($line -split '\s+')[1]
            if ($url -match '^(?:[A-Za-z][A-Za-z0-9+.\-]*://)?(?:[^@/]+@)?([^/:]+)(?::\d+)?[:/](.+)$') {
                $gitHost = $Matches[1].ToLowerInvariant(); $path = $Matches[2]
                if ($script:PublicGitHosts -notcontains $gitHost) { Add-IdentityToken $map $gitHost 'git remote host' -Split -Always }
                foreach ($seg in ($path -split '/')) { Add-IdentityToken $map ($seg -replace '(?i)\.git$', '') 'git remote path' -Split }
            }
        }
        $people = New-Object System.Collections.ArrayList
        $state = $null; try { $state = Read-UpgradeState $Root } catch { }
        if ($state -and $state['gitBaseline']['baseCommit']) {
            $log = Invoke-GitCommand -Root $Root -Arguments @('log', '-n', '500', '--format=%an%x09%ae', ([string]$state['gitBaseline']['baseCommit'] + '..HEAD'))
            foreach ($line in @($log.stdout)) { foreach ($x in ($line -split "`t")) { [void]$people.Add($x) } }
        }
        foreach ($key in @('user.name', 'user.email')) {
            $c = Invoke-GitCommand -Root $Root -Arguments @('config', '--get', $key)
            foreach ($x in @($c.stdout)) { [void]$people.Add($x) }
        }
        foreach ($x in ($people | Select-Object -Unique)) {
            if ($x -match '^([^@\s]+)@([^@\s]+)$') {
                $local = $Matches[1]; $domain = $Matches[2].ToLowerInvariant()
                if ($domain -notmatch '^example\.(com|org|net|invalid)$') { Add-IdentityToken $map $x 'git author email' -Always }
                Add-IdentityToken $map $local 'git author email' -Split
                if ($script:PublicMailDomains -notcontains $domain) { Add-IdentityToken $map $domain 'git author email' -Split }
            } else {
                Add-IdentityToken $map $x 'git author name' -Split
            }
        }
    }
    $stateDir = Get-StateDir $Root
    $patternsFile = Join-Path $stateDir 'evidence/discovery/patterns.json'
    if ([System.IO.File]::Exists((ConvertTo-IoPath $patternsFile))) {
        $disc = ConvertTo-PlainObject (Read-JsonFile $patternsFile)
        foreach ($h in @($disc['hits'])) {
            # Folders that a referenced package copies in carry the package's public name, not the project's.
            if ($null -eq $h -or -not $h['file'] -or $h['pattern'] -eq 'backoffice.package-copied-assets') { continue }
            if ([string]$h['file'] -match '(?i)(?:^|/)App_Plugins/([^/]+)/') { Add-IdentityToken $map $Matches[1] 'custom App_Plugins folder' -Split }
        }
    }
    $compatFile = Join-Path $stateDir 'evidence/planning/package-compatibility.json'
    if ([System.IO.File]::Exists((ConvertTo-IoPath $compatFile))) {
        $compat = ConvertTo-PlainObject (Read-JsonFile $compatFile)
        foreach ($b in @($compat['packages'])) { if ($b -and $b['class'] -eq 'not-found' -and $b['id']) { Add-IdentityToken $map ([string]$b['id']) 'private package' -Split } }
    }
    return ,@($map.Values | Sort-Object -Property @{ Expression = { $_['token'] } })
}

function Test-AllowedDraftHost {
    param([string]$HostName)
    $h = $HostName.ToLowerInvariant().TrimEnd('.')
    foreach ($a in $script:AllowedDraftHosts) { if ($h -eq $a -or $h.EndsWith('.' + $a)) { return $true } }
    return $false
}

function Test-FeedbackDraftText {
    # Findings in a public draft: project names, email addresses, hosts other than official ones, local paths, and
    # values that look like secrets. Secret values are never echoed.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, $Tokens = @())
    $findings = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param([int]$Line, [string]$Kind, [string]$Found, [string]$Source)
        $k = "$Line|$Kind|$($Found.ToLowerInvariant())"
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$findings.Add([ordered]@{ line = $Line; kind = $Kind; text = $Found; source = $Source }) }
    }
    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $tokenRx = @(foreach ($t in @($Tokens)) {
        if ($null -eq $t) { continue }
        $w = [regex]::Escape([string]$t['token'])
        $pattern = $(if (([string]$t['token']).Length -le 5) { "(?<![A-Za-z0-9])$w(?![A-Za-z0-9])" } else { $w })
        [ordered]@{ rx = (New-Object System.Text.RegularExpressions.Regex($pattern, $opts)); source = [string]$t['source'] }
    })
    $emailRx = New-Object System.Text.RegularExpressions.Regex('[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)', $opts)
    $urlRx = New-Object System.Text.RegularExpressions.Regex('\b[a-z][a-z0-9+.\-]*://(?:[^@/\s]+@)?([^/\s:)\]>"''`]+)', $opts)
    $domainRx = New-Object System.Text.RegularExpressions.Regex('(?<![A-Za-z0-9.\-@])(?:[a-z0-9\-]+\.)+(?:com|org|co\.uk|org\.uk|ac\.uk|gov\.uk|info|biz|edu|gov)(?![A-Za-z0-9\-])', $opts)
    $pathRx = New-Object System.Text.RegularExpressions.Regex('(?<![A-Za-z0-9])[A-Za-z]:[\\/][^\s`''"<>|]*|\\\\[A-Za-z0-9._\-]+\\[^\s`''"<>|]+|/(?:Users|home)/[A-Za-z0-9._\-]+', $opts)
    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]; $n = $i + 1
        foreach ($t in $tokenRx) { foreach ($m in $t['rx'].Matches($line)) { & $add $n 'project-name' $m.Value $t['source'] } }
        foreach ($m in $emailRx.Matches($line)) { if (-not ($m.Groups[1].Value -match '(?i)^example\.(com|org|net|invalid)$')) { & $add $n 'email' $m.Value 'email address' } }
        foreach ($m in $urlRx.Matches($line)) { if (-not (Test-AllowedDraftHost $m.Groups[1].Value)) { & $add $n 'host' $m.Groups[1].Value 'link to a host that is not official documentation or a package feed' } }
        foreach ($m in $domainRx.Matches($line)) { if (-not (Test-AllowedDraftHost $m.Value)) { & $add $n 'host' $m.Value 'domain name' } }
        foreach ($m in $pathRx.Matches($line)) { & $add $n 'local-path' $m.Value 'local file path' }
        if ((Protect-Text $line) -ne $line) { & $add $n 'secret' '(a value that looks like a secret)' 'redaction rules' }
    }
    return ,($findings.ToArray())
}

Export-ModuleMember -Function Get-UpgradeComparison, Get-ChangedFileDiff, Get-ProjectIdentityTokens, Test-FeedbackDraftText, Get-ChangedFilesSinceBase
