<#
.SYNOPSIS
  Checks a public feedback draft for anything that identifies the project, for /umbraco-upgrade:feedback.

.DESCRIPTION
  Read-only. Derives names from the project (solution, project, and assembly names, the project and repository
  folders, git remote hosts and paths, git authors, custom App_Plugins folders, private package ids from the gate 4
  package check) and reports each line of the draft that contains one of them, an email address, a host other than
  official documentation and package feeds, a local file path, or a value that looks like a secret. Secret values are
  never echoed. The default draft is .umbraco-upgrade/feedback.md. Prints one JSON object; clean is true when there
  are no findings. The check cannot know every name, so a person still reads the draft before it is posted.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '', [string]$Path = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Feedback.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Path '$root' is not a directory." }
    $draft = $(if ($Path) { Resolve-FullPath $Path.Trim().Trim('"', "'") } else { Join-Path (Get-StateDir $root) 'feedback.md' })
    if (-not [System.IO.File]::Exists((ConvertTo-IoPath $draft))) { throw "No draft at '$draft'. Write the draft first." }
    $tokens = Get-ProjectIdentityTokens -Root $root
    $findings = Test-FeedbackDraftText -Text (Read-TextFile $draft) -Tokens $tokens
    Write-JsonOutput ([ordered]@{ ok = $true; file = $draft; clean = (@($findings).Count -eq 0); findings = @($findings); namesChecked = @($tokens).Count })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
