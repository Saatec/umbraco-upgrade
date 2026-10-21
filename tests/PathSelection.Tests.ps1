# Upgrade path selection (Select-UpgradePath.ps1) on the baseline knowledge.
# Label: mocked. NuGet and documentation responses come from tests/fixtures/mocks (real responses recorded
# on 2026-10-14; the future-major sets are derived and marked as such). One case also uses synthetic fixtures.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    function Invoke-Select([string[]]$Arguments, [string[]]$Mocks = @('m.nuget')) {
        $dd = New-TestDirectory -Prefix 'uud'
        try {
            return Invoke-PluginScript -Script 'scripts/Select-UpgradePath.ps1' -Arguments (@($Arguments) + @('-DataDir', $dd)) -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = (Get-MockSet $Mocks) }
        } finally { Remove-TestDirectory $dd }
    }
    function Get-Recommended($Json) { return @($Json.candidates | Where-Object { $_.id -eq $Json.recommended })[0] }
    function Get-StepList($Candidate) { return @($Candidate.steps | ForEach-Object { "$($_.from)>$($_.to)" }) }
}

Describe 'Path selection for supported versions' -Tag 'mocked' {
    It '7 to 13: rebuild with database migration through 8.5, 8.18, and 10' {
        $r = Invoke-Select @('-Source', '7.15.10', '-Target', '13', '-Engine', 'sqlserver')
        $r.ExitCode | Should -Be 0
        $r.Json.status | Should -Be 'selected'
        $r.Json.target.resolved | Should -Be '13.16.2'
        $rec = Get-Recommended $r.Json
        $rec.strategy | Should -Be 'rebuild-with-database-migration'
        Get-StepList $rec | Should -Be @('7.15.10>8.5.5', '8.5.5>8.18.15', '8.18.15>10.8.11', '10.8.11>13.16.2')
        @($rec.steps | ForEach-Object { $_.type }) | Should -Be @('content-migration-new-install', 'minor-in-place', 'database-reuse-new-project', 'major-in-place')
        $rec.steps[0].rules | Should -Contain 'boundary.7-8'
        $rec.steps[2].rules | Should -Contain 'boundary.8-10'
        @($rec.steps[0].dataMigrations | ForEach-Object { $_.id }) | Should -Contain 'content-migration-from-7'
        @($rec.steps[2].dataMigrations | ForEach-Object { $_.id }) | Should -Contain 'database-migrations-from-8'
        @($r.Json.candidates | ForEach-Object { $_.strategy }) | Should -Not -Contain 'in-place'
        @($r.Json.alternatives | ForEach-Object { $_.strategy }) | Should -Contain 'new-install-with-content-transfer'
    }

    It '7 to 17: continues from 13 to 17 after the closest-LTS stop' {
        $r = Invoke-Select @('-Source', '7.15.10', '-Target', '17', '-Engine', 'sqlserver')
        $r.Json.status | Should -Be 'selected'
        $rec = Get-Recommended $r.Json
        $rec.strategy | Should -Be 'rebuild-with-database-migration'
        Get-StepList $rec | Should -Be @('7.15.10>8.5.5', '8.5.5>8.18.15', '8.18.15>10.8.11', '10.8.11>13.16.2', '13.16.2>17.7.1')
        $rec.steps[3].rules | Should -Contain 'lts.closest-first'
        @($rec.steps[4].removals | ForEach-Object { $_.id }) | Should -Contain 'angularjs-backoffice'
        @($rec.steps[4].dataMigrations | ForEach-Object { $_.id }) | Should -Contain 'block-editor-data-format'
    }

    It '7.6 to 17: first updates within 7 to the minimum the content migration accepts' {
        $r = Invoke-Select @('-Source', '7.6.4', '-Target', '17', '-Engine', 'sqlserver')
        $rec = Get-Recommended $r.Json
        $rec.steps[0].from | Should -Be '7.6.4'
        $rec.steps[0].to | Should -Be '7.15.11'
        $rec.steps[0].type | Should -Be 'minor-in-place'
        $rec.steps[0].rules | Should -Contain 'inplace.minor.7'
        @($r.Json.factsUsed | ForEach-Object { $_.id }) | Should -Contain 'versions[8].minUpgradeFrom'
    }

    It '13 to 17: in place in one step, with the documented removals and data migration' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '17', '-Engine', 'sqlserver')
        $r.ExitCode | Should -Be 0
        $r.Json.status | Should -Be 'selected'
        $rec = Get-Recommended $r.Json
        $rec.strategy | Should -Be 'in-place'
        Get-StepList $rec | Should -Be @('13.10.1>17.7.1')
        @($rec.steps[0].removals | ForEach-Object { $_.id }) | Should -Be @('angularjs-backoffice', 'nested-content-and-grid', 'legacy-media-picker', 'macros', 'smidge', 'installer-endpoints')
        @($rec.steps[0].dataMigrations | ForEach-Object { $_.id }) | Should -Be @('block-editor-data-format')
        $r.Json.target.lts.value | Should -BeTrue
        $r.Json.target.lts.status | Should -Be 'verified'
        $r.Json.target.dotnet.value | Should -Be 'net10.0'
        $r.Json.target.endOfLife.status | Should -Be 'secondary'
        @($r.Json.unverifiedFacts | ForEach-Object { $_.id }) | Should -Contain 'versions[17].endOfLife'
    }

    It '13 to 18: must stop at 17; the direct jump is rejected with both rules' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '18', '-Engine', 'sqlserver')
        $r.Json.status | Should -Be 'selected'
        $rec = Get-Recommended $r.Json
        $rec.strategy | Should -Be 'staged'
        Get-StepList $rec | Should -Be @('13.10.1>17.7.1', '17.7.1>18.2.1')
        $rec.steps[0].rules | Should -Contain 'lts.closest-first'
        @($rec.steps[1].dataMigrations | ForEach-Object { $_.id }) | Should -Be @('single-block-list-migration')
        @($rec.steps[1].preparation | ForEach-Object { $_.id }) | Should -Contain 'empty-media-recycle-bin'
        $direct = @($r.Json.alternatives | Where-Object { $_.strategy -like 'in-place (direct*' })[0]
        $direct.rejectedBecause | Should -Match 'stop at 17'
        $direct.rejectedBecause | Should -Match '16\.4\.0'
        $r.Json.target.lts.value | Should -BeFalse
    }

    It '8 to 17: latest 8 first, then a new 10 project on the 8 database, then 13 and 17' {
        $r = Invoke-Select @('-Source', '8.13.0', '-Target', '17', '-Engine', 'sqlserver')
        $rec = Get-Recommended $r.Json
        $rec.strategy | Should -Be 'rebuild-with-database-migration'
        Get-StepList $rec | Should -Be @('8.13.0>8.18.15', '8.18.15>10.8.11', '10.8.11>13.16.2', '13.16.2>17.7.1')
        $rec.steps[1].codebase | Should -Be 'new'
        $rec.steps[1].prerequisites -join ' ' | Should -Match 'Umbraco Forms'
    }

    It '10 to 13: in place, directly' {
        $r = Invoke-Select @('-Source', '10.8.6', '-Target', '13', '-Engine', 'sqlserver')
        $r.Json.status | Should -Be 'selected'
        $rec = Get-Recommended $r.Json
        $rec.strategy | Should -Be 'in-place'
        Get-StepList $rec | Should -Be @('10.8.6>13.16.2')
    }

    It '9 to 13: the documented 9 to 10 hop first' {
        $r = Invoke-Select @('-Source', '9.5.0', '-Target', '13', '-Engine', 'sqlserver')
        $rec = Get-Recommended $r.Json
        $rec.strategy | Should -Be 'staged'
        Get-StepList $rec | Should -Be @('9.5.0>10.8.11', '10.8.11>13.16.2')
        $rec.steps[0].rules | Should -Contain 'hop.9-10'
    }

    It 'a minor update within a major is in place' {
        $r = Invoke-Select @('-Source', '17.2.0', '-Target', '17', '-Engine', 'sqlserver')
        $rec = Get-Recommended $r.Json
        Get-StepList $rec | Should -Be @('17.2.0>17.7.1')
        $rec.steps[0].rules | Should -Contain 'inplace.minor.modern'
        @($r.Json.candidates).Count | Should -Be 1
    }
}

Describe 'Path selection with discovery facts' -Tag 'mocked' {
    It 'SQL CE source: needs a decision on the engine conversion; content transfer is close' {
        $r = Invoke-Select @('-Source', '8.17.2', '-Target', '13', '-Engine', 'sqlce')
        $r.ExitCode | Should -Be 0
        $r.Json.status | Should -Be 'needs-decision'
        $r.Json.close | Should -BeTrue
        @($r.Json.constraints | ForEach-Object { $_.rule }) | Should -Contain 'engine.sqlce'
        $rec = Get-Recommended $r.Json
        ($rec.decisions -join ' ') | Should -Match 'sqlce database must be converted before step S2'
        ($rec.decisions -join ' ') | Should -Match 'uSync'
        @($rec.riskDetail | ForEach-Object { $_.rule }) | Should -Contain 'engine.sqlce-conversion'
    }

    It 'an engine the 7 to 8 content migration does not support invalidates the database route' {
        $r = Invoke-Select @('-Source', '7.15.10', '-Target', '13', '-Engine', 'other')
        $rebuild = @($r.Json.candidates | Where-Object { $_.strategy -eq 'rebuild-with-database-migration' })[0]
        $rebuild.valid | Should -BeFalse
        ($rebuild.invalidBecause -join ' ') | Should -Match 'SQL Server and SQL CE'
        (Get-Recommended $r.Json).strategy | Should -Be 'new-install-with-content-transfer'
        $r.Json.status | Should -Be 'needs-decision'
    }

    It 'an unknown engine asks for confirmation' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '17')
        $r.Json.status | Should -Be 'needs-decision'
        ((Get-Recommended $r.Json).decisions -join ' ') | Should -Match 'Confirm the database engine'
    }

    It 'patterns adjust risk and add mandatory work' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '17', '-Engine', 'sqlserver', '-Patterns', 'backoffice.angular-property-editor,data.custom-tables')
        @($r.Json.mandatoryWork | ForEach-Object { $_.id }) | Should -Contain 'work.angularjs-backoffice'
        $transfer = @($r.Json.candidates | Where-Object { $_.strategy -eq 'new-install-with-content-transfer' })[0]
        @($transfer.riskDetail | ForEach-Object { $_.rule }) | Should -Contain 'db.custom-tables'
    }

    It 'reads the source version, engine, and patterns from a project after discovery' {
        $d = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.bo.angular-editor'
        $dd = New-TestDirectory -Prefix 'uud'
        try {
            Initialize-GitRepo -Path $d -Commit
            (Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('init', '-ProjectRoot', $d, '-Mode', 'plan', '-Target', '17')).ExitCode | Should -Be 0
            (Invoke-PluginScript -Script 'scripts/Invoke-Discovery.ps1' -Arguments @('-ProjectRoot', $d)).ExitCode | Should -Be 0
            $out = Join-Path $d '.umbraco-upgrade/evidence/version-path/path-selection.json'
            $r = Invoke-PluginScript -Script 'scripts/Select-UpgradePath.ps1' -Arguments @('-ProjectRoot', $d, '-DataDir', $dd, '-OutFile', $out) -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = (Get-MockSet 'm.nuget') }
            $r.ExitCode | Should -Be 0
            $r.Json.inputs.source | Should -Be '13.10.1'
            $r.Json.inputs.target | Should -Be '17'
            $r.Json.inputs.patterns | Should -Contain 'backoffice.angular-property-editor'
            @($r.Json.mandatoryWork | ForEach-Object { $_.id }) | Should -Contain 'work.angularjs-backoffice'
            Test-Path $out | Should -BeTrue
            (Get-Content -Raw $out | ConvertFrom-Json).recommended | Should -Be $r.Json.recommended
        } finally { Remove-TestDirectory $d; Remove-TestDirectory $dd }
    }

    It 'refuses an output file outside .umbraco-upgrade and the data directory' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '17', '-OutFile', (Join-Path ([System.IO.Path]::GetTempPath()) 'elsewhere.json'))
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'OutFile'
    }
}

Describe 'Unknown and invalid targets' -Tag 'mocked' {
    It 'unknown future major not on NuGet: stops with unknown-target' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '25')
        $r.ExitCode | Should -Be 1
        $r.Json.ok | Should -BeFalse
        $r.Json.status | Should -Be 'unknown-target'
        ($r.Json.messages -join ' ') | Should -Match 'not in the version knowledge'
        ($r.Json.messages -join ' ') | Should -Match 'no stable release on NuGet'
    }

    It 'unknown future major with prereleases only: stops and names the prerelease' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '25') -Mocks @('m.nuget.future-prerelease', 'm.nuget')
        $r.Json.status | Should -Be 'unknown-target'
        ($r.Json.messages -join ' ') | Should -Match '25\.0\.0-rc1'
    }

    It 'unknown future major on NuGet: unverified facts, blockers, and the closest known LTS stop' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '25', '-Engine', 'sqlserver') -Mocks @('m.nuget.future-major', 'm.nuget')
        $r.ExitCode | Should -Be 0
        $r.Json.status | Should -Be 'future-unverified'
        $r.Json.target.resolved | Should -Be '25.1.0'
        $r.Json.target.known | Should -BeFalse
        $r.Json.target.dotnet.value | Should -Be 'net99.0'
        $r.Json.target.dotnet.status | Should -Be 'verified'
        $r.Json.target.lts.value | Should -BeNullOrEmpty
        $r.Json.target.lts.status | Should -Be 'unverified'
        ($r.Json.gateBlockers -join ' ') | Should -Match 'LTS status of Umbraco 25'
        ($r.Json.gateBlockers -join ' ') | Should -Match 'minimum version Umbraco 25 can upgrade from'
        ($r.Json.gateBlockers -join ' ') | Should -Match '19, 20, 21, 22, 23, 24'
        $r.Json.suggestions | Should -Contain '/umbraco-upgrade:update-knowledge'
        Get-StepList (Get-Recommended $r.Json) | Should -Be @('13.10.1>17.7.1', '17.7.1>25.1.0')
    }

    It 'unknown future major with user-confirmed facts: those blockers are cleared and the source is recorded' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '25', '-Engine', 'sqlserver', '-UserLts', 'false', '-UserMinFrom', '17.0.0', '-UserSource', 'https://docs.umbraco.com/umbraco-cms/get-started/upgrading-and-migrating/version-specific.md') -Mocks @('m.nuget.future-major', 'm.nuget')
        $r.Json.status | Should -Be 'future-unverified'
        $r.Json.target.lts.value | Should -BeFalse
        $r.Json.target.lts.status | Should -Be 'verified'
        @($r.Json.factsUsed | Where-Object { $_.id -eq 'versions[25].lts' })[0].sourceType | Should -Be 'user-confirmed'
        ($r.Json.gateBlockers -join ' ') | Should -Not -Match 'LTS status'
        ($r.Json.gateBlockers -join ' ') | Should -Not -Match 'minimum version'
    }

    It 'user-confirmed facts need the official source URL' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '25', '-UserLts', 'true') -Mocks @('m.nuget.future-major', 'm.nuget')
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'UserSource'
    }

    It 'an exact target that is not published is an error' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '17.99.0')
        $r.ExitCode | Should -Be 1
        ($r.Json.messages -join ' ') | Should -Match 'not published on NuGet'
    }

    It 'a downgrade is an error' {
        $r = Invoke-Select @('-Source', '17.2.0', '-Target', '13')
        $r.ExitCode | Should -Be 1
        ($r.Json.messages -join ' ') | Should -Match 'Downgrades are not supported'
    }

    It 'offline: exact versions come from the knowledge and say so' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '18', '-Engine', 'sqlserver', '-Offline') -Mocks @('m.docs')
        $r.Json.status | Should -Be 'selected'
        $r.Json.target.resolvedBy | Should -Be 'knowledge'
        $r.Json.nuget.checked | Should -BeFalse
        Get-StepList (Get-Recommended $r.Json) | Should -Be @('13.10.1>17.7.1', '17.7.1>18.2.1')
    }
}

Describe 'Live re-check of the facts a path rests on' -Tag 'mocked' {
    It 'confirms every cited fact against the recorded official pages' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '18', '-Engine', 'sqlserver', '-VerifyLive') -Mocks @('m.docs', 'm.nuget')
        $r.Json.status | Should -Be 'selected'
        $r.Json.liveCheck.counts.missing | Should -Be 0
        $r.Json.liveCheck.counts.unreachable | Should -Be 0
        $r.Json.liveCheck.counts.confirmed | Should -BeGreaterThan 5
        @($r.Json.factsUsed | Where-Object { $_.id -eq 'versions[18].minUpgradeFrom' })[0].live | Should -Be 'confirmed'
    }

    It 'marks a fact needs-review when its source page no longer contains the evidence' {
        $r = Invoke-Select @('-Source', '13.10.1', '-Target', '18', '-Engine', 'sqlserver', '-VerifyLive') -Mocks @('m.docs.changed', 'm.docs', 'm.nuget')
        $f = @($r.Json.factsUsed | Where-Object { $_.id -eq 'versions[18].minUpgradeFrom' })[0]
        $f.live | Should -Be 'missing'
        $f.status | Should -Be 'needs-review'
        @($r.Json.unverifiedFacts | ForEach-Object { $_.id }) | Should -Contain 'versions[18].minUpgradeFrom'
        ($r.Json.messages -join ' ') | Should -Match 'could not be re-confirmed'
    }
}
