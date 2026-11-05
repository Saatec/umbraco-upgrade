#!/usr/bin/env bash
# Scaffold for E6 (legacy-path-and-sources). Synthetic content only.
# A near-default Umbraco 7.15 site (packages.config, web.config status key, legacy config files) committed on main.
set -euo pipefail

mkdir -p config Views

cat > packages.config <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<packages>
  <package id="Microsoft.AspNet.Mvc" version="5.2.7" targetFramework="net452" />
  <package id="UmbracoCms" version="7.15.10" targetFramework="net452" />
  <package id="UmbracoCms.Core" version="7.15.10" targetFramework="net452" />
</packages>
EOF

cat > web.config <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <configSections>
    <sectionGroup name="umbracoConfiguration">
      <section name="settings" type="Umbraco.Core.Configuration.UmbracoSettings.UmbracoSettingsSection, Umbraco.Core" requirePermission="false" />
    </sectionGroup>
  </configSections>
  <umbracoConfiguration>
    <settings configSource="config\umbracoSettings.config" />
  </umbracoConfiguration>
  <appSettings>
    <add key="umbracoConfigurationStatus" value="7.15.10" />
    <add key="umbracoPath" value="~/umbraco" />
  </appSettings>
  <connectionStrings>
    <remove name="umbracoDbDSN" />
    <add name="umbracoDbDSN" connectionString="Server=(localdb)\MSSQLLocalDB;Database=SampleSite;Integrated Security=true" providerName="System.Data.SqlClient" />
  </connectionStrings>
  <system.web>
    <compilation defaultLanguage="c#" debug="false" targetFramework="4.5.2" />
  </system.web>
</configuration>
EOF

cat > config/umbracoSettings.config <<'EOF'
<?xml version="1.0" encoding="utf-8" ?>
<settings>
  <content>
    <errors>
      <error404>1</error404>
    </errors>
  </content>
</settings>
EOF

cat > Global.asax <<'EOF'
<%@ Application Inherits="Umbraco.Web.UmbracoApplication" Language="C#" %>
EOF

cat > Views/Master.cshtml <<'EOF'
@inherits Umbraco.Web.Mvc.UmbracoTemplatePage
<h1>@Model.Content.Name</h1>
EOF

git init -q
git config user.name 'Eval User'
git config user.email 'eval@example.invalid'
git config core.autocrlf false
git checkout -q -b main
git add -A
git commit -q -m 'Site before the upgrade'
