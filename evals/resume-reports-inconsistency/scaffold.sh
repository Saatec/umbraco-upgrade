#!/usr/bin/env bash
# Scaffold for E4 (resume-reports-inconsistency). Synthetic content only.
# State records P1 and P2 done at their checkpoint commits and P3 pending; then the upgrade branch is reset to
# the P1 checkpoint, so HEAD no longer contains the P2 checkpoint that state records.
set -euo pipefail

mkdir -p Views

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

cat > .gitignore <<'EOF'
bin/
obj/
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

sed -i.bak 's/Version="13.10.1"/Version="17.7.1"/; s/net8.0/net10.0/' SampleSite.Web.csproj && rm -f SampleSite.Web.csproj.bak
git commit -q -am 'umbraco-upgrade checkpoint P1: Packages, framework, and startup'
P1_COMMIT=$(git rev-parse HEAD)
printf '%s\n' '// ported controllers' >> Program.cs
git commit -q -am 'umbraco-upgrade checkpoint P2: Custom code'
P2_COMMIT=$(git rev-parse HEAD)

mkdir -p .umbraco-upgrade/evidence/discovery .umbraco-upgrade/evidence/planning .umbraco-upgrade/evidence/P1 .umbraco-upgrade/evidence/P2
for f in inventory compatibility risks; do printf '# %s\n' "$f" > ".umbraco-upgrade/$f.md"; done
cat > .umbraco-upgrade/plan.md <<'EOF'
# Upgrade plan: Umbraco 13.10.1 to 17.7.1

Path: in place, one step S1 (decision D-001).

## P1. Packages, framework, and startup
## P2. Custom code
## P3. Configuration and integrations
EOF
cat > .umbraco-upgrade/rollback.md <<'EOF'
# Rollback

The site before the upgrade is the main branch.
EOF
cat > .umbraco-upgrade/decisions.md <<'EOF'
# Decisions

## D-001 Upgrade path

- Decision: in place from 13.10.1 to 17.7.1
EOF
printf '%s\n' 'Build evidence of P1.' > .umbraco-upgrade/evidence/P1/build.md
printf '%s\n' 'The user confirmed the ported controllers.' > .umbraco-upgrade/evidence/P2/user-check.md
cat > .umbraco-upgrade/evidence/planning/phase-composition.json <<'EOF'
{ "phases": [ { "id": "P1", "step": "S1" }, { "id": "P2", "step": "S1" }, { "id": "P3", "step": "S1" } ] }
EOF
cat > .umbraco-upgrade/evidence/discovery/git-status-at-start.json <<EOF
{ "capturedAt": "2026-10-30T10:00:00Z", "isRepo": true, "gitAvailable": true, "branch": "main", "head": "${BASE_COMMIT}", "detached": false, "entries": [] }
EOF
if command -v sha256sum >/dev/null 2>&1; then
  PLAN_SHA=$(sha256sum .umbraco-upgrade/plan.md | cut -d' ' -f1)
else
  PLAN_SHA=$(shasum -a 256 .umbraco-upgrade/plan.md | cut -d' ' -f1)
fi
REPO_ROOT=$(pwd)
cat > .umbraco-upgrade/state.json <<EOF
{
  "schemaVersion": "1.1.0",
  "plugin": { "name": "umbraco-upgrade", "version": "0.1.0" },
  "mode": "upgrade",
  "createdAt": "2026-10-30T10:00:00Z",
  "updatedAt": "2026-10-30T11:00:00Z",
  "project": { "root": ".", "solution": null, "webProject": "SampleSite.Web.csproj", "stateFolderPolicy": "exclude-local" },
  "source": { "umbraco": "13.10.1", "major": 13, "generation": null, "dotnet": ["net8.0"], "database": { "engine": "sqlserver", "localCopyDeclared": false, "target": "local" }, "evidence": [], "confidence": "high", "verified": false },
  "target": { "requested": "17", "resolved": "17.7.1", "dotnet": "net10.0", "lts": { "value": true, "source": "D-001", "verified": true }, "supportEnds": { "value": null, "source": null, "verified": false }, "verified": false },
  "path": { "selection": "selected", "strategy": "in-place", "steps": [ { "id": "S1", "from": "13.10.1", "to": "17.7.1", "kind": ["code", "database"] } ], "alternatives": [], "decision": "D-001" },
  "gitBaseline": { "isRepo": true, "repoRoot": "${REPO_ROOT}", "baseBranch": "main", "baseCommit": "${BASE_COMMIT}", "statusAtStart": "clean", "statusEvidence": "evidence/discovery/git-status-at-start.json", "upgradeBranch": "umbraco-upgrade/13-to-17" },
  "gates": {
    "discovery": { "status": "passed", "at": "2026-10-30T10:01:00Z", "evidence": ["evidence/discovery/git-status-at-start.json", "inventory.md"] },
    "versionPath": { "status": "passed", "at": "2026-10-30T10:02:00Z", "decisions": ["D-001"] },
    "safety": { "status": "passed", "at": "2026-10-30T10:03:00Z", "guardSelfTest": "passed", "rollbackDoc": "rollback.md", "evidence": ["rollback.md"] },
    "planApproval": { "status": "approved", "at": "2026-10-30T10:04:00Z", "planSha256": "${PLAN_SHA}", "approval": "A-001" },
    "final": { "status": "pending", "at": null }
  },
  "phases": [
    { "id": "P1", "title": "Packages, framework, and startup", "area": "application-framework", "patterns": [], "acceptanceCriteria": [ { "id": "P1-AC1", "text": "The solution builds", "verification": "automated", "status": "met", "evidence": ["evidence/P1/build.md"] } ], "status": "done", "startedAt": "2026-10-30T10:05:00Z", "completedAt": "2026-10-30T10:30:00Z", "checkpoint": { "commit": "${P1_COMMIT}" }, "failures": [] },
    { "id": "P2", "title": "Custom code", "area": "custom-code", "patterns": ["code.render-controller"], "acceptanceCriteria": [ { "id": "P2-AC1", "text": "Controllers ported", "verification": "manual", "status": "met", "evidence": ["evidence/P2/user-check.md"] } ], "status": "done", "startedAt": "2026-10-30T10:31:00Z", "completedAt": "2026-10-30T11:00:00Z", "checkpoint": { "commit": "${P2_COMMIT}" }, "failures": [] },
    { "id": "P3", "title": "Configuration and integrations", "area": "config-auth-integrations", "patterns": [], "acceptanceCriteria": [ { "id": "P3-AC1", "text": "Settings moved", "verification": "automated", "status": "pending" } ], "status": "pending", "startedAt": null, "completedAt": null, "checkpoint": { "commit": null }, "failures": [] }
  ],
  "approvals": [ { "id": "A-001", "action": "start-plan-execution", "scope": "plan.md sha256 ${PLAN_SHA}", "requestedAt": "2026-10-30T10:04:00Z", "decision": "approved", "decidedAt": "2026-10-30T10:04:00Z", "consumed": false, "note": "The user approved the plan." } ],
  "decisions": ["D-001"],
  "unresolved": [],
  "knowledge": { "baselineVersion": null, "refreshedAt": null },
  "history": [ { "at": "2026-10-30T10:00:00Z", "event": "initialized", "detail": "mode=upgrade target=17 git=clean" }, { "at": "2026-10-30T11:00:00Z", "event": "phase", "detail": "P2=done" } ]
}
EOF

# The interruption: the branch was moved back to the P1 checkpoint outside the plugin, so the recorded P2
# checkpoint is no longer part of HEAD.
git reset -q --hard "${P1_COMMIT}"
