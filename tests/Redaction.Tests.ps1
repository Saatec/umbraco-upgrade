# Redaction of planted fake secrets: they never appear in script output, evidence, or hook output.
# Labels: mocked (unit cases with constructed strings) and fixture-based (scripts on fixtures).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Redaction.psm1') -Force -DisableNameChecking
    $script:Marker = 'FAKE-SECRET-FOR-TESTS'
}

Describe 'Protect-Text' -Tag 'mocked' {
    It 'redacts <name>' -ForEach @(
        @{ name = 'a connection string password'; text = 'Server=localhost;Database=x;User ID=u;Password=FAKE-SECRET-FOR-TESTS-1;' }
        @{ name = 'a quoted connection string password'; text = '"umbracoDbDSN": "Server=.;Database=x;Pwd=FAKE-SECRET-FOR-TESTS-2;TrustServerCertificate=true"' }
        @{ name = 'a JSON api key'; text = '"ApiKey": "FAKE-SECRET-FOR-TESTS-3"' }
        @{ name = 'a JSON client secret'; text = '{ "ClientSecret" : "FAKE-SECRET-FOR-TESTS-4" }' }
        @{ name = 'an appSettings key and value'; text = '<add key="PaymentApiKey" value="FAKE-SECRET-FOR-TESTS-5" />' }
        @{ name = 'a machineKey attribute'; text = '<machineKey validationKey="FAKE-SECRET-FOR-TESTS-6" decryptionKey="FAKE-SECRET-FOR-TESTS-7" />' }
        @{ name = 'an SMTP password attribute'; text = '<network host="smtp.example.invalid" userName="u" password="FAKE-SECRET-FOR-TESTS-8" />' }
        @{ name = 'an env file line'; text = "SMTP_PASSWORD=FAKE-SECRET-FOR-TESTS-9`nOTHER=1" }
        @{ name = 'a code assignment'; text = 'private const string ApiToken = "FAKE-SECRET-FOR-TESTS-10";' }
        @{ name = 'a bearer header'; text = 'Authorization: Bearer FAKE-SECRET-FOR-TESTS-11abcdefgh' }
        @{ name = 'a SAS signature'; text = 'https://acct.blob.example.invalid/c?sv=2020&sig=FAKE-SECRET-FOR-TESTS-12' }
        @{ name = 'an account key'; text = 'DefaultEndpointsProtocol=https;AccountName=a;AccountKey=FAKE-SECRET-FOR-TESTS-13;EndpointSuffix=core.example.invalid' }
    ) {
        $out = Protect-Text $text
        $out | Should -Not -Match $script:Marker
        $out | Should -Match '\*\*\*REDACTED\*\*\*'
    }

    It 'redacts token formats built at run time' {
        $cases = @(
            ('AKIA' + ('Q' * 16)),
            ('ghp_' + ('a1B2' * 9)),
            ('eyJ' + ('a' * 12) + '.eyJ' + ('b' * 12) + '.' + ('c' * 12)),
            (("-----BEGIN RSA " + "PRIVATE KEY-----`n") + ("A" * 40) + ("`n-----END RSA " + "PRIVATE KEY-----"))
        )
        foreach ($c in $cases) { (Protect-Text "value: $c") | Should -Not -Match ([regex]::Escape($c)) }
    }

    It 'keeps <name>' -ForEach @(
        @{ name = 'version numbers'; text = '<add key="umbracoConfigurationStatus" value="7.15.10" />' }
        @{ name = 'booleans'; text = '"UseHttps": true, "KeepPassword": false' }
        @{ name = 'the server of a connection string'; text = 'Server=localhost;Database=SampleSite' }
        @{ name = 'a GUID'; text = '"Id": "00000000-0000-0000-0000-000000000013"' }
        @{ name = 'a file path'; text = '"view": "/App_Plugins/BadgeEditor2/badge.controller.js"' }
        @{ name = 'a package id'; text = '<package id="Umbraco.Cms.Web.BackOffice" version="13.10.1" />' }
    ) {
        (Protect-Text $text) | Should -Be $text
    }

    It 'keeps key names when it redacts values' {
        $out = Protect-Text '"ApiKey": "FAKE-SECRET-FOR-TESTS-14"'
        $out | Should -Match '"ApiKey"'
    }
}

Describe 'No planted fake secret leaves the scripts' -Tag 'fixture-based' {
    BeforeAll {
        $script:proj = Copy-Fixture -Baseline 'gen.v7' -Overlay 'p.data.custom-table.v7'
        Initialize-GitRepo -Path $script:proj -Commit
        $script:proj13 = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.ext.http-client'
        Initialize-GitRepo -Path $script:proj13 -Commit
    }
    AfterAll { Remove-TestDirectory $script:proj; Remove-TestDirectory $script:proj13 }

    It 'the fixtures do contain the planted secrets' {
        (Get-Content -Raw (Join-Path $script:proj 'web.config')) | Should -Match $script:Marker
        (Get-Content -Raw (Join-Path $script:proj13 'appsettings.Development.json')) | Should -Match $script:Marker
    }

    It 'discovery output and every evidence file are free of them (<baselineName>)' -ForEach @(@{ baselineName = 'v7' }, @{ baselineName = 'v13' }) {
        $p = $(if ($baselineName -eq 'v7') { $script:proj } else { $script:proj13 })
        $init = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('init', '-ProjectRoot', $p, '-Mode', 'plan', '-Target', '17')
        $init.ExitCode | Should -Be 0
        $r = Invoke-PluginScript -Script 'scripts/Invoke-Discovery.ps1' -Arguments @('-ProjectRoot', $p)
        $r.ExitCode | Should -Be 0
        ($r.StdOut + $r.StdErr) | Should -Not -Match $script:Marker
        $files = Get-ChildItem -LiteralPath (Join-Path $p '.umbraco-upgrade') -Recurse -File
        $files.Count | Should -BeGreaterThan 3
        foreach ($f in $files) { (Get-Content -Raw $f.FullName) | Should -Not -Match $script:Marker }
    }

    It 'the version, inventory, and pattern scripts print none (<script>)' -ForEach @(
        @{ script = 'scripts/Get-UmbracoVersion.ps1' }, @{ script = 'scripts/Get-ProjectInventory.ps1' }, @{ script = 'scripts/Find-Patterns.ps1' }
    ) {
        foreach ($p in @($script:proj, $script:proj13)) {
            $r = Invoke-PluginScript -Script $script -Arguments @('-Path', $p)
            $r.ExitCode | Should -Be 0
            ($r.StdOut + $r.StdErr) | Should -Not -Match $script:Marker
        }
    }

    It 'Read-RedactedConfig shows keys but not values (<file>)' -ForEach @(
        @{ file = 'web.config'; key = 'validationKey'; which = 'v7' }
        @{ file = 'appsettings.json'; key = 'umbracoDbDSN'; which = 'v13' }
        @{ file = 'appsettings.Development.json'; key = 'ApiKey'; which = 'v13' }
    ) {
        $p = $(if ($which -eq 'v7') { $script:proj } else { $script:proj13 })
        $r = Invoke-PluginScript -Script 'scripts/Read-RedactedConfig.ps1' -Arguments @('-Path', (Join-Path $p $file))
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match $key
        $r.StdOut | Should -Not -Match $script:Marker
    }

    It 'the PostToolUse redaction hook replaces secret values in an upgrade project' {
        $content = [System.IO.File]::ReadAllText((Join-Path $script:proj13 'appsettings.Development.json'))
        $payload = @{ session_id = 's'; cwd = $script:proj13; hook_event_name = 'PostToolUse'; tool_name = 'Read'
            tool_input = @{ file_path = (Join-Path $script:proj13 'appsettings.Development.json') }
            tool_response = @{ type = 'text'; file = @{ filePath = (Join-Path $script:proj13 'appsettings.Development.json'); content = $content; numLines = 6; startLine = 1; totalLines = 6 } } } | ConvertTo-Json -Depth 6 -Compress
        $r = Invoke-PluginScript -Script 'scripts/hooks/redact-output.ps1' -StdIn $payload
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Not -Match $script:Marker
        $j = $r.StdOut | ConvertFrom-Json
        $j.hookSpecificOutput.hookEventName | Should -Be 'PostToolUse'
        $j.hookSpecificOutput.updatedToolOutput.type | Should -Be 'text'
        $j.hookSpecificOutput.updatedToolOutput.file.content | Should -Match '"ApiKey": "\*\*\*REDACTED\*\*\*"'
        $j.hookSpecificOutput.updatedToolOutput.file.numLines | Should -Be 6
    }

    It 'the redaction hook keeps non-ASCII text intact' {
        $cafe = 'Caf' + [char]0x00E9 + ' ' + [char]0x00C5 + 'ngstr' + [char]0x00F6 + 'm'
        $content = "{ `"SiteName`": `"$cafe`", `"ApiKey`": `"FAKE-SECRET-FOR-TESTS-16`" }"
        $payload = @{ session_id = 's'; cwd = $script:proj13; hook_event_name = 'PostToolUse'; tool_name = 'Read'; tool_input = @{ file_path = (Join-Path $script:proj13 'appsettings.json') }
            tool_response = @{ type = 'text'; file = @{ filePath = (Join-Path $script:proj13 'appsettings.json'); content = $content; numLines = 1; startLine = 1; totalLines = 1 } } } | ConvertTo-Json -Depth 6 -Compress
        $r = Invoke-PluginScript -Script 'scripts/hooks/redact-output.ps1' -StdIn $payload
        $j = $r.StdOut | ConvertFrom-Json
        $j.hookSpecificOutput.updatedToolOutput.file.content | Should -Match ([regex]::Escape($cafe))
        $j.hookSpecificOutput.updatedToolOutput.file.content | Should -Not -Match $script:Marker
    }

    It 'the redaction hook stays silent outside upgrade projects' {
        $other = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.ext.http-client'
        try {
            $content = [System.IO.File]::ReadAllText((Join-Path $other 'appsettings.Development.json'))
            $payload = @{ session_id = 's'; cwd = $other; hook_event_name = 'PostToolUse'; tool_name = 'Read'; tool_input = @{ file_path = (Join-Path $other 'appsettings.Development.json') }
                tool_response = @{ type = 'text'; file = @{ filePath = 'x'; content = $content; numLines = 6; startLine = 1; totalLines = 6 } } } | ConvertTo-Json -Depth 6 -Compress
            $r = Invoke-PluginScript -Script 'scripts/hooks/redact-output.ps1' -StdIn $payload
            $r.ExitCode | Should -Be 0
            $r.StdOut | Should -BeNullOrEmpty
        } finally { Remove-TestDirectory $other }
    }

    It 'state refuses a value that looks like a secret' {
        $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('set', '-ProjectRoot', $script:proj, '-Section', 'source', '-Set', 'generation=Password=FAKE-SECRET-FOR-TESTS-15')
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'secret'
        (Get-Content -Raw (Join-Path $script:proj '.umbraco-upgrade/state.json')) | Should -Not -Match $script:Marker
    }
}
