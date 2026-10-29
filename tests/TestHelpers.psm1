# TestHelpers.psm1 - shared helpers for the Pester suites. Synthetic fixtures only.

Set-StrictMode -Version 2.0
$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures'
Import-Module (Join-Path $script:RepoRoot 'scripts/lib/Git.psm1') -DisableNameChecking

function Get-RepoRoot { return $script:RepoRoot }
function Get-FixturePath { param([string]$Id) return (Join-Path (Join-Path $script:FixtureRoot 'gen') $Id) }

function New-TestDirectory {
    param([string]$Prefix = 'uut')
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    [void][System.IO.Directory]::CreateDirectory($dir)
    return $dir
}

function Remove-TestDirectory {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path) -and $Path.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-Fixture {
    # Copies a gen.* baseline, then applies an optional p.* overlay on top. Returns the new directory.
    param([string]$Baseline, [string]$Overlay = '', [string]$Destination = '')
    if (-not $Destination) { $Destination = New-TestDirectory -Prefix 'uufx' }
    Copy-Item -Path (Join-Path (Get-FixturePath $Baseline) '*') -Destination $Destination -Recurse -Force
    if ($Overlay) {
        $src = Join-Path (Join-Path $script:FixtureRoot 'patterns') $Overlay
        Get-ChildItem -LiteralPath $src -Force | Where-Object { $_.Name -ne 'overlay.json' } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
        }
    }
    return $Destination
}

function Get-MockSet {
    # Value for UMBRACO_UPGRADE_HTTP_MOCK: recorded responses from tests/fixtures/mocks/<name>, first match wins.
    param([Parameter(Mandatory)][string[]]$Name)
    return (($Name | ForEach-Object { Join-Path (Join-Path $script:FixtureRoot 'mocks') $_ }) -join ';')
}

function Get-OverlayIds {
    return @(Get-ChildItem -LiteralPath (Join-Path $script:FixtureRoot 'patterns') -Directory | Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-OverlayInfo {
    param([string]$Id)
    return (Get-Content -Raw -LiteralPath (Join-Path (Join-Path (Join-Path $script:FixtureRoot 'patterns') $Id) 'overlay.json') | ConvertFrom-Json)
}

function Initialize-GitRepo {
    param([string]$Path, [switch]$Commit)
    $null = & git -C $Path init -q 2>&1
    $null = & git -C $Path config user.name 'Test User' 2>&1
    $null = & git -C $Path config user.email 'test@example.invalid' 2>&1
    $null = & git -C $Path config core.autocrlf false 2>&1
    $null = & git -C $Path checkout -q -b main 2>&1
    if ($Commit) {
        $null = & git -C $Path add -A 2>&1
        $null = & git -C $Path commit -q -m 'initial' 2>&1
    }
}

function Invoke-PluginScript {
    # Runs a plugin script in a child Windows PowerShell with a clean, controlled environment.
    param(
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Arguments = @(),
        [string]$StdIn = $null,
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{}
    )
    $path = Join-Path $script:RepoRoot $Script
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $path) + $Arguments
    $psi.Arguments = (($all | ForEach-Object { ConvertTo-CommandLineArgument ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($name in @('CLAUDE_PROJECT_DIR', 'CLAUDE_PLUGIN_DATA', 'CLAUDE_PLUGIN_ROOT', 'PSExecutionPolicyPreference', 'ASPNETCORE_ENVIRONMENT', 'DOTNET_ENVIRONMENT', 'ConnectionStrings__umbracoDbDSN', 'UMBRACO_UPGRADE_HTTP_MOCK')) {
        if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) }
    }
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
    # The child's stdin writer takes Console.InputEncoding; make sure it writes no BOM.
    $savedInput = $null
    try { $savedInput = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    try { $p = [System.Diagnostics.Process]::Start($psi) } finally { if ($savedInput) { try { [Console]::InputEncoding = $savedInput } catch { } } }
    if ($null -ne $StdIn) {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StdIn)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    }
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; throw "Script $Script timed out." }
    $p.WaitForExit()
    $stdout = $outTask.Result
    $json = $null
    if ($stdout -and $stdout.Trim().StartsWith('{')) { try { $json = $stdout | ConvertFrom-Json } catch { $json = $null } }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $errTask.Result; Json = $json }
}

function Invoke-Guard {
    # Pipes a PreToolUse payload into the guard hook.
    param([string]$ToolName, [hashtable]$ToolInput, [string]$Cwd, [string]$SessionId = 'test-session', [hashtable]$Environment = @{}, [string]$Event = 'PreToolUse')
    $payload = [ordered]@{ session_id = $SessionId; transcript_path = ''; cwd = $Cwd; permission_mode = 'bypassPermissions'; hook_event_name = $Event; tool_name = $ToolName; tool_input = $ToolInput; tool_use_id = 'toolu_test' }
    $json = ConvertTo-Json -InputObject $payload -Depth 6 -Compress
    return (Invoke-PluginScript -Script 'scripts/hooks/guard.ps1' -StdIn $json -Environment $Environment)
}

function New-ApprovedUpgradeProject {
    # Synthetic project with gates 1 to 3 passed, an approved plan with the given phases, on the upgrade branch.
    # The state folder is excluded locally. With -StartFirstPhase, P1 is in progress.
    param(
        [string]$Baseline = 'gen.v13', [string]$Overlay = '', $Phases = $null, [switch]$StartFirstPhase, [switch]$LocalCopyDeclared,
        [string]$Policy = 'exclude-local'
    )
    Import-Module (Join-Path $script:RepoRoot 'scripts/lib/State.psm1') -DisableNameChecking -Scope Local
    $dir = Copy-Fixture -Baseline $Baseline -Overlay $Overlay
    Initialize-GitRepo -Path $dir -Commit
    $excludeFile = Join-Path $dir '.git/info/exclude'
    Add-Content -LiteralPath $excludeFile -Value '.umbraco-upgrade/'
    [void](New-UpgradeState -ProjectRoot $dir -Mode upgrade -TargetRequested '17')
    [void](Update-StateSection -ProjectRoot $dir -Section project -Values @{ stateFolderPolicy = $Policy; webProject = 'SampleSite.Web.csproj' })
    [void](Set-UpgradeGate -ProjectRoot $dir -Gate discovery -Status passed -Evidence @('evidence/discovery/git-status-at-start.json'))
    [void](Update-StateSection -ProjectRoot $dir -Section source -Values @{ umbraco = '13.10.1'; major = 13; confidence = 'high'; database = @{ engine = 'sqlserver'; localCopyDeclared = [bool]$LocalCopyDeclared; target = 'local' } })
    [void](Update-StateSection -ProjectRoot $dir -Section target -Values @{ resolved = '17.7.1'; dotnet = 'net10.0'; lts = @{ value = $true; source = 'D-001'; verified = $true } })
    [void](Update-StateSection -ProjectRoot $dir -Section path -Values @{ selection = 'selected'; strategy = 'in-place'; decision = 'D-001' })
    [void](Set-UpgradeGate -ProjectRoot $dir -Gate versionPath -Status passed)
    $null = & git -C $dir checkout -q -b 'umbraco-upgrade/13-to-17' 2>&1
    [void](Update-StateSection -ProjectRoot $dir -Section gitBaseline -Values @{ upgradeBranch = 'umbraco-upgrade/13-to-17' })
    [System.IO.File]::WriteAllText((Join-Path $dir '.umbraco-upgrade/rollback.md'), "# Rollback`n")
    [void](Set-GateFields -ProjectRoot $dir -Gate safety -Fields @{ guardSelfTest = 'passed'; rollbackDoc = 'rollback.md' })
    [void](Set-UpgradeGate -ProjectRoot $dir -Gate safety -Status passed -Evidence @('rollback.md'))
    if ($null -eq $Phases) {
        $Phases = @(
            [ordered]@{ id = 'P1'; title = 'Packages, framework, and startup'; area = 'application-framework'; patterns = @(); acceptanceCriteria = @([ordered]@{ id = 'P1-AC1'; text = 'The solution builds'; verification = 'automated' }) },
            [ordered]@{ id = 'P2'; title = 'Custom code'; area = 'custom-code'; patterns = @('code.render-controller'); acceptanceCriteria = @([ordered]@{ id = 'P2-AC1'; text = 'Controllers ported'; verification = 'manual' }) })
    }
    [void](Set-UpgradePhases -ProjectRoot $dir -Phases $Phases)
    [System.IO.File]::WriteAllText((Join-Path $dir '.umbraco-upgrade/plan.md'), "# Upgrade plan`n`nSynthetic plan for tests.`n")
    [void](Request-PlanApproval -ProjectRoot $dir)
    [void](Add-Approval -ProjectRoot $dir -Action 'start-plan-execution' -Decision approved -Note 'approve')
    if ($StartFirstPhase) { [void](Set-PhaseStatus -ProjectRoot $dir -PhaseId 'P1' -Status in-progress) }
    return $dir
}

function New-UpgradeProject {
    # Synthetic upgrade project: a gen.* copy in a git repo with initialized state.
    param([string]$Baseline = 'gen.v13', [ValidateSet('upgrade', 'plan')][string]$Mode = 'upgrade', [string]$Target = '17')
    $dir = Copy-Fixture -Baseline $Baseline
    Initialize-GitRepo -Path $dir -Commit
    $r = Invoke-PluginScript -Script 'scripts/state.ps1' -Arguments @('init', '-ProjectRoot', $dir, '-Mode', $Mode, '-Target', $Target)
    if ($r.ExitCode -ne 0) { throw "state init failed: $($r.StdOut) $($r.StdErr)" }
    return $dir
}

Export-ModuleMember -Function *
