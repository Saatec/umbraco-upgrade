---
name: upgrade-state
description: Internal reference for reading and changing .umbraco-upgrade/state.json through the plugin's state script. Loaded by the umbraco-upgrade workflow skills.
user-invocable: false
---

# Upgrade state

All state lives in the target project at `.umbraco-upgrade/state.json`. Field reference: [references/state-schema.md](references/state-schema.md). JSON Schema: `${CLAUDE_PLUGIN_ROOT}/schemas/state.schema.json`.

## Rules

- Change state **only** with `state.ps1`. It validates against the schema, refuses invalid transitions, updates `updatedAt`, appends to `history`, and writes atomically. The safety hook blocks Write and Edit on `state.json`.
- Never put secrets in state. Database targets are `local`, `non-local`, or `unknown`, never a connection string. `state.ps1` refuses values that look like secrets.
- Read results from the script's JSON output (`ok`, `error`). If `ok` is false, report the error; do not work around it.

## Commands

Run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/state.ps1" <command> -ProjectRoot "<root>" ...`

| Command | Use |
|---|---|
| `init -Mode upgrade\|plan -Target <v>` | Gate 1 start. Takes the git status snapshot, then creates `.umbraco-upgrade/`. Refuses if state exists. |
| `adopt-plan -Target <v>` | `/umbraco-upgrade:start` only, after its reality check: turns a plan-only run for the same target (requested or resolved version) into an upgrade run. Sets gates 3 and 4 back to pending; keeps everything else. Refuses in upgrade mode. |
| `get [-Field a.b.c]` | Read the state or one field. |
| `validate` | Check the file against the schema. |
| `gate -Gate <g> -Status in-progress\|passed\|failed\|skipped [-Evidence a,b] [-Notes text]` | Gate transitions. Previous gates must be done; `passed` has per-gate requirements. |
| `gate-fields -Gate <g> -Set "k=v;k2=v2"` | Non-status gate fields such as `pathSelection`, `factsVerified`, `rollbackDoc`. |
| `set -Section source\|target\|path\|project\|gitBaseline\|knowledge -Set "k=v;a.b=v"` | Merge values into a section. Integers, `true`, `false`, `null` are typed. For complex values write JSON to a file under `.umbraco-upgrade/` and pass `-JsonFile`. |
| `decision [-Gate <g>]` | Allocate the next decision id (`D-001`, ...). Write the decision text in `decisions.md`. |
| `unresolved -Item text [-Pattern id] [-Proposal port\|replace\|redesign]` | Record an item that cannot be migrated directly. |
| `unresolved-update -Id U-001 -Status decided\|resolved\|deferred\|awaiting-user [-Proposal ...] [-DecisionId D-001]` | Record the user's answer to an unresolved item (decided or resolved need the decision id). |
| `phases -JsonFile <file>` | Replace the phase list while composing the plan (before approval). |
| `request-plan-approval` | Bind the current `plan.md` hash and mark gate 4 awaiting approval. |
| `approve -Action <a> -Decision approved\|rejected [-Scope s] [-Note n]` | Record the user's decision. |
| `phase -PhaseId P1 -Status in-progress\|blocked\|done\|failed\|deferred` | Phase transitions. In progress needs the approved, unchanged plan, gate 3 passed, and every earlier phase done or deferred; done needs every criterion met or waived and a checkpoint commit. |
| `criterion -PhaseId P1 -CriterionId P1-AC1 -Status met\|not-met\|waived\|pending [-Evidence a,b] [-Note n]` | Record one acceptance criterion. Met needs evidence files under `.umbraco-upgrade/`; waived needs the user's words. |
| `phase-failure -PhaseId P1 -Summary text -Recovery text [-EvidenceFile path]` | Record a failure and how to recover from it. |
| `checkpoint -PhaseId P1 -Commit <sha>` | Record a phase's checkpoint commit (`New-Checkpoint.ps1` does this after it commits). |
| `verification -JsonFile <file>` | Record the gate 5 checklist (from `Get-VerificationPlan.ps1`) while gate 5 is in progress. |
| `verify-check -CheckId V-01 -Result verified\|failed\|not-verified [-Evidence a,b] [-Note n] [-Recovery r]` | Record one gate 5 check. Automated checks are verified only by `Invoke-Verification.ps1`; a manual check is verified only with evidence and the user's words; failed needs the recovery; not verified needs the reason. |
| `require-approval -Action <a> [-Scope s] [-Consume]` | Check for an approved, unused approval. |
| `check-plan [-Invalidate]` | Compare `plan.md` with the approved hash. |
| `session-marker -SessionId <id> -DataDir <dir> [-Remove]` | Activate the safety hooks for a project outside the session's directory. |
| `migrate` | Upgrade an older 1.x state file. |

## Resume reconciliation

Used by `/umbraco-upgrade:resume`, and by the verification skill before gate 5. The caller gives the project root, the session id, and the plugin data directory.

1. If the project root is not the session's working directory or below it, run `state.ps1 session-marker -ProjectRoot "<root>" -SessionId "<session id>" -DataDir "<plugin data dir>"` first, so the safety hooks see the project.
2. Run `Test-StateReality.ps1 -ProjectRoot "<root>"`. It is read-only. It compares the state with the repository (branch, HEAD, base commit, every checkpoint commit, uncommitted changes, a git operation in progress), with `plan.md` and its approved hash, with every file the state cites, with the CMS version in the project files, and with whether the declared local database copy is still what the local configuration points to.
3. Tell the user where the upgrade stands (`position`) and what the last recorded event was.
4. **If `mismatches` is not zero: report and ask, then stop.** For each mismatch give what state expects, what was found, and its `options`. Ask how they want to proceed. Do not continue the workflow, and do not repeat any phase, until they answer.
   - **Never repair to make state and reality agree.** No `git reset`, `checkout`, `switch`, `restore`, `stash`, `clean`, or commits; no edits to state, plan, evidence, or project files; no re-run of a phase or a gate. Changes to the repository or the files are the user's to make.
   - When the user answers: if they changed something themselves, run `Test-StateReality.ps1` again. If they decide something (for example that a commit belongs to a phase, that a done phase must be done again, or that a missing file is accepted), record their decision first (`state.ps1 decision`, then the entry in `decisions.md` with their words), then the state change it calls for, through `state.ps1` only. A done phase that must be done again gets `state.ps1 phase-failure` with the user's words and the recovery, then `phase -Status in-progress` and its criteria back to `pending`; later phases that depend on it are handled the same way, each only on the user's decision.
5. **Warnings** (for example uncommitted changes while a phase is open, new commits on the base branch in a plan-only run): tell the user, and ask before continuing when a warning concerns the phase you would continue.
6. **If everything agrees**, continue from `position` with the `umbraco-upgrade:upgrade-workflow` skill in upgrade mode (or explain, for a plan-only run):

   | Position | Continue with |
   |---|---|
   | `gate` discovery, versionPath, safety, planApproval | That gate's skill, from its first step that has no recorded result. A plan awaiting approval: show where the plan is and ask again. |
   | `phase`, status `in-progress` | That phase through [phase-execution.md](../upgrade-workflow/references/phase-execution.md), from its first open criterion. Do not redo criteria that are met. |
   | `phase`, status `blocked` or `failed` | First show its recorded failures and recovery steps and any open unresolved item, and ask. Continue only on the user's go-ahead. |
   | `phase`, status `pending` | Phase execution from that phase (`state.ps1 check-plan -Invalidate` first). |
   | `gate` final | The `umbraco-upgrade:verification` skill. |
   | `done` | Say that nothing is left to resume; offer `/umbraco-upgrade:report`. For a plan-only run, explain that `/umbraco-upgrade:start <target>` in this project reuses the plan: it runs gate 3 and asks for approval. |

Failures are recorded with their recovery steps (`state.ps1 phase-failure`), so a resumed session shows them before it continues. Phases are written to be idempotent where possible: a resumed phase starts from its open criteria and the evidence already recorded.
