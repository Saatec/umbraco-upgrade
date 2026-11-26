---
name: upgrade-workflow
description: Internal gate engine for the umbraco-upgrade commands. Loaded by /umbraco-upgrade:start, /umbraco-upgrade:plan, and /umbraco-upgrade:resume; not for direct use.
user-invocable: false
---

# Upgrade workflow (gate engine)

You run a fixed sequence of gates for one project. The caller gives you: the project root, the requested target, the mode (`upgrade` for start, `plan` for plan), the session id, and the plugin data directory. After `/umbraco-upgrade:resume`, the caller also gives the position reconciliation found (a gate or a phase): continue from there, in the same order. After `/umbraco-upgrade:start` reused a plan-only run (`state.ps1 adopt-plan`), the caller gives the first gate that has not passed, usually gate 3: continue from there.

## Rules that apply at every step

- **Gates are never skipped, merged, or reordered.** Gate 1 Discovery, gate 2 Version and path, gate 3 Safety (upgrade mode only), gate 4 Plan approval, then plan execution (upgrade mode, after approval), then gate 5 Final verification and report (upgrade mode, after the last phase).
- **State changes only through the state script.** Never write `.umbraco-upgrade/state.json` with Write or Edit; the safety hook blocks it. Load the `umbraco-upgrade:upgrade-state` skill for the commands.
- **Ask only what inspection cannot determine.** Run the scripts first; ask the user only about conflicts, missing facts, and decisions that are theirs.
- **Version facts come from the version knowledge and live official documentation**, through the `version-path` and `doc-retrieval` skills, each with its source URL, the version the source applies to, and a date. Never state an LTS status, .NET requirement, support date, minimum upgrade-from version, or upgrade path from memory. A fact without a primary source is written as "unverified" (or "secondary") and cannot satisfy a gate criterion on its own.
- **Never print secrets.** View configuration only through `Read-RedactedConfig.ps1`. Never quote connection strings, keys, or passwords, even partly.
- **Never remove, stub, or disable custom functionality to make the project compile.** Record anything that cannot be migrated directly as unresolved, with a proposed approach (port, replace, or redesign), and ask. Details: [references/migration-rules.md](references/migration-rules.md).
- **Follow the execution policy** in [references/execution-policy.md](references/execution-policy.md).

Every script is run the same way. `<Script>` is a file under `${CLAUDE_PLUGIN_ROOT}/scripts/`:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" <arguments>
```

Each script prints JSON. Read `ok` and the messages; do not guess at results.

## Gate sequence

Details, entry and exit criteria: [references/gates.md](references/gates.md).

1. **Gate 1, Discovery.** Load `umbraco-upgrade:discovery` and follow it.
2. **Gate 2, Version and path.** Load `umbraco-upgrade:version-path` and follow it.
3. **Gate 3, Safety.**
   - Upgrade mode: load `umbraco-upgrade:safety-setup` and follow it. If it stops, the workflow stops.
   - Plan mode: do not run it. Mark it skipped: `state.ps1 gate -ProjectRoot "<root>" -Gate safety -Status skipped -Notes "plan-only mode"`. The plan describes what gate 3 will do.
4. **Gate 4, Plan approval.** Load `umbraco-upgrade:upgrade-planning` and follow it. It writes the plan and asks for approval in upgrade mode. Then **stop and wait** for the user. Approval rules: [references/approval-protocol.md](references/approval-protocol.md).
5. **Gate 5, Final verification and report.** Upgrade mode only, after every phase is done or deferred (see "After gate 4").

## After gate 4

- **Upgrade mode, user approves:** record it with `state.ps1 approve -ProjectRoot "<root>" -Action start-plan-execution -Decision approved -Note "<user's words>"`. Tell the user the approval id and that it is bound to the current plan text. Then execute the plan: follow [references/phase-execution.md](references/phase-execution.md). Each phase runs through its owning `migrate-*` skill and ends with a checkpoint commit and a state checkpoint.
- **Upgrade mode, user asks for changes:** edit the plan files, run `state.ps1 request-plan-approval` again (the plan hash changes), and ask again.
- **Upgrade mode, user rejects:** record `-Decision rejected` and stop.
- **Plan mode:** report where the plan is and stop. Approval and execution happen through `/umbraco-upgrade:start <target>` in the same project: it reuses this plan, runs gate 3, and asks for approval.
- **After the last phase:** run gate 5. Load `umbraco-upgrade:verification` and follow it: automated checks, the independent verifier, the manual checklist with the user, then the report (`umbraco-upgrade:reporting`). Gate 5 passes only when no check is open or failed.

## First run

When `state.ps1 init` creates `.umbraco-upgrade/`, tell the user what it contains (state, plan files, redacted evidence; see `.umbraco-upgrade/README.md`) and ask them to choose one option. Record it with `Set-StateFolderPolicy.ps1 -ProjectRoot "<root>" -Policy <choice>`:

- `commit`: commit the folder on the upgrade branch (with every checkpoint commit)
- `exclude-local`: ignore it locally through `.git/info/exclude`; no tracked file changes (applied now in upgrade mode)
- `gitignore`: add it to `.gitignore` on the upgrade branch (applied only after gate 3)

In plan mode the choice is only recorded.
