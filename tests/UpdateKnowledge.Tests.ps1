# /umbraco-upgrade:update-knowledge (Update-Knowledge.ps1): writes refreshed, verified data and a maintainer diff
# to the plugin data directory, never to the plugin root.
# Label: mocked. Responses come from tests/fixtures/mocks (real responses recorded on 2026-10-14; the
# future-major and changed-page sets are derived and marked as such).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Compat.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Knowledge.psm1') -Force -DisableNameChecking
    function Invoke-Update([string]$DataDir, [string[]]$Mocks) {
        return Invoke-PluginScript -Script 'scripts/Update-Knowledge.ps1' -Arguments @('-DataDir', $DataDir) -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = (Get-MockSet $Mocks) }
    }
    function Get-KnowledgeHashes {
        $h = @{}
        foreach ($f in (Get-ChildItem -LiteralPath (Join-Path (Get-RepoRoot) 'knowledge') -Recurse -File)) { $h[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
        return $h
    }
    function Read-Refreshed([string]$DataDir, [string]$Kind) { return ConvertTo-PlainObject (Read-JsonFile (Join-Path $DataDir "knowledge/$Kind.json")) }
    $script:today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
}

Describe 'Refresh from the recorded sources' -Tag 'mocked' {
    BeforeAll {
        $script:dd = New-TestDirectory -Prefix 'uud'
        $script:before = Get-KnowledgeHashes
        $script:r = Invoke-Update $script:dd @('m.docs', 'm.nuget')
    }
    AfterAll { Remove-TestDirectory $script:dd }

    It 'succeeds and writes the refreshed files, report, and patch only to the data directory' {
        $script:r.ExitCode | Should -Be 0
        $script:r.Json.ok | Should -BeTrue
        foreach ($k in 'versions', 'paths', 'packages', 'sources') { Test-Path (Join-Path $script:dd "knowledge/$k.json") | Should -BeTrue }
        Test-Path (Join-Path $script:dd 'knowledge/maintainer.patch') | Should -BeTrue
        Test-Path (Join-Path $script:dd 'knowledge/refresh-report.md') | Should -BeTrue
        Test-Path (Join-Path $script:dd 'knowledge/refresh-report.json') | Should -BeTrue
        foreach ($w in @($script:r.Json.written)) { $w.StartsWith($script:dd) | Should -BeTrue }
    }

    It 'leaves the plugin root unchanged' {
        $after = Get-KnowledgeHashes
        $after.Count | Should -Be $script:before.Count
        foreach ($k in $script:before.Keys) { $after[$k] | Should -Be $script:before[$k] -Because $k }
    }

    It 're-confirms every evidence phrase and finds nothing to review' {
        $script:r.Json.reverified.confirmed | Should -BeGreaterThan 80
        $script:r.Json.reverified.missing | Should -Be 0
        $script:r.Json.reverified.unreachable | Should -Be 0
        @($script:r.Json.needsReview).Count | Should -Be 0
        @($script:r.Json.unreachable).Count | Should -Be 0
        # latestKnown follows NuGet releases: a baseline updated after the 2026-10-14 recording differs only there.
        @($script:r.Json.valueChanges | Where-Object { $_.fact -notmatch '\.latestKnown$' }).Count | Should -Be 0
        @($script:r.Json.newMajors).Count | Should -Be 0
    }

    It 'writes valid knowledge stamped by update-knowledge, keeping secondary facts secondary' {
        foreach ($k in (Get-KnowledgeKinds)) {
            $d = Read-Refreshed $script:dd $k
            (Test-KnowledgeDocument -Document $d -Kind $k).Count | Should -Be 0
            $d.verifiedBy | Should -Be 'update-knowledge'
            $d.verifiedAt | Should -Be $script:today
        }
        $v = Read-Refreshed $script:dd 'versions'
        (Get-MajorEntry $v 17).endOfLife.status | Should -Be 'secondary'
        (Get-MajorEntry $v 17).lts.status | Should -Be 'verified'
        (Get-MajorEntry $v 18).minUpgradeFrom.verifiedBy | Should -Be 'update-knowledge'
    }

    It 'notes that the official LTS page was not readable' {
        ($script:r.Json.notes -join ' ') | Should -Match 'official LTS and end-of-life page was not readable \(blocked\)'
    }

    It 'produces a maintainer patch that turns the baseline into the refreshed files' {
        $repo = New-TestDirectory -Prefix 'uup'
        try {
            Initialize-GitRepo -Path $repo
            Copy-Item -Recurse -LiteralPath (Join-Path (Get-RepoRoot) 'knowledge') -Destination (Join-Path $repo 'knowledge')
            Get-ChildItem -LiteralPath (Join-Path $repo 'knowledge') -Recurse -File | ForEach-Object { [System.IO.File]::WriteAllText($_.FullName, ([System.IO.File]::ReadAllText($_.FullName) -replace "`r`n", "`n")) }
            $null = & git -C $repo add -A 2>&1
            $null = & git -C $repo commit -q -m base 2>&1
            $null = & git -C $repo apply (Join-Path $script:dd 'knowledge/maintainer.patch') 2>&1
            $LASTEXITCODE | Should -Be 0
            foreach ($k in 'versions', 'paths', 'packages', 'sources') {
                ([System.IO.File]::ReadAllText((Join-Path $repo "knowledge/$k.json")) -replace "`r`n", "`n") | Should -BeExactly ([System.IO.File]::ReadAllText((Join-Path $script:dd "knowledge/$k.json")))
            }
        } finally { Remove-TestDirectory $repo }
    }

    It 'is used by the lookup order only once it is newer than the baseline' {
        $k = Invoke-PluginScript -Script 'scripts/Get-VersionKnowledge.ps1' -Arguments @('-DataDir', $script:dd)
        $baselineDate = [string](Read-JsonFile (Join-Path (Get-RepoRoot) 'knowledge/versions.json')).verifiedAt
        $expected = $(if ($script:today -gt $baselineDate) { 'refreshed' } else { 'baseline' })
        $k.Json.files.versions.origin | Should -Be $expected
        $script:r.Json.refreshedDataInUse | Should -Be ($expected -eq 'refreshed')
    }
}

Describe 'Refresh with a new major on NuGet' -Tag 'mocked' {
    It 'adds the major with its framework from the nuspec and every other fact unverified' {
        $dd = New-TestDirectory -Prefix 'uud'
        try {
            $r = Invoke-Update $dd @('m.nuget.future-major', 'm.docs', 'm.nuget')
            $r.ExitCode | Should -Be 0
            @($r.Json.newMajors | ForEach-Object { $_.major }) | Should -Contain 25
            ($r.Json.newMajors | Where-Object { $_.major -eq 25 }).latest | Should -Be '25.1.0'
            $v = Read-Refreshed $dd 'versions'
            $e = Get-MajorEntry $v 25
            $e | Should -Not -BeNullOrEmpty
            $e.dotnet.value | Should -Be 'net99.0'
            $e.dotnet.status | Should -Be 'verified'
            $e.dotnet.sourceType | Should -Be 'package-metadata'
            $e.lts.status | Should -Be 'unverified'
            $e.lts.value | Should -BeNullOrEmpty
            $e.endOfLife.status | Should -Be 'unverified'
            $e.releaseDate.status | Should -Be 'unverified'
            $e.Contains('minUpgradeFrom') | Should -BeFalse
            @($v.dotnetChannels | ForEach-Object { $_.channel }) | Should -Contain '99.0'
            (Get-Content -Raw (Join-Path $dd 'knowledge/refresh-report.md')) | Should -Match '25 \(latest 25\.1\.0\)'
        } finally { Remove-TestDirectory $dd }
    }
}

Describe 'Refresh with a pre-release major' -Tag 'mocked' {
    It 'reports its prerelease and its pre-release docs space as upcoming and adds nothing' {
        $dd = New-TestDirectory -Prefix 'uud'
        try {
            $r = Invoke-Update $dd @('m.docs.future-space', 'm.nuget.future-prerelease', 'm.docs', 'm.nuget')
            $r.ExitCode | Should -Be 0
            $up = @($r.Json.upcoming | Where-Object { $_.major -eq 25 })
            $up.Count | Should -Be 1
            $up[0].latestPrerelease | Should -Be '25.0.0-rc1'
            $up[0].docsSpace | Should -Be '25.latest'
            @($r.Json.newMajors).Count | Should -Be 0
            $v = Read-Refreshed $dd 'versions'
            Get-MajorEntry $v 25 | Should -BeNullOrEmpty
            (Get-MajorEntry $v 18).docsSpace.value | Should -Be 'latest'
            @($r.Json.valueChanges | Where-Object { $_.fact -like '*docsSpace' }).Count | Should -Be 0
            (Get-Content -Raw (Join-Path $dd 'knowledge/refresh-report.md')) | Should -Match '(?m)^- 25: prereleases only on NuGet \(latest 25\.0\.0-rc1\); docs space 25\.latest \(pre-release documentation\)\. Not added'
        } finally { Remove-TestDirectory $dd }
    }

    It 'reports a pre-release docs space on its own when NuGet has no release of that major' {
        $dd = New-TestDirectory -Prefix 'uud'
        try {
            $r = Invoke-Update $dd @('m.docs.future-space', 'm.docs', 'm.nuget')
            $r.ExitCode | Should -Be 0
            $up = @($r.Json.upcoming | Where-Object { $_.major -eq 25 })
            $up.Count | Should -Be 1
            $up[0].docsSpace | Should -Be '25.latest'
            $up[0].latestPrerelease | Should -BeNullOrEmpty
            Get-MajorEntry (Read-Refreshed $dd 'versions') 25 | Should -BeNullOrEmpty
        } finally { Remove-TestDirectory $dd }
    }
}

Describe 'Refresh when a source page changed' -Tag 'mocked' {
    It 'marks the fact needs-review and keeps its value' {
        $dd = New-TestDirectory -Prefix 'uud'
        try {
            $r = Invoke-Update $dd @('m.docs.changed', 'm.docs', 'm.nuget')
            $r.ExitCode | Should -Be 0
            $item = @($r.Json.needsReview | Where-Object { $_.fact -like 'versions*major=18*minUpgradeFrom' })
            $item.Count | Should -Be 1
            $item[0].source | Should -Match 'upgrade-details\.md$'
            $f = (Get-MajorEntry (Read-Refreshed $dd 'versions') 18).minUpgradeFrom
            $f.status | Should -Be 'needs-review'
            $f.value | Should -Be '16.4.0'
        } finally { Remove-TestDirectory $dd }
    }
}

Describe 'Refresh failures' -Tag 'mocked' {
    It 'writes nothing when no source is reachable' {
        $dd = New-TestDirectory -Prefix 'uud'
        $empty = New-TestDirectory -Prefix 'uum'
        try {
            [System.IO.File]::WriteAllText((Join-Path $empty 'index.json'), '{ "entries": [] }')
            $r = Invoke-PluginScript -Script 'scripts/Update-Knowledge.ps1' -Arguments @('-DataDir', $dd) -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = $empty }
            $r.ExitCode | Should -Be 1
            $r.Json.error | Should -Match 'No source was reachable'
            Test-Path (Join-Path $dd 'knowledge/versions.json') | Should -BeFalse
        } finally { Remove-TestDirectory $dd; Remove-TestDirectory $empty }
    }

    It 'refuses to write into the plugin root' {
        $r = Invoke-PluginScript -Script 'scripts/Update-Knowledge.ps1' -Arguments @('-DataDir', (Get-RepoRoot)) -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = (Get-MockSet 'm.docs') }
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'plugin root'
    }

    It 'needs a data directory' {
        $r = Invoke-PluginScript -Script 'scripts/Update-Knowledge.ps1' -Arguments @() -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = (Get-MockSet 'm.docs') }
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'DataDir'
    }
}
