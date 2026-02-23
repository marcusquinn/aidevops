---
mode: subagent
---
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

## How (Approach)

{Technical approach, key files to modify, patterns to follow, libraries to use.}
{Reference existing code: `path/to/file.ts:45` — what pattern to follow}
{Reference existing tests: `path/to/file.test.ts` — test patterns to match}

## Acceptance Criteria

Each criterion may include an optional `verify:` block (YAML in a fenced code block)
that defines how to machine-check the criterion. See `scripts/verify-brief.sh` for the runner.

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
