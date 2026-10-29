<#
.SYNOPSIS
  Ends a phase with a checkpoint commit on the upgrade branch and records the commit in state.

.DESCRIPTION
  Refuses unless the plan is approved and unchanged, gate 3 passed, the project is on the upgrade branch, the
  phase is in progress, and every acceptance criterion of the phase is met or waived. Before committing it scans
  the working tree changes (without staging anything):
    - a deleted project file needs a recorded, unused 'remove-custom-feature' approval whose scope names the file
      or a folder that contains it (paths separated by ';'); the approvals used are consumed
    - added lines that throw NotImplementedException or open an '#if false' block are refused as stubs
    - added lines that look like secrets are refused
    - commented-out code, files excluded from compilation (<Compile Remove>), and files that lost most of their
      lines are reported as warnings to review
  Then it stages the project (build output folders bin/ and obj/ excluded; .umbraco-upgrade/ only when the folder
  policy is 'commit'), commits (an empty commit when nothing changed), and records the commit for the phase.
  Writes evidence/<phase>/checkpoint.json. Prints JSON.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [Parameter(Mandatory = $true)][string]$PhaseId,
    [string]$Message = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Execution.psm1') -DisableNameChecking

function Test-IgnoredPath {
    param([string]$Path)
    return ($Path -match '(?i)(^|/)\.umbraco-upgrade/' -or $Path -match '(?i)(^|/)(bin|obj)/')
}

function Invoke-Git { param([string]$Root, [string[]]$Arguments) $r = Invoke-GitCommand -Root $Root -Arguments $Arguments -TimeoutSeconds 300; if ($r.exitCode -ne 0) { throw ("git $($Arguments[0]) failed: " + (Protect-Text ([string]$r.stderr))) }; return $r }

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $state = Assert-ExecutionAllowed -ProjectRoot $root -PhaseId $PhaseId
    $phase = @($state['phases']) | Where-Object { $_['id'] -eq $PhaseId } | Select-Object -First 1
    $open = @(@($phase['acceptanceCriteria']) | Where-Object { $_['status'] -notin @('met', 'waived') } | ForEach-Object { $_['id'] })
    if ($open.Count -gt 0) { throw "Phase $PhaseId has acceptance criteria that are not met or waived: $($open -join ', ')." }
    # 1. What changed (paths relative to the project root).
    $status = Invoke-Git $root @('status', '--porcelain=v1', '--untracked-files=all', '--', '.')
    $prefix = (Invoke-Git $root @('rev-parse', '--show-prefix')).stdout
    $prefix = $(if (@($prefix).Count -gt 0) { [string]$prefix[0] } else { '' })
    $deleted = @(); $changed = @(); $untracked = @()
    foreach ($line in $status.stdout) {
        if ($line.Length -lt 4) { continue }
        $code = $line.Substring(0, 2); $path = $line.Substring(3)
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $path = $path.Trim('"')
        if ($prefix -and $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring($prefix.Length) }
        if (Test-IgnoredPath $path) { continue }
        if ($code.Contains('D')) { $deleted += $path } elseif ($code -eq '??') { $untracked += $path } else { $changed += $path }
    }
    # 2. Deleted files need an approval that names them.
    $approvalsUsed = @()
    if ($deleted.Count -gt 0) {
        $uncovered = @()
        $approvals = @(@($state['approvals']) | Where-Object { $_['action'] -eq 'remove-custom-feature' -and $_['decision'] -eq 'approved' -and -not $_['consumed'] })
        foreach ($d in $deleted) {
            $hit = $null
            foreach ($a in $approvals) {
                foreach ($s in (([string]$a['scope']) -split ';')) {
                    $s2 = $s.Trim().Trim('/').Replace('\', '/')
                    if ($s2 -and ($d -ieq $s2 -or $d.StartsWith($s2 + '/', [System.StringComparison]::OrdinalIgnoreCase))) { $hit = $a; break }
                }
                if ($hit) { break }
            }
            if ($hit) { if ($approvalsUsed -notcontains $hit['id']) { $approvalsUsed += $hit['id'] } } else { $uncovered += $d }
        }
        if ($uncovered.Count -gt 0) { throw ("Files were deleted without a recorded 'remove-custom-feature' approval that names them: " + ($uncovered -join ', ') + ". Restore them, or ask the user and record the approval with the paths as its scope. Never remove custom functionality to make the project build: record an unresolved item instead.") }
    }
    # 3. Added lines: stubs and secrets refused; disabled code reported.
    $added = New-Object System.Collections.ArrayList
    $diff = Invoke-Git $root @('diff', '--relative', '-U0', '--no-color', '--', '.')
    $file = $null; $removedPerFile = @{}; $addedPerFile = @{}
    foreach ($l in $diff.stdout) {
        if ($l.StartsWith('+++ ')) { $file = ($l.Substring(4) -replace '^b/', ''); continue }
        if ($l.StartsWith('--- ')) { continue }
        if (-not $file -or (Test-IgnoredPath $file)) { continue }
        if ($l.StartsWith('+')) { [void]$added.Add([ordered]@{ file = $file; text = $l.Substring(1) }); $addedPerFile[$file] = 1 + [int]$addedPerFile[$file] }
        elseif ($l.StartsWith('-')) { $removedPerFile[$file] = 1 + [int]$removedPerFile[$file] }
    }
    foreach ($u in $untracked) {
        $full = Join-Path $root $u
        if (-not [System.IO.File]::Exists($full) -or (New-Object System.IO.FileInfo($full)).Length -gt 2MB) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($full)
        if ($bytes -contains 0) { continue }
        foreach ($t in ((Read-TextFile $full) -split "`r?`n")) { [void]$added.Add([ordered]@{ file = $u; text = $t }) }
    }
    $stubs = @(); $secrets = @(); $warnings = @()
    foreach ($a in $added) {
        if ($a.text -match '\bthrow\s+new\s+(?:System\.)?NotImplementedException\b' -or $a.text -match '^\s*#\s*if\s+false\b') { $stubs += "$($a.file): $((Protect-Text $a.text).Trim())" }
        elseif ((Protect-Text $a.text) -ne $a.text) { $secrets += $a.file }
        elseif ($a.text -match '^\s*(//|\*|@\*).*(;|\)|\})\s*$' -and $a.text -notmatch '^\s*///') { $warnings += "possible disabled code in $($a.file): $((Protect-Text $a.text).Trim())" }
        elseif ($a.file -match '(?i)\.(csproj|vbproj|props|targets)$' -and $a.text -match '(?i)<Compile\s+Remove\s*=') { $warnings += "files excluded from compilation in $($a.file): $((Protect-Text $a.text).Trim())" }
    }
    foreach ($f in $removedPerFile.Keys) { if ([int]$removedPerFile[$f] -ge 20 -and [int]$addedPerFile[$f] -lt 3) { $warnings += "$f lost $($removedPerFile[$f]) lines and gained $([int]$addedPerFile[$f]): check that no functionality was removed" } }
    if ($stubs.Count -gt 0) { throw ("Stubs were added: " + ($stubs -join ' | ') + ". Do not stub custom functionality. Restore the original code and record an unresolved item with a proposed approach.") }
    if ($secrets.Count -gt 0) { throw ("Added lines look like secrets in: " + (@($secrets | Sort-Object -Unique) -join ', ') + ". Move the values to user secrets or environment variables (Copy-ConfigValue.ps1) before the checkpoint.") }
    # 4. Stage and commit. Exclude pathspecs fail on ignored folders, so stage everything, then unstage what stays out.
    [void](Invoke-Git $root @('add', '-A', '--', '.'))
    $stateOut = $(if ($state['project']['stateFolderPolicy'] -eq 'commit') { '.umbraco-upgrade/tmp' } else { '.umbraco-upgrade' })
    [void](Invoke-Git $root @('reset', '-q', '--', ':(glob,icase)**/bin/**', ':(glob,icase)**/obj/**', $stateOut))
    $title = [string]$phase['title']
    $msg = "umbraco-upgrade checkpoint ${PhaseId}: $title"
    if ($Message) { $msg += "`n`n$Message" }
    [void](Invoke-Git $root @('commit', '-q', '--allow-empty', '-m', (Protect-Text $msg)))
    $sha = [string](Invoke-Git $root @('rev-parse', 'HEAD')).stdout[0]
    [void](Set-PhaseCheckpoint -ProjectRoot $root -PhaseId $PhaseId -Commit $sha)
    foreach ($id in $approvalsUsed) {
        $st = Read-UpgradeState $root
        foreach ($ap in @($st['approvals'])) { if ($ap['id'] -eq $id) { $ap['consumed'] = $true } }
        [void](Save-UpgradeState -ProjectRoot $root -State $st -Event 'approval-consumed' -Detail $id)
    }
    $record = [ordered]@{ at = (Get-UtcTimestamp); phase = $PhaseId; commit = $sha; changed = @($changed); added = @($untracked); deleted = @($deleted); approvalsUsed = @($approvalsUsed); warnings = @($warnings) }
    $ev = Write-RedactedEvidence -ProjectRoot $root -Folder $PhaseId -Name 'checkpoint.json' -Content (ConvertTo-JsonText -InputObject $record)
    Write-JsonOutput ([ordered]@{ ok = $true; phase = $PhaseId; commit = $sha; changed = $changed.Count; added = $untracked.Count; deleted = $deleted.Count; approvalsUsed = @($approvalsUsed); warnings = @($warnings); evidence = $ev.path; next = "state.ps1 phase -PhaseId $PhaseId -Status done" })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
