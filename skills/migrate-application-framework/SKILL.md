---
name: migrate-application-framework
description: Internal phase skill of the umbraco-upgrade workflow for application and framework phases (packages, target framework, startup, new projects, models builder, configuration mapping). Loaded during plan execution.
user-invocable: false
---

# Application and framework phases

Used for phases with area `application-framework`: the package, target framework, and startup work of each path step, a new project at a generation boundary, and the combined minor-update phases. Owned patterns include `pkg.core-id-changes`, `config.startup-hosting`, `config.legacy-settings`, `config.bundling`, `content.models-builder`, `pkg.framework-only-libs`, `pkg.loose-binaries`, and `pkg.implicit-transitive`; the phase lists the ones that apply.

Follow [migration-rules.md](../upgrade-workflow/references/migration-rules.md). The core rule: **Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.**

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

## 1. Read the phase

- `state.ps1 get -ProjectRoot "<root>" -Field phases`: the phase title, patterns, and criteria.
- `.umbraco-upgrade/evidence/planning/phase-composition.json`: the path step of the phase (`step`) and why it exists.
- `.umbraco-upgrade/evidence/version-path/path-selection.json`: the step's `from`, `to`, `type`, `codebase`, `removals`, and `preparation`, each with its source.
- `Get-PatternGuidance.ps1 -ProjectRoot "<root>" -PhaseId <P>`: impacts, options, checks, and documentation per pattern.

## 2. Gather the documentation for the step

Load `umbraco-upgrade:doc-retrieval`. For the step's target major, read the upgrade-details page and the breaking-changes page (`Get-Doc.ps1 -Major <n> -Page upgrade-details|breaking-changes -AppliesTo intermediate|target`). Note every documented step for the majors this step crosses that touches packages, the target framework, startup, configuration, or the project file. The `.NET` version of each major comes from the version knowledge (`Get-VersionKnowledge.ps1`), never from memory.

## 3. Do the work, by step type

**In-place step (`major-in-place`, `minor-in-place`, existing codebase).**

1. Update the CMS packages to the step's target version in every project file (or `Directory.Packages.props` with central package management). First-party add-ons (forms, deployment tools) move to their release for that major; check each with `Get-NuGetPackageInfo.ps1 -PackageId <id> -Major <n>`.
2. Set the target framework the version knowledge gives for that major.
3. Apply every documented removal and preparation item of the step (for example, lines the new template no longer has), each with its source.
4. Startup: compare `Program.cs` or `Startup.cs` with the documented template for the target and change only what the documentation names.
5. Models builder (`content.models-builder`): keep the mode the project uses unless the target removed or moved it; the documentation for each crossed major says when models must be rebuilt and how.
6. View compilation (`content.razor-compilation`): follow the target documentation for the models mode in use.
7. Package results from planning (`.umbraco-upgrade/evidence/planning/package-compatibility.json`): framework-only libraries and loose assemblies get a .NET edition, a replacement, or an unresolved item. Removing or replacing a package needs the `package-removal` approval.

**New project step (`database-reuse-new-project`, `content-migration-new-install`, new codebase).**

1. A new codebase is a migration vehicle unless the plan says code is ported at this step (`codePort` in the composition). Create it next to the existing code; never delete or overwrite the old project.
2. Create the project from the official template for that exact version, as the version's installation documentation describes. Installing a template package writes outside the project: ask, record `outside-project-path`, then install.
3. Point it at the declared local database copy. Move the connection string with `Copy-ConfigValue.ps1 -ToUserSecrets` (approval `outside-project-path`); never print or re-type it.
4. The database phase of the step runs the migration; this phase ends when the new project builds.

**Combined minor-update phase.** Update the packages within the major, then follow the database part of the `umbraco-upgrade:migrate-content-database` skill for the same step (snapshot, approval, migration on the local copy, checks).

## 4. Configuration (`config.legacy-settings`)

Map each setting the code reads to `appsettings.json` (typed options preferred). Map CMS settings only to keys the target documentation lists; flag keys of removed features instead of copying them. Secrets go to user secrets or environment variables (`Copy-ConfigValue.ps1`), never into a tracked file.

## 5. Build, evidence, criteria

`Test-Build.ps1 -ProjectRoot "<root>" -PhaseId <P>` (add `-Precompile` when the models mode allows build-time view compilation). Record each criterion with its evidence. Hand back to the phase loop for the checkpoint.

## Never

- Delete the old project, old configuration files, or packages to make the new one build.
- Copy a configuration key or package version from memory.
- Remove a package without the `package-removal` approval.
