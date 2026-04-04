---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1871: autoagent research program template and example programs

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** ai-interactive
- **Parent task:** t1866
- **Conversation context:** The autoagent needs its own research program template that extends the base autoresearch template with autoagent-specific sections (signal sources, hypothesis types, safety constraints, multi-trial config).

## What

Create `.agents/templates/autoagent-program-template.md` — a research program template specific to autoagent, extending the base `research-program-template.md` with additional sections. Include 3 complete, runnable example programs.

**Template sections (beyond base):**

| Section | Purpose |
|---|---|
| `## Signal Sources` | Which signals to mine (session miner, comprehension tests, linters, git churn, pulse outcomes) |
| `## Hypothesis Types` | Which of the 6 types are enabled for this program |
| `## Safety` | Safety level (standard/elevated), additional never-modify files |
| `## Evaluation` | Multi-trial config (trials count, consistency threshold) |

**3 example programs:**

1. **Self-healing focus** — Mine session errors and error-feedback patterns. Only enable self-healing + tool optimization hypothesis types. Standard safety. 2 trials. Budget: 1h / 15 iterations.

2. **Instruction refinement** — Optimize agent docs for clarity and token efficiency. Only enable instruction refinement hypothesis type. Standard safety. 2 trials. Budget: 2h / 30 iterations. Metric emphasizes token reduction.

3. **Full autonomous** — All 6 hypothesis types enabled. All signal sources. Elevated safety (can touch AGENTS.md). 3 trials. Budget: 4h / 50 iterations. Intended for overnight runs.

## Why

- The autoagent subagent reads a research program file as its contract — without a well-defined template, programs will be inconsistently structured
- Example programs are essential for sonnet to understand the format — they serve as few-shot examples during program generation
- The `/autoagent` command writes research programs from this template — it must be complete and correct
- Separating from the base research-program-template.md keeps the base template clean for non-autoagent use

## How (Approach)

### Template structure

```markdown
---
name: {program-name}
mode: in-repo
target_repo: .
---

# Autoagent: {Title}

<!-- AI-CONTEXT-START -->
An autoagent research program defines what the framework self-improvement loop
optimizes, which signals it mines, which hypothesis types it uses, what safety
constraints apply, and how it evaluates changes.
<!-- AI-CONTEXT-END -->

## Target

\`\`\`text
files: {glob patterns}                    # required
branch: experiment/autoagent-{name}       # auto-generated
\`\`\`

## Signal Sources

\`\`\`text
session_miner: true     # mine session-miner-pulse.sh output for error patterns
comprehension: true     # run agent-test-helper.sh and analyze failures
linters: true           # run linters and count violations
git_churn: true         # identify high-churn framework files
pulse_outcomes: false   # mine pulse dispatch success/failure (requires pulse history)
\`\`\`

## Hypothesis Types

\`\`\`text
self_healing: true          # fix recurring failures from session logs
tool_optimization: true     # improve existing helper scripts
instruction_refinement: true # optimize agent docs for clarity/tokens
tool_creation: false        # propose new tools (higher risk)
agent_composition: false    # restructure subagent routing
workflow_optimization: false # modify operational patterns
\`\`\`

## Safety

\`\`\`text
level: standard             # standard | elevated
never_modify: []            # additional files beyond default never-modify list
require_review: []          # files that need manual review before keep
\`\`\`

## Metric

\`\`\`text
command: autoagent-metric-helper.sh score     # required
name: composite_score                          # required
direction: higher                              # required
baseline: null                                 # auto-populated
goal: null                                     # optional
weights: "0.6,0.3,0.1"                        # optional: comprehension,lint,tokens
\`\`\`

## Constraints

- Tests must pass: `autoagent-metric-helper.sh comprehension | awk '{exit ($1 < 0.8)}'`
- Lint clean: `autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'`
- ShellCheck: `find .agents/scripts -name '*.sh' -exec shellcheck {} \;`

## Models

\`\`\`text
researcher: sonnet
\`\`\`

## Budget

\`\`\`text
timeout: 7200
max_iterations: 30
per_experiment: 300
trials: 2
\`\`\`

## Hints

- {domain-specific guidance}
```

### Example 1: Self-healing focus

Target: `.agents/scripts/*.sh, .agents/workflows/*.md`
Signal sources: session_miner=true, comprehension=false, linters=true, git_churn=true
Hypothesis types: self_healing=true, tool_optimization=true, rest=false
Safety: standard
Budget: 1h / 15 iterations / 5m per-experiment / 2 trials
Hints:
- Check error-feedback patterns for recurring failures
- Priority: fix errors that occur in >10% of sessions
- Prefer adding validation/guards over rewriting logic

### Example 2: Instruction refinement

Target: `.agents/**/*.md, .agents/prompts/*.txt`
Signal sources: comprehension=true, linters=true
Hypothesis types: instruction_refinement=true, rest=false
Safety: standard
Weights: "0.4,0.2,0.4" (emphasize token reduction)
Budget: 2h / 30 iterations / 5m per-experiment / 2 trials
Hints:
- Redundant rules across files are the primary waste
- Merge thin sections covering the same topic
- Never remove security instructions or traceability requirements
- Shorter phrasing that preserves meaning is always a win

### Example 3: Full autonomous (overnight)

Target: `.agents/**/*.md, .agents/scripts/*.sh, .agents/prompts/*.txt`
Signal sources: all=true
Hypothesis types: all=true
Safety: elevated (can touch AGENTS.md, build.txt non-security)
Budget: 4h / 50 iterations / 10m per-experiment / 3 trials
Hints:
- Start with self-healing (highest signal, lowest risk)
- Progress to instruction refinement after self-healing exhausts low-hanging fruit
- Tool creation and agent composition only after iteration 20
- Equal-or-better with less code is always a win

## Acceptance Criteria

- [ ] Template exists at `.agents/templates/autoagent-program-template.md`
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/templates/autoagent-program-template.md"
  ```
- [ ] Template has all autoagent-specific sections (Signal Sources, Hypothesis Types, Safety, Evaluation)
  ```yaml
  verify:
    method: codebase
    pattern: "Signal Sources|Hypothesis Types|Safety|Evaluation|trials:"
    path: ".agents/templates/autoagent-program-template.md"
  ```
- [ ] Template has 3 complete example programs
  ```yaml
  verify:
    method: codebase
    pattern: "Example [123]:|Self.healing|Instruction refinement|Full autonomous"
    path: ".agents/templates/autoagent-program-template.md"
  ```
- [ ] Each example has all required fields (target, signal sources, hypothesis types, metric, constraints, budget)
  ```yaml
  verify:
    method: subagent
    prompt: "Read .agents/templates/autoagent-program-template.md and verify that all 3 example programs contain: Target section with files, Signal Sources section, Hypothesis Types section, Metric section with command/name/direction, Constraints section, Budget section with timeout/max_iterations/trials. Report any missing fields."
  ```
- [ ] Metric command references autoagent-metric-helper.sh
  ```yaml
  verify:
    method: codebase
    pattern: "autoagent-metric-helper\\.sh"
    path: ".agents/templates/autoagent-program-template.md"
  ```
- [ ] Markdown passes markdownlint

## Context & Decisions

- **Why a separate template from research-program-template.md?** The base template is generic (any metric, any files). The autoagent template adds domain-specific sections that don't belong in the generic version. The `/autoagent` command writes from this template; `/autoresearch` writes from the base.
- **Why 3 examples?** Three covers the main use cases: targeted fix (self-healing), systematic optimization (instruction refinement), and full exploration (overnight). They also serve as few-shot examples for the command's program generation.
- **Why elevated safety as opt-in?** AGENTS.md and build.txt affect every session. Modifying them incorrectly has blast radius across all repos. Standard safety keeps these off-limits by default.

## Relevant Files

- `.agents/templates/research-program-template.md` — base template to extend (reference, don't modify)
- `.agents/tools/autoagent/autoagent.md:38-63` — Step 0 variable table that parses this template (t1868)
- `.agents/scripts/commands/autoagent.md` — command that writes from this template (t1869)
- `.agents/scripts/autoagent-metric-helper.sh` — metric command referenced in examples (t1867)

## Dependencies

- **Blocked by:** nothing (can be developed in parallel with t1867)
- **Blocks:** t1868 (subagent reads programs in this format), t1869 (command writes programs from this template)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Re-read base template |
| Template structure | 30m | Sections, field definitions, notes |
| Example 1 (self-healing) | 20m | Complete runnable program |
| Example 2 (instruction) | 20m | Complete runnable program |
| Example 3 (full auto) | 20m | Complete runnable program |
| Testing | 10m | Markdownlint |
| **Total** | **~1.5h** | |
