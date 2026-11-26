# State.psm1 - the only writer of .umbraco-upgrade/state.json.
# Every save validates against schemas/state.schema.json, updates updatedAt, appends history, and writes atomically.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'JsonSchema.psm1') -DisableNameChecking

$script:PluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:SchemaVersion = '1.1.0'
$script:GateOrder = @('discovery', 'versionPath', 'safety', 'planApproval', 'final')
$script:SchemaCache = $null

function Get-StateDir { param([Parameter(Mandatory)][string]$ProjectRoot) return (Join-Path (Resolve-FullPath $ProjectRoot) '.umbraco-upgrade') }
function Get-StatePath { param([Parameter(Mandatory)][string]$ProjectRoot) return (Join-Path (Get-StateDir $ProjectRoot) 'state.json') }
function Test-StateExists { param([Parameter(Mandatory)][string]$ProjectRoot) return [System.IO.File]::Exists((Get-StatePath $ProjectRoot)) }

function Get-PluginVersion {
    $m = Read-JsonFile (Join-Path $script:PluginRoot '.claude-plugin/plugin.json')
    return [string]$m.version
}

function Get-StateSchema {
    if ($null -eq $script:SchemaCache) {
        $script:SchemaCache = ConvertTo-PlainObject (Read-JsonFile (Join-Path $script:PluginRoot 'schemas/state.schema.json'))
    }
    return $script:SchemaCache
}

# ---------------------------------------------------------------- schema validation (subset, in JsonSchema.psm1)

function Test-UpgradeState {
    # Returns an array of error strings; empty means valid.
    param([Parameter(Mandatory)]$State)
    $errors = New-Object System.Collections.ArrayList
    $schema = Get-StateSchema
    Test-SchemaNode -Value $State -Schema $schema -Root $schema -Path '$' -Errors $errors
    # Cross-field rules the subset cannot express.
    if ($State.Contains('gates') -and $State['gates'] -is [System.Collections.IDictionary]) {
        $g = $State['gates']
        if ($g.Contains('safety') -and $g['safety']['status'] -eq 'skipped' -and $State['mode'] -ne 'plan') { [void]$errors.Add('$.gates.safety: skipped is allowed only in plan mode') }
        if ($g.Contains('planApproval') -and $g['planApproval']['status'] -eq 'approved') {
            if (-not $g['planApproval'].Contains('approval') -or -not $g['planApproval']['approval']) { [void]$errors.Add('$.gates.planApproval: approved without an approval id') }
        }
    }
    if ($State.Contains('verification') -and [string]$State['schemaVersion'] -match '^1\.0\.') { [void]$errors.Add('$.verification: needs schema version 1.1.0 or later') }
    $text = ConvertTo-JsonText -InputObject $State -Compress
    if ((Protect-Text $text) -ne $text) { [void]$errors.Add('$: state contains a value that looks like a secret') }
    return ,($errors.ToArray())
}

# ---------------------------------------------------------------- read and write

function Read-UpgradeState {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path = Get-StatePath $ProjectRoot
    if (-not [System.IO.File]::Exists($path)) { throw "No upgrade state at $path. Run state.ps1 init first." }
    $state = ConvertTo-PlainObject (Read-JsonFile $path)
    $ver = [string]$state['schemaVersion']
    if ($ver -notmatch '^1\.') { throw "Unsupported state schema version '$ver'. This plugin reads 1.x." }
    return $state
}

function Add-HistoryEntry {
    param($State, [string]$Event, [string]$Detail)
    $list = New-Object System.Collections.ArrayList
    foreach ($h in @($State['history'])) { [void]$list.Add($h) }
    [void]$list.Add([ordered]@{ at = (Get-UtcTimestamp); event = $Event; detail = $Detail })
    $State['history'] = $list.ToArray()
}

function Save-UpgradeState {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Event, [string]$Detail = $null)
    $State['updatedAt'] = Get-UtcTimestamp
    Add-HistoryEntry -State $State -Event $Event -Detail $Detail
    $errors = Test-UpgradeState -State $State
    if ($errors.Count -gt 0) { throw ("State validation failed: " + ($errors -join '; ')) }
    Write-AtomicTextFile -Path (Get-StatePath $ProjectRoot) -Content (ConvertTo-JsonText -InputObject $State)
    return $State
}

function New-GateRecord { return [ordered]@{ status = 'pending'; at = $null } }

function New-UpgradeState {
    # Creates .umbraco-upgrade/ and state.json. Takes the git status snapshot before writing anything.
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('upgrade', 'plan')][string]$Mode,
        [Parameter(Mandatory)][string]$TargetRequested
    )
    $ProjectRoot = Resolve-FullPath $ProjectRoot
    if (Test-StateExists $ProjectRoot) { throw "State already exists at $(Get-StatePath $ProjectRoot). To continue that upgrade, run /umbraco-upgrade:resume; to start over, move or remove the folder yourself." }
    if ($TargetRequested -notmatch '^\d+(\.\d+){0,2}$') { throw "Invalid target version '$TargetRequested'." }
    # 1. Read-only git snapshot first.
    $repo = Get-GitRepoInfo -Root $ProjectRoot
    $entries = @()
    if ($repo.isRepo) { $entries = Get-GitStatusEntries -Root $ProjectRoot -Prefix $repo.prefix }
    $statusAtStart = 'not-a-repo'
    if ($repo.isRepo) { $statusAtStart = $(if (@($entries).Count -eq 0) { 'clean' } else { 'dirty' }) }
    # 2. Only now write into the project, and only inside .umbraco-upgrade/.
    $dir = Get-StateDir $ProjectRoot
    $evidenceRel = 'evidence/discovery/git-status-at-start.json'
    Write-TextFile -Path (Join-Path $dir $evidenceRel) -Content (ConvertTo-JsonText -InputObject ([ordered]@{
        capturedAt = (Get-UtcTimestamp); isRepo = $repo.isRepo; gitAvailable = $repo.gitAvailable; branch = $repo.branch; head = $repo.head
        detached = $repo.detached; entries = @($entries)
    }))
    Write-TextFile -Path (Join-Path $dir 'README.md') -Content (Get-StateFolderReadme)
    $now = Get-UtcTimestamp
    $state = [ordered]@{
        schemaVersion = $script:SchemaVersion
        plugin = [ordered]@{ name = 'umbraco-upgrade'; version = (Get-PluginVersion) }
        mode = $Mode
        createdAt = $now
        updatedAt = $now
        project = [ordered]@{ root = '.'; solution = $null; webProject = $null; stateFolderPolicy = 'undecided' }
        source = [ordered]@{ umbraco = $null; major = $null; generation = $null; dotnet = @(); database = [ordered]@{ engine = 'unknown'; localCopyDeclared = $false; target = 'unknown' }; evidence = @(); confidence = 'none'; verified = $false }
        target = [ordered]@{ requested = $TargetRequested; resolved = $null; dotnet = $null; lts = [ordered]@{ value = $null; source = $null; verified = $false }; supportEnds = [ordered]@{ value = $null; source = $null; verified = $false }; verified = $false }
        path = [ordered]@{ selection = 'pending'; strategy = 'pending'; steps = @(); alternatives = @(); decision = $null }
        gitBaseline = [ordered]@{ isRepo = $repo.isRepo; repoRoot = $repo.repoRoot; baseBranch = $repo.branch; baseCommit = $repo.head; statusAtStart = $statusAtStart; statusEvidence = $evidenceRel; upgradeBranch = $null }
        gates = [ordered]@{ discovery = (New-GateRecord); versionPath = (New-GateRecord); safety = (New-GateRecord); planApproval = (New-GateRecord); final = (New-GateRecord) }
        phases = @()
        approvals = @()
        decisions = @()
        unresolved = @()
        knowledge = [ordered]@{ baselineVersion = $null; refreshedAt = $null }
        history = @()
    }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'initialized' -Detail "mode=$Mode target=$TargetRequested git=$statusAtStart")
}

function Get-StateFolderReadme {
    return @'
# .umbraco-upgrade

This folder holds the state of an Umbraco upgrade run by the umbraco-upgrade Claude Code plugin.

- `state.json`: machine-readable progress (versions, gates, phases, approvals). Changed only through the plugin's state script.
- `plan.md`, `inventory.md`, `compatibility.md`, `risks.md`, `decisions.md`, `rollback.md`: the upgrade plan and its supporting records.
- `evidence/`: outputs of checks, with secrets redacted.
- `report.md`: the upgrade report (what was verified automatically, verified manually, and not verified).

Nothing in this folder should contain secrets. You decide whether to commit this folder, ignore it locally
(through `.git/info/exclude`), or add it to `.gitignore`. The plugin records your choice in `state.json`.
'@
}

# ---------------------------------------------------------------- gates

function Get-GateIndex { param([string]$Gate) return [array]::IndexOf($script:GateOrder, $Gate) }

function Test-PreviousGatesDone {
    param($State, [string]$Gate)
    $idx = Get-GateIndex $Gate
    for ($i = 0; $i -lt $idx; $i++) {
        $name = $script:GateOrder[$i]
        $s = $State['gates'][$name]['status']
        if ($s -eq 'passed') { continue }
        if ($name -eq 'safety' -and $s -eq 'skipped') { continue }
        if ($name -eq 'planApproval' -and $s -eq 'approved') { continue }
        return "gate '$name' is '$s'"
    }
    return $null
}

function Set-UpgradeGate {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('discovery', 'versionPath', 'safety', 'planApproval', 'final')][string]$Gate,
        [Parameter(Mandatory)][ValidateSet('in-progress', 'passed', 'failed', 'skipped')][string]$Status,
        [string[]]$Evidence = @(),
        [string]$Notes = $null,
        [hashtable]$Fields = @{}
    )
    $state = Read-UpgradeState $ProjectRoot
    $g = $state['gates'][$Gate]
    $current = $g['status']
    if ($Gate -eq 'planApproval' -and $Status -eq 'passed') { throw "Gate planApproval is completed through request-plan-approval and approve, not 'passed'." }
    if ($current -in @('passed', 'approved') -and $Status -ne 'failed') { throw "Gate '$Gate' is already '$current'." }
    if ($Status -in @('in-progress', 'passed', 'skipped')) {
        $blocker = Test-PreviousGatesDone -State $state -Gate $Gate
        if ($blocker) { throw "Cannot set '$Gate' to '$Status': $blocker." }
    }
    if ($Status -eq 'skipped' -and -not ($Gate -eq 'safety' -and $state['mode'] -eq 'plan')) { throw "Only the safety gate can be skipped, and only in plan mode." }
    if ($Gate -eq 'final' -and $Status -in @('in-progress', 'passed')) {
        if ($state['mode'] -ne 'upgrade') { throw 'Gate 5 (final verification) runs only in upgrade mode.' }
        $open = @(@($state['phases']) | Where-Object { $_['status'] -notin @('done', 'deferred') } | ForEach-Object { "$($_['id'])=$($_['status'])" })
        if (@($state['phases']).Count -eq 0) { throw 'Gate 5 needs an executed plan; the state has no phases.' }
        if ($open.Count -gt 0) { throw "Gate 5 starts only when every phase is done or deferred. Open: $($open -join ', ')." }
    }
    if ($Status -eq 'passed') {
        switch ($Gate) {
            'discovery' {
                if (@($Evidence | Where-Object { $_ }).Count -eq 0 -and @($g['evidence'] | Where-Object { $_ }).Count -eq 0) { throw 'Discovery cannot pass without evidence files.' }
            }
            'versionPath' {
                if (-not $state['target']['requested']) { throw 'versionPath cannot pass without a requested target.' }
                if (-not $state['source']['umbraco'] -and $state['source']['confidence'] -ne 'confirmed-by-user') { throw 'versionPath cannot pass without a source version or a user confirmation.' }
                if ($state['source']['confidence'] -eq 'conflict') { throw 'versionPath cannot pass while source version signals conflict. Ask the user and record the confirmed version.' }
                if (-not $state['target']['resolved']) { throw 'versionPath cannot pass without a resolved target version.' }
                if ($null -eq $state['target']['lts']['value'] -or -not $state['target']['dotnet']) { throw 'versionPath cannot pass until the LTS status and the .NET requirement of the target are recorded (from the knowledge, or confirmed by the user from an official page).' }
                if ($state['path']['selection'] -ne 'selected' -or $state['path']['strategy'] -eq 'pending' -or -not $state['path']['decision']) { throw 'versionPath cannot pass without a selected upgrade path and its decision id.' }
            }
            'safety' {
                if ($state['mode'] -ne 'upgrade') { throw 'The safety gate runs only in upgrade mode.' }
                if ($g['guardSelfTest'] -ne 'passed') { throw 'Safety cannot pass: the guard self-test has not passed.' }
                if (-not $state['gitBaseline']['upgradeBranch']) { throw 'Safety cannot pass: no upgrade branch recorded.' }
                if (-not $g['rollbackDoc']) { throw 'Safety cannot pass: no rollback document recorded.' }
            }
            'final' {
                $checks = @(); if ($state.Contains('verification')) { $checks = @($state['verification']['checks']) }
                if ($checks.Count -eq 0) { throw 'Gate 5 cannot pass without a verification checklist (Get-VerificationPlan.ps1, then state.ps1 verification).' }
                $pending = @($checks | Where-Object { $_['result'] -eq 'pending' } | ForEach-Object { $_['id'] })
                if ($pending.Count -gt 0) { throw "Gate 5 cannot pass while checks are pending: $($pending -join ', ')." }
                $failed = @($checks | Where-Object { $_['result'] -eq 'failed' } | ForEach-Object { $_['id'] })
                if ($failed.Count -gt 0) { throw "Gate 5 cannot pass while checks failed: $($failed -join ', '). Fix them through a follow-up phase, or record the user's decision to leave one unverified." }
                if (-not [System.IO.File]::Exists((Join-Path (Get-StateDir $ProjectRoot) 'report.md'))) { throw 'Gate 5 cannot pass without report.md (New-Report.ps1).' }
            }
        }
    }
    $g['status'] = $Status
    $g['at'] = Get-UtcTimestamp
    if (@($Evidence).Count -gt 0) { $g['evidence'] = @(@($g['evidence']) + $Evidence | Where-Object { $_ } | Select-Object -Unique) }
    if ($Notes) { $g['notes'] = $Notes }
    foreach ($k in $Fields.Keys) { $g[$k] = $Fields[$k] }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'gate' -Detail "$Gate=$Status")
}

function Set-GateFields {
    # Updates non-status fields of a gate (for example guardSelfTest, rollbackDoc, pathSelection).
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Gate, [Parameter(Mandatory)][hashtable]$Fields, [string]$Event = 'gate-fields')
    $state = Read-UpgradeState $ProjectRoot
    if (-not $state['gates'].Contains($Gate)) { throw "Unknown gate '$Gate'." }
    foreach ($k in $Fields.Keys) {
        if ($k -eq 'status') { throw 'Use Set-UpgradeGate to change a status.' }
        $state['gates'][$Gate][$k] = $Fields[$k]
    }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event $Event -Detail ("$Gate " + (($Fields.Keys | Sort-Object) -join ',')))
}

# ---------------------------------------------------------------- plan approval

function Get-PlanPath { param([string]$ProjectRoot) return (Join-Path (Get-StateDir $ProjectRoot) 'plan.md') }

function Request-PlanApproval {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $state = Read-UpgradeState $ProjectRoot
    $blocker = Test-PreviousGatesDone -State $state -Gate 'planApproval'
    if ($blocker) { throw "Cannot request plan approval: $blocker." }
    $plan = Get-PlanPath $ProjectRoot
    if (-not [System.IO.File]::Exists($plan)) { throw 'plan.md does not exist.' }
    $hash = Get-FileSha256 $plan
    $g = $state['gates']['planApproval']
    if ($g['status'] -eq 'approved') { throw 'The plan is already approved.' }
    $g['status'] = 'awaiting-approval'
    $g['at'] = Get-UtcTimestamp
    $g['planSha256'] = $hash
    $g['approval'] = $null
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'plan-approval-requested' -Detail "sha256=$hash")
}

function Get-NextId {
    param([object[]]$Existing, [string]$Prefix)
    $max = 0
    foreach ($e in @($Existing)) {
        $id = $e; if ($e -is [System.Collections.IDictionary]) { $id = $e['id'] }
        if ($id -match ("^" + [regex]::Escape($Prefix) + "-(\d+)$")) { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } }
    }
    return ('{0}-{1:000}' -f $Prefix, ($max + 1))
}

function Add-Approval {
    # Records a decision the user gave in chat. For start-plan-execution the scope is bound to the plan hash.
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('approved', 'rejected')][string]$Decision,
        [string]$Scope = '',
        [string]$Note = $null
    )
    $state = Read-UpgradeState $ProjectRoot
    $now = Get-UtcTimestamp
    if ($Action -eq 'start-plan-execution') {
        $g = $state['gates']['planApproval']
        if ($state['mode'] -ne 'upgrade') { throw 'Plan approval for execution exists only in upgrade mode. In plan mode, run /umbraco-upgrade:start.' }
        if ($g['status'] -ne 'awaiting-approval') { throw "Plan approval is '$($g['status'])', not awaiting approval." }
        $hash = Get-FileSha256 (Get-PlanPath $ProjectRoot)
        if ($hash -ne $g['planSha256']) { throw 'plan.md changed after approval was requested. Request approval again.' }
        $Scope = "plan.md sha256 $hash"
    }
    if (-not $Scope) { throw 'An approval needs a scope.' }
    $id = Get-NextId -Existing $state['approvals'] -Prefix 'A'
    $rec = [ordered]@{ id = $id; action = $Action; scope = $Scope; requestedAt = $now; decision = $Decision; decidedAt = $now; consumed = $false; note = $Note }
    $state['approvals'] = @(@($state['approvals']) + $rec)
    if ($Action -eq 'start-plan-execution') {
        $state['gates']['planApproval']['status'] = $(if ($Decision -eq 'approved') { 'approved' } else { 'rejected' })
        $state['gates']['planApproval']['at'] = $now
        $state['gates']['planApproval']['approval'] = $id
    }
    [void](Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'approval' -Detail "$id $Action $Decision")
    return $rec
}

function Test-ApprovalAvailable {
    # Returns the matching approved, unconsumed approval, or $null. -Consume marks it used.
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Action, [string]$Scope = '', [switch]$Consume)
    $state = Read-UpgradeState $ProjectRoot
    foreach ($a in @($state['approvals'])) {
        if ($a['action'] -ne $Action -or $a['decision'] -ne 'approved' -or $a['consumed']) { continue }
        if ($Scope -and $a['scope'] -ne $Scope) { continue }
        if ($Action -eq 'start-plan-execution') {
            $check = Test-PlanHash -ProjectRoot $ProjectRoot
            if (-not $check.matches) { return $null }
        }
        if ($Consume) {
            $a['consumed'] = $true
            [void](Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'approval-consumed' -Detail $a['id'])
        }
        return $a
    }
    return $null
}

function Test-PlanHash {
    # Compares plan.md with the hash bound to the approval. -Invalidate marks an approved plan invalidated on mismatch.
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$Invalidate)
    $state = Read-UpgradeState $ProjectRoot
    $g = $state['gates']['planApproval']
    $recorded = $null; if ($g.Contains('planSha256')) { $recorded = $g['planSha256'] }
    $plan = Get-PlanPath $ProjectRoot
    $current = $null; if ([System.IO.File]::Exists($plan)) { $current = Get-FileSha256 $plan }
    $result = [ordered]@{ recorded = $recorded; current = $current; matches = ($null -ne $recorded -and $recorded -eq $current); status = $g['status'] }
    if ($Invalidate -and -not $result.matches -and $g['status'] -in @('approved', 'awaiting-approval')) {
        $g['status'] = 'invalidated'
        $g['at'] = Get-UtcTimestamp
        [void](Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'plan-approval-invalidated' -Detail 'plan.md changed after approval')
        $result.status = 'invalidated'
    }
    return $result
}

# ---------------------------------------------------------------- adopting a plan-only run

function Test-PlanTargetMatch {
    # True when a requested target names the target of the recorded run: its requested or its resolved version.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$TargetRequested)
    return ($TargetRequested -in @([string]$State['target']['requested'], [string]$State['target']['resolved']))
}

function Convert-PlanToUpgrade {
    # /umbraco-upgrade:start adopts a plan-only run: the mode becomes upgrade, and gate 3 and gate 4 go back to
    # pending, so the safety setup runs and the plan is approved before anything executes. Discovery, the version
    # path, decisions, unresolved items, phases, and the plan files stay as they are.
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$TargetRequested)
    $state = Read-UpgradeState $ProjectRoot
    if ($state['mode'] -ne 'plan') { throw "The state is in '$($state['mode'])' mode; only a plan-only run can be adopted. To continue it, run /umbraco-upgrade:resume." }
    if (-not (Test-PlanTargetMatch -State $state -TargetRequested $TargetRequested)) {
        throw "The plan-only run is for target $($state['target']['requested']), not $TargetRequested. Run /umbraco-upgrade:start $($state['target']['requested']) to use it, or move the folder aside to start over."
    }
    $sg = $state['gates']['safety']
    $sg['status'] = 'pending'; $sg['at'] = $null
    if ($sg.Contains('notes')) { $sg.Remove('notes') }
    $pg = $state['gates']['planApproval']
    $hash = $null; if ($pg.Contains('planSha256')) { $hash = $pg['planSha256'] }
    $pg['status'] = 'pending'; $pg['at'] = $null
    foreach ($k in @('planSha256', 'approval')) { if ($pg.Contains($k)) { $pg.Remove($k) } }
    $state['mode'] = 'upgrade'
    $detail = "plan-only run adopted for target $TargetRequested; safety and planApproval set back to pending"
    if ($hash) { $detail += "; plan.md sha256 was $hash" }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'plan-adopted' -Detail $detail)
}

# ---------------------------------------------------------------- sections, decisions, unresolved, phases

$script:MergeableSections = @('project', 'source', 'target', 'path', 'gitBaseline', 'knowledge')

function Update-StateSection {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)]$Values)
    if ($script:MergeableSections -notcontains $Section) { throw "Section '$Section' cannot be set directly. Allowed: $($script:MergeableSections -join ', ')." }
    $state = Read-UpgradeState $ProjectRoot
    $plain = ConvertTo-PlainObject $Values
    if ($Section -eq 'gitBaseline' -and $plain.Contains('statusAtStart')) { throw 'gitBaseline.statusAtStart is recorded at init and cannot change.' }
    foreach ($k in $plain.Keys) {
        if ($state[$Section].Contains($k) -and $state[$Section][$k] -is [System.Collections.IDictionary] -and $plain[$k] -is [System.Collections.IDictionary]) {
            foreach ($k2 in $plain[$k].Keys) { $state[$Section][$k][$k2] = $plain[$k][$k2] }
        } else {
            $state[$Section][$k] = $plain[$k]
        }
    }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'set' -Detail ("$Section " + (($plain.Keys | Sort-Object) -join ',')))
}

function Add-Decision {
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Gate = $null)
    $state = Read-UpgradeState $ProjectRoot
    $id = Get-NextId -Existing $state['decisions'] -Prefix 'D'
    $state['decisions'] = @(@($state['decisions']) + $id)
    if ($Gate) {
        $g = $state['gates'][$Gate]
        $existing = @(); if ($g.Contains('decisions')) { $existing = @($g['decisions']) }
        $g['decisions'] = @($existing + $id)
    }
    [void](Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'decision' -Detail $id)
    return $id
}

function Add-Unresolved {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Item, [string]$Pattern = $null, [ValidateSet('undecided', 'port', 'replace', 'redesign')][string]$Proposal = 'undecided')
    $state = Read-UpgradeState $ProjectRoot
    $id = Get-NextId -Existing $state['unresolved'] -Prefix 'U'
    $state['unresolved'] = @(@($state['unresolved']) + [ordered]@{ id = $id; pattern = $Pattern; item = $Item; proposal = $Proposal; status = 'awaiting-user' })
    [void](Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'unresolved' -Detail $id)
    return $id
}

function ConvertTo-SortedJson {
    # Compact JSON with dictionary keys sorted, for comparing records whatever order their keys were written in.
    param($Value)
    $sort = $null
    $sort = {
        param($v)
        if ($v -is [System.Collections.IDictionary]) { $h = [ordered]@{}; foreach ($k in (@($v.Keys) | Sort-Object)) { $h[[string]$k] = & $sort $v[$k] }; return $h }
        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) { return ,@(@($v) | ForEach-Object { & $sort $_ }) }
        return $v
    }
    return (ConvertTo-JsonText -InputObject (& $sort (ConvertTo-PlainObject $Value)) -Compress)
}

function Set-UpgradePhases {
    # Replaces the phase list while the plan is being composed (before approval).
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Phases)
    $state = Read-UpgradeState $ProjectRoot
    if ($state['gates']['planApproval']['status'] -eq 'approved') { throw 'Phases are frozen after plan approval.' }
    $list = ConvertTo-PlainObject $Phases
    if ($list -is [System.Collections.IDictionary]) { $list = @($list) }
    # After execution started (a re-approval of an amended plan), phases that ran stay exactly as recorded and in
    # the same order; only phases that never started may change, and new ones are added after them.
    $ran = @(@($state['phases']) | Where-Object { $_['status'] -ne 'pending' })
    foreach ($old in $ran) {
        $new = @($list | Where-Object { $_['id'] -eq $old['id'] }) | Select-Object -First 1
        if ($null -eq $new) { throw "Phase $($old['id']) has run ($($old['status'])) and cannot be removed from the plan." }
        if ((ConvertTo-SortedJson $new) -ne (ConvertTo-SortedJson $old)) { throw "Phase $($old['id']) has run ($($old['status'])) and must stay exactly as recorded. Take the list from state.ps1 get -Field phases and add new phases after it." }
    }
    for ($i = 0; $i -lt $ran.Count; $i++) {
        if ($i -ge @($list).Count -or $list[$i]['id'] -ne @($state['phases'])[$i]['id']) { throw 'Phases that have run must keep their order at the start of the list.' }
    }
    foreach ($p in $list) {
        if (-not $p.Contains('status')) { $p['status'] = 'pending' }
        if (-not $p.Contains('startedAt')) { $p['startedAt'] = $null }
        if (-not $p.Contains('completedAt')) { $p['completedAt'] = $null }
        if (-not $p.Contains('checkpoint')) { $p['checkpoint'] = [ordered]@{ commit = $null } }
        if (-not $p.Contains('failures')) { $p['failures'] = @() }
        foreach ($ac in @($p['acceptanceCriteria'])) { if (-not $ac.Contains('status')) { $ac['status'] = 'pending' } }
    }
    $state['phases'] = $list
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'phases' -Detail ("count=" + $list.Count))
}

function Set-PhaseStatus {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$PhaseId, [Parameter(Mandatory)][ValidateSet('in-progress', 'blocked', 'done', 'failed', 'deferred')][string]$Status)
    $state = Read-UpgradeState $ProjectRoot
    if ($state['gates']['planApproval']['status'] -ne 'approved') { throw 'Phases can start only after the plan is approved.' }
    $phase = @($state['phases']) | Where-Object { $_['id'] -eq $PhaseId } | Select-Object -First 1
    if ($null -eq $phase) { throw "Unknown phase '$PhaseId'." }
    if ($Status -eq 'in-progress') {
        $check = Test-PlanHash -ProjectRoot $ProjectRoot
        if (-not $check.matches) { throw 'plan.md changed after approval. The approval no longer covers it; request approval again.' }
        if ($state['gates']['safety']['status'] -ne 'passed') { throw 'Phases can start only after gate 3 (safety setup) has passed.' }
        if ($state['gates']['final']['status'] -in @('in-progress', 'passed')) { throw "Gate 5 is '$($state['gates']['final']['status'])'. A follow-up phase starts only after gate 5 is set back to failed with the reason (state.ps1 gate -Gate final -Status failed -Notes ...)." }
        foreach ($p in @($state['phases'])) {
            if ($p['id'] -eq $PhaseId) { break }
            if ($p['status'] -notin @('done', 'deferred')) { throw "Phase $($p['id']) is '$($p['status'])'. Phases run in plan order; finish or defer it first." }
        }
    }
    if ($Status -eq 'done') {
        $open = @($phase['acceptanceCriteria'] | Where-Object { $_['status'] -notin @('met', 'waived') })
        if ($open.Count -gt 0) { throw "Phase $PhaseId has unmet acceptance criteria: $((@($open) | ForEach-Object { $_['id'] }) -join ', ')." }
        if (-not $phase['checkpoint']['commit']) { throw "Phase $PhaseId has no checkpoint commit." }
        $phase['completedAt'] = Get-UtcTimestamp
    }
    if ($Status -eq 'in-progress' -and -not $phase['startedAt']) { $phase['startedAt'] = Get-UtcTimestamp }
    $phase['status'] = $Status
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'phase' -Detail "$PhaseId=$Status")
}

function Set-AcceptanceCriterion {
    # Records the result of one acceptance criterion. met needs evidence files under .umbraco-upgrade/; waived needs
    # the user's words in -Note (a waiver is the user's decision, never the agent's).
    param(
        [Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$PhaseId, [Parameter(Mandatory)][string]$CriterionId,
        [Parameter(Mandatory)][ValidateSet('met', 'not-met', 'waived', 'pending')][string]$Status, [string[]]$Evidence = @(), [string]$Note = ''
    )
    $state = Read-UpgradeState $ProjectRoot
    if ($state['gates']['planApproval']['status'] -ne 'approved') { throw 'Acceptance criteria are recorded only after the plan is approved.' }
    $phase = @($state['phases']) | Where-Object { $_['id'] -eq $PhaseId } | Select-Object -First 1
    if ($null -eq $phase) { throw "Unknown phase '$PhaseId'." }
    if ($phase['status'] -ne 'in-progress') { throw "Phase $PhaseId is '$($phase['status'])', not in progress." }
    $ac = @($phase['acceptanceCriteria']) | Where-Object { $_['id'] -eq $CriterionId } | Select-Object -First 1
    if ($null -eq $ac) { throw "Unknown acceptance criterion '$CriterionId' in phase $PhaseId." }
    $ev = @($Evidence | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $dir = Get-StateDir $ProjectRoot
    foreach ($e in $ev) {
        if ($e -match '(^|[\\/])\.\.([\\/]|$)' -or [System.IO.Path]::IsPathRooted($e)) { throw "Evidence '$e' must be a path relative to .umbraco-upgrade/." }
        if (-not [System.IO.File]::Exists((Join-Path $dir $e))) { throw "Evidence file '$e' does not exist under .umbraco-upgrade/." }
    }
    if ($Status -eq 'met' -and $ev.Count -eq 0) { throw "Criterion $CriterionId can be met only with evidence (write it with Write-Evidence.ps1 first)." }
    if ($Status -eq 'waived' -and -not $Note.Trim()) { throw 'A waiver needs the user''s words in -Note.' }
    $ac['status'] = $Status
    if ($ev.Count -gt 0) { $ac['evidence'] = @(@($ac['evidence']) + $ev | Where-Object { $_ } | Select-Object -Unique) }
    $detail = "$PhaseId $CriterionId=$Status"
    if ($Note) { $detail += " note: $Note" }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'criterion' -Detail $detail)
}

function Add-PhaseFailure {
    # Records a failure with its recovery steps (A7). The phase keeps its status unless -Status is given.
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$PhaseId, [Parameter(Mandatory)][string]$Summary, [Parameter(Mandatory)][string]$Recovery, [string]$EvidenceFile = $null)
    $state = Read-UpgradeState $ProjectRoot
    $phase = @($state['phases']) | Where-Object { $_['id'] -eq $PhaseId } | Select-Object -First 1
    if ($null -eq $phase) { throw "Unknown phase '$PhaseId'." }
    $rec = [ordered]@{ at = (Get-UtcTimestamp); summary = $Summary; recovery = $Recovery; evidence = $(if ($EvidenceFile) { $EvidenceFile } else { $null }) }
    $phase['failures'] = @(@($phase['failures']) + $rec)
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'phase-failure' -Detail "$PhaseId $Summary")
}

function Set-UnresolvedStatus {
    # Updates an unresolved item after the user answered. The decision text and its sources go to decisions.md.
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Id, [ValidateSet('awaiting-user', 'decided', 'resolved', 'deferred')][string]$Status = 'decided', [ValidateSet('', 'undecided', 'port', 'replace', 'redesign')][string]$Proposal = '', [string]$Decision = '')
    $state = Read-UpgradeState $ProjectRoot
    $u = @($state['unresolved']) | Where-Object { $_['id'] -eq $Id } | Select-Object -First 1
    if ($null -eq $u) { throw "Unknown unresolved item '$Id'." }
    if ($Status -in @('decided', 'resolved') -and -not $Decision) { throw "Give the decision id (-Decision D-xxx) that records the user's answer in decisions.md." }
    if ($Decision -and @($state['decisions']) -notcontains $Decision) { throw "Unknown decision '$Decision'." }
    $u['status'] = $Status
    if ($Proposal) { $u['proposal'] = $Proposal }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'unresolved-update' -Detail "$Id=$Status $Decision")
}

function Set-PhaseCheckpoint {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$PhaseId, [Parameter(Mandatory)][string]$Commit)
    if ($Commit -notmatch '^[0-9a-f]{7,64}$') { throw "Invalid commit id '$Commit'." }
    $state = Read-UpgradeState $ProjectRoot
    $phase = @($state['phases']) | Where-Object { $_['id'] -eq $PhaseId } | Select-Object -First 1
    if ($null -eq $phase) { throw "Unknown phase '$PhaseId'." }
    $phase['checkpoint'] = [ordered]@{ commit = $Commit }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'checkpoint' -Detail "$PhaseId $Commit")
}

# ---------------------------------------------------------------- gate 5 verification

function Set-VerificationChecks {
    # Records the gate 5 checklist composed by Get-VerificationPlan.ps1. Only while gate 5 is in progress; a new
    # list replaces the old one (earlier results stay in history and in the evidence).
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Checks)
    $state = Read-UpgradeState $ProjectRoot
    if ($state['gates']['final']['status'] -ne 'in-progress') { throw "Gate 5 is '$($state['gates']['final']['status'])'. Start it first: state.ps1 gate -Gate final -Status in-progress." }
    $list = ConvertTo-PlainObject $Checks
    if ($list -is [System.Collections.IDictionary]) { $list = @($list) }
    if (@($list).Count -eq 0) { throw 'The verification checklist is empty.' }
    $seen = @{}
    foreach ($c in @($list)) {
        foreach ($k in @('id', 'rule', 'category', 'title', 'method')) { if (-not $c.Contains($k) -or -not $c[$k]) { throw "A verification check has no '$k'." } }
        if ($seen.ContainsKey($c['id'])) { throw "Duplicate verification check id '$($c['id'])'." }
        $seen[$c['id']] = $true
        $c['result'] = 'pending'
        foreach ($k in @('note', 'recovery', 'recordedAt')) { $c[$k] = $null }
        $c['evidence'] = @()
    }
    if ([version]([string]$state['schemaVersion']) -lt [version]'1.1.0') {
        $from = [string]$state['schemaVersion']
        $state['schemaVersion'] = $script:SchemaVersion
        Add-HistoryEntry -State $state -Event 'schema-migrated' -Detail "$from -> $script:SchemaVersion (verification records)"
    }
    $state['verification'] = [ordered]@{ composedAt = (Get-UtcTimestamp); checks = @($list) }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'verification' -Detail ("checks=" + @($list).Count))
}

function Set-VerificationResult {
    # Records the result of one gate 5 check.
    #   verified: automated checks only through Invoke-Verification.ps1 (-ByScript); manual checks need evidence under
    #             .umbraco-upgrade/ and the user's words in -Note
    #   failed: what failed in -Note and how to recover in -Recovery
    #   not-verified: why not in -Note (for an earlier failure, the user's decision to leave it unverified)
    param(
        [Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][ValidateSet('verified', 'failed', 'not-verified')][string]$Result,
        [string[]]$Evidence = @(), [string]$Note = '', [string]$Recovery = '', [switch]$ByScript
    )
    $state = Read-UpgradeState $ProjectRoot
    if ($state['gates']['final']['status'] -ne 'in-progress') { throw "Gate 5 is '$($state['gates']['final']['status'])', not in progress." }
    if (-not $state.Contains('verification')) { throw 'No verification checklist is recorded (state.ps1 verification).' }
    $c = @($state['verification']['checks']) | Where-Object { $_['id'] -eq $CheckId } | Select-Object -First 1
    if ($null -eq $c) { throw "Unknown verification check '$CheckId'." }
    $ev = @($Evidence | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $dir = Get-StateDir $ProjectRoot
    foreach ($e in $ev) {
        if ($e -match '(^|[\\/])\.\.([\\/]|$)' -or [System.IO.Path]::IsPathRooted($e)) { throw "Evidence '$e' must be a path relative to .umbraco-upgrade/." }
        if (-not [System.IO.File]::Exists((Join-Path $dir $e))) { throw "Evidence file '$e' does not exist under .umbraco-upgrade/." }
    }
    switch ($Result) {
        'verified' {
            if ($c['method'] -eq 'automated' -and -not $ByScript) { throw "Check $CheckId is automated: Invoke-Verification.ps1 records its result from the evidence it checks. Record a failure or a reason it was not verified instead." }
            if ($ev.Count -eq 0) { throw "Check $CheckId can be verified only with evidence (for a manual check, write the user's confirmation with Write-Evidence.ps1 first)." }
            if ($c['method'] -eq 'manual' -and -not $Note.Trim()) { throw 'A manual check is verified only with the user''s words in -Note.' }
        }
        'failed' {
            if (-not $Note.Trim()) { throw 'A failed check needs what failed in -Note.' }
            if (-not $Recovery.Trim()) { throw 'A failed check needs the recovery steps in -Recovery.' }
        }
        'not-verified' { if (-not $Note.Trim()) { throw 'A check that is not verified needs the reason in -Note.' } }
    }
    $c['result'] = $Result
    $c['evidence'] = @($ev)
    $c['note'] = $(if ($Note) { $Note } else { $null })
    $c['recovery'] = $(if ($Recovery) { $Recovery } else { $null })
    $c['recordedAt'] = Get-UtcTimestamp
    $detail = "$CheckId=$Result"
    if ($Note) { $detail += " note: $Note" }
    return (Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'verification-result' -Detail $detail)
}

function Update-StateSchemaVersion {
    # Upgrades older 1.x minors in place. 1.0.0 to 1.1.0 adds the optional verification section, so only the
    # version changes.
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $state = Read-UpgradeState $ProjectRoot
    $from = [string]$state['schemaVersion']
    if ($from -eq $script:SchemaVersion) { return [ordered]@{ from = $from; to = $from; changed = $false } }
    $fromV = [version]$from; $toV = [version]$script:SchemaVersion
    if ($fromV -gt $toV) { throw "State schema $from is newer than this plugin supports ($script:SchemaVersion). Update the plugin." }
    $state['schemaVersion'] = $script:SchemaVersion
    [void](Save-UpgradeState -ProjectRoot $ProjectRoot -State $state -Event 'schema-migrated' -Detail "$from -> $script:SchemaVersion")
    return [ordered]@{ from = $from; to = $script:SchemaVersion; changed = $true }
}

function Get-GateOrder { return $script:GateOrder }
function Get-StateSchemaVersion { return $script:SchemaVersion }

Export-ModuleMember -Function Get-StateDir, Get-StatePath, Test-StateExists, Get-PluginVersion, Get-StateSchema, Test-UpgradeState, Read-UpgradeState, Save-UpgradeState, New-UpgradeState, Set-UpgradeGate, Set-GateFields, Request-PlanApproval, Add-Approval, Test-ApprovalAvailable, Test-PlanHash, Test-PlanTargetMatch, Convert-PlanToUpgrade, Update-StateSection, Add-Decision, Add-Unresolved, Set-UpgradePhases, Set-PhaseStatus, Set-PhaseCheckpoint, Set-AcceptanceCriterion, Add-PhaseFailure, Set-UnresolvedStatus, Set-VerificationChecks, Set-VerificationResult, Update-StateSchemaVersion, Get-PlanPath, Get-GateOrder, Get-StateSchemaVersion
