<#
.SYNOPSIS
  Read-only health counts of the declared local database copy, recorded as evidence.

.DESCRIPTION
  Refuses unless the project has upgrade state, the user declared a local database copy, and the effective
  connection string of the project points to a local database. The connection string stays in memory and is
  never printed or recorded.
  - SQL Server and LocalDB: the database size from sys.database_files (8-KB pages), the largest tables by
    approximate row count from sys.partitions (heap or clustered index), and the number of foreign keys that are
    disabled or not trusted (sys.foreign_keys), and the block labels written as AngularJS templates ({{ }}) in
    Block List and Block Grid data types (umbracoDataType, Umbraco 8 and later; pattern
    content.block-label-templates). Only SELECT statements run: on catalog views, and on the data type tables.
  - SQLite and SQL CE: the size of the database file; row counts need the engine's own tools.
  Writes evidence/<folder>/db-health-<stamp>.json, where -Folder is a phase id or 'discovery'. Prints JSON.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$Folder = 'discovery',
    [string]$ProjectDir = '',
    [string]$Environment = 'Development',
    [ValidateRange(1, 200)][int]$Top = 25
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/ConnectionInfo.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Execution.psm1') -DisableNameChecking

function Invoke-ReadQuery {
    param($Connection, [string]$Sql, [hashtable]$Parameters = @{})
    $cmd = $Connection.CreateCommand()
    $cmd.CommandTimeout = 120
    $cmd.CommandText = $Sql
    foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k]) }
    $reader = $cmd.ExecuteReader()
    $rows = New-Object System.Collections.ArrayList
    try {
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $v = $reader.GetValue($i)
                if ($v -is [System.DBNull]) { $v = $null }
                $row[$reader.GetName($i)] = $v
            }
            [void]$rows.Add($row)
        }
    } finally { $reader.Close() }
    return ,($rows.ToArray())
}

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    if (-not (Test-StateExists $root)) { throw 'No upgrade state in this project.' }
    $state = Read-UpgradeState $root
    if (-not $state['source']['database']['localCopyDeclared']) { throw 'No local database copy is declared. Health checks run only on a restored local copy that the user declares.' }
    Assert-EvidenceFolder -ProjectRoot $root -Folder $Folder
    if (-not $ProjectDir) {
        $web = [string]$state['project']['webProject']
        $ProjectDir = $(if ($web) { [System.IO.Path]::GetDirectoryName((Join-Path $root $web)) } else { $root })
    } else { $ProjectDir = Resolve-FullPath (Join-Path $root $ProjectDir) }
    $eff = Get-EffectiveConnectionString -ProjectDir $ProjectDir -Environment $Environment
    if (-not $eff.connectionString) { throw "No CMS connection string found for environment '$Environment' (checked appsettings layers, user secrets, launch profile, environment, web.config)." }
    $info = Get-DataSourceInfo -ConnectionString $eff.connectionString -ProviderName $eff.providerName
    if ($info.isLocal -ne $true) { throw "The effective connection string ($($eff.source)) does not point to a local database ($($info.reason)). Health checks run only on a local copy." }
    $result = [ordered]@{ at = (Get-UtcTimestamp); engine = $info.engine; configurationLayer = $eff.source; environment = $eff.environment }
    switch ($info.engine) {
        { $_ -in @('sqlserver', 'localdb') } {
            $conn = New-Object System.Data.SqlClient.SqlConnection($eff.connectionString)
            try {
                $conn.Open()
                $result.databaseName = [string](Invoke-ReadQuery $conn 'SELECT DB_NAME() AS databaseName;')[0]['databaseName']
                $result.files = @(Invoke-ReadQuery $conn 'SELECT type_desc AS fileType, CAST(SUM(CAST(size AS bigint)) / 128.0 AS decimal(18, 1)) AS sizeMb FROM sys.database_files GROUP BY type_desc ORDER BY type_desc;')
                $result.tableCount = [int](Invoke-ReadQuery $conn 'SELECT COUNT(*) AS tableCount FROM sys.tables;')[0]['tableCount']
                $result.largestTables = @(Invoke-ReadQuery $conn 'SELECT TOP (@top) s.name AS schemaName, t.name AS tableName, SUM(p.rows) AS approximateRows FROM sys.tables AS t JOIN sys.schemas AS s ON s.schema_id = t.schema_id JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1) GROUP BY s.name, t.name ORDER BY SUM(p.rows) DESC, s.name, t.name;' @{ '@top' = $Top })
                $result.foreignKeysDisabledOrNotTrusted = [int](Invoke-ReadQuery $conn 'SELECT COUNT(*) AS problems FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1;')[0]['problems']
                # Block labels written as AngularJS templates (content.block-label-templates). Only when the CMS data
                # type table with a configuration column exists (Umbraco 8 and later).
                $labelRows = @()
                if ([int](Invoke-ReadQuery $conn "SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.umbracoDataType') AND name = N'config';")[0]['n'] -gt 0) {
                    $labelRows = @(Invoke-ReadQuery $conn "SELECT dt.nodeId AS dataTypeId, n.text AS dataTypeName, dt.propertyEditorAlias AS editorAlias, dt.config AS config FROM dbo.umbracoDataType AS dt JOIN dbo.umbracoNode AS n ON n.id = dt.nodeId WHERE dt.propertyEditorAlias IN (N'Umbraco.BlockList', N'Umbraco.BlockGrid') AND dt.config LIKE N'%{{%';")
                }
                $result.blockLabelTemplates = @(Get-BlockLabelTemplates -Rows $labelRows)
            } finally { $conn.Dispose() }
        }
        { $_ -in @('sqlite', 'sqlce') } {
            $file = Resolve-DataSourceFile -ConnectionString $eff.connectionString -ProjectDir $ProjectDir
            if (-not [System.IO.File]::Exists($file)) { throw "The database file was not found at the configured location (file name: $([System.IO.Path]::GetFileName($file)))." }
            $result.file = [System.IO.Path]::GetFileName($file)
            $result.fileSizeMb = [Math]::Round((New-Object System.IO.FileInfo($file)).Length / 1MB, 1)
            $result.note = "Row counts for $($info.engine) need the engine's own tools: run them read-only on the local copy and record the output with Write-Evidence.ps1."
        }
        default { throw "Health checks for the '$($info.engine)' engine are not supported. Check it with your database tools and record the output as evidence." }
    }
    $result.privacy = 'The connection string is never recorded.'
    $stamp = Get-EvidenceStamp
    $ev = Write-RedactedEvidence -ProjectRoot $root -Folder $Folder -Name "db-health-$stamp.json" -Content (ConvertTo-JsonText -InputObject $result)
    $out = [ordered]@{ ok = $true }
    foreach ($k in $result.Keys) { $out[$k] = $result[$k] }
    $out['evidence'] = $ev.path
    Write-JsonOutput $out
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
