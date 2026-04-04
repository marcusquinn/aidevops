---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1408: Recursive Task Decomposition for Dispatch

## Origin

- **Created:** 2026-03-06
- **Session:** claude-code:interactive
- **Created by:** human + ai-interactive
- **Parent task:** none
- **Conversation context:** User reviewed [TinyAGI/fractals](https://github.com/TinyAGI/fractals) (recursive agentic task orchestrator, 146 stars, MIT) and asked what ideas were worth adopting for aidevops. Analysis identified the classify/decompose pipeline as the highest-ROI steal — it catches "task too big for one worker" failures that currently require human judgment.

## What

A pre-dispatch step that uses a cheap LLM call (haiku-tier, ~$0.001/call) to classify tasks as **atomic** (execute directly) or **composite** (split into subtasks), then recursively decomposes composites into 2-5 independent subtasks with dependency edges and lineage context.

Three integration points:

1. **Interactive** (`/full-loop`, `/new-task`): User describes task -> classify -> if composite, show subtask tree for confirmation -> create child tasks + briefs -> dispatch workers
2. **Pulse/supervisor**: Pick up task from TODO.md -> classify -> if composite, create child tasks with `blocked-by:` edges -> dispatch leaves -> merge results via PRs
3. **`/mission`**: Replace mission's ad-hoc milestone decomposition with the same classify/decompose pipeline for consistency

Each worker receives **lineage context**: the full ancestor chain (parent task, grandparent, etc.) plus sibling task descriptions, so workers stay focused on their specific scope and don't duplicate sibling work.

Batch execution strategies control parallel dispatch order: depth-first (finish one branch before starting next — default, good for dependent work) or breadth-first (one task from each branch per batch — good for independent work).

## Why

**Problem:** Over-scoped tasks are the #1 cause of worker failures. A task like "build auth system with login, registration, password reset, and OAuth" gets dispatched to a single worker that either produces a massive unfocused PR or fails partway through. Currently, decomposition requires human judgment at task creation time.

**Evidence:** Fractals' approach (500 lines of TypeScript) demonstrates that LLM-powered classify/decompose works reliably with well-tuned prompts. Their key heuristics — "when in doubt, choose atomic" and "break into MINIMUM number of subtasks" — prevent over-decomposition, which is worse than under-decomposition.

**Value:** Catches over-scoped tasks before dispatch, produces better-scoped worker briefs, reduces worker failures, and adds lineage context that prevents scope drift. Cost: ~$0.001-0.005 per decomposition (haiku-tier).

## How (Approach)

### t1408.1: Classify/Decompose Helper

Create `task-decompose-helper.sh` with two subcommands:

- `classify <description> [--lineage <json>]` — returns `atomic` or `composite` (JSON output)
- `decompose <description> [--lineage <json>] [--max-subtasks 5]` — returns subtask list with descriptions and dependency edges (JSON output)

Uses `ai-research` MCP tool or `ai-judgment-helper.sh` for haiku-tier LLM calls with structured output.

**Classify prompt** (adapted from Fractals):
- "atomic" = a developer can implement this directly without further planning
- "composite" = clearly contains 2+ independent concerns that should be worked on separately
- At depth 2+ in hierarchy, almost certainly atomic — only composite if 2+ truly independent deliverables
- **When in doubt, choose atomic** (over-decomposition creates more overhead)
- Check TODO.md for existing subtasks before decomposing (don't re-decompose what's already split)

**Decompose prompt** (adapted from Fractals):
- Break into MINIMUM number of subtasks (2-5, never pad)
- Each subtask = real, distinct work a developer would naturally treat as separate
- Output dependency edges between siblings (e.g., "API must exist before frontend can call it")
- Use `blocked-by:` convention from TODO.md format

**Lineage context formatter** (from Fractals `lineage.ts`):
```text
0. Build a CRM with contacts, deals, and email
  1. Implement contact management module  <-- (this task)
```

Key files:
- `.agents/scripts/task-decompose-helper.sh` — new helper script
- `.agents/scripts/ai-judgment-helper.sh` — existing, reuse for LLM calls
- `.agents/scripts/claim-task-id.sh` — existing, use for child task ID allocation

### t1408.2: Dispatch Pipeline Integration

Wire decomposition into the dispatch flow:

- **Interactive mode**: After task description is provided, run classify. If composite, show tree and ask "Does this decomposition look right? [Y/n/edit]". On confirm, create child TODO entries with `claim-task-id.sh`, set `blocked-by:` edges, generate child briefs from parent brief + decomposition context.
- **Pulse mode**: Auto-classify tasks before dispatch. If composite, create children and dispatch leaves. Depth limit: max 3 levels (configurable via `DECOMPOSE_MAX_DEPTH` env var). Skip decomposition for tasks already having subtasks in TODO.md.

Key files:
- `.agents/scripts/commands/full-loop.md` — update guidance
- `.agents/scripts/commands/new-task.md` — update guidance
- `.agents/scripts/commands/pulse.md` — update guidance
- `.agents/workflows/mission-orchestrator.md` — update to use same pipeline

### t1408.3: Lineage Context in Worker Prompts

When dispatching a worker for a task that has parent/sibling tasks:

```text
PROJECT CONTEXT:
0. Build a CRM with contacts, deals, and email
  1. Implement contact management module
  2. Implement deal pipeline module  <-- (this task)
  3. Implement email integration module

You are one of several agents working in parallel on sibling tasks under the same parent.
Do not duplicate work that sibling tasks would handle — focus only on your specific task.
If this task depends on interfaces/types from sibling tasks, define reasonable stubs.
```

Key files:
- `.agents/tools/ai-assistants/headless-dispatch.md` — update dispatch prompt template
- `.agents/workflows/full-loop.md` — update worker prompt assembly

### t1408.4: Batch Execution Strategies

Add `--batch-strategy` to pulse dispatch:

- **depth-first** (default): Complete all leaves under branch 1.x, then 2.x. Tasks within each branch run concurrently. Good for dependent work.
- **breadth-first**: One leaf from each branch per batch. Spreads progress evenly. Good for independent work.
- Configurable concurrency limit per batch (respects existing `MAX_CONCURRENT_WORKERS`).

Key files:
- `.agents/scripts/commands/pulse.md` — update with batch strategy guidance
- `.agents/reference/orchestration.md` — document batch strategies

### t1408.5: Testing and Verification

- Test classify on 5+ real task descriptions from TODO.md history (mix of known atomic and composite tasks)
- Verify decompose produces sensible subtasks with correct dependency edges
- Verify lineage context formatting
- ShellCheck clean on new helper script
- Verify pulse integration doesn't break existing dispatch (no regressions)

## Acceptance Criteria

- [ ] `task-decompose-helper.sh classify` correctly identifies atomic vs composite tasks (test against 5+ known examples from TODO.md)
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/task-decompose-helper.sh classify 'Add a comment to the calculateTotal function' | jq -r '.kind' | grep -q atomic"
  ```
- [ ] `task-decompose-helper.sh decompose` produces 2-5 subtasks with dependency edges for composite tasks
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/task-decompose-helper.sh decompose 'Build auth system with login, registration, password reset, and OAuth' | jq '.subtasks | length' | awk '$1 >= 2 && $1 <= 5'"
  ```
- [ ] Lineage context formatter produces indented hierarchy with current task marker
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/task-decompose-helper.sh format-lineage --test"
  ```
- [ ] Interactive mode shows decomposition tree and asks for confirmation before creating child tasks
  ```yaml
  verify:
    method: subagent
    prompt: "Review full-loop.md and new-task.md for decomposition confirmation step guidance"
    files: ".agents/scripts/commands/full-loop.md,.agents/scripts/commands/new-task.md"
  ```
- [ ] Pulse mode auto-decomposes with depth limit and skips already-decomposed tasks
  ```yaml
  verify:
    method: subagent
    prompt: "Review pulse.md for auto-decomposition guidance with depth limit and skip logic"
    files: ".agents/scripts/commands/pulse.md"
  ```
- [ ] Worker dispatch prompts include lineage context when parent/sibling tasks exist
  ```yaml
  verify:
    method: codebase
    pattern: "sibling tasks|lineage context|ancestor chain"
    path: ".agents/tools/ai-assistants/headless-dispatch.md"
  ```
- [ ] ShellCheck clean on task-decompose-helper.sh
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/task-decompose-helper.sh"
  ```
- [ ] Tests pass — no regressions in existing dispatch flow

## Context & Decisions

- **Fractals as inspiration, not a port.** Fractals is TypeScript; aidevops is shell scripts + agent docs. We adopt the *pattern* (classify -> decompose -> lineage -> batch), not the code.
- **Haiku-tier for classify/decompose.** These are judgment calls, not complex reasoning. Haiku is sufficient and costs ~$0.001/call. Opus would be overkill.
- **"When in doubt, atomic" bias.** Over-decomposition creates more overhead (more tasks, more PRs, more merge conflicts) than under-decomposition. A slightly-too-large task that one worker handles is better than 5 tiny tasks that need coordination.
- **Depth limit of 3.** Fractals allows depth 5 but notes recursive depth as an open question. For aidevops, 3 levels (parent -> child -> grandchild) is sufficient. Deeper decomposition suggests the original task was poorly scoped.
- **Reuse existing infrastructure.** Child tasks use `claim-task-id.sh` for IDs, `blocked-by:` for dependencies, standard briefs. No new state management — TODO.md is the database.
- **Batch strategies are guidance, not enforcement.** The pulse supervisor uses AI judgment for dispatch order. Batch strategies are a recommendation, not a hard constraint.
- **Skip already-decomposed tasks.** If a task in TODO.md already has subtasks (indented children), don't re-decompose it. This prevents the pulse from re-splitting tasks that were manually decomposed.

## Relevant Files

- `.agents/scripts/ai-judgment-helper.sh` — existing LLM judgment calls, reuse pattern
- `.agents/scripts/claim-task-id.sh` — atomic task ID allocation
- `.agents/scripts/commands/pulse.md` — pulse dispatch guidance
- `.agents/scripts/commands/full-loop.md` — interactive dispatch guidance
- `.agents/scripts/commands/new-task.md` — task creation guidance
- `.agents/tools/ai-assistants/headless-dispatch.md` — worker prompt assembly
- `.agents/workflows/mission-orchestrator.md` — mission decomposition
- `.agents/reference/orchestration.md` — orchestration architecture
- `TODO.md` — task format with `blocked-by:` convention

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing directly, but improves dispatch quality for all future tasks
- **External:** none (haiku-tier LLM calls use existing API keys)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Review existing dispatch flow, ai-judgment-helper patterns |
| t1408.1 Implementation | 3h | Helper script + prompts + lineage formatter |
| t1408.2 Implementation | 3h | Pipeline integration (interactive + pulse + mission) |
| t1408.3 Implementation | 1.5h | Lineage context in worker prompts |
| t1408.4 Implementation | 1.5h | Batch strategies |
| t1408.5 Testing | 1h | Classify/decompose tests, regression check |
| **Total** | **~10h** | |
