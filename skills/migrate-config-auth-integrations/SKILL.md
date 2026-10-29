---
name: migrate-config-auth-integrations
description: Internal phase skill of the umbraco-upgrade workflow for configuration, secrets, member and backoffice authentication, external integrations, background jobs, search, caching, webhooks, and media storage. Loaded during plan execution.
user-invocable: false
---

# Configuration, authentication, and integration phases

Used for phases with area `config-auth-integrations`: configuration and secrets, member registration and login, roles, external logins (members and editors), two-factor authentication, access rules, HTTP and SOAP clients, payment gateways, SMTP, scheduled work, search indexing, caching, CDN purging, webhooks, the delivery API, and media file systems. The phase lists the patterns that apply.

Follow [migration-rules.md](../upgrade-workflow/references/migration-rules.md). The core rule: **Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.** An integration that cannot be tested locally stays wired and gets a manual criterion; it is never switched off.

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

## 1. Read the phase

`Get-PatternGuidance.ps1 -ProjectRoot "<root>" -PhaseId <P>` for impacts, options, checks, sources, and hits.

## 2. Configuration and secrets

- View configuration only with `Read-RedactedConfig.ps1 -Path <file>`. Never print a value.
- Move values with `Copy-ConfigValue.ps1`: within the project to a JSON file, or to the project's user secrets with `-ToUserSecrets` (approval `outside-project-path`). Never re-type a secret.
- Settings the code reads move to typed options. Environment-specific values belong in environment files or environment variables; ask the user for the production shape (keys only) when it is not in the repository.

## 3. Authentication

- **Members.** Rebuild custom registration, login, profile, and password flows on the member managers the target documents, with proper reset tokens. Flag insecure flows (for example a reset without a token) and ask before changing their behavior.
- **Roles and access.** Choose between member groups, claims, or an injected service according to where roles come from; check protected pages and media with a test member.
- **External logins and two-factor.** Register providers through the target's external login and two-factor support; on the web components backoffice the documentation requires client-side registrations for the buttons and setup screens. Test only against a test tenant or a sandbox.

## 4. Integrations and jobs

- **HTTP clients.** Register clients through the HTTP client factory with endpoints and keys from options; keys come from a secret store.
- **SOAP clients.** Regenerate with the .NET service reference tool the Microsoft documentation names; installing a tool writes outside the project (approval `outside-project-path`). Endpoints come from configuration.
- **Payments, SMTP, CDN, webhooks, delivery API.** Use sandbox accounts, test zones, local mail pickup, or test receivers. Never call a production endpoint from the local site. If only production exists, add a manual criterion for the user.
- **Scheduled work.** Port to the recurring background jobs the target documents, or an external scheduler; choose server roles for load-balanced hosting.
- **Search and caching.** Port index customizations to the target's index options; order custom registrations after the core search composer where the documentation says so. Caches that must work across servers use the CMS cache refreshers.
- **Media storage.** Use the storage provider package release for the target; test with a test container.

## 5. Build, evidence, criteria

`Test-Build.ps1 -ProjectRoot "<root>" -PhaseId <P>`. Record each criterion with its evidence; integration criteria are usually manual. Hand back to the phase loop for the checkpoint.

## Never

- Print, log, or commit a secret.
- Call a production endpoint, sign in to a production tenant, or send real mail.
- Disable an integration, a job, or an authentication flow to make the site start; record an unresolved item instead.
