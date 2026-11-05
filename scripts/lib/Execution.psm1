# Execution.psm1 - preconditions and evidence for plan execution (after gate 4 approval).
# Every script that changes the project, builds it, or touches the local database checks these first.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -DisableNameChecking

$script:FixedEvidenceFolders = @('discovery', 'version-path', 'safety', 'planning', 'final')

function Get-CurrentBranchName {
    param([Parameter(Mandatory)][string]$Root)
    $r = Invoke-GitCommand -Root $Root -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($r.exitCode -eq 0 -and @($r.stdout).Count -gt 0) { return [string]$r.stdout[0] }
    return $null
}

function Assert-ExecutionAllowed {
    # Throws unless the plan is approved and unchanged, gate 3 passed, the project is on the upgrade branch, and
    # (with -PhaseId) the phase exists and is in progress. -PhaseId final stands for gate 5, which must be in
    # progress (its builds write evidence/final/). Returns the state.
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$PhaseId = '', [switch]$AllowAnyPhaseStatus)
    if (-not (Test-StateExists $ProjectRoot)) { throw 'No upgrade state in this project. Run /umbraco-upgrade:start first.' }
    $state = Read-UpgradeState $ProjectRoot
    if ($state['mode'] -ne 'upgrade') { throw 'This project is in plan-only mode. Plan execution runs only through /umbraco-upgrade:start.' }
    if ($state['gates']['safety']['status'] -ne 'passed') { throw 'Gate 3 (safety setup) has not passed.' }
    if ($state['gates']['planApproval']['status'] -ne 'approved') { throw "The plan is not approved (gate 4 is '$($state['gates']['planApproval']['status'])')." }
    $check = Test-PlanHash -ProjectRoot $ProjectRoot
    if (-not $check.matches) { throw 'plan.md changed after approval. Request approval again before executing.' }
    $branch = Get-CurrentBranchName -Root $ProjectRoot
    $expected = [string]$state['gitBaseline']['upgradeBranch']
    if (-not $expected) { throw 'No upgrade branch is recorded.' }
    if ($branch -ne $expected) { throw "The project is on branch '$branch', not on the upgrade branch '$expected'." }
    if ($PhaseId -eq 'final') {
        if ($state['gates']['final']['status'] -ne 'in-progress') { throw "Gate 5 is '$($state['gates']['final']['status'])'. Start it first: state.ps1 gate -Gate final -Status in-progress." }
        return $state
    }
    if ($PhaseId) {
        $phase = @($state['phases']) | Where-Object { $_['id'] -eq $PhaseId } | Select-Object -First 1
        if ($null -eq $phase) { throw "Unknown phase '$PhaseId'." }
        if (-not $AllowAnyPhaseStatus -and $phase['status'] -ne 'in-progress') { throw "Phase $PhaseId is '$($phase['status'])'. Start it first: state.ps1 phase -PhaseId $PhaseId -Status in-progress." }
    }
    return $state
}

function Assert-EvidenceFolder {
    # Evidence goes to .umbraco-upgrade/evidence/<folder>/ where folder is a phase id in state or a fixed gate folder.
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Folder)
    if ($script:FixedEvidenceFolders -contains $Folder) { return }
    if ($Folder -notmatch '^P\d+$') { throw "Evidence folder '$Folder' must be a phase id (P1, P2, ...) or one of: $($script:FixedEvidenceFolders -join ', ')." }
    $state = Read-UpgradeState $ProjectRoot
    if (@(@($state['phases']) | Where-Object { $_['id'] -eq $Folder }).Count -eq 0) { throw "Unknown phase '$Folder'." }
}

function Write-RedactedEvidence {
    # Writes text to .umbraco-upgrade/evidence/<folder>/<name> with secrets redacted. Returns the relative path and
    # whether redaction changed anything.
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Content, [switch]$Append)
    Assert-EvidenceFolder -ProjectRoot $ProjectRoot -Folder $Folder
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._\-]{0,120}$') { throw "Evidence name '$Name' must be a plain file name (letters, digits, dot, dash, underscore)." }
    $rel = "evidence/$Folder/$Name"
    $path = Join-Path (Get-StateDir $ProjectRoot) $rel
    $safe = Protect-Text ([string]$Content)
    $changed = ($safe -ne [string]$Content)
    if ($Append -and [System.IO.File]::Exists($path)) { $safe = (Read-TextFile $path) + $safe }
    Write-TextFile -Path $path -Content $safe
    return [ordered]@{ path = $rel; bytes = ([System.Text.Encoding]::UTF8.GetByteCount($safe)); redacted = $changed }
}

function Get-EvidenceStamp { return [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') }

Export-ModuleMember -Function Get-CurrentBranchName, Assert-ExecutionAllowed, Assert-EvidenceFolder, Write-RedactedEvidence, Get-EvidenceStamp
