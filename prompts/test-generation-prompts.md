# Test Generation Prompt Templates

This document defines the staged prompt chain used to convert normalized test cases into executable automation integrated with an existing repository. Each stage produces a small, reviewable artifact before moving to the next.

## Design rationale

| Stage | Purpose | Human checkpoint |
|-------|---------|------------------|
| **1. Analyze** | Ground the AI in the target repo: framework, suite placement, reusable abstractions | Confirm target file and components before any code is written |
| **2. Generate** | Produce test logic that maps 1:1 to manual steps | Review assertions and data setup against the source test case |
| **3. Integrate** | Place the test in an existing suite/file and wire imports | Review the diff - no duplicate page objects or helpers |
| **4. Validate** | Run the test and fix failures | Approve execution results before commit |

Splitting the work this way prevents the common failure mode where an AI generates a standalone spec that compiles but ignores repository conventions.

---

## Stage 1 - Analyze

**Goal:** Determine where the test belongs and which existing abstractions to reuse.

```
You are automating a manual test case inside an EXISTING test repository.
Do NOT create new page objects, helpers, or utility classes unless explicitly confirmed missing.

## Test case (source of truth)
{{TEST_CASE_JSON}}

## Repository analysis
{{REPOSITORY_ANALYSIS}}

## Your task
1. Identify the detected framework and the most appropriate existing test file (or suite) for this test.
2. List page objects, helpers, fixtures, and models to reuse - cite exact file paths.
3. Map each manual step to a high-level automation action using ONLY existing abstractions.
4. Flag any gaps (missing page object methods, unclear selectors, missing test data).
5. Propose the integration target: existing file path + describe where the new test method/scenario goes.

Output a structured analysis only. Do NOT write test code yet.
```

---

## Stage 2 - Generate

**Goal:** Write the test logic with traceability to the source case.

```
Based on your Stage 1 analysis (below), generate the test implementation.

## Stage 1 analysis (approved)
{{STAGE_1_OUTPUT}}

## Test case (source of truth)
{{TEST_CASE_JSON}}

## Constraints
- Reuse existing imports, page objects, helpers, and fixtures from the repository analysis.
- Include a traceability comment referencing {{TC_NUMBER}} at the top of the test.
- Map every manual step to at least one assertion or verification.
- Do NOT create new support files without explicit approval.
- Match the coding style of neighboring tests in the target file.

## Your task
Produce the complete test method/scenario/step definitions only (not the full file unless the target is a new file).
Include inline comments linking each block to the corresponding manual step number.
```

---

## Stage 3 - Integrate

**Goal:** Merge the generated test into the repository with minimal diff.

```
Integrate the generated test into the target repository.

## Stage 2 output (approved)
{{STAGE_2_OUTPUT}}

## Integration target
{{INTEGRATION_TARGET}}

## Repository analysis
{{REPOSITORY_ANALYSIS}}

## Constraints
- Modify ONLY the target file and any files that require new imports.
- Do NOT duplicate existing page objects, helpers, or fixtures.
- Preserve existing test ordering and naming conventions.
- Add the test to an existing describe/suite block when possible.

## Your task
Show a unified diff (or before/after) for each file you would change.
Explain any import additions and why they are needed.
```

---

## Stage 4 - Validate (Review and Run)

**Goal:** Execute the test and iterate on failures.

```
Run and validate the integrated test.

## Integrated changes
{{STAGE_3_OUTPUT}}

## Framework
{{DETECTED_FRAMEWORK}}

## Your task
1. Run the new test in isolation using the project's standard test runner command.
2. If it fails, diagnose the failure and propose a minimal fix.
3. Repeat until the test passes or you identify a blocker requiring human input.
4. Summarize: command used, pass/fail status, and any remaining risks.

Do NOT commit changes. Present results for human review.
```

---

## Placeholder reference

`Generate-AiPrompts.ps1` substitutes these tokens when building `ai-prompts/{tc-number}-prompts.md`:

| Token | Source |
|-------|--------|
| `{{TEST_CASE_JSON}}` | Normalized test case JSON |
| `{{TC_NUMBER}}` | Test case number (e.g. TC-1234) |
| `{{REPOSITORY_ANALYSIS}}` | Output of repository scanner |
| `{{DETECTED_FRAMEWORK}}` | Primary detected framework name |
| `{{INTEGRATION_TARGET}}` | Recommended file path from analysis |
| `{{STAGE_1_OUTPUT}}` | Human pastes Stage 1 assistant output before Stage 2 |
| `{{STAGE_2_OUTPUT}}` | Human pastes Stage 2 assistant output before Stage 3 |
| `{{STAGE_3_OUTPUT}}` | Human pastes Stage 3 assistant output before Stage 4 |
