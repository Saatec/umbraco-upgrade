# Pattern registry

Detectors and handling options live in `${CLAUDE_PLUGIN_ROOT}/knowledge/patterns/<id>.json` (schema: `${CLAUDE_PLUGIN_ROOT}/schemas/pattern.schema.json`). They are data: change a record, not the skills, when the documentation changes.

## What a record holds

- `kind`: `customization` (counted for phases) or `baseline` (present in default installations of some generation: reported under `baselineSignals`, adds mandatory work, never counted as a customization).
- `detection`: `static` (detectors run in gate 1), `package-metadata` (classified at gate 4 by `Test-PackageCompatibility.ps1` from NuGet metadata), or `database-review` (checked on the declared local database copy during a database phase).
- `detectors`: file globs plus a regular expression (`strong` hits make a pattern fire; `supporting` hits are reported only for patterns that fired), file-presence detectors (no regular expression), detectors limited to App_Plugins folders that do or do not match a package reference (`pluginScope`), and derived detectors (`app-plugin-orphan`, `implicit-namespace`).
- `impact`: what changes when the upgrade crosses a major (`crosses`: applies when the source major is below it and the target major is at or above it), with a difficulty and sources.
- `handling`: a list of options, each with when it fits, the target generations it applies to, its sources, and `status` (`verified` when an official page confirms it, else `hypothesis`). Some options need an approval (`requiresApproval`). No option is a default: the owning skill chooses per project and records the alternatives.
- `checks`: acceptance criteria the plan adds for the pattern.
- `status`: `verified` when every impact cites an official page whose evidence phrase was confirmed (with the date), else `hypothesis`.
- `flagOnly`: detect and flag (documentation-derived coverage-gap patterns); `requiresDecision`: the user decides before any change.

`Find-Patterns.ps1 -Path <root>` runs the registry on its own; `Invoke-Discovery.ps1` runs it in gate 1. `Get-PatternGuidance.ps1 -ProjectRoot <root> -PatternId <id>` prints what a pattern means for the source and target of the current upgrade.

A pattern that did not fire is "not detected", never "absent". Files that use CMS namespaces but matched no pattern are listed by the catch-all for classification.

## Patterns

| Id | Title | Owner | Detection | Status | Flags |
|---|---|---|---|---|---|
| `api.composition-di` | Startup composition and service registration | migrate-custom-code | static | verified |  |
| `api.content-apps` | Content apps | migrate-packages-backoffice | static | verified | flag |
| `api.content-finders-errors` | Content finders, not-found pages, and error handling | migrate-custom-code | static | verified |  |
| `api.event-handlers` | Content and request event handlers | migrate-custom-code | static | verified |  |
| `api.health-checks` | Custom health checks | migrate-custom-code | static | verified | flag |
| `api.runtime-file-writes` | Runtime writes to the web root or configuration files | migrate-custom-code | static | hypothesis |  |
| `api.url-providers` | Custom URL providers | migrate-custom-code | static | verified | flag |
| `api.value-converters` | Property value converters | migrate-custom-code | static | verified |  |
| `auth.access-rules` | Page and media access rules in code | migrate-config-auth-integrations | static | verified |  |
| `auth.backoffice-external-login` | Backoffice external login providers | migrate-config-auth-integrations | static | verified | flag |
| `auth.backoffice-session-on-frontend` | Front-end features gated on the backoffice login | migrate-config-auth-integrations | static | hypothesis | flag, decision |
| `auth.backoffice-users-permissions` | Backoffice users, groups, and permissions after a migration | migrate-content-database | database-review | hypothesis |  |
| `auth.custom-roles` | Custom role providers and roles from external systems | migrate-config-auth-integrations | static | hypothesis |  |
| `auth.custom-user-permissions` | Custom user groups and permissions in code | migrate-config-auth-integrations | static | hypothesis | flag |
| `auth.external-member-login` | External sign-in for members | migrate-config-auth-integrations | static | verified |  |
| `auth.member-flows` | Member registration, login, and password flows | migrate-config-auth-integrations | static | verified |  |
| `auth.two-factor` | Two-factor authentication providers | migrate-config-auth-integrations | static | verified | flag |
| `backoffice.angular-property-editor` | Project-authored AngularJS property editors | migrate-packages-backoffice | static | verified |  |
| `backoffice.authorized-api` | Authorized backoffice API controllers and server variables | migrate-packages-backoffice | static | verified |  |
| `backoffice.dashboard` | Backoffice dashboards | migrate-packages-backoffice | static | verified |  |
| `backoffice.modern-extension` | Backoffice extensions for the web components backoffice | migrate-packages-backoffice | static | verified | baseline |
| `backoffice.orphan-plugin-folder` | Orphan App_Plugins folders | migrate-packages-backoffice | static | hypothesis | decision |
| `backoffice.package-copied-assets` | Package assets copied into App_Plugins | migrate-packages-backoffice | static | verified |  |
| `backoffice.section-tree` | Custom backoffice sections and trees | migrate-packages-backoffice | static | verified |  |
| `code.content-mapping-library` | Mapping libraries over published content | migrate-custom-code | static | hypothesis |  |
| `code.content-write` | Writing content and media from code | migrate-custom-code | static | hypothesis |  |
| `code.custom-routing` | Custom routes and areas | migrate-custom-code | static | verified |  |
| `code.frontend-api-controller` | Front-end API controllers | migrate-custom-code | static | verified |  |
| `code.hardcoded-ids` | Hard-coded integer content and property IDs | migrate-custom-code | static | hypothesis |  |
| `code.mvc5-razor-features` | Child actions and MVC 5 only Razor features | migrate-custom-code | static | verified |  |
| `code.render-controller` | Custom render controllers (route hijacking) | migrate-custom-code | static | verified |  |
| `code.static-service-access` | Static service and context access | migrate-custom-code | static | verified |  |
| `code.surface-controller` | Surface controllers | migrate-custom-code | static | verified |  |
| `code.unclassified-umbraco-usage` | CMS usage not matched by any pattern | discovery | catch-all | hypothesis |  |
| `code.vendored-source` | Vendored third-party source in the solution | migrate-custom-code | static | hypothesis | decision |
| `code.webforms` | WebForms pages and user controls | migrate-custom-code | static | verified | decision |
| `code.xpath-and-settings-nodes` | XPath content queries and settings nodes | migrate-custom-code | static | verified |  |
| `config.bundling` | Server-side bundling and minification | migrate-application-framework | static | verified |  |
| `config.committed-secrets` | Secrets in tracked configuration | migrate-config-auth-integrations | static | verified | baseline |
| `config.legacy-settings` | Custom application settings and configuration sections | migrate-application-framework | static | verified |  |
| `config.logging` | Legacy logging libraries | migrate-custom-code | static | verified |  |
| `config.startup-hosting` | Application startup and hosting model | migrate-application-framework | static | verified | baseline |
| `config.static-readers` | Static configuration readers | migrate-custom-code | static | hypothesis |  |
| `config.untracked-environment-config` | Environment configuration outside source control | deployment-rehearsal | static | hypothesis |  |
| `content.block-editors` | Block list and block grid page builders | migrate-content-database | static | verified |  |
| `content.code-first-doctypes` | Code-first content type libraries | migrate-custom-code | static | hypothesis |  |
| `content.datatype-config-reads` | Server-side reads of data type configuration | migrate-custom-code | static | hypothesis |  |
| `content.deploy-or-courier` | Vendor deployment and transfer tools | migrate-content-database | static | verified | flag |
| `content.element-type-consistency` | Element type flags and compositions | migrate-content-database | database-review | hypothesis |  |
| `content.forms` | Forms add-on customizations and storage | migrate-content-database | static | verified |  |
| `content.legacy-grid` | Legacy grid layout and grid editors | migrate-content-database | static | verified |  |
| `content.legacy-picker-values` | Obsolete editors and integer picker values | migrate-content-database | static | verified |  |
| `content.legacy-structured-editors` | Nested Content and other legacy structured editors | migrate-content-database | static | verified |  |
| `content.macros` | Macros and partial view macros | migrate-content-database | static | verified |  |
| `content.media-filesystem-provider` | Custom media file system providers | migrate-config-auth-integrations | static | verified | flag |
| `content.models-builder` | Models builder mode and generated models | migrate-application-framework | static | verified |  |
| `content.model-source-of-truth` | Content model files under source control | migrate-content-database | static | hypothesis |  |
| `content.multilingual-variants` | Multilingual and variant content | migrate-content-database | static | verified | flag |
| `content.non-core-editor-data` | Community or custom editor data | migrate-packages-backoffice | static | verified |  |
| `content.razor-compilation` | Razor view compilation settings | migrate-build-tests | static | verified | baseline |
| `data.custom-tables` | Custom database tables via ORM attributes and migrations | migrate-content-database | static | verified |  |
| `data.db-health` | Database health before a major migration | migrate-content-database | database-review | verified |  |
| `data.non-sqlserver-engine` | Database engine other than SQL Server | migrate-content-database | static | verified | baseline |
| `data.raw-sql-core-tables` | Raw SQL against CMS internal tables | migrate-custom-code | static | hypothesis |  |
| `data.raw-sql-custom` | Raw SQL over custom tables | migrate-custom-code | static | verified |  |
| `data.secondary-datastore` | Second database or non-CMS data access stack | migrate-custom-code | static | hypothesis |  |
| `deploy.ci-pipelines` | CI and CD pipeline definitions | deployment-rehearsal | static | hypothesis |  |
| `deploy.containers-or-cloud` | Containers, infrastructure as code, and load balancing | deployment-rehearsal | static | verified | flag |
| `deploy.iis-config` | IIS configuration, rewrite rules, and publish profiles | deployment-rehearsal | static | verified |  |
| `deploy.submodules-artifacts` | Git submodules and committed build artifacts | deployment-rehearsal | static | hypothesis |  |
| `ext.http-client` | HTTP clients to external services | migrate-config-auth-integrations | static | verified |  |
| `ext.payment-gateway` | Payment gateway integration | migrate-config-auth-integrations | static | hypothesis |  |
| `ext.smtp` | SMTP email sending | migrate-config-auth-integrations | static | verified |  |
| `ext.soap-client` | SOAP and WCF service references | migrate-config-auth-integrations | static | verified |  |
| `jobs.app-caching` | Application caching with publish-time invalidation | migrate-config-auth-integrations | static | verified |  |
| `jobs.cdn-purge` | CDN purge on publish | migrate-config-auth-integrations | static | hypothesis |  |
| `jobs.delivery-api` | Content delivery API usage | migrate-config-auth-integrations | static | verified | flag |
| `jobs.scheduled-work` | Scheduled and externally triggered background work | migrate-config-auth-integrations | static | verified |  |
| `jobs.search-indexing` | Search index customization | migrate-config-auth-integrations | static | verified |  |
| `jobs.webhooks` | Webhooks and custom webhook events | migrate-config-auth-integrations | static | verified | flag |
| `pkg.commerce-or-workflow-products` | Commerce and workflow add-on products | migrate-packages-backoffice | static | hypothesis | flag, decision |
| `pkg.core-id-changes` | Core and first-party package IDs per generation | migrate-application-framework | static | hypothesis | baseline |
| `pkg.framework-only-libs` | .NET Framework-only libraries | migrate-application-framework | package-metadata | verified |  |
| `pkg.implicit-transitive` | Implicit transitive dependencies | migrate-application-framework | static | verified |  |
| `pkg.loose-binaries` | Loose assembly references and committed binaries | migrate-application-framework | static | hypothesis |  |
| `pkg.no-target-version` | Packages without a release for the target | migrate-packages-backoffice | package-metadata | hypothesis | decision |
| `pkg.renamed-community` | Packages renamed or replaced for newer versions | migrate-packages-backoffice | package-metadata | hypothesis |  |
