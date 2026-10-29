<#
.SYNOPSIS
  Takes a snapshot of the declared local database copy before a database step. Approval tier.

.DESCRIPTION
  Refuses unless: the plan is approved and unchanged, gate 3 passed, the project is on the upgrade branch, the
  phase is in progress, the user declared a local database copy, a recorded and unused 'db-snapshot-local'
  approval exists, and the effective connection string of the project points to a local database. The
  connection string stays in memory and is never printed or recorded.
  - SQLite and SQL CE: the database file is copied to -Destination.
  - SQL Server and LocalDB: BACKUP DATABASE ... TO DISK with COPY_ONLY; the SQL Server service account must be
    able to write to -Destination.
  -Destination must be outside the project, so snapshots never reach source control. The approval is consumed on
  success. -WhatIf runs every check and reports the plan without taking a snapshot or consuming the approval.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [Parameter(Mandatory = $true)][string]$PhaseId,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$ProjectDir = '',
    [string]$Environment = 'Development',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/ConnectionInfo.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Execution.psm1') -DisableNameChecking

function Resolve-DataFile {
    # The database file of a file-based engine; |DataDirectory| is umbraco/Data (9 and later) or App_Data (7 and 8).
    param([string]$ConnectionString, [string]$ProjectDir)
    $cs = ConvertFrom-ConnectionString $ConnectionString
    $ds = $null
    foreach ($k in @('data source', 'datasource', 'filename')) { if ($cs.ContainsKey($k)) { $ds = $cs[$k]; break } }
    if (-not $ds) { throw 'The connection string has no data source file.' }
    if ($ds -match '(?i)^\|DataDirectory\|[\\/]?(.*)$') {
        $rest = $Matches[1]
        $dataDir = Join-Path $ProjectDir 'umbraco/Data'
        if (-not [System.IO.Directory]::Exists($dataDir)) { $dataDir = Join-Path $ProjectDir 'App_Data' }
        return (Resolve-FullPath (Join-Path $dataDir $rest))
    }
    if ([System.IO.Path]::IsPathRooted($ds)) { return (Resolve-FullPath $ds) }
    return (Resolve-FullPath (Join-Path $ProjectDir $ds))
}

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $state = Assert-ExecutionAllowed -ProjectRoot $root -PhaseId $PhaseId
    if (-not $state['source']['database']['localCopyDeclared']) { throw 'No local database copy is declared. Database work happens only on a restored local copy that the user declares (gate 3).' }
    $approval = Test-ApprovalAvailable -ProjectRoot $root -Action 'db-snapshot-local'
    if ($null -eq $approval) { throw "Taking a database snapshot needs a recorded, unused approval 'db-snapshot-local'. Ask the user (name the destination), then record it with state.ps1 approve." }
    $dest = Resolve-FullPath $Destination
    if (Test-PathUnder -Root $root -Path $dest) { throw 'The destination must be outside the project, so the snapshot never reaches source control.' }
    if (-not $ProjectDir) {
        $web = [string]$state['project']['webProject']
        $ProjectDir = $(if ($web) { [System.IO.Path]::GetDirectoryName((Join-Path $root $web)) } else { $root })
    } else { $ProjectDir = Resolve-FullPath (Join-Path $root $ProjectDir) }
    $eff = Get-EffectiveConnectionString -ProjectDir $ProjectDir -Environment $Environment
    if (-not $eff.connectionString) { throw "No CMS connection string found for environment '$Environment' (checked appsettings layers, user secrets, launch profile, environment, web.config)." }
    $info = Get-DataSourceInfo -ConnectionString $eff.connectionString -ProviderName $eff.providerName
    if ($info.isLocal -ne $true) { throw "The effective connection string ($($eff.source)) does not point to a local database ($($info.reason)). Snapshots are taken only of a local copy." }
    $stamp = Get-EvidenceStamp
    $plan = [ordered]@{ engine = $info.engine; source = $eff.source; environment = $eff.environment; destination = $dest; approval = $approval['id']; approvalScope = $approval['scope'] }
    if ($WhatIf) {
        Write-JsonOutput ([ordered]@{ ok = $true; whatIf = $true; plan = $plan; note = 'Checks passed. Nothing was copied and the approval was not consumed.' })
        exit 0
    }
    [void][System.IO.Directory]::CreateDirectory($dest)
    $files = @()
    switch ($info.engine) {
        { $_ -in @('sqlite', 'sqlce') } {
            $file = Resolve-DataFile -ConnectionString $eff.connectionString -ProjectDir $ProjectDir
            if (-not [System.IO.File]::Exists($file)) { throw "The database file was not found at the configured location (file name: $([System.IO.Path]::GetFileName($file)))." }
            foreach ($f in @($file, ($file + '-wal'), ($file + '-shm'))) {
                if (-not [System.IO.File]::Exists($f)) { continue }
                $target = Join-Path $dest ("$stamp-" + [System.IO.Path]::GetFileName($f))
                [System.IO.File]::Copy($f, $target, $false)
                $files += [ordered]@{ name = [System.IO.Path]::GetFileName($f); bytes = (New-Object System.IO.FileInfo($target)).Length; sha256 = (Get-FileSha256 $target) }
            }
        }
        { $_ -in @('sqlserver', 'localdb') } {
            $cs = ConvertFrom-ConnectionString $eff.connectionString
            $db = $null; foreach ($k in @('database', 'initial catalog')) { if ($cs.ContainsKey($k)) { $db = $cs[$k] } }
            if (-not $db) { throw 'The connection string names no database.' }
            $target = Join-Path $dest "$stamp-umbraco-local.bak"
            $conn = New-Object System.Data.SqlClient.SqlConnection($eff.connectionString)
            try {
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandTimeout = 3600
                $cmd.CommandText = 'BACKUP DATABASE @db TO DISK = @path WITH COPY_ONLY, INIT, CHECKSUM'
                [void]$cmd.Parameters.AddWithValue('@db', $db)
                [void]$cmd.Parameters.AddWithValue('@path', $target)
                [void]$cmd.ExecuteNonQuery()
            } finally { $conn.Dispose() }
            $bytes = $null; if ([System.IO.File]::Exists($target)) { $bytes = (New-Object System.IO.FileInfo($target)).Length }
            $files += [ordered]@{ name = 'umbraco-local.bak'; bytes = $bytes; sha256 = $null }
        }
        default { throw "Snapshots of the '$($info.engine)' engine are not supported. Take a backup with your database tools and record it as evidence." }
    }
    [void](Test-ApprovalAvailable -ProjectRoot $root -Action 'db-snapshot-local' -Consume)
    $record = [ordered]@{ at = (Get-UtcTimestamp); phase = $PhaseId; engine = $info.engine; configurationLayer = $eff.source; destination = $dest; stamp = $stamp; files = @($files); approval = $approval['id']; note = "Each file is saved as <stamp>-<name> in the destination. The connection string is never recorded." }
    $ev = Write-RedactedEvidence -ProjectRoot $root -Folder $PhaseId -Name "snapshot-$stamp.json" -Content (ConvertTo-JsonText -InputObject $record)
    Write-JsonOutput ([ordered]@{ ok = $true; engine = $info.engine; destination = $dest; stamp = $stamp; files = @($files); approval = $approval['id']; approvalConsumed = $true; evidence = $ev.path })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
