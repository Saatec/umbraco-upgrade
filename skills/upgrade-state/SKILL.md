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
| `require-approval -Action <a> [-Scope s] [-Consume]` | Check for an approved, unused approval. |
| `check-plan [-Invalidate]` | Compare `plan.md` with the approved hash. |
| `session-marker -SessionId <id> -DataDir <dir> [-Remove]` | Activate the safety hooks for a project outside the session's directory. |
| `migrate` | Upgrade an older 1.x state file. |

## Not available in this plugin version

Resume reconciliation (comparing state with the branch, HEAD, packages, and database) comes in a later version. If the user asks to resume, say so.
