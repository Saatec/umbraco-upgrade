---
name: verification
description: Internal gate 5 (final verification) for the umbraco-upgrade workflow, and the interim check of an upgrade in progress. Runs the automated A8 checks, the independent verifier, and the manual checklist, and separates what was verified automatically, manually, and not at all. Loaded by /umbraco-upgrade:verify and the upgrade-workflow skill.
user-invocable: false
---

# Gate 5: Final verification

The caller gives you the project root, the session id, and the plugin data directory. Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`. Read `ok` and the messages of every script; never guess at results. State commands: the `umbraco-upgrade:upgrade-state` skill.

## Rules

- **A build is never verification on its own.** The report separates what was verified automatically, what the user verified manually, and what was not verified. A check that was not done is "not verified" with its reason, never "verified".
- **Automated results come only from the scripts.** `Invoke-Verification.ps1` records them from the evidence it checks. You may record an automated check as `failed` or `not-verified` with the reason; you never record one as `verified`.
- **Manual results come only from the user.** A manual check is `verified` only when the user confirms that check in this conversation; record their words. Never infer it from silence, from an earlier answer about something else, or from file contents.
- **Local and test systems only.** The local database copy the user declared, test accounts, test or sandbox endpoints. Never a shared, staging, or production system. Starting the site is approval-tier (`db-migration-local`); the safety hook asks too.
- **No fixes during gate 5.** A failed check is fixed through a follow-up phase (section 4), never by editing code here, and never by removing, stubbing, or disabling custom functionality.
- **Never edit** `state.json`, files under `evidence/`, or `report.md` by hand.

## 1. Where the upgrade stands

If the project root is not the session's working directory or below it, first run `state.ps1 session-marker -ProjectRoot "<root>" -SessionId "<session id>" -DataDir "<plugin data dir>"`, so the safety hooks see the project.

Read `state.ps1 get -ProjectRoot "<root>"` and decide:

| State | What to do |
|---|---|
| `mode` is `plan` | Nothing was executed, so there is nothing to verify. Say so, offer the plan-only report (`umbraco-upgrade:reporting`), and stop. |
| Gate 4 is not `approved` | Nothing was executed yet. Say so and stop. |
| A phase is not `done` or `deferred` | Interim check: section 2. |
| Gate 5 is `passed` | The upgrade is verified. Offer to regenerate the report and stop. Verify again only when the user asks: then record `state.ps1 gate -Gate final -Status failed -Notes "<user's words>"` and continue at section 3. |
| Otherwise | Gate 5: section 3. |

## 2. Interim check (an upgrade in progress)

1. `Test-StateReality.ps1 -ProjectRoot "<root>"`. Report every mismatch with its options and ask; never repair anything.
2. `Invoke-Verification.ps1 -ProjectRoot "<root>" -DataDir "<plugin data dir>" -Interim`. It records nothing in state; its evidence is `evidence/final/interim-<stamp>.json`.
3. Tell the user, per rule, what holds and what does not, which phases are still open, and that gate 5 starts after the last phase. If they want an independent review of a done phase, delegate it as phase execution does (step 4 of [phase-execution.md](../upgrade-workflow/references/phase-execution.md)).
4. Stop.

## 3. Gate 5

1. **Reconcile.** `Test-StateReality.ps1 -ProjectRoot "<root>"`. If it reports a mismatch, report it with its options, ask, and stop.
2. **Start.** If gate 5 is `pending` or `failed`: `state.ps1 gate -ProjectRoot "<root>" -Gate final -Status in-progress`. It refuses while a phase is still open.
3. **Checklist.** If no checklist is recorded (`state.ps1 get -Field verification` fails), or gate 5 was just restarted: `Get-VerificationPlan.ps1 -ProjectRoot "<root>"`, then `state.ps1 verification -ProjectRoot "<root>" -JsonFile "<stateFile from its output>"`. The checklist names, per check, why it applies (detected patterns and files), how it is verified, its risk, and its next step.
4. **Build and tests.** `Test-Build.ps1 -ProjectRoot "<root>" -PhaseId final -Precompile -Test`. If it cannot run (for example no .NET SDK), record the build and test checks with `state.ps1 verify-check -CheckId <id> -Result not-verified -Note "<reason>"`. If the build or the tests fail, do not fix anything now: the next step records the failure.
5. **Automated checks.** `Invoke-Verification.ps1 -ProjectRoot "<root>" -DataDir "<plugin data dir>"`. Read `recorded`, `pending`, and `summary`. Rerun it after the build if the build check was still pending.
6. **Independent review.** Delegate to the `umbraco-upgrade:independent-verifier` agent with only the project root and the words "gate 5 (final)". Do not pass your own account of the upgrade. Wait for its report before you record anything else for gate 5: if it runs in the background, tell the user it is running, end your turn, and continue from here when its result arrives. Write the report to `.umbraco-upgrade/tmp/verifier-final.md` and save it with `Write-Evidence.ps1 -ProjectRoot "<root>" -Folder final -Name verifier.md -SourceFile "<that file>" -RemoveSource`. For every automated check or phase criterion it does not confirm, tell the user, and record the check as `failed` (with what is wrong and the recovery) or `not-verified` (with the reason).
7. **Manual checklist.** Give the user the path of `evidence/final/manual-checklist.md` and, in one message, each manual check: id, title, why it applies, and its steps. Ask them to do the checks on the local copy and to answer each one with verified, failed, or not verified, and what they saw. Stop and wait. They may answer over several turns.
8. **Record each answer** as it comes:
   - verified: `Write-Evidence.ps1 -ProjectRoot "<root>" -Folder final -Name <check id>-user.md -Text "<what the user checked and said>"`, then `state.ps1 verify-check -ProjectRoot "<root>" -CheckId <id> -Result verified -Evidence "evidence/final/<check id>-user.md" -Note "<the user's words>"`
   - failed: `state.ps1 verify-check -ProjectRoot "<root>" -CheckId <id> -Result failed -Note "<what failed>" -Recovery "<how to recover: the follow-up phase, and what it must fix>"`
   - not verified: `state.ps1 verify-check -ProjectRoot "<root>" -CheckId <id> -Result not-verified -Note "<the reason, in the user's words>"`
9. **Failures.** If a check failed, tell the user each failure with its recovery and the choices: fix it in a follow-up phase (section 4); leave it not verified (record `-Result not-verified` with the user's words; the failure stays in the history and in the report); or stop here. Gate 5 never passes while a check is failed or open.
10. **Report.** Load the `umbraco-upgrade:reporting` skill and follow it.
11. **Pass.** `state.ps1 gate -ProjectRoot "<root>" -Gate final -Status passed -Evidence report.md`. If it refuses, say why and stop. When it passes, remove the session marker if one was written (`state.ps1 session-marker ... -Remove`), and tell the user: where `report.md` is, how many checks were verified automatically, verified manually, and not verified (and why), the manual follow-ups (the deployment and the production configuration are theirs), and `rollback.md`.

## 4. Follow-up phase after a failed check

Only when the user chooses to fix a failed check:

1. `state.ps1 gate -ProjectRoot "<root>" -Gate final -Status failed -Notes "<check ids and the user's words>"`.
2. Add the phase to `plan.md` after the last phase: what it fixes (the failed checks), its owner skill, and its acceptance criteria. This changes the plan, so the approval no longer covers it.
3. `state.ps1 check-plan -ProjectRoot "<root>" -Invalidate`. Write `.umbraco-upgrade/tmp/phases.json`: the list from `state.ps1 get -Field phases`, unchanged, with the new phase added at the end. `state.ps1 phases -ProjectRoot "<root>" -JsonFile "<that file>"` refuses any change to a phase that has run.
4. `state.ps1 request-plan-approval -ProjectRoot "<root>"`, then ask for approval as the [approval protocol](../upgrade-workflow/references/approval-protocol.md) says. Stop and wait.
5. After approval, run the phase through [phase-execution.md](../upgrade-workflow/references/phase-execution.md), then gate 5 again from section 3. A new checklist replaces the old one; the earlier results stay in the history and the evidence.
