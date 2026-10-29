<#
.SYNOPSIS
  Writes evidence for a phase or gate to .umbraco-upgrade/evidence/<folder>/<name>, with secrets redacted.

.DESCRIPTION
  Give the content as -Text, or as -SourceFile (for example command output saved under .umbraco-upgrade/tmp/).
  -RemoveSource deletes a source file under .umbraco-upgrade/tmp/ after it is copied, so unredacted output does
  not stay behind. The folder is a phase id that exists in state (P1, P2, ...) or a gate folder (discovery,
  version-path, safety, planning, final). Prints one JSON object with the relative path; never the content.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [Parameter(Mandatory = $true)][string]$Folder,
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Text = $null,
    [string]$SourceFile = '',
    [switch]$Append,
    [switch]$RemoveSource
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Execution.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not (Test-StateExists $root)) { throw 'No upgrade state in this project.' }
    if ($SourceFile -and $PSBoundParameters.ContainsKey('Text')) { throw 'Give -Text or -SourceFile, not both.' }
    $content = $Text
    $src = $null
    if ($SourceFile) {
        $src = Resolve-FullPath $SourceFile
        if (-not [System.IO.File]::Exists($src)) { throw "Source file '$SourceFile' does not exist." }
        if ((New-Object System.IO.FileInfo($src)).Length -gt 5MB) { throw 'Source file is larger than 5 MB; write a summary instead.' }
        $content = Read-TextFile $src
    }
    if ($null -eq $content) { throw 'Give -Text or -SourceFile.' }
    $r = Write-RedactedEvidence -ProjectRoot $root -Folder $Folder -Name $Name -Content $content -Append:$Append
    $out = [ordered]@{ ok = $true; path = $r.path; bytes = $r.bytes; redacted = $r.redacted }
    if ($RemoveSource -and $src) {
        $tmp = Join-Path (Get-StateDir $root) 'tmp'
        if (-not (Test-PathUnder -Root $tmp -Path $src)) { throw 'The evidence was written, but -RemoveSource deletes only files under .umbraco-upgrade/tmp/.' }
        [System.IO.File]::Delete($src)
        $out.sourceRemoved = $true
    }
    Write-JsonOutput $out
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
