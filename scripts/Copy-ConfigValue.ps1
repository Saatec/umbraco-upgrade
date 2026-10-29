<#
.SYNOPSIS
  Copies (or moves) one configuration value between files without printing it.

.DESCRIPTION
  Sources: XML configuration (web.config, app.config) with -FromKey appSettings:<key>, connectionStrings:<name>,
  or connectionStrings:<name>:providerName; or JSON with -FromKey A:B:C. Targets: a JSON file inside the project
  (-To, key path -ToKey A:B:C) or the project's user secrets (-ToUserSecrets -Project <relative .csproj>, flat key
  -ToKey A:B:C). Writing user secrets is outside the project path and needs a recorded, unused approval
  'outside-project-path', which this script consumes. A target JSON file with comments is refused unless
  -Reformat is given (comments would be lost). -Move removes the value from the source after the copy.
  Refuses unless the plan is approved, gate 3 passed, the project is on the upgrade branch, and the phase is in
  progress. Evidence (file and key names only, never the value) goes to evidence/<phase>/. Prints JSON.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [Parameter(Mandatory = $true)][string]$PhaseId,
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$FromKey,
    [string]$To = '',
    [switch]$ToUserSecrets,
    [string]$Project = '',
    [Parameter(Mandatory = $true)][string]$ToKey,
    [switch]$Move,
    [switch]$Reformat
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Knowledge.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/ConnectionInfo.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Execution.psm1') -DisableNameChecking

function Read-XmlPreserving {
    param([string]$Path)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try { $doc.Load($reader) } finally { $reader.Close() }
    return $doc
}

function Find-XmlValueNode {
    # Returns @{ node; attribute } for appSettings:<key>, connectionStrings:<name>[:providerName].
    param($Doc, [string]$Key)
    $parts = $Key -split ':'
    if ($parts[0] -ieq 'appSettings' -and $parts.Count -eq 2) {
        foreach ($n in @($Doc.SelectNodes("//*[local-name()='appSettings']/*[local-name()='add']"))) { if ($n.GetAttribute('key') -ceq $parts[1]) { return @{ node = $n; attribute = 'value' } } }
        return $null
    }
    if ($parts[0] -ieq 'connectionStrings' -and $parts.Count -in @(2, 3)) {
        $attr = 'connectionString'; if ($parts.Count -eq 3) { if ($parts[2] -ine 'providerName') { throw "Unknown connection string part '$($parts[2])'." }; $attr = 'providerName' }
        foreach ($n in @($Doc.SelectNodes("//*[local-name()='connectionStrings']/*[local-name()='add']"))) { if ($n.GetAttribute('name') -ceq $parts[1]) { return @{ node = $n; attribute = $attr } } }
        return $null
    }
    throw "XML keys look like appSettings:<key> or connectionStrings:<name>[:providerName], not '$Key'."
}

function Get-JsonNodeValue {
    param($Tree, [string[]]$Segments)
    $node = $Tree
    foreach ($s in $Segments) {
        if (-not ($node -is [System.Collections.IDictionary])) { return @{ found = $false } }
        $k = @($node.Keys | Where-Object { $_ -ieq $s }) | Select-Object -First 1
        if ($null -eq $k) { return @{ found = $false } }
        $node = $node[$k]
    }
    return @{ found = $true; value = $node }
}

function Set-JsonNodeValue {
    param($Tree, [string[]]$Segments, $Value)
    $node = $Tree
    for ($i = 0; $i -lt $Segments.Count - 1; $i++) {
        $k = @($node.Keys | Where-Object { $_ -ieq $Segments[$i] }) | Select-Object -First 1
        if ($null -eq $k) { $node[$Segments[$i]] = [ordered]@{}; $k = $Segments[$i] }
        if (-not ($node[$k] -is [System.Collections.IDictionary])) { throw "Key '$($Segments[0..$i] -join ':')' is not an object in the target." }
        $node = $node[$k]
    }
    $last = @($node.Keys | Where-Object { $_ -ieq $Segments[-1] }) | Select-Object -First 1
    if ($null -eq $last) { $last = $Segments[-1] }
    $node[$last] = $Value
}

function Remove-JsonNode {
    param($Tree, [string[]]$Segments)
    $node = $Tree
    for ($i = 0; $i -lt $Segments.Count - 1; $i++) {
        $k = @($node.Keys | Where-Object { $_ -ieq $Segments[$i] }) | Select-Object -First 1
        if ($null -eq $k) { return }
        $node = $node[$k]
    }
    $last = @($node.Keys | Where-Object { $_ -ieq $Segments[-1] }) | Select-Object -First 1
    if ($null -ne $last) { $node.Remove($last) }
}

function Test-HasJsonComments {
    param([string]$Text)
    $stripped = Remove-JsonComments $Text
    return (([regex]::Replace($stripped, '\s+', '')) -ne ([regex]::Replace($Text, '\s+', '')))
}

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    [void](Assert-ExecutionAllowed -ProjectRoot $root -PhaseId $PhaseId)
    if ($ToUserSecrets -eq [bool]$To) { throw 'Give exactly one target: -To <json file> or -ToUserSecrets -Project <csproj>.' }
    $stateDir = Get-StateDir $root
    $srcPath = Resolve-FullPath (Join-Path $root $From)
    if (-not (Test-PathUnder -Root $root -Path $srcPath) -or (Test-PathUnder -Root $stateDir -Path $srcPath) -or -not [System.IO.File]::Exists($srcPath)) { throw "Source '$From' is not a configuration file inside the project." }
    # 1. Read the value (kept in memory only).
    $isXml = ($srcPath -match '(?i)\.config$')
    $value = $null
    if ($isXml) {
        $doc = Read-XmlPreserving $srcPath
        $hit = Find-XmlValueNode -Doc $doc -Key $FromKey
        if ($null -eq $hit -or -not $hit.node.HasAttribute($hit.attribute)) { throw "Key '$FromKey' was not found in '$From'." }
        $value = $hit.node.GetAttribute($hit.attribute)
    } else {
        $srcTree = ConvertTo-PlainObject (Read-JsonFile $srcPath)
        $got = Get-JsonNodeValue -Tree $srcTree -Segments ($FromKey -split ':')
        if (-not $got.found) { throw "Key '$FromKey' was not found in '$From'." }
        $value = $got.value
        if ($value -is [System.Collections.IDictionary] -or ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string]))) { throw 'Only single values can be copied, not objects or arrays.' }
    }
    # 2. Resolve the target.
    $targetLabel = $To
    $flat = $false
    $approvalUsed = $null
    if ($ToUserSecrets) {
        if (-not $Project) { throw '-ToUserSecrets needs -Project <relative path to the .csproj>.' }
        $projPath = Resolve-FullPath (Join-Path $root $Project)
        if (-not (Test-PathUnder -Root $root -Path $projPath) -or -not [System.IO.File]::Exists($projPath)) { throw "Project '$Project' is not a project file inside the project." }
        $secretsPath = Get-UserSecretsPath -ProjectDir ([System.IO.Path]::GetDirectoryName($projPath))
        if (-not $secretsPath) { throw "The project has no UserSecretsId. Add one first (dotnet user-secrets init), then run this again." }
        $approvalUsed = Test-ApprovalAvailable -ProjectRoot $root -Action 'outside-project-path'
        if ($null -eq $approvalUsed) { throw "Writing user secrets is outside the project path and needs a recorded, unused approval 'outside-project-path'. Ask the user, then record it with state.ps1 approve." }
        $tgtPath = $secretsPath
        $targetLabel = 'user-secrets of ' + $Project
        $flat = $true
    } else {
        $tgtPath = Resolve-FullPath (Join-Path $root $To)
        if (-not (Test-PathUnder -Root $root -Path $tgtPath) -or (Test-PathUnder -Root $stateDir -Path $tgtPath)) { throw "Target '$To' must be a file inside the project and outside .umbraco-upgrade/." }
        if ($tgtPath -notmatch '(?i)\.json$') { throw 'The target must be a JSON file.' }
    }
    # 3. Write the target.
    $tree = [ordered]@{}
    if ([System.IO.File]::Exists($tgtPath)) {
        $text = Read-TextFile $tgtPath
        if ((Test-HasJsonComments $text) -and -not $Reformat) { throw "The target has comments that a rewrite would remove. Use another file, or give -Reformat to accept that." }
        if ($text.Trim()) { $tree = ConvertTo-PlainObject (ConvertFrom-JsonText $text) }
        if (-not ($tree -is [System.Collections.IDictionary])) { throw 'The target JSON is not an object.' }
    }
    if ($flat) { $tree[$ToKey] = $value } else { Set-JsonNodeValue -Tree $tree -Segments ($ToKey -split ':') -Value $value }
    Write-TextFile -Path $tgtPath -Content (ConvertTo-StableJson $tree)
    if ($approvalUsed) { [void](Test-ApprovalAvailable -ProjectRoot $root -Action 'outside-project-path' -Consume) }
    # 4. Optionally remove it from the source.
    if ($Move) {
        if ($isXml) {
            if ($hit.attribute -eq 'providerName') { [void]$hit.node.RemoveAttribute('providerName') } else { [void]$hit.node.ParentNode.RemoveChild($hit.node) }
            $settings = New-Object System.Xml.XmlWriterSettings
            $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
            $writer = [System.Xml.XmlWriter]::Create($srcPath, $settings)
            try { $doc.Save($writer) } finally { $writer.Close() }
        } else {
            $srcText = Read-TextFile $srcPath
            if ((Test-HasJsonComments $srcText) -and -not $Reformat) { throw "The value was copied, but the source has comments that a rewrite would remove; it was not moved. Give -Reformat to accept that." }
            Remove-JsonNode -Tree $srcTree -Segments ($FromKey -split ':')
            Write-TextFile -Path $srcPath -Content (ConvertTo-StableJson $srcTree)
        }
    }
    $value = $null
    $record = [ordered]@{ at = (Get-UtcTimestamp); from = $From; fromKey = $FromKey; to = $targetLabel; toKey = $ToKey; moved = [bool]$Move; value = '[not recorded]'; approval = $(if ($approvalUsed) { $approvalUsed['id'] } else { $null }) }
    $ev = Write-RedactedEvidence -ProjectRoot $root -Folder $PhaseId -Name ("config-copy-" + (Get-EvidenceStamp) + ".json") -Content (ConvertTo-JsonText -InputObject $record)
    Write-JsonOutput ([ordered]@{ ok = $true; from = $From; fromKey = $FromKey; to = $targetLabel; toKey = $ToKey; moved = [bool]$Move; approval = $record.approval; evidence = $ev.path })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = (Protect-Text $_.Exception.Message) })
    exit 1
}
