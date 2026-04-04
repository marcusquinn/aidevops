<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1749: Retrofit Concurrency Modes and Mailbox Integration into Autoresearch Files

## Origin

- **Created:** 2026-04-02
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + AI (interactive)
- **Parent task:** t1741
- **Conversation context:** The pulse worker completed t1741.1 (schema), t1741.2 (command doc), and t1741.3 (subagent) from the original briefs before concurrency and mailbox scope was added. Three merged/in-progress implementations need updating to match the canonical briefs.

## What

Update the three autoresearch files that were implemented without concurrency support:

1. **`.agents/templates/research-program-template.md`** — add `## Concurrency` and `## Dimensions` sections
2. **`.agents/scripts/commands/autoresearch.md`** — add concurrency interview question, CLI flags, file-overlap validation
3. **`.agents/tools/autoresearch/autoresearch.md`** — add mailbox integration, population-based mode, multi-dimension dispatch

## Why

The original briefs specified a sequential-only autoresearch loop. During the design session, concurrency modes (sequential, population-based, multi-dimension) and inter-agent mailbox communication were added to the briefs. The worker implemented the original scope before these updates landed on main. The files now need to match the canonical briefs.

## How (Approach)

Read the updated briefs, then update each file. The briefs are the source of truth:

### 1. research-program-template.md

Add after the `## Budget` section:

```markdown
## Concurrency
mode: sequential          # sequential | population | multi-dimension
population_size: 4        # population mode: N hypotheses per iteration
convoy_id: null           # auto-generated campaign ID for mailbox grouping

## Dimensions
# Only used when concurrency.mode = multi-dimension
# Each dimension gets its own worktree and agent session
# File targets MUST NOT overlap between dimensions
#
# dimensions:
#   - name: build-perf
#     files: webpack.config.js, src/utils/**
#     metric:
#       command: ...
#       name: build_time_s
#       direction: lower
```

Add a third example program demonstrating multi-dimension mode.

Add inheritance note: dimensions inherit parent Constraints/Models/Budget unless overridden.

Source brief: `todo/tasks/t1742-brief.md`

### 2. autoresearch.md (command doc)

Add interview question #8:

```
8. Concurrency?
   → Sequential [default] / Population-based (N hypotheses per iteration) / Multi-dimension
   → If multi-dimension: "Which independent dimensions?" with file target split suggestion
   → Suggest population-based if user mentions "fast" or "overnight"
   → Suggest multi-dimension if multiple independent metrics detected
```

Add CLI flags:

```
/autoresearch --population 4
/autoresearch --dimensions "build-perf,test-speed,bundle-size"
/autoresearch --concurrent 3
```

Add multi-dimension dispatch logic: validate non-overlapping file targets, generate convoy ID, dispatch separate subagent sessions.

Source brief: `todo/tasks/t1743-brief.md`

### 3. autoresearch.md (subagent)

Add to the loop:
- **Setup phase**: `mail-helper.sh register --agent "autoresearch-{name}" --role worker --worktree {path}`
- **Before each hypothesis**: `mail-helper.sh check --agent "autoresearch-{name}" --unread-only` — incorporate peer discoveries
- **After each keep/discard**: `mail-helper.sh send --type discovery --convoy "autoresearch-{id}" --payload {JSON}`
- **Completion**: `mail-helper.sh deregister --agent "autoresearch-{name}"`

Add population-based mode section:

```
Iteration K:
  Generate N hypotheses from current best state
  Fork experiment worktree → N temp copies
  Run constraint + metric on all N in parallel
  Best result → commit to experiment branch
  Discard other N-1 temp worktrees
```

Add multi-dimension mode section with non-overlapping file enforcement.

Add discovery payload JSON schema.

Add graceful degradation: when no concurrent peers exist, mailbox calls are no-ops.

Source brief: `todo/tasks/t1744-brief.md`

## Acceptance Criteria

- [ ] research-program-template.md has `## Concurrency` section with mode, population_size, convoy_id
  ```yaml
  verify:
    method: codebase
    pattern: "## Concurrency|population_size|convoy_id"
    path: ".agents/templates/research-program-template.md"
  ```
- [ ] research-program-template.md has `## Dimensions` section with per-dimension file targets and metrics
  ```yaml
  verify:
    method: codebase
    pattern: "## Dimensions|dimension.*files|non-overlapping"
    path: ".agents/templates/research-program-template.md"
  ```
- [ ] Command doc has concurrency interview question (#8) with three mode options
  ```yaml
  verify:
    method: codebase
    pattern: "population|multi-dimension|sequential.*default"
    path: ".agents/scripts/commands/autoresearch.md"
  ```
- [ ] Command doc has --population, --dimensions, --concurrent CLI flags
  ```yaml
  verify:
    method: codebase
    pattern: "--population|--dimensions|--concurrent"
    path: ".agents/scripts/commands/autoresearch.md"
  ```
- [ ] Subagent has mailbox register/check/send/deregister lifecycle
  ```yaml
  verify:
    method: codebase
    pattern: "mail-helper.*register|mail-helper.*check|mail-helper.*send|mail-helper.*deregister"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Subagent has population-based mode with N temp worktrees and parallel measurement
  ```yaml
  verify:
    method: codebase
    pattern: "population|parallel.*hypothesis|fork.*worktree"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Subagent has multi-dimension mode with non-overlapping file target enforcement
  ```yaml
  verify:
    method: codebase
    pattern: "dimension|non-overlapping|file.*target"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Subagent has discovery payload JSON schema (campaign, dimension, hypothesis, status, metric_delta, files_changed)
  ```yaml
  verify:
    method: codebase
    pattern: "campaign.*dimension.*hypothesis|discovery.*payload"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Mailbox calls degrade gracefully when no peers exist (no-op, not error)
- [ ] Third example program in template demonstrates multi-dimension mode
- [ ] Lint clean (markdownlint)

## Context & Decisions

- **Retrofit, not rewrite**: the existing implementations are correct for sequential mode. Add concurrency alongside, don't restructure.
- **Briefs are canonical**: the updated briefs (t1742, t1743, t1744, t1747) contain the full specification. Read them, don't invent.
- **Worker did nothing wrong**: it implemented exactly what the briefs said at dispatch time. The scope expanded during the interactive design session. This is normal.

## Relevant Files

- `.agents/templates/research-program-template.md` — file to update (created by PR #15362)
- `.agents/scripts/commands/autoresearch.md` — file to update (created by PR #15367)
- `.agents/tools/autoresearch/autoresearch.md` — file to update (created by PR #15367)
- `.agents/scripts/mail-helper.sh` — mailbox system reference
- `todo/tasks/t1742-brief.md` — canonical schema brief
- `todo/tasks/t1743-brief.md` — canonical command doc brief
- `todo/tasks/t1744-brief.md` — canonical subagent brief

## Dependencies

- **Blocked by:** nothing (all three files exist on main)
- **Blocks:** t1741.4 (agent optimization needs mailbox), t1741.6 (results tracking needs convoy)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read existing files + briefs | 30m | Understand what exists vs what's needed |
| Update research-program-template.md | 45m | Concurrency + Dimensions sections, third example |
| Update command doc | 1h | Question #8, flags, validation, dispatch logic |
| Update subagent | 1.5h | Mailbox lifecycle, population mode, multi-dimension, payload schema |
| Review + lint | 15m | markdownlint, cross-reference check |
| **Total** | **~4h** | |
