# Repository hygiene: scripts stay ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI),
# JSON files parse, skills have the frontmatter the commands rely on.
# Label: fixture-based (checks the repository's own files).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    $script:root = Get-RepoRoot
    $script:files = Get-ChildItem -LiteralPath $script:root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
}

Describe 'Repository files' -Tag 'fixture-based' {
    It 'every PowerShell file is ASCII' {
        foreach ($f in ($script:files | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because $f.FullName
        }
    }
    It 'no file contains an em dash' {
        foreach ($f in ($script:files | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.md', '.json', '.cs', '.cshtml', '.js', '.config') })) {
            ([System.IO.File]::ReadAllText($f.FullName)).IndexOf([char]0x2014) | Should -Be -1 -Because $f.FullName
        }
    }
    It 'every JSON file parses' {
        Import-Module (Join-Path $script:root 'scripts/lib/Compat.psm1') -Force -DisableNameChecking
        foreach ($f in ($script:files | Where-Object { $_.Extension -eq '.json' -or $_.Name -eq 'package.manifest' })) {
            { ConvertFrom-JsonText ([System.IO.File]::ReadAllText($f.FullName)) } | Should -Not -Throw -Because $f.FullName
        }
    }
    It 'command skills disable model invocation and declare their arguments' {
        foreach ($name in @('start', 'plan')) {
            $text = Get-Content -Raw (Join-Path $script:root "skills/$name/SKILL.md")
            $text | Should -Match '(?m)^disable-model-invocation: true\r?$'
            $text | Should -Match '(?m)^argument-hint: <target-version> \[project-path\]\r?$'
            $text | Should -Match '(?m)^arguments: \[target, path\]\r?$'
        }
        foreach ($name in @('resume', 'verify', 'report', 'feedback')) {
            $text = Get-Content -Raw (Join-Path $script:root "skills/$name/SKILL.md")
            $text | Should -Match '(?m)^disable-model-invocation: true\r?$'
            $text | Should -Match '(?m)^argument-hint: \[project-path\]\r?$'
            $text | Should -Match '(?m)^arguments: \[path\]\r?$'
            $text | Should -Match ([regex]::Escape("Resolve-UpgradeArguments.ps1`" -Command $name -Path"))
        }
        # Windows PowerShell 5.1 drops an empty native argument, so -Path "" reaches the script without a value.
        foreach ($name in @('start', 'plan', 'resume', 'verify', 'report', 'feedback')) {
            Get-Content -Raw (Join-Path $script:root "skills/$name/SKILL.md") | Should -Match 'If no project path was given, leave out `-Path`' -Because $name
        }
    }
    It 'update-knowledge is a command that only the user can start' {
        $text = Get-Content -Raw (Join-Path $script:root 'skills/update-knowledge/SKILL.md')
        $text | Should -Match '(?m)^disable-model-invocation: true\r?$'
        $text | Should -Not -Match '(?m)^user-invocable: false\r?$'
        $text | Should -Match 'Update-Knowledge\.ps1" -DataDir "\$\{CLAUDE_PLUGIN_DATA\}"'
    }
    It 'shared skills are not user-invocable and every skill stays under 500 lines' {
        foreach ($dir in (Get-ChildItem -LiteralPath (Join-Path $script:root 'skills') -Directory)) {
            $text = Get-Content -Raw (Join-Path $dir.FullName 'SKILL.md')
            ($text -split "`n").Count | Should -BeLessThan 500
            if ($dir.Name -notin @('start', 'plan', 'resume', 'verify', 'report', 'feedback', 'update-knowledge')) { $text | Should -Match '(?m)^user-invocable: false\r?$' }
        }
    }
    It 'every script a skill or an agent references exists' {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:root 'skills') -Recurse -Filter '*.md') + @(Get-ChildItem -LiteralPath (Join-Path $script:root 'agents') -Filter '*.md')) {
            $text = Get-Content -Raw $f.FullName
            foreach ($m in [regex]::Matches($text, '\b([A-Z][A-Za-z\-]+\.ps1|state\.ps1)\b')) {
                Test-Path (Join-Path $script:root ('scripts/' + $m.Groups[1].Value)) | Should -BeTrue -Because "$($f.Name) references $($m.Groups[1].Value)"
            }
        }
    }
    It 'no root CLAUDE.md and no bin directory' {
        Test-Path (Join-Path $script:root 'CLAUDE.md') | Should -BeFalse
        Test-Path (Join-Path $script:root 'bin') | Should -BeFalse
    }
    It 'every relative link in a skill or an agent resolves' {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:root 'skills') -Recurse -Filter '*.md') + @(Get-ChildItem -LiteralPath (Join-Path $script:root 'agents') -Filter '*.md')) {
            foreach ($m in [regex]::Matches((Get-Content -Raw $f.FullName), '\]\(([^)\s#]+)(#[^)]*)?\)')) {
                $target = $m.Groups[1].Value
                if ($target -match '^[a-z]+:' -or $target.Contains('${')) { continue }
                Test-Path (Join-Path $f.DirectoryName $target) | Should -BeTrue -Because "$($f.FullName) links to $target"
            }
        }
    }
    It 'every skill and agent named as umbraco-upgrade:<name> exists' {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:root 'skills') -Recurse -Filter '*.md') + @(Get-ChildItem -LiteralPath (Join-Path $script:root 'agents') -Filter '*.md')) {
            foreach ($m in [regex]::Matches((Get-Content -Raw $f.FullName), 'umbraco-upgrade:([a-z][a-z\-]+)')) {
                $name = $m.Groups[1].Value
                ((Test-Path (Join-Path $script:root "skills/$name/SKILL.md")) -or (Test-Path (Join-Path $script:root "agents/$name.md"))) | Should -BeTrue -Because "$($f.Name) names umbraco-upgrade:$name"
            }
        }
    }
}

Describe 'Phase skills and subagents' -Tag 'fixture-based' {
    BeforeAll {
        function Get-Frontmatter([string]$Path) {
            $text = [System.IO.File]::ReadAllText($Path)
            $m = [regex]::Match($text, '\A---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
            if (-not $m.Success) { return $null }
            $h = [ordered]@{}
            foreach ($line in ($m.Groups[1].Value -split '\r?\n')) { if ($line -match '^([A-Za-z_\-]+):\s*(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() } }
            return $h
        }
        $script:Rule = 'Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.'
        $script:PhaseSkills = @('migrate-application-framework', 'migrate-content-database', 'migrate-custom-code', 'migrate-packages-backoffice', 'migrate-config-auth-integrations', 'migrate-build-tests', 'deployment-rehearsal')
    }

    It '<skill> is an internal skill that restates the no-removal rule' -ForEach @(
        @{ skill = 'migrate-application-framework' }, @{ skill = 'migrate-content-database' }, @{ skill = 'migrate-custom-code' }, @{ skill = 'migrate-packages-backoffice' },
        @{ skill = 'migrate-config-auth-integrations' }, @{ skill = 'migrate-build-tests' }, @{ skill = 'deployment-rehearsal' }
    ) {
        $path = Join-Path $script:root "skills/$skill/SKILL.md"
        $fm = Get-Frontmatter $path
        $fm | Should -Not -BeNullOrEmpty
        $fm['name'] | Should -Be $skill
        $fm['description'].Length | Should -BeGreaterThan 40
        $fm['user-invocable'] | Should -Be 'false'
        $fm.Contains('disable-model-invocation') | Should -BeFalse
        ([System.IO.File]::ReadAllText($path)).Contains($script:Rule) | Should -BeTrue -Because "$skill must restate the rule word for word"
    }

    It 'every phase area and every pattern owner has its skill' {
        Import-Module (Join-Path $script:root 'scripts/lib/Discovery.psm1') -Force -DisableNameChecking
        foreach ($p in (Get-PatternRegistry)) { Test-Path (Join-Path $script:root "skills/$($p.owner)/SKILL.md") | Should -BeTrue -Because "$($p.id) is owned by $($p.owner)" }
        $workflow = [System.IO.File]::ReadAllText((Join-Path $script:root 'skills/upgrade-workflow/references/phase-execution.md'))
        foreach ($s in $script:PhaseSkills) { $workflow | Should -Match ([regex]::Escape($s)) }
    }

    It 'the shared rules state the rule word for word' {
        foreach ($rel in @('skills/upgrade-workflow/references/migration-rules.md', 'scripts/lib/Planning.psm1')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:root $rel)) -replace '\s+', ' '
            $text.Contains('Never remove, stub, or disable custom functionality') | Should -BeTrue -Because $rel
        }
    }

    It 'subagent <agent> has the plugin frontmatter, no Agent tool, and no settings plugins ignore' -ForEach @(
        @{ agent = 'inventory-analyst' }, @{ agent = 'docs-researcher' }, @{ agent = 'independent-verifier' }
    ) {
        $fm = Get-Frontmatter (Join-Path $script:root "agents/$agent.md")
        $fm['name'] | Should -Be $agent
        $fm['description'].Length | Should -BeGreaterThan 40
        $fm['model'] | Should -Be 'inherit'
        [int]$fm['maxTurns'] | Should -BeGreaterThan 0
        $fm['omitClaudeMd'] | Should -Be 'true'
        $tools = @($fm['tools'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $tools.Count | Should -BeGreaterThan 0
        $tools | Should -Not -Contain 'Agent'
        $tools | Should -Not -Contain 'Task'
        foreach ($k in @('hooks', 'mcpServers', 'permissionMode')) { $fm.Contains($k) | Should -BeFalse -Because "plugin subagents ignore $k" }
    }

    It 'every eval case has the files and keys claude plugin eval accepts' {
        $promptKeys = @('schema_version', 'name', 'description', 'tags', 'plugins', 'runs', 'expected_outcome', 'model', 'max_turns', 'timeout_seconds', 'allowed_tools', 'append_system_prompt', 'env')
        $graderTypes = @('regex', 'tool_used', 'tool_order', 'file_exists', 'llm', 'baseline')
        $cases = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'evals') -Directory | Where-Object { $_.Name -ne 'results' })
        $cases.Count | Should -BeGreaterOrEqual 2
        foreach ($c in $cases) {
            $fm = Get-Frontmatter (Join-Path $c.FullName 'prompt.md')
            foreach ($k in $fm.Keys) { $promptKeys | Should -Contain $k -Because "$($c.Name)/prompt.md" }
            $yaml = [System.IO.File]::ReadAllText((Join-Path $c.FullName 'case.yaml'))
            $yaml | Should -Match '(?m)^schema_version: "1\.1"$'
            $yaml | Should -Match "(?m)^name: $([regex]::Escape($c.Name))$"
            if ($yaml -match '(?m)^\s+scaffold_script:\s*(\S+)$') {
                $script = Join-Path $c.FullName $Matches[1]
                Test-Path $script | Should -BeTrue
                $bytes = [System.IO.File]::ReadAllBytes($script)
                @($bytes | Where-Object { $_ -eq 13 -or $_ -gt 127 }).Count | Should -Be 0 -Because "$script must be ASCII with LF line ends"
            }
            $graders = @(Get-ChildItem -LiteralPath (Join-Path $c.FullName 'graders') -Filter '*.md')
            $graders.Count | Should -BeGreaterThan 0
            foreach ($g in $graders) {
                $gf = Get-Frontmatter $g.FullName
                $graderTypes | Should -Contain $gf['type'] -Because $g.FullName
                if ($gf['type'] -eq 'regex') { $gf.Contains('pattern') | Should -BeTrue }
                if ($gf['type'] -eq 'tool_used') { $gf.Contains('tool') | Should -BeTrue }
            }
        }
    }

    It 'the independent verifier cannot edit files' {
        $fm = Get-Frontmatter (Join-Path $script:root 'agents/independent-verifier.md')
        $tools = @($fm['tools'] -split ',' | ForEach-Object { $_.Trim() })
        foreach ($t in @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')) { $tools | Should -Not -Contain $t }
    }
}
