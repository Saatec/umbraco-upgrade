---
name: migrate-packages-backoffice
description: Internal phase skill of the umbraco-upgrade workflow for third-party packages and backoffice extensions (successor packages, packages without a target release, AngularJS editors, dashboards, sections and trees, backoffice APIs, content apps). Loaded during plan execution.
user-invocable: false
---

# Package and backoffice phases

Used for phases with area `packages-backoffice`. Package phases handle community and add-on packages, packages without a release for the target, successors, package-copied assets, and orphan plugin folders. Backoffice phases handle project-authored extensions: property editors, dashboards, sections and trees, authorized backoffice APIs and server variables, content apps, and extensions of the web components backoffice. The phase lists the patterns that apply.

Follow [migration-rules.md](../upgrade-workflow/references/migration-rules.md). The core rule: **Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.** A backoffice extension that has not been rebuilt yet stays in the repository as it is; it is never deleted to make the new backoffice start.

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

## 1. Read the phase

`Get-PatternGuidance.ps1 -ProjectRoot "<root>" -PhaseId <P>`, the package results in `.umbraco-upgrade/evidence/planning/package-compatibility.json`, and the phase's files in `.umbraco-upgrade/evidence/planning/phase-composition.json`.

## 2. Packages

- **Compatible release exists** (`compatible`): update to the release whose dependency range includes the target. Check it with `Get-NuGetPackageInfo.ps1 -PackageId <id> -Major <n>`.
- **Deprecated with an alternate** (`pkg.renamed-community`): the successor named in the package metadata is a candidate, verified for the target from its own metadata. Replacing a package needs the `package-removal` approval.
- **No release for the target** (`pkg.no-target-version`): a decision point. Present the options with what each loses: replace with another package, fork, rewrite as project code, or drop. Record the user's decision; dropping needs `remove-custom-feature` for the functionality and `package-removal` for the reference.
- **Not on nuget.org** (`not-found`): ask where it comes from (private feed or local file); never guess a public package with a similar name.
- **Package-copied assets**: update the package first, then remove the old copied folder only with the `package-removal` approval naming it.
- **Orphan plugin folders**: removal only after the user confirms the folder is unused (`remove-custom-feature` with the folder as scope).
- **Commerce and workflow products**: follow the product's own upgrade guide for the exact versions; license questions go to the user.

## 3. Backoffice extensions

1. Read the official migration articles for the target, through `umbraco-upgrade:doc-retrieval`: the backoffice extension migration from AngularJS, the custom property editor migration, and the extension type pages of the target version (find them with `Get-Doc.ps1 -Major <n> -Index -Find "<title words>"`). Use the `umbraco-upgrade:docs-researcher` agent for long pages.
2. Map each AngularJS concept to its documented equivalent: the manifest becomes `umbraco-package.json`; controllers and views become web components; injected services become contexts; server variables become a config endpoint on the extension's API controller (check first whether the value is needed); content apps become workspace views; authorized API controllers become Management API controllers.
3. **Property editors.** The upgrade migrates existing data types to a UI alias and a schema alias. Register the new property editor UI with the migrated aliases so existing data keeps working; keep or define a server-side schema when the stored format must stay. Value converters that matched the editor alias may need the UI alias (see `api.value-converters`).
4. **Build tooling.** Plain JavaScript modules need no build step. A TypeScript or Vite setup adds a Node toolchain: ask before adding it.
5. Extensions already built for the web components backoffice (`backoffice.modern-extension`) are checked against the client and server breaking changes of every major crossed.

## 4. Build, evidence, criteria

`Test-Build.ps1 -ProjectRoot "<root>" -PhaseId <P>`. Backoffice criteria are manual: ask the user to open each extension in the local backoffice and confirm it loads, edits, and saves. Record their words as evidence. Hand back to the phase loop for the checkpoint.

## Never

- Delete an App_Plugins folder, a manifest, or an extension without the recorded approval naming it.
- Pick a replacement package from memory or by name similarity.
- Ship compiled extension code without its sources unless the user decides so.
