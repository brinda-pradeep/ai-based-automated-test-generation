<#
.SYNOPSIS
    Analyzes a target test repository and builds a staged AI prompt chain for test generation.

.DESCRIPTION
    Reads a normalized test case JSON, inspects the target repository for framework
    detection, test file inventory, pattern classification, and support file discovery,
    then writes a ready-to-use prompt chain markdown file.

.PARAMETER TcNumber
    The test case identifier (e.g. TC-1234). Used to locate the normalized JSON input.

.PARAMETER ProjectPath
    Path to the target automation repository to analyze.

.PARAMETER TestCasePath
    Optional explicit path to the normalized test case JSON. Overrides the default lookup.

.PARAMETER OutputPath
    Optional explicit output path for the generated prompts file.

.EXAMPLE
    .\scripts\Generate-AiPrompts.ps1 -TcNumber TC-1234 -ProjectPath "C:\repos\my-tests"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TcNumber,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectPath,

    [string]$TestCasePath,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent

function Get-TestCaseFilePath {
    param([string]$Number)
    if ($TestCasePath) { return (Resolve-Path -LiteralPath $TestCasePath).Path }

    $fileName = ($Number.ToLower() -replace '[^a-z0-9\-]', '-') + '.json'
    $defaultPath = Join-Path $RepoRoot "test-resources\sample-test-cases\$fileName"
    if (Test-Path -LiteralPath $defaultPath) { return $defaultPath }

    throw @"
Test case JSON not found at: $defaultPath

Run Get-QTestCase.ps1 or Get-AzureTestCase.ps1 -TcNumber $Number -SaveToFile, or copy an example JSON to:
  test-resources/sample-test-cases/$fileName
  (examples/sample-qtest-case.json or examples/sample-azure-test-case.json)

Use -TestCasePath to point at a specific JSON file.
"@
}

function Read-JsonFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-RelativePath {
    param([string]$Base, [string]$Full)
    $baseUri = (Resolve-Path -LiteralPath $Base).Path.TrimEnd('\') + '\'
    $fullUri = (Resolve-Path -LiteralPath $Full).Path
    return $fullUri.Substring($baseUri.Length).Replace('\', '/')
}

function Get-ProjectFiles {
    param([string]$Root)
    $exclude = @('node_modules', '.git', 'dist', 'build', 'bin', 'obj', '.venv', 'venv', '__pycache__', 'target', 'vendor')
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $parts = $_.FullName.Split([IO.Path]::DirectorySeparatorChar)
            -not ($parts | Where-Object { $exclude -contains $_ })
        }
    return $files
}

function Test-FileContentMatch {
    param([string]$Path, [string[]]$Patterns)
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        foreach ($pattern in $Patterns) {
            if ($content -match $pattern) { return $true }
        }
    }
    catch { }
    return $false
}

function Get-DetectedFramework {
    param([System.IO.FileInfo[]]$Files, [string]$Root)

    $scores = [ordered]@{
        Playwright = 0
        Cucumber   = 0
        MSTest     = 0
        NUnit      = 0
        xUnit      = 0
        Pytest     = 0
        TestCafe   = 0
        Cypress    = 0
        Generic    = 0
    }

    foreach ($file in $Files) {
        $name = $file.Name.ToLower()
        $path = $file.FullName

        if ($name -match '^playwright\.config\.(ts|js|mjs|cjs)$') { $scores.Playwright += 5 }
        if ($name -eq 'package.json') {
            if (Test-FileContentMatch $path @('@playwright/test', '"playwright"')) { $scores.Playwright += 4 }
            if (Test-FileContentMatch $path @('"cucumber"', '@cucumber/cucumber')) { $scores.Cucumber += 4 }
            if (Test-FileContentMatch $path @('"cypress"')) { $scores.Cypress += 4 }
            if (Test-FileContentMatch $path @('"testcafe"')) { $scores.TestCafe += 4 }
        }
        if ($name -match '\.feature$') { $scores.Cucumber += 3 }
        if ($name -eq 'pytest.ini' -or $name -eq 'conftest.py') { $scores.Pytest += 4 }
        if ($name -match '\.csproj$') {
            if (Test-FileContentMatch $path @('MSTest', 'Microsoft.NET.Test.Sdk')) { $scores.MSTest += 3 }
            if (Test-FileContentMatch $path @('NUnit')) { $scores.NUnit += 3 }
            if (Test-FileContentMatch $path @('xunit')) { $scores.xUnit += 3 }
        }
        if ($name -match '\.(spec|test)\.(ts|js|tsx|jsx)$') {
            if (Test-FileContentMatch $path @('@playwright/test', 'from ''playwright''')) { $scores.Playwright += 2 }
            if (Test-FileContentMatch $path @('cypress')) { $scores.Cypress += 2 }
        }
        if ($name -match '\.py$') {
            if (Test-FileContentMatch $path @('import pytest', 'from pytest', 'import unittest')) { $scores.Pytest += 2 }
        }
        if ($name -match '\.(cs)$' -and (Test-FileContentMatch $path @('\[Test\]', '\[Fact\]', '\[TestMethod\]'))) {
            if (Test-FileContentMatch $path @('NUnit')) { $scores.NUnit += 2 }
            elseif (Test-FileContentMatch $path @('Xunit')) { $scores.xUnit += 2 }
            else { $scores.MSTest += 2 }
        }
    }

    $top = ($scores.GetEnumerator() | Where-Object { $_.Key -ne 'Generic' } | Sort-Object Value -Descending | Select-Object -First 1)
    if ($top.Value -gt 0) {
        return [ordered]@{ Name = $top.Key; Score = $top.Value; AllScores = $scores }
    }

    $testDirs = @('tests', 'test', 'e2e', 'spec', 'specs', 'features')
    foreach ($dir in $testDirs) {
        if (Test-Path -LiteralPath (Join-Path $Root $dir)) { $scores.Generic += 1 }
    }

    return [ordered]@{ Name = 'Generic'; Score = $scores.Generic; AllScores = $scores }
}

function Get-TestFileInventory {
    param([System.IO.FileInfo[]]$Files, [string]$Root, [string]$Framework)

    $patterns = switch ($Framework) {
        'Playwright' { @('\.(spec|test)\.(ts|js|tsx|jsx)$') }
        'Cucumber'   { @('\.feature$', '\.steps\.(ts|js|java)$') }
        'Cypress'    { @('\.cy\.(ts|js)$', '\.spec\.(ts|js)$') }
        'Pytest'     { @('test_.*\.py$', '.*_test\.py$') }
        'MSTest'     { @('Tests?\.cs$', '.*Test\.cs$') }
        'NUnit'      { @('Tests?\.cs$', '.*Test\.cs$') }
        'xUnit'      { @('Tests?\.cs$', '.*Test\.cs$') }
        default      { @('\.(spec|test)\.', '\.feature$', 'test_.*\.py$', '.*Test\.cs$') }
    }

    $inventory = @()
    foreach ($file in $Files) {
        $matched = $false
        foreach ($pattern in $patterns) {
            if ($file.Name -match $pattern) { $matched = $true; break }
        }
        if (-not $matched) { continue }

        $content = ''
        try { $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop } catch { continue }

        $testNames = @()
        $suiteNames = @()
        $imports = @()

        switch -Regex ($content) {
            '(?m)^\s*import\s+.+$' { $imports += $Matches[0] }
        }
        $imports = ($content | Select-String -Pattern '(?m)^\s*(import\s+.+|using\s+.+;)' -AllMatches).Matches.Value |
            Select-Object -First 8

        if ($Framework -in @('Playwright', 'Cypress', 'TestCafe')) {
            $testNames = ($content | Select-String -Pattern "test\s*\(\s*['`"]([^'`"]+)" -AllMatches).Matches |
                ForEach-Object { $_.Groups[1].Value }
            $suiteNames = ($content | Select-String -Pattern "test\.describe\s*\(\s*['`"]([^'`"]+)" -AllMatches).Matches |
                ForEach-Object { $_.Groups[1].Value }
        }
        elseif ($Framework -eq 'Pytest') {
            $testNames = ($content | Select-String -Pattern 'def\s+(test_\w+)' -AllMatches).Matches |
                ForEach-Object { $_.Groups[1].Value }
            $suiteNames = ($content | Select-String -Pattern 'class\s+(\w+)' -AllMatches).Matches |
                ForEach-Object { $_.Groups[1].Value }
        }
        elseif ($Framework -in @('MSTest', 'NUnit', 'xUnit')) {
            $testNames = ($content | Select-String -Pattern '\[(Test|Fact|Theory)\][^\n]*\n\s*public\s+(?:async\s+)?(?:void|Task)\s+(\w+)' -AllMatches).Matches |
                ForEach-Object { $_.Groups[2].Value }
            $suiteNames = ($content | Select-String -Pattern 'class\s+(\w+)' -AllMatches).Matches |
                ForEach-Object { $_.Groups[1].Value }
        }
        elseif ($Framework -eq 'Cucumber') {
            $suiteNames = ($content | Select-String -Pattern 'Feature:\s*(.+)' -AllMatches).Matches |
                ForEach-Object { $_.Groups[1].Value.Trim() }
            $testNames = ($content | Select-String -Pattern 'Scenario:\s*(.+)' -AllMatches).Matches |
                ForEach-Object { $_.Groups[1].Value.Trim() }
        }

        $inventory += [ordered]@{
            path       = (Get-RelativePath -Base $Root -Full $file.FullName)
            suiteNames = @($suiteNames | Select-Object -Unique)
            testNames  = @($testNames | Select-Object -Unique)
            testCount  = @($testNames).Count
            imports    = @($imports)
            sizeKb     = [math]::Round($file.Length / 1KB, 1)
        }
    }

    return $inventory | Sort-Object { $_.testCount } -Descending
}

function Get-PatternClassification {
    param([System.IO.FileInfo[]]$Files, [string]$Root)

    $patterns = [ordered]@{
        authentication  = @('login', 'logout', 'sign[\s-]?in', 'authenticate', 'auth')
        crud            = @('create', 'read', 'update', 'delete', 'insert', 'remove')
        ui_components   = @('button', 'modal', 'dialog', 'dropdown', 'checkbox', 'component')
        navigation      = @('navigate', 'redirect', 'route', 'menu', 'sidebar', 'href')
        validation      = @('valid', 'invalid', 'required', 'error message', 'assert')
        api_integration = @('api', 'request', 'response', 'endpoint', 'fetch\(', 'axios')
        data_operations = @('database', 'sql', 'query', 'seed', 'fixture data')
        user_interaction = @('click', 'type', 'fill', 'select', 'hover', 'drag')
        search_filter   = @('search', 'filter', 'sort', 'query param')
        error_handling  = @('try', 'catch', 'exception', 'error', 'fail')
    }

    $results = @()
    $testLike = $Files | Where-Object {
        $_.Name -match '\.(spec|test|feature|cy)\.|test_.*\.py$|Test\.cs$'
    }

    foreach ($entry in $patterns.GetEnumerator()) {
        $matchedFiles = @()
        foreach ($file in $testLike) {
            try {
                $content = (Get-Content -LiteralPath $file.FullName -Raw).ToLower()
                foreach ($regex in $entry.Value) {
                    if ($content -match $regex) {
                        $matchedFiles += (Get-RelativePath -Base $Root -Full $file.FullName)
                        break
                    }
                }
            }
            catch { }
        }
        if ($matchedFiles.Count -gt 0) {
            $results += [ordered]@{
                pattern = $entry.Key
                count   = $matchedFiles.Count
                files   = @($matchedFiles | Select-Object -Unique | Select-Object -First 10)
            }
        }
    }

    return $results | Sort-Object { $_.count } -Descending
}

function Get-SupportFiles {
    param([System.IO.FileInfo[]]$Files, [string]$Root)

    $categories = [ordered]@{
        page_objects = @('page', 'pages', 'pageobject')
        components   = @('component', 'components')
        helpers      = @('helper', 'helpers', 'util', 'utils', 'utility')
        models       = @('model', 'models', 'dto', 'entity')
        fixtures     = @('fixture', 'fixtures', 'conftest', 'testdata', 'test-data')
        config       = @('config', 'settings', 'env')
    }

    $discovered = @{}
    foreach ($key in $categories.Keys) { $discovered[$key] = @() }

    foreach ($file in $Files) {
        $relative = (Get-RelativePath -Base $Root -Full $file.FullName).ToLower()
        $name = $file.Name.ToLower()

        foreach ($entry in $categories.GetEnumerator()) {
            foreach ($token in $entry.Value) {
                if ($relative -match "[/\\]$token[/\\]" -or $relative -match "[/\\]$token\." -or $name -match $token) {
                    $discovered[$entry.Key] += (Get-RelativePath -Base $Root -Full $file.FullName)
                    break
                }
            }
        }
    }

    $output = @()
    foreach ($entry in $discovered.GetEnumerator()) {
        $paths = @($entry.Value | Select-Object -Unique | Select-Object -First 20)
        if ($paths.Count -gt 0) {
            $output += [ordered]@{
                category = $entry.Key
                files    = $paths
            }
        }
    }
    return $output
}

function Get-IntegrationTarget {
    param($Inventory, $TestCase, [string]$Framework)

    $keywords = @()
    if ($TestCase.name) { $keywords += ($TestCase.name -split '\W+' | Where-Object { $_.Length -gt 3 }) }
    foreach ($step in $TestCase.steps) {
        $keywords += ($step.description -split '\W+' | Where-Object { $_.Length -gt 3 })
    }
    $keywords = $keywords | ForEach-Object { $_.ToLower() } | Select-Object -Unique

    $best = $null
    $bestScore = 0
    foreach ($item in $Inventory) {
        $haystack = (($item.suiteNames + $item.testNames + $item.path) -join ' ').ToLower()
        $score = 0
        foreach ($kw in $keywords) {
            if ($haystack -match [regex]::Escape($kw)) { $score++ }
        }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $item
        }
    }

    if (-not $best -and $Inventory.Count -gt 0) { $best = $Inventory[0] }

    if ($best) {
        return "$($best.path) (suites: $($best.suiteNames -join ', '); $($best.testCount) existing tests)"
    }

    return "No strong match - review inventory and choose or create a test file for $Framework"
}

function Format-RepositoryAnalysis {
    param(
        $Framework,
        $Inventory,
        $Patterns,
        $Support,
        [string]$IntegrationTarget,
        [string]$ProjectPath
    )

    $lines = @()
    $lines += "## Detected framework"
    $lines += "- **Primary:** $($Framework.Name) (confidence score: $($Framework.Score))"
    $lines += "- **All scores:** $(($Framework.AllScores.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    $lines += ""
    $lines += "## Project path"
    $lines += "- $ProjectPath"
    $lines += ""
    $lines += "## Recommended integration target"
    $lines += "- $IntegrationTarget"
    $lines += ""
    $lines += "## Test file inventory ($(@($Inventory).Count) files)"
    foreach ($item in ($Inventory | Select-Object -First 15)) {
        $lines += "### $($item.path)"
        $lines += "- Suites: $($item.suiteNames -join ', ')"
        $lines += "- Tests ($($item.testCount)): $($item.testNames -join ', ')"
        if ($item.imports.Count -gt 0) {
            $lines += "- Imports: $($item.imports -join ' | ')"
        }
        $lines += "- Size: $($item.sizeKb) KB"
        $lines += ""
    }
    if ($Inventory.Count -gt 15) {
        $lines += "_($($Inventory.Count - 15) additional test files omitted)_"
        $lines += ""
    }

    $lines += "## Pattern classification"
    foreach ($p in $Patterns) {
        $lines += "- **$($p.pattern)** ($($p.count) files): $($p.files -join ', ')"
    }
    $lines += ""

    $lines += "## Support files"
    foreach ($s in $Support) {
        $lines += "### $($s.category)"
        foreach ($f in $s.files) { $lines += "- $f" }
        $lines += ""
    }

    return $lines -join "`n"
}

function Get-PromptTemplate {
    param([string]$StageTitle)
    $templatePath = Join-Path $RepoRoot 'prompts\test-generation-prompts.md'
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Prompt template not found: $templatePath"
    }

    $content = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
    $escapedTitle = [regex]::Escape($StageTitle)
    $pattern = '(?s)## ' + $escapedTitle + '\s*\r?\n\r?\n\*\*Goal:\*\*[^\r\n]*\r?\n\r?\n```\r?\n(.*?)\r?\n```'
    $match = [regex]::Match($content, $pattern)
    if (-not $match.Success) {
        throw "Could not extract prompt template for stage: $StageTitle"
    }
    return $match.Groups[1].Value.Trim()
}

function Expand-Prompt {
    param(
        [string]$Template,
        [string]$TestCaseJson,
        [string]$TcNumber,
        [string]$Analysis,
        [string]$Framework,
        [string]$IntegrationTarget
    )

    $result = $Template
    $result = $result.Replace('{{TEST_CASE_JSON}}', $TestCaseJson)
    $result = $result.Replace('{{TC_NUMBER}}', $TcNumber)
    $result = $result.Replace('{{REPOSITORY_ANALYSIS}}', $Analysis)
    $result = $result.Replace('{{DETECTED_FRAMEWORK}}', $Framework)
    $result = $result.Replace('{{INTEGRATION_TARGET}}', $IntegrationTarget)
    $result = $result.Replace('{{STAGE_1_OUTPUT}}', '<paste Stage 1 assistant output here>')
    $result = $result.Replace('{{STAGE_2_OUTPUT}}', '<paste Stage 2 assistant output here>')
    $result = $result.Replace('{{STAGE_3_OUTPUT}}', '<paste Stage 3 assistant output here>')
    return $result
}

# --- Main ---

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Project path not found: $ProjectPath"
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
$testCaseFile = Get-TestCaseFilePath -Number $TcNumber
$testCase = Read-JsonFile -Path $testCaseFile
$testCaseJson = Get-Content -LiteralPath $testCaseFile -Raw -Encoding UTF8

Write-Host "Analyzing repository: $resolvedProject"
$allFiles = @(Get-ProjectFiles -Root $resolvedProject)
$framework = Get-DetectedFramework -Files $allFiles -Root $resolvedProject
$inventory = @(Get-TestFileInventory -Files $allFiles -Root $resolvedProject -Framework $framework.Name)
$patterns = @(Get-PatternClassification -Files $allFiles -Root $resolvedProject)
$support = @(Get-SupportFiles -Files $allFiles -Root $resolvedProject)
$integrationTarget = Get-IntegrationTarget -Inventory $inventory -TestCase $testCase -Framework $framework.Name
$analysis = Format-RepositoryAnalysis -Framework $framework -Inventory $inventory -Patterns $patterns -Support $support -IntegrationTarget $integrationTarget -ProjectPath $resolvedProject

$stages = @(
    @{ Title = 'Stage 1 - Analyze'; TemplateKey = 'Stage 1 - Analyze' }
    @{ Title = 'Stage 2 - Generate'; TemplateKey = 'Stage 2 - Generate' }
    @{ Title = 'Stage 3 - Integrate'; TemplateKey = 'Stage 3 - Integrate' }
    @{ Title = 'Stage 4 - Validate (Review and Run)'; TemplateKey = 'Stage 4 - Validate (Review and Run)' }
)

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# AI Prompt Chain: $TcNumber")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$sb.AppendLine("Test case source: $testCaseFile")
[void]$sb.AppendLine("Target repository: $resolvedProject")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Send each prompt below to your AI assistant **in order**, reviewing output before proceeding.")
[void]$sb.AppendLine()
[void]$sb.AppendLine('---')
[void]$sb.AppendLine()
[void]$sb.AppendLine('# Repository Analysis (reference)')
[void]$sb.AppendLine()
[void]$sb.AppendLine($analysis)
[void]$sb.AppendLine()
[void]$sb.AppendLine('---')
[void]$sb.AppendLine()

$promptIndex = 1
foreach ($stage in $stages) {
    $template = Get-PromptTemplate -StageTitle $stage.TemplateKey
    $prompt = Expand-Prompt -Template $template -TestCaseJson $testCaseJson -TcNumber $TcNumber -Analysis $analysis -Framework $framework.Name -IntegrationTarget $integrationTarget

    [void]$sb.AppendLine("## PROMPT $promptIndex - $($stage.Title)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine($prompt)
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine()
    $promptIndex++
}

$outputContent = $sb.ToString()

if ($OutputPath) {
    $targetPath = $OutputPath
}
else {
    $fileName = ($TcNumber.ToLower() -replace '[^a-z0-9\-]', '-') + '-prompts.md'
    $outputDir = Join-Path $RepoRoot 'ai-prompts'
    if (-not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $targetPath = Join-Path $outputDir $fileName
}

$parent = Split-Path $targetPath -Parent
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

Set-Content -LiteralPath $targetPath -Value $outputContent -Encoding UTF8
Write-Host "Saved prompt chain to $targetPath"
Write-Host "Detected framework: $($framework.Name)"
Write-Host "Test files inventoried: $($inventory.Count)"
