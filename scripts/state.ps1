<#
.SYNOPSIS
  State CLI for the umbraco-upgrade plugin. The only supported way to change .umbraco-upgrade/state.json.

.DESCRIPTION
  Prints one JSON object to stdout: { "ok": true, ... } or { "ok": false, "error": "..." }.
  Exit code 0 on success, 1 on a refused or invalid operation.

  Commands:
    init                   -Mode upgrade|plan -Target <version>
    get                    [-Field dotted.path]
    validate
    gate                   -Gate <name> -Status in-progress|passed|failed|skipped [-Evidence a,b] [-Notes text]
    gate-fields            -Gate <name> -Set "key=value;key2=value2"
    request-plan-approval
    approve                -Action <action> -Decision approved|rejected [-Scope text] [-Note text]
    require-approval       -Action <action> [-Scope text] [-Consume]
    check-plan             [-Invalidate]
    set                    -Section <section> (-Set "k=v;a.b=v" | -JsonFile path)
    decision               [-Gate <name>]
    unresolved             -Item text [-Pattern id] [-Proposal port|replace|redesign]
    phases                 -JsonFile path
    phase                  -PhaseId P1 -Status in-progress|blocked|done|failed|deferred
    checkpoint             -PhaseId P1 -Commit <sha>   (New-Checkpoint.ps1 commits and calls this)
    criterion              -PhaseId P1 -CriterionId P1-AC1 -Status met|not-met|waived|pending [-Evidence a,b] [-Note text]
    phase-failure          -PhaseId P1 -Summary text -Recovery text [-EvidenceFile path]
    unresolved-update      -Id U-001 -Status decided|resolved|deferred|awaiting-user [-Proposal port|replace|redesign] [-DecisionId D-001]
    verification           -JsonFile path   (gate 5 checklist from Get-VerificationPlan.ps1)
    verify-check           -CheckId V-01 -Result verified|failed|not-verified [-Evidence a,b] [-Note text] [-Recovery text]
                           (automated checks are verified only by Invoke-Verification.ps1)
    migrate
    session-marker         -SessionId <id> -DataDir <plugin data dir> [-Remove]

  Values in -Set: integers, true, false, and null are typed; everything else is a string.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('init', 'get', 'validate', 'gate', 'gate-fields', 'request-plan-approval', 'approve', 'require-approval', 'check-plan', 'set', 'decision', 'unresolved', 'unresolved-update', 'phases', 'phase', 'checkpoint', 'criterion', 'phase-failure', 'verification', 'verify-check', 'migrate', 'session-marker')]
    [string]$Command,
    [string]$ProjectRoot = '',
    [string]$Mode, [string]$Target,
    [string]$Gate, [string]$Status, [string[]]$Evidence = @(), [string]$Notes,
    [string]$Action, [string]$Decision, [string]$Scope = '', [string]$Note, [switch]$Consume,
    [string]$Section, [string]$Set, [string]$JsonFile,
    [string]$Item, [string]$Pattern, [string]$Proposal = 'undecided',
    [string]$PhaseId, [string]$Commit,
    [string]$CriterionId, [string]$Summary, [string]$Recovery, [string]$EvidenceFile,
    [string]$Id, [string]$DecisionId,
    [string]$CheckId, [string]$Result,
    [string]$Field,
    [string]$SessionId, [string]$DataDir, [switch]$Remove,
    [switch]$Invalidate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking

function ConvertFrom-SetString {
    param([string]$Text)
    $h = [ordered]@{}
    foreach ($pair in ($Text -split ';')) {
        if (-not $pair.Trim()) { continue }
        $idx = $pair.IndexOf('=')
        if ($idx -lt 1) { throw "Invalid -Set entry '$pair'. Use key=value." }
        $key = $pair.Substring(0, $idx).Trim()
        $raw = $pair.Substring($idx + 1).Trim()
        $val = $raw
        if ($raw -match '^-?\d+$') { $val = [int]$raw }
        elseif ($raw -ieq 'true') { $val = $true }
        elseif ($raw -ieq 'false') { $val = $false }
        elseif ($raw -ieq 'null') { $val = $null }
        $node = $h
        $segs = $key -split '\.'
        for ($i = 0; $i -lt $segs.Count - 1; $i++) {
            if (-not $node.Contains($segs[$i])) { $node[$segs[$i]] = [ordered]@{} }
            $node = $node[$segs[$i]]
        }
        $node[$segs[-1]] = $val
    }
    return $h
}

function Get-InputValues {
    if ($JsonFile) { return (ConvertTo-PlainObject (Read-JsonFile $JsonFile)) }
    if ($Set) { return (ConvertFrom-SetString $Set) }
    throw 'Provide -Set or -JsonFile.'
}

function Get-FieldValue {
    param($State, [string]$Dotted)
    $node = $State
    foreach ($seg in ($Dotted -split '\.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($seg)) { $node = $node[$seg] }
        else { throw "Field '$Dotted' not found." }
    }
    return $node
}

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $ProjectRoot = Resolve-FullPath $ProjectRoot
    $out = [ordered]@{ ok = $true; command = $Command }
    switch ($Command) {
        'init' {
            if (-not $Mode -or -not $Target) { throw 'init needs -Mode and -Target.' }
            $s = New-UpgradeState -ProjectRoot $ProjectRoot -Mode $Mode -TargetRequested $Target
            $out.statePath = Get-StatePath $ProjectRoot
            $out.gitBaseline = $s['gitBaseline']
        }
        'get' {
            $s = Read-UpgradeState $ProjectRoot
            if ($Field) { $out.field = $Field; $out.value = Get-FieldValue $s $Field } else { $out.state = $s }
        }
        'validate' {
            $s = Read-UpgradeState $ProjectRoot
            $errs = Test-UpgradeState -State $s
            $out.valid = ($errs.Count -eq 0)
            $out.errors = @($errs)
            if ($errs.Count -gt 0) { $out.ok = $false }
        }
        'gate' {
            if (-not $Gate -or -not $Status) { throw 'gate needs -Gate and -Status.' }
            $ev = @($Evidence | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
            $s = Set-UpgradeGate -ProjectRoot $ProjectRoot -Gate $Gate -Status $Status -Evidence $ev -Notes $Notes
            $out.gate = $Gate; $out.value = $s['gates'][$Gate]
        }
        'gate-fields' {
            if (-not $Gate -or -not $Set) { throw 'gate-fields needs -Gate and -Set.' }
            $h = @{}
            $vals = ConvertFrom-SetString $Set
            foreach ($k in $vals.Keys) { $h[$k] = $vals[$k] }
            $s = Set-GateFields -ProjectRoot $ProjectRoot -Gate $Gate -Fields $h
            $out.gate = $Gate; $out.value = $s['gates'][$Gate]
        }
        'request-plan-approval' {
            $s = Request-PlanApproval -ProjectRoot $ProjectRoot
            $out.value = $s['gates']['planApproval']
        }
        'approve' {
            if (-not $Action -or -not $Decision) { throw 'approve needs -Action and -Decision.' }
            $out.approval = Add-Approval -ProjectRoot $ProjectRoot -Action $Action -Decision $Decision -Scope $Scope -Note $Note
        }
        'require-approval' {
            if (-not $Action) { throw 'require-approval needs -Action.' }
            $a = Test-ApprovalAvailable -ProjectRoot $ProjectRoot -Action $Action -Scope $Scope -Consume:$Consume
            if ($null -eq $a) { $out.ok = $false; $out.error = "No approved, unused approval for '$Action'." } else { $out.approval = $a }
        }
        'check-plan' {
            $out.plan = Test-PlanHash -ProjectRoot $ProjectRoot -Invalidate:$Invalidate
            if (-not $out.plan.matches) { $out.ok = $false; $out.error = 'plan.md does not match the recorded hash.' }
        }
        'set' {
            if (-not $Section) { throw 'set needs -Section.' }
            $s = Update-StateSection -ProjectRoot $ProjectRoot -Section $Section -Values (Get-InputValues)
            $out.section = $Section; $out.value = $s[$Section]
        }
        'decision' {
            $out.id = Add-Decision -ProjectRoot $ProjectRoot -Gate $Gate
        }
        'unresolved' {
            if (-not $Item) { throw 'unresolved needs -Item.' }
            $out.id = Add-Unresolved -ProjectRoot $ProjectRoot -Item $Item -Pattern $Pattern -Proposal $Proposal
        }
        'phases' {
            if (-not $JsonFile) { throw 'phases needs -JsonFile.' }
            $s = Set-UpgradePhases -ProjectRoot $ProjectRoot -Phases (Read-JsonFile $JsonFile)
            $out.count = @($s['phases']).Count
        }
        'phase' {
            if (-not $PhaseId -or -not $Status) { throw 'phase needs -PhaseId and -Status.' }
            [void](Set-PhaseStatus -ProjectRoot $ProjectRoot -PhaseId $PhaseId -Status $Status)
            $out.phase = $PhaseId; $out.status = $Status
        }
        'checkpoint' {
            if (-not $PhaseId -or -not $Commit) { throw 'checkpoint needs -PhaseId and -Commit.' }
            [void](Set-PhaseCheckpoint -ProjectRoot $ProjectRoot -PhaseId $PhaseId -Commit $Commit)
            $out.phase = $PhaseId; $out.commit = $Commit
        }
        'criterion' {
            if (-not $PhaseId -or -not $CriterionId -or -not $Status) { throw 'criterion needs -PhaseId, -CriterionId, and -Status.' }
            $s = Set-AcceptanceCriterion -ProjectRoot $ProjectRoot -PhaseId $PhaseId -CriterionId $CriterionId -Status $Status -Evidence $Evidence -Note $Note
            $ph = @($s['phases']) | Where-Object { $_['id'] -eq $PhaseId } | Select-Object -First 1
            $out.criterion = @($ph['acceptanceCriteria']) | Where-Object { $_['id'] -eq $CriterionId } | Select-Object -First 1
            $out.open = @(@($ph['acceptanceCriteria']) | Where-Object { $_['status'] -notin @('met', 'waived') } | ForEach-Object { $_['id'] })
        }
        'phase-failure' {
            if (-not $PhaseId -or -not $Summary -or -not $Recovery) { throw 'phase-failure needs -PhaseId, -Summary, and -Recovery.' }
            [void](Add-PhaseFailure -ProjectRoot $ProjectRoot -PhaseId $PhaseId -Summary $Summary -Recovery $Recovery -EvidenceFile $EvidenceFile)
            $out.phase = $PhaseId
        }
        'unresolved-update' {
            if (-not $Id -or -not $Status) { throw 'unresolved-update needs -Id and -Status.' }
            $p2 = ''; if ($PSBoundParameters.ContainsKey('Proposal')) { $p2 = $Proposal }
            [void](Set-UnresolvedStatus -ProjectRoot $ProjectRoot -Id $Id -Status $Status -Proposal $p2 -Decision $DecisionId)
            $out.id = $Id; $out.status = $Status
        }
        'verification' {
            if (-not $JsonFile) { throw 'verification needs -JsonFile.' }
            $s = Set-VerificationChecks -ProjectRoot $ProjectRoot -Checks (Read-JsonFile $JsonFile)
            $out.count = @($s['verification']['checks']).Count
        }
        'verify-check' {
            if (-not $CheckId -or -not $Result) { throw 'verify-check needs -CheckId and -Result.' }
            $s = Set-VerificationResult -ProjectRoot $ProjectRoot -CheckId $CheckId -Result $Result -Evidence $Evidence -Note $Note -Recovery $Recovery
            $out.check = @($s['verification']['checks']) | Where-Object { $_['id'] -eq $CheckId } | Select-Object -First 1
            $out.pending = @(@($s['verification']['checks']) | Where-Object { $_['result'] -eq 'pending' } | ForEach-Object { $_['id'] })
        }
        'migrate' {
            $out.migration = Update-StateSchemaVersion -ProjectRoot $ProjectRoot
        }
        'session-marker' {
            if (-not $SessionId -or -not $DataDir) { throw 'session-marker needs -SessionId and -DataDir.' }
            if ($SessionId -notmatch '^[A-Za-z0-9\-_]+$') { throw 'Invalid session id.' }
            $marker = Join-Path (Join-Path $DataDir 'active-sessions') ($SessionId + '.json')
            if ($Remove) {
                if ([System.IO.File]::Exists($marker)) { [System.IO.File]::Delete($marker) }
                $out.removed = $marker
            } else {
                if (-not (Test-StateExists $ProjectRoot)) { throw 'No upgrade state in the project; create it first.' }
                Write-TextFile -Path $marker -Content (ConvertTo-JsonText -InputObject ([ordered]@{ projectRoot = $ProjectRoot; createdAt = (Get-UtcTimestamp) }))
                $out.marker = $marker
            }
        }
    }
    Write-JsonOutput $out
    if ($out.ok) { exit 0 } else { exit 1 }
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; command = $Command; error = $_.Exception.Message })
    exit 1
}
