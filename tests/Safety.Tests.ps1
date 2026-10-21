# Gate 1 and gate 3 scripts: discovery, preconditions, upgrade branch, state folder policy.
# Label: fixture-based (temporary git repositories built from synthetic fixtures).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    function Get-StateJson([string]$Dir) { return (Get-Content -Raw (Join-Path $Dir '.umbraco-upgrade/state.json') | ConvertFrom-Json) }
    function Invoke-State([string]$Dir, [string[]]$Arguments) { return Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments (@($Arguments[0], '-ProjectRoot', $Dir) + @($Arguments | Select-Object -Skip 1)) }
}

Describe 'Invoke-Discovery' -Tag 'fixture-based' {
    It 'records source, project, and evidence and leaves the project unchanged' {
        $d = Copy-Fixture -Baseline 'gen.v13-multi'
        try {
            Initialize-GitRepo -Path $d -Commit
            (Invoke-State $d @('init', '-Mode', 'plan', '-Target', '17')).ExitCode | Should -Be 0
            $r = Invoke-PluginScript -Script 'scripts/Invoke-Discovery.ps1' -Arguments @('-ProjectRoot', $d)
            $r.ExitCode | Should -Be 0
            $r.Json.version.resolved | Should -Be '13.10.1'
            $r.Json.database.engine | Should -Be 'sqlserver'
            $s = Get-StateJson $d
            $s.source.umbraco | Should -Be '13.10.1'
            $s.source.major | Should -Be 13
            $s.source.database.target | Should -Be 'local'
            $s.project.solution | Should -Be 'SampleSite.sln'
            $s.project.webProject | Should -Be 'src/SampleSite.Web/SampleSite.Web.csproj'
            $s.gates.discovery.status | Should -Be 'in-progress'
            @($s.gates.discovery.evidence) | Should -Contain 'evidence/discovery/patterns.json'
            # Only .umbraco-upgrade/ appears in git status.
            $status = @(& git -C $d status --porcelain --untracked-files=all)
            @($status | Where-Object { $_ -notmatch '\.umbraco-upgrade/' }).Count | Should -Be 0
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'Test-SafetyPreconditions' -Tag 'fixture-based' {
    It 'passes on a clean tree and ignores the state folder' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $r = Invoke-PluginScript -Script 'scripts/Test-SafetyPreconditions.ps1' -Arguments @('-ProjectRoot', $d)
            $r.Json.ok | Should -BeTrue
            $r.Json.stateFolderChanges | Should -BeGreaterThan 0
            $r.Json.branch | Should -Be 'main'
        } finally { Remove-TestDirectory $d }
    }
    It 'stops on uncommitted changes and lists them without touching them' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            Add-Content -LiteralPath (Join-Path $d 'Program.cs') -Value '// local change'
            [System.IO.File]::WriteAllText((Join-Path $d 'new-file.txt'), 'x')
            $r = Invoke-PluginScript -Script 'scripts/Test-SafetyPreconditions.ps1' -Arguments @('-ProjectRoot', $d)
            $r.Json.ok | Should -BeFalse
            @($r.Json.problems | ForEach-Object { $_.code }) | Should -Contain 'uncommitted-changes'
            @($r.Json.changes | ForEach-Object { $_.path }) | Should -Contain 'Program.cs'
            (Get-Content -Raw (Join-Path $d 'Program.cs')) | Should -Match 'local change'
            Test-Path (Join-Path $d 'new-file.txt') | Should -BeTrue
            @(& git -C $d stash list).Count | Should -Be 0
        } finally { Remove-TestDirectory $d }
    }
    It 'reports a folder that is not a git repository' {
        $d = Copy-Fixture -Baseline 'gen.v13'
        try {
            $r = Invoke-PluginScript -Script 'scripts/Test-SafetyPreconditions.ps1' -Arguments @('-ProjectRoot', $d)
            @($r.Json.problems | ForEach-Object { $_.code }) | Should -Contain 'not-a-repo'
        } finally { Remove-TestDirectory $d }
    }
    It 'strips credentials from remote URLs' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $null = & git -C $d remote add origin 'https://someone:FAKE-SECRET-FOR-TESTS-pat@git.example.invalid/repo.git' 2>&1
            $r = Invoke-PluginScript -Script 'scripts/Test-SafetyPreconditions.ps1' -Arguments @('-ProjectRoot', $d)
            $r.StdOut | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
            $r.Json.remotes[0].url | Should -Be 'https://***@git.example.invalid/repo.git'
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'New-UpgradeBranch and state folder policy' -Tag 'fixture-based' {
    BeforeEach {
        $script:d = New-UpgradeProject -Baseline 'gen.v13'
    }
    AfterEach { Remove-TestDirectory $script:d }

    It 'refuses before gates 1 and 2 have passed' {
        $r = Invoke-PluginScript -Script 'scripts/New-UpgradeBranch.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match "Gate 'discovery'"
        (& git -C $script:d branch --show-current) | Should -Be 'main'
    }

    It 'creates the branch from a clean tree and records it; refuses a dirty tree' {
        (Invoke-State $script:d @('gate', '-Gate', 'discovery', '-Status', 'passed', '-Evidence', 'evidence/discovery/git-status-at-start.json')).ExitCode | Should -Be 0
        (Invoke-State $script:d @('set', '-Section', 'source', '-Set', 'umbraco=13.10.1;major=13;confidence=high')).ExitCode | Should -Be 0
        (Invoke-State $script:d @('set', '-Section', 'target', '-Set', 'resolved=17.7.1;dotnet=net10.0;lts.value=true;lts.source=D-001')).ExitCode | Should -Be 0
        (Invoke-State $script:d @('set', '-Section', 'path', '-Set', 'selection=selected;strategy=in-place;decision=D-001')).ExitCode | Should -Be 0
        (Invoke-State $script:d @('gate', '-Gate', 'versionPath', '-Status', 'passed')).ExitCode | Should -Be 0
        Add-Content -LiteralPath (Join-Path $script:d 'Program.cs') -Value '// local change'
        $r0 = Invoke-PluginScript -Script 'scripts/New-UpgradeBranch.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r0.ExitCode | Should -Be 1
        $r0.Json.error | Should -Match 'uncommitted'
        $null = & git -C $script:d checkout -q -- Program.cs 2>&1
        $r = Invoke-PluginScript -Script 'scripts/New-UpgradeBranch.ps1' -Arguments @('-ProjectRoot', $script:d)
        $r.ExitCode | Should -Be 0
        $r.Json.branch | Should -Be 'umbraco-upgrade/13-to-17'
        (& git -C $script:d branch --show-current) | Should -Be 'umbraco-upgrade/13-to-17'
        $s = Get-StateJson $script:d
        $s.gitBaseline.upgradeBranch | Should -Be 'umbraco-upgrade/13-to-17'
        $s.gitBaseline.baseBranch | Should -Be 'main'
    }

    It 'applies exclude-local in .git/info/exclude without changing tracked files' {
        $r = Invoke-PluginScript -Script 'scripts/Set-StateFolderPolicy.ps1' -Arguments @('-ProjectRoot', $script:d, '-Policy', 'exclude-local')
        $r.Json.result | Should -Be 'applied'
        (Get-Content -Raw (Join-Path $script:d '.git/info/exclude')) | Should -Match '/\.umbraco-upgrade/'
        @(& git -C $script:d status --porcelain --untracked-files=all).Count | Should -Be 0
        (Get-StateJson $script:d).project.stateFolderPolicy | Should -Be 'exclude-local'
    }

    It 'refuses gitignore before gate 3' {
        $r = Invoke-PluginScript -Script 'scripts/Set-StateFolderPolicy.ps1' -Arguments @('-ProjectRoot', $script:d, '-Policy', 'gitignore')
        $r.ExitCode | Should -Be 1
        Test-Path (Join-Path $script:d '.gitignore') | Should -BeFalse
    }

    It 'only records the policy in plan mode' {
        $p = New-UpgradeProject -Baseline 'gen.v13' -Mode plan
        try {
            $r = Invoke-PluginScript -Script 'scripts/Set-StateFolderPolicy.ps1' -Arguments @('-ProjectRoot', $p, '-Policy', 'exclude-local')
            $r.Json.result | Should -Be 'recorded'
            (Get-Content -Raw (Join-Path $p '.git/info/exclude')) | Should -Not -Match 'umbraco-upgrade'
        } finally { Remove-TestDirectory $p }
    }
}
