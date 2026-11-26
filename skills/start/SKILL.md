---
name: start
description: Start an Umbraco CMS major-version upgrade. Runs discovery, version checks, and safety setup, writes a plan, stops for your approval, then executes it phase by phase with checkpoints. Reuses a plan made by /umbraco-upgrade:plan for the same target.
argument-hint: <target-version> [project-path]
arguments: [target, path]
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# /umbraco-upgrade:start

Arguments as typed: `$ARGUMENTS`

Outside Claude Code (GitHub Copilot, OpenAI Codex, Cursor), first read [other-tools.md](../upgrade-workflow/references/other-tools.md).

## 1. Validate the arguments

If more than two arguments were given, stop and print the usage line below.

Run (from the session's working directory):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-UpgradeArguments.ps1" -Command start -Target "$target" -Path "$path"
```

If no project path was given, leave out `-Path` and its empty value: Windows PowerShell drops an empty argument, and the script then stops with a missing-argument error.

- If `ok` is false, show each error message exactly, show the usage line, and stop. Do not create anything.
- Show any warnings to the user before continuing.
- Use `projectRoot` from the output as the project path for every later step.

Usage: `/umbraco-upgrade:start <target-version> [project-path]`, for example `/umbraco-upgrade:start 17` or `/umbraco-upgrade:start 17.2.0 C:\src\MySite`.

## 2. Reuse a plan-only run

Skip this step unless `stateMode` in the output of step 1 is `plan`. Then the project already holds a run of `/umbraco-upgrade:plan` for this target (`planRun` in the output). Start reuses it: discovery, the version and path, the decisions, and the plan stay; gate 3 runs now, and the plan is approved again before anything executes.

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

1. If the project root is not the session's working directory or below it, run `state.ps1 session-marker -ProjectRoot "<root>" -SessionId "${CLAUDE_SESSION_ID}" -DataDir "${CLAUDE_PLUGIN_DATA}"`, so the safety hooks see the project.
2. `Test-StateReality.ps1 -ProjectRoot "<root>"`. It is read-only. It compares the plan-only run with the repository and the files as they are now.
   - **Any mismatch:** report each one (what the plan expects, what was found, its `options`), then stop and ask. Never repair anything to make them agree. When the user has fixed it, they run `/umbraco-upgrade:start` again. To start over instead, they move or remove `.umbraco-upgrade/` themselves.
   - **A warning about the repository or the packages** (for example new commits since discovery): tell the user, and ask whether to reuse the plan or start over. Continue only when they choose to reuse it. A warning that the folder policy is undecided needs no answer here: gate 3 asks for it.
3. Tell the user that a plan-only run from `planRun.createdAt` was found and that start reuses it.
4. `state.ps1 adopt-plan -ProjectRoot "<root>" -Target "<target.requested from step 1>"`. If `ok` is false, show the error and stop.
5. If `project.stateFolderPolicy` is `exclude-local`, apply it now: `Set-StateFolderPolicy.ps1 -ProjectRoot "<root>" -Policy exclude-local`. Plan mode only recorded it. (`gitignore` is applied at the end of gate 3, and `commit` needs nothing now.)
6. Continue with step 3 from the first gate in `gates` (from the `adopt-plan` output) that is not `passed`. For a finished plan, that is gate 3.

## 3. Run the workflow

Load the `umbraco-upgrade:upgrade-workflow` skill with the Skill tool and follow it in **upgrade mode** with:

- project root: `projectRoot` from step 1
- requested target: `target.requested` from step 1
- session id: `${CLAUDE_SESSION_ID}`
- plugin data directory: `${CLAUDE_PLUGIN_DATA}`
- after step 2: the gate to continue from

The workflow runs gates 1 to 4 and stops at gate 4 for approval. After the user approves in chat, it executes the plan phase by phase, each phase ending with a checkpoint commit on the upgrade branch. After the last phase it runs final verification and writes the report (gate 5). An interrupted upgrade continues with `/umbraco-upgrade:resume`.
