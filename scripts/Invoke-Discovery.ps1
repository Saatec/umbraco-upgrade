<#
.SYNOPSIS
  Gate 1 discovery: version detection, inventory, pattern detection, and database summary.

.DESCRIPTION
  Read-only on the project. Writes only redacted evidence under .umbraco-upgrade/evidence/discovery/
  and updates state through the state module. Requires state.ps1 init first (init takes the git
  status snapshot before anything is written). Prints a compact JSON summary.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Discovery.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/ConnectionInfo.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $state = Read-UpgradeState $root
    $gate = $state['gates']['discovery']['status']
    if ($gate -notin @('pending', 'in-progress', 'failed')) { throw "Discovery gate is '$gate'; discovery has already completed." }
    if ($gate -ne 'in-progress') { [void](Set-UpgradeGate -ProjectRoot $root -Gate discovery -Status in-progress) }

    $version = Get-UmbracoVersionInfo -Root $root
    $inventory = Get-ProjectInventoryInfo -Root $root
    # Files git reported as modified or untracked when the state was created (outside .umbraco-upgrade/).
    $changed = @()
    $statusRel = [string]$state['gitBaseline']['statusEvidence']
    if ($statusRel) {
        $statusPath = Join-Path (Get-StateDir $root) $statusRel
        if ([System.IO.File]::Exists($statusPath)) {
            $st = Read-JsonFile $statusPath
            if ($st.PSObject.Properties['entries']) { $changed = @(@($st.entries) | Where-Object { $_ -and -not $_.inStateFolder -and ([string]$_.code -match 'M|\?\?') } | ForEach-Object { [string]$_.path }) }
        }
    }
    $patterns = Find-PatternHits -Root $root -ChangedFiles $changed

    # Database engine and locality per configuration layer, for each web project (no connection strings).
    $dbDirs = New-Object System.Collections.ArrayList
    foreach ($wp in @($version.webProjects)) { [void]$dbDirs.Add([System.IO.Path]::GetDirectoryName((Join-Path $root $wp))) }
    if ($dbDirs.Count -eq 0) {
        foreach ($cf in @($inventory.configFiles)) {
            if ($cf -match '(?i)(^|/)(web\.config|appsettings\.json)$' -and $cf -notmatch '(?i)(^|/)views/') {
                [void]$dbDirs.Add([System.IO.Path]::GetDirectoryName((Join-Path $root $cf)))
            }
        }
    }
    $database = foreach ($d in ($dbDirs | Select-Object -Unique)) {
        [ordered]@{ project = (Get-RelativePathCompat -BasePath $root -Path $d); configurations = (Get-DatabaseSummary -ProjectDir $d) }
    }
    $database = @($database)

    $evDir = Join-Path (Get-StateDir $root) 'evidence/discovery'
    $files = [ordered]@{
        'version.json' = $version; 'inventory.json' = $inventory; 'patterns.json' = $patterns; 'database.json' = [ordered]@{ projects = $database }
    }
    $evidence = @()
    foreach ($k in $files.Keys) {
        $safe = Protect-Object -InputObject (ConvertTo-PlainObject $files[$k])
        $text = Protect-Text (ConvertTo-JsonText -InputObject $safe)
        Write-TextFile -Path (Join-Path $evDir $k) -Content $text
        $evidence += "evidence/discovery/$k"
    }

    # Database summary across configurations: engine of the base configuration; non-local if any layer is non-local.
    $engines = @($database | ForEach-Object { $_.configurations } | ForEach-Object { $_.engine } | Where-Object { $_ } | Select-Object -Unique)
    $locals = @($database | ForEach-Object { $_.configurations } | ForEach-Object { $_.isLocal })
    $dbTarget = 'unknown'
    if ($locals.Count -gt 0) {
        if (@($locals | Where-Object { $_ -eq $false }).Count -gt 0) { $dbTarget = 'non-local' }
        elseif (@($locals | Where-Object { $null -eq $_ }).Count -eq 0) { $dbTarget = 'local' }
    }
    $engine = 'unknown'; if ($engines.Count -ge 1) { $engine = [string]$engines[0] }

    $confidence = [string]$version.resolved.confidence
    if ($confidence -eq 'none' -and $version.isUmbraco) { $confidence = 'low' }
    $src = [ordered]@{
        umbraco = $version.resolved.version; major = $version.resolved.major; generation = $version.resolved.generation
        dotnet = @($version.targetFrameworks); database = [ordered]@{ engine = $engine; target = $dbTarget }
        evidence = @('evidence/discovery/version.json', 'evidence/discovery/database.json'); confidence = $confidence; verified = $false
    }
    [void](Update-StateSection -ProjectRoot $root -Section source -Values $src)
    $sln = $null; if (@($inventory.solutions).Count -eq 1) { $sln = $inventory.solutions[0] }
    $web = $null; if (@($version.webProjects).Count -eq 1) { $web = $version.webProjects[0] }
    [void](Update-StateSection -ProjectRoot $root -Section project -Values ([ordered]@{ solution = $sln; webProject = $web }))
    $state = Read-UpgradeState $root
    $state['gates']['discovery']['evidence'] = @(@($state['gates']['discovery']['evidence']) + $evidence + 'evidence/discovery/git-status-at-start.json' | Where-Object { $_ } | Select-Object -Unique)
    [void](Save-UpgradeState -ProjectRoot $root -State $state -Event 'discovery-evidence' -Detail ($evidence -join ','))

    $summary = [ordered]@{
        ok = $true
        projectRoot = $root
        version = [ordered]@{
            resolved = $version.resolved.version; major = $version.resolved.major; generation = $version.resolved.generation
            confidence = $version.resolved.confidence; needsConfirmation = $version.resolved.needsConfirmation
            conflicts = @($version.conflicts | ForEach-Object { [ordered]@{ kind = $_.kind; versions = @($_.versions) } })
            targetFrameworks = @($version.targetFrameworks); factStatus = 'unverified'
        }
        inventory = [ordered]@{
            solutions = @($inventory.solutions).Count; projects = @($inventory.projects).Count; packagesConfig = @($inventory.packagesConfig).Count
            centralPackageManagement = (@($inventory.centralPackageManagement).Count -gt 0); appPlugins = @($inventory.appPlugins).Count
            views = $inventory.views; configFiles = @($inventory.configFiles).Count; ciFiles = @($inventory.ciFiles).Count
            publishProfiles = @($inventory.publishProfiles).Count; looseAssemblies = @($inventory.looseAssemblies).Count; files = $inventory.fileCount
        }
        patterns = @($patterns.patterns)
        baselineSignals = @($patterns.baselineSignals | ForEach-Object { $_.pattern })
        requiresPackageMetadata = @($patterns.requiresPackageMetadata)
        unclassifiedFiles = @($patterns.unclassified.files).Count
        skippedFiles = @($patterns.skipped).Count
        database = [ordered]@{ engine = $engine; configuredTarget = $dbTarget; note = 'Connection strings are never printed. A local copy must be declared by the user before any database work.' }
        evidence = @($evidence)
        errors = @(@($version.errors) + @($inventory.errors))
    }
    Write-JsonOutput $summary
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
