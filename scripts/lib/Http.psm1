# Http.psm1 - read-only HTTP GET with a cache in the plugin data directory.
# Network access goes only to the hosts listed in knowledge/sources.json; callers pass full URLs.
# Test seam: when UMBRACO_UPGRADE_HTTP_MOCK names one or more mock directories (separated by ';'),
# responses come from <dir>/index.json and no request leaves the machine. Unrecorded URLs fail as
# network errors. Used only by the plugin's own tests.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking

$script:PluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:MockIndex = $null
$script:MockKey = $null
$script:Client = $null
$script:AllowedHosts = $null

function Get-HttpPluginRoot { return $script:PluginRoot }

function Get-AllowedHosts {
    # The hosts the plugin may contact, from the baseline knowledge/sources.json. Refreshed knowledge cannot add hosts.
    if ($null -eq $script:AllowedHosts) {
        $src = Read-JsonFile (Join-Path $script:PluginRoot 'knowledge/sources.json')
        $script:AllowedHosts = @($src.hosts | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    return $script:AllowedHosts
}

function Resolve-PluginDataDir {
    # Returns the plugin data directory from -DataDir or CLAUDE_PLUGIN_DATA, or $null when neither is set.
    # Refuses any location inside the plugin root: the root is replaced on every plugin update.
    param([string]$DataDir = '')
    $d = $DataDir
    if (-not $d) { $d = [Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_DATA') }
    if (-not $d) { return $null }
    $full = Resolve-FullPath $d
    if (Test-PathUnder -Root $script:PluginRoot -Path $full) { throw "Refusing to use '$full' as the plugin data directory: it is inside the plugin root, which is replaced on every update. Pass `${CLAUDE_PLUGIN_DATA}." }
    return $full
}

function Get-MockIndex {
    $raw = [Environment]::GetEnvironmentVariable('UMBRACO_UPGRADE_HTTP_MOCK')
    if (-not $raw) { return $null }
    if ($raw -eq $script:MockKey -and $null -ne $script:MockIndex) { return ,$script:MockIndex }
    $entries = New-Object System.Collections.ArrayList
    foreach ($dir in ($raw -split ';' | Where-Object { $_ })) {
        $idx = Join-Path $dir 'index.json'
        if (-not [System.IO.File]::Exists($idx)) { throw "Mock index not found: $idx" }
        foreach ($e in @((Read-JsonFile $idx).entries)) {
            [void]$entries.Add([ordered]@{ dir = $dir; entry = $e })
        }
    }
    $script:MockKey = $raw
    $script:MockIndex = $entries
    # The comma keeps an empty list from turning into $null (which would mean "no mock" and reach the network).
    return ,$entries
}

function Get-HttpClient {
    if ($null -ne $script:Client) { return $script:Client }
    Add-Type -AssemblyName System.Net.Http
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(45)
    $version = 'dev'
    try { $version = [string](Read-JsonFile (Join-Path $script:PluginRoot '.claude-plugin/plugin.json')).version } catch { }
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("umbraco-upgrade-plugin/$version")
    $script:Client = $client
    return $client
}

function Invoke-HttpGet {
    # Returns url, status (0 on a network error), finalUrl (after redirects), contentType, body (UTF-8 text), error, mocked.
    param([Parameter(Mandatory)][string]$Url, [int]$MaxBytes = 8MB)
    $r = [ordered]@{ url = $Url; status = 0; finalUrl = $Url; contentType = $null; body = $null; error = $null; mocked = $false }
    if ($Url -notmatch '^https://') { $r.error = 'Only https URLs are allowed.'; return $r }
    $urlHost = ([uri]$Url).Host.ToLowerInvariant()
    if ((Get-AllowedHosts) -notcontains $urlHost) { $r.error = "Host '$urlHost' is not in the plugin's network allowlist (knowledge/sources.json hosts)."; return $r }
    $mock = Get-MockIndex
    if ($null -ne $mock) {
        $r.mocked = $true
        $hit = $null
        foreach ($m in $mock) { if ([string]$m.entry.url -ceq $Url) { $hit = $m; break } }
        if ($null -eq $hit) { $r.error = 'network error (URL not recorded in the mock)'; return $r }
        $e = $hit.entry
        $r.status = [int]$e.status
        if ($e.PSObject.Properties['finalUrl'] -and $e.finalUrl) { $r.finalUrl = [string]$e.finalUrl }
        if ($e.PSObject.Properties['contentType']) { $r.contentType = [string]$e.contentType }
        if ($e.PSObject.Properties['file'] -and $e.file) { $r.body = Read-TextFile (Join-Path $hit.dir ([string]$e.file)) } else { $r.body = '' }
        return $r
    }
    try {
        $client = Get-HttpClient
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        try {
            $r.status = [int]$resp.StatusCode
            $r.finalUrl = $resp.RequestMessage.RequestUri.AbsoluteUri
            if ($resp.Content.Headers.ContentType) { $r.contentType = $resp.Content.Headers.ContentType.ToString() }
            $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -gt $MaxBytes) { $r.error = "Response larger than $MaxBytes bytes."; $r.body = $null; return $r }
            $r.body = $script:Utf8.GetString($bytes)
            if ($r.body.Length -gt 0 -and $r.body[0] -eq [char]0xFEFF) { $r.body = $r.body.Substring(1) }
        } finally { $resp.Dispose() }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        $r.status = 0
        $r.error = "network error: $msg"
    }
    return $r
}

function Get-UrlHash {
    param([Parameter(Mandatory)][string]$Url)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($script:Utf8.GetBytes($Url)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function Get-TextSha256 {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($script:Utf8.GetBytes([string]$Text)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function Get-CachePaths {
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$Url)
    $dir = Join-Path $DataDir 'doc-cache'
    $h = Get-UrlHash $Url
    return [ordered]@{ dir = $dir; body = (Join-Path $dir ($h + '.body')); meta = (Join-Path $dir ($h + '.json')) }
}

function Read-HttpCache {
    # Returns the cached metadata (with bodyPath and ageDays) or $null.
    param([string]$DataDir, [Parameter(Mandatory)][string]$Url)
    if (-not $DataDir) { return $null }
    $p = Get-CachePaths -DataDir $DataDir -Url $Url
    if (-not ([System.IO.File]::Exists($p.meta) -and [System.IO.File]::Exists($p.body))) { return $null }
    try { $meta = ConvertTo-PlainObject (Read-JsonFile $p.meta) } catch { return $null }
    $fetched = [DateTime]::Parse([string]$meta['fetchedAt'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    $meta['ageDays'] = [Math]::Round(([DateTime]::UtcNow - $fetched).TotalDays, 2)
    $meta['bodyPath'] = $p.body
    return $meta
}

function Save-HttpCache {
    # Stores a validated response body with its metadata. $Label carries the caller's labels (version, space, source type).
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)]$Response, [System.Collections.IDictionary]$Label = @{})
    $p = Get-CachePaths -DataDir $DataDir -Url $Response.url
    Write-TextFile -Path $p.body -Content ([string]$Response.body)
    $meta = [ordered]@{
        url = $Response.url; finalUrl = $Response.finalUrl; httpStatus = $Response.status; contentType = $Response.contentType
        fetchedAt = (Get-UtcTimestamp); sha256 = (Get-TextSha256 ([string]$Response.body)); bytes = $script:Utf8.GetByteCount([string]$Response.body)
    }
    foreach ($k in $Label.Keys) { $meta[$k] = $Label[$k] }
    Write-AtomicTextFile -Path $p.meta -Content (ConvertTo-JsonText -InputObject $meta)
    $meta['bodyPath'] = $p.body
    $meta['ageDays'] = 0
    return $meta
}

function Invoke-CachedGet {
    # Cache first (unless -Refresh or older than -MaxAgeDays), then the network. $Validator gets the response and
    # $ValidatorContext and returns 'ok' or a failure status; only 'ok' responses are cached. When the network fails and a cached copy
    # exists, the stale copy is returned with stale = true.
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$DataDir,
        [double]$MaxAgeDays = 7,
        [switch]$Refresh,
        [scriptblock]$Validator = { param($resp, $ctx) if ($resp.status -eq 200) { 'ok' } else { 'http-' + $resp.status } },
        $ValidatorContext = $null,
        [System.Collections.IDictionary]$Label = @{}
    )
    $cached = Read-HttpCache -DataDir $DataDir -Url $Url
    if ($cached -and -not $Refresh -and [double]$cached['ageDays'] -le $MaxAgeDays) {
        return [ordered]@{ status = 'ok'; fromCache = $true; stale = $false; meta = $cached; body = (Read-TextFile $cached['bodyPath']); response = $null; error = $null }
    }
    $resp = Invoke-HttpGet -Url $Url
    if ($resp.status -eq 0) {
        if ($cached) {
            return [ordered]@{ status = 'ok'; fromCache = $true; stale = $true; meta = $cached; body = (Read-TextFile $cached['bodyPath']); response = $resp; error = $resp.error }
        }
        return [ordered]@{ status = 'network-error'; fromCache = $false; stale = $false; meta = $null; body = $null; response = $resp; error = $resp.error }
    }
    $verdict = [string](& $Validator $resp $ValidatorContext)
    if ($verdict -ne 'ok') {
        return [ordered]@{ status = $verdict; fromCache = $false; stale = $false; meta = $null; body = $resp.body; response = $resp; error = $null }
    }
    $meta = $null
    if ($DataDir) { $meta = Save-HttpCache -DataDir $DataDir -Response $resp -Label $Label }
    else {
        $meta = [ordered]@{ url = $resp.url; finalUrl = $resp.finalUrl; httpStatus = $resp.status; contentType = $resp.contentType; fetchedAt = (Get-UtcTimestamp); sha256 = (Get-TextSha256 ([string]$resp.body)); bytes = $script:Utf8.GetByteCount([string]$resp.body); bodyPath = $null; ageDays = 0 }
        foreach ($k in $Label.Keys) { $meta[$k] = $Label[$k] }
    }
    return [ordered]@{ status = 'ok'; fromCache = $false; stale = $false; meta = $meta; body = $resp.body; response = $resp; error = $null }
}

Export-ModuleMember -Function Get-HttpPluginRoot, Get-AllowedHosts, Resolve-PluginDataDir, Invoke-HttpGet, Get-UrlHash, Get-TextSha256, Read-HttpCache, Save-HttpCache, Invoke-CachedGet
