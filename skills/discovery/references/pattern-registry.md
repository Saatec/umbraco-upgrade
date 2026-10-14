# Pattern registry

Detectors live in `${CLAUDE_PLUGIN_ROOT}/knowledge/patterns/*.json`. Each record has a generic ID, a description, detectors (file globs plus a regular expression, weighted `strong` or `supporting`), the generations it applies to, handling options, and sources. A pattern counts as found when at least one `strong` detector matches; `supporting` hits are reported only for found patterns. Every handling option is a hypothesis until the target version's documentation confirms it.

`Find-Patterns.ps1 -Path <root>` runs the registry on its own. `Invoke-Discovery.ps1` runs it as part of gate 1.

## Patterns detected in this plugin version

| ID | Finds | Typical handling options (verify against the target docs) |
|---|---|---|
| `code.render-controller` | Render controller base types of each generation, default render controller registration | Port to the target base type with constructor injection; or move page logic to view components or services |
| `code.surface-controller` | Surface controller base types, `BeginUmbracoForm`, `/umbraco/surface/` URLs | Port to the target base type; move JSON endpoints to API controllers |
| `code.frontend-api-controller` | `UmbracoApiController`, Web API `ApiController`, `/umbraco/api/` URLs | Port to the target API controller type, or to plain controllers with explicit routes where auto-routing is obsolete |
| `data.custom-tables` | `[TableName]`, migration base types and plans, schema helpers, table creation | Port data access and migrations to the target APIs; compare expected tables with a declared local database copy |
| `backoffice.angular-property-editor` | `package.manifest` with property editors, AngularJS controllers and views under `App_Plugins` | Keep on v13 or earlier; rewrite as a web component for v14 and later, keeping a server-side schema for stored data |
| `ext.http-client` | `HttpClient` construction and static instances, `WebClient`, `HttpWebRequest`, client factory, REST libraries; endpoint config keys | Register clients through the HTTP client factory and bind endpoints through options |
| `pkg.core-id-changes` | Core package IDs, configuration status keys, legacy config files; used by version detection | Replace legacy core package IDs with the target generation's IDs |
| `code.unclassified-umbraco-usage` | Catch-all: source files that use CMS namespaces but matched no pattern | Classify each file, or flag it for a human decision |

Later plugin versions add the remaining customization patterns (routing, events, composers, content editors, backoffice sections, authentication, jobs, configuration, packages, deployment).
