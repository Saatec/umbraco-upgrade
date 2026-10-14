# Argument handling for /umbraco-upgrade:start and :plan (Resolve-UpgradeArguments.ps1).
# Label: fixture-based (synthetic fixtures, real script in a child process).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    function Invoke-Args([string]$Target, [string]$Path, [string]$Command = 'start') {
        return Invoke-PluginScript -Script 'scripts/Resolve-UpgradeArguments.ps1' -Arguments @('-Command', $Command, '-Target', $Target, '-Path', $Path)
    }
}

Describe 'Resolve-UpgradeArguments' -Tag 'fixture-based' {
    Context 'target version format' {
        It 'accepts <target>' -ForEach @(
            @{ target = '17'; kind = 'major' }
            @{ target = '17.2'; kind = 'minor' }
            @{ target = '17.2.0'; kind = 'exact' }
        ) {
            $r = Invoke-Args $target (Get-FixturePath 'gen.v13')
            $r.ExitCode | Should -Be 0
            $r.Json.ok | Should -BeTrue
            $r.Json.target.requested | Should -Be $target
            $r.Json.target.kind | Should -Be $kind
            $r.Json.target.factStatus | Should -Be 'unverified'
        }
        It 'rejects <target> with code invalid-target' -ForEach @(
            @{ target = 'v17' }, @{ target = 'latest' }, @{ target = '17.x' }, @{ target = '17.0.0.1' }, @{ target = '-1' }, @{ target = '17 ' + [char]0x2013 }
        ) {
            $r = Invoke-Args $target (Get-FixturePath 'gen.v13')
            $r.ExitCode | Should -Be 1
            $r.Json.ok | Should -BeFalse
            @($r.Json.errors | ForEach-Object { $_.code }) | Should -Contain 'invalid-target'
        }
        It 'suggests the number when the target has a v prefix' {
            $r = Invoke-Args 'v17' (Get-FixturePath 'gen.v13')
            ($r.Json.errors | Where-Object { $_.code -eq 'invalid-target' }).message | Should -Match "Did you mean '17'"
        }
        It 'reports a missing target with usage' {
            $r = Invoke-Args '' (Get-FixturePath 'gen.v13')
            $r.ExitCode | Should -Be 1
            @($r.Json.errors | ForEach-Object { $_.code }) | Should -Contain 'missing-target'
            $r.Json.usage | Should -Match '/umbraco-upgrade:start <target-version> \[project-path\]'
        }
    }

    Context 'project path' {
        It 'reports a path that does not exist' {
            $r = Invoke-Args '17' (Join-Path ([System.IO.Path]::GetTempPath()) ('does-not-exist-' + [guid]::NewGuid()))
            $r.ExitCode | Should -Be 1
            @($r.Json.errors | ForEach-Object { $_.code }) | Should -Contain 'path-not-found'
        }
        It 'reports a file instead of a folder' {
            $r = Invoke-Args '17' (Join-Path (Get-FixturePath 'gen.v13') 'Program.cs')
            @($r.Json.errors | ForEach-Object { $_.code }) | Should -Contain 'path-not-directory'
        }
        It 'reports a folder without an Umbraco project' {
            $r = Invoke-Args '17' (Get-FixturePath 'gen.not-umbraco')
            $r.ExitCode | Should -Be 1
            @($r.Json.errors | ForEach-Object { $_.code }) | Should -Contain 'not-umbraco'
        }
        It 'defaults the path to the working directory' {
            $r = Invoke-PluginScript -Script 'scripts/Resolve-UpgradeArguments.ps1' -Arguments @('-Target', '17') -WorkingDirectory (Get-FixturePath 'gen.v13')
            $r.ExitCode | Should -Be 0
            $r.Json.projectRoot | Should -Be (Get-FixturePath 'gen.v13')
        }
        It 'strips quotes around the path' {
            $r = Invoke-Args '17' ('"' + (Get-FixturePath 'gen.v13') + '"')
            $r.ExitCode | Should -Be 0
        }
        It 'reports existing upgrade state' {
            $dir = New-UpgradeProject -Baseline 'gen.v13'
            try {
                $r = Invoke-Args '17' $dir
                $r.ExitCode | Should -Be 1
                @($r.Json.errors | ForEach-Object { $_.code }) | Should -Contain 'state-exists'
            } finally { Remove-TestDirectory $dir }
        }
    }

    Context 'each generation is recognized' {
        It '<fixture> is an Umbraco project' -ForEach @(
            @{ fixture = 'gen.v7'; target = '13' }, @{ fixture = 'gen.v7-old'; target = '13' }, @{ fixture = 'gen.v8'; target = '13' }
            @{ fixture = 'gen.v8-sqlce'; target = '13' }, @{ fixture = 'gen.v10'; target = '13' }, @{ fixture = 'gen.v13'; target = '17' }
            @{ fixture = 'gen.v13-startup-class'; target = '17' }, @{ fixture = 'gen.v13-cpm'; target = '17' }, @{ fixture = 'gen.v13-multi'; target = '17' }
            @{ fixture = 'gen.v14plus'; target = '18' }
        ) {
            $r = Invoke-Args $target (Get-FixturePath $fixture)
            $r.ExitCode | Should -Be 0
            $r.Json.detected.isUmbraco | Should -BeTrue
        }
    }

    Context 'target relative to source' {
        It 'rejects a target older than the source' {
            $r = Invoke-Args '10' (Get-FixturePath 'gen.v13')
            @($r.Json.errors | ForEach-Object { $_.code }) | Should -Contain 'target-not-newer'
        }
        It 'rejects an exact target equal to the source' {
            $r = Invoke-Args '13.10.1' (Get-FixturePath 'gen.v13')
            @($r.Json.errors | ForEach-Object { $_.code }) | Should -Contain 'target-not-newer'
        }
        It 'warns for a same-major target' {
            $r = Invoke-Args '13' (Get-FixturePath 'gen.v13')
            $r.ExitCode | Should -Be 0
            @($r.Json.warnings | ForEach-Object { $_.code }) | Should -Contain 'same-major'
        }
        It 'accepts an unknown future major (facts stay unverified)' {
            $r = Invoke-Args '25' (Get-FixturePath 'gen.v13')
            $r.ExitCode | Should -Be 0
            $r.Json.target.factStatus | Should -Be 'unverified'
        }
    }

    Context 'plan command' {
        It 'uses the plan usage line' {
            $r = Invoke-Args '' (Get-FixturePath 'gen.v13') 'plan'
            $r.Json.usage | Should -Match '/umbraco-upgrade:plan'
        }
    }
}
