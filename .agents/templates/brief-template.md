---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# {task_id}: {Title}

## Origin

- **Created:** {YYYY-MM-DD}
- **Session:** {app}:{session-id}
- **Created by:** {author} (human | ai-supervisor | ai-interactive)
- **Parent task:** {parent_id} (if subtask)
- **Conversation context:** {1-2 sentence summary of what was discussed that led to this task}

## What

{Clear description of the deliverable. Not "implement X" but what the implementation must produce, what it must do, and what the user/system will experience when it's done.}

## Why

{Problem being solved, user need, business value, or dependency chain that requires this. Why now? What breaks or stalls without it?}

## Tier

<!-- Recommended model tier. Determines cascade dispatch starting point.
     See reference/task-taxonomy.md for criteria and cascade model. -->

`tier:simple` | `tier:standard` | `tier:reasoning`

**Tier rationale:** {Why this tier — e.g., "Single-file edit with exact code block provided → tier:simple"
or "Multi-file refactor requiring judgment about which pattern to follow → tier:standard"}

## How (Approach)

<!-- Worker-ready implementation context (t1900): every section below is required
     for auto-dispatch issues. Vague "How" sections waste worker tokens on exploration.
     If files/patterns cannot be determined, state that explicitly.

     TIER-AWARE DETAIL LEVEL:
     - tier:simple: Code blocks must be COMPLETE — exact oldString/newString for edits,
       full file content for new files. The worker copies and verifies, not invents.
     - tier:standard: Code skeletons with function signatures and inline comments.
       The worker fills in logic following the specified pattern.
     - tier:reasoning: Approach description with constraints and trade-offs.
       The worker designs the solution. -->

### Files to Modify

<!-- Prefix NEW: for new files, EDIT: for existing. Include line ranges where relevant. -->

- `NEW: path/to/new-file.ts` — {purpose, model on `path/to/reference-file.ts`}
- `EDIT: path/to/existing.ts:45-60` — {what to change and why}

### Implementation Steps

<!-- For each file above, read the reference pattern and include a code skeleton
     or diff as a fenced code block. New files: complete skeleton with imports,
     function signatures, and inline comments marking where logic goes.
     Edits: exact code block to insert with surrounding context.
     The implementing worker should copy and fill in, not invent structure. -->

1. {Concrete step with code skeleton:}

```{language}
{Code skeleton for new file — or exact diff block for edits.
 Include imports, function signatures, inline comments for logic.
 The worker copies this and fills in implementation details.}
```

2. {Next step with code skeleton if applicable}
3. {Final step — e.g., "Run `shellcheck` on new file, verify hook fires with test harness"}

### Verification

```bash
{Command(s) to confirm the implementation works — e.g., shellcheck, grep, test run}
```

## Acceptance Criteria

Each criterion may include an optional `verify:` block (YAML in a fenced code block)
that defines how to machine-check the criterion. See `.agents/scripts/verify-brief.sh` for the runner.

- [ ] {Specific, testable criterion — e.g., "User can toggle sidebar with Cmd+B"}
  ```yaml
  verify:
    method: bash
    run: "{shell command — pass if exit 0}"
  ```
- [ ] {Another criterion — e.g., "Conversation history persists across page reloads"}
  ```yaml
  verify:
    method: codebase
    pattern: "{regex pattern to search for}"
    path: "{directory or file to search in}"
  ```
- [ ] {Negative criterion — e.g., "Org A's data never appears in Org B's context"}
  ```yaml
  verify:
    method: codebase
    pattern: "{pattern that must NOT match}"
    path: "{search scope}"
    expect: absent
  ```
- [ ] {Criterion requiring AI review}
  ```yaml
  verify:
    method: subagent
    prompt: "{review prompt for AI to evaluate}"
    files: "{optional: files to include as context}"
  ```
- [ ] {Criterion requiring human review}
  ```yaml
  verify:
    method: manual
    prompt: "{what the human should check}"
  ```
- [ ] Tests pass (`npm test` / `bun test` / project-specific)
- [ ] Lint clean (`eslint` / `shellcheck` / project-specific)

<!-- Verify block reference:
  Methods:
    bash     — run shell command, pass if exit 0
    codebase — rg pattern search, pass if match found (or absent with expect: absent)
    subagent — spawn AI review prompt via ai-research
    manual   — flag for human, always reports SKIP (never blocks automation)

  Verify blocks are optional. Criteria without them are reported as UNVERIFIED.
  Runner: .agents/scripts/verify-brief.sh <brief-file>
-->

## Context & Decisions

{Key decisions from the conversation that created this task:}
{- Why approach A was chosen over B}
{- Constraints discovered during discussion}
{- Things explicitly ruled out (non-goals)}
{- Prior art or references consulted}

## Relevant Files

- `path/to/file.ts:45` — {why relevant, what to change}
- `path/to/related.ts` — {dependency or pattern to follow}
- `path/to/test.test.ts` — {existing test patterns}

## Dependencies

- **Blocked by:** {task_ids or external requirements}
- **Blocks:** {what this unblocks when complete}
- **External:** {APIs, services, credentials, purchases needed}

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | {Xm} | {what to read} |
| Implementation | {Xh} | {scope} |
| Testing | {Xm} | {test strategy} |
| **Total** | **{Xh}** | |
