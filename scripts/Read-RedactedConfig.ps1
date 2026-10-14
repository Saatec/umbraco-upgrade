<#
.SYNOPSIS
  Prints a configuration file with secret values redacted.

.DESCRIPTION
  Read-only. Use this instead of printing appsettings*.json, *.config, secrets.json, .env*,
  publish profiles, or similar files directly; the safety guard blocks direct dumps of those
  files in upgrade projects. Key names stay visible; values that look like secrets are replaced.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking

try {
    $full = Resolve-FullPath $Path.Trim().Trim('"', "'")
    if (-not [System.IO.File]::Exists($full)) { throw "File '$full' does not exist." }
    $len = (New-Object System.IO.FileInfo($full)).Length
    if ($len -gt 5MB) { throw "File '$full' is larger than 5 MB." }
    $text = Read-TextFile $full
    if ($text.IndexOf([char]0) -ge 0) { throw "File '$full' looks binary." }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes('# ' + $full + ' (secrets redacted)' + [Environment]::NewLine + (Protect-Text $text))
    $stream = [Console]::OpenStandardOutput()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    exit 0
} catch {
    [Console]::Error.WriteLine((Protect-Text $_.Exception.Message))
    exit 1
}
