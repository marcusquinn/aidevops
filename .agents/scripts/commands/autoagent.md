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
if $ARGUMENTS contains "--signal-scan":  → Signal Scan Mode (Step 2 only)
elif $ARGUMENTS contains "--program ":   → validate path exists, skip directly to Step 4 (Dispatch)
elif $ARGUMENTS contains "--focus ":     → extract focus type, pre-fill Q2, show summary
elif $ARGUMENTS is non-empty:            → One-Liner Mode (infer defaults)
else:                                    → Interactive Setup (Q1–Q6)
```

**`--program` path:** Validate the supplied path exists and is readable. Do NOT overwrite
it with Step 3 (Write Research Program). Pass it directly to Step 4 dispatch.

## Step 2: Interactive Setup (Q1–Q6)

Ask sequentially; show inferred default as option 1; Enter accepts default.

**Q1 — What to optimize?**

| Signal | Suggestion |
|--------|-----------|
| Recent session errors in logs | "self-healing focus — fix recurring failures" |
| High token usage in agent files | "instruction refinement — reduce tokens, improve pass rate" |
| Many linter violations | "tool optimization — fix script quality issues" |
| Default | "general framework improvement" |

Options:

```text
1. General framework improvement    [default]
2. Specific agent file              → which file?
3. Specific tool/script             → which script?
4. Specific workflow                → which workflow?
```

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

**Q4 — Budget?** Defaults: `2h / 30 iterations / 5m per-experiment`

```text
Timeout:          2h     [Enter to accept]
Max iterations:   30     [Enter to accept]
Per-experiment:   5m     [Enter to accept]
```

**Q5 — Models?** Default: `researcher=sonnet`

```text
Researcher model: sonnet    [Enter to accept]
```

**Q6 — Multi-trial count?** Default: `2` evaluation trials per hypothesis

```text
Trials per hypothesis: 2    [Enter to accept]
```

After setup: writes research program to `todo/research/autoagent-{name}.md`, confirms, dispatches to autoagent subagent.

## Step 3: Write Research Program

Write to `todo/research/autoagent-{name}.md` from `.agents/templates/autoagent-program-template.md`.

Confirm: "Research program written to `todo/research/autoagent-{name}.md`."

## Step 4: Dispatch

```text
1. Begin now (dispatch to autoagent subagent)    [default]
2. Queue for later (add to TODO.md)
3. Show program file and exit
```

Headless: begin now (option 1).

**Begin now:** dispatch to `.agents/tools/autoagent/autoagent.md` with `--program todo/research/autoagent-{name}.md`.

**Queue:** add to TODO.md:

```text
- [ ] t{next_id} autoagent: {name} — {description} #auto-dispatch ~{hours}h ref:GH#{issue}
```

## Signal Scan Mode (`/autoagent --signal-scan`)

Analysis only — no research program written, no loop started.

1. Mine signals from all available sources:
   - Session miner logs (`~/.aidevops/.agent-workspace/`)
   - Comprehension test results (`agent-test-helper.sh`)
   - Linter output (`markdownlint-cli2`, `shellcheck`)
   - Git churn (files changed most frequently)
2. For each signal, identify which hypothesis type would address it
3. Output summary:

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
