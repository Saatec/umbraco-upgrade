# Gate 5 (final verification) and the report on fixture states: the state rules of gate 5, the checklist the rules
# compose, the automated checks, and report.md (categories, evidence links, no secrets).
# Label: fixture-based (synthetic upgrades in temporary git repositories; the package check reads the synthetic
# NuGet responses of tests/fixtures/mocks/m.nuget.synthetic, so no network is used).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Compat.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/State.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Execution.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Verification.psm1') -Force -DisableNameChecking
    $env:GIT_OPTIONAL_LOCKS = '0'
    $script:Mock = Get-MockSet 'm.nuget.synthetic'

    function Invoke-Git([string]$Dir, [string[]]$GitArgs) { return (& git -C $Dir @GitArgs 2>&1) }

    function Complete-Phase([string]$Dir, [string]$Phase, [string]$Criterion, [scriptblock]$Work = $null) {
        [void](Set-PhaseStatus -ProjectRoot $Dir -PhaseId $Phase -Status in-progress)
        if ($Work) { & $Work $Dir }
        $ev = Write-RedactedEvidence -ProjectRoot $Dir -Folder $Phase -Name "$Criterion.md" -Content "Evidence for $Criterion."
        [void](Set-AcceptanceCriterion -ProjectRoot $Dir -PhaseId $Phase -CriterionId $Criterion -Status met -Evidence @($ev.path))
        $cp = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $Dir, '-PhaseId', $Phase)
        if ($cp.ExitCode -ne 0) { throw "checkpoint $Phase failed: $($cp.StdOut)" }
        [void](Set-PhaseStatus -ProjectRoot $Dir -PhaseId $Phase -Status done)
    }

    function New-CompletedUpgrade([switch]$StartGate5, [switch]$OpenSecondPhase) {
        # Approved upgrade 13.10.1 to 17.7.1: P1 moves the packages and framework (automated criterion), P2 ports
        # the controllers (manual criterion confirmed by the user). Both done at checkpoints unless -OpenSecondPhase.
        $phases = @(
            [ordered]@{ id = 'P1'; title = 'Packages, framework, and startup'; area = 'application-framework'; patterns = @(); acceptanceCriteria = @([ordered]@{ id = 'P1-AC1'; text = 'The solution builds'; verification = 'automated' }) },
            [ordered]@{ id = 'P2'; title = 'Custom code'; area = 'custom-code'; patterns = @('code.render-controller'); acceptanceCriteria = @([ordered]@{ id = 'P2-AC1'; text = 'Controllers ported'; verification = 'manual' }) })
        $d = New-ApprovedUpgradeProject -Phases $phases
        $sd = Join-Path $d '.umbraco-upgrade'
        foreach ($f in @('inventory.md', 'compatibility.md', 'risks.md')) { [System.IO.File]::WriteAllText((Join-Path $sd $f), "# $f`n") }
        [System.IO.File]::WriteAllText((Join-Path $sd 'decisions.md'), "# Decisions`n`n## D-001 Upgrade path`n`n- Decision: in place from 13.10.1 to 17.7.1`n- Alternatives considered: staged through 14 to 16 (rejected: no stop is required)`n- Sources: https://docs.umbraco.com/umbraco-cms/get-started/upgrading-and-migrating/version-specific.md, applies to the target 17, fetched 2026-10-30`n- Status: verified`n")
        [void](Update-StateSection -ProjectRoot $d -Section path -Values @{ steps = @([ordered]@{ id = 'S1'; from = '13.10.1'; to = '17.7.1'; kind = @('code', 'database') }) })
        [void](Update-StateSection -ProjectRoot $d -Section source -Values @{ dotnet = @('net8.0') })
        New-Item -ItemType Directory -Force (Join-Path $sd 'evidence/planning') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sd 'evidence/planning/phase-composition.json'), '{ "phases": [ { "id": "P1", "step": "S1" }, { "id": "P2", "step": "S1" } ] }')
        Complete-Phase $d 'P1' 'P1-AC1' {
            param($dir)
            $proj = Join-Path $dir 'SampleSite.Web.csproj'
            [System.IO.File]::WriteAllText($proj, ([System.IO.File]::ReadAllText($proj).Replace('Version="13.10.1"', 'Version="17.7.1"').Replace('net8.0', 'net10.0')))
        }
        if (-not $OpenSecondPhase) {
            Complete-Phase $d 'P2' 'P2-AC1' { param($dir) [System.IO.File]::WriteAllText((Join-Path $dir 'Views/Ported.cshtml'), "@* ported view *@`n") }
        }
        if ($StartGate5) {
            [void](Set-UpgradeGate -ProjectRoot $d -Gate final -Status in-progress)
            [void](Set-VerificationChecks -ProjectRoot $d -Checks (New-VerificationPlan -ProjectRoot $d))
        }
        return $d
    }

    function Write-BuildEvidence([string]$Dir, [int]$ExitCode = 0, [bool]$Precompiled = $true, $Tests = 'not run') {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $txt = Write-RedactedEvidence -ProjectRoot $Dir -Folder final -Name "build-$stamp.txt" -Content 'synthetic build output'
        $s = [ordered]@{ ok = ($ExitCode -eq 0); phase = 'final'; target = 'SampleSite.Web.csproj'; configuration = 'Release'; precompiledViews = $Precompiled
            build = [ordered]@{ exitCode = $ExitCode; errors = $(if ($ExitCode) { 2 } else { 0 }); warnings = 1; seconds = 3 }; tests = $Tests; evidence = @($txt.path); at = (Get-UtcTimestamp) }
        return (Write-RedactedEvidence -ProjectRoot $Dir -Folder final -Name "build-$stamp.json" -Content (ConvertTo-JsonText -InputObject $s)).path
    }

    function Invoke-Verify([string]$Dir, [string[]]$Extra = @()) {
        $data = New-TestDirectory
        try { return (Invoke-PluginScript -Script 'scripts/Invoke-Verification.ps1' -Arguments (@('-ProjectRoot', $Dir, '-DataDir', $data) + $Extra) -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = $script:Mock }) }
        finally { Remove-TestDirectory $data }
    }

    function Get-CheckByRule([string]$Dir, [string]$Rule) { return @((Read-UpgradeState $Dir).verification.checks | Where-Object { $_.rule -eq $Rule }) | Select-Object -First 1 }

    function Get-ReportSection([string]$Text, [string]$Heading) {
        $m = [regex]::Match($Text, '(?ms)^## ' + [regex]::Escape($Heading) + '\r?\n(.*?)(?=^## |\z)')
        return $m.Groups[1].Value
    }
}

Describe 'Gate 5 state rules' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'does not start while a phase is open' {
        $script:d = New-CompletedUpgrade -OpenSecondPhase
        { Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status in-progress } | Should -Throw '*every phase is done or deferred*'
    }

    It 'records the checklist only while gate 5 is in progress, and raises a 1.0.0 state to 1.1.0' {
        $script:d = New-CompletedUpgrade
        { Set-VerificationChecks -ProjectRoot $script:d -Checks (New-VerificationPlan -ProjectRoot $script:d) } | Should -Throw '*Start it first*'
        $p = Join-Path $script:d '.umbraco-upgrade/state.json'
        [System.IO.File]::WriteAllText($p, ([System.IO.File]::ReadAllText($p) -replace '"schemaVersion":\s*"1\.1\.0"', '"schemaVersion": "1.0.0"'))
        (Read-UpgradeState $script:d).schemaVersion | Should -Be '1.0.0'
        [void](Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status in-progress)
        $s = Set-VerificationChecks -ProjectRoot $script:d -Checks (New-VerificationPlan -ProjectRoot $script:d)
        $s.schemaVersion | Should -Be '1.1.0'
        @($s.history | Where-Object { $_.event -eq 'schema-migrated' }).Count | Should -Be 1
        (Test-UpgradeState -State (Read-UpgradeState $script:d)).Count | Should -Be 0
    }

    It 'lets only the script verify an automated check, and needs the user''s words, a recovery, or a reason' {
        $script:d = New-CompletedUpgrade -StartGate5
        $auto = (Get-CheckByRule $script:d 'unresolved').id
        $manual = (Get-CheckByRule $script:d 'frontend').id
        $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('verify-check', '-ProjectRoot', $script:d, '-CheckId', $auto, '-Result', 'verified', '-Evidence', 'plan.md')
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'Invoke-Verification\.ps1 records its result'
        (Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('verify-check', '-ProjectRoot', $script:d, '-CheckId', $auto, '-Result', 'failed', '-Note', 'x')).Json.error | Should -Match 'recovery'
        (Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('verify-check', '-ProjectRoot', $script:d, '-CheckId', $manual, '-Result', 'not-verified')).Json.error | Should -Match 'reason'
        (Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('verify-check', '-ProjectRoot', $script:d, '-CheckId', $manual, '-Result', 'verified', '-Note', 'looked fine')).Json.error | Should -Match 'evidence'
        $ev = Write-RedactedEvidence -ProjectRoot $script:d -Folder final -Name "$manual-user.md" -Content 'The user opened ten pages.'
        (Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('verify-check', '-ProjectRoot', $script:d, '-CheckId', $manual, '-Result', 'verified', '-Evidence', $ev.path)).Json.error | Should -Match 'user''s words'
        $ok = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('verify-check', '-ProjectRoot', $script:d, '-CheckId', $manual, '-Result', 'verified', '-Evidence', $ev.path, '-Note', 'I opened ten pages, all fine')
        $ok.ExitCode | Should -Be 0 -Because $ok.StdOut
        $ok.Json.check.result | Should -Be 'verified'
    }

    It 'passes only with no open or failed check and with report.md' {
        $script:d = New-CompletedUpgrade -StartGate5
        { Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status passed } | Should -Throw '*pending*'
        $checks = @((Read-UpgradeState $script:d).verification.checks)
        foreach ($c in $checks) { [void](Set-VerificationResult -ProjectRoot $script:d -CheckId $c.id -Result not-verified -Note 'not done in this test') }
        $first = $checks[0].id
        [void](Set-VerificationResult -ProjectRoot $script:d -CheckId $first -Result failed -Note 'it broke' -Recovery 'fix it in a follow-up phase')
        { Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status passed } | Should -Throw '*failed*'
        [void](Set-VerificationResult -ProjectRoot $script:d -CheckId $first -Result not-verified -Note 'The user accepted it: fix after go-live')
        { Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status passed } | Should -Throw '*report.md*'
        (Invoke-PluginScript -Script 'scripts/New-Report.ps1' -Arguments @('-ProjectRoot', $script:d)).ExitCode | Should -Be 0
        (Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status passed -Evidence @('report.md')).gates.final.status | Should -Be 'passed'
    }

    It 'starts a follow-up phase only after gate 5 is set back, and keeps the phases that ran' {
        $script:d = New-CompletedUpgrade -StartGate5
        $s = Read-UpgradeState $script:d
        $p3 = [ordered]@{ id = 'P3'; title = 'Fix the failed check'; area = 'custom-code'; patterns = @(); acceptanceCriteria = @([ordered]@{ id = 'P3-AC1'; text = 'Fixed'; verification = 'automated' }) }
        { Set-UpgradePhases -ProjectRoot $script:d -Phases (@($s.phases) + $p3) } | Should -Throw '*frozen*'
        [void](Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status failed -Notes 'V-01 failed; the user chose a follow-up phase')
        Add-Content -LiteralPath (Join-Path $script:d '.umbraco-upgrade/plan.md') -Value "`n### P3 Fix the failed check`n"
        (Test-PlanHash -ProjectRoot $script:d -Invalidate).status | Should -Be 'invalidated'
        $changed = ConvertTo-PlainObject $s.phases
        $changed[0]['title'] = 'Renamed after it ran'
        { Set-UpgradePhases -ProjectRoot $script:d -Phases (@($changed) + $p3) } | Should -Throw '*must stay exactly as recorded*'
        { Set-UpgradePhases -ProjectRoot $script:d -Phases @($s.phases[0], $p3, $s.phases[1]) } | Should -Throw '*keep their order*'
        { Set-UpgradePhases -ProjectRoot $script:d -Phases @($p3) } | Should -Throw '*cannot be removed*'
        $plain = ConvertTo-PlainObject $s.phases
        $r = Set-UpgradePhases -ProjectRoot $script:d -Phases (@($plain) + $p3)
        @($r.phases).Count | Should -Be 3
        $r.phases[0].status | Should -Be 'done'
        [void](Request-PlanApproval -ProjectRoot $script:d)
        [void](Add-Approval -ProjectRoot $script:d -Action 'start-plan-execution' -Decision approved -Note 'approve the follow-up')
        (Set-PhaseStatus -ProjectRoot $script:d -PhaseId P3 -Status in-progress).phases[2].status | Should -Be 'in-progress'
    }

    It 'refuses a phase start while gate 5 is in progress' {
        $script:d = New-CompletedUpgrade -StartGate5
        { Set-PhaseStatus -ProjectRoot $script:d -PhaseId P2 -Status in-progress } | Should -Throw '*Gate 5*'
    }
}

Describe 'Verification checklist' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'gives every upgrade the general checks and no conditional check without its pattern' {
        $script:d = New-CompletedUpgrade
        $plan = New-VerificationPlan -ProjectRoot $script:d
        $rules = @($plan | ForEach-Object { $_['rule'] })
        foreach ($r in @('build', 'cms-version', 'package-ranges', 'tests', 'phase-criteria', 'checkpoints', 'no-removal', 'no-secrets', 'unresolved', 'database-content', 'content-model', 'backoffice-workflows', 'frontend', 'logs', 'deployment', 'rollback')) { $rules | Should -Contain $r }
        foreach ($r in @('backoffice-extensions', 'auth', 'integrations', 'forms')) { $rules | Should -Not -Contain $r }
        $ids = @($plan | ForEach-Object { $_['id'] })
        $ids[0] | Should -Be 'V-01'
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'adds conditional checks for detected patterns and names their files' {
        $script:d = New-CompletedUpgrade
        $patterns = '{ "patterns": [ { "pattern": "backoffice.angular-property-editor", "occurrences": 2 }, { "pattern": "ext.http-client", "occurrences": 1 } ], "hits": [ { "pattern": "backoffice.angular-property-editor", "file": "App_Plugins/SampleBadge/package.manifest" }, { "pattern": "ext.http-client", "file": "Services/WeatherClient.cs" } ] }'
        New-Item -ItemType Directory -Force (Join-Path $script:d '.umbraco-upgrade/evidence/discovery') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:d '.umbraco-upgrade/evidence/discovery/patterns.json'), $patterns)
        $plan = New-VerificationPlan -ProjectRoot $script:d
        $bo = @($plan | Where-Object { $_['rule'] -eq 'backoffice-extensions' })[0]
        $bo | Should -Not -BeNullOrEmpty
        ($bo['appliesBecause'] -join ' ') | Should -Match 'backoffice\.angular-property-editor in App_Plugins/SampleBadge/package\.manifest'
        ((@($plan | Where-Object { $_['rule'] -eq 'integrations' })[0])['appliesBecause'] -join ' ') | Should -Match 'Services/WeatherClient\.cs'
        @($plan | Where-Object { $_['rule'] -in @('auth', 'forms') }).Count | Should -Be 0
    }

    It 'writes the plan evidence, the manual checklist, and the state file through the script' {
        $script:d = New-CompletedUpgrade
        [void](Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status in-progress)
        $r = Invoke-PluginScript -Script 'scripts/Get-VerificationPlan.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $md = [System.IO.File]::ReadAllText((Join-Path $script:d '.umbraco-upgrade/evidence/final/manual-checklist.md'))
        foreach ($m in @($r.Json.manual)) { $md | Should -Match ([regex]::Escape(($m -split ' ')[0])) }
        $md | Should -Match 'Never against a shared, staging, or production system'
        $md | Should -Not -Match '\{\{'
        $rec = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('verification', '-ProjectRoot', $script:d, '-JsonFile', $r.Json.stateFile)
        $rec.ExitCode | Should -Be 0 -Because $rec.StdOut
        $rec.Json.count | Should -Be $r.Json.checks
    }
}

Describe 'Automated gate 5 checks' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'records build and tests from the gate 5 build evidence, and leaves them open without it' {
        $script:d = New-CompletedUpgrade -StartGate5
        $r = Invoke-Verify $script:d
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        @($r.Json.pending | ForEach-Object { $_.rule }) | Should -Contain 'build'
        (Get-CheckByRule $script:d 'build').result | Should -Be 'pending'
        $b = Write-BuildEvidence $script:d
        $r = Invoke-Verify $script:d
        $build = Get-CheckByRule $script:d 'build'
        $build.result | Should -Be 'verified'
        $build.evidence | Should -Contain $b
        (Get-CheckByRule $script:d 'tests').result | Should -Be 'not-verified'
        (Get-CheckByRule $script:d 'tests').note | Should -Match 'no test projects'
        (Get-CheckByRule $script:d 'cms-version').result | Should -Be 'verified'
        foreach ($rule in @('phase-criteria', 'checkpoints', 'no-removal', 'no-secrets', 'unresolved', 'package-ranges')) { (Get-CheckByRule $script:d $rule).result | Should -Be 'verified' -Because "$rule : $((Get-CheckByRule $script:d $rule).note)" }
        @((Read-UpgradeState $script:d).verification.checks | Where-Object { $_.method -eq 'manual' -and $_.result -ne 'pending' }).Count | Should -Be 0 -Because 'manual checks are never recorded by the script'
    }

    It 'records a failed build as failed with its recovery, and a build without view compilation as not verified' {
        $script:d = New-CompletedUpgrade -StartGate5
        [void](Write-BuildEvidence $script:d -ExitCode 1)
        [void](Invoke-Verify $script:d)
        $b = Get-CheckByRule $script:d 'build'
        $b.result | Should -Be 'failed'
        $b.recovery | Should -Match 'follow-up phase'
        Start-Sleep -Milliseconds 20
        [void](Write-BuildEvidence $script:d -Precompiled $false)
        [void](Invoke-Verify $script:d)
        (Get-CheckByRule $script:d 'build').result | Should -Be 'not-verified'
    }

    It 'fails the version check while the project references another version' {
        $script:d = New-CompletedUpgrade -StartGate5
        $proj = Join-Path $script:d 'SampleSite.Web.csproj'
        [System.IO.File]::WriteAllText($proj, ([System.IO.File]::ReadAllText($proj).Replace('Version="17.7.1"', 'Version="17.0.0"')))
        [void](Invoke-Verify $script:d)
        (Get-CheckByRule $script:d 'cms-version').result | Should -Be 'failed'
        (Get-CheckByRule $script:d 'cms-version').note | Should -Match '17\.0\.0'
        (Get-CheckByRule $script:d 'checkpoints').result | Should -Be 'failed' -Because 'the change is not committed'
    }

    It 'checks the CMS ranges of the referenced package versions' {
        $script:d = New-CompletedUpgrade -StartGate5
        $proj = Join-Path $script:d 'SampleSite.Web.csproj'
        [System.IO.File]::WriteAllText($proj, ([System.IO.File]::ReadAllText($proj).Replace('<PackageReference Include="Umbraco.Cms" Version="17.7.1" />', '<PackageReference Include="Umbraco.Cms" Version="17.7.1" /><PackageReference Include="Sample.Modern.Grid" Version="17.0.2" />')))
        [void](Invoke-Verify $script:d)
        (Get-CheckByRule $script:d 'package-ranges').result | Should -Be 'verified'
        [System.IO.File]::WriteAllText($proj, ([System.IO.File]::ReadAllText($proj).Replace('<PackageReference Include="Sample.Modern.Grid" Version="17.0.2" />', '<PackageReference Include="Sample.Community.Editor" Version="2.1.0" />')))
        [void](Invoke-Verify $script:d)
        $c = Get-CheckByRule $script:d 'package-ranges'
        $c.result | Should -Be 'failed'
        $c.note | Should -Match 'Sample\.Community\.Editor 2\.1\.0'
    }

    It 'fails deletions without an approval and added stubs, and accepts an approved deletion' {
        $script:d = New-CompletedUpgrade -StartGate5
        $null = Invoke-Git $script:d @('rm', '-q', 'Views/Home.cshtml'); $null = Invoke-Git $script:d @('commit', '-q', '-m', 'remove a view')
        [void](Invoke-Verify $script:d)
        $c = Get-CheckByRule $script:d 'no-removal'
        $c.result | Should -Be 'failed'
        $c.note | Should -Match 'Views/Home\.cshtml'
        Add-Content -LiteralPath (Join-Path $script:d 'Program.cs') -Value 'static void Later() { throw new NotImplementedException(); }'
        $null = Invoke-Git $script:d @('commit', '-q', '-am', 'stub')
        [void](Invoke-Verify $script:d)
        (Get-CheckByRule $script:d 'no-removal').note | Should -Match 'stub'
        $null = Invoke-Git $script:d @('reset', '-q', '--hard', 'HEAD~1')
        [void](Add-Approval -ProjectRoot $script:d -Action 'remove-custom-feature' -Decision approved -Scope 'Views/Home.cshtml' -Note 'Delete it, the ported view replaces it')
        [void](Invoke-Verify $script:d)
        (Get-CheckByRule $script:d 'no-removal').result | Should -Be 'verified'
    }

    It 'fails secret-looking values on the branch and in .umbraco-upgrade/ without printing them' {
        $script:d = New-CompletedUpgrade -StartGate5
        $secret = 'FAKE-SECRET-FOR-TESTS-verify-branch-7Qk2'
        Set-Content -LiteralPath (Join-Path $script:d 'appsettings.Staging.json') -Value "{ `"Payments`": { `"ApiKey`": `"$secret`" } }" -Encoding ASCII
        $null = Invoke-Git $script:d @('add', 'appsettings.Staging.json'); $null = Invoke-Git $script:d @('commit', '-q', '-m', 'staging settings')
        $r = Invoke-Verify $script:d
        $c = Get-CheckByRule $script:d 'no-secrets'
        $c.result | Should -Be 'failed'
        $c.note | Should -Match 'appsettings\.Staging\.json'
        $r.StdOut | Should -Not -Match $secret
        Get-ChildItem -LiteralPath (Join-Path $script:d '.umbraco-upgrade') -Recurse -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) | Should -Not -Match $secret -Because $_.Name }
        $null = Invoke-Git $script:d @('reset', '-q', '--hard', 'HEAD~1')
        New-Item -ItemType Directory -Force (Join-Path $script:d '.umbraco-upgrade/tmp') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:d '.umbraco-upgrade/tmp/raw-output.txt'), "Password=$secret;`n")
        [void](Invoke-Verify $script:d)
        (Get-CheckByRule $script:d 'no-secrets').note | Should -Match 'tmp[\\/]raw-output\.txt'
    }

    It 'fails while an unresolved item is open and passes once the user defers it' {
        $script:d = New-CompletedUpgrade -StartGate5
        $u = Add-Unresolved -ProjectRoot $script:d -Item 'Export dashboard not ported' -Pattern 'backoffice.dashboard' -Proposal port
        [void](Invoke-Verify $script:d)
        (Get-CheckByRule $script:d 'unresolved').result | Should -Be 'failed'
        [void](Set-UnresolvedStatus -ProjectRoot $script:d -Id $u -Status deferred)
        [void](Invoke-Verify $script:d)
        (Get-CheckByRule $script:d 'unresolved').result | Should -Be 'verified'
        (Get-CheckByRule $script:d 'unresolved').note | Should -Match "Deferred by the user: $u"
    }

    It 'checks an upgrade in progress without recording anything' {
        $script:d = New-CompletedUpgrade -OpenSecondPhase
        $before = (Get-FileHash -LiteralPath (Join-Path $script:d '.umbraco-upgrade/state.json')).Hash
        $r = Invoke-Verify $script:d @('-Interim')
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.interim | Should -BeTrue
        @($r.Json.results | ForEach-Object { $_.rule }) | Should -Not -Contain 'build'
        (@($r.Json.results | Where-Object { $_.rule -eq 'phase-criteria' })[0]).note | Should -Match 'Interim: phases still open: P2'
        (Get-FileHash -LiteralPath (Join-Path $script:d '.umbraco-upgrade/state.json')).Hash | Should -Be $before
        @(Get-ChildItem -LiteralPath (Join-Path $script:d '.umbraco-upgrade/evidence/final') -Filter 'interim-*.json').Count | Should -Be 1
    }

    It 'refuses a plan-only run' {
        $script:d = New-UpgradeProject -Mode plan
        $r = Invoke-Verify $script:d
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'plan-only'
    }
}

Describe 'Report' -Tag 'fixture-based' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'separates what was verified automatically, manually, and not at all, and links existing evidence only' {
        $script:d = New-CompletedUpgrade -StartGate5
        [void](Write-BuildEvidence $script:d)
        [void](Invoke-Verify $script:d)
        $front = (Get-CheckByRule $script:d 'frontend').id
        $logs = (Get-CheckByRule $script:d 'logs').id
        $deploy = (Get-CheckByRule $script:d 'deployment').id
        $ev = Write-RedactedEvidence -ProjectRoot $script:d -Folder final -Name "$front-user.md" -Content 'The user compared twelve pages.'
        [void](Set-VerificationResult -ProjectRoot $script:d -CheckId $front -Result verified -Evidence @($ev.path) -Note 'I compared twelve pages, all match')
        [void](Set-VerificationResult -ProjectRoot $script:d -CheckId $logs -Result failed -Note 'Two errors at startup' -Recovery 'Fix the startup errors in a follow-up phase')
        [void](Set-VerificationResult -ProjectRoot $script:d -CheckId $deploy -Result not-verified -Note 'No test server available yet')
        $r = Invoke-PluginScript -Script 'scripts/New-Report.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $text = [System.IO.File]::ReadAllText((Join-Path $script:d '.umbraco-upgrade/report.md'))
        $auto = Get-ReportSection $text 'Verified automatically'
        $manual = Get-ReportSection $text 'Verified manually (by you)'
        $not = Get-ReportSection $text 'Not verified'
        $auto | Should -Match ([regex]::Escape((Get-CheckByRule $script:d 'build').id))
        $auto | Should -Match 'P1-AC1'
        $manual | Should -Match ([regex]::Escape($front))
        $manual | Should -Match 'P2-AC1'
        $manual | Should -Match 'I compared twelve pages'
        $not | Should -Match "$logs .*failed: Two errors at startup"
        $not | Should -Match "$deploy .*No test server available yet"
        $not | Should -Match ([regex]::Escape((Get-CheckByRule $script:d 'tests').id))
        foreach ($id in @(@((Read-UpgradeState $script:d).verification.checks) | ForEach-Object { $_.id })) {
            @(@($auto, $manual, $not) | Where-Object { $_ -match ([regex]::Escape($id) + '\b') }).Count | Should -Be 1 -Because "$id belongs to exactly one category"
        }
        foreach ($m in [regex]::Matches($text, '\]\(([^)]+)\)')) { Test-Path -LiteralPath (Join-Path $script:d ('.umbraco-upgrade/' + $m.Groups[1].Value)) | Should -BeTrue -Because $m.Groups[1].Value }
        $text | Should -Match '(?m)^Status: partial: final verification found failures'
        $r.Json.missingEvidence | Should -Be 0
    }

    It 'follows the template sections in order' {
        $script:d = New-CompletedUpgrade
        [void](Invoke-PluginScript -Script 'scripts/New-Report.ps1' -Arguments @('-ProjectRoot', $script:d))
        $text = [System.IO.File]::ReadAllText((Join-Path $script:d '.umbraco-upgrade/report.md'))
        $tpl = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'skills/upgrade-planning/templates/report.md'))
        $h = @([regex]::Matches($text, '(?m)^## (.+?)\r?$') | ForEach-Object { $_.Groups[1].Value })
        $t = @([regex]::Matches($tpl, '(?m)^## (.+?)\r?$') | ForEach-Object { $_.Groups[1].Value })
        ($h -join '|') | Should -Be ($t -join '|')
        $text | Should -Not -Match '<project name>|<UTC date>'
        (Get-ReportSection $text 'Not verified') | Should -Match 'Final verification \(gate 5\)'
    }

    It 'contains no secrets from decisions or evidence' {
        $script:d = New-CompletedUpgrade
        $secret = 'FAKE-SECRET-FOR-TESTS-report-9Zx4'
        Add-Content -LiteralPath (Join-Path $script:d '.umbraco-upgrade/decisions.md') -Value "`n## D-002 Payment settings`n`n- Decision: keep ApiKey=$secret in user secrets`n"
        [void](Add-Decision -ProjectRoot $script:d)
        [System.IO.File]::WriteAllText((Join-Path $script:d '.umbraco-upgrade/evidence/P2/raw.txt'), "Password=$secret`n")
        $r = Invoke-PluginScript -Script 'scripts/New-Report.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.Json.redacted | Should -BeTrue
        $text = [System.IO.File]::ReadAllText((Join-Path $script:d '.umbraco-upgrade/report.md'))
        $text | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
        $text | Should -Match 'D-002'
        $r.StdOut | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
    }

    It 'reports a waived criterion as not verified, with the user''s words, and as a deviation' {
        $phases = @([ordered]@{ id = 'P1'; title = 'Packages and framework'; area = 'application-framework'; patterns = @(); acceptanceCriteria = @([ordered]@{ id = 'P1-AC1'; text = 'Search works'; verification = 'manual' }) })
        $script:d = New-ApprovedUpgradeProject -Phases $phases -StartFirstPhase
        [void](Set-AcceptanceCriterion -ProjectRoot $script:d -PhaseId P1 -CriterionId 'P1-AC1' -Status waived -Note 'Search is rebuilt next quarter')
        [void](Invoke-PluginScript -Script 'scripts/New-Report.ps1' -Arguments @('-ProjectRoot', $script:d))
        $text = [System.IO.File]::ReadAllText((Join-Path $script:d '.umbraco-upgrade/report.md'))
        (Get-ReportSection $text 'Not verified') | Should -Match 'P1-AC1 Search works \| waived by you: Search is rebuilt next quarter'
        (Get-ReportSection $text 'Deviations from the plan') | Should -Match 'criterion P1-AC1 waived \| Search is rebuilt next quarter'
        $text | Should -Match '(?m)^Status: partial: phases open'
    }

    It 'gives a plan-only run a plan-only report' {
        $script:d = New-UpgradeProject -Mode plan
        $r = Invoke-PluginScript -Script 'scripts/New-Report.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.status | Should -Match '^plan only'
        $text = [System.IO.File]::ReadAllText((Join-Path $script:d '.umbraco-upgrade/report.md'))
        (Get-ReportSection $text 'Rollback') | Should -Match 'No rollback document'
    }

    It 'says complete once gate 5 passed' {
        $script:d = New-CompletedUpgrade -StartGate5
        foreach ($c in @((Read-UpgradeState $script:d).verification.checks)) { [void](Set-VerificationResult -ProjectRoot $script:d -CheckId $c.id -Result not-verified -Note 'not done in this test') }
        [void](Invoke-PluginScript -Script 'scripts/New-Report.ps1' -Arguments @('-ProjectRoot', $script:d))
        [void](Set-UpgradeGate -ProjectRoot $script:d -Gate final -Status passed -Evidence @('report.md'))
        $r = Invoke-PluginScript -Script 'scripts/New-Report.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.Json.status | Should -Be 'complete'
        ([System.IO.File]::ReadAllText((Join-Path $script:d '.umbraco-upgrade/report.md'))) | Should -Match '(?m)^Status: complete'
    }
}
