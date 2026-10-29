# state.json, schema version 1.0.0

Readers accept the same major version. `state.ps1 migrate` upgrades older minors. The machine-readable schema is `schemas/state.schema.json`.

| Field | Meaning |
|---|---|
| `schemaVersion` | `1.x.y` |
| `plugin` | `name` (always `umbraco-upgrade`) and the plugin `version` that created the file |
| `mode` | `upgrade` (start) or `plan` (plan only) |
| `createdAt`, `updatedAt` | UTC timestamps, ISO 8601 |
| `project` | `root` (always `.`), `solution`, `webProject` (relative paths), `stateFolderPolicy`: `undecided`, `commit`, `exclude-local`, `gitignore` |
| `source` | `umbraco` (version or null), `major`, `generation`, `dotnet` (target frameworks), `database` (`engine`: unknown, sqlserver, localdb, sqlce, sqlite, other; `localCopyDeclared`; `target`: unknown, local, non-local), `evidence` (relative paths), `confidence`: none, low, medium, high, conflict, confirmed-by-user; `verified` |
| `target` | `requested` (from the command), `resolved` (exact version, later), `dotnet`, `lts` and `supportEnds` (each `value`, `source`, `verified`), `verified` |
| `path` | `selection`: pending or selected; `strategy`: pending, in-place, staged, rebuild-with-database-migration, new-install-with-content-transfer; `steps` (`S1`...), `alternatives` (strategy and reason rejected), `decision` (`D-xxx`) |
| `gitBaseline` | `isRepo`, `repoRoot`, `baseBranch`, `baseCommit`, `statusAtStart` (clean, dirty, not-a-repo; fixed at init), `statusEvidence`, `upgradeBranch` |
| `gates` | `discovery`, `versionPath`, `safety`, `planApproval`, `final`; each has `status` and `at`, plus optional `evidence`, `decisions`, `notes`, `pathSelection`, `factsVerified`, `guardSelfTest` (not-run, issued, passed, failed), `canaryNonce`, `rollbackDoc`, `planSha256`, `approval` |
| `phases` | `id` (`P1`...), `title`, `area`, `patterns`, `status` (pending, in-progress, blocked, done, failed, deferred), `acceptanceCriteria` (`id` `P1-AC1`..., `text`, `verification` automated or manual, `status` pending, met, not-met, waived, `evidence`), `startedAt`, `completedAt`, `checkpoint.commit`, `failures` (`at`, `summary`, `recovery`, `evidence`) |
| `approvals` | `id` (`A-001`...), `action`, `scope`, `requestedAt`, `decision` (pending, approved, rejected), `decidedAt`, `consumed`, `note` |
| `decisions` | Decision ids; the text and sources are in `decisions.md` |
| `unresolved` | `id` (`U-001`...), `pattern`, `item`, `proposal` (undecided, port, replace, redesign), `status` (awaiting-user, decided, resolved, deferred) |
| `knowledge` | `baselineVersion` (knowledgeVersion of the versions file used), `refreshedAt` (its verifiedAt when the refreshed copy from the plugin data directory was used, else null) |
| `history` | Append-only list of `at`, `event`, `detail` |

## Gate statuses

`pending`, `in-progress`, `passed`, `failed`, `skipped` (safety in plan mode only), `awaiting-approval`, `approved`, `rejected`, `invalidated` (plan changed after approval was requested or given).

## Transition rules enforced by the state module

- A gate can start or pass only when every earlier gate has passed (safety may be `skipped` in plan mode; plan approval counts when `approved`).
- `discovery` passes only with evidence files; `versionPath` only with a requested target, a source version or user confirmation (never while source signals conflict), a resolved target version, the target's LTS status and .NET version, and a selected path with its decision id; `safety` only in upgrade mode, with `guardSelfTest = passed`, a recorded upgrade branch, and a rollback document.
- `planApproval` moves to `awaiting-approval` through `request-plan-approval` (binds the plan hash) and to `approved` or `rejected` through `approve`.
- Phases are frozen once the plan is approved. A phase starts (`in-progress`) only while the approved plan is unchanged, after gate 3 passed, and when every earlier phase is `done` or `deferred`.
- An acceptance criterion is `met` only with evidence files under `.umbraco-upgrade/`, and `waived` only with the user's words. A phase is `done` only when every acceptance criterion is met or waived and a checkpoint commit is recorded.
- An unresolved item moves to `decided` or `resolved` only with the id of the decision that records the user's answer.
