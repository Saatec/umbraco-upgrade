# Package compatibility from NuGet metadata: version ranges, and the class of every direct package reference.
# Label: mocked (range unit cases; synthetic NuGet responses from tests/fixtures/mocks/m.nuget.synthetic, whose
# package ids and metadata are invented).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Planning.psm1') -Force -DisableNameChecking
    $script:Mock = Get-MockSet 'm.nuget.synthetic'
    function Invoke-Compatibility([string]$Dir, [string[]]$More = @()) {
        return (Invoke-PluginScript -Script 'scripts/Test-PackageCompatibility.ps1' -Arguments (@('-ProjectRoot', $Dir) + $More) -Environment @{ UMBRACO_UPGRADE_HTTP_MOCK = $script:Mock })
    }
    function Get-Row($Result, [string]$Id) { return @($Result.packages | Where-Object { $_.id -eq $Id })[0] }
    function Get-PatternPackages($Result, [string]$Pattern) { return @(@($Result.patterns | Where-Object { $_.pattern -eq $Pattern }) | ForEach-Object { @($_.packages) }) }
}

Describe 'NuGet version ranges' -Tag 'mocked' {
    It 'range <range> admits major <major>: <expected>' -ForEach @(
        @{ range = '[10.0.0, 14.0.0)'; major = 13; expected = $true }
        @{ range = '[10.0.0, 14.0.0)'; major = 14; expected = $false }
        @{ range = '[10.0.0, 14.0.0]'; major = 14; expected = $true }
        @{ range = '[17.0.0, 18.0.0)'; major = 17; expected = $true }
        @{ range = '[17.0.0, 18.0.0)'; major = 18; expected = $false }
        @{ range = '[17.0.0, 18.0.0)'; major = 16; expected = $false }
        @{ range = '10.0.0'; major = 17; expected = $true }
        @{ range = '10.0.0'; major = 9; expected = $false }
        @{ range = '(,14)'; major = 13; expected = $true }
        @{ range = '(,14)'; major = 14; expected = $false }
        @{ range = '[17.0.0]'; major = 17; expected = $true }
        @{ range = '[17.0.0]'; major = 18; expected = $false }
        @{ range = '[17.0.0-rc1, )'; major = 17; expected = $true }
        @{ range = 'not a range ['; major = 17; expected = $false }
    ) {
        Test-NuGetRangeAdmitsMajor -Range $range -Major $major | Should -Be $expected
    }

    It 'reads a bare version as an inclusive minimum without an upper bound' {
        $b = ConvertFrom-NuGetRange '10.0.0'
        $b.min | Should -Be '10.0.0'
        $b.minInclusive | Should -BeTrue
        $b.max | Should -BeNullOrEmpty
    }
}

Describe 'Test-PackageCompatibility.ps1' -Tag 'mocked' {
    AfterEach { if ($script:d) { Remove-TestDirectory $script:d; $script:d = $null } }

    It 'classifies each reference from the metadata of its releases, and never guesses' {
        $script:d = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.pkg.no-target'
        $r = Invoke-Compatibility $script:d @('-TargetMajor', '17', '-SourceMajor', '13')
        $r.ExitCode | Should -Be 0
        (Get-Row $r.Json 'Umbraco.Cms').class | Should -Be 'core'
        (Get-Row $r.Json 'Sample.Community.Editor').class | Should -Be 'no-target-version'
        $grid = Get-Row $r.Json 'Sample.Modern.Grid'
        $grid.class | Should -Be 'compatible'
        $grid.compatibleVersion | Should -Be '17.0.2'
        $open = Get-Row $r.Json 'Sample.Open.Range'
        $open.class | Should -Be 'compatible'
        @($open.notes | Where-Object { $_ -match 'no upper bound' }).Count | Should -Be 1
        (Get-Row $r.Json 'Sample.Utility').class | Should -Be 'not-cms-specific'
        (Get-Row $r.Json 'Sample.Private.Toolkit').class | Should -Be 'not-found'
        (@($r.Json.notFound) -join ',') | Should -Be 'Sample.Private.Toolkit'
        (@(Get-PatternPackages $r.Json 'pkg.no-target-version') -join ',') | Should -Be 'Sample.Community.Editor'
        $r.Json.factStatus | Should -Be 'package-metadata'
    }

    It 'finds the release line that supports an older target, and claims nothing when a release line cannot be read' {
        $script:d = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.pkg.no-target'
        $r = Invoke-Compatibility $script:d @('-TargetMajor', '13', '-SourceMajor', '10')
        $editor = Get-Row $r.Json 'Sample.Community.Editor'
        $editor.class | Should -Be 'compatible'
        $editor.compatibleVersion | Should -Be '2.1.0'
        # The 17.0.2 release does not support 13 and the mock has no metadata for 13.1.0.
        (Get-Row $r.Json 'Sample.Modern.Grid').class | Should -Be 'unreachable'
        @($r.Json.unreachable) -contains 'Sample.Modern.Grid' | Should -BeTrue
        @($r.Json.patterns).Count | Should -Be 0
    }

    It 'reports a library that targets .NET Framework only' {
        $script:d = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.pkg.framework-only'
        $r = Invoke-Compatibility $script:d @('-TargetMajor', '17')
        (Get-Row $r.Json 'Sample.Pdf.Legacy').class | Should -Be 'framework-only'
        (@(Get-PatternPackages $r.Json 'pkg.framework-only-libs') -join ',') | Should -Be 'Sample.Pdf.Legacy'
    }

    It 'reports a deprecated package with its alternate as the publisher states it' {
        $script:d = Copy-Fixture -Baseline 'gen.v13' -Overlay 'p.pkg.renamed'
        $r = Invoke-Compatibility $script:d @('-TargetMajor', '17')
        $row = Get-Row $r.Json 'Sample.Old.Widgets'
        $row.deprecation.alternatePackage.id | Should -Be 'Sample.New.Widgets'
        (@(Get-PatternPackages $r.Json 'pkg.renamed-community') -join ',') | Should -Be 'Sample.Old.Widgets'
        (@(Get-PatternPackages $r.Json 'pkg.no-target-version') -join ',') | Should -Be 'Sample.Old.Widgets'
    }

    It 'claims nothing from a range on a core package of an earlier generation, and applies the package knowledge' {
        $script:d = Copy-Fixture -Baseline 'gen.v8'
        $pc = Join-Path $script:d 'packages.config'
        $more = '  <package id="Sample.Legacy.Mapper" version="1.0.0" targetFramework="net472" />' + "`n" +
            '  <package id="UmbracoForms" version="8.5.0" targetFramework="net472" />' + "`n" +
            '  <package id="Umbraco.ModelsBuilder" version="8.1.6" targetFramework="net472" />' + "`n</packages>"
        [System.IO.File]::WriteAllText($pc, [System.IO.File]::ReadAllText($pc).Replace('</packages>', $more))
        $r = Invoke-Compatibility $script:d @('-TargetMajor', '13', '-SourceMajor', '8')
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        # Its only release depends on UmbracoCms.Core 7.3.2 or later, and that package has no 13 release.
        $mapper = Get-Row $r.Json 'Sample.Legacy.Mapper'
        $mapper.class | Should -Be 'no-target-version'
        (@($mapper.notes) -join ' ') | Should -Match 'UmbracoCms\.Core has no 13 release'
        $forms = Get-Row $r.Json 'UmbracoForms'
        $forms.class | Should -Be 'renamed'
        $forms.successor | Should -Be 'Umbraco.Forms'
        $mb = Get-Row $r.Json 'Umbraco.ModelsBuilder'
        $mb.class | Should -Be 'no-target-version'
        (@($mb.notes) -join ' ') | Should -Match 'No release after 8'
        @(Get-PatternPackages $r.Json 'pkg.renamed-community') | Should -Contain 'UmbracoForms'
        @(Get-PatternPackages $r.Json 'pkg.no-target-version') | Should -Contain 'Sample.Legacy.Mapper'
    }

    It 'does not take an old release without an upper bound as support when newer releases exclude the target' {
        $script:d = Copy-Fixture -Baseline 'gen.v13'
        $proj = Join-Path $script:d 'SampleSite.Web.csproj'
        [System.IO.File]::WriteAllText($proj, [System.IO.File]::ReadAllText($proj).Replace('<PackageReference Include="Umbraco.Cms" Version="13.10.1" />', '<PackageReference Include="Umbraco.Cms" Version="13.10.1" /><PackageReference Include="Sample.Stale.Range" Version="2.0.0" />'))
        # 2.0.0 depends on Umbraco.Cms.Core [13.0.0, 14.0.0); 1.0.0 on 10.0.0 or later, without an upper bound.
        $row = Get-Row (Invoke-Compatibility $script:d @('-TargetMajor', '17', '-SourceMajor', '13')).Json 'Sample.Stale.Range'
        $row.class | Should -Be 'no-target-version'
        (@($row.notes) -join ' ') | Should -Match 'Release 1\.0\.0 declares a CMS range without an upper bound'
        $row13 = Get-Row (Invoke-Compatibility $script:d @('-TargetMajor', '13', '-SourceMajor', '13')).Json 'Sample.Stale.Range'
        $row13.class | Should -Be 'compatible'
        $row13.compatibleVersion | Should -Be '2.0.0'
    }

    It 'follows the dependencies of a product package to its own core package to find the CMS range' {
        $script:d = Copy-Fixture -Baseline 'gen.v13'
        $proj = Join-Path $script:d 'SampleSite.Web.csproj'
        [System.IO.File]::WriteAllText($proj, [System.IO.File]::ReadAllText($proj).Replace('<PackageReference Include="Umbraco.Cms" Version="13.10.1" />', '<PackageReference Include="Umbraco.Cms" Version="13.10.1" /><PackageReference Include="Sample.Suite" Version="17.1.0" />'))
        # Sample.Suite depends only on Sample.Suite.Core, which depends on Umbraco.Cms.Core.
        $row = Get-Row (Invoke-Compatibility $script:d @('-TargetMajor', '17', '-SourceMajor', '13')).Json 'Sample.Suite'
        $row.class | Should -Be 'compatible'
        $row.compatibleVersion | Should -Be '17.1.0'
        (@($row.notes) -join ' ') | Should -Match 'through packages of its own family'
    }

    It 'marks ASP.NET packages of a 7 or 8 source as platform, and an unrecorded lookup as unreachable' {
        $script:d = Copy-Fixture -Baseline 'gen.v8'
        $r = Invoke-Compatibility $script:d @('-TargetMajor', '17', '-SourceMajor', '8')
        (Get-Row $r.Json 'Microsoft.AspNet.Mvc').class | Should -Be 'platform'
        (Get-Row $r.Json 'UmbracoCms.Core').class | Should -Be 'core'
        (Get-Row $r.Json 'Serilog').class | Should -Be 'unreachable'
        (@($r.Json.unreachable) -join ',') | Should -Be 'Serilog'
    }

    It 'takes the majors from state and writes the planning evidence' {
        $script:d = New-ApprovedUpgradeProject -Overlay 'p.pkg.framework-only'
        $r = Invoke-Compatibility $script:d
        $r.ExitCode | Should -Be 0
        $r.Json.targetMajor | Should -Be 17
        $r.Json.sourceMajor | Should -Be 13
        Test-Path (Join-Path $script:d '.umbraco-upgrade/evidence/planning/package-compatibility.json') | Should -BeTrue
    }

    It 'refuses without a target and a data directory inside the plugin' {
        $script:d = Copy-Fixture -Baseline 'gen.v13'
        (Invoke-Compatibility $script:d).Json.error | Should -Match 'TargetMajor'
        (Invoke-Compatibility $script:d @('-TargetMajor', '17', '-DataDir', (Join-Path (Get-RepoRoot) 'knowledge'))).Json.error | Should -Match 'plugin root'
    }
}
