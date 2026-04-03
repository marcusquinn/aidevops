---
mode: subagent
---
# t1877: Structured Code Review Categories Reference Doc

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + ai-interactive
- **Conversation context:** Analysis of imbue-ai/mngr repo revealed their `.reviewer/code-issue-categories.md` defines 18 structured review categories with explicit examples, exceptions, and severity levels. Our current review guidance is scattered and lacks this level of structure. This is a documentation task — no new tools, just a better reference for existing review agents.

## What

Create `.agents/tools/code-review/review-categories.md` — a structured reference doc defining code review issue categories with examples, counter-examples (exceptions), and severity scales. Referenced by `auditing.md`, `agent-review.md`, and any future automated review agents.

The doc should be usable both as human-readable reference and as agent context when performing code reviews.

## Why

Current review guidance is spread across `auditing.md`, `agent-review.md`, `code-standards.md`, and `build.txt` without explicit category definitions. When a review agent runs, it improvises what to check. A structured categories doc improves:
- Consistency (same categories across all reviews)
- Catch rate (explicit categories prevent blind spots)
- Severity calibration (agents assign consistent severity)
- Quality of findings (examples teach the agent what good/bad looks like)

## How (Approach)

Create the doc at `.agents/tools/code-review/review-categories.md` with categories adapted from mngr's review system but filtered for our context (shell scripts, markdown, agent docs — not Python monorepos). Each category gets:

1. **Category name** (kebab-case ID)
2. **Description** (2-3 sentences)
3. **Examples** (what to flag)
4. **Exceptions** (what NOT to flag)
5. **Severity guide** (CRITICAL/MAJOR/MINOR/NITPICK)

Categories to include (adapted from mngr, filtered for aidevops context):

| Category | Why relevant |
|----------|-------------|
| `commit-message-mismatch` | Diff doesn't match stated intent — common in headless workers |
| `instruction-file-disobeyed` | Agent violated AGENTS.md/build.txt rules |
| `user-request-artifacts` | Comments like "Fixed bug where..." instead of describing current behavior |
| `fails-silently` | Shell scripts catching errors without logging — our #1 script quality issue |
| `documentation-implementation-mismatch` | Docs/code divergence in agent docs |
| `incomplete-integration` | New code doesn't follow existing patterns |
| `repetitive-code` | Duplicate logic across helper scripts |
| `poor-naming` | Inconsistent naming in scripts/agents |
| `logic-error` | Incorrect conditionals, off-by-one, wrong operators |
| `runtime-error-risk` | Unquoted variables, missing existence checks |
| `security-violation` | Hardcoded secrets, exposed credentials |
| `missing-error-handling` | Operations that can fail without handlers |
| `abstraction-violation` | Bypassing helper APIs, accessing internals directly |

Categories to EXCLUDE (not relevant to our codebase):
- `async_correctness` (we don't write async code)
- `type_safety_violation` (shell/markdown, not typed languages)
- `resource_leakage` (not our failure mode)
- `dependency_management` (we have minimal deps)

Reference from existing docs:
- `.agents/tools/code-review/auditing.md` — add pointer to categories doc
- `.agents/tools/build-agent/agent-review.md` — add pointer to categories doc

Key files:
- `.agents/tools/code-review/review-categories.md` — NEW file
- `.agents/tools/code-review/auditing.md` — add reference
- `.agents/tools/build-agent/agent-review.md` — add reference

## Acceptance Criteria

- [ ] Review categories doc exists at `.agents/tools/code-review/review-categories.md`
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/tools/code-review/review-categories.md"
  ```
- [ ] At least 10 categories defined with name, description, examples, exceptions, severity
  ```yaml
  verify:
    method: bash
    run: "grep -c '^## ' .agents/tools/code-review/review-categories.md | awk '{exit ($1 >= 10) ? 0 : 1}'"
  ```
- [ ] `auditing.md` references the categories doc
  ```yaml
  verify:
    method: codebase
    pattern: "review-categories"
    path: ".agents/tools/code-review/auditing.md"
  ```
- [ ] `agent-review.md` references the categories doc
  ```yaml
  verify:
    method: codebase
    pattern: "review-categories"
    path: ".agents/tools/build-agent/agent-review.md"
  ```
- [ ] Markdownlint clean
  ```yaml
  verify:
    method: bash
    run: "markdownlint-cli2 .agents/tools/code-review/review-categories.md 2>&1 | grep -c 'error' | awk '{exit ($1 == 0) ? 0 : 1}'"
  ```

## Context & Decisions

- Inspired by imbue-ai/mngr `.reviewer/code-issue-categories.md` (18 categories)
- Filtered to 13 categories relevant to shell/markdown/agent-doc codebase
- This is a reference doc, not a new tool — existing review agents reference it as context
- Severity scale matches mngr's: CRITICAL (must fix), MAJOR (should fix), MINOR (could fix), NITPICK (optional)
- Examples should use aidevops-specific scenarios (shell scripts, helper scripts, agent docs), not generic Python examples

## Relevant Files

- `.agents/tools/code-review/review-categories.md` — NEW
- `.agents/tools/code-review/auditing.md` — add reference
- `.agents/tools/code-review/code-standards.md` — existing standards (don't duplicate)
- `.agents/tools/build-agent/agent-review.md` — add reference
- `.agents/prompts/build.txt` — existing quality rules (categories doc supplements, doesn't replace)

## Dependencies

- **Blocked by:** nothing
- **Blocks:** nothing
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Read existing auditing.md, agent-review.md, code-standards.md |
| Implementation | 2h | Write categories doc, add references |
| Testing | 10m | Markdownlint check |
| **Total** | **2.5h** | |
