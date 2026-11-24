# Architecture

This document explains how the plugin is built, for contributors. User-facing behavior is in the [README](../README.md).

## Principles

1. **Generic first.** The plugin must work for any Umbraco installation, from a near-default site to a heavily customized one, and for any supported source and target version, including LTS releases that do not exist yet.
2. **Version facts are data, not code.** Versions, LTS status, .NET requirements, support dates, path constraints, package mappings, and detection signals live in versioned knowledge files, each fact with its source and verification date. Skills reason over them and never hard-code them.
3. **Scripts do the deterministic work; skills do the judgment.** Anything that can be computed (version detection, pattern detection, path candidates, package classification, phase composition, state transitions, verification checks, the report) is a PowerShell script with JSON output and tests. Skills decide what to run, explain results, and talk to the user.
4. **Safety is enforced, not requested.** Prohibited operations are blocked by hooks before permission rules are evaluated. Approval-tier actions are gated by approvals recorded in state, and the scripts that perform them check for those approvals.
5. **State lives only in the target project.** The plugin holds no project state. `${CLAUDE_PLUGIN_ROOT}` is read-only at runtime; caches go to `${CLAUDE_PLUGIN_DATA}`.
6. **Nothing is removed to make a build pass.** Custom functionality that cannot be migrated directly becomes an unresolved item with a proposal and a question.
7. **Every significant decision cites its source** (URL, the version it applies to, date). What cannot be confirmed from a primary source is "unverified".

## Repository layout

```text
.claude-plugin/
  plugin.json              manifest
  marketplace.json         single-entry marketplace, source "./"
skills/                    commands (user-invocable) and shared internal skills
agents/                    inventory-analyst, docs-researcher, independent-verifier
hooks/hooks.json           PreToolUse guard, PostToolUse redaction, SessionStart note
scripts/
  *.ps1                    entry scripts (JSON out)
  lib/*.psm1               shared modules
  hooks/                   hook entry scripts, GuardCore.psm1, rules.json
knowledge/
  versions.json            majors, .NET channels, per-fact sources
  paths.json               path strategies, documented rules, scoring heuristics
  packages.json            core packages per generation, package mappings
  sources.json             host allowlist, docs spaces, page map, NuGet and .NET endpoints
  patterns/*.json          customization pattern registry (one record per pattern)
  planning/                phase-rules.json and verification-rules.json (heuristics, labelled as such)
schemas/                   state, knowledge, and pattern JSON schemas
tests/                     Pester suites, synthetic fixtures, recorded HTTP mocks
evals/                     claude plugin eval cases (results are not committed)
docs/                      this file, example prompts, manual validation procedure
```

There is no `bin/` directory (it blocks installation on some surfaces) and no root `CLAUDE.md` (plugins do not load it).

## Commands and skills

Commands are skills with `disable-model-invocation: true`, an `argument-hint`, and `arguments`. Each validates its arguments with `Resolve-UpgradeArguments.ps1`, then loads shared skills by their namespaced names. Instructions live once, in the shared skills.

| Command | Loads |
|---|---|
| `start` | `upgrade-workflow` in upgrade mode |
| `plan` | `upgrade-workflow` in plan mode |
| `resume` | `upgrade-state` (reconciliation), then `upgrade-workflow` at the recorded position |
| `verify` | `verification` |
| `report` | `reporting` |
| `update-knowledge` | runs `Update-Knowledge.ps1`, then `doc-retrieval` for review items |

Shared skills (`user-invocable: false`, short descriptions so the always-on listing stays small):

| Skill | Responsibility |
|---|---|
| `upgrade-workflow` | The gate engine: order, entry and exit criteria (`references/gates.md`), approval protocol, execution policy, migration rules, phase execution, the first-run folder explanation |
| `upgrade-state` | State commands and resume reconciliation |
| `discovery` | Gate 1 |
| `version-path` | Gate 2 and path selection |
| `doc-retrieval` | Source priority, versioned retrieval, citations, secondary sources |
| `safety-setup` | Gate 3 |
| `upgrade-planning` | Gate 4 and the plan templates |
| `migrate-*` (6) and `deployment-rehearsal` | One per migration area; each owns the handling of its patterns |
| `verification` | Gate 5 and the interim check |
| `reporting` | `report.md` |

Skill bodies refer to `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, and `${CLAUDE_SESSION_ID}`, which Claude Code substitutes in the text. These variables are not in the environment of Bash or PowerShell tool commands, so skills pass `-DataDir "${CLAUDE_PLUGIN_DATA}"` and similar arguments explicitly.

## The workflow

```text
gate 1 discovery -> gate 2 version and path -> gate 3 safety (upgrade mode) -> gate 4 plan approval
  -> [stop: approval] -> phases P1..Pn (upgrade mode) -> gate 5 final verification and report
```

- Gates are never skipped, merged, or reordered. `state.ps1 gate` refuses a gate whose predecessors have not passed, and each gate has pass conditions in `State.psm1` (for example gate 2 needs a resolved target, its LTS value and .NET version, and a selected path with its decision id).
- Plan mode skips gate 3 (recorded as `skipped`), writes the plan, and stops.
- After approval, phases start only in plan order, only while `plan.md` still matches the approved SHA-256, only after gate 3 passed, and only on the upgrade branch. A phase is `done` only with every acceptance criterion met (with evidence files) or waived (with the user's words) and a checkpoint commit.
- Gate 5 starts only when every phase is `done` or `deferred`. No phase starts while gate 5 is in progress or passed; a failed check that the user wants fixed goes through gate 5 `failed`, an amended plan, a new approval, and a follow-up phase. A new phase list must keep every phase that has run exactly as recorded.

## State

`.umbraco-upgrade/state.json`, schema `schemas/state.schema.json` (version 1.1.0; readers accept the same major, `state.ps1 migrate` raises older minors). Only `scripts/state.ps1` writes it; the guard blocks Write and Edit on it.

- Sections: plugin, mode, project (including the folder policy), source, target, path, gitBaseline (base commit and the status at start), gates, phases (with criteria, checkpoint commits, failures), approvals, decisions, unresolved items, knowledge (which knowledge files were used), verification (gate 5 checklist and results), and an append-only history.
- `State.psm1` validates every write against the schema with a JSON Schema subset in `lib/JsonSchema.psm1` (Windows PowerShell 5.1 has no `Test-Json`), plus cross-field rules, and refuses content that the redaction module would change.
- Writes are atomic (write to a temporary file, then replace).
- The plan approval binds to the SHA-256 of `plan.md`.

## Knowledge

- **Fact model.** Each fact has `value`, `status` (`verified`, `secondary`, `unverified`, `needs-review`), `source`, `sourceType`, `sourceVersion` (the docs or package version the source belongs to), `appliesTo`, `verifiedAt`, `verifiedBy`, and optionally `evidence` (a short phrase the source must contain) and `note`. `schemas/knowledge.schema.json` defines each document kind.
- **Lookup order.** `lib/Knowledge.psm1` uses the refreshed copy in `${CLAUDE_PLUGIN_DATA}/knowledge/` for a file when it parses, has the same schema major, validates, and is newer than the shipped baseline; otherwise the baseline.
- **Refresh.** `Update-Knowledge.ps1` changes only what it can verify mechanically: latest releases and target frameworks from NuGet, LTS labels from the release notes site, .NET support dates from the release metadata, docs spaces from the docs index, and secondary dates. It re-checks every evidence phrase; a missing phrase marks the fact `needs-review` and the value is kept. A new major with a stable release is added with its framework verified and every other fact unverified. Prereleases and pre-release documentation spaces are reported as upcoming, not added. The output includes `maintainer.patch`, a unified diff from the baseline that a maintainer applies, reviews, and commits.
- **Patterns.** `knowledge/patterns/*.json` (schema `schemas/pattern.schema.json`): id, description, kind (customization or baseline signal), area, owner skill, prevalence (`common`, `gap` for detect-and-flag, `universal`, `project-specific`), detection type (static, package-metadata, database-review), detectors per generation (file globs, regexes, plugin-folder scope, excluded files, derived detectors), impacts per version boundary with difficulty, handling options per target generation with citations or `hypothesis`, checks, and sources. `skills/discovery/references/pattern-registry.md` lists them.
- **Planning heuristics.** `knowledge/planning/phase-rules.json` (split thresholds, group order, when functional verification and rehearsal apply) and `verification-rules.json` (gate 5 checks and when they apply) are plugin heuristics, labelled as such, not documentation facts.

## Discovery, path selection, and planning

- `Invoke-Discovery.ps1` combines `Get-UmbracoVersion.ps1` (signals with confidence and conflicts), `Get-ProjectInventory.ps1`, and `Find-Patterns.ps1`, and writes redacted evidence. Baseline signals (what a default installation has) are reported apart from customizations. A catch-all lists CMS usage no detector explains.
- `Select-UpgradePath.ps1` builds candidates for the four strategies, applies the documented rules in `paths.json`, scores them with the heuristics, resolves exact versions from NuGet, and reports the facts each candidate rests on with their status. The `version-path` skill makes and records the decision with its alternatives.
- `Test-PackageCompatibility.ps1` classifies each direct package reference from NuGet metadata and reports `unreachable` rather than a claim when metadata cannot be read.
- `Get-PhaseComposition.ps1` composes phases: framework first, groups in dependency order, high-difficulty patterns alone, large areas split, one set of phases per stop of a staged path, code ported once onto a new codebase, functional verification and rehearsal when they apply.

## Execution, verification, and resume

- `lib/Execution.psm1` holds the common refusal: the plan approved and unchanged, gate 3 passed, the upgrade branch checked out, the phase in progress (or gate 5 in progress for `-PhaseId final`). `Test-Build.ps1`, `Copy-ConfigValue.ps1`, `Invoke-DatabaseSnapshot.ps1`, and `New-Checkpoint.ps1` use it.
- `New-Checkpoint.ps1` enforces the no-removal rule at every checkpoint: deleted files need a `remove-custom-feature` approval that names them; stubs and secrets are refused; commented-out code and compile exclusions are warnings.
- Gate 5: `Get-VerificationPlan.ps1` composes the checklist from discovery and the package check; `Invoke-Verification.ps1` records automated results from evidence (only it can record an automated check as verified); manual checks are recorded only with the user's words and an evidence file; `New-Report.ps1` writes the report, linking evidence and redacting text.
- `Test-StateReality.ps1` (`lib/Reconcile.psm1`) compares state with reality and returns the position, mismatches, warnings, and per-check options. It never changes anything. The resume flow reports mismatches and asks; the user's decisions are recorded before any state change.

## Documentation retrieval

`Get-Doc.ps1` (`lib/Docs.psm1`) resolves the docs space for a major from the knowledge: the unversioned site for the latest major, `<n>.latest` spaces for other supported majors, the `umbraco-eol-versions` branch on GitHub for end-of-life majors, and the `legacy-docs` branch for 7 and 8. Majors not in the knowledge are probed and marked unverified. Every response is validated: the docs site answers missing pages with HTTP 200 and a "Page Not Found" body, and redirects unpublished spaces to another version, so a response whose final URL or self-link names another space is `version-mismatch`. Bot challenges are `blocked` and never bypassed. Pages and metadata are cached in `${CLAUDE_PLUGIN_DATA}/doc-cache/` with URL, final URL, version label, fetch time, status, and SHA-256.

There is no local search index: supported versions have versioned Markdown pages and an index, end-of-life and legacy versions are raw files on GitHub, and package data comes from the NuGet API. Context7 is not bundled; users who install the official context7 plugin get a secondary search aid.

## Subagents

| Agent | Why it exists | Tools |
|---|---|---|
| `inventory-analyst` | Context isolation: classifies hundreds of detector hits so the main conversation gets a short summary | Read, Grep, Glob, Bash, PowerShell |
| `docs-researcher` | Context isolation and source discipline: reads long official pages and returns cited answers | Read, Grep, WebFetch, Bash, PowerShell |
| `independent-verifier` | Independence: checks a phase, or gate 5, from the repository and the evidence only, without the implementation conversation | Read, Grep, Glob, Bash, PowerShell; no Edit or Write |

All use `model: inherit` and `omitClaudeMd: true`, and leave out the `Agent` tool so they cannot nest. Plugin subagents cannot carry their own hooks, but the plugin's hooks apply to their tool calls. Subagents may run in the background; the skills wait for their result before recording anything that depends on it.

## Hooks

- **Exec form.** Every hook is `"command": "powershell"` with `args` ending in `-File ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/<script>`. Exec form avoids shell quoting, profile loading, and the default execution policy. Shell form with `"shell": "powershell"` was rejected: its `-Command` wrapper turned the script's exit code 2 into 1, so a block became a non-blocking error.
- **Scope check first.** Each script exits 0 with no output unless the session is in an upgrade project (state found from the hook's working directory, `CLAUDE_PROJECT_DIR`, their parents, a session marker in `${CLAUDE_PLUGIN_DATA}/active-sessions/`, or a directory the command names).
- **Guard.** `guard.ps1` reads the hook input as UTF-8 bytes (Windows PowerShell would decode stdin with the console code page), tokenizes the command for both shells (`GuardCore.psm1`), and evaluates the rules in `rules.json`. A block is exit code 2 with the reason on stderr; an approval-tier operation returns `permissionDecision: "ask"`. Inside scope, any internal error blocks. `onFailure: "block"` covers a guard that cannot start or times out.
- **Self-test.** `onFailure` does not cover a missing script (`powershell -File <missing>` exits 0). Gate 3 therefore issues a nonce-bound canary command through the normal shell tool; the guard blocks it and writes an evidence file with the nonce; `Test-Guard.ps1 -Verify` checks that file. Without it gate 3 fails.
- **Redaction.** `redact-output.ps1` returns `updatedToolOutput` in the tool's own output shape (a replacement that does not match is ignored); for Read the stored transcript also holds the replacement. It never blocks.
- **Session note.** `session-context.ps1` prints a short factual note and a version warning.

## Redaction and secrets

`lib/Redaction.psm1` is the single implementation, used by discovery, evidence, state validation, the hooks, and the report. It redacts connection-string secrets, keys, tokens, client secrets, machine keys, passwords, JWTs, private key blocks, high-entropy values under sensitive key names, unquoted YAML and `Section:Key = value` lines, and inline sensitive assignments. Connection strings are reduced to an engine and "local" or "non-local" by `lib/ConnectionInfo.psm1`; the value never leaves memory.

## HTTP

`lib/Http.psm1` enforces the host allowlist from the shipped `knowledge/sources.json`, caches responses, and implements the `UMBRACO_UPGRADE_HTTP_MOCK` test seam (recorded responses from `tests/fixtures/mocks/<set>/index.json`, first match wins, unrecorded URLs fail as network errors).

## Conventions

- **PowerShell.** Every script runs on Windows PowerShell 5.1 and PowerShell 7. No 7-only syntax (`??`, `?.`, ternaries, `&&` and `||`, `-AsHashtable`, `Test-Json`, `-Parallel`). `Set-StrictMode -Version 2.0`, `$ErrorActionPreference = 'Stop'`. ASCII source files only.
- **I/O.** Read and write files as UTF-8 explicitly. Parse JSON with comments and trailing commas through the helper in `lib/Compat.psm1`. Parse XML without DTD processing.
- **Output.** Entry scripts print one JSON object with `ok`; exit code 0 on success and 1 on a refusal or error, unless the synopsis says otherwise. Messages say what to do next.
- **Arrays.** Functions that return arrays use `return ,$list`; callers must not wrap the result again.
- **Paths.** Never write under `${CLAUDE_PLUGIN_ROOT}`. Scripts that write take the project root or the data directory explicitly and refuse the plugin root.
- **Skills.** `SKILL.md` under 500 lines; details in `references/`; commands thin; shared skills `user-invocable: false`.
- **Fixtures.** Written from scratch from generic pattern descriptions and official documentation, never copied from a real project. Placeholder names only (for example `SampleSite`, `Sample.*` packages). Fake secrets carry the marker `FAKE-SECRET-FOR-TESTS`.

## Tests and evals

- `tests/Invoke-Tests.ps1` runs the Pester suites on Windows PowerShell 5.1 and, when installed, PowerShell 7. Every `Describe` carries one label tag: `mocked` (recorded HTTP or git), `fixture-based` (scripts on synthetic fixtures), `eval`, or `real-project` (never in the automated suite). The selector tag `integration` marks `claude -p --plugin-dir` runs, excluded unless `-Integration` is given.
- Hook tests pipe hook payloads to the guard: every rule blocks its positive cases (including wrapped forms), near misses pass, and every positive case is inactive outside an upgrade project and in a sibling folder.
- `evals/` holds `claude plugin eval` cases with scaffold scripts and graders. Shell-granting suites need an OS sandbox, which native Windows lacks, so they run under Linux or WSL2. See `evals/README.md`.

## Other AI tools

GitHub Copilot, OpenAI Codex, and Cursor load the same skills and scripts. Only the packaging and the hook wiring differ:

- **Manifests.** `.github/plugin/plugin.json` (Copilot reads it before `.claude-plugin/`), `.codex-plugin/plugin.json`, and `.cursor-plugin/plugin.json`. The Copilot and Codex manifests declare empty inline hooks, so neither tool loads `hooks/hooks.json`, which is in Claude Code's format. The Cursor manifest points to `hooks/cursor-hooks.json`. Marketplaces: Copilot reads `.claude-plugin/marketplace.json`; Codex reads `.agents/plugins/marketplace.json`; Cursor reads `.cursor-plugin/marketplace.json`.
- **Hook input and output.** `guard.ps1`, `redact-output.ps1`, and `session-context.ps1` take `-HostTool`. `scripts/hooks/HostAdapter.psm1` converts the tool's input to the Claude Code shape (shell commands become `Shell` and are read in both the bash and the PowerShell dialect; Codex `apply_patch` files are checked one by one as writes) and writes the decision as the tool's JSON on stdout with exit code 0, because a shell wrapper can turn exit code 2 into 1. Tools that cannot ask the user get a deny that says so.
- **Hook wiring.** Cursor runs plugin hooks from the plugin folder, so `hooks/cursor-hooks.json` uses relative paths. Copilot and Codex document no reliable plugin-folder path for hook commands, so `Install-HostHooks.ps1` writes a project hook file with absolute paths that work in cmd.exe and PowerShell.
- **Data folder.** Outside Claude Code it is `UMBRACO_UPGRADE_DATA` or `~/.umbraco-upgrade/data` (`Get-HostDataDir`), used by the skills and the hooks alike.
- **Skills.** Each command skill points to `skills/upgrade-workflow/references/other-tools.md`, which says how to read `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, `${CLAUDE_SESSION_ID}`, `$ARGUMENTS`, skill loading, and subagents in other tools. `skills/<command>/agents/openai.yaml` keeps the commands user-invoked in Codex.
- **Safety net.** The gate 3 guard self-test runs through whichever tool is in use. If that tool's hooks are not active, gate 3 fails before anything changes.

Tests: `tests/HostAdapters.Tests.ps1`.

## Extending the plugin

**Add a customization pattern.**

1. Write a record in `knowledge/patterns/<area>.<name>.json` that validates against `schemas/pattern.schema.json`: a generic description, detectors per generation, impacts per version boundary, and handling options per target generation. Cite each option and impact from official documentation (URL, docs version, applies-to, date, evidence phrase), or mark it `hypothesis`.
2. Name an owner skill that exists, and mention the pattern in that skill if its handling needs instructions.
3. Add a synthetic overlay under `tests/fixtures/patterns/<id>/` with an `overlay.json` that names its `baseline` (a `gen.*` fixture) and the patterns it `expects`. `tests/PatternDetection.Tests.ps1` checks that it fires exactly those.
4. Add the pattern to the list in `skills/discovery/references/pattern-registry.md`.

**Update version facts.** Run `/umbraco-upgrade:update-knowledge` (or `Update-Knowledge.ps1 -DataDir <dir>`), review `refresh-report.md`, apply `maintainer.patch` in a clone, check every changed fact against its source, resolve `needs-review` items by reading the cited page, and run the tests. Facts that cannot be checked mechanically (for example minimum upgrade-from versions or data migrations of a new major) are written by hand with their source and evidence phrase.

**Add a guard rule.** Add the rule to `scripts/hooks/rules.json` with a stable id, decision (`deny` or `ask`), and a reason that tells Claude what to do instead; implement its matcher in `GuardCore.psm1`; add positive cases, wrapped forms, near misses, and the inactive-outside cases to `tests/Guard.Tests.ps1`.

## Releasing

1. Bump `version` in `.claude-plugin/plugin.json` (the marketplace entry carries no version, so they cannot disagree) and add the release to `CHANGELOG.md`.
2. Run the tests, `claude plugin validate . --strict`, and, where possible, the evals.
3. Commit, then `claude plugin tag --dry-run` and `claude plugin tag`, which creates `umbraco-upgrade--v<version>` after checking that `plugin.json` and the marketplace entry agree.
