# Documentation retrieval (Get-Doc.ps1) and package metadata (Get-NuGetPackageInfo.ps1).
# Label: mocked. HTTP responses come from tests/fixtures/mocks (real responses recorded on 2026-10-14).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    $script:Mocks = Get-MockSet @('m.docs', 'm.nuget')
    function Invoke-Doc([string[]]$Arguments, [string]$DataDir, [string]$Mock = $script:Mocks) {
        $a = @($Arguments)
        if ($DataDir) { $a += @('-DataDir', $DataDir) }
        return Invoke-PluginScript -Script 'scripts/Get-Doc.ps1' -Arguments $a -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = $Mock }
    }
    function Get-Sha256Hex([string]$Text) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (($sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
    }
}

Describe 'Version-space resolution' -Tag 'mocked' {
    BeforeAll { $script:dd = New-TestDirectory -Prefix 'uud' }
    AfterAll { Remove-TestDirectory $script:dd }

    It 'resolves <major> <page> to <space>' -ForEach @(
        @{ major = 18; page = 'upgrade-details'; space = 'latest'; url = 'https://docs.umbraco.com/umbraco-cms/get-started/upgrading-and-migrating/upgrade-details.md' }
        @{ major = 17; page = 'upgrade-details'; space = 'versioned'; url = 'https://docs.umbraco.com/umbraco-cms/17.latest/get-started/upgrading-and-migrating/upgrade-details.md' }
        @{ major = 13; page = 'upgrade-details'; space = 'versioned'; url = 'https://docs.umbraco.com/umbraco-cms/13.latest/fundamentals/setup/upgrading.md' }
        @{ major = 13; page = 'breaking-changes'; space = 'versioned'; url = 'https://docs.umbraco.com/umbraco-cms/13.latest/fundamentals/setup/upgrading/version-specific.md' }
        @{ major = 16; page = 'upgrade-details'; space = 'eol'; url = 'https://raw.githubusercontent.com/umbraco/UmbracoDocs/umbraco-eol-versions/16/umbraco-cms/fundamentals/setup/upgrading/README.md' }
        @{ major = 16; page = 'breaking-changes'; space = 'eol'; url = 'https://raw.githubusercontent.com/umbraco/UmbracoDocs/umbraco-eol-versions/16/umbraco-cms/fundamentals/setup/upgrading/version-specific/README.md' }
    ) {
        $r = Invoke-Doc @('-Major', $major, '-Page', $page, '-AppliesTo', 'target') $script:dd
        $r.ExitCode | Should -Be 0
        $r.Json.status | Should -Be 'ok'
        $r.Json.space | Should -Be $space
        $r.Json.url | Should -Be $url
        $r.Json.major | Should -Be $major
        $r.Json.spaceSource.status | Should -Be 'verified'
    }

    It 'reports a page that a version does not have' {
        $r = Invoke-Doc @('-Major', '13', '-Page', 'migrate-content-15') $script:dd
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'no known path for Umbraco 13'
    }

    It 'reports no docs space for Umbraco 9' {
        $r = Invoke-Doc @('-Major', '9', '-Page', 'upgrade-details') $script:dd
        $r.ExitCode | Should -Be 1
        $r.Json.status | Should -Be 'unavailable'
    }

    It 'probes an unknown major and reports it unavailable when no branch has it' {
        $r = Invoke-Doc @('-Major', '25', '-Page', 'upgrade-details') $script:dd
        $r.Json.status | Should -Be 'unavailable'
        $r.Json.probed | Should -BeTrue
    }

    It 'refuses page keys for the legacy versions and points to -Path' {
        $r = Invoke-Doc @('-Major', '8', '-Page', 'upgrade-details') $script:dd
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match '-Path'
    }

    It 'treats the docs site Page Not Found answer (HTTP 200) as not-found and does not cache it' {
        $u = 'https://docs.umbraco.com/umbraco-cms/19.latest/get-started/upgrading-and-migrating/upgrade-details.md'
        $r = Invoke-Doc @('-Url', $u) $script:dd
        $r.Json.status | Should -Be 'not-found'
        $r.Json.httpStatus | Should -Be 200
        $r.Json.bodyPath | Should -BeNullOrEmpty
    }

    It 'rejects a redirect to another version as version-mismatch' {
        $u = 'https://docs.umbraco.com/umbraco-cms/16.latest/fundamentals/setup/upgrading/upgrade-details.md'
        $r = Invoke-Doc @('-Url', $u) $script:dd
        $r.Json.status | Should -Be 'version-mismatch'
        $r.Json.finalUrl | Should -Match '17\.latest'
        $r.Json.message | Should -Match 'different version'
    }

    It 'lists a version index from SUMMARY.md and from llms.txt' {
        $r = Invoke-Doc @('-Major', '16', '-Index', '-Find', 'Version Specific') $script:dd
        $r.Json.ok | Should -BeTrue
        $r.Json.space | Should -Be 'eol'
        @($r.Json.entries)[0].url | Should -Match '^https://raw\.githubusercontent\.com/umbraco/UmbracoDocs/umbraco-eol-versions/16/umbraco-cms/'
        $r2 = Invoke-Doc @('-Major', '13', '-Index', '-Find', 'upgrad') $script:dd
        $r2.Json.ok | Should -BeTrue
        @($r2.Json.entries).Count | Should -BeGreaterThan 0
        @($r2.Json.entries | Where-Object { $_.url -notmatch '/13\.latest/' }).Count | Should -Be 0
    }

    It 'only contacts allowlisted hosts' {
        $r = Invoke-Doc @('-Url', 'https://example.com/page.md') $script:dd
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'allowlist'
    }
}

Describe 'Documentation cache' -Tag 'mocked' {
    BeforeEach { $script:dd = New-TestDirectory -Prefix 'uud' }
    AfterEach { Remove-TestDirectory $script:dd }

    It 'stores the body with metadata, reuses it, and refreshes on request' {
        $r1 = Invoke-Doc @('-Major', '17', '-Page', 'upgrade-details', '-AppliesTo', 'target') $script:dd
        $r1.Json.fromCache | Should -BeFalse
        $r1.Json.bodyPath | Should -Not -BeNullOrEmpty
        $metaPath = [System.IO.Path]::ChangeExtension($r1.Json.bodyPath, '.json')
        $meta = Get-Content -Raw $metaPath | ConvertFrom-Json
        $meta.url | Should -Be $r1.Json.url
        $meta.finalUrl | Should -Be $r1.Json.url
        $meta.httpStatus | Should -Be 200
        $meta.fetchedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $meta.major | Should -Be 17
        $meta.space | Should -Be 'versioned'
        $meta.appliesTo | Should -Be 'target'
        $meta.sourceType | Should -Be 'official-docs'
        $meta.sha256 | Should -Be (Get-Sha256Hex ([System.IO.File]::ReadAllText($r1.Json.bodyPath)))
        $r1.Json.bodyPath.StartsWith((Join-Path $script:dd 'doc-cache')) | Should -BeTrue
        $r2 = Invoke-Doc @('-Major', '17', '-Page', 'upgrade-details') $script:dd
        $r2.Json.fromCache | Should -BeTrue
        $r3 = Invoke-Doc @('-Major', '17', '-Page', 'upgrade-details', '-Refresh') $script:dd
        $r3.Json.fromCache | Should -BeFalse
    }

    It 'returns a stale cached copy when the network fails' {
        $r1 = Invoke-Doc @('-Major', '18', '-Page', 'upgrade-details') $script:dd
        $r1.Json.status | Should -Be 'ok'
        $empty = New-TestDirectory -Prefix 'uum'
        try {
            [System.IO.File]::WriteAllText((Join-Path $empty 'index.json'), '{ "entries": [] }')
            $r2 = Invoke-Doc @('-Major', '18', '-Page', 'upgrade-details', '-Refresh') $script:dd $empty
            $r2.Json.status | Should -Be 'ok'
            $r2.Json.fromCache | Should -BeTrue
            $r2.Json.stale | Should -BeTrue
        } finally { Remove-TestDirectory $empty }
    }

    It 'works without a data directory (no cache) and prints the text' {
        $r = Invoke-Doc @('-Major', '18', '-Page', 'upgrade-details') ''
        $r.Json.status | Should -Be 'ok'
        $r.Json.bodyPath | Should -BeNullOrEmpty
        $r.Json.text | Should -Match 'Upgrade Your Project'
    }

    It 'refuses a data directory inside the plugin root' {
        $r = Invoke-Doc @('-Major', '18', '-Page', 'upgrade-details') (Join-Path (Get-RepoRoot) 'tests')
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'plugin root'
    }
}

Describe 'LTS and end-of-life dates' -Tag 'mocked' {
    It 'falls back to the labelled secondary source when the official page is blocked' {
        $dd = New-TestDirectory -Prefix 'uud'
        try {
            $r = Invoke-Doc @('-Major', '17', '-Lts') $dd
            $r.ExitCode | Should -Be 0
            $r.Json.officialStatus | Should -Be 'blocked'
            $r.Json.sourceType | Should -Be 'secondary'
            $r.Json.label | Should -Match 'Secondary source'
            $r.Json.needsUserConfirmation | Should -BeTrue
            $r.Json.confirmUrl | Should -Be 'https://umbraco.com/products/knowledge-center/long-term-support-and-end-of-life/'
            $r.Json.data.endOfLife | Should -Be '2028-11-27'
            $r.Json.data.lts | Should -BeTrue
        } finally { Remove-TestDirectory $dd }
    }

    It 'reports an error when neither source answers' {
        $empty = New-TestDirectory -Prefix 'uum'
        try {
            [System.IO.File]::WriteAllText((Join-Path $empty 'index.json'), '{ "entries": [] }')
            $r = Invoke-Doc @('-Major', '17', '-Lts') '' $empty
            $r.ExitCode | Should -Be 1
            $r.Json.ok | Should -BeFalse
        } finally { Remove-TestDirectory $empty }
    }
}

Describe 'NuGet package metadata' -Tag 'mocked' {
    BeforeAll {
        function Invoke-NuGet([string[]]$Arguments) {
            return Invoke-PluginScript -Script 'scripts/Get-NuGetPackageInfo.ps1' -Arguments $Arguments -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = (Get-MockSet 'm.nuget') }
        }
    }

    It 'resolves the latest release of a major with its framework and dependency ranges' {
        $r = Invoke-NuGet @('-PackageId', 'Umbraco.Cms', '-Major', '17')
        $r.ExitCode | Should -Be 0
        $r.Json.found | Should -BeTrue
        $r.Json.resolved.version | Should -Be '17.7.1'
        $r.Json.nuspec.data.targetFrameworks | Should -Be @('net10.0')
        @($r.Json.nuspec.data.dependencies | Where-Object { $_.id -eq 'Umbraco.Cms.Persistence.SqlServer' })[0].range | Should -Be '[17.7.1, 18.0.0)'
        $r.Json.latestStable | Should -Be '18.2.1'
        @($r.Json.majors | Where-Object { $_.major -eq 13 })[0].latest | Should -Be '13.16.2'
    }

    It 'reports a package that does not exist without failing' {
        $r = Invoke-NuGet @('-PackageId', 'Does.Not.Exist.Sample')
        $r.ExitCode | Should -Be 0
        $r.Json.found | Should -BeFalse
        $r.Json.message | Should -Match 'does not exist'
    }

    It 'reads publication and listing from the registration index' {
        $r = Invoke-NuGet @('-PackageId', 'Umbraco.ModelsBuilder', '-Version', '8.1.6', '-Registration', '-NoNuspec')
        $r.Json.registration.found | Should -BeTrue
        $r.Json.registration.published | Should -Match '^\d{4}-\d{2}-\d{2}'
        $r.Json.registration.listed | Should -BeTrue
    }

    It 'rejects an invalid package id' {
        $r = Invoke-NuGet @('-PackageId', '../etc')
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'Invalid package id'
    }
}
