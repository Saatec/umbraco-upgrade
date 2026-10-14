# PreToolUse guard: every rule blocks its positive cases (including wrapped forms), near-misses pass,
# the guard is inactive outside upgrade projects, active through the session marker and named
# directories, fails closed on internal errors inside scope, and recognizes the canary.
# Label: fixture-based (JSON payloads piped to the hook; synthetic upgrade projects).

BeforeDiscovery {
    $script:DenyCases = @(
        # git.force-push
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git push --force origin main' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git push -f' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git push --force-with-lease origin main' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git push --force-if-includes origin main' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git push --mirror backup' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git push origin +main' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git push -uf origin main' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git -c core.editor=true push -f' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git status && git push --force' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git fetch; git push -f' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'false || git push -f' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'git log | head; git push -f' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = '(git push -f)' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'echo $(git push --force)' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'echo `git push --force`' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'GIT_TRACE=1 git push -f' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'sudo git push -f' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'bash -c "git push --force"' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = "sh -lc 'git push -f origin main'" }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'powershell -NoProfile -Command "git push --force"' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = 'cmd /c git push -f' }
        @{ rule = 'git.force-push'; tool = 'Bash'; cmd = '"/c/Program Files/Git/cmd/git.exe" push -f' }
        @{ rule = 'git.force-push'; tool = 'PowerShell'; cmd = 'git push --force' }
        @{ rule = 'git.force-push'; tool = 'PowerShell'; cmd = '& git push --force origin main' }
        @{ rule = 'git.force-push'; tool = 'PowerShell'; cmd = '& "C:\Program Files\Git\cmd\git.exe" push -f' }
        @{ rule = 'git.force-push'; tool = 'PowerShell'; cmd = 'Invoke-Expression "git push -f"' }
        @{ rule = 'git.force-push'; tool = 'PowerShell'; cmd = 'iex ''git push --force''' }
        @{ rule = 'git.force-push'; tool = 'PowerShell'; cmd = 'Start-Process git -ArgumentList "push --force"' }
        @{ rule = 'git.force-push'; tool = 'PowerShell'; cmd = 'pwsh -c "git push -f"' }
        @{ rule = 'git.force-push'; tool = 'PowerShell'; cmd = 'if ($true) { git push -f }' }
        # git.rewrite-history
        @{ rule = 'git.rewrite-history'; tool = 'Bash'; cmd = 'git rebase main' }
        @{ rule = 'git.rewrite-history'; tool = 'Bash'; cmd = 'git rebase -i HEAD~3' }
        @{ rule = 'git.rewrite-history'; tool = 'Bash'; cmd = 'git pull --rebase origin main' }
        @{ rule = 'git.rewrite-history'; tool = 'Bash'; cmd = 'git filter-branch --tree-filter true HEAD' }
        @{ rule = 'git.rewrite-history'; tool = 'Bash'; cmd = 'git filter-repo --path src' }
        @{ rule = 'git.rewrite-history'; tool = 'Bash'; cmd = 'git replace HEAD HEAD~1' }
        @{ rule = 'git.rewrite-history'; tool = 'Bash'; cmd = 'git update-ref -d refs/heads/feature' }
        @{ rule = 'git.rewrite-history'; tool = 'PowerShell'; cmd = 'git rebase --onto main feature' }
        # git.delete-branch
        @{ rule = 'git.delete-branch'; tool = 'Bash'; cmd = 'git branch -D feature' }
        @{ rule = 'git.delete-branch'; tool = 'Bash'; cmd = 'git branch -d feature' }
        @{ rule = 'git.delete-branch'; tool = 'Bash'; cmd = 'git branch --delete feature' }
        @{ rule = 'git.delete-branch'; tool = 'Bash'; cmd = 'git push origin --delete feature' }
        @{ rule = 'git.delete-branch'; tool = 'Bash'; cmd = 'git push origin :feature' }
        @{ rule = 'git.delete-branch'; tool = 'PowerShell'; cmd = 'git branch -D feature' }
        # git.discard-changes
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git reset --hard' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git reset --hard HEAD~1' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git clean -fd' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git clean -xdf' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git stash drop' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git stash clear' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git restore Program.cs' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git restore --staged --worktree Program.cs' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git switch -f main' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git switch --discard-changes main' }
        @{ rule = 'git.discard-changes'; tool = 'Bash'; cmd = 'git checkout -f main' }
        @{ rule = 'git.discard-changes'; tool = 'PowerShell'; cmd = 'git reset --hard; git status' }
        # db.non-local
        @{ rule = 'db.non-local'; tool = 'Bash'; cmd = 'sqlcmd -S db.example.invalid -Q "select 1"' }
        @{ rule = 'db.non-local'; tool = 'Bash'; cmd = 'osql -S sql.example.invalid -E' }
        @{ rule = 'db.non-local'; tool = 'PowerShell'; cmd = 'Invoke-Sqlcmd -ServerInstance db.example.invalid -Query "select 1"' }
        @{ rule = 'db.non-local'; tool = 'Bash'; cmd = 'sqlpackage /Action:Publish /TargetServerName:db.example.invalid /SourceFile:x.dacpac' }
        @{ rule = 'db.non-local'; tool = 'Bash'; cmd = 'dotnet ef database update --connection "Server=db.example.invalid;Database=x;"' }
        @{ rule = 'db.non-local'; tool = 'Bash'; cmd = 'myimporter --cs "Server=10.1.2.3;Database=x;"' }
        # deploy.any
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'msdeploy -verb:sync -source:contentPath=out' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'az webapp deploy --name site --src-path out.zip' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'az webapp up --name site' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'kubectl apply -f deploy.yaml' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'helm upgrade site ./chart' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'func azure functionapp publish site' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'docker push registry.example.invalid/site:1' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'terraform apply -auto-approve' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'scp -r out user@host.example.invalid:/var/www' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'rsync -av out/ host.example.invalid:/var/www' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'curl -T site.zip ftp://host.example.invalid/' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'dotnet publish -p:PublishProfile=Production' }
        @{ rule = 'deploy.any'; tool = 'Bash'; cmd = 'dotnet publish /p:WebPublishMethod=MSDeploy' }
        @{ rule = 'deploy.any'; tool = 'PowerShell'; cmd = 'Publish-AzWebApp -ResourceGroupName rg -Name site -ArchivePath out.zip' }
        # secrets.print
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'env' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'printenv' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'export -p' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'set' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'env | sort' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = 'Get-ChildItem env:' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = 'gci Env:\' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = 'dir env:' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = '[Environment]::GetEnvironmentVariables()' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'cat appsettings.json' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'type web.config' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'head -n 20 .env' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'tail secrets.json' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'grep -i password appsettings.Development.json' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'grep -ri password --include=*.config .' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'grep password < appsettings.json' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'sed -n 1,20p web.config' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'jq . appsettings.json' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'findstr /i password web.config' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'cat Properties/PublishProfiles/Prod.pubxml' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = 'Get-Content .\appsettings.json' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = 'gc appsettings.Production.json' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = 'Get-Content -Path web.config | Select-Object -First 5' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = 'Select-String -Path web.config -Pattern password' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'dotnet user-secrets list' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'az webapp config appsettings list --name site' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'az keyvault secret show --vault-name v --name n' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'az storage account show-connection-string --name acct' }
        @{ rule = 'secrets.print'; tool = 'PowerShell'; cmd = 'Get-AzKeyVaultSecret -VaultName v -Name n -AsPlainText' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'kubectl get secret site -o yaml' }
        @{ rule = 'secrets.print'; tool = 'Bash'; cmd = 'aws secretsmanager get-secret-value --secret-id site' }
        # shell.encoded-command
        @{ rule = 'shell.encoded-command'; tool = 'Bash'; cmd = 'powershell -EncodedCommand ZQBjAGgAbwA=' }
        @{ rule = 'shell.encoded-command'; tool = 'PowerShell'; cmd = 'pwsh -enc ZQBjAGgAbwA=' }
        @{ rule = 'shell.encoded-command'; tool = 'PowerShell'; cmd = 'powershell -NoProfile -e ZQBjAGgAbwA=' }
    )
    $script:AskCases = @(
        @{ rule = 'approval.git-push'; tool = 'Bash'; cmd = 'git push origin main' }
        @{ rule = 'approval.git-push'; tool = 'Bash'; cmd = 'git push' }
        @{ rule = 'approval.git-push'; tool = 'PowerShell'; cmd = 'git push -u origin umbraco-upgrade/13-to-17' }
        @{ rule = 'approval.package-removal'; tool = 'Bash'; cmd = 'dotnet remove package Some.Package' }
        @{ rule = 'approval.package-removal'; tool = 'Bash'; cmd = 'dotnet remove SampleSite.Web.csproj package Some.Package' }
        @{ rule = 'approval.package-removal'; tool = 'Bash'; cmd = 'dotnet package remove Some.Package' }
        @{ rule = 'approval.package-removal'; tool = 'PowerShell'; cmd = 'Uninstall-Package Some.Package' }
        @{ rule = 'approval.site-start'; tool = 'Bash'; cmd = 'dotnet run' }
        @{ rule = 'approval.site-start'; tool = 'Bash'; cmd = 'dotnet watch run' }
        @{ rule = 'approval.db-migration'; tool = 'Bash'; cmd = 'dotnet ef database update' }
    )
    $script:AllowCases = @(
        @{ tool = 'Bash'; cmd = 'git status' }
        @{ tool = 'Bash'; cmd = 'git log --oneline -5' }
        @{ tool = 'Bash'; cmd = 'git branch --list' }
        @{ tool = 'Bash'; cmd = 'git branch -a' }
        @{ tool = 'Bash'; cmd = 'git diff HEAD' }
        @{ tool = 'Bash'; cmd = 'git fetch origin' }
        @{ tool = 'Bash'; cmd = 'git checkout -b feature' }
        @{ tool = 'Bash'; cmd = 'git switch -c feature' }
        @{ tool = 'Bash'; cmd = 'git stash list' }
        @{ tool = 'Bash'; cmd = 'git clean -n' }
        @{ tool = 'Bash'; cmd = 'git clean -fdn' }
        @{ tool = 'Bash'; cmd = 'git restore --staged Program.cs' }
        @{ tool = 'Bash'; cmd = 'git reset HEAD Program.cs' }
        @{ tool = 'Bash'; cmd = 'git commit -m "checkpoint"' }
        @{ tool = 'Bash'; cmd = 'git replace -l' }
        @{ tool = 'Bash'; cmd = 'echo "git push --force"' }
        @{ tool = 'Bash'; cmd = 'grep -rn "git push -f" docs' }
        @{ tool = 'Bash'; cmd = 'cat Program.cs' }
        @{ tool = 'Bash'; cmd = 'cat packages.config' }
        @{ tool = 'Bash'; cmd = 'printenv HOME' }
        @{ tool = 'Bash'; cmd = 'env DOTNET_CLI_TELEMETRY_OPTOUT=1 dotnet build' }
        @{ tool = 'Bash'; cmd = 'dotnet build' }
        @{ tool = 'Bash'; cmd = 'dotnet publish -c Release -o out' }
        @{ tool = 'Bash'; cmd = 'sqlcmd -S localhost -Q "select 1"' }
        @{ tool = 'Bash'; cmd = 'sqlcmd -S "(localdb)\MSSQLLocalDB" -Q "select 1"' }
        @{ tool = 'Bash'; cmd = 'sqlcmd -Q "select 1"' }
        @{ tool = 'Bash'; cmd = 'az webapp list' }
        @{ tool = 'Bash'; cmd = 'kubectl get pods' }
        @{ tool = 'Bash'; cmd = 'docker build -t site .' }
        @{ tool = 'Bash'; cmd = 'rsync -av src/ backup/' }
        @{ tool = 'Bash'; cmd = 'grep -c "Server=" notes.txt' }
        @{ tool = 'Bash'; cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "C:/plugin/scripts/state.ps1" get' }
        @{ tool = 'PowerShell'; cmd = 'Get-ChildItem .' }
        @{ tool = 'PowerShell'; cmd = 'Get-Content Program.cs' }
        @{ tool = 'PowerShell'; cmd = '$env:PATH' }
        @{ tool = 'PowerShell'; cmd = 'Invoke-Sqlcmd -Query "select 1"' }
        @{ tool = 'PowerShell'; cmd = 'Write-Output "git reset --hard"' }
    )
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    $script:proj = New-UpgradeProject -Baseline 'gen.v13'
    # A remote that holds main, so amend-of-pushed can be tested.
    $script:remote = New-TestDirectory -Prefix 'uurem'
    $null = & git -C $script:remote init -q --bare 2>&1
    $null = & git -C $script:proj remote add origin $script:remote 2>&1
    $null = & git -C $script:proj push -q origin main 2>&1
    $script:outside = New-TestDirectory -Prefix 'uuout'
    $script:siblingParent = New-TestDirectory -Prefix 'uusib'
    $script:sibProj = Join-Path $script:siblingParent 'project'
    [void](New-Item -ItemType Directory $script:sibProj)
    Copy-Fixture -Baseline 'gen.v13' -Destination $script:sibProj | Out-Null
    Initialize-GitRepo -Path $script:sibProj -Commit
    [void](Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('init', '-ProjectRoot', $script:sibProj, '-Mode', 'upgrade', '-Target', '17'))
    $script:sibling = Join-Path $script:siblingParent 'sibling'
    [void](New-Item -ItemType Directory $script:sibling)

    function Set-StateField([string]$Dir, [scriptblock]$Change) {
        $p = Join-Path $Dir '.umbraco-upgrade/state.json'
        $s = Get-Content -Raw $p | ConvertFrom-Json
        & $Change $s
        [System.IO.File]::WriteAllText($p, ($s | ConvertTo-Json -Depth 20))
    }
}

AfterAll {
    foreach ($d in @($script:proj, $script:remote, $script:outside, $script:siblingParent)) { Remove-TestDirectory $d }
}

Describe 'Guard blocks prohibited operations in an upgrade project' -Tag 'fixture-based' {
    It '[<rule>] <tool>: <cmd>' -ForEach $script:DenyCases {
        $r = Invoke-Guard -ToolName $tool -ToolInput @{ command = $cmd } -Cwd $script:proj
        $r.ExitCode | Should -Be 2
        $r.StdErr | Should -Match ([regex]::Escape("umbraco-upgrade guard [$rule]"))
    }
}

Describe 'Guard asks for approval-tier operations' -Tag 'fixture-based' {
    It '[<rule>] <tool>: <cmd>' -ForEach $script:AskCases {
        $r = Invoke-Guard -ToolName $tool -ToolInput @{ command = $cmd } -Cwd $script:proj
        $r.ExitCode | Should -Be 0
        $j = $r.StdOut | ConvertFrom-Json
        $j.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
        $j.hookSpecificOutput.permissionDecision | Should -Be 'ask'
        $j.hookSpecificOutput.permissionDecisionReason | Should -Match ([regex]::Escape("[$rule]"))
    }
}

Describe 'Guard lets near-misses through' -Tag 'fixture-based' {
    It '<tool>: <cmd>' -ForEach $script:AllowCases {
        $r = Invoke-Guard -ToolName $tool -ToolInput @{ command = $cmd } -Cwd $script:proj
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeNullOrEmpty
    }
}

Describe 'Guard context-dependent git rules' -Tag 'fixture-based' {
    It 'blocks amending a commit that exists on a remote' {
        $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git commit --amend -m x' } -Cwd $script:proj
        $r.ExitCode | Should -Be 2
        $r.StdErr | Should -Match 'git.rewrite-history'
    }
    It 'allows amending a local-only commit' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git commit --amend -m x' } -Cwd $d
            $r.ExitCode | Should -Be 0
        } finally { Remove-TestDirectory $d }
    }
    It 'blocks checkout of paths and reset --keep only when there are local changes' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            foreach ($c in @('git checkout -- Program.cs', 'git checkout .', 'git reset --keep HEAD')) {
                (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = $c } -Cwd $d).ExitCode | Should -Be 0
            }
            Add-Content -LiteralPath (Join-Path $d 'Program.cs') -Value '// change'
            foreach ($c in @('git checkout -- Program.cs', 'git checkout .', 'git checkout Program.cs', 'git reset --keep HEAD')) {
                $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = $c } -Cwd $d
                $r.ExitCode | Should -Be 2
                $r.StdErr | Should -Match 'git.discard-changes'
            }
        } finally { Remove-TestDirectory $d }
    }
    It 'resolves git aliases' {
        $null = & git -C $script:proj config alias.yolo 'push --force' 2>&1
        $null = & git -C $script:proj config alias.shout '!git push -f' 2>&1
        try {
            (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git yolo' } -Cwd $script:proj).ExitCode | Should -Be 2
            (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git shout' } -Cwd $script:proj).ExitCode | Should -Be 2
        } finally {
            $null = & git -C $script:proj config --unset alias.yolo 2>&1
            $null = & git -C $script:proj config --unset alias.shout 2>&1
        }
    }
    It 'blocks a pull that rebases through configuration' {
        $null = & git -C $script:proj config pull.rebase true 2>&1
        try { (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git pull' } -Cwd $script:proj).ExitCode | Should -Be 2 }
        finally { $null = & git -C $script:proj config --unset pull.rebase 2>&1 }
    }
}

Describe 'Guard database and publish rules that read project configuration' -Tag 'fixture-based' {
    It 'blocks starting the site against a non-local database' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $f = Join-Path $d 'appsettings.json'
            [System.IO.File]::WriteAllText($f, ((Get-Content -Raw $f) -replace 'Server=\.\\\\SQLEXPRESS', 'Server=db.example.invalid'))
            foreach ($c in @('dotnet run', 'dotnet watch', 'dotnet ef database update')) {
                $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = $c } -Cwd $d
                $r.ExitCode | Should -Be 2
                $r.StdErr | Should -Match 'db.non-local'
                $r.StdErr | Should -Not -Match 'db\.example\.invalid|FAKE-SECRET'
            }
        } finally { Remove-TestDirectory $d }
    }
    It 'blocks a non-local database set through an environment variable' {
        $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'dotnet run' } -Cwd $script:proj -Environment @{ 'ConnectionStrings__umbracoDbDSN' = 'Server=db.example.invalid;Database=x' }
        $r.ExitCode | Should -Be 2
    }
    It 'allows starting the site on a local database once db-migration-local is approved' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            [void](Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('approve', '-ProjectRoot', $d, '-Action', 'db-migration-local', '-Decision', 'approved', '-Scope', 'declared local copy'))
            (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'dotnet run' } -Cwd $d).ExitCode | Should -Be 0
            (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'dotnet run' } -Cwd $d).StdOut | Should -BeNullOrEmpty
        } finally { Remove-TestDirectory $d }
    }
    It 'allows publishing with a file system profile and blocks a web deploy profile' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $pp = Join-Path $d 'Properties/PublishProfiles'
            [void](New-Item -ItemType Directory $pp -Force)
            [System.IO.File]::WriteAllText((Join-Path $pp 'FolderProfile.pubxml'), '<Project><PropertyGroup><WebPublishMethod>FileSystem</WebPublishMethod><PublishUrl>bin\publish</PublishUrl></PropertyGroup></Project>')
            [System.IO.File]::WriteAllText((Join-Path $pp 'Remote.pubxml'), '<Project><PropertyGroup><WebPublishMethod>MSDeploy</WebPublishMethod></PropertyGroup></Project>')
            (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'dotnet publish -p:PublishProfile=FolderProfile' } -Cwd $d).ExitCode | Should -Be 0
            $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'dotnet publish -p:PublishProfile=Remote' } -Cwd $d
            $r.ExitCode | Should -Be 2
            $r.StdErr | Should -Match 'deploy.any'
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'Guard on file tools' -Tag 'fixture-based' {
    It 'blocks direct writes to state.json' {
        foreach ($tool in @('Write', 'Edit')) {
            $r = Invoke-Guard -ToolName $tool -ToolInput @{ file_path = (Join-Path $script:proj '.umbraco-upgrade\state.json'); content = '{}'; old_string = 'a'; new_string = 'b' } -Cwd $script:proj
            $r.ExitCode | Should -Be 2
            $r.StdErr | Should -Match 'state.direct-write'
        }
    }
    It 'allows plan files and blocks secret values in the state folder' {
        $p = Join-Path $script:proj '.umbraco-upgrade\plan.md'
        (Invoke-Guard -ToolName 'Write' -ToolInput @{ file_path = $p; content = "# Plan`n" } -Cwd $script:proj).ExitCode | Should -Be 0
        $r = Invoke-Guard -ToolName 'Write' -ToolInput @{ file_path = $p; content = "Server=.;Password=FAKE-SECRET-FOR-TESTS-guard" } -Cwd $script:proj
        $r.ExitCode | Should -Be 2
        $r.StdErr | Should -Match 'state.secret-write'
        $r.StdErr | Should -Not -Match 'FAKE-SECRET-FOR-TESTS'
    }
    It 'blocks project file changes before gate 3 and plan approval' {
        $r = Invoke-Guard -ToolName 'Edit' -ToolInput @{ file_path = (Join-Path $script:proj 'Program.cs'); old_string = 'a'; new_string = 'b' } -Cwd $script:proj
        $r.ExitCode | Should -Be 2
        $r.StdErr | Should -Match 'project.write-before-approval'
    }
    It 'blocks project file changes in plan mode' {
        $d = New-UpgradeProject -Baseline 'gen.v13' -Mode plan
        try {
            $r = Invoke-Guard -ToolName 'Write' -ToolInput @{ file_path = (Join-Path $d 'Program.cs'); content = 'x' } -Cwd $d
            $r.ExitCode | Should -Be 2
            $r.StdErr | Should -Match 'project.plan-mode-write'
        } finally { Remove-TestDirectory $d }
    }
    It 'after approval allows edits on the upgrade branch, asks for CI files, and blocks other branches' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            Set-StateField $d {
                param($s)
                $s.gates.safety.status = 'passed'; $s.gates.planApproval.status = 'approved'; $s.gates.planApproval | Add-Member approval 'A-001' -Force
                $s.gitBaseline.upgradeBranch = 'main'
            }
            (Invoke-Guard -ToolName 'Edit' -ToolInput @{ file_path = (Join-Path $d 'Program.cs'); old_string = 'a'; new_string = 'b' } -Cwd $d).ExitCode | Should -Be 0
            $r = Invoke-Guard -ToolName 'Write' -ToolInput @{ file_path = (Join-Path $d '.github\workflows\ci.yml'); content = 'on: push' } -Cwd $d
            $r.ExitCode | Should -Be 0
            ($r.StdOut | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'ask'
            Set-StateField $d { param($s) $s.gitBaseline.upgradeBranch = 'umbraco-upgrade/13-to-17' }
            $r = Invoke-Guard -ToolName 'Edit' -ToolInput @{ file_path = (Join-Path $d 'Program.cs'); old_string = 'a'; new_string = 'b' } -Cwd $d
            $r.ExitCode | Should -Be 2
            $r.StdErr | Should -Match 'project.write-off-branch'
        } finally { Remove-TestDirectory $d }
    }
    It 'asks before writing outside the project and allows the scratchpad' {
        $r = Invoke-Guard -ToolName 'Write' -ToolInput @{ file_path = (Join-Path $script:outside 'notes.txt'); content = 'x' } -Cwd $script:proj
        ($r.StdOut | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'ask'
        $payload = @{ session_id = 's'; cwd = $script:proj; scratchpad_dir = $script:outside; hook_event_name = 'PreToolUse'; tool_name = 'Write'; tool_input = @{ file_path = (Join-Path $script:outside 'notes.txt'); content = 'x' } } | ConvertTo-Json -Compress
        $r2 = Invoke-PluginScript -Script 'scripts/hooks/guard.ps1' -StdIn $payload
        $r2.ExitCode | Should -Be 0
        $r2.StdOut | Should -BeNullOrEmpty
    }
}

Describe 'Guard on database MCP tools' -Tag 'fixture-based' {
    It 'blocks without a declared local copy and asks with one' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $r = Invoke-Guard -ToolName 'mcp__dbserver__sql_query' -ToolInput @{ query = 'select 1' } -Cwd $d
            $r.ExitCode | Should -Be 2
            $r.StdErr | Should -Match 'mcp.database'
            [void](Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('set', '-ProjectRoot', $d, '-Section', 'source', '-Set', 'database.localCopyDeclared=true'))
            $r = Invoke-Guard -ToolName 'mcp__dbserver__sql_query' -ToolInput @{ query = 'select 1' } -Cwd $d
            ($r.StdOut | ConvertFrom-Json).hookSpecificOutput.permissionDecision | Should -Be 'ask'
        } finally { Remove-TestDirectory $d }
    }
}

Describe 'Guard is inactive outside upgrade projects' -Tag 'fixture-based' {
    It 'outside: [<rule>] <tool>: <cmd>' -ForEach $script:DenyCases {
        $r = Invoke-Guard -ToolName $tool -ToolInput @{ command = $cmd } -Cwd $script:outside
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeNullOrEmpty
        $r.StdErr | Should -BeNullOrEmpty
    }
    It 'sibling: [<rule>] <tool>: <cmd>' -ForEach $script:DenyCases {
        $r = Invoke-Guard -ToolName $tool -ToolInput @{ command = $cmd } -Cwd $script:sibling
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeNullOrEmpty
    }
    It 'outside: ask cases stay silent (<cmd>)' -ForEach $script:AskCases {
        $r = Invoke-Guard -ToolName $tool -ToolInput @{ command = $cmd } -Cwd $script:outside
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeNullOrEmpty
    }
    It 'outside: file writes and MCP tools stay silent' {
        (Invoke-Guard -ToolName 'Write' -ToolInput @{ file_path = (Join-Path $script:outside 'state.json'); content = 'Password=FAKE-SECRET-FOR-TESTS-x' } -Cwd $script:outside).ExitCode | Should -Be 0
        (Invoke-Guard -ToolName 'mcp__dbserver__sql_query' -ToolInput @{ query = 'x' } -Cwd $script:outside).ExitCode | Should -Be 0
    }
    It 'outside: unreadable hook input does not block' {
        $r = Invoke-PluginScript -Script 'scripts/hooks/guard.ps1' -StdIn 'not json' -WorkingDirectory $script:outside
        $r.ExitCode | Should -Be 0
    }
}

Describe 'Guard scoping' -Tag 'fixture-based' {
    It 'is active from a subdirectory of an upgrade project' {
        $sub = Join-Path $script:proj 'Views'
        (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git push -f' } -Cwd $sub).ExitCode | Should -Be 2
    }
    It 'is active through CLAUDE_PROJECT_DIR' {
        (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git push -f' } -Cwd $script:outside -Environment @{ CLAUDE_PROJECT_DIR = $script:proj }).ExitCode | Should -Be 2
    }
    It 'is active through the session marker when the session directory differs' {
        $data = New-TestDirectory
        try {
            [void](Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('session-marker', '-ProjectRoot', $script:proj, '-SessionId', 'sess-1', '-DataDir', $data))
            (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git push -f' } -Cwd $script:outside -SessionId 'sess-1' -Environment @{ CLAUDE_PLUGIN_DATA = $data }).ExitCode | Should -Be 2
            (Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git push -f' } -Cwd $script:outside -SessionId 'sess-2' -Environment @{ CLAUDE_PLUGIN_DATA = $data }).ExitCode | Should -Be 0
        } finally { Remove-TestDirectory $data }
    }
    It 'is active when the command names the project directory (<cmd>)' -ForEach @(
        @{ tool = 'Bash'; cmd = 'cd "{0}" && git push -f' }
        @{ tool = 'Bash'; cmd = 'git -C "{0}" push --force' }
        @{ tool = 'PowerShell'; cmd = 'Set-Location "{0}"; git push -f' }
        @{ tool = 'PowerShell'; cmd = 'Push-Location -Path "{0}"; git reset --hard' }
    ) {
        $c = $cmd -f $script:proj
        (Invoke-Guard -ToolName $tool -ToolInput @{ command = $c } -Cwd $script:outside).ExitCode | Should -Be 2
    }
    It 'is active for a file path inside an upgrade project from outside' {
        (Invoke-Guard -ToolName 'Write' -ToolInput @{ file_path = (Join-Path $script:proj '.umbraco-upgrade\state.json'); content = '{}' } -Cwd $script:outside).ExitCode | Should -Be 2
    }
}

Describe 'Guard failure behavior' -Tag 'fixture-based' {
    It 'blocks when its own processing fails inside an upgrade project' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            [System.IO.File]::WriteAllText((Join-Path $d '.umbraco-upgrade/state.json'), '{ not valid json')
            $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git status' } -Cwd $d
            $r.ExitCode | Should -Be 2
            $r.StdErr | Should -Match 'guard error, blocking'
        } finally { Remove-TestDirectory $d }
    }
    It 'blocks unreadable hook input inside an upgrade project' {
        $r = Invoke-PluginScript -Script 'scripts/hooks/guard.ps1' -StdIn 'not json' -Environment @{ CLAUDE_PROJECT_DIR = $script:proj }
        $r.ExitCode | Should -Be 2
    }
}

Describe 'Guard canary and self-test' -Tag 'fixture-based' {
    It 'recognizes the canary and records evidence that Test-Guard verifies' {
        $d = New-UpgradeProject -Baseline 'gen.v13'
        try {
            $issue = Invoke-PluginScript -Script 'scripts/Test-Guard.ps1' -Arguments @('-ProjectRoot', $d, '-Issue')
            $issue.ExitCode | Should -Be 0
            $issue.Json.command | Should -Match '^git push --force --dry-run __umbraco_upgrade_guard_canary__[0-9a-f]{16}$'
            $verify0 = Invoke-PluginScript -Script 'scripts/Test-Guard.ps1' -Arguments @('-ProjectRoot', $d, '-Verify')
            $verify0.ExitCode | Should -Be 1
            $verify0.Json.guardSelfTest | Should -Be 'failed'
            $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = $issue.Json.command } -Cwd $d
            $r.ExitCode | Should -Be 2
            $r.StdErr | Should -Match 'guard.canary'
            $verify = Invoke-PluginScript -Script 'scripts/Test-Guard.ps1' -Arguments @('-ProjectRoot', $d, '-Verify')
            $verify.ExitCode | Should -Be 0
            $verify.Json.guardSelfTest | Should -Be 'passed'
        } finally { Remove-TestDirectory $d }
    }
    It 'does not record canary evidence outside upgrade projects' {
        $r = Invoke-Guard -ToolName 'Bash' -ToolInput @{ command = 'git push --force --dry-run __umbraco_upgrade_guard_canary__0123456789abcdef' } -Cwd $script:outside
        $r.ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:outside -Recurse -Force).Count | Should -Be 0
    }
}

Describe 'Session context hook' -Tag 'fixture-based' {
    It 'adds a note in an upgrade project and stays silent elsewhere' {
        $payload = @{ session_id = 's'; cwd = $script:proj; hook_event_name = 'SessionStart'; source = 'startup' } | ConvertTo-Json -Compress
        $r = Invoke-PluginScript -Script 'scripts/hooks/session-context.ps1' -StdIn $payload
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match 'umbraco-upgrade safety hooks are active'
        $payload2 = @{ session_id = 's'; cwd = $script:outside; hook_event_name = 'SessionStart'; source = 'startup' } | ConvertTo-Json -Compress
        $r2 = Invoke-PluginScript -Script 'scripts/hooks/session-context.ps1' -StdIn $payload2
        $r2.ExitCode | Should -Be 0
        $r2.StdOut | Should -BeNullOrEmpty
    }
}

Describe 'hooks.json' -Tag 'fixture-based' {
    It 'uses exec form with -File, onFailure block on the guard, and plugin-root paths' {
        $h = Get-Content -Raw (Join-Path (Get-RepoRoot) 'hooks/hooks.json') | ConvertFrom-Json
        foreach ($group in @($h.hooks.PreToolUse)) {
            foreach ($hk in $group.hooks) {
                $hk.command | Should -Be 'powershell'
                $hk.args | Should -Contain '-File'
                $hk.args | Should -Contain '-NoProfile'
                ($hk.args -join ' ') | Should -Match ([regex]::Escape('${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard.ps1'))
                $hk.onFailure | Should -Be 'block'
            }
        }
        @($h.hooks.PreToolUse | ForEach-Object { $_.matcher }) | Should -Contain 'Bash|PowerShell'
        @($h.hooks.PostToolUse.hooks | ForEach-Object { $_.if }) | Should -Contain 'Read(//**/appsettings*.json)'
    }
}
