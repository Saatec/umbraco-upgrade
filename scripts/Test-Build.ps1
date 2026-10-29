<#
.SYNOPSIS
  Builds the solution (and optionally runs its tests) during an approved phase, with redacted output kept as evidence.

.DESCRIPTION
  Refuses unless the plan is approved and unchanged, gate 3 passed, the project is on the upgrade branch, and the
  phase is in progress. Runs dotnet build (and dotnet test with -Test) in the project folder. -Precompile forces
  build-time view compilation (RazorCompileOnBuild and RazorCompileOnPublish true). Writes
  evidence/<phase>/build-<stamp>.txt (redacted output) and build-<stamp>.json (summary). Build outputs are the only
  files it changes. Prints the summary as JSON; never the full output.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [Parameter(Mandatory = $true)][string]$PhaseId,
    [string]$Target = '',
    [string]$Configuration = 'Release',
    [switch]$Precompile,
    [switch]$Test,
    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Execution.psm1') -DisableNameChecking

function Invoke-Dotnet {
    param([string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutMinutes)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command dotnet -ErrorAction Stop).Source
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
    $psi.EnvironmentVariables['DOTNET_NOLOGO'] = '1'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMinutes * 60000)) { try { $p.Kill() } catch { }; return [ordered]@{ exitCode = -1; output = $o.Result + $e.Result + "`n[timed out after $TimeoutMinutes minutes]"; seconds = [int]$sw.Elapsed.TotalSeconds } }
    $p.WaitForExit()
    return [ordered]@{ exitCode = $p.ExitCode; output = ($o.Result + $e.Result); seconds = [int]$sw.Elapsed.TotalSeconds }
}

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $state = Assert-ExecutionAllowed -ProjectRoot $root -PhaseId $PhaseId
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'The .NET SDK (dotnet) is not on PATH. Install the SDK the target needs, then run the build again.' }
    if (-not $Target) {
        if ($state['project']['solution']) { $Target = [string]$state['project']['solution'] }
        elseif ($state['project']['webProject']) { $Target = [string]$state['project']['webProject'] }
    }
    if (-not $Target) { throw 'No solution or project to build. Give -Target <relative path to .sln or .csproj>.' }
    $targetFull = Resolve-FullPath (Join-Path $root $Target)
    if (-not (Test-PathUnder -Root $root -Path $targetFull) -or -not [System.IO.File]::Exists($targetFull)) { throw "Build target '$Target' is not a file inside the project." }
    $buildArgs = @('build', $targetFull, '-c', $Configuration, '-nologo', '-v:minimal')
    if ($Precompile) { $buildArgs += @('-p:RazorCompileOnBuild=true', '-p:RazorCompileOnPublish=true') }
    $build = Invoke-Dotnet -Arguments $buildArgs -WorkingDirectory $root -TimeoutMinutes $TimeoutMinutes
    $log = "dotnet $(@($buildArgs | ForEach-Object { if ($_ -eq $targetFull) { $Target } else { $_ } }) -join ' ')`n" + $build.output
    $testResult = $null
    if ($Test -and $build.exitCode -eq 0) {
        $testArgs = @('test', $targetFull, '-c', $Configuration, '--no-build', '-nologo', '-v:minimal')
        $testResult = Invoke-Dotnet -Arguments $testArgs -WorkingDirectory $root -TimeoutMinutes $TimeoutMinutes
        $log += "`n`ndotnet test $Target -c $Configuration --no-build`n" + $testResult.output
    }
    $stamp = Get-EvidenceStamp
    $txt = Write-RedactedEvidence -ProjectRoot $root -Folder $PhaseId -Name "build-$stamp.txt" -Content $log
    $errors = @([regex]::Matches($build.output, '(?m):\s*error\s+[A-Z]+\d+')).Count
    $warnings = @([regex]::Matches($build.output, '(?m):\s*warning\s+[A-Z]+\d+')).Count
    $summary = [ordered]@{
        ok = ($build.exitCode -eq 0 -and ($null -eq $testResult -or $testResult.exitCode -eq 0))
        phase = $PhaseId; target = $Target; configuration = $Configuration; precompiledViews = [bool]$Precompile
        build = [ordered]@{ exitCode = $build.exitCode; errors = $errors; warnings = $warnings; seconds = $build.seconds }
        tests = $(if ($testResult) { [ordered]@{ exitCode = $testResult.exitCode; seconds = $testResult.seconds } } elseif ($Test) { 'skipped: the build failed' } else { 'not run' })
        evidence = @($txt.path)
        at = (Get-UtcTimestamp)
    }
    $js = Write-RedactedEvidence -ProjectRoot $root -Folder $PhaseId -Name "build-$stamp.json" -Content (ConvertTo-JsonText -InputObject $summary)
    $summary.evidence = @($txt.path, $js.path)
    Write-JsonOutput $summary
    if ($summary.ok) { exit 0 } else { exit 1 }
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
