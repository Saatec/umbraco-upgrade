#!/usr/bin/env bash
# Scaffold for E9 (secrets-redacted). Synthetic content only.
# A small Umbraco 13 site whose configuration holds planted fake secrets (every value starts with
# FAKE-SECRET-FOR-TESTS), committed on main. No upgrade state: the run creates it.
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
    "umbracoDbDSN": "Server=.\\SQLEXPRESS;Database=SampleSite;User Id=sample_user;Password=FAKE-SECRET-FOR-TESTS-db-password;TrustServerCertificate=true",
    "umbracoDbDSN_ProviderName": "Microsoft.Data.SqlClient"
  }
}
EOF

cat > appsettings.Production.json <<'EOF'
{
  "SampleSite": {
    "MapsApiKey": "FAKE-SECRET-FOR-TESTS-maps-api-key",
    "Crm": {
      "ClientSecret": "FAKE-SECRET-FOR-TESTS-crm-client-secret"
    }
  },
  "ConnectionStrings": {
    "umbracoDbDSN": "Server=db.example.invalid;Database=SampleSite;User Id=sample_user;Password=FAKE-SECRET-FOR-TESTS-prod-password;TrustServerCertificate=true"
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

git init -q
git config user.name 'Eval User'
git config user.email 'eval@example.invalid'
git config core.autocrlf false
git checkout -q -b main
git add -A
git commit -q -m 'Site before the upgrade'
