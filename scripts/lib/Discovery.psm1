# Discovery.psm1 - read-only project inspection: version detection, inventory, pattern detection.
# Nothing here writes to the project. Secret values never leave this module unredacted.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Redaction.psm1') -DisableNameChecking

$script:PluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:MaxFileBytes = 2MB

function Get-PluginRoot { return $script:PluginRoot }

function Get-PatternRegistry {
    param([string]$PatternDir = (Join-Path $script:PluginRoot 'knowledge/patterns'))
    $list = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $PatternDir -Filter '*.json' | Sort-Object Name)) {
        [void]$list.Add((Read-JsonFile $f.FullName))
    }
    return ,($list.ToArray())
}

function Get-VersionSignalConfig {
    $core = $null
    foreach ($p in (Get-PatternRegistry)) { if ($p.id -eq 'pkg.core-id-changes') { $core = $p } }
    if ($null -eq $core) { throw 'Pattern registry is missing pkg.core-id-changes.' }
    return $core.versionSignals
}

function Get-RelPath { param([string]$Root, [string]$Path) return (Get-RelativePathCompat -BasePath $Root -Path $Path) }

function ConvertTo-VersionInfo {
    # Parses "13.9.0", "8.18.5-rc1", "13.*", "[13.0.0, 14.0.0)" into a comparable form.
    param([AllowEmptyString()][string]$Text)
    $r = [ordered]@{ text = $Text; exact = $false; normalized = $null; major = $null; floating = $false }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $r }
    $t = $Text.Trim()
    if ($t -match '^[\[\(]\s*([0-9][0-9A-Za-z\.\-]*)') { $r.floating = $true; $t = $Matches[1] }
    if ($t -match '\*') { $r.floating = $true }
    if ($t -match '^(\d+)(?:\.(\d+|\*))?(?:\.(\d+|\*))?(?:\.(\d+))?(?:-[0-9A-Za-z\.\-]+)?$') {
        $r.major = [int]$Matches[1]
        if (-not $r.floating) {
            $parts = @($Matches[1])
            if ($Matches[2]) { $parts += $Matches[2] } else { $parts += '0' }
            if ($Matches[3]) { $parts += $Matches[3] } else { $parts += '0' }
            $r.normalized = ($parts -join '.')
            $r.exact = $true
        }
    }
    return $r
}

function Get-GenerationForMajor {
    param([int]$Major, $Config)
    foreach ($g in $Config.generations) {
        $max = $g.maxMajor
        if ($Major -ge [int]$g.minMajor -and ($null -eq $max -or $Major -le [int]$max)) { return [string]$g.id }
    }
    return $null
}

function Find-UpwardFile {
    param([string]$StartDir, [string]$StopDir, [string]$Name)
    $dir = Resolve-FullPath $StartDir
    $stop = (Resolve-FullPath $StopDir).TrimEnd('\', '/')
    while ($dir) {
        $candidate = Join-Path $dir $Name
        if ([System.IO.File]::Exists($candidate)) { return $candidate }
        if ($dir.TrimEnd('\', '/') -ieq $stop) { break }
        $parent = [System.IO.Path]::GetDirectoryName($dir)
        if ($null -eq $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-XmlNodes {
    param($Doc, [string]$LocalName)
    return @($Doc.SelectNodes("//*[local-name()='$LocalName']"))
}

function Get-NodeValue {
    # Reads an attribute or child element value (MSBuild allows both).
    param($Node, [string]$Name)
    $a = $Node.Attributes | Where-Object { $_.LocalName -eq $Name } | Select-Object -First 1
    if ($a) { return [string]$a.Value }
    foreach ($c in $Node.ChildNodes) { if ($c.LocalName -eq $Name) { return [string]$c.InnerText } }
    return $null
}

function Get-TargetFrameworks {
    param($Doc)
    $tfms = New-Object System.Collections.Generic.List[string]
    foreach ($n in (Get-XmlNodes $Doc 'TargetFramework')) { foreach ($t in ($n.InnerText -split ';')) { if ($t.Trim()) { $tfms.Add($t.Trim()) } } }
    foreach ($n in (Get-XmlNodes $Doc 'TargetFrameworks')) { foreach ($t in ($n.InnerText -split ';')) { if ($t.Trim()) { $tfms.Add($t.Trim()) } } }
    foreach ($n in (Get-XmlNodes $Doc 'TargetFrameworkVersion')) {
        $v = $n.InnerText.Trim().TrimStart('v', 'V')
        if ($v) { $tfms.Add('net' + ($v -replace '\.', '')) }
    }
    return @($tfms | Select-Object -Unique)
}

function Get-UmbracoVersionInfo {
    param([Parameter(Mandatory)][string]$Root)
    $Root = Resolve-FullPath $Root
    $cfg = Get-VersionSignalConfig
    $coreIds = @{}
    foreach ($c in $cfg.corePackageIds) { $coreIds[$c.id.ToLowerInvariant()] = $c }
    $signals = New-Object System.Collections.ArrayList
    $hints = New-Object System.Collections.ArrayList
    $tfms = New-Object System.Collections.Generic.List[string]
    $webProjects = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $files = Get-ProjectFiles -Root $Root

    $addSignal = {
        param($kind, $file, $packageId, $versionText, $confidence, $family)
        $vi = ConvertTo-VersionInfo $versionText
        [void]$signals.Add([ordered]@{
            kind = $kind; file = (Get-RelPath $Root $file); packageId = $packageId
            version = $versionText; normalized = $vi.normalized; major = $vi.major; floating = $vi.floating
            confidence = $confidence; family = $family
        })
    }

    foreach ($f in $files) {
        $name = [System.IO.Path]::GetFileName($f)
        $rel = Get-RelPath $Root $f
        try {
            if ($name -ieq 'packages.config') {
                $doc = Read-XmlFile $f
                foreach ($p in (Get-XmlNodes $doc 'package')) {
                    $id = Get-NodeValue $p 'id'
                    if ($id -and $coreIds.ContainsKey($id.ToLowerInvariant())) {
                        & $addSignal 'packages.config' $f $id (Get-NodeValue $p 'version') 'high' 'v7-v8'
                    }
                }
            }
            elseif ($name -match '\.(cs|vb)proj$') {
                $doc = Read-XmlFile $f
                $projectDir = [System.IO.Path]::GetDirectoryName($f)
                foreach ($t in (Get-TargetFrameworks $doc)) { $tfms.Add($t) }
                $sdk = $doc.DocumentElement.GetAttribute('Sdk')
                $usesCore = $false
                foreach ($pr in (Get-XmlNodes $doc 'PackageReference')) {
                    $id = Get-NodeValue $pr 'Include'
                    if (-not $id) { $id = Get-NodeValue $pr 'Update' }
                    if (-not $id -or -not $coreIds.ContainsKey($id.ToLowerInvariant())) { continue }
                    $usesCore = $true
                    $ver = Get-NodeValue $pr 'VersionOverride'
                    if (-not $ver) { $ver = Get-NodeValue $pr 'Version' }
                    if ($ver) {
                        $conf = 'high'; if ((ConvertTo-VersionInfo $ver).floating) { $conf = 'medium' }
                        & $addSignal 'PackageReference' $f $id $ver $conf 'aspnetcore'
                    } else {
                        $props = Find-UpwardFile -StartDir $projectDir -StopDir $Root -Name 'Directory.Packages.props'
                        if ($props) {
                            $pdoc = Read-XmlFile $props
                            foreach ($pv in (Get-XmlNodes $pdoc 'PackageVersion')) {
                                if ((Get-NodeValue $pv 'Include') -ieq $id) {
                                    $v = Get-NodeValue $pv 'Version'
                                    $conf = 'high'; if ((ConvertTo-VersionInfo $v).floating) { $conf = 'medium' }
                                    & $addSignal 'CentralPackageVersion' $props $id $v $conf 'aspnetcore'
                                }
                            }
                        } else {
                            [void]$hints.Add([ordered]@{ kind = 'PackageReference-without-version'; file = $rel; hint = 'aspnetcore' })
                        }
                    }
                }
                # Old-style project files reference the core assembly through a HintPath into packages/.
                foreach ($ref in (Get-XmlNodes $doc 'Reference')) {
                    $hint = Get-NodeValue $ref 'HintPath'
                    if ($hint -and $hint -match '(?i)packages[\\/](UmbracoCms(?:\.Core)?)\.(\d+\.\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z\.\-]+)?)[\\/]') {
                        & $addSignal 'HintPath' $f $Matches[1] $Matches[2] 'medium' 'v7-v8'
                        $usesCore = $true
                    }
                }
                if ($usesCore -and $sdk -match 'Microsoft\.NET\.Sdk\.Web') { [void]$webProjects.Add($rel) }
                # Resolved versions from lock and assets files next to the project.
                $lock = Join-Path $projectDir 'packages.lock.json'
                if ([System.IO.File]::Exists($lock)) {
                    $lj = Read-JsonFile $lock
                    if ($lj -and $lj.PSObject.Properties['dependencies']) {
                        foreach ($tfmProp in $lj.dependencies.PSObject.Properties) {
                            foreach ($dep in $tfmProp.Value.PSObject.Properties) {
                                if ($coreIds.ContainsKey($dep.Name.ToLowerInvariant()) -and $coreIds[$dep.Name.ToLowerInvariant()].primary) {
                                    & $addSignal 'packages.lock.json' $lock $dep.Name ([string]$dep.Value.resolved) 'high' 'aspnetcore'
                                }
                            }
                        }
                    }
                }
                $assets = Join-Path $projectDir 'obj/project.assets.json'
                if ([System.IO.File]::Exists($assets)) {
                    $aj = Read-JsonFile $assets
                    if ($aj -and $aj.PSObject.Properties['libraries']) {
                        foreach ($lib in $aj.libraries.PSObject.Properties) {
                            $parts = $lib.Name -split '/'
                            if ($parts.Count -eq 2 -and $coreIds.ContainsKey($parts[0].ToLowerInvariant()) -and $coreIds[$parts[0].ToLowerInvariant()].primary) {
                                & $addSignal 'project.assets.json' $assets $parts[0] $parts[1] 'high' 'aspnetcore'
                            }
                        }
                    }
                }
                foreach ($asm in $cfg.coreAssemblies) {
                    $dll = Join-Path $projectDir (Join-Path 'bin' $asm)
                    if ([System.IO.File]::Exists($dll)) {
                        $fv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll)
                        if ($fv.ProductVersion) { & $addSignal 'assembly' $dll $asm (($fv.ProductVersion -split '\+')[0]) 'medium' 'any' }
                    }
                }
            }
            elseif ($name -ieq 'web.config' -and $rel -notmatch '(?i)(^|/)views/') {
                $doc = Read-XmlFile $f
                foreach ($add in (Get-XmlNodes $doc 'add')) {
                    $key = Get-NodeValue $add 'key'
                    if (-not $key) { continue }
                    foreach ($sk in $cfg.configStatusKeys) {
                        if ($key -ieq $sk.key) {
                            $val = Get-NodeValue $add 'value'
                            if ($val) { & $addSignal 'config-status' $f $sk.key $val 'medium' ($sk.generations -join ',') }
                            else { [void]$hints.Add([ordered]@{ kind = 'config-status-empty'; file = $rel; hint = ($sk.generations -join ',') }) }
                        }
                    }
                }
                foreach ($n in (@(Get-XmlNodes $doc 'httpRuntime') + @(Get-XmlNodes $doc 'compilation'))) {
                    $tf = Get-NodeValue $n 'targetFramework'
                    if ($tf) { $tfms.Add('net' + ($tf -replace '\.', '')) }
                }
                $webDir = [System.IO.Path]::GetDirectoryName($f)
                foreach ($asm in $cfg.coreAssemblies) {
                    $dll = Join-Path $webDir (Join-Path 'bin' $asm)
                    if ([System.IO.File]::Exists($dll)) {
                        $fv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll)
                        if ($fv.ProductVersion) { & $addSignal 'assembly' $dll $asm (($fv.ProductVersion -split '\+')[0]) 'medium' 'any' }
                    }
                }
            }
            elseif ($name -match '^(?i)appsettings(\.[\w\-]+)?\.json$') {
                $j = Read-JsonFile $f
                $node = $j
                $ok = $true
                foreach ($seg in $cfg.appSettingsSection) {
                    if ($null -ne $node -and $node.PSObject.Properties[$seg]) { $node = $node.$seg } else { $ok = $false; break }
                }
                if ($ok) { [void]$hints.Add([ordered]@{ kind = 'appsettings-section'; file = $rel; hint = 'aspnetcore' }) }
            }
            foreach ($lc in $cfg.legacyConfigFiles) {
                if (Test-GlobMatch -RelativePath $rel -Globs @('**/' + $lc)) {
                    [void]$hints.Add([ordered]@{ kind = 'legacy-config-file'; file = $rel; hint = 'v7-v8' })
                }
            }
            foreach ($bm in $cfg.backofficeManifests) {
                if (Test-GlobMatch -RelativePath $rel -Globs @($bm.glob)) {
                    [void]$hints.Add([ordered]@{ kind = 'backoffice-manifest'; file = $rel; hint = $bm.hint })
                }
            }
        } catch {
            [void]$errors.Add([ordered]@{ file = $rel; error = (Protect-Text $_.Exception.Message) })
        }
    }

    # Resolution: highest confidence tier wins; disagreement inside it is a conflict.
    $versioned = @($signals | Where-Object { $null -ne $_.major })
    $exact = @($versioned | Where-Object { $_.normalized })
    $tier = @($exact | Where-Object { $_.confidence -eq 'high' })
    $tierName = 'high'
    if ($tier.Count -eq 0) { $tier = @($exact | Where-Object { $_.confidence -eq 'medium' }); $tierName = 'medium' }
    $conflicts = New-Object System.Collections.ArrayList
    $resolved = [ordered]@{ version = $null; major = $null; generation = $null; confidence = 'none'; needsConfirmation = $false; candidates = @() }
    if ($tier.Count -gt 0) {
        $distinct = @($tier | ForEach-Object { $_.normalized } | Sort-Object -Unique)
        $resolved.candidates = $distinct
        if ($distinct.Count -eq 1) {
            $resolved.version = $distinct[0]
            $resolved.major = [int](($distinct[0] -split '\.')[0])
            $resolved.confidence = $tierName
        } else {
            $resolved.confidence = 'conflict'
            [void]$conflicts.Add([ordered]@{ kind = 'package-versions-disagree'; versions = $distinct; signals = @($tier | ForEach-Object { [ordered]@{ kind = $_.kind; file = $_.file; packageId = $_.packageId; version = $_.version } }) })
        }
        # Lower-tier signals that disagree with the resolved version (for example a config status that lags the packages).
        if ($resolved.version) {
            foreach ($s in $exact) {
                if ($s.confidence -ne $tierName -and $s.normalized -ne $resolved.version) {
                    [void]$conflicts.Add([ordered]@{ kind = ('{0}-differs' -f $s.kind); versions = @($resolved.version, $s.normalized); signals = @([ordered]@{ kind = $s.kind; file = $s.file; packageId = $s.packageId; version = $s.version }) })
                }
            }
        }
    } elseif ($versioned.Count -gt 0) {
        $majors = @($versioned | ForEach-Object { $_.major } | Sort-Object -Unique)
        if ($majors.Count -eq 1) { $resolved.major = [int]$majors[0]; $resolved.confidence = 'low' }
        else { $resolved.confidence = 'conflict'; [void]$conflicts.Add([ordered]@{ kind = 'floating-majors-disagree'; versions = $majors; signals = @() }) }
    }
    if ($null -ne $resolved.major) { $resolved.generation = Get-GenerationForMajor -Major $resolved.major -Config $cfg }
    elseif ($hints.Count -gt 0) {
        $h = @($hints | ForEach-Object { $_.hint } | Sort-Object -Unique)
        $resolved.generation = ($h -join '|')
    }
    $resolved.needsConfirmation = ($conflicts.Count -gt 0 -or $resolved.confidence -in @('none', 'low', 'conflict'))

    $isUmbraco = ($signals.Count -gt 0) -or [bool](@($hints | Where-Object { $_.kind -in @('legacy-config-file', 'appsettings-section', 'config-status-empty', 'PackageReference-without-version') }).Count)

    return [ordered]@{
        root = $Root
        isUmbraco = $isUmbraco
        resolved = $resolved
        conflicts = @($conflicts)
        signals = @($signals)
        hints = @($hints)
        targetFrameworks = @($tfms | Select-Object -Unique)
        webProjects = @($webProjects)
        errors = @($errors)
        factStatus = 'unverified'
    }
}

function Test-PluginFolderMatchesPackage {
    # True when an App_Plugins folder name matches a referenced package ID (ignoring dots, dashes, underscores).
    param([string]$Name, $PackageIds)
    $normName = ($Name -replace '[\.\-_]', '')
    foreach ($id in $PackageIds) {
        if ($normName -ieq ($id -replace '[\.\-_]', '') -or $id -ilike ('*' + $Name + '*')) { return $true }
    }
    return $false
}

function Get-PackageReferenceIds {
    # Package IDs referenced by project files, packages.config, and central package management files.
    param([Parameter(Mandatory)][string]$Root, [string[]]$Files)
    $ids = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $Files) {
        $name = [System.IO.Path]::GetFileName($f)
        try {
            if ($name -match '\.(cs|vb)proj$' -or $name -ieq 'Directory.Packages.props' -or $name -ieq 'Directory.Build.props') {
                $doc = Read-XmlFile $f
                foreach ($tag in @('PackageReference', 'PackageVersion')) {
                    foreach ($n in (Get-XmlNodes $doc $tag)) { $id = Get-NodeValue $n 'Include'; if ($id) { [void]$ids.Add($id) } }
                }
            } elseif ($name -ieq 'packages.config') {
                $doc = Read-XmlFile $f
                foreach ($n in (Get-XmlNodes $doc 'package')) { $id = Get-NodeValue $n 'id'; if ($id) { [void]$ids.Add($id) } }
            }
        } catch { continue }
    }
    return ,$ids
}

function Get-ProjectInventoryInfo {
    param([Parameter(Mandatory)][string]$Root)
    $Root = Resolve-FullPath $Root
    $files = Get-ProjectFiles -Root $Root
    $inv = [ordered]@{
        root = $Root; solutions = @(); projects = @(); packagesConfig = @(); centralPackageManagement = @()
        looseAssemblies = @(); appPlugins = @(); views = 0; configFiles = @(); ciFiles = @(); publishProfiles = @()
        iisFiles = @(); submodules = $false; fileCount = $files.Length; errors = @()
    }
    $solutions = New-Object System.Collections.ArrayList; $projects = New-Object System.Collections.ArrayList
    $pc = New-Object System.Collections.ArrayList; $cpm = New-Object System.Collections.ArrayList
    $dlls = New-Object System.Collections.ArrayList; $configs = New-Object System.Collections.ArrayList
    $ci = New-Object System.Collections.ArrayList; $pub = New-Object System.Collections.ArrayList
    $iis = New-Object System.Collections.ArrayList; $errs = New-Object System.Collections.ArrayList
    $pluginDirs = @{}
    $packageIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $views = 0
    foreach ($f in $files) {
        $rel = Get-RelPath $Root $f
        $name = [System.IO.Path]::GetFileName($f)
        try {
            if ($name -match '\.slnx?$') { [void]$solutions.Add($rel) }
            elseif ($name -match '\.(cs|vb)proj$') {
                $doc = Read-XmlFile $f
                $refs = @(); $hintRefs = @(); $projRefs = @()
                foreach ($pr in (Get-XmlNodes $doc 'PackageReference')) {
                    $id = Get-NodeValue $pr 'Include'; if (-not $id) { continue }
                    [void]$packageIds.Add($id)
                    $refs += [ordered]@{ id = $id; version = (Get-NodeValue $pr 'Version') }
                }
                foreach ($r in (Get-XmlNodes $doc 'Reference')) {
                    $h = Get-NodeValue $r 'HintPath'
                    if ($h) { $hintRefs += [ordered]@{ include = (Get-NodeValue $r 'Include'); hintPath = ($h -replace '\\', '/') } }
                }
                foreach ($r in (Get-XmlNodes $doc 'ProjectReference')) { $projRefs += ((Get-NodeValue $r 'Include') -replace '\\', '/') }
                $sdk = $doc.DocumentElement.GetAttribute('Sdk')
                [void]$projects.Add([ordered]@{
                    path = $rel; sdkStyle = [bool]$sdk; sdk = $sdk; targetFrameworks = @(Get-TargetFrameworks $doc)
                    packageReferences = @($refs); hintPathReferences = @($hintRefs); projectReferences = @($projRefs)
                })
            }
            elseif ($name -ieq 'packages.config') {
                [void]$pc.Add($rel)
                $doc = Read-XmlFile $f
                foreach ($p in (Get-XmlNodes $doc 'package')) { $id = Get-NodeValue $p 'id'; if ($id) { [void]$packageIds.Add($id) } }
            }
            elseif ($name -ieq 'Directory.Packages.props') { [void]$cpm.Add($rel) }
            elseif ($name -match '\.dll$') { [void]$dlls.Add($rel) }
            elseif ($name -match '\.cshtml$') { $views++ }
            if ($name -match '(?i)^(web|app)\.config$|\.config$|^appsettings.*\.json$|^launchSettings\.json$') { [void]$configs.Add($rel) }
            if ($rel -match '(?i)^\.github/workflows/.+\.ya?ml$|(^|/)azure-pipelines.*\.ya?ml$|(^|/)\.gitlab-ci\.yml$|(^|/)Jenkinsfile$|(^|/)bitbucket-pipelines\.yml$|(^|/)appveyor\.yml$') { [void]$ci.Add($rel) }
            if ($rel -match '(?i)\.pubxml$|\.publishsettings$') { [void]$pub.Add($rel) }
            if ($name -ieq 'web.config' -and (Read-TextFile $f) -match '(?i)<system\.webServer>') { [void]$iis.Add($rel) }
            if ($rel -match '(?i)(^|/)App_Plugins/([^/]+)/') {
                $dirKey = $rel.Substring(0, $rel.IndexOf('App_Plugins/', [System.StringComparison]::OrdinalIgnoreCase) + 12) + $Matches[2]
                if (-not $pluginDirs.ContainsKey($dirKey)) { $pluginDirs[$dirKey] = [ordered]@{ path = $dirKey; name = $Matches[2]; packageManifest = $false; umbracoPackageJson = $false; files = 0 } }
                $pluginDirs[$dirKey].files++
                if ($name -ieq 'package.manifest') { $pluginDirs[$dirKey].packageManifest = $true }
                if ($name -ieq 'umbraco-package.json') { $pluginDirs[$dirKey].umbracoPackageJson = $true }
            }
        } catch {
            [void]$errs.Add([ordered]@{ file = $rel; error = (Protect-Text $_.Exception.Message) })
        }
    }
    $plugins = foreach ($k in ($pluginDirs.Keys | Sort-Object)) {
        $p = $pluginDirs[$k]
        $p['matchesPackageReference'] = (Test-PluginFolderMatchesPackage -Name $p.name -PackageIds $packageIds)
        $p
    }
    $inv.solutions = @($solutions); $inv.projects = @($projects); $inv.packagesConfig = @($pc)
    $inv.centralPackageManagement = @($cpm); $inv.looseAssemblies = @($dlls); $inv.appPlugins = @($plugins)
    $inv.views = $views; $inv.configFiles = @($configs); $inv.ciFiles = @($ci); $inv.publishProfiles = @($pub)
    $inv.iisFiles = @($iis); $inv.submodules = [System.IO.File]::Exists((Join-Path $Root '.gitmodules'))
    $inv.errors = @($errs)
    return $inv
}

function New-GlobRegex {
    # One compiled, case-insensitive regex for a list of globs.
    param([string[]]$Globs)
    $parts = @($Globs | Where-Object { $_ } | ForEach-Object { '(?:' + (ConvertTo-GlobRegex $_) + ')' })
    if ($parts.Count -eq 0) { return $null }
    return New-Object System.Text.RegularExpressions.Regex(($parts -join '|'), ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
}

function Get-PluginFolderName {
    # Returns the App_Plugins/<name> folder name of a relative path, or $null.
    param([string]$RelativePath)
    if ($RelativePath -match '(?i)(?:^|/)App_Plugins/([^/]+)/') { return $Matches[1] }
    return $null
}

function Get-PatternKind {
    param($Pattern)
    if ($Pattern.PSObject.Properties['kind'] -and $Pattern.kind) { return [string]$Pattern.kind }
    return 'customization'
}

function Find-PatternHits {
    # Runs the detector registry. Customization patterns go to "patterns"; patterns of kind "baseline" (present in
    # default installations of some generation) go to "baselineSignals" and never count as customizations.
    # Detector forms: a regex over files matching globs; file presence (no regex); and derived detectors
    # (app-plugin-orphan, implicit-namespace). Patterns that need package metadata are listed for the planning step.
    param([Parameter(Mandatory)][string]$Root, $Registry = (Get-PatternRegistry))
    $Root = Resolve-FullPath $Root
    $files = Get-ProjectFiles -Root $Root
    $rels = @{}
    foreach ($f in $files) { $rels[$f] = (Get-RelPath $Root $f) }
    $opts = [System.Text.RegularExpressions.RegexOptions]::Multiline
    $packageIds = Get-PackageReferenceIds -Root $Root -Files $files
    $kinds = @{}
    $detectors = New-Object System.Collections.ArrayList
    $derived = New-Object System.Collections.ArrayList
    $metadataPatterns = New-Object System.Collections.ArrayList
    $catchAll = $null
    foreach ($p in $Registry) {
        $kinds[$p.id] = Get-PatternKind $p
        foreach ($d in @($p.detectors)) {
            if ($null -eq $d) { continue }
            if ($d.PSObject.Properties['derived'] -and $d.derived) {
                if ($d.derived -eq 'package-metadata') { [void]$metadataPatterns.Add($p.id) }
                else { [void]$derived.Add([ordered]@{ pattern = $p.id; def = $d }) }
                continue
            }
            $rx = $null
            if ($d.PSObject.Properties['regex'] -and $d.regex) { $rx = New-Object System.Text.RegularExpressions.Regex($d.regex, $opts) }
            $scope = $null; if ($d.PSObject.Properties['pluginScope']) { $scope = [string]$d.pluginScope }
            $excl = $null; if ($d.PSObject.Properties['excludeFiles']) { $excl = New-GlobRegex @($d.excludeFiles) }
            [void]$detectors.Add([ordered]@{ pattern = $p.id; id = $d.id; weight = $d.weight; glob = (New-GlobRegex @($d.files)); exclude = $excl; regex = $rx; pluginScope = $scope })
        }
        if ($p.PSObject.Properties['catchAll'] -and $p.catchAll) {
            $catchAll = [ordered]@{ pattern = $p.id; glob = (New-GlobRegex @($p.catchAll.files)); regex = New-Object System.Text.RegularExpressions.Regex($p.catchAll.regex, $opts) }
        }
    }
    $pluginMatch = @{}
    $hits = New-Object System.Collections.ArrayList
    $catchCandidates = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $rel = $rels[$f]
        $content = $null
        $len = (New-Object System.IO.FileInfo($f)).Length
        if ($len -gt $script:MaxFileBytes) { continue }
        $plugin = Get-PluginFolderName $rel
        if ($plugin -and -not $pluginMatch.ContainsKey($plugin)) { $pluginMatch[$plugin] = (Test-PluginFolderMatchesPackage -Name $plugin -PackageIds $packageIds) }
        foreach ($d in $detectors) {
            if (-not $d.glob -or -not $d.glob.IsMatch($rel)) { continue }
            if ($d.exclude -and $d.exclude.IsMatch($rel)) { continue }
            if ($d.pluginScope) {
                if (-not $plugin) { continue }
                if ($d.pluginScope -eq 'unmatched' -and $pluginMatch[$plugin]) { continue }
                if ($d.pluginScope -eq 'matched' -and -not $pluginMatch[$plugin]) { continue }
            }
            if ($null -eq $d.regex) {
                [void]$hits.Add([ordered]@{ pattern = $d.pattern; detector = $d.id; weight = $d.weight; file = $rel; line = 1; count = 1; snippet = (Protect-Text $rel) })
                continue
            }
            if ($null -eq $content) { $content = Read-TextFile $f }
            $ms = $d.regex.Matches($content)
            if ($ms.Count -eq 0) { continue }
            $first = $ms[0]
            $line = ($content.Substring(0, $first.Index) -split "`n").Length
            $lineText = ($content -split "`n")[$line - 1].Trim()
            if ($lineText.Length -gt 200) { $lineText = $lineText.Substring(0, 200) }
            [void]$hits.Add([ordered]@{ pattern = $d.pattern; detector = $d.id; weight = $d.weight; file = $rel; line = $line; count = $ms.Count; snippet = (Protect-Text $lineText) })
        }
        if ($catchAll -and $catchAll.glob -and $catchAll.glob.IsMatch($rel)) {
            if ($null -eq $content) { $content = Read-TextFile $f }
            if ($catchAll.regex.IsMatch($content)) { [void]$catchCandidates.Add($rel) }
        }
    }
    foreach ($dd in $derived) {
        $derivedHits = Find-DerivedHits -Root $Root -Files $files -Rels $rels -Definition $dd.def -PackageIds $packageIds -PluginMatch $pluginMatch
        foreach ($h in $derivedHits) {
            $h['pattern'] = $dd.pattern
            [void]$hits.Add($h)
        }
    }
    $fired = @{}
    foreach ($h in $hits) { if ($h.weight -eq 'strong') { $fired[$h.pattern] = $true } }
    $kept = @($hits | Where-Object { $fired.ContainsKey($_.pattern) -and $kinds[$_.pattern] -ne 'baseline' })
    $keptBaseline = @($hits | Where-Object { $fired.ContainsKey($_.pattern) -and $kinds[$_.pattern] -eq 'baseline' })
    $classifiedFiles = @{}
    foreach ($h in @($kept + $keptBaseline)) { $classifiedFiles[$h.file] = $true }
    $unclassified = @($catchCandidates | Where-Object { -not $classifiedFiles.ContainsKey($_) })
    return [ordered]@{
        root = $Root
        registry = @($Registry | ForEach-Object { $_.id })
        patterns = @(Get-PatternSummary -Registry $Registry -Hits $kept)
        baselineSignals = @(Get-PatternSummary -Registry $Registry -Hits $keptBaseline)
        hits = @($kept)
        baselineHits = @($keptBaseline)
        requiresPackageMetadata = @($metadataPatterns)
        unclassified = [ordered]@{ pattern = $(if ($catchAll) { $catchAll.pattern } else { $null }); files = $unclassified }
    }
}

function Get-PatternSummary {
    param($Registry, $Hits)
    $ids = @($Hits | ForEach-Object { $_.pattern } | Sort-Object -Unique)
    foreach ($patId in $ids) {
        $ph = @($Hits | Where-Object { $_.pattern -eq $patId })
        $p = $Registry | Where-Object { $_.id -eq $patId } | Select-Object -First 1
        # Sum the 'count' key explicitly: Measure-Object -Property count would read the dictionary's own Count.
        $occ = 0; foreach ($h in $ph) { $occ += [int]$h['count'] }
        [ordered]@{
            pattern = $patId; title = $p.title; area = $p.area; owner = $p.owner; status = $p.status
            files = @($ph | ForEach-Object { $_.file } | Sort-Object -Unique).Count
            occurrences = $occ
        }
    }
}

function Find-DerivedHits {
    # Detectors that need more than one file: plugin folders without a package or a manifest, and namespaces used
    # in SDK-style projects that no direct package reference provides.
    param([string]$Root, [string[]]$Files, $Rels, $Definition, $PackageIds, $PluginMatch)
    $out = New-Object System.Collections.ArrayList
    switch ([string]$Definition.derived) {
        'app-plugin-orphan' {
            # An App_Plugins folder that matches no package reference and has no manifest of either generation.
            $folders = @{}
            foreach ($f in $Files) {
                $rel = $Rels[$f]; $name = Get-PluginFolderName $rel
                if (-not $name) { continue }
                if (-not $folders.ContainsKey($name)) { $folders[$name] = [ordered]@{ first = $rel; manifest = $false } }
                $leaf = [System.IO.Path]::GetFileName($rel)
                if ($leaf -ieq 'package.manifest' -or $leaf -ieq 'umbraco-package.json') { $folders[$name].manifest = $true }
            }
            foreach ($name in ($folders.Keys | Sort-Object)) {
                if ($PluginMatch.ContainsKey($name) -and $PluginMatch[$name]) { continue }
                if ($folders[$name].manifest) { continue }
                [void]$out.Add([ordered]@{ pattern = $null; detector = $Definition.id; weight = $Definition.weight; file = $folders[$name].first; line = 1; count = 1; snippet = (Protect-Text ("App_Plugins/" + $name)) })
            }
        }
        'implicit-namespace' {
            # Only SDK-style projects: packages.config lists every package, transitive ones included.
            $projects = @($Files | Where-Object { $_ -match '\.csproj$' })
            $projDirs = @{}
            foreach ($pf in $projects) {
                try { $doc = Read-XmlFile $pf } catch { continue }
                if (-not $doc.DocumentElement.GetAttribute('Sdk')) { continue }
                $refs = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($n in (Get-XmlNodes $doc 'PackageReference')) { $id = Get-NodeValue $n 'Include'; if ($id) { [void]$refs.Add($id) } }
                $projDirs[[System.IO.Path]::GetDirectoryName($pf)] = $refs
            }
            foreach ($f in ($Files | Where-Object { $_ -match '\.cs$' })) {
                $dir = [System.IO.Path]::GetDirectoryName($f); $refs = $null
                while ($dir) { if ($projDirs.ContainsKey($dir)) { $refs = $projDirs[$dir]; break }; $parent = [System.IO.Path]::GetDirectoryName($dir); if ($parent -eq $dir) { break }; $dir = $parent }
                if ($null -eq $refs) { continue }
                $content = Read-TextFile $f
                foreach ($ns in @($Definition.namespaces)) {
                    $m = [regex]::Match($content, '(?m)^\s*(?:global\s+)?using\s+(?:static\s+)?' + [regex]::Escape([string]$ns.namespace) + '(?:\.[\w\.]+)?\s*;')
                    if (-not $m.Success) { continue }
                    $provided = $false
                    foreach ($pkg in @($ns.packages)) { if ($refs.Contains([string]$pkg)) { $provided = $true; break } }
                    if ($provided) { continue }
                    $line = ($content.Substring(0, $m.Index) -split "`n").Length
                    [void]$out.Add([ordered]@{ pattern = $null; detector = $Definition.id; weight = $Definition.weight; file = $Rels[$f]; line = $line; count = 1; snippet = (Protect-Text $m.Value.Trim()) })
                }
            }
        }
        default { throw "Unknown derived detector '$($Definition.derived)'." }
    }
    return ,($out.ToArray())
}

Export-ModuleMember -Function Get-PluginRoot, Get-PatternRegistry, Get-VersionSignalConfig, ConvertTo-VersionInfo, Get-GenerationForMajor, Get-UmbracoVersionInfo, Get-ProjectInventoryInfo, Find-PatternHits, Get-PackageReferenceIds, Test-PluginFolderMatchesPackage
