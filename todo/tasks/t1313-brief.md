---
mode: subagent
---
# t1313: Executable verification blocks in task briefs

## Origin

- **Created:** 2026-02-22
- **Session:** claude-code:interactive
- **Created by:** ai-interactive
- **Conversation context:** Inspired by manifest-dev's per-criterion verification schema (GH#2179). Verification should be defined at brief-creation time, not completion time, so acceptance criteria are machine-checkable.

## What

Extend the brief template with optional `verify:` YAML blocks on acceptance criteria. Create a runner script that extracts and executes all verification blocks. Integrate with task-complete-helper.sh as a completion gate.

Four verification methods:
1. **bash** — run a shell command, pass if exit 0
2. **codebase** — run `rg` pattern check against the codebase
3. **subagent** — spawn a review prompt via ai-research
4. **manual** — flag for human review (cannot be auto-verified)

## Why

Currently, acceptance criteria in briefs are human-readable text with no machine-checkable verification. Task completion relies on the AI self-assessing "done" without structured proof. This creates:
- False completions (AI declares done without verification)
- Inconsistent quality (no standard verification methods)
- Manual overhead (reviewer must re-derive verification steps)

Defining verification at brief-creation time means the person/AI who understands the requirement also defines how to check it.

## How (Approach)

1. **Extend `brief-template.md`** — Add optional `verify:` YAML fenced blocks after acceptance criteria items
2. **Create `verify-brief.sh`** — Shell script that:
   - Parses brief markdown to extract `verify:` blocks
   - Dispatches each block by method (bash/codebase/subagent/manual)
   - Reports pass/fail/skip per criterion
   - Returns exit 0 only if all non-manual criteria pass
3. **Integrate with `task-complete-helper.sh`** — Add `--verify` flag that runs verify-brief.sh before marking complete
4. Follow existing script patterns: source shared-constants.sh, use `local var="$1"`, explicit returns

## Acceptance Criteria

- [ ] Brief template includes documented `verify:` block syntax with examples for all 4 methods
  ```yaml
  verify:
    method: bash
    run: "shellcheck -S warning .agents/scripts/verify-brief.sh"
  ```
- [ ] `verify-brief.sh` extracts verify blocks from a brief file
  ```yaml
  verify:
    method: codebase
    pattern: "verify-brief\\.sh"
    path: ".agents/scripts/"
  ```
- [ ] `verify-brief.sh` executes bash method (exit 0 = pass)
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/scripts/verify-brief.sh"
  ```
- [ ] `verify-brief.sh` executes codebase method (rg pattern match)
  ```yaml
  verify:
    method: codebase
    pattern: "method: (bash|codebase|subagent|manual)"
    path: ".agents/templates/brief-template.md"
  ```
- [ ] `verify-brief.sh` handles subagent method (spawns review prompt)
  ```yaml
  verify:
    method: manual
    prompt: "Verify subagent dispatch works correctly"
  ```
- [ ] `verify-brief.sh` handles manual method (reports skip, doesn't block)
  ```yaml
  verify:
    method: manual
    prompt: "Review the template documentation for clarity"
  ```
- [ ] `task-complete-helper.sh` accepts `--verify` flag that gates completion on verify-brief.sh
  ```yaml
  verify:
    method: codebase
    pattern: "--verify"
    path: ".agents/scripts/task-complete-helper.sh"
  ```
- [ ] All scripts pass shellcheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck -S warning .agents/scripts/verify-brief.sh"
  ```
- [ ] Lint clean
  ```yaml
  verify:
    method: bash
    run: "shellcheck -S warning .agents/scripts/task-complete-helper.sh"
  ```

## Context & Decisions

- Verification blocks use YAML inside fenced code blocks (not inline YAML frontmatter) to avoid breaking existing markdown parsers
- `manual` method never blocks automated completion — it reports "SKIP (manual)" and succeeds
- `subagent` method uses ai-research MCP tool for lightweight review (not full agent dispatch)
- Verification is optional — briefs without verify blocks still work normally
- The verify block is placed immediately after its acceptance criterion line for locality
- Inspired by manifest-dev's per-criterion verification schema (GH#2179)

## Relevant Files

- `.agents/templates/brief-template.md` — Template to extend with verify syntax
- `.agents/scripts/task-complete-helper.sh` — Integration point for completion gate
- `.agents/scripts/shared-constants.sh` — Shared constants and utilities
- `todo/PLANS.md` — Reference: 2026-02-22-manifest-driven-brief-generation

## Dependencies

- **Blocked by:** none
- **Blocks:** Future auto-dispatch quality improvements
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Read existing scripts, template, patterns |
| Implementation | 2h30m | Template + verify-brief.sh + integration |
| Testing | 1h | Test all 4 methods, edge cases |
| **Total** | **~4h** | |
