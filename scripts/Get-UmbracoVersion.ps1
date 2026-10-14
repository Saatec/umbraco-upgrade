<#
.SYNOPSIS
  Detects the Umbraco version from package references, lock and assets files, central package management, web.config status keys, legacy config files, appsettings.json, and assembly metadata.

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
    Write-JsonOutput (Get-UmbracoVersionInfo -Root $root)
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
