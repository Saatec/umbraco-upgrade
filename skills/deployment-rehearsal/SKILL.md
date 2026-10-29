---
name: deployment-rehearsal
description: Internal phase skill of the umbraco-upgrade workflow for deployment rehearsal and production readiness (CI pipelines, IIS, publish profiles, containers, environment configuration). Never deploys. Loaded during plan execution.
user-invocable: false
---

# Deployment rehearsal phases

Used for phases with area `deployment-rehearsal`: CI and CD pipelines, IIS configuration and rewrite rules, publish profiles, containers and infrastructure templates, environment configuration kept outside source control, and submodules or committed artifacts. The plugin prepares and documents; the user rehearses and deploys.

Follow [migration-rules.md](../upgrade-workflow/references/migration-rules.md). The core rule: **Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.** Rewrite rules, modules, and pipeline steps are functionality too.

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

## Rules

- **Never deploy.** Publishing to a remote target, swapping slots, pushing images, or applying infrastructure is prohibited; the safety hook blocks it. A file-system publish into a local folder is allowed for inspection.
- Changing a CI or deployment file needs the `ci-deploy-config-change` approval; the safety hook asks for each edit too.
- Never read or print production secrets. Ask the user for the production configuration shape as key names only.

## Steps

1. `Get-PatternGuidance.ps1 -ProjectRoot "<root>" -PhaseId <P>`.
2. **Pipelines** (`deploy.ci-pipelines`): list the SDK, build, and test steps that change for the target framework. Propose the edits, ask for the approval, then edit.
3. **IIS** (`deploy.iis-config`): the hosting requirements of the target come from its IIS hosting documentation (for example the hosting bundle for the target .NET version, which the user installs). Rewrite rules stay in `web.config` for IIS or move to the rewrite middleware; custom modules and handlers move to middleware. Keep every rule; test each one in the rehearsal.
4. **Containers and templates** (`deploy.containers-or-cloud`): update base images and templates to the target runtime with the approval; never apply them.
5. **Environment configuration** (`config.untracked-environment-config`): record the production key names (never values) and map them to the target configuration.
6. **Submodules and artifacts** (`deploy.submodules-artifacts`): list them in the rehearsal plan.
7. **Rehearsal plan.** Write `.umbraco-upgrade/evidence/<P>/rehearsal.md` with `Write-Evidence.ps1`: the target environment (non-production), the steps the user runs, the database restore from the user's backup, the rollback from `rollback.md`, and the checks after deployment. The user rehearses; record their result as evidence.

## Never

- Run a deployment, a remote publish, or an infrastructure apply.
- Edit CI or deployment files without the recorded approval.
- Drop a rewrite rule, module, or pipeline step to make the build pass.
