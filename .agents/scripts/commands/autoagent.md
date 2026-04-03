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

## Invocation Patterns

| Pattern | Example | Behaviour |
|---------|---------|-----------|
| `--program <path>` | `/autoagent --program todo/research/autoagent-self-healing.md` | Skip interview, run directly |
| `--focus <type>` | `/autoagent --focus self-healing` | Pre-select hypothesis type, short confirmation |
| `--signal-scan` | `/autoagent --signal-scan` | Analysis only — mine signals, suggest hypotheses, no execution |
| Bare | `/autoagent` | Full interactive setup (Q1–Q6) |

## Step 1: Resolve Invocation Pattern

```text
if $ARGUMENTS contains "--signal-scan":  → Signal Scan Mode
elif $ARGUMENTS contains "--program ":   → extract program path, skip to Step 3
elif $ARGUMENTS contains "--focus ":     → extract focus type, pre-fill Q2, show summary
elif $ARGUMENTS is non-empty:            → One-Liner Mode (infer defaults)
else:                                    → Interactive Setup (Q1–Q6)
```

## Step 2: Interactive Setup (Q1–Q6)

Ask sequentially; show inferred default as option 1; Enter accepts default.

**Q1 — What to optimize?** Suggest based on signals (session errors → self-healing, high token usage → instruction-refinement, linter violations → tool-optimization). Options: `1. General framework improvement [default]` / `2. Specific agent file` / `3. Specific tool/script` / `4. Specific workflow`.

**Q2 — Which hypothesis types?** (multi-select; all default enabled; `--focus` pre-selects one)

```text
[x] 1. self-healing       — fix recurring errors, improve error recovery
[x] 2. instruction-refinement — reduce token usage, improve clarity
[x] 3. tool-optimization  — improve script reliability and performance
[x] 4. tool-creation      — add missing automation
[x] 5. agent-composition  — improve agent routing and orchestration
[x] 6. workflow-alignment — align workflows with actual usage patterns
```

**Q3 — Edit surface?** (files that may be modified; defaults based on Q1)

| Q1 answer | Default edit surface |
|-----------|---------------------|
| General | `.agents/**/*.md, .agents/scripts/*.sh` |
| Self-healing | `.agents/scripts/*.sh, .agents/workflows/*.md` |
| Instruction refinement | `.agents/**/*.md, .agents/prompts/*.txt` |
| Tool optimization | `.agents/scripts/*.sh` |
| Tool creation | `.agents/scripts/` (new files only) |
| Agent composition | `.agents/tools/**/*.md, .agents/reference/agent-routing.md` |

Safety constraints shown alongside defaults. Confirm or override.

**Q4–Q6 — Defaults** (Enter to accept each):

| Setting | Default |
|---------|---------|
| Timeout | `2h` |
| Max iterations | `30` |
| Per-experiment | `5m` |
| Researcher model | `sonnet` |
| Trials per hypothesis | `2` |

After setup: writes research program to `todo/research/autoagent-{name}.md`, confirms, dispatches to autoagent subagent.

## Step 3: Write Research Program

Write to `todo/research/autoagent-{name}.md` from `.agents/templates/autoagent-program-template.md`. Confirm path to user.

## Step 4: Dispatch

Options: `1. Begin now [default]` / `2. Queue for later (add to TODO.md)` / `3. Show program file and exit`. Headless: begin now.

**Begin now:** dispatch to `.agents/tools/autoagent/autoagent.md` with `--program todo/research/autoagent-{name}.md`.

**Queue:** add to TODO.md:

```text
- [ ] t{next_id} autoagent: {name} — {description} #auto-dispatch ~{hours}h ref:GH#{issue}
```

## Signal Scan Mode (`/autoagent --signal-scan`)

Analysis only — no research program written, no loop started. Mine signals from: session miner logs (`~/.aidevops/.agent-workspace/`), comprehension test results (`agent-test-helper.sh`), linter output (`markdownlint-cli2`, `shellcheck`), git churn. For each signal, identify hypothesis type. Output:

```text
Found N actionable signals. Top 5:
  1. [self-healing]         recurring error in pulse-wrapper.sh:142 — 7 occurrences
  2. [instruction-refinement] build.txt token count 18k — above 15k threshold
  3. [tool-optimization]    shellcheck violations in 3 scripts
  4. [agent-composition]    agent-routing.md missing 4 new agents
  5. [workflow-alignment]   full-loop.md step 4.6 diverged from actual release flow

Run `/autoagent --focus self-healing` to address these, or `/autoagent` for full setup.
```

## Related

`.agents/templates/autoagent-program-template.md` · `.agents/tools/autoagent/autoagent.md` · `todo/research/`
