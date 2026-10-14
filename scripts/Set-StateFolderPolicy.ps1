<#
.SYNOPSIS
  Records and applies the user's choice for the .umbraco-upgrade/ folder: commit, exclude-local, or gitignore.

.DESCRIPTION
  - commit: recorded only; the folder is committed at the first checkpoint on the upgrade branch.
  - exclude-local: adds the folder to .git/info/exclude (an untracked, local-only file).
  - gitignore: adds the folder to the project's .gitignore. Allowed only on the upgrade branch after gate 3.
  In plan mode the choice is recorded and nothing outside .umbraco-upgrade/ is changed.
#>
[CmdletBinding()]
param([string]$ProjectRoot = '', [Parameter(Mandatory = $true)][ValidateSet('commit', 'exclude-local', 'gitignore')][string]$Policy)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Git.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -DisableNameChecking

try {
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).ProviderPath }
    $root = Resolve-FullPath $ProjectRoot.Trim().Trim('"', "'")
    $state = Read-UpgradeState $root
    $applied = 'recorded'
    if ($state['mode'] -eq 'upgrade') {
        $repo = Get-GitRepoInfo -Root $root
        $line = '/' + $repo.prefix + '.umbraco-upgrade/'
        if ($Policy -eq 'exclude-local') {
            if (-not $repo.isRepo) { throw 'Not a git repository.' }
            $gd = Invoke-GitCommand -Root $root -Arguments @('rev-parse', '--git-common-dir')
            $gitDir = $gd.stdout[0]; if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $root $gitDir }
            $exclude = Join-Path $gitDir 'info/exclude'
            $text = ''; if ([System.IO.File]::Exists($exclude)) { $text = Read-TextFile $exclude }
            if (($text -split "`r?`n") -notcontains $line) {
                if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
                Write-TextFile -Path $exclude -Content ($text + $line + "`n")
            }
            $applied = 'applied'
        } elseif ($Policy -eq 'gitignore') {
            if ($state['gates']['safety']['status'] -ne 'passed' -or $repo.branch -ne $state['gitBaseline']['upgradeBranch']) {
                throw 'gitignore can be applied only on the upgrade branch after gate 3 has passed.'
            }
            $gi = Join-Path $root '.gitignore'
            $rel = '/.umbraco-upgrade/'
            $text = ''; if ([System.IO.File]::Exists($gi)) { $text = Read-TextFile $gi }
            if (($text -split "`r?`n") -notcontains $rel) {
                if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
                Write-TextFile -Path $gi -Content ($text + $rel + "`n")
            }
            $applied = 'applied'
        }
    }
    [void](Update-StateSection -ProjectRoot $root -Section project -Values ([ordered]@{ stateFolderPolicy = $Policy }))
    Write-JsonOutput ([ordered]@{ ok = $true; policy = $Policy; result = $applied; mode = $state['mode'] })
    exit 0
} catch {
    Write-JsonOutput ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
