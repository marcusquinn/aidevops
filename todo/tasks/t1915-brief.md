---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1915: Add Qlty verification step to simplification brief template and code-simplifier

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:qlty-maintainability-a-grade
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability badge dropped to C. Tasks t1858 and t1861 were marked completed but Qlty still flags the target files with high complexity. Root cause: acceptance criteria didn't include "zero Qlty smells remaining on this file" — workers declared success based on partial complexity reduction without verifying the badge-relevant metric.

## What

Add a mandatory Qlty verification step to:
1. The brief template (`templates/brief-template.md`) for `#simplification` tasks
2. The code-simplifier agent (`tools/code-review/code-simplifier.md`) output format
3. The complexity-scan-helper issue creation in pulse-wrapper.sh

## Why

- t1858 (completed) still has Qlty complexity 334 — was never verified
- t1861 (completed) still has Qlty complexity 156 — was never verified
- Without a verification step, workers can declare success after partial reduction
- The existing acceptance criteria check function-level complexity but not total file smells

## Tier

`tier:simple`

**Tier rationale:** Three targeted edits to existing files, adding a standard verification pattern. Exact code blocks provided below.

## How (Approach)

### Files to Modify

- `EDIT: .agents/templates/brief-template.md:120-121` — add Qlty verification criterion to the default criteria list
- `EDIT: .agents/tools/code-review/code-simplifier.md:46-66` — add Qlty verification to the Phase 4 verify section of the output format
- `EDIT: .agents/tools/code-review/code-simplifier.md:70-76` — add Qlty row to Regression Verification table

### Implementation Steps

1. In `templates/brief-template.md`, after the lint criterion (line ~121), add:

**oldString:**
```
- [ ] Lint clean (`eslint` / `shellcheck` / project-specific)
```

**newString:**
```
- [ ] Lint clean (`eslint` / `shellcheck` / project-specific)
- [ ] Qlty smells resolved (for `#simplification` tasks): `~/.qlty/bin/qlty smells --all 2>&1 | grep '<target_file>' | grep -c . | grep -q '^0$'`
  ```yaml
  verify:
    method: bash
    run: "~/.qlty/bin/qlty smells --all 2>&1 | grep '<target_file>' | grep -c '.' | xargs test 0 -eq"
  ```
```

2. In `code-simplifier.md`, add to the Regression Verification table (after line ~76):

**oldString:**
```
| Configuration files | Schema validation or dry-run the consuming tool |
```

**newString:**
```
| Configuration files | Schema validation or dry-run the consuming tool |
| All `#simplification` targets | `qlty smells --all \| grep <file>` returns zero results — partial reduction is not completion |
```

3. In `code-simplifier.md`, add to the prescriptive format section (after `**Verification:**` line ~62):

Add a note that verification MUST include Qlty smell check, not just shellcheck/grep.

### Verification

```bash
# Template includes Qlty criterion
grep -q "Qlty smells resolved" .agents/templates/brief-template.md && echo PASS

# Code-simplifier includes Qlty verification
grep -q "qlty smells" .agents/tools/code-review/code-simplifier.md && echo PASS
```

## Acceptance Criteria

- [ ] Brief template includes Qlty smells verification criterion for `#simplification` tasks
  ```yaml
  verify:
    method: codebase
    pattern: "Qlty smells resolved"
    path: ".agents/templates/brief-template.md"
  ```
- [ ] Code-simplifier regression verification table includes Qlty check for all simplification targets
  ```yaml
  verify:
    method: codebase
    pattern: "qlty smells.*grep.*file"
    path: ".agents/tools/code-review/code-simplifier.md"
  ```
- [ ] Verification step is a concrete command, not just prose guidance
- [ ] No existing template content is removed or modified beyond the additions

## Context & Decisions

- This is a template change — it affects all future simplification tasks, not existing ones
- The Qlty check is marked as applicable to `#simplification` tasks specifically — not all tasks
- Workers may not have Qlty CLI installed — the verify block should degrade gracefully (report SKIP, not FAIL)
- The `<target_file>` placeholder in the template is intentional — the task creator fills it in when writing the brief

## Relevant Files

- `.agents/templates/brief-template.md:120-122` — default acceptance criteria section
- `.agents/tools/code-review/code-simplifier.md:70-76` — regression verification table
- `.agents/tools/code-review/code-simplifier.md:44-66` — prescriptive output format

## Dependencies

- **Blocked by:** nothing
- **Blocks:** quality of future simplification task execution
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Review current template and code-simplifier |
| Implementation | 20m | Add three targeted edits |
| Testing | 10m | Verify grep patterns match |
| **Total** | **~40m** | |
