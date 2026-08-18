# AI-Based Automated Test Generation from Test Management Platforms

AI-powered framework that converts manual test cases into executable automation scripts integrated directly into enterprise test automation frameworks.

Works with qTest and Azure DevOps Test Plans out of the box, and with any other test management platform through CSV exports or adapter scripts.

## Problem statement

Organizations maintain thousands of manual test cases in test management systems such as qTest.  Converting these test cases into maintainable automation scripts requires significant engineering effort and often becomes a bottleneck for automation adoption.

Generic AI assistants only partially solve this.  Asked to "automate this test case", an assistant usually produces a standalone file that compiles but ignores the target repository: it re-implements page objects that already exist, invents helper methods, drops traceability to the source test case, and creates one new spec file per test case.  That output looks like automation while increasing long-term maintenance cost.

## Innovation

This project introduces an AI-assisted workflow that transforms structured test cases into executable automation scripts *inside your existing framework*.  Two things make the difference:

1. **Repository-grounded context.** Before generating anything, the toolkit detects your test framework, inventories your test files (suite names, test names, imports, detected patterns) and discovers your page objects, helpers, models and fixtures.  The AI receives that inventory, so it puts the new test in an existing suite and reuses abstractions that already exists.

2. **A staged prompt chain with human checkpoints.** The work is split into analyze, generate, integrate, and review-and-run.  Each stage produces a small reviewable artifact, so a wrong decision is caught in seconds instead of in code review.

The solution analyzes test case artifacts and generates test implementations compatible with existing automation frameworks such as Cucumber, Cypress, Playwright, TestCafe and so on.

## Repository structure

```
ai-based-automated-test-generation
├── README.md
├── architecture
│   └── architecture-diagram.png
├── scripts
│   ├── Get-QTestCase.ps1               Fetch and normalize a test case from qTest
│   ├── Get-AzureTestCase.ps1           Fetch and normalize a test case from Azure DevOps
│   └── Generate-AiPrompts.ps1          Analyze the repository and build the prompt chain
├── prompts
│   └── test-generation-prompts.md      Prompt templates and the rationale for each stage
├── examples
│   ├── sample-qtest-case.json          Normalized qTest sample (offline input)
│   └── sample-azure-test-case.json     Normalized Azure DevOps sample (offline input)
```

## Supported frameworks

Detection is automatic, based on dependencies, config files, project files and source evidence.

|Framework   |Language            |Detected via                          |
|------------|--------------------|--------------------------------------|
| Playwright | TypeScript / JavaScript | `@playwright/test`, `playwright.config.*` |
| Cucumber / Gherkin   | Java / JavaScript  | `cucumber`, `*.feature` files        |
| MSTest / NUnit / xUnit     | C#                 | `.csproj`    |
| Pytest     | Python             | `pytest.ini`, `import pytest`, `import unittest`              |
| Generic    | Any                | Fallback to directory structure and file patterns |

## Prerequisites

- PowerShell 5.1 or later (Windows PowerShell or PowerShell 7+)
- Network access to your test management platform
- An API token for that platform
- An AI coding assistant: GitHub Copilot Chat, Claude Code, or any chat assistant

## Configuration

Connection settings are read from parameters or environment variables. Nothing instance-specific is stored in the repository.

### qTest

```powershell
$env:QTEST_BASE_URL     = 'https://yourorg.qtest.com'
$env:QTEST_TOKEN        = 'Bearer <your api token>'
$env:QTEST_PROJECT_ID   = '12345'
```

Optional: map test case numbers to qTest internal IDs when search is unavailable or unreliable:

```powershell
# id-map.json format: { "TC-1234": 98765, "TC-5678": 12345 }
.\scripts\Get-QTestCase.ps1 -TcNumber TC-1234 -SaveToFile -IdMapPath .\id-map.json
```

### Azure DevOps Test Plans

```powershell
$env:AZURE_DEVOPS_ORG_URL  = 'https://dev.azure.com/yourorg'
$env:AZURE_DEVOPS_PAT       = '<personal-access-token>'
$env:AZURE_DEVOPS_PROJECT   = 'YourProject'
```

Optional: map test case numbers to Azure DevOps work item IDs, or set a custom precondition field name:

```powershell
# id-map.json format: { "TC-1234": 12345, "TC-5678": 67890 }
.\scripts\Get-AzureTestCase.ps1 -TcNumber TC-1234 -SaveToFile -IdMapPath .\id-map.json

# When preconditions are stored in a custom work item field:
$env:AZURE_DEVOPS_PRECONDITION_FIELD = 'Custom.Preconditions'
```

> **Never commit tokens.** Use environment variables, a secret manager or your CI provider's secret store.

## Quick start

```powershell
# 1. Fetch the test case and normalize it to JSON (choose your platform)
.\scripts\Get-QTestCase.ps1 -TcNumber TC-1234 -SaveToFile
# or
.\scripts\Get-AzureTestCase.ps1 -TcNumber TC-1234 -SaveToFile
#   -> test-resources/sample-test-cases/tc-1234.json

# 2. Analyze the target repository and build the prompt chain
#    (requires test-resources/sample-test-cases/tc-1234.json from step 1 or the offline copy below)
.\scripts\Generate-AiPrompts.ps1 -TcNumber TC-1234 -ProjectPath "C:\path\to\your\test-repo"
#   -> ai-prompts\tc-1234-prompts.md

# 3. Open ai-prompts\tc-1234-prompts.md and send the prompts to your AI assistant
#    in order, reviewing the output of each stage:
#       PROMPT 1 analyze        -> confirm the target file and reusable components
#       PROMPT 2 generate       -> review the test logic and assertions
#       PROMPT 3 integrate      -> review the diff
#       PROMPT 4 validate       -> the assistant runs the test and fixes failures

# 4. Run the test yourself before committing.
```

No test management access? Copy [`examples/sample-qtest-case.json`](examples/sample-qtest-case.json) or [`examples/sample-azure-test-case.json`](examples/sample-azure-test-case.json) to `test-resources/sample-test-cases/tc-1234.json` (create the folder if needed) and start at step 2. Step 2 fails if that file is missing for the given `-TcNumber`.

Alternatively, pass the JSON path directly:

```powershell
.\scripts\Generate-AiPrompts.ps1 -TcNumber TC-1234 -ProjectPath "C:\path\to\your\test-repo" `
  -TestCasePath "examples\sample-qtest-case.json"
```

## How it works

### 1. Extract

`Get-QTestCase.ps1` and `Get-AzureTestCase.ps1` resolve a test case number to the platform's internal ID (qTest search API or PID, Azure DevOps WIQL search or work item ID, or an optional id-map file), fetch the test case and its steps, strip rich-text markup, and extract precondition key/value pairs. Both scripts produce the same framework-neutral JSON document so `Generate-AiPrompts.ps1` can consume either source.

### 2. Analyze

`Generate-AiPrompts.ps1` inspects the target repository:

- **Framework detection** from dependencies, config files, project files and imports
- **Test file inventory**: suite/class names, test names, test counts, imports, file size
- **Pattern classification**: authentication, CRUD, UI components, navigation, validation, API integration, data operations, user interaction, search/filter, error handling
- **Support file discovery**: page objects, components, helpers, utilities, models, fixtures, config

### 3. Generate through a staged prompt chain

The AI generates test scripts in a staged process:

1. **Analyze**: The repository structure and test case are analyzed to determine the appropriate framework and patterns.
2. **Generate**: Prompts are created for each stage of the test case, ensuring compatibility with the existing framework.
3. **Integrate**: The generated test is integrated into the appropriate suite or file, reusing existing abstractions like page objects and helpers.
4. **Review and Run**: The generated test is presented for human review, and once approved, it can be executed within the existing framework.

### 4. Review and refine

Each stage produces a small, reviewable artifact. This ensures that any errors or misinterpretations are caught early in the process, reducing the risk of introducing unmaintainable code.

---

This workflow ensures that the generated tests are maintainable, traceable, and seamlessly integrated into the existing automation framework, reducing long-term maintenance costs and accelerating automation adoption.