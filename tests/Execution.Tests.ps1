# Plan execution: phase transitions, criteria, evidence, and the scripts that act during execution. Each script
# refuses without its preconditions or approval, and never writes a secret into evidence or output.
# Label: fixture-based (temporary git repositories built from synthetic fixtures).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Compat.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/State.psm1') -Force -DisableNameChecking
    function Invoke-State([string]$Dir, [string[]]$Arguments) { return (Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments (@($Arguments[0], '-ProjectRoot', $Dir) + @($Arguments | Select-Object -Skip 1))) }
    function Get-Phase([string]$Dir, [string]$Id) { return @((Read-UpgradeState $Dir)['phases'] | Where-Object { $_['id'] -eq $Id })[0] }
    function Get-EvidenceText([string]$Dir) {
        $root = Join-Path $Dir '.umbraco-upgrade/evidence'
        if (-not (Test-Path $root)) { return '' }
        return ((Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n")
    }
    $script:Fake = 'FAKE-SECRET-FOR-TESTS'
}

Describe 'Phase transitions and criteria' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'starts phases only in plan order, with the approved plan unchanged' {
        $script:d = New-ApprovedUpgradeProject
        { Set-PhaseStatus -ProjectRoot $script:d -PhaseId 'P2' -Status in-progress } | Should -Throw '*Phase P1*'
        [void](Set-PhaseStatus -ProjectRoot $script:d -PhaseId 'P1' -Status in-progress)
        (Get-Phase $script:d 'P1')['status'] | Should -Be 'in-progress'
        Add-Content -LiteralPath (Join-Path $script:d '.umbraco-upgrade/plan.md') -Value 'edited after approval'
        [void](Set-PhaseStatus -ProjectRoot $script:d -PhaseId 'P1' -Status deferred)
        { Set-PhaseStatus -ProjectRoot $script:d -PhaseId 'P2' -Status in-progress } | Should -Throw '*plan.md changed*'
    }

    It 'records a criterion only with evidence, and a waiver only with the user''s words' {
        $script:d = New-ApprovedUpgradeProject -StartFirstPhase
        $r = Invoke-State $script:d @('criterion', '-PhaseId', 'P1', '-CriterionId', 'P1-AC1', '-Status', 'met')
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'evidence'
        $r = Invoke-State $script:d @('criterion', '-PhaseId', 'P1', '-CriterionId', 'P1-AC1', '-Status', 'met', '-Evidence', 'evidence/P1/missing.txt')
        $r.Json.error | Should -Match 'does not exist'
        $r = Invoke-State $script:d @('criterion', '-PhaseId', 'P1', '-CriterionId', 'P1-AC1', '-Status', 'met', '-Evidence', '../outside.txt')
        $r.Json.ok | Should -BeFalse
        $r = Invoke-State $script:d @('criterion', '-PhaseId', 'P1', '-CriterionId', 'P1-AC1', '-Status', 'waived')
        $r.Json.error | Should -Match 'user'
        $w = Invoke-PluginScript -Script 'scripts/Write-Evidence.ps1' -Arguments @('-ProjectRoot', $script:d, '-Folder', 'P1', '-Name', 'note.md', '-Text', 'User confirmed the build.')
        $w.Json.ok | Should -BeTrue
        $r = Invoke-State $script:d @('criterion', '-PhaseId', 'P1', '-CriterionId', 'P1-AC1', '-Status', 'met', '-Evidence', $w.Json.path)
        $r.Json.ok | Should -BeTrue
        @($r.Json.open).Count | Should -Be 0
        (Get-Phase $script:d 'P1')['acceptanceCriteria'][0]['status'] | Should -Be 'met'
    }

    It 'marks a phase done only with its criteria met and a checkpoint commit' {
        $script:d = New-ApprovedUpgradeProject -StartFirstPhase
        { Set-PhaseStatus -ProjectRoot $script:d -PhaseId 'P1' -Status done } | Should -Throw '*P1-AC1*'
        $w = Invoke-PluginScript -Script 'scripts/Write-Evidence.ps1' -Arguments @('-ProjectRoot', $script:d, '-Folder', 'P1', '-Name', 'build.md', '-Text', 'built')
        [void](Set-AcceptanceCriterion -ProjectRoot $script:d -PhaseId 'P1' -CriterionId 'P1-AC1' -Status met -Evidence @($w.Json.path))
        { Set-PhaseStatus -ProjectRoot $script:d -PhaseId 'P1' -Status done } | Should -Throw '*no checkpoint commit*'
    }

    It 'records failures with recovery steps and decided unresolved items' {
        $script:d = New-ApprovedUpgradeProject -StartFirstPhase
        $r = Invoke-State $script:d @('phase-failure', '-PhaseId', 'P1', '-Summary', 'Build failed on a removed API', '-Recovery', 'Port the call to the documented replacement')
        $r.Json.ok | Should -BeTrue
        @((Get-Phase $script:d 'P1')['failures']).Count | Should -Be 1
        $u = Invoke-State $script:d @('unresolved', '-Item', 'Badge editor needs a new UI', '-Pattern', 'backoffice.angular-property-editor', '-Proposal', 'port')
        $r = Invoke-State $script:d @('unresolved-update', '-Id', $u.Json.id, '-Status', 'decided')
        $r.Json.ok | Should -BeFalse
        $dec = Invoke-State $script:d @('decision')
        $r = Invoke-State $script:d @('unresolved-update', '-Id', $u.Json.id, '-Status', 'decided', '-DecisionId', $dec.Json.id)
        $r.Json.ok | Should -BeTrue
        @((Read-UpgradeState $script:d)['unresolved'])[0]['status'] | Should -Be 'decided'
    }
}

Describe 'Write-Evidence.ps1' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'redacts secrets, removes the temporary source, and refuses unknown folders and names' {
        $script:d = New-ApprovedUpgradeProject -StartFirstPhase
        $tmp = Join-Path $script:d '.umbraco-upgrade/tmp/out.txt'
        Write-TextFile -Path $tmp -Content "Server=localhost;Database=x;User Id=sa;Password=$($script:Fake)-pw`napikey: $($script:Fake)-key`nBuild succeeded."
        $r = Invoke-PluginScript -Script 'scripts/Write-Evidence.ps1' -Arguments @('-ProjectRoot', $script:d, '-Folder', 'P1', '-Name', 'log.txt', '-SourceFile', $tmp, '-RemoveSource')
        $r.Json.ok | Should -BeTrue
        $r.Json.redacted | Should -BeTrue
        Test-Path $tmp | Should -BeFalse
        $text = Get-EvidenceText $script:d
        $text | Should -Not -Match $script:Fake
        $text | Should -Match 'Build succeeded'
        $r.StdOut | Should -Not -Match $script:Fake
        (Invoke-PluginScript -Script 'scripts/Write-Evidence.ps1' -Arguments @('-ProjectRoot', $script:d, '-Folder', 'P9', '-Name', 'x.txt', '-Text', 'x')).Json.ok | Should -BeFalse
        (Invoke-PluginScript -Script 'scripts/Write-Evidence.ps1' -Arguments @('-ProjectRoot', $script:d, '-Folder', 'P1', '-Name', '../x.txt', '-Text', 'x')).Json.ok | Should -BeFalse
        (Invoke-PluginScript -Script 'scripts/Write-Evidence.ps1' -Arguments @('-ProjectRoot', $script:d, '-Folder', 'safety', '-Name', 'notes.md', '-Text', 'ok')).Json.ok | Should -BeTrue
    }
}

Describe 'Scripts refuse outside an approved, running phase' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'refuses before the plan is approved' {
        $script:d = New-UpgradeProject
        foreach ($s in @(
            @('scripts/Test-Build.ps1', @('-PhaseId', 'P1')),
            @('scripts/New-Checkpoint.ps1', @('-PhaseId', 'P1')),
            @('scripts/Invoke-DatabaseSnapshot.ps1', @('-PhaseId', 'P1', '-Destination', (Join-Path ([IO.Path]::GetTempPath()) 'uu-snap'))),
            @('scripts/Copy-ConfigValue.ps1', @('-PhaseId', 'P1', '-From', 'appsettings.json', '-FromKey', 'Umbraco:CMS:Global:Id', '-To', 'appsettings.Development.json', '-ToKey', 'X')))) {
            $r = Invoke-PluginScript -Script $s[0] -Arguments (@('-ProjectRoot', $script:d) + $s[1])
            $r.ExitCode | Should -Be 1 -Because $s[0]
            $r.Json.error | Should -Match 'Gate 3|not approved' -Because $s[0]
        }
    }

    It 'refuses when the phase is not in progress, and off the upgrade branch' {
        $script:d = New-ApprovedUpgradeProject
        $r = Invoke-PluginScript -Script 'scripts/Test-Build.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.error | Should -Match 'Start it first'
        [void](Set-PhaseStatus -ProjectRoot $script:d -PhaseId 'P1' -Status in-progress)
        $null = & git -C $script:d checkout -q main 2>&1
        $r = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.error | Should -Match 'not on the upgrade branch'
    }

    It 'refuses when the approved plan changed' {
        $script:d = New-ApprovedUpgradeProject -StartFirstPhase
        Add-Content -LiteralPath (Join-Path $script:d '.umbraco-upgrade/plan.md') -Value 'changed'
        $r = Invoke-PluginScript -Script 'scripts/Test-Build.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.error | Should -Match 'plan.md changed'
    }
}

Describe 'Invoke-DatabaseSnapshot.ps1 (approval tier)' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null }; if ($script:dest -and (Test-Path $script:dest)) { Remove-Item -Recurse -Force $script:dest } }

    It 'refuses without a declared local copy, without an approval, and for a destination inside the project' {
        $script:dest = Join-Path ([IO.Path]::GetTempPath()) ('uu-snap-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v14plus' -StartFirstPhase
        $r = Invoke-PluginScript -Script 'scripts/Invoke-DatabaseSnapshot.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-Destination', $script:dest)
        $r.Json.error | Should -Match 'No local database copy is declared'
        [void](Update-StateSection -ProjectRoot $script:d -Section source -Values @{ database = @{ localCopyDeclared = $true } })
        $r = Invoke-PluginScript -Script 'scripts/Invoke-DatabaseSnapshot.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-Destination', $script:dest)
        $r.Json.error | Should -Match "approval 'db-snapshot-local'"
        [void](Add-Approval -ProjectRoot $script:d -Action 'db-snapshot-local' -Decision approved -Scope "destination $($script:dest)")
        $r = Invoke-PluginScript -Script 'scripts/Invoke-DatabaseSnapshot.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-Destination', (Join-Path $script:d 'backups'))
        $r.Json.error | Should -Match 'outside the project'
        Test-Path $script:dest | Should -BeFalse
    }

    It 'refuses a non-local database even with an approval, without printing the connection string' {
        $script:dest = Join-Path ([IO.Path]::GetTempPath()) ('uu-snap-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v13' -Overlay 'p.conf.planted-fake-secrets' -StartFirstPhase -LocalCopyDeclared
        [void](Add-Approval -ProjectRoot $script:d -Action 'db-snapshot-local' -Decision approved -Scope 'destination temp')
        $r = Invoke-PluginScript -Script 'scripts/Invoke-DatabaseSnapshot.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-Destination', $script:dest, '-Environment', 'Production')
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'does not point to a local database'
        $r.StdOut | Should -Not -Match $script:Fake
        $r.StdOut | Should -Not -Match 'db\.example\.invalid'
        (Test-ApprovalAvailable -ProjectRoot $script:d -Action 'db-snapshot-local') | Should -Not -BeNullOrEmpty
    }

    It 'copies a local SQLite database with the approval, consumes it, and records evidence without secrets' {
        $script:dest = Join-Path ([IO.Path]::GetTempPath()) ('uu-snap-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v14plus' -StartFirstPhase -LocalCopyDeclared
        $db = Join-Path $script:d 'umbraco/Data/Umbraco.sqlite.db'
        Write-TextFile -Path $db -Content 'synthetic database file'
        [void](Add-Approval -ProjectRoot $script:d -Action 'db-snapshot-local' -Decision approved -Scope "destination $($script:dest)")
        $w = Invoke-PluginScript -Script 'scripts/Invoke-DatabaseSnapshot.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-Destination', $script:dest, '-WhatIf')
        $w.Json.ok | Should -BeTrue
        $w.Json.whatIf | Should -BeTrue
        (Test-ApprovalAvailable -ProjectRoot $script:d -Action 'db-snapshot-local') | Should -Not -BeNullOrEmpty
        $r = Invoke-PluginScript -Script 'scripts/Invoke-DatabaseSnapshot.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-Destination', $script:dest)
        $r.Json.ok | Should -BeTrue
        $r.Json.engine | Should -Be 'sqlite'
        $r.Json.approvalConsumed | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:dest -File).Count | Should -Be 1
        (Test-ApprovalAvailable -ProjectRoot $script:d -Action 'db-snapshot-local') | Should -BeNullOrEmpty
        $ev = [System.IO.File]::ReadAllText((Join-Path $script:d (Join-Path '.umbraco-upgrade' $r.Json.evidence)))
        $ev | Should -Match 'never recorded'
        $ev | Should -Match '"name":\s*"Umbraco\.sqlite\.db"'
        $ev | Should -Not -Match 'Data Source'
        $again = Invoke-PluginScript -Script 'scripts/Invoke-DatabaseSnapshot.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-Destination', $script:dest)
        $again.Json.error | Should -Match "approval 'db-snapshot-local'"
    }
}

Describe 'Test-DatabaseHealth.ps1 (read-only, local copy only)' -Tag 'fixture-based' {
    BeforeDiscovery {
        $script:hasLocalDb = $false
        if (Get-Command sqllocaldb -ErrorAction SilentlyContinue) { $null = & sqllocaldb info MSSQLLocalDB 2>&1; $script:hasLocalDb = ($LASTEXITCODE -eq 0) }
    }
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'refuses without a declared local copy, for an unknown folder, and for a non-local database without printing secrets' {
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v13' -Overlay 'p.conf.planted-fake-secrets'
        $r = Invoke-PluginScript -Script 'scripts/Test-DatabaseHealth.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.Json.error | Should -Match 'No local database copy is declared'
        [void](Update-StateSection -ProjectRoot $script:d -Section source -Values @{ database = @{ localCopyDeclared = $true } })
        (Invoke-PluginScript -Script 'scripts/Test-DatabaseHealth.ps1' -Arguments @('-ProjectRoot', $script:d, '-Folder', 'P9')).Json.error | Should -Match "Unknown phase 'P9'"
        $r = Invoke-PluginScript -Script 'scripts/Test-DatabaseHealth.ps1' -Arguments @('-ProjectRoot', $script:d, '-Environment', 'Production')
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'does not point to a local database'
        $r.StdOut | Should -Not -Match $script:Fake
        $r.StdOut | Should -Not -Match 'db\.example\.invalid'
    }

    It 'records the file size of a local SQLite copy' {
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v14plus' -LocalCopyDeclared
        Write-TextFile -Path (Join-Path $script:d 'umbraco/Data/Umbraco.sqlite.db') -Content ('x' * 4096)
        $r = Invoke-PluginScript -Script 'scripts/Test-DatabaseHealth.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.engine | Should -Be 'sqlite'
        $r.Json.file | Should -Be 'Umbraco.sqlite.db'
        $r.Json.note | Should -Match 'engine''s own tools'
        $ev = [System.IO.File]::ReadAllText((Join-Path $script:d (Join-Path '.umbraco-upgrade' $r.Json.evidence)))
        $ev | Should -Match 'never recorded'
        $ev | Should -Not -Match 'Data Source'
    }

    It 'counts tables and foreign key problems with catalog queries on LocalDB' -Skip:(-not $script:hasLocalDb) {
        # The master database of the default LocalDB instance, read only: no database is created or changed.
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v14plus' -LocalCopyDeclared
        Write-TextFile -Path (Join-Path $script:d 'appsettings.json') -Content '{ "ConnectionStrings": { "umbracoDbDSN": "Server=(localdb)\\MSSQLLocalDB;Database=master;Integrated Security=true", "umbracoDbDSN_ProviderName": "Microsoft.Data.SqlClient" } }'
        $r = Invoke-PluginScript -Script 'scripts/Test-DatabaseHealth.ps1' -Arguments @('-ProjectRoot', $script:d, '-Top', '5')
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.engine | Should -Be 'localdb'
        $r.Json.databaseName | Should -Be 'master'
        @($r.Json.files | Where-Object { $_.fileType -eq 'ROWS' }).Count | Should -Be 1
        [int]$r.Json.tableCount | Should -BeGreaterOrEqual 0
        @($r.Json.largestTables).Count | Should -BeLessOrEqual 5
        [int]$r.Json.foreignKeysDisabledOrNotTrusted | Should -BeGreaterOrEqual 0
        $r.StdOut | Should -Not -Match 'Integrated Security'
    }
}

Describe 'Copy-ConfigValue.ps1' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null }; if ($script:appdata -and (Test-Path $script:appdata)) { Remove-Item -Recurse -Force $script:appdata } }

    It 'copies a value between JSON files without printing it, and refuses a target with comments unless told' {
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v13' -Overlay 'p.conf.planted-fake-secrets' -StartFirstPhase
        $r = Invoke-PluginScript -Script 'scripts/Copy-ConfigValue.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-From', 'appsettings.Production.json', '-FromKey', 'SampleSite:MapsApiKey', '-To', 'appsettings.json', '-ToKey', 'SampleSite:MapsApiKey')
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'comments'
        $r = Invoke-PluginScript -Script 'scripts/Copy-ConfigValue.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-From', 'appsettings.Production.json', '-FromKey', 'SampleSite:MapsApiKey', '-To', 'appsettings.Local.json', '-ToKey', 'Maps:ApiKey', '-Move')
        $r.Json.ok | Should -BeTrue
        $r.StdOut | Should -Not -Match $script:Fake
        (Get-EvidenceText $script:d) | Should -Not -Match $script:Fake
        $target = ConvertFrom-JsonText ([System.IO.File]::ReadAllText((Join-Path $script:d 'appsettings.Local.json')))
        $target.Maps.ApiKey | Should -Be "$($script:Fake)-maps-api-key"
        [System.IO.File]::ReadAllText((Join-Path $script:d 'appsettings.Production.json')) | Should -Not -Match 'MapsApiKey'
    }

    It 'writes user secrets only with an outside-project-path approval, and consumes it' {
        $script:appdata = Join-Path ([IO.Path]::GetTempPath()) ('uu-appdata-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v13' -StartFirstPhase
        $proj = Join-Path $script:d 'SampleSite.Web.csproj'
        [System.IO.File]::WriteAllText($proj, [System.IO.File]::ReadAllText($proj).Replace('<Nullable>enable</Nullable>', '<Nullable>enable</Nullable><UserSecretsId>00000000-0000-0000-0000-0000000000aa</UserSecretsId>'))
        $args1 = @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-From', 'appsettings.json', '-FromKey', 'ConnectionStrings:umbracoDbDSN', '-ToUserSecrets', '-Project', 'SampleSite.Web.csproj', '-ToKey', 'ConnectionStrings:umbracoDbDSN')
        $r = Invoke-PluginScript -Script 'scripts/Copy-ConfigValue.ps1' -Arguments $args1 -Environment @{ APPDATA = $script:appdata }
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'outside-project-path'
        [void](Add-Approval -ProjectRoot $script:d -Action 'outside-project-path' -Decision approved -Scope 'user secrets of SampleSite.Web.csproj')
        $r = Invoke-PluginScript -Script 'scripts/Copy-ConfigValue.ps1' -Arguments $args1 -Environment @{ APPDATA = $script:appdata }
        $r.Json.ok | Should -BeTrue
        $r.StdOut | Should -Not -Match $script:Fake
        $secrets = Join-Path $script:appdata 'Microsoft\UserSecrets\00000000-0000-0000-0000-0000000000aa\secrets.json'
        Test-Path $secrets | Should -BeTrue
        [System.IO.File]::ReadAllText($secrets) | Should -Match 'ConnectionStrings:umbracoDbDSN'
        (Test-ApprovalAvailable -ProjectRoot $script:d -Action 'outside-project-path') | Should -BeNullOrEmpty
        (Get-EvidenceText $script:d) | Should -Not -Match $script:Fake
    }
}

Describe 'New-Checkpoint.ps1' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    BeforeAll {
        function Complete-Criteria([string]$Dir, [string]$Phase = 'P1') {
            $w = Invoke-PluginScript -Script 'scripts/Write-Evidence.ps1' -Arguments @('-ProjectRoot', $Dir, '-Folder', $Phase, '-Name', 'ok.md', '-Text', 'checked')
            foreach ($c in @((Get-Phase $Dir $Phase)['acceptanceCriteria'])) { [void](Set-AcceptanceCriterion -ProjectRoot $Dir -PhaseId $Phase -CriterionId $c['id'] -Status met -Evidence @($w.Json.path)) }
        }
    }

    It 'refuses while criteria are open' {
        $script:d = New-ApprovedUpgradeProject -StartFirstPhase
        $r = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.error | Should -Match 'P1-AC1'
    }

    It 'refuses a deleted project file without a remove-custom-feature approval that names it' {
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v13' -Overlay 'p.bo.angular-editor' -StartFirstPhase
        Complete-Criteria $script:d
        Remove-Item -Recurse -Force (Join-Path $script:d 'App_Plugins/BadgeEditor')
        $r = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'App_Plugins/BadgeEditor/package.manifest'
        [void](Add-Approval -ProjectRoot $script:d -Action 'remove-custom-feature' -Decision approved -Scope 'App_Plugins/SomethingElse')
        (Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')).Json.ok | Should -BeFalse
        [void](Add-Approval -ProjectRoot $script:d -Action 'remove-custom-feature' -Decision approved -Scope 'App_Plugins/BadgeEditor' -Note 'the user retired the badge editor')
        $r = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.ok | Should -BeTrue
        $r.Json.deleted | Should -Be 3
        @($r.Json.approvalsUsed).Count | Should -Be 1
        (Get-Phase $script:d 'P1')['checkpoint']['commit'] | Should -Be $r.Json.commit
    }

    It 'refuses an added stub and an added secret, and reports disabled code as a warning' {
        $script:d = New-ApprovedUpgradeProject -Baseline 'gen.v13' -Overlay 'p.code.render-controller.v13' -StartFirstPhase
        Complete-Criteria $script:d
        $file = Join-Path $script:d 'Controllers/ArticlePageController.cs'
        $orig = [System.IO.File]::ReadAllText($file)
        [System.IO.File]::WriteAllText($file, $orig.Replace('return CurrentTemplate(CurrentPage);', 'throw new NotImplementedException();'))
        $r = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.error | Should -Match 'Stubs were added'
        [System.IO.File]::WriteAllText($file, $orig)
        Write-TextFile -Path (Join-Path $script:d 'appsettings.Local.json') -Content "{ ""Api"": { ""ApiKey"": ""$($script:Fake)-local"" } }"
        $r = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.error | Should -Match 'look like secrets in: appsettings.Local.json'
        $r.StdOut | Should -Not -Match $script:Fake
        Remove-Item -LiteralPath (Join-Path $script:d 'appsettings.Local.json')
        [System.IO.File]::WriteAllText($file, $orig.Replace('return CurrentTemplate(CurrentPage);', "// return CurrentTemplate(CurrentPage);`n        return CurrentTemplate(CurrentPage);"))
        $proj = Join-Path $script:d 'SampleSite.Web.csproj'
        [System.IO.File]::WriteAllText($proj, [System.IO.File]::ReadAllText($proj).Replace('</Project>', "  <ItemGroup>`n    <Compile Remove=""Controllers/ArticlePageController.cs"" />`n  </ItemGroup>`n</Project>"))
        $r = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.ok | Should -BeTrue
        @($r.Json.warnings | Where-Object { $_ -match 'possible disabled code' }).Count | Should -Be 1
        @($r.Json.warnings | Where-Object { $_ -match 'excluded from compilation in SampleSite\.Web\.csproj' }).Count | Should -Be 1
        $log = & git -C $script:d log -1 --pretty=%s
        $log | Should -Match 'umbraco-upgrade checkpoint P1'
        [void](Set-PhaseStatus -ProjectRoot $script:d -PhaseId 'P1' -Status done)
        (Get-Phase $script:d 'P1')['status'] | Should -Be 'done'
    }

    It 'commits an empty checkpoint when nothing changed and leaves the state folder out of the commit' {
        $script:d = New-ApprovedUpgradeProject -StartFirstPhase
        Complete-Criteria $script:d
        $r = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1')
        $r.Json.ok | Should -BeTrue
        $files = & git -C $script:d show --name-only --pretty=format: HEAD
        @($files | Where-Object { $_ }).Count | Should -Be 0
    }
}

Describe 'Test-Build.ps1 with the .NET SDK' -Tag 'fixture-based' {
    BeforeDiscovery { $script:hasDotnet = [bool](Get-Command dotnet -ErrorAction SilentlyContinue) }
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'builds a small project and keeps redacted output as evidence' -Skip:(-not $script:hasDotnet) {
        $script:d = New-ApprovedUpgradeProject -StartFirstPhase
        $tool = Join-Path $script:d 'tools/BuildProbe'
        # The SDK's own target framework: its targeting pack ships with the SDK, so the build needs no package download.
        $tfm = 'net' + ([version]((& dotnet --version) -replace '-.*$', '')).Major + '.0'
        Write-TextFile -Path (Join-Path $tool 'BuildProbe.csproj') -Content "<Project Sdk=""Microsoft.NET.Sdk""><PropertyGroup><TargetFramework>$tfm</TargetFramework></PropertyGroup></Project>"
        Write-TextFile -Path (Join-Path $tool 'Probe.cs') -Content "namespace BuildProbe { public static class Probe { public const string Note = ""$($script:Fake)-in-source""; } }"
        $r = Invoke-PluginScript -Script 'scripts/Test-Build.ps1' -Arguments @('-ProjectRoot', $script:d, '-PhaseId', 'P1', '-Target', 'tools/BuildProbe/BuildProbe.csproj', '-Configuration', 'Debug')
        $r.Json.build.exitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.ok | Should -BeTrue
        @($r.Json.evidence).Count | Should -Be 2
        Test-Path (Join-Path $script:d (Join-Path '.umbraco-upgrade' $r.Json.evidence[0])) | Should -BeTrue
        $r.StdOut | Should -Not -Match $script:Fake
    }
}
