# /umbraco-upgrade:feedback: the comparison of the plan with what changed since the base commit, the diff of one
# file, and the check of a public draft for names that identify the project.
# Label: fixture-based (synthetic projects in temporary git repositories with hand-written discovery and package
# check evidence; no network is used).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/State.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Get-RepoRoot) 'scripts/lib/Feedback.psm1') -Force -DisableNameChecking
    $env:GIT_OPTIONAL_LOCKS = '0'

    function Invoke-Git([string]$Dir, [string[]]$GitArgs) { return (& git -C $Dir @GitArgs 2>&1) }

    function Set-TestFile([string]$Dir, [string]$Rel, [string]$Text) {
        $p = Join-Path $Dir $Rel
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($p))
        [System.IO.File]::WriteAllText($p, $Text)
    }

    function Get-ProjectXml([string]$Framework, [string[]]$Packages) {
        $refs = ($Packages | ForEach-Object { $p = $_ -split ' '; "    <PackageReference Include=`"$($p[0])`" Version=`"$($p[1])`" />" }) -join "`n"
        return "<Project Sdk=`"Microsoft.NET.Sdk.Web`">`n  <PropertyGroup>`n    <TargetFramework>$Framework</TargetFramework>`n  </PropertyGroup>`n  <ItemGroup>`n$refs`n  </ItemGroup>`n</Project>`n"
    }

    function New-FeedbackProject {
        # A 13.10.1 project in plan state for 17.7.1: P2 covers render controllers and composers, P3 an AngularJS
        # property editor; discovery also found a surface controller that no phase covers.
        param([string]$ProjectName = 'SampleSite.Web', [switch]$NoEvidence)
        $d = Copy-Fixture -Baseline 'gen.v13'
        Remove-Item -LiteralPath (Join-Path $d 'SampleSite.Web.csproj')
        Set-TestFile $d "$ProjectName.csproj" (Get-ProjectXml 'net8.0' @('Umbraco.Cms 13.10.1', 'Sample.Compatible 1.0.0', 'Sample.NoTarget 2.0.0', 'SampleCorpKit 1.0.0', 'Sample.OldName 1.0.0'))
        Set-TestFile $d 'Controllers/SampleRenderController.cs' '// render controller v1'
        Set-TestFile $d 'Controllers/SampleOldController.cs' "// old controller`n// kept as it is`n// so git sees a rename`n"
        Set-TestFile $d 'Controllers/SampleSurfaceController.cs' '// surface v1'
        Set-TestFile $d 'Code/SampleComposer.cs' '// composer'
        Set-TestFile $d 'Services/SampleMailer.cs' '// mailer v1'
        Set-TestFile $d 'Services/SampleLegacy.cs' '// legacy'
        Set-TestFile $d 'App_Plugins/SampleEditor/package.manifest' '{ "propertyEditors": [] }'
        Set-TestFile $d 'App_Plugins/SampleEditor/editor.js' '// editor v1'
        Set-TestFile $d 'umbraco/models/Home.generated.cs' '// model v1'
        Initialize-GitRepo -Path $d -Commit
        Add-Content -LiteralPath (Join-Path $d '.git/info/exclude') -Value '.umbraco-upgrade/'
        [void](New-UpgradeState -ProjectRoot $d -Mode plan -TargetRequested '17')
        [void](Update-StateSection -ProjectRoot $d -Section source -Values @{ umbraco = '13.10.1'; major = 13; confidence = 'high' })
        [void](Update-StateSection -ProjectRoot $d -Section target -Values @{ resolved = '17.7.1' })
        $phases = @(
            [ordered]@{ id = 'P1'; title = 'Packages, framework, and startup'; area = 'application-framework'; patterns = @(); acceptanceCriteria = @([ordered]@{ id = 'P1-AC1'; text = 'The solution builds'; verification = 'automated' }) },
            [ordered]@{ id = 'P2'; title = 'Custom code'; area = 'custom-code'; patterns = @('code.render-controller', 'api.composition-di'); acceptanceCriteria = @([ordered]@{ id = 'P2-AC1'; text = 'Code ported'; verification = 'manual' }) },
            [ordered]@{ id = 'P3'; title = 'Backoffice'; area = 'packages-backoffice'; patterns = @('backoffice.angular-property-editor'); acceptanceCriteria = @([ordered]@{ id = 'P3-AC1'; text = 'Editors work'; verification = 'manual' }) })
        [void](Set-UpgradePhases -ProjectRoot $d -Phases $phases)
        if ($NoEvidence) { return $d }
        $hit = { param($p, $f) [ordered]@{ pattern = $p; detector = 'test'; weight = 'strong'; file = $f; line = 1; count = 1; snippet = $f } }
        $patterns = [ordered]@{
            hits = @(
                (& $hit 'code.render-controller' 'Controllers/SampleRenderController.cs'),
                (& $hit 'code.render-controller' 'Controllers/SampleOldController.cs'),
                (& $hit 'code.surface-controller' 'Controllers/SampleSurfaceController.cs'),
                (& $hit 'api.composition-di' 'Code/SampleComposer.cs'),
                (& $hit 'backoffice.angular-property-editor' 'App_Plugins/SampleEditor/package.manifest'),
                (& $hit 'content.models-builder' 'umbraco/models/Home.generated.cs'))
            baselineHits = @((& $hit 'config.startup-hosting' 'Program.cs'))
            unclassified = [ordered]@{ pattern = 'code.unclassified-umbraco-usage'; files = @('Views/Home.cshtml') }
        }
        Set-TestFile $d '.umbraco-upgrade/evidence/discovery/patterns.json' (ConvertTo-Json -InputObject $patterns -Depth 8)
        $pkg = { param($id, $v, $c) [ordered]@{ id = $id; version = $v; file = "$ProjectName.csproj"; class = $c } }
        $renamed = & $pkg 'Sample.OldName' '1.0.0' 'renamed'; $renamed['successor'] = 'Sample.NewName'
        $compat = [ordered]@{ packages = @((& $pkg 'Umbraco.Cms' '13.10.1' 'core'), (& $pkg 'Sample.Compatible' '1.0.0' 'compatible'), (& $pkg 'Sample.NoTarget' '2.0.0' 'no-target-version'), (& $pkg 'SampleCorpKit' '1.0.0' 'not-found'), $renamed) }
        Set-TestFile $d '.umbraco-upgrade/evidence/planning/package-compatibility.json' (ConvertTo-Json -InputObject $compat -Depth 8)
        return $d
    }

    function Invoke-SampleUpgrade([string]$Dir, [string]$ProjectName = 'SampleSite.Web') {
        # Committed: a planned controller changed and a planned one renamed, packages moved to 17, models regenerated.
        Set-TestFile $Dir 'Controllers/SampleRenderController.cs' '// render controller v2'
        $null = Invoke-Git $Dir @('mv', 'Controllers/SampleOldController.cs', 'Controllers/SampleNewController.cs')
        Set-TestFile $Dir "$ProjectName.csproj" (Get-ProjectXml 'net10.0' @('Umbraco.Cms 17.7.1', 'Sample.NoTarget 2.0.0', 'SampleCorpKit 1.0.0', 'Sample.Added 3.0.0'))
        Set-TestFile $Dir 'umbraco/models/Home.generated.cs' '// model v2'
        $null = Invoke-Git $Dir @('add', '-A')
        $null = Invoke-Git $Dir @('commit', '-q', '-m', 'upgrade')
        # Not committed: the rest of the work.
        Set-TestFile $Dir 'Controllers/SampleSurfaceController.cs' '// surface v2'
        Set-TestFile $Dir 'Services/SampleMailer.cs' "// mailer v2`n// changed for the target`n"
        Remove-Item -LiteralPath (Join-Path $Dir 'Services/SampleLegacy.cs')
        Set-TestFile $Dir 'App_Plugins/SampleEditor/editor.js' '// editor v2'
        Set-TestFile $Dir 'Views/Home.cshtml' '@* changed *@'
        Set-TestFile $Dir 'Services/SampleNewHelper.cs' '// new'
    }

    function Get-Category($Result, [string]$Path) { return (@($Result.files | Where-Object { $_['path'] -eq $Path }) | Select-Object -First 1)['category'] }
}

Describe 'Comparison of the plan with the changes' -Tag 'fixture-based' {
    BeforeAll {
        $script:dir = New-FeedbackProject
        Invoke-SampleUpgrade $script:dir
        $script:r = Get-UpgradeComparison -Root $script:dir
    }
    AfterAll { Remove-TestDirectory $script:dir }

    It 'sorts each changed file, committed or not, against discovery and the plan' {
        Get-Category $script:r 'Controllers/SampleRenderController.cs' | Should -Be 'planned'
        Get-Category $script:r 'Controllers/SampleNewController.cs' | Should -Be 'planned'
        Get-Category $script:r 'App_Plugins/SampleEditor/editor.js' | Should -Be 'planned'
        Get-Category $script:r 'Controllers/SampleSurfaceController.cs' | Should -Be 'found-not-planned'
        Get-Category $script:r 'SampleSite.Web.csproj' | Should -Be 'expected'
        Get-Category $script:r 'Views/Home.cshtml' | Should -Be 'flagged'
        Get-Category $script:r 'Services/SampleNewHelper.cs' | Should -Be 'added'
        Get-Category $script:r 'Services/SampleMailer.cs' | Should -Be 'not-found'
        Get-Category $script:r 'Services/SampleLegacy.cs' | Should -Be 'not-found'
        Get-Category $script:r 'umbraco/models/Home.generated.cs' | Should -Be 'generated'
    }
    It 'keeps the old path of a renamed file and leaves unchanged files and the state folder out' {
        $renamed = @($script:r.files | Where-Object { $_['path'] -eq 'Controllers/SampleNewController.cs' })[0]
        $renamed['status'] | Should -Be 'renamed'
        $renamed['oldPath'] | Should -Be 'Controllers/SampleOldController.cs'
        @($script:r.files | Where-Object { $_['path'] -in @('Program.cs', 'Code/SampleComposer.cs') }).Count | Should -Be 0
        @($script:r.files | Where-Object { ([string]$_['path']).StartsWith('.umbraco-upgrade') }).Count | Should -Be 0
        $script:r.counts['not-found'] | Should -Be 2
        $script:r.counts['planned'] | Should -Be 3
    }
    It 'groups the candidate misses by folder and extension' {
        $g = @($script:r.notFoundGroups)[0]
        $g['group'] | Should -Be 'Services/*.cs'
        $g['count'] | Should -Be 2
    }
    It 'reports planned patterns none of whose files changed, and found patterns no phase covers' {
        @($script:r.patterns.plannedUnchanged | ForEach-Object { $_['pattern'] }) | Should -Be @('api.composition-di')
        @($script:r.patterns.plannedUnchanged)[0]['phases'] | Should -Be @('P2')
        $script:r.patterns.plannedWithChanges | Should -Be 2
        $surface = @($script:r.patterns.foundNotPlanned | Where-Object { $_['pattern'] -eq 'code.surface-controller' })
        $surface.Count | Should -Be 1
        $surface[0]['changedFiles'] | Should -Be 1
        @($script:r.patterns.foundNotPlanned | Where-Object { $_['pattern'] -eq 'content.models-builder' }).Count | Should -Be 0 -Because 'its only file is a generated model'
    }
    It 'compares the package check with the package references now' {
        $p = @{}; foreach ($i in $script:r.packages.items) { $p[$i['id']] = $i }
        $p['Umbraco.Cms']['outcome'] | Should -Be 'updated'
        $p['Umbraco.Cms']['flag'] | Should -BeNullOrEmpty
        $p['Sample.Compatible']['flag'] | Should -Be 'compatible-but-removed'
        $p['Sample.NoTarget']['flag'] | Should -Be 'no-target-version-but-kept'
        $p['Sample.OldName']['flag'] | Should -Be 'successor-not-used'
        $p['SampleCorpKit']['private'] | Should -BeTrue
        @($script:r.packages.added | ForEach-Object { $_['id'] }) | Should -Be @('Sample.Added')
    }
    It 'reports the version now and the untracked files' {
        $script:r.detectedNow | Should -Be '17.7.1'
        @($script:r.warnings | ForEach-Object { $_['code'] }) | Should -Contain 'untracked-files'
        @($script:r.warnings | ForEach-Object { $_['code'] }) | Should -Not -Contain 'target-not-reached'
    }
}

Describe 'Compare-UpgradeOutcome.ps1' -Tag 'fixture-based' {
    BeforeAll {
        $script:dir = New-FeedbackProject
        Invoke-SampleUpgrade $script:dir
    }
    AfterAll { Remove-TestDirectory $script:dir }

    It 'writes the comparison into the state folder and changes nothing else' {
        $before = (Invoke-Git $script:dir @('status', '--porcelain')) -join "`n"
        $r = Invoke-PluginScript -Script 'scripts/Compare-UpgradeOutcome.ps1' -Arguments @('-ProjectRoot', $script:dir)
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.counts.'not-found' | Should -Be 2
        @($r.Json.packageFlags | ForEach-Object { $_.flag }) | Should -Contain 'compatible-but-removed'
        [System.IO.File]::Exists((Join-Path $script:dir '.umbraco-upgrade/evidence/feedback/comparison.json')) | Should -BeTrue
        ((Invoke-Git $script:dir @('status', '--porcelain')) -join "`n") | Should -Be $before
    }
    It 'shows the diff of one changed file' {
        $r = Invoke-PluginScript -Script 'scripts/Compare-UpgradeOutcome.ps1' -Arguments @('-ProjectRoot', $script:dir, '-ShowDiff', 'Services/SampleMailer.cs')
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.kind | Should -Be 'diff'
        $r.Json.diff | Should -Match 'changed for the target'
    }
    It 'says when a file is new and untracked' {
        $r = Invoke-PluginScript -Script 'scripts/Compare-UpgradeOutcome.ps1' -Arguments @('-ProjectRoot', $script:dir, '-ShowDiff', 'Services/SampleNewHelper.cs')
        $r.Json.kind | Should -Be 'untracked'
    }
    It 'refuses a path outside the project or inside the state folder' -ForEach @('../outside.txt', '.umbraco-upgrade/state.json', 'C:\Windows\win.ini') {
        $r = Invoke-PluginScript -Script 'scripts/Compare-UpgradeOutcome.ps1' -Arguments @('-ProjectRoot', $script:dir, '-ShowDiff', $_)
        $r.ExitCode | Should -Be 1
        $r.Json.ok | Should -BeFalse
    }
}

Describe 'Comparison refusals and warnings' -Tag 'fixture-based' {
    It 'needs the discovery evidence' {
        $d = New-FeedbackProject -NoEvidence
        try {
            $r = Invoke-PluginScript -Script 'scripts/Compare-UpgradeOutcome.ps1' -Arguments @('-ProjectRoot', $d)
            $r.ExitCode | Should -Be 1
            $r.Json.error | Should -Match 'Discovery evidence is missing'
        } finally { Remove-TestDirectory $d }
    }
    It 'needs the base commit in the repository' {
        $d = New-FeedbackProject
        try {
            [void](Update-StateSection -ProjectRoot $d -Section gitBaseline -Values @{ baseCommit = ('a' * 40) })
            { Get-UpgradeComparison -Root $d } | Should -Throw -ExpectedMessage '*not in this repository*'
        } finally { Remove-TestDirectory $d }
    }
    It 'warns when the project is not on the target yet' {
        $d = New-FeedbackProject
        try {
            Set-TestFile $d 'Services/SampleMailer.cs' '// started'
            $r = Get-UpgradeComparison -Root $d
            @($r.warnings | ForEach-Object { $_['code'] }) | Should -Contain 'target-not-reached'
            Get-Category $r 'Services/SampleMailer.cs' | Should -Be 'not-found'
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'Draft check' -Tag 'fixture-based' {
    BeforeAll {
        $script:dir = New-FeedbackProject -ProjectName 'SampleClientCo.Web'
        $null = Invoke-Git $script:dir @('remote', 'add', 'origin', 'https://dev.azure.com/sampleorg/SampleProj/_git/SampleRepo')
        $null = Invoke-Git $script:dir @('config', 'user.name', 'Riley Sampleton')
        $null = Invoke-Git $script:dir @('config', 'user.email', 'riley@sampleclientco.example')
        $found = Get-ProjectIdentityTokens -Root $script:dir
        $script:tokens = @($found | ForEach-Object { [string]$_['token'] })
    }
    AfterAll { Remove-TestDirectory $script:dir }

    It 'derives names from the project, the remote, the author, custom folders, and private packages' {
        foreach ($t in @('SampleClientCo.Web', 'SampleClientCo', 'sampleorg', 'SampleProj', 'SampleRepo', 'Riley', 'Sampleton', 'riley@sampleclientco.example', 'SampleEditor', 'SampleCorpKit')) {
            $script:tokens | Should -Contain $t
        }
    }
    It 'leaves out generic words and placeholder names' {
        foreach ($t in @('Web', 'Sample', 'SampleSite', 'dev.azure.com', '_git', 'example', 'Test User', 'Umbraco.Cms', 'Sample.NoTarget')) {
            $script:tokens | Should -Not -Contain $t
        }
    }
    It 'reports names, emails, hosts, local paths, and secrets without echoing the secret' {
        $draft = @(
            '# Feedback',
            'The SampleClientCo.Web project has a custom mailer.',
            'Contact riley@sampleclientco.example for details.',
            'See https://intranet.sampleclientco.example/wiki for the setup.',
            'The code lives in sampleorg/SampleRepo.',
            'It reads C:\Projects\Site\Web.config at startup.',
            'Server=.;Database=x;User Id=sa;Password=FAKE-SECRET-FOR-TESTS-123',
            'The folder App_Plugins/SampleEditor broke.') -join "`n"
        Set-TestFile $script:dir '.umbraco-upgrade/feedback.md' $draft
        $r = Invoke-PluginScript -Script 'scripts/Test-FeedbackDraft.ps1' -Arguments @('-ProjectRoot', $script:dir)
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.clean | Should -BeFalse
        $kinds = @($r.Json.findings | ForEach-Object { $_.kind } | Sort-Object -Unique)
        foreach ($k in @('project-name', 'email', 'host', 'local-path', 'secret')) { $kinds | Should -Contain $k }
        foreach ($line in 2..8) { @($r.Json.findings | Where-Object { $_.line -eq $line }).Count | Should -BeGreaterThan 0 -Because "line $line" }
        $r.StdOut | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
    }
    It 'passes a generic draft with placeholders, public packages, and official links' {
        $draft = @(
            '# Feedback for the umbraco-upgrade plugin',
            'Plugin version: 0.2.0. Umbraco versions: 13.10.1 to 17.7.1.',
            'Form: Missed or wrong customization',
            'The customization: a surface controller in SampleSite.Web that inherits from a custom base class, for example SampleBaseController.',
            'Where it is: App_Plugins/<folder>/package.manifest, Program.cs, and appsettings.json in a separate class library.',
            'What the plugin reported: code.surface-controller was not reported. A private package also needed a new version.',
            'Packages: Umbraco.Forms (https://www.nuget.org/packages/Umbraco.Forms) on ASP.NET Core with System.Net.Http.',
            'Source: https://docs.umbraco.com/umbraco-cms/17.latest/get-started/upgrading-and-migrating/upgrade-details') -join "`n"
        $file = Join-Path $script:dir '.umbraco-upgrade/clean.md'
        Set-TestFile $script:dir '.umbraco-upgrade/clean.md' $draft
        $r = Invoke-PluginScript -Script 'scripts/Test-FeedbackDraft.ps1' -Arguments @('-ProjectRoot', $script:dir, '-Path', $file)
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.Json.clean | Should -BeTrue -Because ($r.Json.findings | ConvertTo-Json -Depth 4)
    }
    It 'refuses when there is no draft' {
        $r = Invoke-PluginScript -Script 'scripts/Test-FeedbackDraft.ps1' -Arguments @('-ProjectRoot', $script:dir, '-Path', (Join-Path $script:dir 'missing.md'))
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'No draft'
    }
}
