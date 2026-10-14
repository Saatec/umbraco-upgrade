# Version detection on every gen.* fixture, including conflicting signals.
# Label: fixture-based.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Discovery.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/ConnectionInfo.psm1') -Force -DisableNameChecking
    function Set-FileText([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }
}

Describe 'Get-UmbracoVersionInfo on generation baselines' -Tag 'fixture-based' {
    It '<fixture> resolves to <version> (<generation>)' -ForEach @(
        @{ fixture = 'gen.v7'; version = '7.15.10'; major = 7; generation = 'v7'; tfm = 'net452' }
        @{ fixture = 'gen.v7-old'; version = '7.6.4'; major = 7; generation = 'v7'; tfm = 'net45' }
        @{ fixture = 'gen.v8'; version = '8.18.8'; major = 8; generation = 'v8'; tfm = 'net472' }
        @{ fixture = 'gen.v8-sqlce'; version = '8.17.2'; major = 8; generation = 'v8'; tfm = 'net472' }
        @{ fixture = 'gen.v10'; version = '10.8.6'; major = 10; generation = 'v9-v13'; tfm = 'net6.0' }
        @{ fixture = 'gen.v13'; version = '13.10.1'; major = 13; generation = 'v9-v13'; tfm = 'net8.0' }
        @{ fixture = 'gen.v13-startup-class'; version = '13.10.1'; major = 13; generation = 'v9-v13'; tfm = 'net8.0' }
        @{ fixture = 'gen.v13-cpm'; version = '13.10.1'; major = 13; generation = 'v9-v13'; tfm = 'net8.0' }
        @{ fixture = 'gen.v13-multi'; version = '13.10.1'; major = 13; generation = 'v9-v13'; tfm = 'net8.0' }
        @{ fixture = 'gen.v14plus'; version = '17.2.0'; major = 17; generation = 'v14+'; tfm = 'net10.0' }
    ) {
        $v = Get-UmbracoVersionInfo -Root (Get-FixturePath $fixture)
        $v.isUmbraco | Should -BeTrue
        $v.resolved.version | Should -Be $version
        $v.resolved.major | Should -Be $major
        $v.resolved.generation | Should -Be $generation
        $v.resolved.confidence | Should -Be 'high'
        $v.resolved.needsConfirmation | Should -BeFalse
        @($v.conflicts).Count | Should -Be 0
        @($v.errors).Count | Should -Be 0
        $v.targetFrameworks | Should -Contain $tfm
        $v.factStatus | Should -Be 'unverified'
    }

    It 'gen.not-umbraco is not an Umbraco project' {
        $v = Get-UmbracoVersionInfo -Root (Get-FixturePath 'gen.not-umbraco')
        $v.isUmbraco | Should -BeFalse
        $v.resolved.version | Should -BeNullOrEmpty
        $v.resolved.confidence | Should -Be 'none'
    }

    It 'reads the v7 and v8 configuration status keys as medium-confidence signals' {
        foreach ($f in @('gen.v7', 'gen.v8')) {
            $v = Get-UmbracoVersionInfo -Root (Get-FixturePath $f)
            @($v.signals | Where-Object { $_.kind -eq 'config-status' -and $_.confidence -eq 'medium' }).Count | Should -Be 1
            @($v.hints | Where-Object { $_.kind -eq 'legacy-config-file' }).Count | Should -BeGreaterThan 0
        }
    }

    It 'reads central package management' {
        $v = Get-UmbracoVersionInfo -Root (Get-FixturePath 'gen.v13-cpm')
        @($v.signals | Where-Object { $_.kind -eq 'CentralPackageVersion' -and $_.version -eq '13.10.1' }).Count | Should -Be 1
    }

    It 'finds the web project in a multi-project solution' {
        $v = Get-UmbracoVersionInfo -Root (Get-FixturePath 'gen.v13-multi')
        $v.webProjects | Should -Be @('src/SampleSite.Web/SampleSite.Web.csproj')
        @($v.signals | Where-Object { $_.packageId -eq 'Umbraco.Cms.Core' }).Count | Should -Be 1
    }

    It 'notes the modern backoffice manifest on v14+' {
        $v = Get-UmbracoVersionInfo -Root (Get-FixturePath 'gen.v14plus')
        @($v.hints | Where-Object { $_.kind -eq 'backoffice-manifest' -and $_.hint -eq 'modern-backoffice' }).Count | Should -Be 1
    }

    It 'runs as a script and prints JSON' {
        $r = Invoke-PluginScript -Script 'scripts/Get-UmbracoVersion.ps1' -Arguments @('-Path', (Get-FixturePath 'gen.v13'))
        $r.ExitCode | Should -Be 0
        $r.Json.resolved.version | Should -Be '13.10.1'
    }
}

Describe 'Get-UmbracoVersionInfo with conflicting or partial signals' -Tag 'fixture-based' {
    BeforeEach { $script:dirs = @() }
    AfterEach { foreach ($d in $script:dirs) { Remove-TestDirectory $d } }

    It 'reports a configuration status that lags the packages' {
        $d = Copy-Fixture -Baseline 'gen.v8'; $script:dirs += $d
        $wc = Join-Path $d 'web.config'
        Set-FileText $wc ((Get-Content -Raw $wc) -replace 'key="Umbraco.Core.ConfigurationStatus" value="8.18.8"', 'key="Umbraco.Core.ConfigurationStatus" value="8.17.0"')
        $v = Get-UmbracoVersionInfo -Root $d
        $v.resolved.version | Should -Be '8.18.8'
        $v.resolved.needsConfirmation | Should -BeTrue
        @($v.conflicts | Where-Object { $_.kind -eq 'config-status-differs' }).Count | Should -Be 1
    }

    It 'reports a conflict when projects reference different core versions' {
        $d = Copy-Fixture -Baseline 'gen.v13-multi'; $script:dirs += $d
        $core = Join-Path $d 'src/SampleSite.Core/SampleSite.Core.csproj'
        Set-FileText $core ((Get-Content -Raw $core) -replace '13\.10\.1', '13.9.0')
        $v = Get-UmbracoVersionInfo -Root $d
        $v.resolved.confidence | Should -Be 'conflict'
        $v.resolved.version | Should -BeNullOrEmpty
        $v.resolved.candidates | Should -Be @('13.10.1', '13.9.0')
        $v.resolved.needsConfirmation | Should -BeTrue
        @($v.conflicts | Where-Object { $_.kind -eq 'package-versions-disagree' }).Count | Should -Be 1
    }

    It 'reports a conflict between the project file and the restored assets file' {
        $d = Copy-Fixture -Baseline 'gen.v13'; $script:dirs += $d
        New-Item -ItemType Directory (Join-Path $d 'obj') | Out-Null
        Set-FileText (Join-Path $d 'obj/project.assets.json') '{ "version": 3, "libraries": { "Umbraco.Cms/13.10.2": { "type": "package" }, "Serilog/3.1.1": { "type": "package" } } }'
        $v = Get-UmbracoVersionInfo -Root $d
        $v.resolved.confidence | Should -Be 'conflict'
        @($v.signals | Where-Object { $_.kind -eq 'project.assets.json' -and $_.version -eq '13.10.2' }).Count | Should -Be 1
    }

    It 'resolves a floating reference through packages.lock.json' {
        $d = Copy-Fixture -Baseline 'gen.v13'; $script:dirs += $d
        $proj = Join-Path $d 'SampleSite.Web.csproj'
        Set-FileText $proj ((Get-Content -Raw $proj) -replace 'Version="13\.10\.1"', 'Version="13.*"')
        Set-FileText (Join-Path $d 'packages.lock.json') '{ "version": 1, "dependencies": { "net8.0": { "Umbraco.Cms": { "type": "Direct", "requested": "[13.*, )", "resolved": "13.10.1" } } } }'
        $v = Get-UmbracoVersionInfo -Root $d
        $v.resolved.version | Should -Be '13.10.1'
        $v.resolved.confidence | Should -Be 'high'
    }

    It 'gives low confidence to a floating reference without a lock file' {
        $d = Copy-Fixture -Baseline 'gen.v13'; $script:dirs += $d
        $proj = Join-Path $d 'SampleSite.Web.csproj'
        Set-FileText $proj ((Get-Content -Raw $proj) -replace 'Version="13\.10\.1"', 'Version="13.*"')
        $v = Get-UmbracoVersionInfo -Root $d
        $v.resolved.version | Should -BeNullOrEmpty
        $v.resolved.major | Should -Be 13
        $v.resolved.confidence | Should -Be 'low'
        $v.resolved.needsConfirmation | Should -BeTrue
    }

    It 'reads the version from an old-style project HintPath when packages.config is missing' {
        $d = Copy-Fixture -Baseline 'gen.v8'; $script:dirs += $d
        Remove-Item (Join-Path $d 'packages.config')
        Set-FileText (Join-Path $d 'SampleSite.Web.csproj') @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup><TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion></PropertyGroup>
  <ItemGroup>
    <Reference Include="Umbraco.Core"><HintPath>..\packages\UmbracoCms.Core.8.18.8\lib\net472\Umbraco.Core.dll</HintPath></Reference>
  </ItemGroup>
</Project>
'@
        $v = Get-UmbracoVersionInfo -Root $d
        @($v.signals | Where-Object { $_.kind -eq 'HintPath' -and $_.version -eq '8.18.8' }).Count | Should -Be 1
        $v.resolved.version | Should -Be '8.18.8'
        $v.targetFrameworks | Should -Contain 'net472'
    }

    It 'ignores a zero-byte placeholder assembly without failing' {
        $d = Copy-Fixture -Baseline 'gen.v13'; $script:dirs += $d
        New-Item -ItemType Directory (Join-Path $d 'bin') | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $d 'bin/Umbraco.Cms.Core.dll'), [byte[]]@())
        $v = Get-UmbracoVersionInfo -Root $d
        @($v.errors).Count | Should -Be 0
        $v.resolved.version | Should -Be '13.10.1'
    }

    It 'detects an Umbraco project from configuration alone and asks for the version' {
        $d = New-TestDirectory; $script:dirs += $d
        New-Item -ItemType Directory (Join-Path $d 'config') | Out-Null
        Copy-Item (Join-Path (Get-FixturePath 'gen.v7') 'config/umbracoSettings.config') (Join-Path $d 'config')
        $v = Get-UmbracoVersionInfo -Root $d
        $v.isUmbraco | Should -BeTrue
        $v.resolved.version | Should -BeNullOrEmpty
        $v.resolved.generation | Should -Be 'v7-v8'
        $v.resolved.needsConfirmation | Should -BeTrue
    }
}

Describe 'Database summary from configuration' -Tag 'fixture-based' {
    It '<fixture> uses <engine>, local=<isLocal>' -ForEach @(
        @{ fixture = 'gen.v7'; engine = 'sqlserver'; isLocal = $true }
        @{ fixture = 'gen.v8'; engine = 'sqlserver'; isLocal = $true }
        @{ fixture = 'gen.v8-sqlce'; engine = 'sqlce'; isLocal = $true }
        @{ fixture = 'gen.v10'; engine = 'sqlserver'; isLocal = $true }
        @{ fixture = 'gen.v13'; engine = 'sqlserver'; isLocal = $true }
        @{ fixture = 'gen.v14plus'; engine = 'sqlite'; isLocal = $true }
    ) {
        $s = Get-DatabaseSummary -ProjectDir (Get-FixturePath $fixture)
        $s.Count | Should -BeGreaterThan 0
        $s[0].engine | Should -Be $engine
        $s[0].isLocal | Should -Be $isLocal
        ($s | ConvertTo-Json -Depth 5) | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
    }

    It 'classifies <server> as local=<expected>' -ForEach @(
        @{ server = 'localhost'; expected = $true }, @{ server = '.'; expected = $true }, @{ server = '.\SQLEXPRESS'; expected = $true }
        @{ server = '(localdb)\MSSQLLocalDB'; expected = $true }, @{ server = '127.0.0.1,1433'; expected = $true }, @{ server = 'tcp:localhost,1433'; expected = $true }
        @{ server = '(local)'; expected = $true }, @{ server = 'db.example.invalid'; expected = $false }, @{ server = 'tcp:sql.example.invalid,1433'; expected = $false }
        @{ server = '10.0.0.5'; expected = $false }
    ) {
        (Get-DataSourceInfo -ConnectionString "Server=$server;Database=x").isLocal | Should -Be $expected
    }

    It 'reports a non-local server without printing the connection string' {
        $d = Copy-Fixture -Baseline 'gen.v13'
        try {
            $f = Join-Path $d 'appsettings.json'
            Set-FileText $f ((Get-Content -Raw $f) -replace 'Server=\.\\\\SQLEXPRESS', 'Server=db.example.invalid')
            $s = Get-DatabaseSummary -ProjectDir $d
            $s[0].isLocal | Should -BeFalse
            ($s | ConvertTo-Json -Depth 5) | Should -Not -Match 'db\.example\.invalid|Password'
        } finally { Remove-TestDirectory $d }
    }
}
