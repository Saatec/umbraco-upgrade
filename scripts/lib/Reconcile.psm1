# Reconcile.psm1 - resume reconciliation (A7): compares .umbraco-upgrade/state.json with the repository, the
# project files, and the recorded evidence. Read-only. It reports each difference with options for the user and
# never repairs state, files, or the repository.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ConnectionInfo.psm1') -DisableNameChecking

function New-RealityCheck {
    # status: ok, mismatch (state and reality disagree: report and ask), warning (worth telling the user), or
    # not-checked (with the reason).
    param([string]$Id, [string]$Area, [ValidateSet('ok', 'mismatch', 'warning', 'not-checked')][string]$Status, $Expected = $null, $Actual = $null, [string]$Detail = '', [string[]]$Options = @())
    return [ordered]@{ id = $Id; area = $Area; status = $Status; expected = $Expected; actual = $Actual; detail = $Detail; options = @($Options) }
}

function Invoke-GitRead {
    param([string]$Root, [string[]]$Arguments)
    return (Invoke-GitCommand -Root $Root -Arguments $Arguments -TimeoutSeconds 60)
}

function Test-CommitExists {
    param([string]$Root, [string]$Commit)
    if (-not $Commit) { return $false }
    return ((Invoke-GitRead $Root @('cat-file', '-e', "$Commit^{commit}")).exitCode -eq 0)
}

function Test-IsAncestor {
    # $true, $false, or $null when git cannot tell.
    param([string]$Root, [string]$Ancestor, [string]$Descendant = 'HEAD')
    $r = Invoke-GitRead $Root @('merge-base', '--is-ancestor', $Ancestor, $Descendant)
    if ($r.exitCode -eq 0) { return $true }
    if ($r.exitCode -eq 1) { return $false }
    return $null
}

function Get-CommitCount {
    param([string]$Root, [string]$Range)
    $r = Invoke-GitRead $Root @('rev-list', '--count', $Range)
    if ($r.exitCode -eq 0 -and @($r.stdout).Count -gt 0) { return [int]$r.stdout[0] }
    return $null
}

function Get-ShortSha { param([string]$Sha) if ($Sha -and $Sha.Length -gt 12) { return $Sha.Substring(0, 12) } return $Sha }

function Get-PhaseStepMap {
    # Phase id -> path step id, from the phase proposal written at gate 4.
    param([string]$ProjectRoot)
    $map = @{}
    $f = Join-Path (Get-StateDir $ProjectRoot) 'evidence/planning/phase-composition.json'
    if (-not [System.IO.File]::Exists($f)) { return $null }
    try { $c = ConvertTo-PlainObject (Read-JsonFile $f) } catch { return $null }
    foreach ($p in @($c['phases'])) { if ($p -and $p.Contains('id') -and $p.Contains('step')) { $map[[string]$p['id']] = [string]$p['step'] } }
    return $map
}

function Get-ResumePosition {
    # Where the workflow stands, from state alone.
    param($State)
    $g = $State['gates']
    $mode = $State['mode']
    foreach ($name in @('discovery', 'versionPath')) {
        if ($g[$name]['status'] -ne 'passed') { return [ordered]@{ kind = 'gate'; gate = $name; phase = $null; status = $g[$name]['status']; next = "Gate '$name' is '$($g[$name]['status'])'. Continue it from its first step that has no result yet." } }
    }
    if ($mode -eq 'upgrade' -and $g['safety']['status'] -ne 'passed') { return [ordered]@{ kind = 'gate'; gate = 'safety'; phase = $null; status = $g['safety']['status']; next = "Gate 3 is '$($g['safety']['status'])'. Continue the safety setup (git checks, branch, rollback document, guard self-test)." } }
    $pa = $g['planApproval']['status']
    if ($mode -eq 'plan') {
        if ($pa -eq 'awaiting-approval') { return [ordered]@{ kind = 'done'; gate = 'planApproval'; phase = $null; status = $pa; next = 'This is a plan-only run and its plan is written. Approval and execution happen through /umbraco-upgrade:start in a project without this state; move the folder away first.' } }
        return [ordered]@{ kind = 'gate'; gate = 'planApproval'; phase = $null; status = $pa; next = "Gate 4 is '$pa'. Finish writing the plan." }
    }
    if ($pa -ne 'approved') {
        $next = switch ($pa) {
            'awaiting-approval' { 'The plan waits for the user''s approval. Show where it is and ask again.' }
            'invalidated' { 'plan.md changed after approval. Request approval again (state.ps1 request-plan-approval) and ask.' }
            'rejected' { 'The user rejected the plan. Ask what to change; nothing runs until a new approval.' }
            default { "Gate 4 is '$pa'. Finish the plan and request approval." }
        }
        return [ordered]@{ kind = 'gate'; gate = 'planApproval'; phase = $null; status = $pa; next = $next }
    }
    foreach ($p in @($State['phases'])) {
        if ($p['status'] -in @('in-progress', 'blocked', 'failed')) {
            $open = @(@($p['acceptanceCriteria']) | Where-Object { $_['status'] -notin @('met', 'waived') } | ForEach-Object { $_['id'] })
            return [ordered]@{ kind = 'phase'; gate = $null; phase = $p['id']; status = $p['status']; next = "Phase $($p['id']) was interrupted ('$($p['status'])'). Open criteria: $(if ($open.Count) { $open -join ', ' } else { 'none' }). Review its recorded failures and evidence before continuing it." }
        }
        if ($p['status'] -eq 'pending') { return [ordered]@{ kind = 'phase'; gate = $null; phase = $p['id']; status = 'pending'; next = "Next: phase $($p['id']) ($($p['title']))." } }
    }
    $fs = $g['final']['status']
    if ($fs -eq 'passed') { return [ordered]@{ kind = 'done'; gate = 'final'; phase = $null; status = $fs; next = 'The upgrade is complete. /umbraco-upgrade:report regenerates the report.' } }
    return [ordered]@{ kind = 'gate'; gate = 'final'; phase = $null; status = $fs; next = "Every phase is done or deferred; gate 5 is '$fs'. Run /umbraco-upgrade:verify." }
}

function Get-EvidenceReferences {
    # Every evidence path the state refers to, with where it was referred from.
    param($State)
    $refs = New-Object System.Collections.ArrayList
    foreach ($e in @($State['source']['evidence'])) { if ($e) { [void]$refs.Add([ordered]@{ path = [string]$e; from = 'source.evidence' }) } }
    foreach ($gn in @(Get-GateOrder)) {
        $gr = $State['gates'][$gn]
        if ($gr.Contains('evidence')) { foreach ($e in @($gr['evidence'])) { if ($e) { [void]$refs.Add([ordered]@{ path = [string]$e; from = "gates.$gn" }) } } }
        if ($gr.Contains('rollbackDoc') -and $gr['rollbackDoc']) { [void]$refs.Add([ordered]@{ path = ([string]$gr['rollbackDoc'] -replace '#.*$', ''); from = "gates.$gn.rollbackDoc" }) }
    }
    if ($State['gitBaseline']['statusEvidence']) { [void]$refs.Add([ordered]@{ path = [string]$State['gitBaseline']['statusEvidence']; from = 'gitBaseline.statusEvidence' }) }
    foreach ($p in @($State['phases'])) {
        foreach ($c in @($p['acceptanceCriteria'])) { if ($c -and $c.Contains('evidence')) { foreach ($e in @($c['evidence'])) { if ($e) { [void]$refs.Add([ordered]@{ path = [string]$e; from = "$($p['id']) $($c['id'])" }) } } } }
        foreach ($f in @($p['failures'])) { if ($f -and $f['evidence']) { [void]$refs.Add([ordered]@{ path = [string]$f['evidence']; from = "$($p['id']) failure" }) } }
    }
    if ($State.Contains('verification')) {
        foreach ($c in @($State['verification']['checks'])) { foreach ($e in @($c['evidence'])) { if ($e) { [void]$refs.Add([ordered]@{ path = [string]$e; from = "verification $($c['id'])" }) } } }
    }
    return ,($refs.ToArray())
}

function Test-GitReality {
    param([string]$Root, $State, $Position)
    $checks = New-Object System.Collections.ArrayList
    $gb = $State['gitBaseline']
    $repo = Get-GitRepoInfo -Root $Root
    if (-not $repo.gitAvailable) { [void]$checks.Add((New-RealityCheck 'git.available' 'git' 'not-checked' -Detail 'git is not available, so the branch, HEAD, and checkpoints were not compared.')); return ,($checks.ToArray()) }
    if (-not $gb['isRepo']) {
        if ($repo.isRepo) { [void]$checks.Add((New-RealityCheck 'git.repo' 'git' 'warning' 'not a git repository' 'a git repository' 'The project was not a git repository when the upgrade started; it is one now.')) }
        else { [void]$checks.Add((New-RealityCheck 'git.repo' 'git' 'not-checked' -Detail 'The project is not a git repository; branch and checkpoint checks do not apply.')) }
        return ,($checks.ToArray())
    }
    if (-not $repo.isRepo) {
        [void]$checks.Add((New-RealityCheck 'git.repo' 'git' 'mismatch' 'a git repository' 'not a git repository' 'State was recorded in a git repository, but the project folder is no longer inside one.' @('Point the command at the original clone of the project.', 'Restore the repository yourself, then run /umbraco-upgrade:resume again.')))
        return ,($checks.ToArray())
    }
    [void]$checks.Add((New-RealityCheck 'git.repo' 'git' 'ok' 'a git repository' 'a git repository'))
    $op = Get-GitOperationInProgress -Root $Root
    if ($op) { [void]$checks.Add((New-RealityCheck 'git.operation' 'git' 'mismatch' 'no git operation in progress' "a $op in progress" "A git $op is in progress in this repository." @("Finish or abort the $op yourself, then run /umbraco-upgrade:resume again."))) }
    # Branch.
    $expectedBranch = $(if ($gb['upgradeBranch']) { [string]$gb['upgradeBranch'] } else { [string]$gb['baseBranch'] })
    if ($gb['upgradeBranch']) {
        $exists = ((Invoke-GitRead $Root @('rev-parse', '--verify', '--quiet', "refs/heads/$($gb['upgradeBranch'])")).exitCode -eq 0)
        if (-not $exists) { [void]$checks.Add((New-RealityCheck 'git.upgrade-branch' 'git' 'mismatch' "branch $($gb['upgradeBranch']) exists" 'branch not found' 'The upgrade branch recorded in state does not exist in this repository.' @('Check whether the work is in another clone or under another branch name, and tell the plugin which one.', 'If the branch is gone, the recorded checkpoints cannot be trusted; start over in a copy of the folder.'))) }
    }
    if ($repo.detached) {
        [void]$checks.Add((New-RealityCheck 'git.branch' 'git' 'mismatch' $expectedBranch "detached HEAD at $(Get-ShortSha $repo.head)" 'HEAD is detached.' @("Switch back to $expectedBranch yourself (commit or set aside your changes first), then run /umbraco-upgrade:resume again.")))
    } elseif ($expectedBranch -and $repo.branch -ne $expectedBranch) {
        [void]$checks.Add((New-RealityCheck 'git.branch' 'git' 'mismatch' $expectedBranch $repo.branch "The project is on '$($repo.branch)', but state expects '$expectedBranch'." @("Switch back to $expectedBranch yourself, then run /umbraco-upgrade:resume again.", "If the work really continues on '$($repo.branch)', tell the plugin: the recorded checkpoints will be compared with that branch only after you confirm it.")))
    } else { [void]$checks.Add((New-RealityCheck 'git.branch' 'git' 'ok' $expectedBranch $repo.branch)) }
    # Base commit.
    $base = [string]$gb['baseCommit']
    if ($base) {
        if (-not (Test-CommitExists $Root $base)) {
            [void]$checks.Add((New-RealityCheck 'git.base-commit' 'git' 'mismatch' "commit $(Get-ShortSha $base) exists" 'commit not found' 'The base commit recorded at discovery is not in this repository (history rewritten, or another clone).' @('Point the command at the clone where the upgrade started.', 'Start over in a copy of the folder if that history is gone.')))
        } elseif ($State['mode'] -eq 'plan' -or -not $gb['upgradeBranch']) {
            if ($repo.head -eq $base) { [void]$checks.Add((New-RealityCheck 'git.base-commit' 'git' 'ok' (Get-ShortSha $base) (Get-ShortSha $repo.head))) }
            else {
                $anc = Test-IsAncestor $Root $base 'HEAD'
                if ($anc -eq $true) {
                    $n = Get-CommitCount $Root "$base..HEAD"
                    [void]$checks.Add((New-RealityCheck 'git.base-commit' 'git' 'warning' (Get-ShortSha $base) (Get-ShortSha $repo.head) "$n new commit(s) since discovery recorded the base commit; the inventory and plan may not cover them." @('Run discovery again in a fresh copy of the state folder if the new commits change project files.', 'Continue if the commits do not touch the site.')))
                } else {
                    [void]$checks.Add((New-RealityCheck 'git.base-commit' 'git' 'mismatch' (Get-ShortSha $base) (Get-ShortSha $repo.head) 'HEAD does not descend from the commit that discovery recorded.' @('Check out the history the upgrade started from yourself, or start over.')))
                }
            }
        } else {
            $anc = Test-IsAncestor $Root $base 'HEAD'
            if ($anc -eq $false) { [void]$checks.Add((New-RealityCheck 'git.base-commit' 'git' 'mismatch' "HEAD descends from $(Get-ShortSha $base)" (Get-ShortSha $repo.head) 'HEAD does not descend from the base commit of the upgrade branch.' @('Check out the upgrade branch as the checkpoints recorded it, or tell the plugin what happened.'))) }
            else { [void]$checks.Add((New-RealityCheck 'git.base-commit' 'git' 'ok' (Get-ShortSha $base) 'ancestor of HEAD')) }
        }
    }
    # Checkpoints of the phases.
    $inProgress = $(if ($Position.kind -eq 'phase' -and $Position.status -in @('in-progress', 'blocked', 'failed')) { [string]$Position.phase } else { $null })
    $last = $null
    foreach ($p in @($State['phases'])) {
        $sha = $null; if ($p['checkpoint'] -and $p['checkpoint']['commit']) { $sha = [string]$p['checkpoint']['commit'] }
        if ($p['status'] -eq 'done' -and -not $sha) { [void]$checks.Add((New-RealityCheck "git.checkpoint.$($p['id'])" 'git' 'mismatch' 'a checkpoint commit' 'none' "Phase $($p['id']) is done but has no checkpoint commit in state." @('Tell the plugin which commit ended the phase; it is recorded only after you confirm it.'))); continue }
        if (-not $sha) { continue }
        if (-not (Test-CommitExists $Root $sha)) {
            [void]$checks.Add((New-RealityCheck "git.checkpoint.$($p['id'])" 'git' 'mismatch' "commit $(Get-ShortSha $sha)" 'commit not found' "The checkpoint commit of phase $($p['id']) is not in this repository." @('Check whether the history was rewritten or this is another clone.', "If the commit is gone, phase $($p['id']) has to be checked again before anything continues; the plugin will not re-run it on its own.")))
        } elseif ((Test-IsAncestor $Root $sha 'HEAD') -ne $true) {
            [void]$checks.Add((New-RealityCheck "git.checkpoint.$($p['id'])" 'git' 'mismatch' "HEAD contains $(Get-ShortSha $sha)" (Get-ShortSha $repo.head) "The checkpoint commit of phase $($p['id']) is not part of the current HEAD (the branch was reset, or HEAD points elsewhere)." @("Move the upgrade branch back to its checkpoint yourself if the reset was a mistake.", "Tell the plugin if phase $($p['id']) should count as not done; that is recorded only on your decision.", 'Keep the current HEAD and stop here to investigate.')))
        } else { [void]$checks.Add((New-RealityCheck "git.checkpoint.$($p['id'])" 'git' 'ok' (Get-ShortSha $sha) 'in HEAD')) }
        $last = [ordered]@{ phase = $p['id']; commit = $sha }
    }
    # HEAD against the last checkpoint (or the base commit before the first checkpoint).
    if ($State['mode'] -eq 'upgrade' -and $gb['upgradeBranch'] -and $repo.head) {
        $ref = $(if ($last) { $last } else { [ordered]@{ phase = $null; commit = $base } })
        if ($ref.commit -and (Test-CommitExists $Root $ref.commit) -and (Test-IsAncestor $Root $ref.commit 'HEAD') -eq $true) {
            $label = $(if ($ref.phase) { "the checkpoint of $($ref.phase)" } else { 'the base commit (no checkpoint yet)' })
            if ($repo.head -eq $ref.commit) { [void]$checks.Add((New-RealityCheck 'git.head' 'git' 'ok' (Get-ShortSha $ref.commit) (Get-ShortSha $repo.head) "HEAD is at $label.")) }
            else {
                $n = Get-CommitCount $Root "$($ref.commit)..HEAD"
                if ($inProgress) { [void]$checks.Add((New-RealityCheck 'git.head' 'git' 'warning' (Get-ShortSha $ref.commit) (Get-ShortSha $repo.head) "$n commit(s) after $label while phase $inProgress is open. Checkpoints are made by New-Checkpoint.ps1; these commits were made another way." @("Tell the plugin whether the commits belong to phase $inProgress.", 'Review them (git log) before continuing.'))) }
                else { [void]$checks.Add((New-RealityCheck 'git.head' 'git' 'mismatch' (Get-ShortSha $ref.commit) (Get-ShortSha $repo.head) "HEAD is $n commit(s) after $label, and no phase records them." @('Review the commits (git log) and tell the plugin what they are.', 'If they are unrelated work, move them to another branch yourself.', 'If they belong to the upgrade, say which phase; nothing is recorded or re-run without your decision.'))) }
            }
        }
    }
    # Uncommitted changes outside .umbraco-upgrade/.
    $all = Get-GitStatusEntries -Root $Root -Prefix $repo.prefix
    $entries = @($all | Where-Object { -not $_.inStateFolder })
    if ($entries.Count -gt 0) {
        $paths = @($entries | Select-Object -First 20 | ForEach-Object { "$($_.code.Trim()) $($_.path)" })
        if ($inProgress) { [void]$checks.Add((New-RealityCheck 'git.working-tree' 'git' 'warning' 'clean or the open phase''s changes' "$($entries.Count) uncommitted change(s)" "Uncommitted changes while phase $inProgress is open; they are probably that phase's unfinished work: $($paths -join '; ')" @("Tell the plugin whether these changes are phase $inProgress's work.", 'Never discard them to make state agree; the plugin will not.'))) }
        else { [void]$checks.Add((New-RealityCheck 'git.working-tree' 'git' 'mismatch' 'no uncommitted changes outside .umbraco-upgrade/' "$($entries.Count) uncommitted change(s)" "Uncommitted changes that no open phase explains: $($paths -join '; ')" @('Commit them or set them aside yourself, then run /umbraco-upgrade:resume again.', 'Tell the plugin which phase they belong to.'))) }
    } else { [void]$checks.Add((New-RealityCheck 'git.working-tree' 'git' 'ok' 'clean' 'clean')) }
    return ,($checks.ToArray())
}

function Test-FileReality {
    param([string]$Root, $State)
    $checks = New-Object System.Collections.ArrayList
    $dir = Get-StateDir $Root
    $g = $State['gates']
    $required = New-Object System.Collections.ArrayList
    if ($g['discovery']['status'] -eq 'passed') { [void]$required.Add('inventory.md') }
    if ($g['versionPath']['status'] -eq 'passed') { [void]$required.Add('decisions.md'); [void]$required.Add('compatibility.md') }
    if ($g['planApproval']['status'] -in @('awaiting-approval', 'approved', 'invalidated')) { [void]$required.Add('plan.md'); [void]$required.Add('risks.md') }
    if ($g['final']['status'] -eq 'passed') { [void]$required.Add('report.md') }
    $missing = New-Object System.Collections.ArrayList
    foreach ($f in $required) { if (-not [System.IO.File]::Exists((Join-Path $dir $f))) { [void]$missing.Add([ordered]@{ path = $f; from = 'gate status' }) } }
    foreach ($r in (Get-EvidenceReferences $State)) {
        $p = $r.path
        if ($p -match '(^|[\\/])\.\.([\\/]|$)' -or [System.IO.Path]::IsPathRooted($p)) { [void]$missing.Add([ordered]@{ path = $p; from = "$($r.from) (not a path inside .umbraco-upgrade/)" }); continue }
        $full = Join-Path $dir $p
        $exists = $(if ($p.EndsWith('/')) { [System.IO.Directory]::Exists($full) } else { [System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full) })
        if (-not $exists) { [void]$missing.Add([ordered]@{ path = $p; from = $r.from }) }
    }
    if ($missing.Count -gt 0) {
        $list = @($missing | Select-Object -First 30 | ForEach-Object { "$($_.path) ($($_.from))" })
        [void]$checks.Add((New-RealityCheck 'files.expected' 'files' 'mismatch' 'every file the state refers to' "$($missing.Count) missing" "Missing under .umbraco-upgrade/: $($list -join '; ')" @('Restore the files from where the folder was kept (the folder policy decides whether git has them).', 'If they are gone, the criteria and gates that cite them are not proven; tell the plugin how to proceed.')))
    } else { [void]$checks.Add((New-RealityCheck 'files.expected' 'files' 'ok' 'every file the state refers to' 'present')) }
    # Decision ids recorded in state (the list, the path, the target facts, the gates) must be written up in
    # decisions.md.
    $cited = @($State['decisions']) + @($State['path']['decision'], $State['target']['lts']['source'], $State['target']['supportEnds']['source'])
    foreach ($gn in @(Get-GateOrder)) { if ($State['gates'][$gn].Contains('decisions')) { $cited += @($State['gates'][$gn]['decisions']) } }
    $ids = @($cited | Where-Object { $_ -and [string]$_ -match '^D-\d{3,}$' } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if ($ids.Count -gt 0) {
        $dec = Join-Path $dir 'decisions.md'
        $text = $(if ([System.IO.File]::Exists($dec)) { Read-TextFile $dec } else { '' })
        $absent = @($ids | Where-Object { $text -notmatch ('(?m)\b' + [regex]::Escape([string]$_) + '\b') })
        if ($absent.Count -gt 0) { [void]$checks.Add((New-RealityCheck 'files.decisions' 'files' 'mismatch' 'every decision id in decisions.md' "missing: $($absent -join ', ')" 'State records decision ids that decisions.md does not describe.' @('Restore decisions.md, or write the missing entries from what the user decided (ask first).'))) }
        else { [void]$checks.Add((New-RealityCheck 'files.decisions' 'files' 'ok' "$($ids.Count) decision(s)" 'described')) }
    }
    # The plan text against the approved hash.
    $pa = $g['planApproval']['status']
    if ($pa -in @('awaiting-approval', 'approved')) {
        $h = Test-PlanHash -ProjectRoot $Root
        if ($h.matches) { [void]$checks.Add((New-RealityCheck 'plan.hash' 'plan' 'ok' 'plan.md as approved' 'unchanged')) }
        else {
            $what = $(if ($null -eq $h.current) { 'plan.md is missing' } else { 'plan.md changed after approval was ' + $(if ($pa -eq 'approved') { 'given' } else { 'requested' }) })
            [void]$checks.Add((New-RealityCheck 'plan.hash' 'plan' 'mismatch' 'plan.md as approved' $what "$what. The recorded approval does not cover the current text." @('Restore the approved plan.md.', 'Or keep the new text: the plugin then requests approval again before anything runs.')))
        }
    } elseif ($pa -eq 'invalidated') {
        [void]$checks.Add((New-RealityCheck 'plan.hash' 'plan' 'warning' 'an approved plan' 'approval invalidated' 'plan.md changed after approval, and the approval was invalidated. Nothing runs until the user approves again.'))
    }
    if ($State['project']['stateFolderPolicy'] -eq 'undecided') { [void]$checks.Add((New-RealityCheck 'files.folder-policy' 'files' 'warning' 'a folder policy' 'undecided' 'The user has not chosen whether to commit, ignore locally, or gitignore .umbraco-upgrade/.' @('Ask the user and record it with Set-StateFolderPolicy.ps1.'))) }
    return ,($checks.ToArray())
}

function Test-PackageReality {
    # The CMS version in the project files against what state implies at this point.
    param([string]$Root, $State)
    $v = Get-UmbracoVersionInfo -Root $Root
    $actual = $v.resolved.version
    if (-not $v.isUmbraco) { return (New-RealityCheck 'packages.version' 'packages' 'mismatch' $State['source']['umbraco'] 'no Umbraco project found' 'Discovery found no Umbraco project files in the folder any more.' @('Check that the command points at the project root, and that no project files were moved or deleted.')) }
    if ($v.resolved.confidence -eq 'conflict') { return (New-RealityCheck 'packages.version' 'packages' 'mismatch' $State['source']['umbraco'] ("conflicting: " + (@($v.resolved.candidates) -join ', ')) 'The project files name different CMS versions.' @('Tell the plugin which version the project is on now; nothing is changed to make them agree.')) }
    $source = [string]$State['source']['umbraco']
    $expected = $source
    $alsoAllowed = @()
    $steps = @{}
    foreach ($s in @($State['path']['steps'])) { if ($s) { $steps[[string]$s['id']] = $s } }
    $map = Get-PhaseStepMap -ProjectRoot $Root
    $framework = @(@($State['phases']) | Where-Object { $_['area'] -eq 'application-framework' })
    $done = @($framework | Where-Object { $_['status'] -eq 'done' })
    $open = @($framework | Where-Object { $_['status'] -in @('in-progress', 'blocked', 'failed') })
    if ($done.Count -gt 0 -and $null -eq $map) { return (New-RealityCheck 'packages.version' 'packages' 'not-checked' $null $actual 'The phase proposal (evidence/planning/phase-composition.json) is missing, so the expected version after the done framework phases is not known.') }
    if ($done.Count -gt 0) {
        $stepId = $map[[string]$done[-1]['id']]
        if ($stepId -and $steps.ContainsKey($stepId)) { $expected = [string]$steps[$stepId]['to'] }
    }
    if ($null -ne $map) { foreach ($o in $open) { $sid = $map[[string]$o['id']]; if ($sid -and $steps.ContainsKey($sid)) { $alsoAllowed += [string]$steps[$sid]['to'] } } }
    if (-not $expected) { return (New-RealityCheck 'packages.version' 'packages' 'not-checked' $null $actual 'State records no source version.') }
    if ($actual -eq $expected -or ($alsoAllowed -contains $actual)) { return (New-RealityCheck 'packages.version' 'packages' 'ok' $expected $actual) }
    if ($open.Count -gt 0 -and $null -eq $map) { return (New-RealityCheck 'packages.version' 'packages' 'warning' $expected $actual "The project files reference $actual while framework phase $($open[0]['id']) is open; without the phase proposal (evidence/planning/phase-composition.json) the version that phase aims for is not known." @("Tell the plugin whether $actual is phase $($open[0]['id'])'s work.")) }
    $newCodebase = ($State['path']['strategy'] -in @('rebuild-with-database-migration', 'new-install-with-content-transfer'))
    $status = $(if ($newCodebase) { 'warning' } else { 'mismatch' })
    $why = $(if ($done.Count -gt 0) { "State expects $expected after phase $($done[-1]['id'])" } else { "State expects the source version $expected (no framework phase is done)" })
    if ($newCodebase) { $why += '; on a new-codebase path the old and new projects can both be present' }
    return (New-RealityCheck 'packages.version' 'packages' $status $expected $actual "$why, but the project files reference $actual." @('Tell the plugin whether the package versions were changed on purpose.', 'If not, restore the project files from the last checkpoint yourself.', 'Nothing is re-run or changed to make the versions agree without your decision.'))
}

function Test-DatabaseReality {
    # Only what can be checked without connecting: whether the declared local copy is still what the configuration
    # points to. The connection string stays in memory and is never printed.
    param([string]$Root, $State)
    $db = $State['source']['database']
    if (-not $db['localCopyDeclared']) { return (New-RealityCheck 'database.local-copy' 'database' 'not-checked' -Detail 'No local database copy is declared, so no database comparison applies.') }
    $web = [string]$State['project']['webProject']
    $projectDir = $(if ($web) { [System.IO.Path]::GetDirectoryName((Join-Path $Root $web)) } else { $Root })
    try {
        $eff = Get-EffectiveConnectionString -ProjectDir $projectDir -Environment 'Development'
        if (-not $eff.connectionString) { return (New-RealityCheck 'database.local-copy' 'database' 'warning' 'a local connection string' 'none found' 'No CMS connection string was found for the Development environment.' @('Check the local configuration before any database step.')) }
        $info = Get-DataSourceInfo -ConnectionString $eff.connectionString -ProviderName $eff.providerName
        if ($info.isLocal -eq $true) { return (New-RealityCheck 'database.local-copy' 'database' 'ok' 'local' "local ($($info.engine), from $($eff.source))" 'The schema version inside the database is not read: the plugin does not query the CMS tables. Test-DatabaseHealth.ps1 gives read-only counts on request.') }
        return (New-RealityCheck 'database.local-copy' 'database' 'mismatch' 'local' "$($info.reason) ($($eff.source))" 'The effective connection string no longer points to a local database. No database step may run until it does.' @('Point the local configuration back to the restored local copy yourself.', 'Never continue against a shared, staging, or production database.'))
    } catch {
        return (New-RealityCheck 'database.local-copy' 'database' 'warning' 'local' 'unreadable' ('The local configuration could not be read: ' + (Protect-Text $_.Exception.Message)))
    }
}

function Test-StateReality {
    # Returns the reconciliation result. Never writes anything.
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath $ProjectRoot
    $result = [ordered]@{ ok = $true; consistent = $false; projectRoot = $root; mode = $null; position = $null; mismatches = 0; warnings = 0; checks = @(); lastEvent = $null
        note = 'Read-only: nothing was changed. Report every mismatch to the user with its options and ask; never repair state, files, or the repository to make them agree, and never repeat a phase on your own.' }
    if (-not (Test-StateExists $root)) { throw "No upgrade state in '$root'. Start with /umbraco-upgrade:start or /umbraco-upgrade:plan." }
    $checks = New-Object System.Collections.ArrayList
    try { $state = Read-UpgradeState $root }
    catch {
        [void]$checks.Add((New-RealityCheck 'state.readable' 'state' 'mismatch' 'a readable state.json' 'unreadable' (Protect-Text $_.Exception.Message) @('Restore state.json from where the folder was kept. The plugin never rewrites it by hand.')))
        $result.checks = @($checks); $result.mismatches = 1
        return $result
    }
    $errs = Test-UpgradeState -State $state
    if ($errs.Count -gt 0) { [void]$checks.Add((New-RealityCheck 'state.valid' 'state' 'mismatch' 'valid against the schema' "$($errs.Count) error(s)" (($errs | Select-Object -First 10) -join '; ') @('Restore state.json from where the folder was kept. Edits by hand are refused by the safety hook for this reason.'))) }
    else { [void]$checks.Add((New-RealityCheck 'state.valid' 'state' 'ok' 'valid' 'valid')) }
    if ([version]([string]$state['schemaVersion']) -lt [version](Get-StateSchemaVersion)) {
        [void]$checks.Add((New-RealityCheck 'state.schema-version' 'state' 'warning' 'the current schema minor' $state['schemaVersion'] 'The state was written by an older plugin version. state.ps1 migrate upgrades it in place; gate 5 does it when it first records results.'))
    }
    $result.mode = $state['mode']
    $position = Get-ResumePosition $state
    $result.position = $position
    $h = @($state['history'])
    if ($h.Count -gt 0) { $result.lastEvent = $h[-1] }
    foreach ($c in (Test-GitReality -Root $root -State $state -Position $position)) { [void]$checks.Add($c) }
    foreach ($c in (Test-FileReality -Root $root -State $state)) { [void]$checks.Add($c) }
    [void]$checks.Add((Test-PackageReality -Root $root -State $state))
    [void]$checks.Add((Test-DatabaseReality -Root $root -State $state))
    $result.checks = @($checks)
    $result.mismatches = @($checks | Where-Object { $_.status -eq 'mismatch' }).Count
    $result.warnings = @($checks | Where-Object { $_.status -eq 'warning' }).Count
    $result.consistent = ($result.mismatches -eq 0)
    return $result
}

Export-ModuleMember -Function Test-StateReality, Get-ResumePosition, Get-PhaseStepMap, Get-EvidenceReferences, Test-CommitExists, Test-IsAncestor, Get-CommitCount
