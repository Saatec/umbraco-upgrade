---
name: start
description: Start an Umbraco CMS major-version upgrade. Runs discovery, version checks, and safety setup, writes a plan, stops for your approval, then executes it phase by phase with checkpoints.
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

## 2. Run the workflow

Load the `umbraco-upgrade:upgrade-workflow` skill with the Skill tool and follow it in **upgrade mode** with:

- project root: `projectRoot` from step 1
- requested target: `target.requested` from step 1
- session id: `${CLAUDE_SESSION_ID}`
- plugin data directory: `${CLAUDE_PLUGIN_DATA}`

The workflow runs gates 1 to 4 and stops at gate 4 for approval. After the user approves in chat, it executes the plan phase by phase, each phase ending with a checkpoint commit on the upgrade branch. After the last phase it runs final verification and writes the report (gate 5). An interrupted upgrade continues with `/umbraco-upgrade:resume`.
