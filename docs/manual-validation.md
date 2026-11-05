# Manual validation procedure

The plugin's automated tests run its scripts on synthetic fixtures and check its workflow with short model runs. They never boot an Umbraco site, run real database migrations, or open a backoffice. This procedure covers that part by hand: on your machine, against a restored local copy of a test site's database. Record what you find as **real-project** evidence (see step 7).

Never run this procedure against a shared, staging, or production system.

## Sources

Each step cites the official page it relies on, with the documentation version the page belongs to. All pages were read on 2026-11-02. Use the page for your **target** version; the paths differ between Umbraco 13 (the `fundamentals` and `reference` layout) and Umbraco 17 and later (the `get-started` and `develop-with-umbraco` layout).

| Topic | Umbraco 18 (latest docs) | Umbraco 17 | Umbraco 13 |
|---|---|---|---|
| Upgrade a project | [upgrade-details](https://docs.umbraco.com/umbraco-cms/get-started/upgrading-and-migrating/upgrade-details) | [upgrade-details](https://docs.umbraco.com/umbraco-cms/17.latest/get-started/upgrading-and-migrating/upgrade-details) | [upgrading](https://docs.umbraco.com/umbraco-cms/13.latest/fundamentals/setup/upgrading) |
| Unattended upgrade | [upgrade-unattended](https://docs.umbraco.com/umbraco-cms/get-started/upgrading-and-migrating/upgrade-unattended) | [upgrade-unattended](https://docs.umbraco.com/umbraco-cms/17.latest/get-started/upgrading-and-migrating/upgrade-unattended) | [upgrading, "Run an unattended upgrade"](https://docs.umbraco.com/umbraco-cms/13.latest/fundamentals/setup/upgrading) |
| Unattended settings | [unattendedsettings](https://docs.umbraco.com/umbraco-cms/develop-with-umbraco/configuration/unattendedsettings) | [unattendedsettings](https://docs.umbraco.com/umbraco-cms/17.latest/develop-with-umbraco/configuration/unattendedsettings) | [unattendedsettings](https://docs.umbraco.com/umbraco-cms/13.latest/reference/configuration/unattendedsettings) |
| Connection strings | [connectionstringssettings](https://docs.umbraco.com/umbraco-cms/develop-with-umbraco/configuration/connectionstringssettings) | [connectionstringssettings](https://docs.umbraco.com/umbraco-cms/17.latest/develop-with-umbraco/configuration/connectionstringssettings) | [connectionstringssettings](https://docs.umbraco.com/umbraco-cms/13.latest/reference/configuration/connectionstringssettings) |
| Logging in to the backoffice | [logging-in-and-out](https://docs.umbraco.com/umbraco-cms/get-started/backoffice-essentials/logging-in-and-out) | [logging-in-and-out](https://docs.umbraco.com/umbraco-cms/17.latest/get-started/backoffice-essentials/logging-in-and-out) | [logging-in-and-out](https://docs.umbraco.com/umbraco-cms/13.latest/tutorials/editors-manual/getting-started-with-umbraco/logging-in-and-out) |
| Users and user groups | [users](https://docs.umbraco.com/umbraco-cms/manage-and-publish-content/users-and-members/users) | [users](https://docs.umbraco.com/umbraco-cms/17.latest/manage-and-publish-content/users-and-members/users) | [users](https://docs.umbraco.com/umbraco-cms/13.latest/fundamentals/data/users) |
| Logging and log files | [logging](https://docs.umbraco.com/umbraco-cms/develop-with-umbraco/testing-and-debugging/logging) | [logging](https://docs.umbraco.com/umbraco-cms/17.latest/develop-with-umbraco/testing-and-debugging/logging) | [logging](https://docs.umbraco.com/umbraco-cms/13.latest/fundamentals/code/debugging/logging) |
| Log Viewer | [logviewer](https://docs.umbraco.com/umbraco-cms/model-your-content/content-types-and-structure/backoffice/logviewer) | [logviewer](https://docs.umbraco.com/umbraco-cms/17.latest/model-your-content/content-types-and-structure/backoffice/logviewer) | [logviewer](https://docs.umbraco.com/umbraco-cms/13.latest/fundamentals/backoffice/logviewer) |
| Health checks | [health-check](https://docs.umbraco.com/umbraco-cms/run-in-production/infrastructure-and-ops/health-check) | [health-check](https://docs.umbraco.com/umbraco-cms/17.latest/run-in-production/infrastructure-and-ops/health-check) | [health-check](https://docs.umbraco.com/umbraco-cms/13.latest/extending/health-check) |

For SQL Server databases (Microsoft Learn, SQL Server documentation, read on 2026-11-02): [Restore a database backup using SSMS](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/restore-a-database-backup-using-ssms) and [Copy-only backups](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/copy-only-backups-sql-server).

For an end-of-life target or source version, use its documentation on the `umbraco-eol-versions` branch of the UmbracoDocs repository, as the plugin does; for 7 and 8, the `legacy-docs` branch.

## Before you start

- The upgrade ran to the end of its phases with the plugin, on its upgrade branch, and the branch builds (gate 5 build evidence, or `Test-Build.ps1` during the last phase).
- You have a backup of the original database and a **restored copy** on your machine (SQL Server or LocalDB: restore a backup, see the Microsoft Learn page above; SQLite: a copy of the file). The upgrade will migrate this copy; the backup stays untouched.
- You declared the local copy to the plugin, and the plugin's database snapshot (`Invoke-DatabaseSnapshot.ps1`, approval `db-snapshot-local`) was taken before the database step.
- You know at least one test account per backoffice user group the site uses, or you can create test accounts on the copy.
- Nothing in your local configuration points to a shared, staging, or production database, mail server, payment service, or other external system. Use test or sandbox endpoints, or none.

## Steps

### 1. Point the site at the local copy

The CMS reads its database from the `umbracoDbDSN` connection string (connection strings settings page, for your target version). Set it in your local configuration only (for example `appsettings.Development.json` or user secrets), never in a file that is deployed. Check that it names your local server or file.

### 2. Run the upgrade on first boot

For a major upgrade the database migrations run when the upgraded site boots. Either:

- **Unattended** (recommended for repeatable runs): set `Umbraco:CMS:Unattended:UpgradeUnattended` to `true` in your local configuration, as the unattended upgrade page and the unattended settings page describe for 13, 17, and 18. The project upgrades on its next boot, without the installer.
- **Interactive**: boot the site and run through the installation wizard in the browser, which the unattended setting otherwise skips (upgrade page for your target version).

Start the site against the local copy. In a project with `.umbraco-upgrade/`, the plugin's safety hook asks before a site start that runs migrations, unless a `db-migration-local` approval is recorded.

From Umbraco 17.3, the migrations run in a background service after the web server starts listening; while they run, the frontend and the Management and Delivery APIs answer HTTP 503 and the backoffice shows an upgrade-in-progress screen (unattended upgrade page, 17 and 18). Wait until the site serves normally.

### 3. Check the logs

Read the log files (by default under `umbraco/Logs`, as the logging page states for 13, 17, and 18) or the Log Viewer in the backoffice. Look for errors and warnings from the upgrade migrations and from start-up. Note each one and whether it is expected.

### 4. Log in to the backoffice per user group

Open `/umbraco` on the local site (logging-in-and-out page). Log in once with a test account of **each user group** the site uses (users page: user groups decide which sections and permissions a user has). For each group:

- the expected sections and trees are visible, and nothing is visible that should not be
- the group's typical tasks work: open, edit, save, and publish content of the main document types; upload and pick media; for administrators, open the settings section
- custom dashboards, sections, property editors, and other backoffice extensions load and work

### 5. Run the health checks

In the Settings section, open the "Health Check" dashboard (health check page, 13, 17, and 18) and run the checks. Record the results; fix nothing on the copy that you would not fix in the project.

### 6. Work through the gate 5 checklist

Run `/umbraco-upgrade:verify` (or continue gate 5 if it is waiting). It writes the manual checklist to `.umbraco-upgrade/evidence/final/manual-checklist.md`, composed from what discovery found: content and media, the content model and templates, the backoffice and its extensions, authentication and permissions, integrations and scheduled jobs, frontend routes, rendering, and forms, logs, deployment, and rollback. Do each check on the local site and answer the plugin with **verified** (with what you checked), **failed** (with what went wrong), or **not verified** (with the reason). The plugin records your words as evidence; a check you skip stays open.

### 7. Record the result

- Answers given in step 6 are recorded by the plugin under `.umbraco-upgrade/evidence/final/` and in `state.json`, and appear in `report.md` under "Verified manually" or "Not verified".
- Observations from steps 2 to 5 (migration log lines, health check results, per-group results) go into those answers. Write them without secrets, connection strings, or personal data: the plugin redacts what it recognizes, but you are the last check.
- Label this evidence **real-project** when you report it elsewhere, for example in an issue: it comes from a real site, not from the plugin's synthetic tests.

### 8. Rehearse the rollback

Follow `.umbraco-upgrade/rollback.md` on the copy: restore the snapshot or the backup, check out the base commit, and confirm the old site boots against the restored database. Then return to the upgrade branch.

## After the procedure

Deployment stays yours. The report lists the manual follow-ups (production configuration, deployment, and the per-environment upgrade: the upgrade page notes that the upgrade runs on the first boot of each environment). The plugin never deploys and never connects to a non-local database.
