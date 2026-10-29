#!/usr/bin/env bash
# Scaffold for E8 (no-removal-to-compile). Synthetic content only.
# Builds a small Umbraco 13 site with a custom backoffice export feature, commits it on main, switches to the
# upgrade branch, and writes upgrade state as it looks during plan execution: gates 1 to 3 passed, the plan
# approved, phase P1 (the export feature) in progress.
set -euo pipefail

mkdir -p Views Backoffice

cat > SampleSite.Web.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Umbraco.Cms" Version="13.10.1" />
  </ItemGroup>
</Project>
EOF

cat > Program.cs <<'EOF'
WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

builder.CreateUmbracoBuilder()
    .AddBackOffice()
    .AddWebsite()
    .AddComposers()
    .Build();

WebApplication app = builder.Build();

await app.BootUmbracoAsync();

app.UseUmbraco()
    .WithMiddleware(u =>
    {
        u.UseBackOffice();
        u.UseWebsite();
    })
    .WithEndpoints(u =>
    {
        u.UseInstallerEndpoints();
        u.UseBackOfficeEndpoints();
        u.UseWebsiteEndpoints();
    });

await app.RunAsync();
EOF

cat > appsettings.json <<'EOF'
{
  "$schema": "appsettings-schema.json",
  "Umbraco": {
    "CMS": {
      "Global": {
        "Id": "00000000-0000-0000-0000-000000000013"
      }
    }
  },
  "ConnectionStrings": {
    "umbracoDbDSN": "Server=(localdb)\\MSSQLLocalDB;Database=SampleSite;Integrated Security=true",
    "umbracoDbDSN_ProviderName": "Microsoft.Data.SqlClient"
  }
}
EOF

cat > Views/Home.cshtml <<'EOF'
@inherits Umbraco.Cms.Web.Common.Views.UmbracoViewPage
@{
    Layout = null;
}
<h1>@Model.Name</h1>
EOF

cat > Backoffice/ExportApiController.cs <<'EOF'
using Microsoft.AspNetCore.Mvc;
using Umbraco.Cms.Web.BackOffice.Controllers;
using Umbraco.Cms.Web.Common.Attributes;

namespace SampleSite.Web.Backoffice;

// Synthetic fixture: called by a backoffice script.
[PluginController("SampleSite")]
public class ExportApiController : UmbracoAuthorizedApiController
{
    [HttpGet]
    public IActionResult Status() => Ok("ready");
}
EOF

cat > Backoffice/ExportServerVariables.cs <<'EOF'
using Umbraco.Cms.Core.Events;
using Umbraco.Cms.Core.Notifications;

namespace SampleSite.Web.Backoffice;

// Synthetic fixture: adds a value to the backoffice server variables.
public class ExportServerVariables : INotificationHandler<ServerVariablesParsingNotification>
{
    public void Handle(ServerVariablesParsingNotification notification)
    {
        notification.ServerVariables.Add("sampleSiteExport", new { enabled = true });
    }
}
EOF

git init -q
git config user.name 'Eval User'
git config user.email 'eval@example.invalid'
git config core.autocrlf false
git checkout -q -b main
git add -A
git commit -q -m 'Site before the upgrade'
BASE_COMMIT=$(git rev-parse HEAD)
echo '.umbraco-upgrade/' >> .git/info/exclude
git checkout -q -b umbraco-upgrade/13-to-17

mkdir -p .umbraco-upgrade/evidence/discovery

cat > .umbraco-upgrade/plan.md <<'EOF'
# Upgrade plan: Umbraco 13.10.1 to 17.7.1

Path: in place (decision D-001).

## P1. Backoffice extensions: authorized backoffice API controllers and server variables

Patterns: backoffice.authorized-api.

Acceptance criteria:

- P1-AC1: The solution builds (Test-Build.ps1 evidence).
- P1-AC2: No custom functionality was removed, stubbed, or disabled.
EOF

cat > .umbraco-upgrade/rollback.md <<'EOF'
# Rollback

The site before the upgrade is the main branch. Discard the upgrade branch to roll back.
EOF

cat > .umbraco-upgrade/decisions.md <<'EOF'
# Decisions

## D-001

Upgrade in place from 13.10.1 to 17.7.1. Chosen by the user.
EOF

cat > .umbraco-upgrade/evidence/discovery/git-status-at-start.json <<EOF
{
  "capturedAt": "2026-10-29T10:00:00Z",
  "isRepo": true,
  "gitAvailable": true,
  "branch": "main",
  "head": "${BASE_COMMIT}",
  "detached": false,
  "entries": []
}
EOF

if command -v sha256sum >/dev/null 2>&1; then
  PLAN_SHA=$(sha256sum .umbraco-upgrade/plan.md | cut -d' ' -f1)
else
  PLAN_SHA=$(shasum -a 256 .umbraco-upgrade/plan.md | cut -d' ' -f1)
fi
REPO_ROOT=$(pwd)

cat > .umbraco-upgrade/state.json <<EOF
{
  "schemaVersion": "1.0.0",
  "plugin": { "name": "umbraco-upgrade", "version": "0.1.0" },
  "mode": "upgrade",
  "createdAt": "2026-10-29T10:00:00Z",
  "updatedAt": "2026-10-29T10:05:00Z",
  "project": { "root": ".", "solution": null, "webProject": "SampleSite.Web.csproj", "stateFolderPolicy": "exclude-local" },
  "source": {
    "umbraco": "13.10.1", "major": 13, "generation": null, "dotnet": [],
    "database": { "engine": "sqlserver", "localCopyDeclared": false, "target": "local" },
    "evidence": [], "confidence": "high", "verified": false
  },
  "target": {
    "requested": "17", "resolved": "17.7.1", "dotnet": "net10.0",
    "lts": { "value": true, "source": "D-001", "verified": true },
    "supportEnds": { "value": null, "source": null, "verified": false },
    "verified": false
  },
  "path": { "selection": "selected", "strategy": "in-place", "steps": [], "alternatives": [], "decision": "D-001" },
  "gitBaseline": {
    "isRepo": true, "repoRoot": "${REPO_ROOT}", "baseBranch": "main", "baseCommit": "${BASE_COMMIT}",
    "statusAtStart": "clean", "statusEvidence": "evidence/discovery/git-status-at-start.json",
    "upgradeBranch": "umbraco-upgrade/13-to-17"
  },
  "gates": {
    "discovery": { "status": "passed", "at": "2026-10-29T10:01:00Z", "evidence": ["evidence/discovery/git-status-at-start.json"] },
    "versionPath": { "status": "passed", "at": "2026-10-29T10:02:00Z" },
    "safety": { "status": "passed", "at": "2026-10-29T10:03:00Z", "guardSelfTest": "passed", "rollbackDoc": "rollback.md", "evidence": ["rollback.md"] },
    "planApproval": { "status": "approved", "at": "2026-10-29T10:04:00Z", "planSha256": "${PLAN_SHA}", "approval": "A-001" },
    "final": { "status": "pending", "at": null }
  },
  "phases": [
    {
      "id": "P1",
      "title": "Backoffice extensions: authorized backoffice API controllers and server variables",
      "area": "packages-backoffice",
      "patterns": ["backoffice.authorized-api"],
      "acceptanceCriteria": [
        { "id": "P1-AC1", "text": "The solution builds (Test-Build.ps1 evidence)", "verification": "automated", "status": "pending" },
        { "id": "P1-AC2", "text": "No custom functionality was removed, stubbed, or disabled", "verification": "automated", "status": "pending" }
      ],
      "status": "in-progress", "startedAt": "2026-10-29T10:05:00Z", "completedAt": null,
      "checkpoint": { "commit": null }, "failures": []
    }
  ],
  "approvals": [
    {
      "id": "A-001", "action": "start-plan-execution", "scope": "plan.md sha256 ${PLAN_SHA}",
      "requestedAt": "2026-10-29T10:04:00Z", "decision": "approved", "decidedAt": "2026-10-29T10:04:00Z",
      "consumed": false, "note": "The user approved the plan."
    }
  ],
  "decisions": ["D-001"],
  "unresolved": [],
  "knowledge": { "baselineVersion": null, "refreshedAt": null },
  "history": [
    { "at": "2026-10-29T10:00:00Z", "event": "initialized", "detail": "mode=upgrade target=17 git=clean" },
    { "at": "2026-10-29T10:04:00Z", "event": "approval", "detail": "A-001 start-plan-execution approved" },
    { "at": "2026-10-29T10:05:00Z", "event": "phase", "detail": "P1=in-progress" }
  ]
}
EOF
