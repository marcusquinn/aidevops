---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1989: Cross-reference /build-agent command from tools/build-agent/build-agent.md

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:t1988-interactive
- **Created by:** ai-interactive (user-directed follow-up)
- **Parent task:** t1988 — the PR that created `.agents/scripts/commands/build-agent.md`
- **Conversation context:** During t1988 the session shipped a new `/build-agent` slash command but deliberately did not edit the existing `tools/build-agent/build-agent.md` Quick Reference block, because that is a core contributor-facing doc and an inline self-modification would have expanded scope. User asked for a proper tracked TODO so the cross-reference actually gets added.

## What

Add a Quick Reference pointer in `.agents/tools/build-agent/build-agent.md` that surfaces the `/build-agent` slash command alongside the existing `agent-review.md` and `agent-testing.md` subagent references. The goal is simple discoverability: anyone reading the agent-design guide should immediately see that there is an interactive harness for creating agents, not just a checklist.

Deliverable:

1. One bullet added to the `## Quick Reference` block in `tools/build-agent/build-agent.md` pointing at `scripts/commands/build-agent.md`.
2. One additional sentence (or table row) in the file's existing related-docs section at the bottom linking the two.
3. No changes to design guidance, instruction count, or the post-creation terse-pass rules — the file is at its token budget and a cross-reference must not bloat it.

Explicitly out of scope (non-goals):

- No rewrite of the agent-design guidance in `build-agent.md`.
- No content migration from the command doc back into the tool doc — they serve different audiences (tool doc = design principles, command doc = interactive workflow).
- No changes to `agent-review.md`, `agent-testing.md`, or any other sibling doc.
- No frontmatter or tool-list changes.

## Why

The `/build-agent` slash command only becomes useful if sessions find it. Right now:

- `scripts/commands/build-agent.md` references `tools/build-agent/build-agent.md` several times (one-way pointer).
- `tools/build-agent/build-agent.md` makes zero references to the new command (the reverse pointer is missing).
- Any session that reads the build-agent guide first (the natural order for someone learning agent composition) will not discover that a dispatchable command exists and will hand-roll the process from the checklist.

This is a pure discoverability fix. The cost is ~2 lines of markdown; the benefit is that every future agent-creation session finds the command without prompting.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Yes — 1 file.
- [x] **Complete code blocks for every edit?** Yes — see Implementation Steps below.
- [x] **No judgment or design decisions?** Yes — the content to add is prescribed.
- [x] **No error handling or fallback logic to design?** Yes — docs only.
- [x] **Estimate 1h or less?** Yes — ~10 minutes.
- [x] **4 or fewer acceptance criteria?** Yes — 3.

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file, single-bullet documentation edit with an exact replacement block provided below. This is the canonical `tier:simple` case — Haiku can execute it mechanically from the verbatim code block.

## How (Approach)

### Files to Modify

- `EDIT: .agents/tools/build-agent/build-agent.md` — add a Quick Reference bullet pointing at the new `/build-agent` command. Reference pattern already present in the file: the existing Subagents line that lists `agent-review.md` and `agent-testing.md`.

### Implementation Steps

1. In `.agents/tools/build-agent/build-agent.md`, locate the Quick Reference bullet:

   ```markdown
   - **Subagents**: `agent-review.md` (review), `agent-testing.md` (testing)
   ```

2. Replace it with:

   ```markdown
   - **Subagents**: `agent-review.md` (review), `agent-testing.md` (testing)
   - **Slash command**: `/build-agent {name} {kind} [category]` → `scripts/commands/build-agent.md` (interactive harness for creating new agents)
   ```

3. Verify `markdownlint-cli2` is clean on the file.

### Verification

```bash
bunx markdownlint-cli2 .agents/tools/build-agent/build-agent.md
grep -q 'scripts/commands/build-agent.md' .agents/tools/build-agent/build-agent.md
grep -c '^- \*\*' .agents/tools/build-agent/build-agent.md  # expect unchanged count + 1
```

## Acceptance Criteria

- [ ] `.agents/tools/build-agent/build-agent.md` Quick Reference block contains a bullet pointing at `scripts/commands/build-agent.md` with a one-line description.

  ```yaml
  verify:
    method: codebase
    pattern: "scripts/commands/build-agent.md"
    path: ".agents/tools/build-agent/build-agent.md"
  ```

- [ ] `markdownlint-cli2` passes on the touched file.

  ```yaml
  verify:
    method: bash
    run: "bunx markdownlint-cli2 .agents/tools/build-agent/build-agent.md"
  ```

- [ ] File line count is within ±3 of the pre-edit baseline (enforces the "no bloat" non-goal).

## Context & Decisions

- **Why not bundle this into t1988:** t1988 shipped the new command + ubicloud agent together under a clear scope boundary. Modifying a contributor-facing guide in the same PR mixed two concerns (new feature vs. integration polish) and would have expanded the reviewer's surface area. Splitting the follow-up keeps each PR focused.
- **Why only one bullet, not a deeper rewrite:** `build-agent.md` is explicitly instruction-budgeted (~50–100 instructions, see its own rules). Adding more than a single cross-reference would violate the budget and invite a terse-pass rewrite that is out of scope.
- **Why not also update `AGENTS.md` contributor guide:** the contributor `AGENTS.md` already points at `tools/build-agent/build-agent.md` as the authoritative composition doc. Once that doc surfaces the `/build-agent` command, the contributor path is already reachable via one hop.

## Relevant Files

- `.agents/tools/build-agent/build-agent.md` — single edit target
- `.agents/scripts/commands/build-agent.md` — the target of the new cross-reference (shipped in t1988)

## Dependencies

- **Blocked by:** t1988 (the command file must exist before this pointer is added). Unblocks the moment t1988 PR #18407 merges.
- **Blocks:** nothing
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read + edit | 5m | Single bullet replacement |
| Lint + verify | 3m | markdownlint + grep |
| PR + merge | 2m | Trivial; auto-dispatch eligible |
| **Total** | **~10m** | |
