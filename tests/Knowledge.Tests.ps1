# Version knowledge: baseline integrity, lookup order (baseline versus refreshed data), and the maintainer diff.
# Label: fixture-based (the shipped knowledge files and synthetic refreshed copies in temporary data directories).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Compat.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Knowledge.psm1') -Force -DisableNameChecking
    function Get-Baseline([string]$Kind) { return ConvertTo-PlainObject (Read-JsonFile (Get-BaselineKnowledgePath $Kind)) }
    function Write-Refreshed([string]$DataDir, [string]$Kind, $Document) {
        Write-TextFile -Path (Join-Path (Join-Path $DataDir 'knowledge') "$Kind.json") -Content (ConvertTo-StableJson $Document)
    }
    function Invoke-Knowledge([string[]]$Arguments) { return Invoke-PluginScript -Script 'scripts/Get-VersionKnowledge.ps1' -Arguments $Arguments }
}

Describe 'Baseline knowledge' -Tag 'fixture-based' {
    It '<kind>.json validates against the schema and is in canonical form' -ForEach @(
        @{ kind = 'versions' }, @{ kind = 'paths' }, @{ kind = 'packages' }, @{ kind = 'sources' }
    ) {
        $d = Get-Baseline $kind
        (Test-KnowledgeDocument -Document $d -Kind $kind).Count | Should -Be 0
        $raw = [System.IO.File]::ReadAllText((Get-BaselineKnowledgePath $kind)) -replace "`r`n", "`n"
        $raw | Should -BeExactly (ConvertTo-StableJson $d)
    }

    It 'every fact carries a source URL, the version it applies to, the source version, and a verification date' {
        foreach ($kind in (Get-KnowledgeKinds)) {
            foreach ($item in (Get-FactList (Get-Baseline $kind))) {
                $f = $item.fact; $where = "$kind $($item.path)"
                $f.status | Should -BeIn @('verified', 'secondary') -Because $where
                $f.source | Should -Match '^https://' -Because $where
                $f.appliesTo | Should -Not -BeNullOrEmpty -Because $where
                $f.sourceVersion | Should -Not -BeNullOrEmpty -Because $where
                $f.verifiedAt | Should -Match '^\d{4}-\d{2}-\d{2}$' -Because $where
                if ($f.status -eq 'secondary') { $f.sourceType | Should -Be 'secondary' -Because $where } else { $f.sourceType | Should -Not -Be 'secondary' -Because $where }
                if ($f.Contains('evidence')) { @($f.evidence -split '\s+').Count | Should -BeLessOrEqual 25 -Because "$where evidence is a short phrase" }
            }
        }
    }

    It 'covers every major from 7 to 18 with the required facts' {
        $v = Get-Baseline 'versions'
        @($v.majors | ForEach-Object { [int]$_.major }) | Should -Be (7..18)
        foreach ($m in $v.majors) {
            foreach ($name in @('releaseDate', 'lts', 'endOfSupport', 'endOfLife', 'dotnet', 'latestKnown', 'docsSpace')) { Test-IsFact $m[$name] | Should -BeTrue -Because "$($m.major).$name" }
        }
    }

    It 'keeps LTS status official where documented and labels the rest secondary' {
        $v = Get-Baseline 'versions'
        foreach ($m in 13, 17) { (Get-MajorEntry $v $m).lts.value | Should -BeTrue; (Get-MajorEntry $v $m).lts.status | Should -Be 'verified' }
        foreach ($m in 11, 12, 14, 15, 16, 18) { (Get-MajorEntry $v $m).lts.value | Should -BeFalse; (Get-MajorEntry $v $m).lts.status | Should -Be 'verified' }
        foreach ($m in 7, 8, 9, 10) { (Get-MajorEntry $v $m).lts.status | Should -Be 'secondary' }
        foreach ($m in $v.majors) { $m.endOfLife.status | Should -Be 'secondary'; $m.endOfSupport.status | Should -Be 'secondary' }
    }

    It 'takes package mappings only from package metadata' {
        $p = Get-Baseline 'packages'
        foreach ($x in @($p.mappings) + @($p.noSuccessor) + @($p.corePackages)) { $x.fact.sourceType | Should -Be 'package-metadata' }
    }

    It 'allows only the hosts its URL templates use' {
        $s = Get-Baseline 'sources'
        $urls = @($s.docs.spaces | ForEach-Object { $_.urlTemplate; $_.indexTemplate }) + @($s.nuget.flatContainer, $s.nuget.registration, $s.dotnet.releasesIndex, $s.releases.home, $s.lts.official, $s.lts.secondary)
        foreach ($u in $urls) { $s.hosts | Should -Contain ([uri]($u -replace '[{}]', '')).Host }
    }

    It 'rejects a fact without its source fields' {
        $v = Get-Baseline 'versions'
        $v.majors[0].lts.Remove('appliesTo')
        (Test-KnowledgeDocument -Document $v -Kind 'versions') -join ' ' | Should -Match "missing required property 'appliesTo'"
    }
}

Describe 'Knowledge lookup order' -Tag 'fixture-based' {
    BeforeEach { $script:dd = New-TestDirectory -Prefix 'uud' }
    AfterEach { Remove-TestDirectory $script:dd }

    It 'uses the baseline without a data directory' {
        $r = Invoke-Knowledge @()
        $r.ExitCode | Should -Be 0
        foreach ($k in 'versions', 'paths', 'packages', 'sources') { $r.Json.files.$k.origin | Should -Be 'baseline' }
        $r.Json.files.versions.reason | Should -Match 'no plugin data directory'
    }

    It 'uses the baseline when the data directory has no refreshed knowledge' {
        $r = Invoke-Knowledge @('-DataDir', $script:dd)
        $r.Json.files.versions.origin | Should -Be 'baseline'
        $r.Json.files.versions.reason | Should -Be 'no refreshed data'
    }

    It 'uses newer refreshed data, per file' {
        $v = Get-Baseline 'versions'
        $v.verifiedAt = '2099-01-01'; $v.verifiedBy = 'update-knowledge'
        (Get-MajorEntry $v 18).latestKnown.value = '18.9.9'
        Write-Refreshed $script:dd 'versions' $v
        $r = Invoke-Knowledge @('-DataDir', $script:dd, '-Major', '18')
        $r.Json.files.versions.origin | Should -Be 'refreshed'
        $r.Json.files.versions.verifiedAt | Should -Be '2099-01-01'
        $r.Json.files.paths.origin | Should -Be 'baseline'
        $r.Json.data.latestKnown.value | Should -Be '18.9.9'
    }

    It 'accepts a newer minor schema version' {
        $v = Get-Baseline 'versions'
        $v.verifiedAt = '2099-01-01'; $v.schemaVersion = '1.1.0'
        Write-Refreshed $script:dd 'versions' $v
        (Invoke-Knowledge @('-DataDir', $script:dd)).Json.files.versions.origin | Should -Be 'refreshed'
    }

    It 'falls back to the baseline when the refreshed schema major is incompatible' {
        $v = Get-Baseline 'versions'
        $v.verifiedAt = '2099-01-01'; $v.schemaVersion = '2.0.0'
        Write-Refreshed $script:dd 'versions' $v
        $r = Invoke-Knowledge @('-DataDir', $script:dd)
        $r.Json.files.versions.origin | Should -Be 'baseline'
        $r.Json.files.versions.reason | Should -Match 'not compatible'
    }

    It 'falls back to the baseline when the refreshed data is not newer' -ForEach @(@{ date = '2020-01-01' }, @{ date = '2026-10-14' }) {
        $v = Get-Baseline 'versions'
        $v.verifiedAt = $date
        Write-Refreshed $script:dd 'versions' $v
        $r = Invoke-Knowledge @('-DataDir', $script:dd)
        $r.Json.files.versions.origin | Should -Be 'baseline'
        $r.Json.files.versions.reason | Should -Match 'not newer'
    }

    It 'falls back to the baseline when the refreshed file is invalid or unreadable' {
        $p = Get-Baseline 'paths'
        $p.verifiedAt = '2099-01-01'; $p.Remove('rules')
        Write-Refreshed $script:dd 'paths' $p
        Write-TextFile -Path (Join-Path $script:dd 'knowledge/packages.json') -Content '{ not json'
        $r = Invoke-Knowledge @('-DataDir', $script:dd)
        $r.Json.files.paths.origin | Should -Be 'baseline'
        $r.Json.files.paths.reason | Should -Match 'invalid'
        $r.Json.files.packages.origin | Should -Be 'baseline'
        $r.Json.files.packages.reason | Should -Match 'unreadable'
    }

    It 'is the knowledge path selection uses' {
        $v = Get-Baseline 'versions'
        $v.verifiedAt = '2099-01-01'
        (Get-MajorEntry $v 17).latestKnown.value = '17.9.9'
        Write-Refreshed $script:dd 'versions' $v
        $r = Invoke-PluginScript -Script 'scripts/Select-UpgradePath.ps1' -Arguments @('-Source', '13.10.1', '-Target', '17', '-Engine', 'sqlserver', '-Offline', '-DataDir', $script:dd) -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = (Get-MockSet 'm.docs') }
        $r.Json.target.resolved | Should -Be '17.9.9'
        $r.Json.knowledge.versions.origin | Should -Be 'refreshed'
    }

    It 'refuses a data directory inside the plugin root' {
        $r = Invoke-Knowledge @('-DataDir', (Join-Path (Get-RepoRoot) 'knowledge'))
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'plugin root'
    }

    It 'reports a major that is not in the knowledge' {
        $r = Invoke-Knowledge @('-Major', '25')
        $r.Json.known | Should -BeFalse
        $r.Json.message | Should -Match 'unverified'
    }
}

Describe 'Maintainer diff' -Tag 'fixture-based' {
    It 'produces a patch that git apply accepts: <name>' -ForEach @(
        @{ name = 'change in the middle'; old = "a`nb`nc`nd`ne`nf`ng`nh`n"; new = "a`nb`nc`nX`ne`nf`ng`nh`n" }
        @{ name = 'insert at the start, delete at the end'; old = "a`nb`nc`nd`n"; new = "Z`na`nb`nc`n" }
        @{ name = 'two separate hunks'; old = (((1..30) | ForEach-Object { "l$_" }) -join "`n") + "`n"; new = (((1..30) | ForEach-Object { if ($_ -in 3, 25) { "x$_" } else { "l$_" } }) -join "`n") + "`n" }
        @{ name = 'new file content'; old = ''; new = "a`nb`n" }
    ) {
        $dir = New-TestDirectory -Prefix 'uup'
        try {
            Initialize-GitRepo -Path $dir
            $f = Join-Path $dir 'file.txt'
            [System.IO.File]::WriteAllText($f, $old)
            $null = & git -C $dir add -A 2>&1
            $null = & git -C $dir commit -q -m base --allow-empty 2>&1
            $patch = "diff --git a/file.txt b/file.txt`n" + (New-UnifiedDiff -OldText $old -NewText $new -OldName 'a/file.txt' -NewName 'b/file.txt')
            $pf = Join-Path $dir 'change.patch'
            [System.IO.File]::WriteAllText($pf, $patch)
            $null = & git -C $dir apply $pf 2>&1
            $LASTEXITCODE | Should -Be 0
            ([System.IO.File]::ReadAllText($f) -replace "`r`n", "`n") | Should -BeExactly $new
        } finally { Remove-TestDirectory $dir }
    }

    It 'is empty for equal texts' {
        New-UnifiedDiff -OldText "a`nb`n" -NewText "a`r`nb`r`n" -OldName a -NewName b | Should -Be ''
    }
}
