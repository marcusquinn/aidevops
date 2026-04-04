---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1869: /autoagent command doc — entry point for framework self-improvement loop

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** ai-interactive
- **Parent task:** t1866
- **Conversation context:** The command doc is the user-facing entry point. Follows the same pattern as `/autoresearch` command but with autoagent-specific setup questions and dispatch.

## What

Command doc at `.agents/scripts/commands/autoagent.md` defining the `/autoagent` slash command. Handles 4 invocation patterns:

| Pattern | Example | Behaviour |
|---|---|---|
| `--program <path>` | `/autoagent --program todo/research/autoagent-self-healing.md` | Skip interview, run directly |
| `--focus <type>` | `/autoagent --focus self-healing` | Pre-select hypothesis type, short confirmation |
| `--signal-scan` | `/autoagent --signal-scan` | Analysis only — mine signals, suggest hypotheses, no execution |
| Bare | `/autoagent` | Full interactive setup |

**Interactive setup (Q1-Q6):**

1. **What to optimize?** — Inferred from signals. Options: general framework improvement, specific agent file, specific tool/script, specific workflow.
2. **Which hypothesis types?** — Multi-select from 6 types. Default: all enabled. `--focus` pre-selects one.
3. **Edit surface?** — Which files can be modified. Default based on Q1 answer. Safety constraints shown.
4. **Budget?** — Timeout, max iterations, per-experiment timeout. Defaults: 2h / 30 iterations / 5m.
5. **Models?** — Researcher model tier. Default: sonnet.
6. **Multi-trial count?** — How many evaluation trials per hypothesis. Default: 2.

After setup: writes research program to `todo/research/autoagent-{name}.md`, confirms, dispatches to autoagent subagent.

## Why

- Users need a clean entry point to the autoagent system
- Interactive setup ensures the research program is well-formed before dispatch
- `--signal-scan` mode allows analysis without commitment — useful for understanding what the system would try to fix
- `--focus` mode lets users target specific improvement areas efficiently

## How (Approach)

**Follow the exact structure of `.agents/scripts/commands/autoresearch.md`:**

```markdown
---
description: Autonomous framework self-improvement loop — optimize agents, tools, scripts, prompts, orchestration
agent: autoagent
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: true
  bash: true
---

Run an autonomous self-improvement loop that modifies framework files, measures composite quality, and keeps only improvements.

Arguments: $ARGUMENTS
```

**Step 1: Resolve Invocation Pattern**

```text
if $ARGUMENTS contains "--signal-scan":  -> Signal Scan Mode
elif $ARGUMENTS contains "--program ":   -> extract program path, skip to Step 3
elif $ARGUMENTS contains "--focus ":     -> extract focus type, pre-fill Q2, show summary
elif $ARGUMENTS is non-empty:            -> One-liner Mode (infer defaults)
else:                                    -> Interactive Setup (Q1-Q6)
```

**Step 2: Interactive Setup (Q1-Q6)**

Q1 infers from current state:
- Recent session errors? Suggest "self-healing focus"
- High token usage in agent files? Suggest "instruction refinement"
- Many linter violations? Suggest "tool optimization"
- Default: "general framework improvement"

Q2 presents 6 hypothesis types with checkboxes (all default enabled).

Q3 maps to safe defaults:
- General: `.agents/**/*.md, .agents/scripts/*.sh`
- Self-healing: `.agents/scripts/*.sh, .agents/workflows/*.md`
- Instruction refinement: `.agents/**/*.md, .agents/prompts/*.txt`
- Tool optimization: `.agents/scripts/*.sh`
- Tool creation: `.agents/scripts/` (new files only)
- Agent composition: `.agents/tools/**/*.md, .agents/reference/agent-routing.md`

Q4-Q6 have sensible defaults shown with `[Enter to accept]`.

**Step 3: Write Research Program**

Write to `todo/research/autoagent-{name}.md` from `.agents/templates/autoagent-program-template.md`.

**Step 4: Dispatch**

Same as autoresearch: Begin now (dispatch to autoagent subagent) / Queue for later / Show program and exit. Headless: begin now.

**Signal Scan Mode:**

Don't write a research program or start a loop. Instead:
1. Mine signals from all available sources (session miner, comprehension tests, linters, git churn)
2. For each signal, suggest which hypothesis type would address it
3. Output a summary: "Found N actionable signals. Top 5: ..."
4. Offer: "Run `/autoagent --focus <type>` to address these, or `/autoagent` for full setup"

## Acceptance Criteria

- [ ] Command doc exists at `.agents/scripts/commands/autoagent.md` with valid YAML frontmatter
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/scripts/commands/autoagent.md && head -5 .agents/scripts/commands/autoagent.md | grep -q 'agent: autoagent'"
  ```
- [ ] All 4 invocation patterns are documented (--program, --focus, --signal-scan, bare)
  ```yaml
  verify:
    method: codebase
    pattern: "--program|--focus|--signal-scan|Interactive Setup"
    path: ".agents/scripts/commands/autoagent.md"
  ```
- [ ] Interactive setup has 6 questions (Q1-Q6)
  ```yaml
  verify:
    method: codebase
    pattern: "Q[1-6]"
    path: ".agents/scripts/commands/autoagent.md"
  ```
- [ ] Signal scan mode is documented with output format
  ```yaml
  verify:
    method: codebase
    pattern: "Signal Scan|signal.scan|actionable signals"
    path: ".agents/scripts/commands/autoagent.md"
  ```
- [ ] Dispatches to autoagent subagent (not autoresearch)
  ```yaml
  verify:
    method: codebase
    pattern: "tools/autoagent/autoagent\\.md"
    path: ".agents/scripts/commands/autoagent.md"
  ```
- [ ] Markdown passes markdownlint

## Context & Decisions

- **Why mirror autoresearch command structure?** Consistency for users who already know `/autoresearch`. Same invocation patterns, same dispatch flow.
- **Why `--signal-scan` mode?** Low-commitment entry point. Users can see what autoagent would try to fix before letting it run autonomously. Builds trust.
- **Why `--focus` instead of just `--program`?** `--focus self-healing` is more ergonomic than writing a research program manually. The command infers the rest.
- **Why 6 questions not 7?** Unlike autoresearch, there's no "where does the work happen?" question — autoagent always targets the current (aidevops) repo.

## Relevant Files

- `.agents/scripts/commands/autoresearch.md` — EXACT pattern to follow (invocation patterns, step structure, dispatch)
- `.agents/tools/autoagent/autoagent.md` — subagent this dispatches to (t1868)
- `.agents/templates/autoagent-program-template.md` — template for writing research programs (t1871)

## Dependencies

- **Blocked by:** t1868 (subagent — the command dispatches to it), t1871 (template — the command writes from it)
- **Blocks:** nothing (final user-facing piece)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Re-read autoresearch command doc |
| Implementation | 2h | 4 invocation patterns, Q1-Q6, signal scan mode |
| Testing | 15m | Markdownlint, structure review |
| **Total** | **~2.5h** | |
