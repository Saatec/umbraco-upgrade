# ConnectionInfo.psm1 - resolves the effective CMS connection string and decides whether it is local.
# Connection strings stay in memory. Callers must never print them; output only engine and locality.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking

$script:DefaultName = 'umbracoDbDSN'

function ConvertFrom-ConnectionString {
    param([AllowEmptyString()][string]$Value)
    $h = @{}
    if ([string]::IsNullOrWhiteSpace($Value)) { return $h }
    foreach ($part in ($Value -split ';')) {
        $idx = $part.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $part.Substring(0, $idx).Trim().ToLowerInvariant()
        $v = $part.Substring($idx + 1).Trim().Trim('"', "'")
        $h[$k] = $v
    }
    return $h
}

function Test-LocalHostName {
    param([AllowEmptyString()][string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $h = $HostName.Trim().ToLowerInvariant().Trim('[', ']')
    $locals = @('.', '(local)', 'localhost', '127.0.0.1', '::1', '0:0:0:0:0:0:0:1')
    if ($locals -contains $h) { return $true }
    $machine = [string]$env:COMPUTERNAME
    if ($machine -and $h -eq $machine.ToLowerInvariant()) { return $true }
    try {
        $fqdn = [System.Net.Dns]::GetHostName()
        if ($fqdn -and $h -eq $fqdn.ToLowerInvariant()) { return $true }
    } catch { }
    if ($h -like '*.localhost') { return $true }
    return $false
}

function Get-DataSourceInfo {
    # Returns engine and locality. isLocal is $null when it cannot be determined.
    param([AllowEmptyString()][string]$ConnectionString, [AllowEmptyString()][string]$ProviderName = '')
    $r = [ordered]@{ engine = 'unknown'; isLocal = $null; reason = '' }
    if ([string]::IsNullOrWhiteSpace($ConnectionString)) { $r.reason = 'empty'; return $r }
    $cs = ConvertFrom-ConnectionString $ConnectionString
    $ds = $null
    foreach ($k in @('server', 'data source', 'address', 'addr', 'network address', 'host')) { if ($cs.ContainsKey($k)) { $ds = $cs[$k]; break } }
    $prov = [string]$ProviderName
    if ($prov -match '(?i)SqlServerCe' -or ($ds -and $ds -match '(?i)\.sdf$')) {
        $r.engine = 'sqlce'; $r.isLocal = $true; $r.reason = 'file database'; return $r
    }
    if ($prov -match '(?i)sqlite' -or ($ds -and $ds -match '(?i)\.(db|sqlite|sqlite3)$')) {
        $r.engine = 'sqlite'; $r.isLocal = $true; $r.reason = 'file database'; return $r
    }
    if ($prov -match '(?i)mysql|npgsql|postgres') { $r.engine = 'other' }
    else { $r.engine = 'sqlserver' }
    if (-not $ds) { $r.reason = 'no server in connection string'; return $r }
    if ($ds -match '(?i)^\|DataDirectory\|') { $r.isLocal = $true; $r.reason = 'file database'; return $r }
    if ($ds -match '(?i)^\(localdb\)\\') { $r.engine = 'localdb'; $r.isLocal = $true; $r.reason = 'LocalDB'; return $r }
    $hostPart = $ds -replace '(?i)^(tcp|np|lpc|admin):', ''
    $hostPart = ($hostPart -split ',')[0]
    $hostPart = ($hostPart -split '\\')[0]
    if ($hostPart -match '^\[?[0-9a-fA-F:]+\]?$' -and $hostPart.Contains(':')) { $hostPart = $hostPart } else { $hostPart = ($hostPart -split ':')[0] }
    $r.isLocal = (Test-LocalHostName $hostPart)
    $r.reason = $(if ($r.isLocal) { 'local server' } else { 'non-local server' })
    return $r
}

function Get-JsonPathValue {
    param($Object, [string[]]$Segments)
    $node = $Object
    foreach ($s in $Segments) {
        if ($null -eq $node) { return $null }
        $prop = $node.PSObject.Properties | Where-Object { $_.Name -ieq $s } | Select-Object -First 1
        if ($null -eq $prop) { return $null }
        $node = $prop.Value
    }
    return $node
}

function Get-UserSecretsPath {
    param([string]$ProjectDir)
    foreach ($proj in (Get-ChildItem -LiteralPath $ProjectDir -Filter '*.csproj' -ErrorAction SilentlyContinue)) {
        $text = Read-TextFile $proj.FullName
        if ($text -match '<UserSecretsId>\s*([^<\s]+)\s*</UserSecretsId>') {
            $id = $Matches[1]
            $base = $env:APPDATA
            if (-not $base -and $env:HOME) { $base = Join-Path $env:HOME '.microsoft/usersecrets' ; return (Join-Path (Join-Path $base $id) 'secrets.json') }
            if ($base) { return (Join-Path $base "Microsoft\UserSecrets\$id\secrets.json") }
        }
    }
    return $null
}

function Get-LaunchProfileEnvironment {
    # Environment variables of the launch profile dotnet run would use (named or first Project profile).
    param([string]$ProjectDir, [string]$ProfileName = '')
    $path = Join-Path $ProjectDir 'Properties/launchSettings.json'
    if (-not [System.IO.File]::Exists($path)) { return @{} }
    $j = Read-JsonFile $path
    $profiles = Get-JsonPathValue $j @('profiles')
    if ($null -eq $profiles) { return @{} }
    $chosen = $null
    foreach ($p in $profiles.PSObject.Properties) {
        if ($ProfileName) { if ($p.Name -ieq $ProfileName) { $chosen = $p.Value; break } }
        elseif ((Get-JsonPathValue $p.Value @('commandName')) -eq 'Project') { $chosen = $p.Value; break }
    }
    $h = @{}
    if ($chosen) {
        $ev = Get-JsonPathValue $chosen @('environmentVariables')
        if ($ev) { foreach ($e in $ev.PSObject.Properties) { $h[$e.Name] = [string]$e.Value } }
    }
    return $h
}

function Get-EffectiveConnectionString {
    # Layers (last wins): appsettings.json, appsettings.{env}.json, user secrets, launch profile env, process env.
    # Legacy projects: web.config connectionStrings. Returns the string in memory with its source layer.
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$Name = $script:DefaultName,
        [string]$Environment = '',
        [string]$LaunchProfile = '',
        [switch]$NoLaunchProfile
    )
    $result = [ordered]@{ connectionString = $null; providerName = $null; source = $null; environment = $null }
    $webConfig = Join-Path $ProjectDir 'web.config'
    $appsettings = Join-Path $ProjectDir 'appsettings.json'
    if (-not [System.IO.File]::Exists($appsettings) -and [System.IO.File]::Exists($webConfig)) {
        $doc = Read-XmlFile $webConfig
        foreach ($n in @($doc.SelectNodes("//*[local-name()='connectionStrings']/*[local-name()='add']"))) {
            if ($n.GetAttribute('name') -ieq $Name) {
                $result.connectionString = $n.GetAttribute('connectionString')
                $result.providerName = $n.GetAttribute('providerName')
                $result.source = 'web.config'
            }
        }
        return $result
    }
    $launchEnv = @{}
    if (-not $NoLaunchProfile) { $launchEnv = Get-LaunchProfileEnvironment -ProjectDir $ProjectDir -ProfileName $LaunchProfile }
    $envName = $Environment
    if (-not $envName) { $envName = [string]$env:ASPNETCORE_ENVIRONMENT }
    if (-not $envName) { $envName = [string]$env:DOTNET_ENVIRONMENT }
    if (-not $envName -and $launchEnv.ContainsKey('ASPNETCORE_ENVIRONMENT')) { $envName = $launchEnv['ASPNETCORE_ENVIRONMENT'] }
    if (-not $envName -and $launchEnv.ContainsKey('DOTNET_ENVIRONMENT')) { $envName = $launchEnv['DOTNET_ENVIRONMENT'] }
    if (-not $envName) { $envName = 'Production' }
    $result.environment = $envName
    $layers = @(
        @{ name = 'appsettings.json'; path = $appsettings },
        @{ name = "appsettings.$envName.json"; path = (Join-Path $ProjectDir "appsettings.$envName.json") }
    )
    if ($envName -ieq 'Development') {
        $sp = Get-UserSecretsPath -ProjectDir $ProjectDir
        if ($sp) { $layers += @{ name = 'user-secrets'; path = $sp; flat = $true } }
    }
    foreach ($l in $layers) {
        if (-not [System.IO.File]::Exists($l.path)) { continue }
        $j = Read-JsonFile $l.path
        $v = $null; $p = $null
        if ($l.ContainsKey('flat')) {
            $v = Get-JsonPathValue $j @("ConnectionStrings:$Name")
            $p = Get-JsonPathValue $j @("ConnectionStrings:${Name}_ProviderName")
            if ($null -eq $v) { $v = Get-JsonPathValue $j @('ConnectionStrings', $Name) }
        } else {
            $v = Get-JsonPathValue $j @('ConnectionStrings', $Name)
            $p = Get-JsonPathValue $j @('ConnectionStrings', "${Name}_ProviderName")
        }
        if ($null -ne $v) { $result.connectionString = [string]$v; $result.source = $l.name }
        if ($null -ne $p) { $result.providerName = [string]$p }
    }
    $envKey = "ConnectionStrings__$Name"
    if ($launchEnv.ContainsKey($envKey)) { $result.connectionString = $launchEnv[$envKey]; $result.source = 'launchSettings.json' }
    if ($launchEnv.ContainsKey("${envKey}_ProviderName")) { $result.providerName = $launchEnv["${envKey}_ProviderName"] }
    $pv = [Environment]::GetEnvironmentVariable($envKey)
    if ($pv) { $result.connectionString = $pv; $result.source = 'environment' }
    $pp = [Environment]::GetEnvironmentVariable("${envKey}_ProviderName")
    if ($pp) { $result.providerName = $pp }
    return $result
}

function Get-DatabaseSummary {
    # Engine and locality per configuration file, without connection strings. Used by discovery.
    param([Parameter(Mandatory)][string]$ProjectDir)
    $items = New-Object System.Collections.ArrayList
    $envs = @('')
    foreach ($f in (Get-ChildItem -LiteralPath $ProjectDir -Filter 'appsettings.*.json' -ErrorAction SilentlyContinue)) {
        if ($f.Name -match '^appsettings\.([\w\-]+)\.json$') { $envs += $Matches[1] }
    }
    foreach ($e in $envs) {
        $envArg = $e; if (-not $e) { $envArg = 'Production' }
        $eff = Get-EffectiveConnectionString -ProjectDir $ProjectDir -Environment $envArg -NoLaunchProfile
        if ($null -eq $eff.connectionString -and $null -eq $eff.source) { continue }
        $info = Get-DataSourceInfo -ConnectionString $eff.connectionString -ProviderName $eff.providerName
        [void]$items.Add([ordered]@{ environment = $eff.environment; source = $eff.source; engine = $info.engine; isLocal = $info.isLocal; reason = $info.reason })
        if ($eff.source -eq 'web.config') { break }
    }
    return ,($items.ToArray())
}

Export-ModuleMember -Function ConvertFrom-ConnectionString, Test-LocalHostName, Get-DataSourceInfo, Get-EffectiveConnectionString, Get-DatabaseSummary, Get-LaunchProfileEnvironment, Get-UserSecretsPath
