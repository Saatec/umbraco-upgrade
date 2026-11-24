# Running outside Claude Code

The skills and scripts also run under GitHub Copilot, OpenAI Codex, and Cursor. The skills are written for Claude Code, so read them with the rules below. In Claude Code, ignore this file.

## Paths and values

- **`${CLAUDE_PLUGIN_ROOT}`** is the plugin folder: the folder that holds `skills/`, `scripts/`, and `knowledge/`. This file is `<plugin folder>/skills/upgrade-workflow/references/other-tools.md`. Put the full path in every command. Never leave `${CLAUDE_PLUGIN_ROOT}` in a command: PowerShell reads it as an empty variable.
- **`${CLAUDE_PLUGIN_DATA}`** is the data folder: the `UMBRACO_UPGRADE_DATA` environment variable if it is set, otherwise `.umbraco-upgrade/data` in the user's home folder (on Windows `%USERPROFILE%\.umbraco-upgrade\data`). The safety hooks use the same folder.
- **`${CLAUDE_SESSION_ID}`** is not available. Leave out the session id and skip the session marker step (`state.ps1 session-marker`). Work with the project folder as the working folder, so the safety hooks find the project.
- **`$ARGUMENTS`**: if it was not replaced, take the target version and the project path from the user's message.

## Skills and subagents

- "Load the `umbraco-upgrade:<name>` skill" means: read `<plugin folder>/skills/<name>/SKILL.md` and follow it.
- `allowed-tools` in skill frontmatter applies to Claude Code only.
- The subagents `umbraco-upgrade:inventory-analyst`, `umbraco-upgrade:docs-researcher`, and `umbraco-upgrade:independent-verifier` are described in `<plugin folder>/agents/<name>.md`. If your tool cannot run them as subagents, do the task yourself with the instructions in that file.
- The commands are the skills `start`, `plan`, `resume`, `verify`, `report`, and `update-knowledge`. Start them the way your tool starts skills.

## Safety hooks

Install the hooks before gate 1, the first time in a project and again after each plugin update:

- **Cursor:** the hooks come with the plugin. Nothing to install.
- **GitHub Copilot:** run `powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin folder>/scripts/Install-HostHooks.ps1" -Tool copilot -ProjectRoot "<project>"`.
- **OpenAI Codex:** run the same script with `-Tool codex`. Then ask the user to open `/hooks` in Codex and trust the umbraco-upgrade hooks. Codex runs project hooks only in trusted projects.

The script writes one hook file into the project and excludes it from git. Show the user its `nextSteps`. If it stops because the hook file is tracked in git, show the message and stop.

The gate 3 guard self-test proves that the hooks are active. If it fails, stop as the safety-setup skill says, and tell the user which setup step above is missing.

**Approvals.** Copilot, and Cursor for shell commands, show the user a prompt for operations that need approval. Codex, and Cursor for file edits, cannot ask: the guard blocks the operation and gives the reason. Ask the user to run that operation themselves, or follow the skill's approval steps and try again.

**Secrets.** Copilot gets tool output with secret values replaced. Codex withholds any tool output that holds secret values. Cursor blocks reading a file that holds secret values. In every tool, read configuration files only with `Read-RedactedConfig.ps1`.
