# Umbraco Upgrade

A Claude Code plugin that plans and runs Umbraco CMS major-version upgrades: from legacy Umbraco 7 and 8, through 9 to 13, to current versions such as 17 and 18, and later LTS releases once their facts are verified.

It discovers the project, selects an upgrade path from versioned knowledge and live official documentation, writes a phased plan and stops for your approval, executes the plan on a dedicated branch with a checkpoint commit per phase, verifies the result, and writes a report that separates what was verified automatically, what you verified manually, and what was not verified.

Status: version 0.1.0, the first release. Tested on Windows only (see [Tested platforms](#tested-platforms)). Provided without warranty (see [License and no warranty](#license-and-no-warranty)).

## Contents

- [Install](#install)
- [Prerequisites](#prerequisites)
- [Commands](#commands)
- [How an upgrade runs: the gates](#how-an-upgrade-runs-the-gates)
- [Approvals](#approvals)
- [Supported scenarios and limitations](#supported-scenarios-and-limitations)
- [Safety hooks](#safety-hooks)
- [Scripts](#scripts)
- [Network access](#network-access)
- [Privacy and telemetry](#privacy-and-telemetry)
- [What the plugin writes into your project](#what-the-plugin-writes-into-your-project)
- [Plugin data directory](#plugin-data-directory)
- [Version facts and secondary sources](#version-facts-and-secondary-sources)
- [Tested platforms](#tested-platforms)
- [Development](#development)
- [License and no warranty](#license-and-no-warranty)

More documentation: [example prompts](docs/example-prompts.md), [manual validation procedure](docs/manual-validation.md), [architecture](docs/architecture.md), [changelog](CHANGELOG.md), [evals](evals/README.md).

## Install

### From this plugin's marketplace

This repository is its own marketplace (named `umbraco-upgrade`). In a Claude Code session, add the marketplace, then install the plugin:

```
/plugin marketplace add progproger/umbraco-upgrade
/plugin install umbraco-upgrade@umbraco-upgrade
```

On Claude Code 2.1.275 or later you can do both in one step:

```
/plugin install umbraco-upgrade --marketplace progproger/umbraco-upgrade
```

In a session, `/plugin install` opens the plugin's details and asks for an installation scope before it installs anything.

From your shell instead:

```
claude plugin marketplace add progproger/umbraco-upgrade
claude plugin install umbraco-upgrade@umbraco-upgrade --scope project
```

**Recommended scope: project or local, in the repository you upgrade.** The safety hooks start a PowerShell process on every shell, write, and search tool call in every session where the plugin is enabled, even outside upgrade projects (see [Hook cost](#hook-cost)). Project scope (`.claude/settings.json`, committed) enables the plugin for everyone who works in that repository; each collaborator still runs the install command once. Local scope (`.claude/settings.local.json`) enables it for you in that repository only. User scope enables it in every project on your machine.

Updates: the marketplace has auto-update off by default (it is a third-party marketplace). Run `claude plugin update umbraco-upgrade@umbraco-upgrade` to update.

### From Anthropic's community marketplace (once listed)

The plugin is not listed in the community marketplace yet. Once it is, add that marketplace and install with its `@claude-community` suffix:

```
/plugin marketplace add anthropics/claude-plugins-community
/plugin install umbraco-upgrade@claude-community
```

### Local development

Load a clone for one session without installing it:

```
git clone https://github.com/progproger/umbraco-upgrade
claude --plugin-dir ./umbraco-upgrade
```

A plugin loaded this way has the id `umbraco-upgrade@inline` and its own data directory (see [Plugin data directory](#plugin-data-directory)).

## Prerequisites

| Requirement | Why |
|---|---|
| Claude Code 2.1.295 or later | The guard hook uses `onFailure: "block"`, which needs 2.1.295. The session note warns when Claude Code is older. |
| Windows PowerShell 5.1 (built into Windows) or PowerShell 7 | Every script and hook is PowerShell. Hooks start `powershell`; on macOS and Linux that command must exist and start `pwsh` (a shim). Not tested on macOS or Linux. |
| Git | `/umbraco-upgrade:start` needs the project in a Git repository with at least one commit (gate 3 creates the upgrade branch). `/umbraco-upgrade:plan` also works in a folder that is not a repository. |
| Network access to the hosts in [Network access](#network-access) | Version facts, documentation, and package metadata. Without network the plugin works from its cache and the shipped knowledge, and marks what it could not check as unverified. |
| .NET SDK for the target framework (execution and gate 5 only) | Builds, view precompilation, and tests during the phases and at gate 5. Planning does not build anything. |
| Optional: a local, restored copy of the site's database | Database snapshots, read-only health counts, and migrations run only against a local copy you declare. The plugin never connects to any other database. |
| Optional: the official `context7` plugin | A documentation search aid. Install it separately with `/plugin install context7@claude-plugins-official`. This plugin does not bundle it, and treats its results as secondary pointers to official pages (see [Version facts and secondary sources](#version-facts-and-secondary-sources)). It connects to Context7's hosted service. |

## Commands

Every command validates its arguments first (target format `<major>[.<minor>[.<patch>]]`, the path exists, the path holds an Umbraco project) and fails with a specific message otherwise. `project-path` defaults to the current working directory. Claude never starts these commands on its own: only you can run them.

| Command | What it does | Where it stops |
|---|---|---|
| `/umbraco-upgrade:start <target-version> [project-path]` | Starts a new upgrade: gates 1 to 4, then, after your approval, the plan phases and gate 5. A bare major such as `17` means the latest released version of that major. | At gate 4, waiting for your approval. After approval it continues phase by phase. |
| `/umbraco-upgrade:plan <target-version> [project-path]` | Discovery and plan only: gates 1, 2, and 4. Gate 3 is described in the plan but not run, because it creates a branch. Changes nothing in the project except `.umbraco-upgrade/`. | After writing the plan. Execution happens through `start` in a project without this state. |
| `/umbraco-upgrade:resume [project-path]` | Continues an interrupted upgrade. First compares the recorded state with the repository and the files (branch, HEAD, checkpoint commits, uncommitted changes, plan hash, cited files, CMS version, declared database copy). | On any mismatch: it reports what differs and asks. It never repairs or repeats a phase on its own. |
| `/umbraco-upgrade:verify [project-path]` | After the last phase: gate 5 final verification (automated checks, an independent review, a manual checklist for you). During an upgrade: an interim check that records nothing. | After the report, or while waiting for your answers to the manual checks. |
| `/umbraco-upgrade:report [project-path]` | Writes or rewrites `.umbraco-upgrade/report.md` from the state, the evidence, and the decisions, at any point. | After writing the report. |
| `/umbraco-upgrade:update-knowledge` | Refreshes version facts (releases, LTS labels, .NET requirements, docs spaces, support dates) from public sources into the plugin data directory, and writes a diff for the plugin maintainer. | After the refresh report. It never writes into a project or into the plugin's install directory. |

Example prompts for common scenarios: [docs/example-prompts.md](docs/example-prompts.md).

## How an upgrade runs: the gates

The workflow has a fixed skeleton of gates. They are never skipped, merged, or reordered.

1. **Discovery** (read-only): repository and Git status, solutions and projects, target frameworks, packages, Umbraco version signals, configuration (with secrets redacted), and customizations found by a registry of detectors. It writes `inventory.md` and redacted evidence.
2. **Version and path**: resolves the target release, its .NET requirement, LTS status, and support dates; builds candidate paths (in place, staged through intermediate majors, a rebuild that carries the database through intermediate versions, or a new installation with content transfer); applies the documented rules, such as "upgrade to the closest LTS major first"; and records the chosen path, the alternatives, and the sources in `decisions.md`.
3. **Safety setup** (start only): checks that the working tree has no uncommitted changes (if it has, it stops and asks; it never stashes, resets, or discards your changes), creates the upgrade branch, writes the backup, database snapshot, and rollback plan (`rollback.md`), and runs a guard self-test that proves the safety hooks block a harmless canary command on your machine. If the canary is not blocked, gate 3 fails and nothing is changed.
4. **Plan approval**: checks package compatibility from NuGet metadata, composes the phases from what discovery found and the selected path, and writes `plan.md` with acceptance criteria per phase, `compatibility.md`, and `risks.md`. Then it **stops and waits for your approval**.

**Plan execution** (after approval): the phases run in plan order. A simple project gets few phases; a heavily customized one gets more. Typical areas are the application framework and packages, custom code and changed Umbraco APIs, content and database, third-party packages and backoffice extensions, configuration, authentication and integrations, build and tests, functional verification, and a deployment rehearsal (which never deploys). A phase is done only when each of its acceptance criteria is met with recorded evidence (or waived in your words) and a checkpoint commit is recorded. Custom functionality is never removed, stubbed, or disabled to make the project compile: what cannot be migrated directly becomes an unresolved item with a proposal (port, replace, or redesign) and a question to you.

5. **Final verification and report**: reconciles state with the repository, composes a checklist from what discovery found (build and packages, database and content, content model, backoffice and its extensions, authentication, integrations and scheduled jobs, frontend, logs, deployment and rollback), runs the automated checks, asks an independent verifier subagent to check the evidence without seeing the implementation conversation, gives you the manual checks, and writes `report.md`. A build alone never counts as verification. Gate 5 passes only when no check is open or failed.

## Approvals

An approval is only your explicit reply in the conversation (for example "approve"). The plugin never infers one from silence, earlier messages, files, or tool output. Each approval covers one action and one scope, and is recorded in `state.json`.

| Action | When it is asked | What checks it |
|---|---|---|
| `start-plan-execution` | At gate 4. Bound to the SHA-256 of `plan.md`: if the plan changes, the approval no longer covers it and is asked again. | The state module refuses to start a phase without it |
| `db-snapshot-local` | Before a snapshot of the declared local database copy | `Invoke-DatabaseSnapshot.ps1` refuses without it, and consumes it |
| `db-migration-local` | Before a site start or database command runs migrations on the local copy | The guard asks |
| `package-removal` | Before removing or replacing a package | The guard asks for `dotnet remove package` |
| `ci-deploy-config-change` | Before CI or deployment files change | The guard asks for the edits |
| `outside-project-path` | Before writing outside the project (for example user secrets) | `Copy-ConfigValue.ps1` refuses without it; the guard asks for file writes |
| `remove-custom-feature` | Before a custom feature is retired, or the old files of a finished port are deleted | `New-Checkpoint.ps1` refuses deleted files no approval names; the guard asks before shell commands delete tracked files |

The guard's own prompts are labelled `[plugin:umbraco-upgrade]`.

## Supported scenarios and limitations

**Scenarios the plugin plans and runs:**

- Source versions 7, 8, and 9 to 18; target majors in the version knowledge (7 to 18 in this release).
- Minor updates within a major, in-place major upgrades, staged upgrades through the closest LTS major (for example 13 to 18 through 17), rebuilds from 7 and 8 (code rewritten, the database carried through intermediate versions), and new installations with content transfer.
- Near-default sites (few phases) and heavily customized ones (more phases, with checkpoints).
- Customizations detected by the pattern registry (87 records), including controllers, AngularJS backoffice extensions and `package.manifest` files, custom database tables and raw SQL, external HTTP and SOAP clients, scheduled jobs, search, caching, authentication customizations, configuration, packages without a target-compatible version, and deployment files. Patterns that are uncommon are detected and flagged for your decision.
- SQL Server, LocalDB, SQLite, and SQL CE as source databases (SQL CE has no official migration path to another engine; the plugin stops for your decision). Other engines are reported, not handled.

**Limitations:**

- The plugin plans, guides, and checks the migration of custom code. It does not port code on its own without you: decisions about features stay yours. AngularJS backoffice extensions must be rewritten for Umbraco 14 and later; the guidance comes from the official migration articles, and migration quality is checked only through acceptance criteria and your manual checks.
- A target major that is not in the knowledge (for example a future release) blocks gate 2 until its facts are confirmed from official pages or refreshed with `/umbraco-upgrade:update-knowledge`. Pre-releases are not upgrade targets.
- LTS status for 7 to 10 and every support and end-of-life date come from a secondary source, because the official LTS page answers automated requests with a bot challenge. Confirm them on the official page.
- Command analysis in the guard is best effort. Commands built from variables, scripts the guard cannot see into, and searches over whole directories are not caught. Encoded PowerShell commands are blocked in upgrade projects.
- An installed mod that handles tool checks can override a hook block, and `claude --bare` loads no plugins. Use a normal session for upgrades.
- Real Umbraco runtime behavior (booting the site, running migrations, the backoffice) is not covered by the automated tests. Use the [manual validation procedure](docs/manual-validation.md).
- Umbraco Commerce, Workflow, Deploy, and Courier are detected and flagged for your decision, not migrated. Umbraco Forms is detected, and its version and license requirements for the target are cited.
- Built for Claude Code (terminal, IDE extensions, and the desktop app's Code tab). In claude.ai chat, plugin hooks and agents are not loaded and there is no shell to run the scripts, so the plugin does not work there. Cowork is not tested.
- Tested on Windows only. See [Tested platforms](#tested-platforms).

## Safety hooks

The plugin's hooks (`hooks/hooks.json`) enforce the prohibited tier deterministically, not by instructions alone. All are exec-form `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/<script>`, with a 30-second timeout.

**Scope.** Every hook script first checks whether the session is in an upgrade project: a folder with `.umbraco-upgrade/state.json` found from the hook's working directory, the session's project directory, or their parents; a session marker written when the project is outside the session's directory; or a directory the command names (such as `git -C <path>` or `cd <path>`). Outside upgrade projects every hook exits 0 with no output and changes nothing.

| Event and matcher | Script | What it does in an upgrade project |
|---|---|---|
| `PreToolUse` on `Bash` and `PowerShell` | `scripts/hooks/guard.ps1` | Parses the command (quoting, chains, pipes, subshells, `bash -c`, `powershell -Command`, `cmd /c`, common aliases) and blocks prohibited operations with exit code 2: force push, history rewrites (rebase, filter-branch, filter-repo, replace, amending a pushed commit), branch deletion, discarding uncommitted changes (`reset --hard`, `checkout --`, `restore`, `clean -f`, stash drop), database commands against a non-local database, deployments and remote publishing, printing environment variables wholesale or dumping secret-bearing files, and encoded PowerShell commands. Asks before a non-force push, a site start, a database migration, a package removal, and deleting tracked project files that no approval names. Recognizes the gate 3 canary and writes a nonce-bound evidence file for the self-test. Any internal error blocks (fail-closed). |
| `PreToolUse` on `Write`, `Edit`, `NotebookEdit` | `scripts/hooks/guard.ps1` | Blocks direct writes to `state.json`, secret-looking content in `.umbraco-upgrade/`, project file changes in plan mode, before gate 3 and plan approval, or off the upgrade branch. Asks before CI or deployment files change and before writes outside the project. |
| `PreToolUse` on MCP tools whose names suggest a database | `scripts/hooks/guard.ps1` | Blocks them unless you declared a local database copy, and then asks. |
| `PostToolUse` on `Read` of secret-bearing files (`appsettings*.json`, `*.config`, `secrets.json`, `.env*`, `*.pubxml*`, `*.publishsettings`, filtered by the hook's `if` rules) | `scripts/hooks/redact-output.ps1` | Replaces secret values in what Claude sees with `***REDACTED***`, keeping the tool's output shape. |
| `PostToolUse` on `Grep`, `Bash`, and `PowerShell` | `scripts/hooks/redact-output.ps1` | Redacts secret values in search results and in the output of shell commands (for example `git show` of a settings file). This hook has no `if` filter, so it starts on every such call. It never blocks: a failure leaves the output as it was. |
| `SessionStart` | `scripts/hooks/session-context.ps1` | Adds a short note to the session: an upgrade is in progress, its mode, target, gates, the phase in progress, that the safety hooks are active, the no-removal rule, and that `/umbraco-upgrade:resume` continues it. Warns when Claude Code is older than 2.1.295. |

The rules, their ids, and their reasons are data in `scripts/hooks/rules.json`; the logic is in `scripts/hooks/GuardCore.psm1`.

**Failure behavior.** The guard hooks set `onFailure: "block"`: a guard that cannot start, crashes, or times out blocks the tool call. This could affect unrelated projects only if PowerShell itself is missing or hangs. `onFailure` does **not** cover a missing hook script: `powershell -File <missing script>` exits 0, so Claude Code would treat the hook as passed. The gate 3 guard self-test covers this case: if the guard does not block the canary, gate 3 fails and the upgrade does not start.

### Hook cost

Outside upgrade projects the hooks add no model context; inside one, the session note adds a few lines. The plugin's skills and agents add roughly 1,500 to 2,300 tokens of always-on context to every session where it is enabled (the estimate of `claude plugin details umbraco-upgrade@umbraco-upgrade` varies between runs). Each matching tool call starts one Windows PowerShell process, also outside upgrade projects, where the script exits right after its scope check:

- every `Bash` and `PowerShell` call: two starts, the guard before the call and the output redaction after it
- every `Write`, `Edit`, and `NotebookEdit` call: one start (the guard)
- every `Grep` call: one start (the output redaction)
- every `Read` of a file that matches the secret-bearing patterns: one start (the redaction)
- every session start: one start

Measured on Windows: about 240 ms for a start that exits at once, 500 to 700 ms for a start that does more work. Inside an upgrade project the guard may run a few git commands. To avoid the cost elsewhere, install the plugin at project or local scope in the repository you upgrade.

## Scripts

All scripts are PowerShell, written for Windows PowerShell 5.1 and PowerShell 7, ASCII only, and print one JSON object. Skills run them as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>"`. Scripts that change something refuse unless the workflow has reached the point where that change is allowed.

**Arguments, discovery, and inventory (read-only)**

| Script | What it does |
|---|---|
| `Resolve-UpgradeArguments.ps1` | Validates command arguments: target format, path, Umbraco presence, existing state. |
| `Invoke-Discovery.ps1` | Gate 1: runs version detection, inventory, pattern detection, and the database summary; writes redacted evidence under `evidence/discovery/`. |
| `Get-UmbracoVersion.ps1` | Detects the Umbraco version from package references, lock and assets files, central package management, `web.config` status keys, legacy config files, `appsettings.json`, and assembly metadata. |
| `Get-ProjectInventory.ps1` | Lists solutions, projects, target frameworks, package references, loose assemblies, `App_Plugins` folders and manifests, views, configuration, CI, publish, and IIS files. |
| `Find-Patterns.ps1` | Runs the detector registry (`knowledge/patterns/`) and reports hits with redacted one-line snippets, plus unclassified Umbraco usage. |
| `Read-RedactedConfig.ps1` | Shows a configuration file with secret values redacted. Use it instead of printing settings files, which the guard blocks. |
| `Test-DatabaseHealth.ps1` | Read-only catalog counts (size, largest tables, untrusted foreign keys) and block labels written as AngularJS templates on the declared local database copy; refuses any other database. |

**Versions, paths, documentation, and packages (read-only; network through the plugin cache)**

| Script | What it does |
|---|---|
| `Get-VersionKnowledge.ps1` | Reads the version knowledge in the lookup order: refreshed data in the plugin data directory when it is valid and newer, otherwise the shipped baseline. |
| `Select-UpgradePath.ps1` | Builds and ranks candidate paths from the knowledge and discovery, and reports the facts each choice rests on and their status. |
| `Get-NuGetPackageInfo.ps1` | Package versions, target frameworks, dependency ranges, deprecation, and vulnerabilities from the NuGet v3 API. |
| `Get-Doc.ps1` | Fetches official documentation for a specific version, labelled with the version it applies to, with checks for redirects to another version and "Page Not Found" bodies. |
| `Update-Knowledge.ps1` | Refreshes the version knowledge into the plugin data directory and writes a refresh report and a maintainer patch. |

**Planning (read-only on the project)**

| Script | What it does |
|---|---|
| `Test-PackageCompatibility.ps1` | Classifies each direct package reference for the target major from NuGet metadata, and makes no claim when metadata cannot be read. |
| `Get-PhaseComposition.ps1` | Proposes the plan phases from discovery and the selected path (dependency order, splitting large areas, staged paths per stop). |
| `Get-PatternGuidance.ps1` | Prints, per detected pattern, the impacts the upgrade crosses and the handling options for the target, each cited or marked as a hypothesis. |

**Safety (gate 3)**

| Script | What it does |
|---|---|
| `Test-SafetyPreconditions.ps1` | Read-only Git checks: repository, uncommitted changes outside `.umbraco-upgrade/`, operations in progress, remotes (credentials removed from URLs), stash. |
| `New-UpgradeBranch.ps1` | Creates the upgrade branch from a clean tree and records it; refuses otherwise. |
| `Set-StateFolderPolicy.ps1` | Records and applies your choice for `.umbraco-upgrade/`: commit, exclude locally (`.git/info/exclude`), or add to `.gitignore` (only on the upgrade branch after gate 3). In plan mode it only records the choice. |
| `Test-Guard.ps1` | The guard self-test: issues the canary command and verifies the evidence the guard writes when it blocks it. |

**Execution (only after plan approval, on the upgrade branch, in a running phase)**

| Script | What it does |
|---|---|
| `Test-Build.ps1` | Runs `dotnet build` (and `dotnet test`, and view precompilation when asked) and keeps redacted output as evidence. |
| `Copy-ConfigValue.ps1` | Copies or moves one configuration value between files, or into user secrets (approval needed), without printing it. |
| `Invoke-DatabaseSnapshot.ps1` | Snapshots the declared local database copy (file copy, or a copy-only backup) to a folder outside the project; needs the `db-snapshot-local` approval. |
| `New-Checkpoint.ps1` | Ends a phase with a checkpoint commit. Refuses deleted files without a `remove-custom-feature` approval, stubs, and secrets; warns about commented-out code and excluded files. |
| `Write-Evidence.ps1` | Writes evidence under `evidence/<phase or gate>/` with secrets redacted. |

**State, reconciliation, verification, and report**

| Script | What it does |
|---|---|
| `state.ps1` | The only way to change `state.json`: init, gates, approvals, decisions, unresolved items, phases, criteria, checkpoints, failures, the gate 5 checklist and results, schema migration, session markers. |
| `Test-StateReality.ps1` | Resume reconciliation, read-only: compares the state with the repository, the plan hash, the cited files, the CMS version, and the declared database copy, and reports every difference with options. |
| `Get-VerificationPlan.ps1` | Composes the gate 5 checklist and the manual checklist from what discovery and the package check found. |
| `Invoke-Verification.ps1` | Runs the automated gate 5 checks (build and tests evidence, CMS version, package ranges, phase criteria, checkpoints, no removed functionality, no secrets, unresolved items) and records their results; `-Interim` checks an upgrade in progress without recording anything. |
| `New-Report.ps1` | Writes `report.md` from state, evidence, and decisions; links evidence without copying it. |

Libraries live in `scripts/lib/` (state, schema validation, Git, HTTP with the host allowlist, docs, NuGet, knowledge, discovery, redaction, connection-string locality, path selection, planning, execution, reconciliation, verification, report).

## Network access

The scripts reach only the hosts in the allowlist of the shipped `knowledge/sources.json`, enforced in `scripts/lib/Http.psm1`. Refreshed knowledge cannot add hosts.

| Host | Used for |
|---|---|
| `docs.umbraco.com` | Official Umbraco documentation pages and the `llms.txt` index |
| `raw.githubusercontent.com` | Umbraco documentation branches for end-of-life and legacy versions (UmbracoDocs repository) |
| `api.nuget.org` | Package versions, frameworks, dependency ranges, deprecation |
| `builds.dotnet.microsoft.com`, `dotnetcli.blob.core.windows.net` | The official .NET release metadata (support dates) |
| `learn.microsoft.com` | Official .NET and SQL Server documentation |
| `releases.umbraco.com` | Release notes and current release labels |
| `umbraco.com` | The official LTS and end-of-life page (it usually answers automated requests with a bot challenge; the plugin never tries to get past it) |
| `endoflife.date` | Support and end-of-life dates, labelled secondary |

Besides the scripts, Claude may use Claude Code's WebFetch tool for official .NET documentation and for package repositories, changelogs, and migration guides. WebFetch follows your Claude Code permission settings. If you installed the separate context7 plugin, its queries go to Context7's hosted service.

What is sent: requests for public pages and package metadata only. Queries to search services contain generic terms (API names, versions, error messages without project identifiers). One thing comes from your project: the package check looks up each direct package reference on api.nuget.org by its id, so the ids of your package references (private ones included) appear in those requests. No code, configuration value, secret, or file content is sent by the plugin.

Responses are cached in the plugin data directory, so a resumed upgrade can reuse them and the plugin keeps working with reduced capability when offline.

## Privacy and telemetry

The plugin collects no telemetry and has no analytics, tracking, or phone-home of its own. It sends nothing about you or your project anywhere except the requests listed in [Network access](#network-access). Claude Code's own data handling is governed by Claude Code's settings, not by this plugin.

Secrets are never printed, logged, or written by the plugin: discovery and evidence are redacted at the source, the hooks redact what Claude sees, the state refuses content that looks like a secret, and connection strings are reduced to "local" or "non-local".

**The plugin never touches production.** It never deploys, never connects to a shared, staging, or production database (database work runs only against a local copy you declare), never force-pushes, rewrites history, or deletes branches, and never discards your uncommitted changes. The safety hooks block these operations in upgrade projects. Deployment and production configuration stay yours: the report lists them as manual follow-ups.

## What the plugin writes into your project

Everything the plugin records lives in the project under `.umbraco-upgrade/`. On the first run it explains this folder and asks whether you want to commit it, exclude it locally (`.git/info/exclude`), or add it to `.gitignore`.

| Path | Contents |
|---|---|
| `README.md` | What the folder is |
| `state.json` | Machine-readable progress: versions, chosen path, gates, phases, checkpoint commits, approvals, decisions, unresolved items, verification results, history. Versioned schema (`schemas/state.schema.json`); changed only through `state.ps1`. |
| `inventory.md` | What discovery found, by area |
| `plan.md` | Phases, acceptance criteria, risks, rollback, what each gate does |
| `compatibility.md` | Package and framework compatibility for the target |
| `risks.md` | Risk register |
| `decisions.md` | Each decision with its sources (URL, the version it applies to, date) |
| `rollback.md` | Backup, database snapshot, and rollback plan (gate 3) |
| `report.md` | The report: verified automatically, verified manually, not verified, decisions, unresolved items, follow-ups |
| `evidence/<gate or phase>/` | Outputs of checks and builds, redacted |
| `tmp/` | Short-lived files that scripts read and remove |

In upgrade mode the plugin also creates the upgrade branch (`umbraco-upgrade/<source major>-to-<target>`) at gate 3, changes project files on that branch only after you approve the plan, and ends each phase with a checkpoint commit. In plan mode it changes nothing outside `.umbraco-upgrade/` and creates no branch.

## Plugin data directory

Caches live in `${CLAUDE_PLUGIN_DATA}`, never in the plugin's install directory (which is replaced on every update). For an install from this marketplace that is `~/.claude/plugins/data/umbraco-upgrade-umbraco-upgrade/`; for the community marketplace `~/.claude/plugins/data/umbraco-upgrade-claude-community/`; for `--plugin-dir`, `~/.claude/plugins/data/umbraco-upgrade-inline/`. It holds no project state.

| Path | Contents |
|---|---|
| `doc-cache/` | Fetched documentation pages, NuGet responses, and release metadata, each with its URL, final URL, version label, fetch time, HTTP status, and SHA-256. Docs pages are reused for 7 days, NuGet version lists for 1 day, package specifications for a year. Not pruned automatically. |
| `knowledge/` | Refreshed version knowledge from `/umbraco-upgrade:update-knowledge` (`versions.json`, `paths.json`, `packages.json`, `sources.json`), `refresh-report.md` and `.json`, and `maintainer.patch` |
| `active-sessions/<session id>.json` | Session markers: when the project is outside the session's working directory, the marker tells the hooks which project to guard. Removed when gate 5 passes. |

Claude Code deletes this directory when you uninstall the plugin from its last scope, unless you pass `--keep-data`.

**`UMBRACO_UPGRADE_HTTP_MOCK`** is a test seam for the plugin's own tests. When it names one or more folders of recorded responses (separated by `;`), every HTTP request is answered from those files and no request leaves the machine; unrecorded URLs fail as network errors. Do not set it in normal use: the plugin would then work from recorded, possibly outdated responses.

## Version facts and secondary sources

Version facts are data, not code. The shipped knowledge (`knowledge/versions.json`, `paths.json`, `packages.json`, `sources.json`) records for each fact its value, a status (`verified`, `secondary`, `unverified`, `needs-review`), the source URL, the source type, the version the source belongs to, what it applies to, and the date it was verified. Many facts also carry a short evidence phrase that `update-knowledge` and gate 2 re-check on the source page. The plugin uses the refreshed copy in the plugin data directory when it is valid and newer, and the shipped baseline otherwise.

Documentation follows the official Umbraco documentation for the exact version first, then official .NET documentation, then NuGet package metadata, then package repositories, changelogs, and migration guides.

**Secondary sources** are never authoritative and are always labelled "secondary": endoflife.date (support and end-of-life dates, because the official LTS page blocks automated requests), the documentation platform's generated answers, and Context7. A secondary fact cannot satisfy a gate on its own: the plugin asks you to confirm it on the official page, and records what you confirmed. Anything the plugin cannot confirm from a primary source is written as "unverified". It never invents APIs, package replacements, migration commands, or compatibility claims.

## Tested platforms

| Platform | Status |
|---|---|
| Windows 11 with Windows PowerShell 5.1, Claude Code 2.1.301 | Tested: the Pester suites, the hook tests, and `claude -p --plugin-dir` integration runs |
| PowerShell 7 on Windows | Not tested |
| macOS and Linux (scripts and hooks through a `powershell` command that starts `pwsh`) | Not tested |
| `claude plugin eval` cases (`evals/`) | Written, not run: they grant shell tools, which need an OS sandbox that native Windows lacks |

## Development

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Integration
claude plugin validate . --strict
```

- The tests need Pester 5 or later (developed with Pester 6.2.0). Every test carries one label: `mocked`, `fixture-based`, `eval`, or `real-project`. Fixtures under `tests/fixtures/` are synthetic and written from scratch; recorded HTTP responses are in `tests/fixtures/mocks/` (see its `NOTICE.md`).
- `-Integration` adds a few `claude -p --plugin-dir` runs that use model calls, each capped with `--max-budget-usd`. They need the `claude` CLI on `PATH` and logged in.
- Evals: [evals/README.md](evals/README.md).
- Design, conventions, and how to add a pattern or a version fact: [docs/architecture.md](docs/architecture.md).
- Releases follow semantic versioning, are listed in [CHANGELOG.md](CHANGELOG.md), and are tagged with `claude plugin tag`.

## License and no warranty

MIT License, see [LICENSE](LICENSE). Recorded documentation and package metadata in `tests/fixtures/mocks/` keep their own MIT notices.

This software is provided "as is", without warranty of any kind. An upgrade changes your code, configuration, and database: keep backups, work on a copy of the database, review every change on the upgrade branch, and test the result before you deploy it. You decide what is deployed, and when.

This is an independent project. It is not affiliated with or endorsed by Umbraco. Umbraco is a trademark of its owner, used here only to name the CMS the plugin works with.
