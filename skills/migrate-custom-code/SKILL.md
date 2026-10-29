---
name: migrate-custom-code
description: Internal phase skill of the umbraco-upgrade workflow for custom code phases (controllers, composition, notifications, routing, content finders, value converters, queries, data access, views and templates). Loaded during plan execution.
user-invocable: false
---

# Custom code phases

Used for phases with area `custom-code`: controllers, composition and dependency injection, event and notification handlers, routing, content finders and error handling, value converters, content queries and writes, data access, hard-coded IDs, configuration readers, logging, and the templates and views rebuilt on a new codebase. The phase lists the patterns that apply.

Follow [migration-rules.md](../upgrade-workflow/references/migration-rules.md). The core rule: **Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.**

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

## 1. Read the phase

- `Get-PatternGuidance.ps1 -ProjectRoot "<root>" -PhaseId <P>`: per pattern, the impacts the upgrade crosses (with sources), the handling options for the target generation, the checks, and the files and lines discovery found.
- `.umbraco-upgrade/evidence/planning/phase-composition.json`: the files of this phase when a pattern was split into parts. Work only on those files in this phase.
- For a large or unclear set of files, delegate the classification to the `umbraco-upgrade:inventory-analyst` agent and work from its summary.

## 2. Per pattern

1. Read the cited documentation for the exact target version with `umbraco-upgrade:doc-retrieval` (or the `umbraco-upgrade:docs-researcher` agent for long pages). For each API the code uses, confirm the target signature or its documented replacement. When a removal is documented (for example a base class or a service), use the documented replacement only.
2. Choose among the handling options. Record the decision with the rejected options and the sources (`state.ps1 decision`, `decisions.md`).
3. Port the code. Keep behavior: same routes and URLs, same view models, same side effects, same error handling. Where the target forces a behavior change (for example JSON casing or a removed feature), name it in the decision and add a check.
4. Anything that cannot be ported directly stays in place and becomes an unresolved item with a proposal (port, replace, redesign). The phase becomes `blocked` if it blocks a criterion.

## 3. Guidance by kind of code

- **Controllers.** Render, surface, and API controllers move to the base types the target documents. When the target removes auto-routed API controllers, keep every public URL working with explicit routes; callers outside the project depend on them.
- **Composition and notifications.** Registrations move to composers or builder extensions; event subscriptions move to notification handlers. Review lifetimes: a singleton must not capture request-scoped objects. Use async handlers for I/O.
- **Queries.** Replace removed query APIs (for example XPath) with the documented alternatives. Settings read from content keep resolving the same nodes; check it.
- **Data access and SQL.** SQL over custom tables usually stays; SQL against CMS internal tables must be rewritten or replaced with services and verified at runtime on the local copy, never by build success.
- **Hard-coded IDs.** They stay valid only on a database-preserving path. Never renumber them; add a check that each resolves on the migrated copy.
- **Views and templates (new codebase).** Rebuild each template and partial view on the target view engine: child actions become view components, helpers become partials or tag helpers, static access becomes injection. Keep the rendered markup the same.
- **WebForms and vendored code** are user decisions (`requiresDecision`): present the options, record the answer, then do exactly that.

## 4. Build, evidence, criteria

`Test-Build.ps1 -ProjectRoot "<root>" -PhaseId <P>`. Record each criterion with its evidence; manual criteria need the user's confirmation. Hand back to the phase loop for the checkpoint.

## Never

- Comment out, delete, or stub code that does not compile; record an unresolved item instead.
- Change a public URL, a route, or a view model's shape without the user's decision.
- Rely on an API you did not confirm in the target documentation.
