# Phase execution (after the plan is approved)

Runs only in upgrade mode, after gate 3 passed and the user approved the plan. Gate 5 (final verification and report) belongs to a later plugin version: after the last phase, stop and tell the user.

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`. Read `ok` and the messages of every script; never guess at results.

## Before the first phase

1. `state.ps1 check-plan -ProjectRoot "<root>" -Invalidate`. If the plan changed after approval, tell the user, run `state.ps1 request-plan-approval` again, ask, and stop.
2. Read the phases: `state.ps1 get -ProjectRoot "<root>" -Field phases`, and the proposal behind them in `.umbraco-upgrade/evidence/planning/phase-composition.json` (owner, files, reasons).
3. Tell the user which phase starts, what it changes, and which approvals it will ask for.

## Owner of each phase

| Phase area | Skill to load |
|---|---|
| `application-framework` | `umbraco-upgrade:migrate-application-framework` |
| `content-database` | `umbraco-upgrade:migrate-content-database` |
| `custom-code` | `umbraco-upgrade:migrate-custom-code` |
| `packages-backoffice` | `umbraco-upgrade:migrate-packages-backoffice` |
| `config-auth-integrations` | `umbraco-upgrade:migrate-config-auth-integrations` |
| `build-tests`, `functional-verification` | `umbraco-upgrade:migrate-build-tests` |
| `deployment-rehearsal` | `umbraco-upgrade:deployment-rehearsal` |

## For each phase, in plan order

1. **Start.** `state.ps1 phase -ProjectRoot "<root>" -PhaseId <P> -Status in-progress`. The state script refuses when an earlier phase is not done or deferred, or when the plan changed.
2. **Work.** Load the owning skill with the Skill tool and follow it for this phase. It follows [migration-rules.md](migration-rules.md).
3. **Approval-tier steps.** Ask before each one, following the approval protocol, record the approval, then run the script that checks it:

   | Action | Approval | Script or check |
   |---|---|---|
   | Snapshot of the local database copy | `db-snapshot-local` (scope: destination folder) | `Invoke-DatabaseSnapshot.ps1` |
   | Database migration on the local copy (start the site, unattended upgrade) | `db-migration-local` | the safety hook asks before the site starts |
   | Remove or replace a package | `package-removal` | the safety hook asks for `dotnet remove package` |
   | CI or deployment files | `ci-deploy-config-change` | the safety hook asks for the edit |
   | Write outside the project (user secrets, tool installs) | `outside-project-path` | `Copy-ConfigValue.ps1 -ToUserSecrets`; the safety hook asks for file writes |
   | Remove or retire a custom feature | `remove-custom-feature` (scope: the paths) | `New-Checkpoint.ps1` |

4. **Independent check.** For a phase with a high-difficulty pattern, or more than five criteria, delegate to the `umbraco-upgrade:independent-verifier` agent: give it the project root and the phase id only, not your narrative. Save its report with `Write-Evidence.ps1 -Folder <P> -Name verifier.md -SourceFile <file>` and act on every criterion it does not confirm.
5. **Criteria.** Record each one with `state.ps1 criterion` and its evidence. Manual criteria need the user's confirmation; ask for it in one message that lists them.
6. **Checkpoint.** `New-Checkpoint.ps1 -ProjectRoot "<root>" -PhaseId <P>`. If it refuses, fix the cause (restore a deleted file, replace a stub with real code or an unresolved item, move a secret out of the tracked file). Never work around it. Review every warning it reports.
7. **Done.** `state.ps1 phase -ProjectRoot "<root>" -PhaseId <P> -Status done`. Tell the user: the phase, its commit, what changed, the open items, and the next phase. Continue with the next phase unless the user asked to pause after each one.

## When something goes wrong

- A step fails: record it with `state.ps1 phase-failure -PhaseId <P> -Summary "<what failed>" -Recovery "<how to recover>" [-EvidenceFile <path>]`, set the phase to `failed` or `blocked`, tell the user, and stop.
- Something cannot be migrated directly: follow rule 1 of [migration-rules.md](migration-rules.md).
- A blocking safety hook message (`umbraco-upgrade guard [<rule>]`): stop, tell the user what was blocked and why, and ask. Never try another way to do the same thing.

## After the last phase

Tell the user that every phase is done or deferred, list the open unresolved items and the evidence folder, and say that final verification and the report (gate 5) come in a later plugin version. Stop.
