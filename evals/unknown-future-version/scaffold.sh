#!/usr/bin/env bash
# Scaffold for E7 (unknown-future-version). Synthetic content only.
# A near-default Umbraco 13 site committed on main; the target 25 does not exist.
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
