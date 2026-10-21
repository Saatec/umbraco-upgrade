---
name: upgrade-workflow
description: Internal gate engine for the umbraco-upgrade commands. Loaded by /umbraco-upgrade:start and /umbraco-upgrade:plan; not for direct use.
user-invocable: false
---

# Upgrade workflow (gate engine)

You run a fixed sequence of gates for one project. The caller gives you: the project root, the requested target, the mode (`upgrade` for start, `plan` for plan), the session id, and the plugin data directory.

## Rules that apply at every step

- **Gates are never skipped, merged, or reordered.** Gate 1 Discovery, gate 2 Version and path, gate 3 Safety (upgrade mode only), gate 4 Plan approval. Gate 5 (final verification) belongs to a later plugin version.
- **State changes only through the state script.** Never write `.umbraco-upgrade/state.json` with Write or Edit; the safety hook blocks it. Load the `umbraco-upgrade:upgrade-state` skill for the commands.
- **Ask only what inspection cannot determine.** Run the scripts first; ask the user only about conflicts, missing facts, and decisions that are theirs.
- **Version facts come from the version knowledge and live official documentation**, through the `version-path` and `doc-retrieval` skills, each with its source URL, the version the source applies to, and a date. Never state an LTS status, .NET requirement, support date, minimum upgrade-from version, or upgrade path from memory. A fact without a primary source is written as "unverified" (or "secondary") and cannot satisfy a gate criterion on its own.
- **Never print secrets.** View configuration only through `Read-RedactedConfig.ps1`. Never quote connection strings, keys, or passwords, even partly.
- **Never remove, stub, or disable custom functionality.** Record anything that cannot be migrated directly as unresolved, with a proposed approach (port, replace, or redesign), and ask.
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

## After gate 4

- **Upgrade mode, user approves:** record it with `state.ps1 approve -ProjectRoot "<root>" -Action start-plan-execution -Decision approved -Note "<user's words>"`. Then tell the user: the approval is recorded (give the approval id), it is bound to the current plan text, and **plan execution is not available in this plugin version yet**. Stop.
- **Upgrade mode, user asks for changes:** edit the plan files, run `state.ps1 request-plan-approval` again (the plan hash changes), and ask again.
- **Upgrade mode, user rejects:** record `-Decision rejected` and stop.
- **Plan mode:** report where the plan is and stop. Approval and execution happen through `/umbraco-upgrade:start`.

## First run

When `state.ps1 init` creates `.umbraco-upgrade/`, tell the user what it contains (state, plan files, redacted evidence; see `.umbraco-upgrade/README.md`) and ask them to choose one option. Record it with `Set-StateFolderPolicy.ps1 -ProjectRoot "<root>" -Policy <choice>`:

- `commit`: commit the folder on the upgrade branch (at the first checkpoint, in a later version)
- `exclude-local`: ignore it locally through `.git/info/exclude`; no tracked file changes (applied now in upgrade mode)
- `gitignore`: add it to `.gitignore` on the upgrade branch (applied only after gate 3)

In plan mode the choice is only recorded.
