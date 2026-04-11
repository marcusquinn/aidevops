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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run an autonomous self-improvement loop that modifies framework files, measures composite quality, and keeps only improvements.

Arguments: $ARGUMENTS

## Invocation Patterns

| Pattern | Example | Behaviour |
|---------|---------|-----------|
| `--program <path>` | `/autoagent --program todo/research/autoagent-self-healing.md` | Skip interview, run directly |
| `--focus <type>` | `/autoagent --focus self-healing` | Pre-select hypothesis type, short confirmation |
| `--signal-scan` | `/autoagent --signal-scan` | Analysis only — mine signals, suggest hypotheses, no execution |
| Bare | `/autoagent` | Full interactive setup (Q1-Q6) |

## Step 1: Resolve Invocation

```text
if $ARGUMENTS contains "--signal-scan":  -> Signal Scan Mode
elif $ARGUMENTS contains "--program ":   -> extract path, skip to Step 3
elif $ARGUMENTS contains "--focus ":     -> extract type, pre-fill Q2, show summary
elif $ARGUMENTS is non-empty:            -> One-Liner Mode (infer defaults)
else:                                    -> Interactive Setup (Q1-Q6)
```

## Step 2: Interactive Setup (Q1-Q6)

Ask sequentially. Show inferred default as option 1; Enter accepts default.

**Q1 — What to optimize?** Suggest based on signals (session errors -> self-healing, high token usage -> instruction-refinement, linter violations -> tool-optimization). Options: `1. General [default]` / `2. Specific agent` / `3. Specific tool/script` / `4. Specific workflow`.

**Q2 — Hypothesis types** (multi-select; all enabled by default; `--focus` pre-selects one):
`self-healing` | `instruction-refinement` | `tool-optimization` | `tool-creation` | `agent-composition` | `workflow-alignment`

**Q3 — Edit surface** (defaults based on Q1; confirm or override):

| Q1 answer | Default edit surface |
|-----------|---------------------|
| General | `.agents/**/*.md, .agents/scripts/*.sh` |
| Self-healing | `.agents/scripts/*.sh, .agents/workflows/*.md` |
| Instruction refinement | `.agents/**/*.md, .agents/prompts/*.txt` |
| Tool optimization | `.agents/scripts/*.sh` |
| Tool creation | `.agents/scripts/` (new files only) |
| Agent composition | `.agents/tools/**/*.md, .agents/reference/agent-routing.md` |

**Q4-Q6 — Defaults** (Enter to accept each):

| Setting | Default |
|---------|---------|
| Timeout | `2h` |
| Max iterations | `30` |
| Per-experiment | `5m` |
| Researcher model | `sonnet` |
| Trials per hypothesis | `2` |

After setup: write research program to `todo/research/autoagent-{name}.md`, confirm, dispatch.

## Step 3: Write Research Program

Write to `todo/research/autoagent-{name}.md` from `.agents/templates/autoagent-program-template.md`. Confirm path.

## Step 4: Dispatch

Options: `1. Begin now [default]` / `2. Queue for later` / `3. Show program and exit`. Headless: begin now.

- **Begin now:** dispatch to `.agents/tools/autoagent/autoagent.md` with `--program todo/research/autoagent-{name}.md`
- **Queue:** add `- [ ] t{next_id} autoagent: {name} — {description} #auto-dispatch ~{hours}h ref:GH#{issue}` to TODO.md

## Signal Scan Mode (`--signal-scan`)

Analysis only — no program written, no loop started. Mine signals from: session miner logs (`~/.aidevops/.agent-workspace/`), comprehension tests (`agent-test-helper.sh`), linter output (`markdownlint-cli2`, `shellcheck`), git churn. Classify each by hypothesis type. Output format:

```text
Found N actionable signals. Top 5:
  1. [self-healing]           recurring error in pulse-wrapper.sh:142 — 7 occurrences
  2. [instruction-refinement] build.txt token count 18k — above 15k threshold
  3. [tool-optimization]      shellcheck violations in 3 scripts
  4. [agent-composition]      agent-routing.md missing 4 new agents
  5. [workflow-alignment]     full-loop.md step 4.6 diverged from actual release flow
```

## Related

`.agents/templates/autoagent-program-template.md` · `.agents/tools/autoagent/autoagent.md` · `todo/research/`
