# Resume reconciliation (Test-StateReality.ps1): mismatches between state and the repository or the files are
# reported with options, and nothing is ever repaired.
# Label: mocked (each case builds a synthetic upgrade in a temporary git repository, then constructs one git or
# file mismatch by hand, as an interrupted or tampered-with upgrade would leave it).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/State.psm1') -Force -DisableNameChecking
    $env:GIT_OPTIONAL_LOCKS = '0'

    function Invoke-Git([string]$Dir, [string[]]$GitArgs) { $out = & git -C $Dir @GitArgs 2>&1; return $out }

    function New-ReconcileProject {
        # An approved upgrade: gate documents present, path step S1 13.10.1 to 17.7.1, P1 (framework) done at a
        # checkpoint with the packages moved to 17.7.1, P2 pending.
        $phases = @(
            [ordered]@{ id = 'P1'; title = 'Packages, framework, and startup'; area = 'application-framework'; patterns = @(); acceptanceCriteria = @([ordered]@{ id = 'P1-AC1'; text = 'The solution builds'; verification = 'automated' }) },
            [ordered]@{ id = 'P2'; title = 'Custom code'; area = 'custom-code'; patterns = @('code.render-controller'); acceptanceCriteria = @([ordered]@{ id = 'P2-AC1'; text = 'Controllers ported'; verification = 'manual' }) })
        $d = New-ApprovedUpgradeProject -Phases $phases
        $sd = Join-Path $d '.umbraco-upgrade'
        foreach ($f in @('inventory.md', 'compatibility.md', 'risks.md')) { [System.IO.File]::WriteAllText((Join-Path $sd $f), "# $f`n") }
        [System.IO.File]::WriteAllText((Join-Path $sd 'decisions.md'), "# Decisions`n`n## D-001 Upgrade path`n`n- Decision: in place`n")
        [void](Update-StateSection -ProjectRoot $d -Section path -Values @{ steps = @([ordered]@{ id = 'S1'; from = '13.10.1'; to = '17.7.1'; kind = @('code', 'database') }) })
        New-Item -ItemType Directory -Force (Join-Path $sd 'evidence/planning') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sd 'evidence/planning/phase-composition.json'), '{ "phases": [ { "id": "P1", "step": "S1" }, { "id": "P2", "step": "S1" } ] }')
        [void](Set-PhaseStatus -ProjectRoot $d -PhaseId P1 -Status in-progress)
        $proj = Join-Path $d 'SampleSite.Web.csproj'
        [System.IO.File]::WriteAllText($proj, ([System.IO.File]::ReadAllText($proj).Replace('Version="13.10.1"', 'Version="17.7.1"').Replace('net8.0', 'net10.0')))
        $ev = Invoke-PluginScript -Script 'scripts/Write-Evidence.ps1' -Arguments @('-ProjectRoot', $d, '-Folder', 'P1', '-Name', 'build-note.md', '-Text', 'Build evidence for the test.')
        if ($ev.ExitCode -ne 0) { throw "evidence: $($ev.StdOut)" }
        [void](Set-AcceptanceCriterion -ProjectRoot $d -PhaseId P1 -CriterionId 'P1-AC1' -Status met -Evidence @('evidence/P1/build-note.md'))
        $cp = Invoke-PluginScript -Script 'scripts/New-Checkpoint.ps1' -Arguments @('-ProjectRoot', $d, '-PhaseId', 'P1')
        if ($cp.ExitCode -ne 0) { throw "checkpoint: $($cp.StdOut)" }
        [void](Set-PhaseStatus -ProjectRoot $d -PhaseId P1 -Status done)
        return $d
    }

    function Get-Reality([string]$Dir) {
        # Everything reconciliation must leave as it found it.
        $st = Join-Path $Dir '.umbraco-upgrade/state.json'
        return [ordered]@{
            state = (Get-FileHash -LiteralPath $st -Algorithm SHA256).Hash
            refs = ((Invoke-Git $Dir @('for-each-ref', '--format=%(refname) %(objectname)')) -join "`n")
            head = ((Invoke-Git $Dir @('rev-parse', 'HEAD')) -join '')
            symbolic = ((Invoke-Git $Dir @('rev-parse', '--abbrev-ref', 'HEAD')) -join '')
            status = ((Invoke-Git $Dir @('status', '--porcelain=v1', '--untracked-files=all')) -join "`n")
            plan = (Get-FileHash -LiteralPath (Join-Path $Dir '.umbraco-upgrade/plan.md') -Algorithm SHA256).Hash
        }
    }

    function Invoke-Reconcile([string]$Dir) {
        $before = Get-Reality $Dir
        $r = Invoke-PluginScript -Script 'scripts/Test-StateReality.ps1' -Arguments @('-ProjectRoot', $Dir)
        $after = Get-Reality $Dir
        foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] -Because "reconciliation must not change $k" }
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        return $r.Json
    }

    function Get-Check($Result, [string]$Id) { return @($Result.checks | Where-Object { $_.id -eq $Id }) | Select-Object -First 1 }
}

Describe 'Resume reconciliation' -Tag 'mocked' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'reports a consistent upgrade and where it continues' {
        $script:d = New-ReconcileProject
        $r = Invoke-Reconcile $script:d
        $r.ok | Should -BeTrue
        $r.consistent | Should -BeTrue -Because (($r.checks | Where-Object { $_.status -eq 'mismatch' } | ForEach-Object { "$($_.id): $($_.detail)" }) -join '; ')
        $r.mismatches | Should -Be 0
        $r.position.kind | Should -Be 'phase'
        $r.position.phase | Should -Be 'P2'
        $r.position.status | Should -Be 'pending'
        (Get-Check $r 'packages.version').status | Should -Be 'ok'
        (Get-Check $r 'packages.version').actual | Should -Be '17.7.1'
        (Get-Check $r 'git.head').status | Should -Be 'ok'
        $r.note | Should -Match 'never repair'
    }

    It 'reports commits after the last checkpoint that no phase records, with options, and changes nothing' {
        $script:d = New-ReconcileProject
        [System.IO.File]::WriteAllText((Join-Path $script:d 'Notes.txt'), "unrelated`n")
        $null = Invoke-Git $script:d @('add', '-A'); $null = Invoke-Git $script:d @('commit', '-q', '-m', 'work outside the plugin')
        $r = Invoke-Reconcile $script:d
        $r.consistent | Should -BeFalse
        $c = Get-Check $r 'git.head'
        $c.status | Should -Be 'mismatch'
        $c.detail | Should -Match '1 commit\(s\) after the checkpoint of P1'
        @($c.options).Count | Should -BeGreaterThan 0
    }

    It 'reports a checkpoint that is no longer part of HEAD after a reset' {
        $script:d = New-ReconcileProject
        $null = Invoke-Git $script:d @('reset', '-q', '--hard', 'HEAD~1')
        $r = Invoke-Reconcile $script:d
        $r.consistent | Should -BeFalse
        (Get-Check $r 'git.checkpoint.P1').status | Should -Be 'mismatch'
        (Get-Check $r 'git.checkpoint.P1').detail | Should -Match 'not part of the current HEAD'
        $pkg = Get-Check $r 'packages.version'
        $pkg.status | Should -Be 'mismatch'
        $pkg.expected | Should -Be '17.7.1'
        $pkg.actual | Should -Be '13.10.1'
        $r.position.phase | Should -Be 'P2' -Because 'the position comes from state; the mismatch decides whether to continue'
    }

    It 'reports a checkpoint commit that is not in the repository' {
        $script:d = New-ReconcileProject
        [void](Set-PhaseCheckpoint -ProjectRoot $script:d -PhaseId P1 -Commit ('ab' * 20))
        $r = Invoke-Reconcile $script:d
        (Get-Check $r 'git.checkpoint.P1').status | Should -Be 'mismatch'
        (Get-Check $r 'git.checkpoint.P1').actual | Should -Be 'commit not found'
    }

    It 'reports the wrong branch and a detached HEAD' {
        $script:d = New-ReconcileProject
        $null = Invoke-Git $script:d @('checkout', '-q', 'main')
        $r = Invoke-Reconcile $script:d
        $c = Get-Check $r 'git.branch'
        $c.status | Should -Be 'mismatch'
        $c.expected | Should -Be 'umbraco-upgrade/13-to-17'
        $c.actual | Should -Be 'main'
        $null = Invoke-Git $script:d @('checkout', '-q', '--detach', 'umbraco-upgrade/13-to-17')
        $r = Invoke-Reconcile $script:d
        (Get-Check $r 'git.branch').actual | Should -Match '^detached HEAD'
    }

    It 'reports uncommitted changes: a mismatch with no phase open, a warning while one is' {
        $script:d = New-ReconcileProject
        Add-Content -LiteralPath (Join-Path $script:d 'Program.cs') -Value '// edited outside any phase'
        $r = Invoke-Reconcile $script:d
        (Get-Check $r 'git.working-tree').status | Should -Be 'mismatch'
        (Get-Check $r 'git.working-tree').detail | Should -Match 'Program\.cs'
        [void](Set-PhaseStatus -ProjectRoot $script:d -PhaseId P2 -Status in-progress)
        $r = Invoke-Reconcile $script:d
        (Get-Check $r 'git.working-tree').status | Should -Be 'warning'
        $r.position.phase | Should -Be 'P2'
        $r.position.status | Should -Be 'in-progress'
    }

    It 'reports plan.md edited after approval' {
        $script:d = New-ReconcileProject
        Add-Content -LiteralPath (Join-Path $script:d '.umbraco-upgrade/plan.md') -Value 'An extra line.'
        $before = Get-FileHash -LiteralPath (Join-Path $script:d '.umbraco-upgrade/plan.md')
        $r = Invoke-PluginScript -Script 'scripts/Test-StateReality.ps1' -Arguments @('-ProjectRoot', $script:d)
        (Get-Check $r.Json 'plan.hash').status | Should -Be 'mismatch'
        (Get-Check $r.Json 'plan.hash').actual | Should -Match 'changed after approval was given'
        (Get-FileHash -LiteralPath (Join-Path $script:d '.umbraco-upgrade/plan.md')).Hash | Should -Be $before.Hash
        (Read-UpgradeState $script:d).gates.planApproval.status | Should -Be 'approved' -Because 'reconciliation does not invalidate the approval itself'
    }

    It 'reports missing evidence and decisions that decisions.md does not describe' {
        $script:d = New-ReconcileProject
        Remove-Item -LiteralPath (Join-Path $script:d '.umbraco-upgrade/evidence/P1/build-note.md')
        [System.IO.File]::WriteAllText((Join-Path $script:d '.umbraco-upgrade/decisions.md'), "# Decisions`n")
        $r = Invoke-Reconcile $script:d
        (Get-Check $r 'files.expected').status | Should -Be 'mismatch'
        (Get-Check $r 'files.expected').detail | Should -Match 'evidence/P1/build-note\.md \(P1 P1-AC1\)'
        (Get-Check $r 'files.decisions').status | Should -Be 'mismatch'
        (Get-Check $r 'files.decisions').actual | Should -Match 'D-001'
        Test-Path (Join-Path $script:d '.umbraco-upgrade/evidence/P1/build-note.md') | Should -BeFalse -Because 'nothing is restored'
    }

    It 'reports a CMS version in the project files that state does not expect' {
        $script:d = New-ReconcileProject
        $proj = Join-Path $script:d 'SampleSite.Web.csproj'
        [System.IO.File]::WriteAllText($proj, ([System.IO.File]::ReadAllText($proj).Replace('Version="17.7.1"', 'Version="17.0.0"')))
        $r = Invoke-Reconcile $script:d
        $c = Get-Check $r 'packages.version'
        $c.status | Should -Be 'mismatch'
        $c.expected | Should -Be '17.7.1'
        $c.actual | Should -Be '17.0.0'
        $c.detail | Should -Match 'after phase P1'
    }

    It 'reports a git operation in progress' {
        $script:d = New-ReconcileProject
        $head = (Invoke-Git $script:d @('rev-parse', 'HEAD')) -join ''
        [System.IO.File]::WriteAllText((Join-Path $script:d '.git/MERGE_HEAD'), "$head`n")
        $r = Invoke-Reconcile $script:d
        (Get-Check $r 'git.operation').status | Should -Be 'mismatch'
        (Get-Check $r 'git.operation').actual | Should -Match 'merge'
    }

    It 'reports a state file that fails validation, without rewriting it' {
        $script:d = New-ReconcileProject
        $p = Join-Path $script:d '.umbraco-upgrade/state.json'
        [System.IO.File]::WriteAllText($p, ([System.IO.File]::ReadAllText($p) -replace '"mode":\s*"upgrade"', '"mode": "bogus"'))
        $r = Invoke-Reconcile $script:d
        (Get-Check $r 'state.valid').status | Should -Be 'mismatch'
        $r.consistent | Should -BeFalse
    }

    It 'reports a non-local database for the declared local copy without printing the connection string' {
        $script:d = New-ReconcileProject
        [void](Update-StateSection -ProjectRoot $script:d -Section source -Values @{ database = @{ localCopyDeclared = $true } })
        $pw = 'FAKE-SECRET-FOR-TESTS-reconcile-db'
        [System.IO.File]::WriteAllText((Join-Path $script:d 'appsettings.Development.json'), "{ `"ConnectionStrings`": { `"umbracoDbDSN`": `"Server=db-shared.example.invalid;Database=Site;User Id=app;Password=$pw`", `"umbracoDbDSN_ProviderName`": `"Microsoft.Data.SqlClient`" } }")
        $r = Invoke-PluginScript -Script 'scripts/Test-StateReality.ps1' -Arguments @('-ProjectRoot', $script:d)
        $c = Get-Check $r.Json 'database.local-copy'
        $c.status | Should -Be 'mismatch'
        $c.actual | Should -Match 'non-local server'
        $r.StdOut | Should -Not -Match ([regex]::Escape($pw))
        $r.StdOut | Should -Not -Match 'db-shared'
    }

    It 'warns about new commits on the base branch of a plan-only run' {
        $script:d = New-UpgradeProject -Baseline 'gen.v13' -Mode plan
        [System.IO.File]::WriteAllText((Join-Path $script:d 'Later.txt'), "x`n")
        $null = Invoke-Git $script:d @('add', 'Later.txt'); $null = Invoke-Git $script:d @('commit', '-q', '-m', 'later work')
        $r = Invoke-PluginScript -Script 'scripts/Test-StateReality.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.ExitCode | Should -Be 0
        (Get-Check $r.Json 'git.base-commit').status | Should -Be 'warning'
        $r.Json.position.gate | Should -Be 'discovery'
    }

    It 'fails clearly without state' {
        $script:d = Copy-Fixture -Baseline 'gen.v13'
        $r = Invoke-PluginScript -Script 'scripts/Test-StateReality.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'No upgrade state'
    }
}
