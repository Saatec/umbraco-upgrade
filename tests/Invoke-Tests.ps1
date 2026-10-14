<#
.SYNOPSIS
  Runs the Pester suites (Pester 5 or later) on Windows PowerShell 5.1 and, when installed, PowerShell 7.

.DESCRIPTION
  Every Describe block carries exactly one label tag: mocked, fixture-based, eval, or real-project.
  The selector tag "integration" (claude -p runs, a few model calls) is excluded unless -Integration is set.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Integration
#>
[CmdletBinding()]
param([switch]$Integration, [string[]]$Path = @(), [switch]$CurrentRuntimeOnly, [string]$ResultPath = '')

$ErrorActionPreference = 'Stop'
if (-not $CurrentRuntimeOnly) {
    $codes = @()
    $runtimes = @('powershell')
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { $runtimes += 'pwsh' } else { Write-Host 'PowerShell 7 (pwsh) not found: running on Windows PowerShell 5.1 only.' }
    foreach ($rt in $runtimes) {
        Write-Host "=== Runtime: $rt"
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-CurrentRuntimeOnly')
        if ($Integration) { $a += '-Integration' }
        if ($Path.Count -gt 0) { $a += '-Path'; $a += ($Path -join ',') }
        if ($ResultPath) { $a += '-ResultPath'; $a += $ResultPath }
        & $rt @a
        $codes += $LASTEXITCODE
    }
    if (@($codes | Where-Object { $_ -ne 0 }).Count -gt 0) { exit 1 } else { exit 0 }
}

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5 or later is required: Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5' }
Import-Module $pester.Path -Force
Write-Host ("Pester {0} on PowerShell {1}" -f $pester.Version, $PSVersionTable.PSVersion)

$config = New-PesterConfiguration
$paths = @($Path | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($paths.Count -eq 0) { $paths = @($PSScriptRoot) }
$config.Run.Path = $paths
$config.Run.Exit = $true
$config.Output.Verbosity = 'Normal'
if (-not $Integration) { $config.Filter.ExcludeTag = @('integration') }
# Result files go outside the repository: they contain machine-specific paths.
if ($ResultPath) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = Join-Path $ResultPath ("results-{0}.xml" -f $PSVersionTable.PSEdition)
}
Invoke-Pester -Configuration $config
