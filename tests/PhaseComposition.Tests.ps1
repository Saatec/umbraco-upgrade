# Phase composition (design section 7.2): plan phases from discovery results and the selected path, split by the
# heuristics in knowledge/planning/phase-rules.json. The split thresholds were tuned against these cases.
# Labels: fixture-based (synthetic fixtures through detection, path selection, and composition) and mocked (split
# rules on constructed work items).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    foreach ($m in @('Compat', 'Knowledge', 'Discovery', 'PathSelection', 'Planning', 'State')) { Import-Module (Join-Path (Get-RepoRoot) "scripts/lib/$m.psm1") -Force -DisableNameChecking }
    $script:Rules = Get-PhaseRules
    $script:PatternFixtures = Join-Path $PSScriptRoot 'fixtures/patterns'
    $script:Heavy = @('p.api.composers.v13', 'p.api.content-finders', 'p.api.events.v13', 'p.auth.access-rules', 'p.auth.external-login', 'p.bo.angular-editor',
        'p.bo.authorized-api', 'p.bo.dashboard', 'p.bo.section-tree', 'p.code.api-controller.v13', 'p.code.content-write', 'p.code.custom-routing',
        'p.code.render-controller.v13', 'p.conf.static-reader', 'p.content.blocks', 'p.content.macros', 'p.data.custom-table.v13', 'p.data.raw-sql-custom',
        'p.dep.ci', 'p.dep.iis', 'p.ext.payment', 'p.ext.smtp', 'p.jobs.caching', 'p.jobs.examine', 'p.jobs.scheduled', 'p.gap.url-provider',
        'p.gap.health-check', 'p.gap.content-apps')

    # The scripts pass these results through JSON files; the round trip gives the same object shapes here.
    function ConvertTo-JsonObject($Value) { return ((ConvertTo-JsonText -InputObject $Value) | ConvertFrom-Json) }

    function Add-Overlay([string]$Dir, [string]$Overlay) {
        Get-ChildItem -LiteralPath (Join-Path $script:PatternFixtures $Overlay) -Force | Where-Object { $_.Name -ne 'overlay.json' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Dir -Recurse -Force }
    }

    function Get-Selection([string]$Source, [string]$Target, [string[]]$PatternIds) {
        $k = Get-Knowledge
        $kn = @{ versions = $k['versions'].data; paths = $k['paths'].data; packages = $k['packages'].data }
        return (ConvertTo-JsonObject (Select-UpgradePathCore -Knowledge $kn -Source $Source -Target $Target -Engine 'sqlserver' -Patterns $PatternIds -PackageVersions @{} -PackageSources @{} -TargetNuspec $null -TargetNuspecUrl '' -UserFacts @{}))
    }

    function New-Composition {
        param([string]$Baseline = 'gen.v13', [string[]]$Overlays = @(), [string]$Source = '13.10.1', [string]$Target = '17', [scriptblock]$Prepare = $null)
        $d = Copy-Fixture -Baseline $Baseline
        try {
            foreach ($o in $Overlays) { Add-Overlay $d $o }
            if ($Prepare) { & $Prepare $d }
            $hits = ConvertTo-JsonObject (Find-PatternHits -Root $d)
        } finally { Remove-TestDirectory $d }
        $ids = @($hits.patterns | ForEach-Object { [string]$_.pattern })
        $sel = Get-Selection $Source $Target $ids
        $cand = @($sel.candidates | Where-Object { $_.id -eq $sel.recommended })[0]
        $comp = Get-PhaseComposition -PatternResult $hits -Steps @($cand.steps) -SourceMajor ([int]($Source -split '\.')[0]) -TargetMajor ([int]($Target -split '\.')[0]) -Strategy $cand.strategy
        return [pscustomobject]@{ Hits = $hits; Candidate = $cand; Composition = $comp; Fired = $ids; Steps = @($cand.steps) }
    }

    function Test-PhaseShape($Composition) {
        $n = 0
        foreach ($p in @($Composition.phases)) {
            $n++
            $p.id | Should -Be "P$n"
            @($p.acceptanceCriteria).Count | Should -BeGreaterThan 0 -Because $p.title
            $m = 0
            foreach ($c in @($p.acceptanceCriteria)) { $m++; $c.id | Should -Be "P$n-AC$m"; $c.verification | Should -BeIn @('automated', 'manual') }
            @($p.reasons).Count | Should -BeGreaterThan 0 -Because $p.title
        }
    }
}

Describe 'Phase composition on synthetic fixtures' -Tag 'fixture-based' {
    BeforeAll { $script:HeavyResult = New-Composition -Overlays $script:Heavy -Target '18' }

    It 'gives a near-default in-place upgrade two phases: framework, then the database' {
        $r = New-Composition -Target '17'
        $r.Candidate.strategy | Should -Be 'in-place'
        $r.Fired.Count | Should -Be 0
        $c = $r.Composition
        Test-PhaseShape $c
        $c.summary.phases | Should -Be 2
        $c.phases[0].area | Should -Be 'application-framework'
        $c.phases[1].area | Should -Be 'content-database'
        $c.phases[1].title | Should -Match 'Database migration on the local copy'
        # Baseline signals join the framework phase with their checks.
        foreach ($b in @($r.Hits.baselineSignals | ForEach-Object { $_.pattern })) { @($c.phases[0].patterns) | Should -Contain $b }
        @($c.phases | Where-Object { @($_.reasons) -match 'volume|split' }).Count | Should -Be 0
        @($c.decisions).Count | Should -Be 0
    }

    It 'gives each stop of a staged path its own framework and database phases' {
        $r = New-Composition -Target '18'
        $steps = @($r.Steps)
        $steps.Count | Should -BeGreaterThan 1
        $c = $r.Composition
        Test-PhaseShape $c
        foreach ($s in $steps) {
            $mine = @($c.phases | Where-Object { $_.step -eq $s.id })
            $mine[0].area | Should -Be 'application-framework' -Because "step $($s.id) starts with packages and startup"
            if (@($s.kind) -contains 'database') { @($mine | Where-Object { $_.title -match '^Database migration' }).Count | Should -Be 1 }
        }
        $c.summary.phases | Should -Be (2 * $steps.Count)
    }

    It 'ports custom code once, onto the new codebase, when the path rebuilds from an 8 source' {
        $r = New-Composition -Baseline 'gen.v8' -Source '8.18.8' -Target '17'
        $c = $r.Composition
        Test-PhaseShape $c
        $c.rules.codePort | Should -Be 'final-codebase'
        $last = $r.Steps[$r.Steps.Count - 1].id
        $tpl = @($c.phases | Where-Object { $_.title -eq 'Templates, views, and configuration rebuilt on the new codebase' })
        $tpl.Count | Should -Be 1
        $tpl[0].step | Should -Be $last
        foreach ($s in @($r.Steps | Where-Object { $_.type -eq 'minor-in-place' -and $_.id -ne $last })) {
            @($c.phases | Where-Object { $_.step -eq $s.id }).Count | Should -Be 1 -Because 'a minor step without work is one combined phase'
        }
        foreach ($s in @($r.Steps | Where-Object { @($_.kind) -contains 'database' -and $_.type -ne 'minor-in-place' })) {
            @($c.phases | Where-Object { $_.step -eq $s.id -and $_.area -eq 'content-database' }).Count | Should -Be 1 -Because "step $($s.id) migrates the database"
        }
    }

    It 'splits a heavily customized project as the rules say' {
        $r = $script:HeavyResult
        $c = $r.Composition
        Test-PhaseShape $c
        $r.Fired.Count | Should -BeGreaterOrEqual 25
        $c.summary.phases | Should -BeGreaterThan 10
        $all = @($c.phases | ForEach-Object { @($_.patterns) })
        foreach ($id in $r.Fired) { $all | Should -Contain $id -Because 'no detected pattern may drop out of the plan' }
        # A high-difficulty pattern gets a phase of its own.
        $own = @($c.phases | Where-Object { @($_.reasons) -match '^high difficulty: ' })
        $own.Count | Should -BeGreaterThan 0
        foreach ($p in $own) { @($p.patterns).Count | Should -Be 1; @($p.reasons)[0] | Should -Be "high difficulty: $(@($p.patterns)[0])" }
        # Packed phases stay under the thresholds.
        foreach ($p in @($c.phases | Where-Object { @($_.reasons) -contains 'detector fired' -and @($_.patterns).Count -gt 1 })) {
            @($p.files).Count | Should -BeLessOrEqual ([int]$script:Rules['split']['maxFiles'])
        }
        # Within each stop: framework first, the groups in dependency order, the database migration after the code.
        foreach ($s in $r.Steps) {
            $mine = @($c.phases | Where-Object { $_.step -eq $s.id })
            $mine[0].area | Should -Be 'application-framework'
            $db = @($mine | Where-Object { $_.title -match '^Database migration' })
            $db.Count | Should -Be 1
            $dbIndex = [array]::IndexOf(@($mine | ForEach-Object { $_.id }), $db[0].id)
            foreach ($p in @($mine | Select-Object -Skip ($dbIndex + 1))) { $p.area | Should -BeIn @('functional-verification', 'deployment-rehearsal') }
        }
        # The last stop ends with functional verification and the deployment rehearsal.
        $c.phases[-2].area | Should -Be 'functional-verification'
        $c.phases[-1].area | Should -Be 'deployment-rehearsal'
        @($c.phases[-1].patterns) | Should -Contain 'deploy.ci-pipelines'
        # Patterns that need the user's decision are listed with their options, and their phases wait for it.
        $c.decisions.Count | Should -BeGreaterThan 0
        foreach ($dec in @($c.decisions)) {
            $ph = @($c.phases | Where-Object { @($_.patterns) -contains $dec.pattern })
            $ph.Count | Should -BeGreaterThan 0
            @($ph[0].acceptanceCriteria | Where-Object { $_.text -match "decision for" }).Count | Should -BeGreaterThan 0
        }
    }

    It 'gives the second stop only the patterns whose documented changes it crosses' {
        $r = $script:HeavyResult
        $s2 = $r.Steps[1]
        $idx = @{}; foreach ($p in (Get-PatternRegistry)) { $idx[$p.id] = $p }
        foreach ($p in @($r.Composition.phases | Where-Object { $_.step -eq $s2.id -and $_.area -notin @('application-framework', 'functional-verification', 'deployment-rehearsal') -and @($_.patterns).Count -gt 0 })) {
            foreach ($id in @($p.patterns)) {
                # A pattern whose documented changes all lie outside the path is verified at the last stop.
                $relevant = @(Get-RelevantImpacts -Pattern $idx[$id] -SourceMajor 13 -TargetMajor 18)
                if ($relevant.Count -eq 0) { continue }
                $crossings = @($relevant | Where-Object { [int]$s2.fromMajor -lt [int]$_.crosses -and [int]$_.crosses -le [int]$s2.toMajor })
                $crossings.Count | Should -BeGreaterThan 0 -Because "$id is placed in step $($s2.id)"
            }
        }
    }

    It 'splits one pattern above the volume thresholds into file chunks' {
        $prepare = {
            param($dir)
            $orig = [System.IO.File]::ReadAllText((Join-Path $dir 'Controllers/ArticlePageController.cs'))
            for ($i = 1; $i -le 19; $i++) { [System.IO.File]::WriteAllText((Join-Path $dir "Controllers/Article${i}PageController.cs"), $orig.Replace('ArticlePageController', "Article${i}PageController")) }
        }
        $r = New-Composition -Overlays @('p.code.render-controller.v13') -Target '17' -Prepare $prepare
        $c = $r.Composition
        Test-PhaseShape $c
        $parts = @($c.phases | Where-Object { @($_.patterns) -contains 'code.render-controller' })
        $parts.Count | Should -Be 2
        foreach ($p in $parts) {
            @($p.files).Count | Should -BeLessOrEqual ([int]$script:Rules['split']['maxFiles'])
            (@($p.reasons) -join ' ') | Should -Match 'volume: 20 occurrences in 20 files'
        }
        $parts[0].title | Should -Match 'part 1 of 2'
        @($parts | ForEach-Object { @($_.files) } | Sort-Object -Unique).Count | Should -Be 20
    }

    It 'produces a phase list that state accepts' {
        $r = $script:HeavyResult
        $d = New-UpgradeProject -Target '18'
        try {
            $phases = ConvertTo-StatePhases $r.Composition
            [void](Set-UpgradePhases -ProjectRoot $d -Phases $phases)
            $state = Read-UpgradeState $d
            @($state['phases']).Count | Should -Be $r.Composition.summary.phases
            (Test-UpgradeState -State $state).Count | Should -Be 0
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'Split rules' -Tag 'mocked' {
    BeforeAll {
        function New-WorkItem([string]$Pattern, [string]$Difficulty, [int]$Files, [int]$Occurrences) {
            return [ordered]@{ pattern = $Pattern; title = $Pattern; difficulty = $Difficulty; files = @(1..$Files | ForEach-Object { "$Pattern/f$_.cs" }); occurrences = $Occurrences }
        }
    }

    It 'packs small patterns into one phase' {
        $chunks = Split-WorkItems -Items @((New-WorkItem 'a' 'low' 2 5), (New-WorkItem 'b' 'medium' 3 6), (New-WorkItem 'c' 'low' 1 2)) -Rules $script:Rules
        @($chunks).Count | Should -Be 1
        @($chunks[0].items).Count | Should -Be 3
    }

    It 'starts a new phase when a group would exceed the occurrence threshold' {
        $chunks = Split-WorkItems -Items @((New-WorkItem 'a' 'low' 2 10), (New-WorkItem 'b' 'low' 2 10), (New-WorkItem 'c' 'low' 2 10), (New-WorkItem 'd' 'low' 2 10)) -Rules $script:Rules
        @($chunks).Count | Should -Be 2
        foreach ($ch in $chunks) { $sum = 0; foreach ($it in @($ch.items)) { $sum += [int]$it.occurrences }; $sum | Should -BeLessOrEqual ([int]$script:Rules['split']['maxOccurrences']) }
        (@($chunks[0].reasons) -join ' ') | Should -Match 'split: the group exceeds'
    }

    It 'starts a new phase when a group would exceed the file threshold' {
        $chunks = Split-WorkItems -Items @((New-WorkItem 'a' 'low' 9 9), (New-WorkItem 'b' 'low' 9 9)) -Rules $script:Rules
        @($chunks).Count | Should -Be 2
    }

    It 'gives a high-difficulty pattern its own phase' {
        $chunks = Split-WorkItems -Items @((New-WorkItem 'hard' 'high' 1 1), (New-WorkItem 'a' 'low' 1 1), (New-WorkItem 'b' 'low' 1 1)) -Rules $script:Rules
        @($chunks).Count | Should -Be 2
        @($chunks[0].items).Count | Should -Be 1
        $chunks[0].items[0].pattern | Should -Be 'hard'
        $chunks[0].reasons[0] | Should -Be 'high difficulty: hard'
    }

    It 'keeps many occurrences in one file as one phase' {
        $chunks = Split-WorkItems -Items @((New-WorkItem 'dense' 'low' 1 60)) -Rules $script:Rules
        @($chunks).Count | Should -Be 1
        (@($chunks[0].reasons) -join ' ') | Should -Match 'in one file; kept as one phase'
    }

    It 'splits a large pattern into parts of at most the file threshold' {
        $chunks = Split-WorkItems -Items @((New-WorkItem 'wide' 'low' 40 40)) -Rules $script:Rules
        @($chunks).Count | Should -Be 3
        foreach ($ch in $chunks) { @($ch.files).Count | Should -BeLessOrEqual ([int]$script:Rules['split']['maxFiles']) }
        @($chunks | ForEach-Object { @($_.files) } | Sort-Object -Unique).Count | Should -Be 40
    }
}

Describe 'Get-PhaseComposition.ps1 and Get-PatternGuidance.ps1' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'reads discovery and path evidence from the project and writes the proposal and the state phase list' {
        $script:d = New-UpgradeProject -Target '17'
        Add-Overlay $script:d 'p.bo.angular-editor'
        $hits = Find-PatternHits -Root $script:d
        $ev = Join-Path $script:d '.umbraco-upgrade/evidence'
        Write-TextFile -Path (Join-Path $ev 'discovery/patterns.json') -Content (ConvertTo-JsonText -InputObject $hits)
        $sel = Get-Selection '13.10.1' '17' @($hits.patterns | ForEach-Object { [string]$_.pattern })
        Write-TextFile -Path (Join-Path $ev 'version-path/path-selection.json') -Content (ConvertTo-JsonText -InputObject $sel)
        $r = Invoke-PluginScript -Script 'scripts/Get-PhaseComposition.ps1' -Arguments @('-ProjectRoot', $script:d, '-SourceMajor', '13', '-TargetMajor', '17')
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.strategy | Should -Be 'in-place'
        @($r.Json.phases | Where-Object { @($_.patterns) -contains 'backoffice.angular-property-editor' }).Count | Should -Be 1
        Test-Path (Join-Path $ev 'planning/phase-composition.json') | Should -BeTrue
        $s = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('phases', '-ProjectRoot', $script:d, '-JsonFile', $r.Json.stateFile)
        $s.Json.ok | Should -BeTrue -Because $s.StdOut
        $s.Json.count | Should -Be $r.Json.summary.phases
    }

    It 'refuses without discovery results' {
        $script:d = New-UpgradeProject -Target '17'
        $r = Invoke-PluginScript -Script 'scripts/Get-PhaseComposition.ps1' -Arguments @('-ProjectRoot', $script:d, '-SourceMajor', '13', '-TargetMajor', '17')
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'Discovery results not found'
    }

    It 'prints the guidance for the target generation with cited options and the no-removal rule' {
        $script:d = New-TestDirectory
        $r = Invoke-PluginScript -Script 'scripts/Get-PatternGuidance.ps1' -Arguments @('-ProjectRoot', $script:d, '-PatternId', 'backoffice.angular-property-editor', '-SourceMajor', '13', '-TargetMajor', '17')
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $g = $r.Json.patterns[0]
        $g.targetGeneration | Should -Be 'v14+'
        @($g.impacts).Count | Should -BeGreaterThan 0
        foreach ($i in @($g.impacts)) { [int]$i.crosses | Should -BeGreaterThan 13; [int]$i.crosses | Should -BeLessOrEqual 17 }
        @($g.options).Count | Should -BeGreaterThan 1
        foreach ($o in @($g.options)) {
            @($o.targets) | Should -Contain 'v14+'
            if ($o.status -eq 'verified') { @($o.sources).Count | Should -BeGreaterThan 0 } else { $o.status | Should -Be 'hypothesis' }
        }
        foreach ($doc in @($g.docs)) { $doc.url | Should -Match '^https://' ; $doc.verifiedAt | Should -Match '^\d{4}-\d{2}-\d{2}$' }
        $g.rule | Should -Match 'Never remove, stub, or disable custom functionality'
        $bad = Invoke-PluginScript -Script 'scripts/Get-PatternGuidance.ps1' -Arguments @('-ProjectRoot', $script:d, '-PatternId', 'no.such-pattern', '-SourceMajor', '13', '-TargetMajor', '17')
        $bad.Json.error | Should -Match 'Unknown pattern'
    }
}
