<#
.SYNOPSIS
  Validates /umbraco-upgrade command arguments: target version format, project path, and Umbraco presence.

.DESCRIPTION
  Read-only. Prints one JSON object. Exit code 0 when the arguments are usable, 1 otherwise.
  Each failure has a stable code and a specific message. No state is written.
  start and plan take a target and a path, and refuse a project that already has upgrade state. resume, verify,
  and report take only a path and need the state; for them a project the version detection does not recognize
  is a warning, because resume reconciliation reports what changed.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$Path = '',
    [ValidateSet('start', 'plan', 'resume', 'verify', 'report')][string]$Command = 'start'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Discovery.psm1') -DisableNameChecking

$stateCommand = ($Command -in @('resume', 'verify', 'report'))
$usage = $(if ($stateCommand) { "Usage: /umbraco-upgrade:$Command [project-path]. Example: /umbraco-upgrade:$Command C:\src\MySite" } else { "Usage: /umbraco-upgrade:$Command <target-version> [project-path]. Example: /umbraco-upgrade:$Command 17 C:\src\MySite" })
$result = [ordered]@{ ok = $false; command = $Command; usage = $usage; target = $null; projectRoot = $null; detected = $null; stateExists = $false; errors = @(); warnings = @() }
$errors = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList

function Add-Problem { param($List, [string]$Code, [string]$Message) [void]$List.Add([ordered]@{ code = $Code; message = $Message }) }

try {
    $t = $Target.Trim().Trim('"', "'")
    $p = $Path.Trim().Trim('"', "'")
    if ($stateCommand) {
        if ($t) { Add-Problem $errors 'unexpected-argument' "/umbraco-upgrade:$Command takes only a project path; the target comes from the recorded state. $usage" }
    } elseif (-not $t) {
        Add-Problem $errors 'missing-target' "A target version is required. $usage"
    } elseif ($t -notmatch '^\d+(\.\d+){0,2}$') {
        $hint = ''
        if ($t -match '^[vV](\d+(\.\d+){0,2})$') { $hint = " Did you mean '$($Matches[1])'?" }
        Add-Problem $errors 'invalid-target' "Target version '$t' is not valid. Use a major version such as 17, or an exact version such as 17.2.0.$hint"
    } else {
        $parts = $t -split '\.'
        $kind = @('major', 'minor', 'exact')[$parts.Count - 1]
        $result.target = [ordered]@{ requested = $t; kind = $kind; major = [int]$parts[0]; factStatus = 'unverified' }
    }

    if (-not $p) { $p = (Get-Location).ProviderPath }
    $full = $null
    try { $full = Resolve-FullPath $p } catch { $full = $null }
    if (-not $full -or -not (Test-Path -LiteralPath $full)) {
        Add-Problem $errors 'path-not-found' "Project path '$p' does not exist."
    } elseif (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Add-Problem $errors 'path-not-directory' "Project path '$p' is a file. Pass the project folder."
    } else {
        $result.projectRoot = $full
        $result.stateExists = [System.IO.File]::Exists((Join-Path $full '.umbraco-upgrade/state.json'))
        $v = Get-UmbracoVersionInfo -Root $full
        $result.detected = [ordered]@{
            isUmbraco = $v.isUmbraco; version = $v.resolved.version; major = $v.resolved.major; generation = $v.resolved.generation
            confidence = $v.resolved.confidence; needsConfirmation = $v.resolved.needsConfirmation; conflicts = @($v.conflicts).Count
        }
        if (-not $v.isUmbraco -and $stateCommand) {
            Add-Problem $warnings 'not-umbraco' "No Umbraco project files were recognized in '$full'. The recorded state is checked against the folder anyway."
        } elseif (-not $v.isUmbraco) {
            Add-Problem $errors 'not-umbraco' "No Umbraco project found in '$full'. Looked for core package references (packages.config, project files, central package management), Umbraco configuration status keys in web.config, legacy config files, and the Umbraco section in appsettings.json."
        }
        if ($stateCommand -and -not $result.stateExists) {
            Add-Problem $errors 'no-state' "No upgrade state in '$full' (looked for .umbraco-upgrade/state.json). Start with /umbraco-upgrade:start or /umbraco-upgrade:plan."
        } elseif ($result.stateExists -and -not $stateCommand) {
            Add-Problem $errors 'state-exists' "An upgrade state already exists at '$(Join-Path $full '.umbraco-upgrade')'. To continue it, run /umbraco-upgrade:resume. To start over, review that folder, then move or remove it yourself."
        }
        if ($result.target -and $null -ne $v.resolved.major) {
            $srcMajor = [int]$v.resolved.major
            $tgt = $result.target
            if ($tgt.major -lt $srcMajor) {
                Add-Problem $errors 'target-not-newer' "Target $($tgt.requested) is older than the detected source $($v.resolved.version). Downgrades are not supported."
            } elseif ($tgt.major -eq $srcMajor) {
                if ($tgt.kind -eq 'exact' -and $v.resolved.version -and ([version]$tgt.requested -le [version]$v.resolved.version)) {
                    Add-Problem $errors 'target-not-newer' "Target $($tgt.requested) is not newer than the detected source $($v.resolved.version)."
                } else {
                    Add-Problem $warnings 'same-major' "Target $($tgt.requested) is in the same major version as the source. This plugin is built for major-version upgrades."
                }
            }
        }
        if ($v.resolved.needsConfirmation -and -not $stateCommand) {
            Add-Problem $warnings 'source-needs-confirmation' "The source version could not be determined with high confidence (confidence: $($v.resolved.confidence)). Discovery will report the signals and ask."
        }
    }
    $result.errors = @($errors)
    $result.warnings = @($warnings)
    $result.ok = ($errors.Count -eq 0)
} catch {
    $result.errors = @(@($errors) + [ordered]@{ code = 'internal-error'; message = $_.Exception.Message })
    $result.ok = $false
}
Write-JsonOutput $result
if ($result.ok) { exit 0 } else { exit 1 }
