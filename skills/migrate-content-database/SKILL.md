---
name: migrate-content-database
description: Internal phase skill of the umbraco-upgrade workflow for database migrations on the declared local copy and content conversions (structured editors, grid, macros, pickers, forms, custom tables). Loaded during plan execution.
user-invocable: false
---

# Content and database phases

Used for phases with area `content-database`: the database migration of each path step, and the content and data work that comes before it (custom tables, legacy grid, Nested Content, macros, block editors, legacy pickers, forms, content model files, element types, database health, users and permissions). The phase lists the patterns that apply.

Follow [migration-rules.md](../upgrade-workflow/references/migration-rules.md). The core rule: **Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.** For content this also means: never delete content, data types, or properties to make a migration pass.

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

## Database rules

- Work only on the **declared local copy** (`source.database.localCopyDeclared` in state). If none is declared, stop and ask the user to restore one; never use a shared, staging, or production database. The safety hook blocks database commands against non-local servers.
- Read-only checks first. Any change to data (a migration run, a cleanup, a conversion) needs the `db-migration-local` approval.
- Never write to the CMS core tables with raw SQL unless the target documentation names that as an option, the user approves it, and a snapshot exists.

## 1. Read the phase

`state.ps1 get -Field phases`, `.umbraco-upgrade/evidence/planning/phase-composition.json` (step, reasons), the step in `.umbraco-upgrade/evidence/version-path/path-selection.json` (`dataMigrations`, `preparation`, `type`), and `Get-PatternGuidance.ps1 -ProjectRoot "<root>" -PhaseId <P>`.

## 2. Database migration phase

1. **Documentation.** Load `umbraco-upgrade:doc-retrieval` and read, for the step's target major: the upgrade page, the breaking-changes page, and each data migration's own page (for example the content migration articles). Note settings that control the migration (for example unattended upgrade, or settings a data migration documents) and its expected duration on large sites.
2. **Health (read-only).** Where the plan lists database health checks, run `Test-DatabaseHealth.ps1 -ProjectRoot "<root>" -Folder <P>`. For SQL Server and LocalDB it records the database size, the largest tables by approximate row count, the foreign keys that are disabled or not trusted, and the Block List and Block Grid labels written as AngularJS templates (`blockLabelTemplates`, pattern `content.block-label-templates`); for SQLite and SQL CE, the file size. The upgrade to 14 and later does not convert those labels: after the migration, rewrite each one in Umbraco Flavored Markdown (with `db-migration-local`), run the health check again so the list is empty, and tell the user that every other environment needs the same edits after its own upgrade. Compare the result with what the documentation of the step warns about (for example version history size before a long content migration). Anything more specific (obsolete editor aliases, orphan rows) is a read-only query you run on the local copy only, with its output saved through `Write-Evidence.ps1`.
3. **Snapshot.** Ask for the `db-snapshot-local` approval with the destination folder (outside the project) as its scope, record it, then `Invoke-DatabaseSnapshot.ps1 -ProjectRoot "<root>" -PhaseId <P> -Destination "<folder>"`.
4. **Migrate.** Ask for the `db-migration-local` approval: say which version runs the migration, against the declared local copy, and what the documented duration risk is. Record it. Then run the migration the way the target documentation describes (unattended upgrade setting, or starting the site and completing the upgrade). The safety hook asks before the site starts; that prompt is the user's.
5. **Check.** Save the relevant log lines (redacted) with `Write-Evidence.ps1 -SourceFile ... -RemoveSource`. Check each documented data migration of the step. Ask the user to confirm the manual criteria (content renders, backoffice login per user group).

Step types:

- `content-migration-new-install` (7 to 8): follow the content migration article for the exact versions, including its minimum source version and the obsolete editors that must be switched first.
- `database-reuse-new-project` (8 to a later major): follow the upgrade-from-8 article: the new project of the step points at the copy and runs the migrations; documented prerequisites (for example forms data stored in the database) come first.
- `major-in-place` and `minor-in-place`: the existing project, updated in the framework phase, runs the migration.

## 3. Content and data conversions

Each pattern lists its options (`Get-PatternGuidance.ps1`). Typical decisions:

- **Structured editors and the legacy grid** (`content.legacy-structured-editors`, `content.legacy-grid`): convert to the block editors the documentation recommends, with a conversion tested on the local copy. Element types must be consistent first (`content.element-type-consistency`). A transfer tool or community tool is an option only after its support for the exact source and target is verified from its own documentation.
- **Macros** (`content.macros`): scan rich text on the local copy for macro markup before calling any macro unused. Template-rendered macros become partial views; rich text macros become blocks with a content migration (custom migration or batch), as the migration article describes.
- **Legacy pickers** (`content.legacy-picker-values`): switch obsolete editors to their updated versions before the database step that needs it.
- **Forms** (`content.forms`): follow the forms add-on version notes for each major crossed; license questions go to the user.
- **Custom tables** (`data.custom-tables`): compare the expected tables with the real schema on the local copy (read-only), then port data access and migrations to the target APIs.
- **Content model files** (`content.model-source-of-truth`): keep them in sync after the database step; never let a sync tool overwrite migrated content without the user's decision.

Every conversion that changes data needs `db-migration-local`, runs on the local copy, and records counts before and after as evidence.

## 4. Build, evidence, criteria

Code changes of the phase build with `Test-Build.ps1`. Record each criterion with its evidence and hand back to the phase loop for the checkpoint.

## Never

- Connect to anything but the declared local copy.
- Run a migration, cleanup, or conversion without a snapshot and the recorded approval.
- Drop tables, delete content, or remove data types or properties to get past a migration error. Record an unresolved item and ask.
