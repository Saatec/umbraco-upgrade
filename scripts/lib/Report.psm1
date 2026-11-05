# Report.psm1 - assembles .umbraco-upgrade/report.md from state, the evidence folder, and decisions.md, following
# the section order and table headers of skills/upgrade-planning/templates/report.md. The report links to evidence;
# it copies no evidence content, and the whole text goes through redaction before it is written.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -DisableNameChecking

$script:PluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Get-ReportTemplatePath { return (Join-Path $script:PluginRoot 'skills/upgrade-planning/templates/report.md') }

function ConvertTo-Cell {
    # One table cell: no pipes or line breaks, never empty.
    param($Value)
    $t = [string]$Value
    $t = ($t -replace '\r?\n', ' ').Replace('|', '/').Trim()
    if (-not $t) { return '-' }
    return $t
}

function Get-ShortCommit { param([string]$Sha) if ($Sha -and $Sha.Length -gt 12) { return $Sha.Substring(0, 12) } if ($Sha) { return $Sha } return 'none' }

function Format-EvidenceLinks {
    # Markdown links relative to .umbraco-upgrade/, only for files that exist.
    param([string]$StateDir, $Paths)
    $links = @()
    foreach ($p in @($Paths | Where-Object { $_ } | Select-Object -Unique)) {
        $rel = ([string]$p).Replace('\', '/')
        if ($rel -match '(^|/)\.\.(/|$)' -or [System.IO.Path]::IsPathRooted($rel)) { continue }
        $full = Join-Path $StateDir $rel
        if ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full)) { $links += "[$rel]($rel)" } else { $links += "$rel (missing)" }
    }
    if ($links.Count -eq 0) { return 'none' }
    return ($links -join ', ')
}

function Get-TemplateSections {
    # Header lines (before the first '## ') and the sections in template order, each with its table header lines.
    param([string]$Text)
    $header = New-Object System.Collections.ArrayList
    $sections = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^## (.+)$') { $current = [ordered]@{ heading = $Matches[1].Trim(); lines = (New-Object System.Collections.ArrayList) }; [void]$sections.Add($current); continue }
        if ($null -eq $current) { [void]$header.Add($line) } else { [void]$current.lines.Add($line) }
    }
    return [ordered]@{ header = @($header); sections = @($sections) }
}

function Get-TableHeader {
    # The header row and separator of the first table in a template section, or $null.
    param($Lines)
    $rows = @($Lines | Where-Object { $_ -match '^\|' })
    if ($rows.Count -ge 2 -and $rows[1] -match '^\|[\s\-:|]+\|$') { return @($rows[0], $rows[1]) }
    return $null
}

function Get-DecisionEntries {
    # Entries of decisions.md: '## D-001 <title>' followed by '- Key: value' lines (template form). Lenient for
    # entries written another way: the first text line stands in for the decision.
    param([string]$StateDir)
    $f = Join-Path $StateDir 'decisions.md'
    $out = New-Object System.Collections.ArrayList
    if (-not [System.IO.File]::Exists($f)) { return ,($out.ToArray()) }
    $cur = $null
    foreach ($line in ((Read-TextFile $f) -split '\r?\n')) {
        if ($line -match '^#{2,3}\s+(D-\d{3,})\b[\s:.\-]*(.*)$') {
            $cur = [ordered]@{ id = $Matches[1]; title = $Matches[2].Trim(); decision = $null; alternatives = $null; sources = $null; status = $null; firstLine = $null }
            [void]$out.Add($cur); continue
        }
        if ($null -eq $cur) { continue }
        if ($line -match '^#{1,2}\s') { $cur = $null; continue }
        if ($line -match '^\s*[-*]\s*(Decision|Alternatives considered|Alternatives|Sources?|Status)\s*:\s*(.*)$') {
            $k = $Matches[1].ToLowerInvariant(); $v = $Matches[2].Trim()
            if ($k -eq 'decision') { $cur.decision = $v } elseif ($k -like 'alternatives*') { $cur.alternatives = $v } elseif ($k -like 'source*') { $cur.sources = $v } else { $cur.status = $v }
        } elseif (-not $cur.firstLine -and $line.Trim()) { $cur.firstLine = $line.Trim() }
    }
    return ,($out.ToArray())
}

function Get-HistoryNotes {
    # The user's words recorded with waivers, from history details 'P1 P1-AC2=waived note: ...'.
    param($State)
    $notes = @{}
    foreach ($h in @($State['history'])) {
        if ($h['event'] -eq 'criterion' -and [string]$h['detail'] -match '^(P\d+) (P\d+-AC\d+)=(\w[\w-]*)(?: note: (.*))?$') { $notes[$Matches[2]] = [ordered]@{ status = $Matches[3]; note = $Matches[4]; at = $h['at'] } }
    }
    return $notes
}

function Get-ReportStatus {
    param($State)
    $g = $State['gates']
    if ($State['mode'] -eq 'plan') { return 'plan only: nothing was executed' }
    foreach ($n in @('discovery', 'versionPath', 'safety')) { if ($g[$n]['status'] -eq 'failed') { return "stopped: gate $n failed" } }
    $pa = $g['planApproval']['status']
    if ($pa -eq 'rejected') { return 'stopped: the plan was rejected' }
    if ($pa -ne 'approved') { return "partial: the plan is not approved ($pa)" }
    $open = @(@($State['phases']) | Where-Object { $_['status'] -notin @('done', 'deferred') } | ForEach-Object { "$($_['id']) $($_['status'])" })
    if ($open.Count -gt 0) { return "partial: phases open ($($open -join ', '))" }
    $fs = $g['final']['status']
    if ($fs -eq 'passed') { return 'complete' }
    if ($fs -eq 'failed') { return 'partial: follow-up work after final verification' }
    if (-not $State.Contains('verification')) { return "partial: final verification $fs" }
    $checks = @($State['verification']['checks'])
    $failed = @($checks | Where-Object { $_['result'] -eq 'failed' } | ForEach-Object { $_['id'] })
    if ($failed.Count -gt 0) { return "partial: final verification found failures ($($failed -join ', '))" }
    $pending = @($checks | Where-Object { $_['result'] -eq 'pending' }).Count
    if ($pending -gt 0) { return "partial: final verification in progress ($pending check(s) open)" }
    return 'partial: final verification recorded; gate 5 not passed yet'
}

function New-UpgradeReport {
    # Returns @{ text; status; counts } for the project. Writes nothing.
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Resolve-FullPath $ProjectRoot
    $state = Read-UpgradeState $root
    $dir = Get-StateDir $root
    $tpl = Get-TemplateSections (Read-TextFile (Get-ReportTemplatePath))
    $checks = @(); if ($state.Contains('verification')) { $checks = @($state['verification']['checks']) }
    $phases = @($state['phases'])
    $notes = Get-HistoryNotes $state
    $gb = $state['gitBaseline']
    $status = Get-ReportStatus $state
    $lastCheckpoint = $null
    foreach ($p in $phases) { if ($p['checkpoint'] -and $p['checkpoint']['commit']) { $lastCheckpoint = [string]$p['checkpoint']['commit'] } }
    $name = Split-Path $root -Leaf
    $counts = [ordered]@{ verifiedAutomatically = 0; verifiedManually = 0; notVerified = 0 }

    $sb = New-Object System.Text.StringBuilder
    $add = { param([string]$l) [void]$sb.Append($l + "`n") }
    # Header: title, generated, status, then the template's own text.
    foreach ($line in $tpl.header) {
        if ($line -match '^# ') { & $add ("# Upgrade report: " + $name); continue }
        if ($line -match '^Generated:') { & $add ("Generated: $(Get-UtcTimestamp) by umbraco-upgrade $(Get-PluginVersion)  "); continue }
        if ($line -match '^Status:') { & $add "Status: $status"; continue }
        & $add $line
    }
    foreach ($sec in $tpl.sections) {
        & $add "## $($sec.heading)"
        & $add ''
        $th = Get-TableHeader $sec.lines
        $rows = New-Object System.Collections.ArrayList
        $body = New-Object System.Collections.ArrayList
        switch ($sec.heading) {
            'Summary' {
                $steps = @(@($state['path']['steps']) | Where-Object { $_ } | ForEach-Object { "$($_['id']) ($($_['from']) to $($_['to']))" })
                $done = @($phases | Where-Object { $_['status'] -eq 'done' }).Count
                $deferred = @($phases | Where-Object { $_['status'] -eq 'deferred' }).Count
                $open = $phases.Count - $done - $deferred
                $unres = @($state['unresolved'])
                $openU = @($unres | Where-Object { $_['status'] -in @('awaiting-user', 'decided') }).Count
                $defU = @($unres | Where-Object { $_['status'] -eq 'deferred' }).Count
                [void]$body.Add("- Source: Umbraco $(if ($state['source']['umbraco']) { $state['source']['umbraco'] } else { 'unknown' }) on $(if (@($state['source']['dotnet']).Count) { @($state['source']['dotnet']) -join ', ' } else { 'unknown framework' })")
                [void]$body.Add("- Target: Umbraco $(if ($state['target']['resolved']) { $state['target']['resolved'] } else { 'not resolved' }) on $(if ($state['target']['dotnet']) { $state['target']['dotnet'] } else { 'unknown framework' }) (requested: $($state['target']['requested']))")
                [void]$body.Add("- Path: $($state['path']['strategy'])$(if ($steps.Count) { ', steps ' + ($steps -join ', ') } else { '' }) (decision $(if ($state['path']['decision']) { $state['path']['decision'] } else { 'none' }))")
                [void]$body.Add("- Upgrade branch: $(if ($gb['upgradeBranch']) { $gb['upgradeBranch'] } else { 'none' }), base commit $(Get-ShortCommit ([string]$gb['baseCommit'])), last checkpoint $(Get-ShortCommit $lastCheckpoint)")
                [void]$body.Add("- Phases: $done done, $deferred deferred, $open open")
                if ($checks.Count) {
                    $va = @($checks | Where-Object { $_['result'] -eq 'verified' -and $_['method'] -eq 'automated' }).Count
                    $vm = @($checks | Where-Object { $_['result'] -eq 'verified' -and $_['method'] -eq 'manual' }).Count
                    $nv = @($checks | Where-Object { $_['result'] -eq 'not-verified' }).Count
                    $fa = @($checks | Where-Object { $_['result'] -eq 'failed' }).Count
                    $pe = @($checks | Where-Object { $_['result'] -eq 'pending' }).Count
                    [void]$body.Add("- Final verification (gate 5): $va verified automatically, $vm verified manually, $nv not verified, $fa failed, $pe open")
                } else { [void]$body.Add("- Final verification (gate 5): $($state['gates']['final']['status'])") }
                [void]$body.Add("- Unresolved items: $openU open, $defU deferred")
                [void]$body.Add("- Gates: " + ((@(Get-GateOrder) | ForEach-Object { "$_ $($state['gates'][$_]['status'])" }) -join ', '))
            }
            'Phases' {
                foreach ($p in $phases) {
                    $crit = @($p['acceptanceCriteria'])
                    $m = @($crit | Where-Object { $_['status'] -eq 'met' }).Count; $w = @($crit | Where-Object { $_['status'] -eq 'waived' }).Count
                    $folder = "evidence/$($p['id'])/"
                    [void]$rows.Add(@($p['id'], $p['title'], $p['status'], (Get-ShortCommit ([string]$p['checkpoint']['commit'])), "$m / $w / $($crit.Count - $m - $w)", $(if ([System.IO.Directory]::Exists((Join-Path $dir $folder))) { Format-EvidenceLinks $dir @($folder) } else { 'none' })))
                }
            }
            'Verified automatically' {
                foreach ($c in @($checks | Where-Object { $_['result'] -eq 'verified' -and $_['method'] -eq 'automated' })) { $counts.verifiedAutomatically++; [void]$rows.Add(@("$($c['id']) $($c['title'])", "passed: $($c['note'])", (Format-EvidenceLinks $dir $c['evidence']))) }
                foreach ($p in $phases) { foreach ($c in @($p['acceptanceCriteria'] | Where-Object { $_['status'] -eq 'met' -and $_['verification'] -eq 'automated' })) { $counts.verifiedAutomatically++; [void]$rows.Add(@("$($c['id']) $($c['text'])", 'met', (Format-EvidenceLinks $dir $c['evidence']))) } }
            }
            'Verified manually (by you)' {
                foreach ($c in @($checks | Where-Object { $_['result'] -eq 'verified' -and $_['method'] -eq 'manual' })) { $counts.verifiedManually++; [void]$rows.Add(@("$($c['id']) $($c['title'])", "you, $($c['recordedAt'])", "confirmed: $($c['note'])", (Format-EvidenceLinks $dir $c['evidence']))) }
                foreach ($p in $phases) {
                    foreach ($c in @($p['acceptanceCriteria'] | Where-Object { $_['status'] -eq 'met' -and $_['verification'] -eq 'manual' })) {
                        $counts.verifiedManually++
                        $at = $(if ($notes.ContainsKey($c['id'])) { $notes[$c['id']].at } else { 'recorded' })
                        [void]$rows.Add(@("$($c['id']) $($c['text'])", "you, $at", 'met', (Format-EvidenceLinks $dir $c['evidence'])))
                    }
                }
            }
            'Not verified' {
                if ($checks.Count -eq 0 -and $state['mode'] -eq 'upgrade') { $counts.notVerified++; [void]$rows.Add(@('Final verification (gate 5)', "not run ($($state['gates']['final']['status']))", 'Nothing beyond the phase criteria is verified.', 'Run /umbraco-upgrade:verify after the last phase.')) }
                if ($state['mode'] -eq 'plan') { $counts.notVerified++; [void]$rows.Add(@('Every check', 'plan only: nothing was executed', 'The plan is untested.', 'Run /umbraco-upgrade:start to execute and verify an upgrade.')) }
                foreach ($c in @($checks | Where-Object { $_['result'] -ne 'verified' })) {
                    $counts.notVerified++
                    $why = switch ($c['result']) { 'failed' { "failed: $($c['note'])" } 'not-verified' { [string]$c['note'] } default { 'not checked yet' } }
                    $next = $(if ($c['result'] -eq 'failed' -and $c['recovery']) { $c['recovery'] } elseif ($c['result'] -eq 'pending') { 'Finish it in /umbraco-upgrade:verify.' } else { $c['nextStep'] })
                    [void]$rows.Add(@("$($c['id']) $($c['title'])", $why, $c['risk'], $next))
                }
                foreach ($p in $phases) {
                    if ($p['status'] -eq 'deferred') { $counts.notVerified++; [void]$rows.Add(@("$($p['id']) $($p['title'])", 'phase deferred', 'Its work is not part of this upgrade.', 'Plan it as follow-up work.')) }
                    foreach ($c in @($p['acceptanceCriteria'])) {
                        if ($c['status'] -eq 'met') { continue }
                        $counts.notVerified++
                        if ($c['status'] -eq 'waived') {
                            $n = $(if ($notes.ContainsKey($c['id']) -and $notes[$c['id']].note) { $notes[$c['id']].note } else { 'no words recorded' })
                            [void]$rows.Add(@("$($c['id']) $($c['text'])", "waived by you: $n", 'The criterion was not proven.', 'Check it before going live.'))
                        } else { [void]$rows.Add(@("$($c['id']) $($c['text'])", "$($c['status']) (phase $($p['status']))", 'The criterion is not proven.', "Finish phase $($p['id']).")) }
                    }
                }
            }
            'Decisions' {
                $entries = Get-DecisionEntries $dir
                foreach ($d in $entries) {
                    $what = $(if ($d.decision) { $d.decision } elseif ($d.title) { $d.title } else { $d.firstLine })
                    $src = $(if ($d.sources) { $d.sources } else { 'none recorded' })
                    if ($d.status) { $src += " (status: $($d.status))" }
                    [void]$rows.Add(@($d.id, $what, $(if ($d.alternatives) { $d.alternatives } else { 'none recorded' }), $src))
                }
                $described = @($entries | ForEach-Object { $_.id })
                foreach ($id in @($state['decisions'] | Where-Object { $described -notcontains $_ })) { [void]$rows.Add(@($id, 'recorded in state, not described in decisions.md', '-', '-')) }
            }
            'Unresolved items' { foreach ($u in @($state['unresolved'])) { [void]$rows.Add(@($u['id'], $u['pattern'], $u['item'], $u['proposal'], $u['status'])) } }
            'Deviations from the plan' {
                foreach ($p in $phases) {
                    if ($p['status'] -eq 'deferred') { [void]$rows.Add(@($p['id'], 'deferred', 'see the phase history and decisions.md', 'recorded in state')) }
                    foreach ($c in @($p['acceptanceCriteria'] | Where-Object { $_['status'] -eq 'waived' })) {
                        $n = $(if ($notes.ContainsKey($c['id'])) { $notes[$c['id']] } else { $null })
                        [void]$rows.Add(@($p['id'], "criterion $($c['id']) waived", $(if ($n -and $n.note) { $n.note } else { 'no words recorded' }), $(if ($n) { "you ($($n.at))" } else { 'you' })))
                    }
                    foreach ($f in @($p['failures'])) { if ($f) { [void]$rows.Add(@($p['id'], "failure: $($f['summary'])", "recovery: $($f['recovery'])", '-')) } }
                }
                foreach ($h in @($state['history'] | Where-Object { $_['event'] -eq 'plan-approval-invalidated' })) { [void]$rows.Add(@('-', "plan changed after approval ($($h['at']))", 'a new approval was needed', 'see approvals in state')) }
                if ($state['gates']['final']['status'] -eq 'failed' -and $state['gates']['final'].Contains('notes')) { [void]$rows.Add(@('-', 'final verification set back for follow-up work', $state['gates']['final']['notes'], '-')) }
            }
            'Manual follow-ups' {
                foreach ($c in @($checks | Where-Object { $_['method'] -eq 'manual' -and $_['result'] -ne 'verified' })) { [void]$body.Add("- $($c['id']) $($c['title']): $(@($c['steps'])[0])") }
                foreach ($u in @($state['unresolved'] | Where-Object { $_['status'] -in @('deferred', 'awaiting-user', 'decided') })) { [void]$body.Add("- $($u['id']) ($($u['status'])): $($u['item'])") }
                [void]$body.Add('- The deployment and the production configuration are yours: the plugin never deploys and never touches production.')
            }
            'Rollback' {
                $rb = [string]$state['gates']['safety']['rollbackDoc']
                if ($rb -and [System.IO.File]::Exists((Join-Path $dir ($rb -replace '#.*$', '')))) {
                    $snaps = @(Get-ChildItem -LiteralPath (Join-Path $dir 'evidence') -Recurse -File -Filter 'snapshot-*.json' -ErrorAction SilentlyContinue | ForEach-Object { 'evidence/' + (Get-RelativePathCompat -BasePath (Join-Path $dir 'evidence') -Path $_.FullName).Replace('\', '/') })
                    $restore = $(if ($snaps.Count) { 'the snapshot recorded in ' + (Format-EvidenceLinks $dir $snaps) } else { 'your own backup (no snapshot evidence was recorded)' })
                    [void]$body.Add("See [$rb]($rb): return to $($gb['baseBranch']) at $(Get-ShortCommit ([string]$gb['baseCommit'])); restore the local database copy from $restore.")
                } else { [void]$body.Add('No rollback document: gate 3 has not run (plan-only, or not reached yet). Nothing was changed outside .umbraco-upgrade/ before gate 3.') }
            }
            'Evidence index' {
                $ev = Join-Path $dir 'evidence'
                if ([System.IO.Directory]::Exists($ev)) {
                    foreach ($d in (Get-ChildItem -LiteralPath $ev -Directory | Sort-Object Name)) {
                        $n = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File).Count
                        [void]$body.Add("- [evidence/$($d.Name)/](evidence/$($d.Name)/) ($n file(s))")
                    }
                }
                if ($body.Count -eq 0) { [void]$body.Add('- no evidence recorded') }
            }
            default { foreach ($l in $sec.lines) { [void]$body.Add($l) } }
        }
        if ($null -ne $th -and $sec.heading -notin @('Summary', 'Manual follow-ups', 'Rollback', 'Evidence index')) {
            if ($rows.Count -eq 0) { & $add 'None.' }
            else {
                & $add $th[0]; & $add $th[1]
                foreach ($r in $rows) { & $add ('| ' + ((@($r) | ForEach-Object { ConvertTo-Cell $_ }) -join ' | ') + ' |') }
            }
        } else {
            foreach ($l in $body) { & $add $l }
            if ($body.Count -eq 0 -and $rows.Count -eq 0) { & $add 'None.' }
        }
        & $add ''
    }
    $text = ($sb.ToString().TrimEnd() + "`n")
    $safe = Protect-Text $text
    return [ordered]@{ text = $safe; redacted = ($safe -ne $text); status = $status; counts = $counts }
}

Export-ModuleMember -Function New-UpgradeReport, Get-DecisionEntries, Get-ReportStatus, Get-ReportTemplatePath
