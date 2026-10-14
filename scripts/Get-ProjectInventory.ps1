<#
.SYNOPSIS
  Lists solutions, projects, target frameworks, package references, loose assemblies, App_Plugins folders and manifests, views, config, CI, publish, and IIS files.

.DESCRIPTION
  Read-only. Prints one JSON object to stdout. Exit code 0 on success, 1 on error.
#>
[CmdletBinding()]
param([string]$Path = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Discovery.psm1') -DisableNameChecking

try {
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $Path.Trim().Trim('"', "'")
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Path '$root' is not a directory." }
    Write-JsonOutput (Get-ProjectInventoryInfo -Root $root)
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
