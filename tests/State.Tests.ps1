# State read, write, validation, and transitions.
# Label: fixture-based (temporary git repositories built from synthetic fixtures).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/State.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Compat.psm1') -Force -DisableNameChecking
    function New-Project([string]$Mode = 'upgrade', [switch]$NoGit, [switch]$Dirty) {
        $d = Copy-Fixture -Baseline 'gen.v13'
        if (-not $NoGit) { Initialize-GitRepo -Path $d -Commit }
        if ($Dirty) { Add-Content -LiteralPath (Join-Path $d 'Program.cs') -Value '// local change' }
        [void](New-UpgradeState -ProjectRoot $d -Mode $Mode -TargetRequested '17')
        return $d
    }
    function Write-Plan([string]$Dir, [string]$Text = "# Plan`n") {
        [System.IO.File]::WriteAllText((Join-Path $Dir '.umbraco-upgrade/plan.md'), $Text)
    }
    function Pass-Discovery([string]$Dir) {
        [void](Set-UpgradeGate -ProjectRoot $Dir -Gate discovery -Status passed -Evidence @('evidence/discovery/version.json'))
    }
    function Set-PathSelected([string]$Dir) {
        # What the version-path skill records before gate 2 can pass (target facts and the selected path).
        [void](Update-StateSection -ProjectRoot $Dir -Section target -Values @{ resolved = '17.7.1'; dotnet = 'net10.0'; lts = @{ value = $true; source = 'D-001'; verified = $true } })
        [void](Update-StateSection -ProjectRoot $Dir -Section path -Values @{ selection = 'selected'; strategy = 'in-place'; decision = 'D-001' })
    }
    function Pass-VersionPath([string]$Dir) {
        [void](Update-StateSection -ProjectRoot $Dir -Section source -Values @{ umbraco = '13.10.1'; major = 13; confidence = 'high' })
        Set-PathSelected $Dir
        [void](Set-UpgradeGate -ProjectRoot $Dir -Gate versionPath -Status passed)
    }
}

Describe 'Initialization' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'creates the state folder, README, git snapshot, and a valid state' {
        $script:d = New-Project
        $s = Read-UpgradeState $script:d
        $s.schemaVersion | Should -Be '1.0.0'
        $s.mode | Should -Be 'upgrade'
        $s.target.requested | Should -Be '17'
        $s.gitBaseline.isRepo | Should -BeTrue
        $s.gitBaseline.statusAtStart | Should -Be 'clean'
        $s.gitBaseline.baseBranch | Should -Be 'main'
        $s.gitBaseline.baseCommit | Should -Match '^[0-9a-f]{40}$'
        (Test-UpgradeState -State $s).Count | Should -Be 0
        Test-Path (Join-Path $script:d '.umbraco-upgrade/README.md') | Should -BeTrue
        Test-Path (Join-Path $script:d '.umbraco-upgrade/evidence/discovery/git-status-at-start.json') | Should -BeTrue
        @($s.history).Count | Should -Be 1
        $s.history[0].event | Should -Be 'initialized'
    }

    It 'takes the git snapshot before writing anything (clean stays clean)' {
        $script:d = New-Project
        $snap = Get-Content -Raw (Join-Path $script:d '.umbraco-upgrade/evidence/discovery/git-status-at-start.json') | ConvertFrom-Json
        @($snap.entries).Count | Should -Be 0
    }

    It 'records a dirty tree at start' {
        $script:d = New-Project -Dirty
        (Read-UpgradeState $script:d).gitBaseline.statusAtStart | Should -Be 'dirty'
    }

    It 'records a project that is not a git repository' {
        $script:d = New-Project -NoGit
        $s = Read-UpgradeState $script:d
        $s.gitBaseline.isRepo | Should -BeFalse
        $s.gitBaseline.statusAtStart | Should -Be 'not-a-repo'
    }

    It 'refuses to initialize twice' {
        $script:d = New-Project
        { New-UpgradeState -ProjectRoot $script:d -Mode upgrade -TargetRequested '17' } | Should -Throw '*already exists*'
    }

    It 'refuses an invalid target' {
        $script:d = Copy-Fixture -Baseline 'gen.v13'
        { New-UpgradeState -ProjectRoot $script:d -Mode upgrade -TargetRequested 'v17' } | Should -Throw '*Invalid target*'
        Test-Path (Join-Path $script:d '.umbraco-upgrade') | Should -BeFalse
    }
}

Describe 'Read, write, and validation' -Tag 'fixture-based' {
    BeforeEach { $script:d = New-Project }
    AfterEach { Remove-TestDirectory $script:d }

    It 'writes atomically and leaves no temp files' {
        Pass-Discovery $script:d
        @(Get-ChildItem -LiteralPath (Join-Path $script:d '.umbraco-upgrade') -Filter '*.tmp' -Force).Count | Should -Be 0
    }

    It 'appends history and updates updatedAt on every save' {
        $before = Read-UpgradeState $script:d
        Start-Sleep -Milliseconds 1100
        Pass-Discovery $script:d
        $after = Read-UpgradeState $script:d
        @($after.history).Count | Should -Be (@($before.history).Count + 1)
        $after.updatedAt | Should -Not -Be $before.updatedAt
    }

    It 'rejects a state that violates the schema' {
        $s = Read-UpgradeState $script:d
        $s.mode = 'deploy'
        $errs = Test-UpgradeState -State $s
        ($errs -join ' ') | Should -Match 'mode'
        { Save-UpgradeState -ProjectRoot $script:d -State $s -Event 'x' } | Should -Throw '*validation failed*'
        (Read-UpgradeState $script:d).mode | Should -Be 'upgrade'
    }

    It 'rejects unknown properties' {
        $s = Read-UpgradeState $script:d
        $s['unexpected'] = 1
        (Test-UpgradeState -State $s) -join ' ' | Should -Match "unexpected property 'unexpected'"
    }

    It 'refuses a newer major schema version' {
        $p = Join-Path $script:d '.umbraco-upgrade/state.json'
        [System.IO.File]::WriteAllText($p, ((Get-Content -Raw $p) -replace '"schemaVersion":\s*"1\.0\.0"', '"schemaVersion": "2.0.0"'))
        { Read-UpgradeState $script:d } | Should -Throw '*Unsupported state schema version*'
    }

    It 'migrate is a no-op on the current version and refuses a newer minor' {
        (Update-StateSchemaVersion -ProjectRoot $script:d).changed | Should -BeFalse
        $p = Join-Path $script:d '.umbraco-upgrade/state.json'
        [System.IO.File]::WriteAllText($p, ((Get-Content -Raw $p) -replace '"schemaVersion":\s*"1\.0\.0"', '"schemaVersion": "1.9.0"'))
        { Update-StateSchemaVersion -ProjectRoot $script:d } | Should -Throw '*newer than this plugin supports*'
    }

    It 'merges sections and keeps statusAtStart fixed' {
        [void](Update-StateSection -ProjectRoot $script:d -Section source -Values @{ database = @{ localCopyDeclared = $true } })
        $s = Read-UpgradeState $script:d
        $s.source.database.localCopyDeclared | Should -BeTrue
        $s.source.database.engine | Should -Be 'unknown'
        { Update-StateSection -ProjectRoot $script:d -Section gitBaseline -Values @{ statusAtStart = 'clean' } } | Should -Throw '*cannot change*'
        { Update-StateSection -ProjectRoot $script:d -Section gates -Values @{ x = 1 } } | Should -Throw '*cannot be set directly*'
    }

    It 'allocates sequential decision and unresolved ids' {
        Add-Decision -ProjectRoot $script:d -Gate versionPath | Should -Be 'D-001'
        Add-Decision -ProjectRoot $script:d | Should -Be 'D-002'
        Add-Unresolved -ProjectRoot $script:d -Item 'Badge editor needs a web component' -Pattern 'backoffice.angular-property-editor' -Proposal port | Should -Be 'U-001'
        $s = Read-UpgradeState $script:d
        $s.gates.versionPath.decisions | Should -Be @('D-001')
        $s.unresolved[0].status | Should -Be 'awaiting-user'
    }
}

Describe 'Gate transitions' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'refuses a gate before the previous one has passed' {
        $script:d = New-Project
        { Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status in-progress } | Should -Throw "*gate 'discovery' is 'pending'*"
    }

    It 'refuses discovery without evidence' {
        $script:d = New-Project
        { Set-UpgradeGate -ProjectRoot $script:d -Gate discovery -Status passed } | Should -Throw '*without evidence*'
    }

    It 'refuses versionPath without a source version, and while signals conflict' {
        $script:d = New-Project
        Pass-Discovery $script:d
        { Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status passed } | Should -Throw '*source version*'
        [void](Update-StateSection -ProjectRoot $script:d -Section source -Values @{ umbraco = '13.10.1'; confidence = 'conflict' })
        { Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status passed } | Should -Throw '*conflict*'
        [void](Update-StateSection -ProjectRoot $script:d -Section source -Values @{ confidence = 'confirmed-by-user' })
        Set-PathSelected $script:d
        (Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status passed).gates.versionPath.status | Should -Be 'passed'
    }

    It 'refuses versionPath without a resolved target, the target LTS status and .NET version, and a selected path' {
        $script:d = New-Project
        Pass-Discovery $script:d
        [void](Update-StateSection -ProjectRoot $script:d -Section source -Values @{ umbraco = '13.10.1'; major = 13; confidence = 'high' })
        { Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status passed } | Should -Throw '*resolved target*'
        [void](Update-StateSection -ProjectRoot $script:d -Section target -Values @{ resolved = '17.7.1' })
        { Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status passed } | Should -Throw '*LTS status and the .NET requirement*'
        [void](Update-StateSection -ProjectRoot $script:d -Section target -Values @{ dotnet = 'net10.0'; lts = @{ value = $false; source = 'D-002'; verified = $true } })
        { Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status passed } | Should -Throw '*selected upgrade path*'
        [void](Update-StateSection -ProjectRoot $script:d -Section path -Values @{ selection = 'selected'; strategy = 'staged' })
        { Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status passed } | Should -Throw '*decision id*'
        [void](Update-StateSection -ProjectRoot $script:d -Section path -Values @{ decision = 'D-003' })
        (Set-UpgradeGate -ProjectRoot $script:d -Gate versionPath -Status passed).gates.versionPath.status | Should -Be 'passed'
    }

    It 'skips safety only in plan mode' {
        $script:d = New-Project
        Pass-Discovery $script:d; Pass-VersionPath $script:d
        { Set-UpgradeGate -ProjectRoot $script:d -Gate safety -Status skipped } | Should -Throw '*plan mode*'
        Remove-TestDirectory $script:d
        $script:d = New-Project -Mode plan
        Pass-Discovery $script:d; Pass-VersionPath $script:d
        (Set-UpgradeGate -ProjectRoot $script:d -Gate safety -Status skipped).gates.safety.status | Should -Be 'skipped'
    }

    It 'refuses safety without the guard self-test, branch, and rollback document' {
        $script:d = New-Project
        Pass-Discovery $script:d; Pass-VersionPath $script:d
        { Set-UpgradeGate -ProjectRoot $script:d -Gate safety -Status passed } | Should -Throw '*guard self-test*'
        [void](Set-GateFields -ProjectRoot $script:d -Gate safety -Fields @{ guardSelfTest = 'passed' })
        { Set-UpgradeGate -ProjectRoot $script:d -Gate safety -Status passed } | Should -Throw '*upgrade branch*'
        [void](Update-StateSection -ProjectRoot $script:d -Section gitBaseline -Values @{ upgradeBranch = 'umbraco-upgrade/13-to-17' })
        { Set-UpgradeGate -ProjectRoot $script:d -Gate safety -Status passed } | Should -Throw '*rollback*'
        [void](Set-GateFields -ProjectRoot $script:d -Gate safety -Fields @{ rollbackDoc = 'rollback.md' })
        (Set-UpgradeGate -ProjectRoot $script:d -Gate safety -Status passed).gates.safety.status | Should -Be 'passed'
    }

    It 'never sets planApproval to passed directly and never re-passes a gate' {
        $script:d = New-Project
        { Set-UpgradeGate -ProjectRoot $script:d -Gate planApproval -Status passed } | Should -Throw '*request-plan-approval*'
        Pass-Discovery $script:d
        { Set-UpgradeGate -ProjectRoot $script:d -Gate discovery -Status passed -Evidence @('x') } | Should -Throw '*already*'
    }
}

Describe 'Plan approval' -Tag 'fixture-based' {
    BeforeEach {
        $script:d = New-Project
        Pass-Discovery $script:d; Pass-VersionPath $script:d
        [void](Set-GateFields -ProjectRoot $script:d -Gate safety -Fields @{ guardSelfTest = 'passed'; rollbackDoc = 'rollback.md' })
        [void](Update-StateSection -ProjectRoot $script:d -Section gitBaseline -Values @{ upgradeBranch = 'umbraco-upgrade/13-to-17' })
        [void](Set-UpgradeGate -ProjectRoot $script:d -Gate safety -Status passed)
    }
    AfterEach { Remove-TestDirectory $script:d }

    It 'needs plan.md before approval can be requested' {
        { Request-PlanApproval -ProjectRoot $script:d } | Should -Throw '*plan.md does not exist*'
    }

    It 'binds the approval to the plan hash' {
        Write-Plan $script:d
        $s = Request-PlanApproval -ProjectRoot $script:d
        $s.gates.planApproval.status | Should -Be 'awaiting-approval'
        $hash = Get-FileSha256 (Join-Path $script:d '.umbraco-upgrade/plan.md')
        $s.gates.planApproval.planSha256 | Should -Be $hash
        $a = Add-Approval -ProjectRoot $script:d -Action start-plan-execution -Decision approved -Note 'approve'
        $a.id | Should -Be 'A-001'
        $a.scope | Should -Be "plan.md sha256 $hash"
        $s = Read-UpgradeState $script:d
        $s.gates.planApproval.status | Should -Be 'approved'
        $s.gates.planApproval.approval | Should -Be 'A-001'
        (Test-PlanHash -ProjectRoot $script:d).matches | Should -BeTrue
        (Test-ApprovalAvailable -ProjectRoot $script:d -Action start-plan-execution).id | Should -Be 'A-001'
    }

    It 'invalidates the approval when the plan changes' {
        Write-Plan $script:d
        [void](Request-PlanApproval -ProjectRoot $script:d)
        [void](Add-Approval -ProjectRoot $script:d -Action start-plan-execution -Decision approved)
        Write-Plan $script:d "# Plan`nchanged`n"
        Test-ApprovalAvailable -ProjectRoot $script:d -Action start-plan-execution | Should -BeNullOrEmpty
        (Test-PlanHash -ProjectRoot $script:d -Invalidate).status | Should -Be 'invalidated'
        (Read-UpgradeState $script:d).gates.planApproval.status | Should -Be 'invalidated'
    }

    It 'refuses an approval when the plan changed after the request' {
        Write-Plan $script:d
        [void](Request-PlanApproval -ProjectRoot $script:d)
        Write-Plan $script:d "# Plan v2`n"
        { Add-Approval -ProjectRoot $script:d -Action start-plan-execution -Decision approved } | Should -Throw '*changed after approval was requested*'
    }

    It 'records a rejection' {
        Write-Plan $script:d
        [void](Request-PlanApproval -ProjectRoot $script:d)
        [void](Add-Approval -ProjectRoot $script:d -Action start-plan-execution -Decision rejected)
        (Read-UpgradeState $script:d).gates.planApproval.status | Should -Be 'rejected'
    }

    It 'freezes phases after approval and requires approval to start one' {
        $phases = @(@{ id = 'P1'; title = 'Packages and framework'; area = 'application-framework'; patterns = @('pkg.core-id-changes'); acceptanceCriteria = @(@{ id = 'P1-AC1'; text = 'Solution builds with views precompiled'; verification = 'automated' }) })
        [void](Set-UpgradePhases -ProjectRoot $script:d -Phases $phases)
        { Set-PhaseStatus -ProjectRoot $script:d -PhaseId P1 -Status in-progress } | Should -Throw '*after the plan is approved*'
        Write-Plan $script:d
        [void](Request-PlanApproval -ProjectRoot $script:d)
        [void](Add-Approval -ProjectRoot $script:d -Action start-plan-execution -Decision approved)
        { Set-UpgradePhases -ProjectRoot $script:d -Phases $phases } | Should -Throw '*frozen*'
        [void](Set-PhaseStatus -ProjectRoot $script:d -PhaseId P1 -Status in-progress)
        { Set-PhaseStatus -ProjectRoot $script:d -PhaseId P1 -Status done } | Should -Throw '*unmet acceptance criteria*'
    }
}

Describe 'Approvals for other actions' -Tag 'fixture-based' {
    BeforeEach { $script:d = New-Project }
    AfterEach { Remove-TestDirectory $script:d }

    It 'consumes an approval once' {
        [void](Add-Approval -ProjectRoot $script:d -Action db-migration-local -Decision approved -Scope 'local copy')
        (Test-ApprovalAvailable -ProjectRoot $script:d -Action db-migration-local -Consume).id | Should -Be 'A-001'
        Test-ApprovalAvailable -ProjectRoot $script:d -Action db-migration-local | Should -BeNullOrEmpty
    }

    It 'refuses plan execution approval in plan mode' {
        Remove-TestDirectory $script:d
        $script:d = New-Project -Mode plan
        { Add-Approval -ProjectRoot $script:d -Action start-plan-execution -Decision approved } | Should -Throw '*upgrade mode*'
    }
}

Describe 'state.ps1 CLI' -Tag 'fixture-based' {
    BeforeAll { $script:c = New-UpgradeProject -Baseline 'gen.v13' }
    AfterAll { Remove-TestDirectory $script:c }

    It 'get prints a field' {
        $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('get', '-ProjectRoot', $script:c, '-Field', 'target.requested')
        $r.ExitCode | Should -Be 0
        $r.Json.value | Should -Be '17'
    }
    It 'validate reports a valid file' {
        $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('validate', '-ProjectRoot', $script:c)
        $r.Json.valid | Should -BeTrue
    }
    It 'set types integers and booleans' {
        $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('set', '-ProjectRoot', $script:c, '-Section', 'source', '-Set', 'umbraco=13.10.1;major=13;database.localCopyDeclared=true')
        $r.ExitCode | Should -Be 0
        $r.Json.value.major | Should -Be 13
        $r.Json.value.database.localCopyDeclared | Should -BeTrue
    }
    It 'refuses an invalid transition with ok=false and exit code 1' {
        $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('gate', '-ProjectRoot', $script:c, '-Gate', 'safety', '-Status', 'passed')
        $r.ExitCode | Should -Be 1
        $r.Json.ok | Should -BeFalse
    }
    It 'writes and removes a session marker' {
        $data = New-TestDirectory
        try {
            $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('session-marker', '-ProjectRoot', $script:c, '-SessionId', 'abc-123', '-DataDir', $data)
            $r.ExitCode | Should -Be 0
            Test-Path (Join-Path $data 'active-sessions/abc-123.json') | Should -BeTrue
            $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('session-marker', '-ProjectRoot', $script:c, '-SessionId', 'abc-123', '-DataDir', $data, '-Remove')
            Test-Path (Join-Path $data 'active-sessions/abc-123.json') | Should -BeFalse
        } finally { Remove-TestDirectory $data }
    }
}

Describe 'Schema file' -Tag 'fixture-based' {
    It 'parses and declares version 1.0.0 enums used by the module' {
        $schema = Get-Content -Raw (Join-Path (Get-RepoRoot) 'schemas/state.schema.json') | ConvertFrom-Json
        $schema.'$defs'.gate.properties.status.enum | Should -Contain 'awaiting-approval'
        $schema.properties.mode.enum | Should -Be @('upgrade', 'plan')
    }
}
