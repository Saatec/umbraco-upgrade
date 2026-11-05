# Changelog

All notable changes to this plugin are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [semantic versioning](https://semver.org/). Releases are tagged with `claude plugin tag` as `umbraco-upgrade--v<version>`.

## [0.1.0] - Unreleased

First release.

### Commands

- `/umbraco-upgrade:start <target-version> [project-path]`: gates 1 to 4, a stop for plan approval, then plan execution phase by phase and gate 5.
- `/umbraco-upgrade:plan <target-version> [project-path]`: discovery and plan only; writes nothing outside `.umbraco-upgrade/`.
- `/umbraco-upgrade:resume [project-path]`: reconciles the recorded state with the repository and the files, reports every difference and asks, then continues from the recorded position.
- `/umbraco-upgrade:verify [project-path]`: gate 5 final verification after the last phase, or an interim check of an upgrade in progress.
- `/umbraco-upgrade:report [project-path]`: writes `report.md` from state, evidence, and decisions at any point.
- `/umbraco-upgrade:update-knowledge`: refreshes version knowledge into the plugin data directory and writes a maintainer patch; reports upcoming majors (prereleases on NuGet and pre-release documentation spaces).

### Workflow

- Fixed gates: discovery, version and path, safety setup (upgrade branch, rollback plan, guard self-test), plan approval, final verification and report.
- Adaptive phases composed from discovery and the selected path, each with acceptance criteria, evidence, and a checkpoint commit.
- Path selection over in-place, staged, rebuild-with-database-migration, and new-install-with-content-transfer strategies, with alternatives and sources recorded.
- Package compatibility from NuGet metadata and the package knowledge: a CMS range counts only when the dependency package has a release of the target major; renamed first-party packages and packages without a successor are named as such.
- Discovery that reports and skips files it cannot read (including paths of 260 characters or more on Windows PowerShell 5.1), and that does not report the stock files of the 7 and 8 core packages as customizations.
- Seven migration skills (application framework, custom code, content and database, packages and backoffice, configuration and integrations, build and tests, deployment rehearsal) and three subagents (inventory analyst, documentation researcher, independent verifier).
- Gate 5 checklist composed from what discovery found, automated checks recorded only by script, manual checks recorded only with the user's words, and a report that separates verified automatically, verified manually, and not verified.
- Resume reconciliation that never repairs or repeats a phase on its own.

### Safety

- PreToolUse guard for shell, file-write, and database MCP tools in upgrade projects: blocks force pushes, history rewrites, branch deletion, discarding changes, non-local database commands, deployments, and printing secrets; asks before pushes, site starts, migrations, package removal, CI and deployment edits, writes outside the project, and deleting tracked project files.
- PostToolUse redaction of secret values in reads of settings files and in Grep, Bash, and PowerShell output.
- SessionStart note in upgrade projects.
- Hooks are inactive outside projects that contain `.umbraco-upgrade/state.json`.

### Knowledge

- Version knowledge for Umbraco 7 to 18 and .NET 5.0 to 10.0, path rules, and package mappings, each fact with its source, status, and verification date (verified 2026-10-14; latest releases updated 2026-10-29).
- A registry of 87 customization patterns with detectors, impacts, and handling options per target generation, each cited or marked as a hypothesis.

### Known limitations

- Tested on Windows with Windows PowerShell 5.1 only. PowerShell 7, macOS, and Linux are untested.
- The `claude plugin eval` cases are written but have not been run.
- LTS status for 7 to 10 and all support and end-of-life dates are from a secondary source until confirmed on the official page.
