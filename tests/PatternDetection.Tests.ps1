# Pattern detection: each overlay fires its detectors and no unrelated customization pattern; baselines fire no
# customization pattern; the catch-all lists unmatched CMS usage; every registry record is well formed.
# Label: fixture-based.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Discovery.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Compat.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/JsonSchema.psm1') -Force -DisableNameChecking
}

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    $script:overlays = @(Get-OverlayIds | ForEach-Object {
        $info = Get-OverlayInfo $_
        $eb = @(); if ($info.PSObject.Properties['expectsBaseline']) { $eb = @($info.expectsBaseline) }
        @{ id = $_; baseline = $info.baseline; expects = @($info.expects); expectsBaseline = $eb }
    })
    $script:baselines = @('gen.v7', 'gen.v7-old', 'gen.v8', 'gen.v8-sqlce', 'gen.v10', 'gen.v13', 'gen.v13-startup-class', 'gen.v13-cpm', 'gen.v13-multi', 'gen.v14plus', 'gen.not-umbraco' | ForEach-Object { @{ fixture = $_ } })
}

Describe 'Required overlays' -Tag 'fixture-based' {
    It 'the ten required overlays exist' {
        $ids = Get-OverlayIds
        foreach ($req in @('p.code.render-controller.v7', 'p.code.render-controller.v13', 'p.code.surface-controller', 'p.code.api-controller.v7', 'p.code.api-controller.v13', 'p.bo.angular-editor', 'p.data.custom-table.v7', 'p.data.custom-table.v8', 'p.data.custom-table.v13', 'p.ext.http-client')) {
            $ids | Should -Contain $req
        }
    }

    It 'every pattern detected statically has at least one overlay' {
        $covered = @{}
        foreach ($id in (Get-OverlayIds)) {
            $info = Get-OverlayInfo $id
            foreach ($p in @($info.expects)) { $covered[$p] = $true }
            if ($info.PSObject.Properties['expectsBaseline']) { foreach ($p in @($info.expectsBaseline)) { $covered[$p] = $true } }
        }
        # Baseline signals that every matching baseline fixture already exercises.
        foreach ($p in @('config.startup-hosting', 'data.non-sqlserver-engine')) { $covered[$p] = $true }
        foreach ($p in (Get-PatternRegistry)) {
            if ($p.detection -ne 'static' -or @($p.detectors).Count -eq 0) { continue }
            $covered.ContainsKey($p.id) | Should -BeTrue -Because "$($p.id) needs a synthetic overlay"
        }
    }
}

Describe 'Find-PatternHits on overlays' -Tag 'fixture-based' {
    It '<id> on <baseline> fires exactly <expects>' -ForEach $script:overlays {
        $d = Copy-Fixture -Baseline $baseline -Overlay $id
        try {
            $r = Find-PatternHits -Root $d
            $fired = @($r.patterns | ForEach-Object { $_.pattern })
            (@($fired | Sort-Object) -join ',') | Should -Be (@($expects | Sort-Object) -join ',')
            $signals = @($r.baselineSignals | ForEach-Object { $_.pattern })
            foreach ($b in $expectsBaseline) { $signals | Should -Contain $b }
            foreach ($p in $r.patterns) { $p.files | Should -BeGreaterThan 0; $p.occurrences | Should -BeGreaterThan 0 }
            # Every hit carries a location and a one-line snippet.
            foreach ($h in @($r.hits) + @($r.baselineHits)) { $h.file | Should -Not -BeNullOrEmpty; $h.line | Should -BeGreaterThan 0; $h.snippet.Length | Should -BeLessOrEqual 200 }
            # Files matched by a pattern are not in the unclassified list.
            foreach ($h in $r.hits) { $r.unclassified.files | Should -Not -Contain $h.file }
            ($r | ConvertTo-Json -Depth 8) | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'Find-PatternHits on baselines' -Tag 'fixture-based' {
    It '<fixture> fires no customization pattern' -ForEach $script:baselines {
        $r = Find-PatternHits -Root (Get-FixturePath $fixture)
        (@($r.patterns | ForEach-Object { $_.pattern }) -join ',') | Should -Be ''
        foreach ($s in $r.baselineSignals) { ((Get-PatternRegistry) | Where-Object { $_.id -eq $s.pattern }).kind | Should -Be 'baseline' }
    }

    It 'reports the generation signals of default installations as baseline signals' {
        $v13 = Find-PatternHits -Root (Get-FixturePath 'gen.v13')
        @($v13.baselineSignals | ForEach-Object { $_.pattern }) | Should -Contain 'config.startup-hosting'
        @($v13.baselineSignals | ForEach-Object { $_.pattern }) | Should -Contain 'content.razor-compilation'
        $v14 = Find-PatternHits -Root (Get-FixturePath 'gen.v14plus')
        @($v14.baselineSignals | ForEach-Object { $_.pattern }) | Should -Contain 'backoffice.modern-extension'
        @($v14.baselineSignals | ForEach-Object { $_.pattern }) | Should -Contain 'data.non-sqlserver-engine'
        $ce = Find-PatternHits -Root (Get-FixturePath 'gen.v8-sqlce')
        @($ce.baselineSignals | ForEach-Object { $_.pattern }) | Should -Contain 'data.non-sqlserver-engine'
        $none = Find-PatternHits -Root (Get-FixturePath 'gen.not-umbraco')
        @($none.baselineSignals).Count | Should -Be 0
    }

    It 'lists unmatched CMS usage in the catch-all' {
        $r = Find-PatternHits -Root (Get-FixturePath 'gen.v13-multi')
        $r.unclassified.pattern | Should -Be 'code.unclassified-umbraco-usage'
        $r.unclassified.files | Should -Contain 'src/SampleSite.Core/Services/GreetingService.cs'
        # A startup class is classified by the startup baseline signal, so it is not unclassified.
        $r10 = Find-PatternHits -Root (Get-FixturePath 'gen.v10')
        @($r10.baselineHits | ForEach-Object { $_.file }) | Should -Contain 'Startup.cs'
        $r10.unclassified.files | Should -Not -Contain 'Startup.cs'
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

    It 'treats an App_Plugins folder that matches a package reference as package assets, not as custom code' {
        $d = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.bo.angular-editor'
        try {
            $proj = Join-Path $d 'SampleSite.Web.csproj'
            $xml = [System.IO.File]::ReadAllText($proj).Replace('<PackageReference Include="Umbraco.Cms" Version="13.10.1" />', '<PackageReference Include="Umbraco.Cms" Version="13.10.1" /><PackageReference Include="BadgeEditor" Version="1.0.0" />')
            [System.IO.File]::WriteAllText($proj, $xml)
            $r = Find-PatternHits -Root $d
            @($r.patterns | ForEach-Object { $_.pattern }) | Should -Be @('backoffice.package-copied-assets')
        } finally { Remove-TestDirectory $d }
    }

    It 'lists the patterns that need package metadata' {
        $r = Find-PatternHits -Root (Get-FixturePath 'gen.v13')
        foreach ($id in @('pkg.renamed-community', 'pkg.no-target-version', 'pkg.framework-only-libs')) { $r.requiresPackageMetadata | Should -Contain $id }
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
    BeforeAll {
        $script:schema = ConvertTo-PlainObject (Read-JsonFile (Join-Path (Get-RepoRoot) 'schemas/pattern.schema.json'))
        $script:files = @(Get-ChildItem -LiteralPath (Join-Path (Get-RepoRoot) 'knowledge/patterns') -Filter '*.json')
    }

    It 'every record validates against the pattern schema and is named after its id' {
        foreach ($f in $script:files) {
            $plain = ConvertTo-PlainObject (Read-JsonFile $f.FullName)
            $errors = Test-JsonSchema -Value $plain -Schema $script:schema
            ($errors -join '; ') | Should -Be '' -Because $f.Name
            $plain['id'] | Should -Be $f.BaseName
        }
    }

    It 'every detector regex compiles and every detector without a derivation names files' {
        foreach ($p in (Get-PatternRegistry)) {
            foreach ($d in @($p.detectors)) {
                if ($null -eq $d) { continue }
                if ($d.PSObject.Properties['regex']) { { [regex]::new($d.regex) } | Should -Not -Throw }
                if (-not $d.PSObject.Properties['derived']) { @($d.files).Count | Should -BeGreaterThan 0 -Because "$($p.id)/$($d.id)" }
            }
        }
    }

    It 'a verified record cites an official page with an evidence phrase for every impact' {
        foreach ($p in (Get-PatternRegistry)) {
            $impacts = @($p.impact)
            if ($p.status -eq 'verified') {
                $impacts.Count | Should -BeGreaterThan 0
                foreach ($i in $impacts) {
                    $i.status | Should -Be 'verified' -Because $p.id
                    @($i.sources).Count | Should -BeGreaterThan 0 -Because $p.id
                }
            } else {
                @($impacts | Where-Object { $_.status -ne 'verified' }).Count + [int]($impacts.Count -eq 0) | Should -BeGreaterThan 0 -Because "$($p.id) is a hypothesis only when some impact is unverified"
            }
            foreach ($i in $impacts) {
                foreach ($s in @($i.sources)) { $s.url | Should -Match '^https://(docs\.umbraco\.com|learn\.microsoft\.com|raw\.githubusercontent\.com)/' }
            }
        }
    }

    It 'handling options are lists, each cited or marked hypothesis' {
        foreach ($p in (Get-PatternRegistry)) {
            @($p.handling).Count | Should -BeGreaterThan 0 -Because $p.id
            foreach ($h in @($p.handling)) {
                if ($h.status -eq 'verified') { @($h.sources).Count | Should -BeGreaterThan 0 -Because "$($p.id)/$($h.id)" }
                else { $h.status | Should -Be 'hypothesis' }
            }
        }
    }

    It 'every owner and involved skill exists' {
        foreach ($p in (Get-PatternRegistry)) {
            foreach ($o in @($p.owner) + @($(if ($p.PSObject.Properties['involves']) { $p.involves } else { @() }))) {
                Test-Path (Join-Path (Get-RepoRoot) "skills/$o/SKILL.md") | Should -BeTrue -Because "$($p.id) names $o"
            }
        }
    }

    It 'contains every common pattern and every coverage-gap pattern of the design' {
        $ids = @((Get-PatternRegistry) | ForEach-Object { $_.id })
        $expected = @(
            'code.render-controller', 'code.surface-controller', 'code.frontend-api-controller', 'code.mvc5-razor-features', 'code.static-service-access',
            'code.content-mapping-library', 'code.custom-routing', 'code.content-write', 'code.xpath-and-settings-nodes', 'code.hardcoded-ids',
            'code.webforms', 'code.vendored-source', 'data.custom-tables', 'data.raw-sql-custom', 'data.raw-sql-core-tables', 'data.secondary-datastore',
            'data.db-health', 'content.models-builder', 'content.legacy-grid', 'content.macros', 'content.legacy-structured-editors', 'content.block-editors',
            'content.non-core-editor-data', 'content.datatype-config-reads', 'content.model-source-of-truth', 'content.forms', 'content.code-first-doctypes',
            'content.razor-compilation', 'content.legacy-picker-values', 'content.element-type-consistency', 'api.event-handlers', 'api.composition-di',
            'api.content-finders-errors', 'api.value-converters', 'api.runtime-file-writes', 'backoffice.angular-property-editor', 'backoffice.dashboard',
            'backoffice.section-tree', 'backoffice.authorized-api', 'backoffice.package-copied-assets', 'backoffice.orphan-plugin-folder',
            'backoffice.modern-extension', 'auth.member-flows', 'auth.custom-roles', 'auth.external-member-login', 'auth.access-rules',
            'auth.backoffice-users-permissions', 'ext.soap-client', 'ext.http-client', 'ext.payment-gateway', 'ext.smtp', 'jobs.scheduled-work',
            'jobs.search-indexing', 'jobs.app-caching', 'jobs.cdn-purge', 'config.legacy-settings', 'config.startup-hosting', 'config.static-readers',
            'config.committed-secrets', 'config.untracked-environment-config', 'config.logging', 'config.bundling', 'pkg.core-id-changes',
            'pkg.renamed-community', 'pkg.no-target-version', 'pkg.framework-only-libs', 'pkg.loose-binaries', 'pkg.implicit-transitive',
            'deploy.ci-pipelines', 'deploy.iis-config', 'deploy.submodules-artifacts',
            'content.multilingual-variants', 'content.media-filesystem-provider', 'content.deploy-or-courier', 'api.url-providers', 'api.content-apps',
            'api.health-checks', 'jobs.webhooks', 'jobs.delivery-api', 'auth.backoffice-external-login', 'auth.two-factor', 'auth.custom-user-permissions',
            'data.non-sqlserver-engine', 'deploy.containers-or-cloud', 'pkg.commerce-or-workflow-products', 'code.unclassified-umbraco-usage')
        foreach ($e in $expected) { $ids | Should -Contain $e }
        foreach ($g in @('content.multilingual-variants', 'content.media-filesystem-provider', 'content.deploy-or-courier', 'api.url-providers', 'api.content-apps', 'api.health-checks', 'jobs.webhooks', 'jobs.delivery-api', 'auth.backoffice-external-login', 'auth.two-factor', 'auth.custom-user-permissions', 'deploy.containers-or-cloud', 'pkg.commerce-or-workflow-products')) {
            ((Get-PatternRegistry) | Where-Object { $_.id -eq $g }).flagOnly | Should -BeTrue -Because "$g is detect-and-flag"
        }
    }

    It 'patterns the path selection scores by id exist' {
        Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Knowledge.psm1') -Force -DisableNameChecking
        $paths = (Get-KnowledgeFile -Kind paths).data
        $ids = @((Get-PatternRegistry) | ForEach-Object { $_.id })
        foreach ($s in @($paths['scoring'])) { if ($s['when'].Contains('pattern')) { $ids | Should -Contain $s['when']['pattern'] } }
    }
}
