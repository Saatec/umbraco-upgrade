# Pattern detection on the required overlays: each fires its detector and no unrelated one.
# Label: fixture-based.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Discovery.psm1') -Force -DisableNameChecking
}

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    $script:overlays = @(Get-OverlayIds | ForEach-Object { $info = Get-OverlayInfo $_; @{ id = $_; baseline = $info.baseline; expects = @($info.expects) } })
    $script:baselines = @('gen.v7', 'gen.v7-old', 'gen.v8', 'gen.v8-sqlce', 'gen.v10', 'gen.v13', 'gen.v13-startup-class', 'gen.v13-cpm', 'gen.v13-multi', 'gen.v14plus', 'gen.not-umbraco' | ForEach-Object { @{ fixture = $_ } })
}

Describe 'Required overlays' -Tag 'fixture-based' {
    It 'the ten required overlays exist' {
        $ids = Get-OverlayIds
        foreach ($req in @('p.code.render-controller.v7', 'p.code.render-controller.v13', 'p.code.surface-controller', 'p.code.api-controller.v7', 'p.code.api-controller.v13', 'p.bo.angular-editor', 'p.data.custom-table.v7', 'p.data.custom-table.v8', 'p.data.custom-table.v13', 'p.ext.http-client')) {
            $ids | Should -Contain $req
        }
    }
}

Describe 'Find-PatternHits on overlays' -Tag 'fixture-based' {
    It '<id> on <baseline> fires exactly <expects>' -ForEach $script:overlays {
        $d = Copy-Fixture -Baseline $baseline -Overlay $id
        try {
            $r = Find-PatternHits -Root $d
            $fired = @($r.patterns | ForEach-Object { $_.pattern })
            ($fired | Sort-Object) | Should -Be ($expects | Sort-Object)
            foreach ($p in $r.patterns) { $p.files | Should -BeGreaterThan 0; $p.occurrences | Should -BeGreaterThan 0 }
            # Every hit carries a location and a one-line snippet.
            foreach ($h in $r.hits) { $h.file | Should -Not -BeNullOrEmpty; $h.line | Should -BeGreaterThan 0; $h.snippet.Length | Should -BeLessOrEqual 200 }
            # Files matched by a pattern are not in the unclassified list.
            foreach ($h in $r.hits) { $r.unclassified.files | Should -Not -Contain $h.file }
            ($r | ConvertTo-Json -Depth 8) | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'Find-PatternHits on baselines' -Tag 'fixture-based' {
    It '<fixture> fires no customization pattern' -ForEach $script:baselines {
        $r = Find-PatternHits -Root (Get-FixturePath $fixture)
        @($r.patterns).Count | Should -Be 0
    }

    It 'lists unmatched Umbraco usage in the catch-all' {
        $r = Find-PatternHits -Root (Get-FixturePath 'gen.v10')
        $r.unclassified.pattern | Should -Be 'code.unclassified-umbraco-usage'
        $r.unclassified.files | Should -Contain 'Startup.cs'
        $r2 = Find-PatternHits -Root (Get-FixturePath 'gen.v13-multi')
        $r2.unclassified.files | Should -Contain 'src/SampleSite.Core/Services/GreetingService.cs'
    }

    It 'reports supporting hits only for patterns that fired' {
        # The baseline appsettings has no strong http-client hit, so endpoint-like keys alone are not reported.
        $d = Copy-Fixture -Baseline 'gen.v13'
        try {
            [System.IO.File]::WriteAllText((Join-Path $d 'appsettings.Staging.json'), '{ "Search": { "Endpoint": "https://search.example.invalid/" } }')
            $r = Find-PatternHits -Root $d
            @($r.patterns).Count | Should -Be 0
            @($r.hits).Count | Should -Be 0
        } finally { Remove-TestDirectory $d }
    }

    It 'runs as a script and prints JSON' {
        $d = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.ext.http-client'
        try {
            $r = Invoke-PluginScript -Script 'scripts/Find-Patterns.ps1' -Arguments @('-Path', $d)
            $r.ExitCode | Should -Be 0
            @($r.Json.patterns | ForEach-Object { $_.pattern }) | Should -Be @('ext.http-client')
            $r.StdOut | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'Pattern registry records' -Tag 'fixture-based' {
    It 'every record has the required fields and compiles' {
        foreach ($p in (Get-PatternRegistry)) {
            $p.id | Should -Match '^[a-z]+\.[a-z0-9\-]+$'
            $p.title | Should -Not -BeNullOrEmpty
            $p.description | Should -Not -BeNullOrEmpty
            $p.status | Should -Be 'hypothesis'
            foreach ($d in @($p.detectors)) {
                if ($null -eq $d) { continue }
                $d.weight | Should -BeIn @('strong', 'supporting')
                { [regex]::new($d.regex) } | Should -Not -Throw
                @($d.files).Count | Should -BeGreaterThan 0
            }
        }
    }
}
