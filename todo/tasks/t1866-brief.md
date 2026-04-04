---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1866: feat: autoagent — autonomous framework self-improvement agent and command

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** human + ai-interactive
- **Conversation context:** User shared kevinrgu/autoagent (autonomous harness engineering) and harbor-framework/harbor (agent evaluation framework). Analysis revealed these patterns could extend our existing autoresearch infrastructure to create an autonomous framework self-improvement loop.

## What

An autonomous agent (`/autoagent` command + subagent) that improves the aidevops framework itself by:
1. Mining signals from session logs, pulse outcomes, error patterns, and comprehension tests
2. Generating hypotheses across 6 types (self-healing, tool optimization, instruction refinement, tool creation, agent composition, workflow optimization)
3. Applying modifications to framework files (agents, tools, scripts, prompts)
4. Running multi-trial evaluation (2-3x per hypothesis to reduce LLM stochasticity)
5. Keeping only consistent improvements, discarding everything else
6. Repeating within budget constraints

The system reuses all existing autoresearch loop infrastructure (worktrees, results TSV, memory, mailbox, budget enforcement, crash recovery) and extends it with framework-specific capabilities.

## Why

- Current self-improvement is manual (reference/self-improvement.md says "file an issue, describe pattern, propose fix") — no autonomous optimization loop exists for the framework itself
- autoresearch's agent-optimization mode is limited to instruction simplification — doesn't touch tools, scripts, routing, or workflows
- kevinrgu/autoagent demonstrates that hill-climbing on agent harness quality works — we have the infrastructure to do this but don't yet apply it to ourselves
- Harbor's multi-trial pattern addresses a real weakness in our single-measurement autoresearch (LLM stochasticity causes false positives)

## How (Approach)

### Architecture

```
/autoagent command (entry point)
  |-- autoagent research program (todo/research/autoagent-*.md)
       |-- autoagent subagent (extends autoresearch loop)
            |-- Signal miner: session logs, pulse outcomes, error patterns, comprehension tests
            |-- Hypothesis generator: 6 hypothesis types
            |-- Edit surface: .agents/**/*.md, scripts/*.sh, prompts/*.txt, configs/*.json
            |-- Multi-trial evaluator: run each change 2-3x (from Harbor sweeps)
            |-- Safety layer: security exemptions, regression enforcement, rollback
            |-- Results: todo/research/autoagent-*-results.tsv
```

### File structure

```
.agents/scripts/autoagent-metric-helper.sh         # t1867
.agents/tools/autoagent/autoagent.md                # t1868
.agents/tools/autoagent/autoagent/signal-mining.md  # t1868
.agents/tools/autoagent/autoagent/hypothesis-types.md # t1868
.agents/tools/autoagent/autoagent/safety.md         # t1868
.agents/tools/autoagent/autoagent/evaluation.md     # t1868
.agents/scripts/commands/autoagent.md               # t1869
.agents/templates/autoagent-program-template.md     # t1871
.agents/tools/autoresearch/autoresearch/loop.md     # t1870 (extend existing)
```

### Reused from autoresearch (no reimplementation)

- Worktree creation/management (Step 1 in autoresearch.md)
- Results TSV logging (autoresearch/logging.md)
- Cross-session memory store/recall
- Multi-dimension campaigns + mailbox
- Budget enforcement (timeout, max iterations, goal, per-experiment)
- Crash recovery (resume from results.tsv + branch HEAD)
- Keep/discard rules
- Progression strategy framework

### Key design decisions

1. **Extends autoresearch, not a replacement** — same loop infrastructure, different edit surface and metric source
2. **Does NOT integrate Harbor directly** — domain mismatch (Harbor is for sandboxed Docker benchmarks, we modify a live framework), dependency cost too high
3. **Adopts Harbor design patterns** — multi-trial evaluation (sweeps), structured task format, trajectory recording, overfitting prevention
4. **Composite metric v1**: comprehension tests + linter checks (cheap, fast feedback)
5. **Composite metric v2** (later): + session miner data + pulse outcomes + PR merge rates
6. **Budget-bounded by default** — unlike autoagent's "NEVER STOP", explicit opt-in for longer runs
7. **Security exemptions** inherited from agent-optimization.md — cannot weaken security instructions

## Acceptance Criteria

- [ ] `/autoagent` command exists and produces a research program file
  ```yaml
  verify:
    method: codebase
    pattern: "autoagent"
    path: ".agents/scripts/commands/"
  ```
- [ ] Autoagent subagent exists with 4 subdocs
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/tools/autoagent/autoagent.md && test -f .agents/tools/autoagent/autoagent/signal-mining.md && test -f .agents/tools/autoagent/autoagent/hypothesis-types.md && test -f .agents/tools/autoagent/autoagent/safety.md && test -f .agents/tools/autoagent/autoagent/evaluation.md"
  ```
- [ ] autoagent-metric-helper.sh exists and passes shellcheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/autoagent-metric-helper.sh"
  ```
- [ ] Research program template exists with autoagent-specific sections
  ```yaml
  verify:
    method: codebase
    pattern: "hypothesis_types|signal_sources|safety"
    path: ".agents/templates/autoagent-program-template.md"
  ```
- [ ] Multi-trial evaluation is documented in autoresearch/loop.md
  ```yaml
  verify:
    method: codebase
    pattern: "multi.trial|trials:"
    path: ".agents/tools/autoresearch/autoresearch/loop.md"
  ```
- [ ] All shell scripts pass shellcheck
- [ ] All markdown files pass markdownlint

## Context & Decisions

- **Why not Harbor directly?** Harbor evaluates agents in Docker containers against standardized benchmarks (SWE-Bench, Terminal-Bench). Our framework self-modifies and needs operational metrics (session success, pulse throughput), not coding task scores. The infrastructure cost (Docker builds per evaluation) exceeds the benefit.
- **Why extend autoresearch rather than build from scratch?** 80% of the loop machinery is identical — worktrees, results tracking, memory, budget enforcement, crash recovery. Only the edit surface, metric source, and hypothesis generator differ.
- **Why multi-trial?** Single measurements in autoresearch are vulnerable to LLM stochasticity — a hypothesis that improves the metric by luck on one run isn't a real improvement. Harbor's sweeps pattern (run N times, take median) solves this.
- **Why 6 hypothesis types?** autoagent (kevinrgu) showed that tool engineering and agent composition are high-leverage axes that pure prompt tuning misses. Our agent-optimization mode only does instruction refinement.
- **Overfitting test from autoagent:** "If this exact test disappeared, would this still be a worthwhile framework improvement?" — adopted directly.

## Relevant Files

- `.agents/tools/autoresearch/autoresearch.md` — existing subagent to extend
- `.agents/tools/autoresearch/autoresearch/loop.md` — loop pseudocode to extend with multi-trial
- `.agents/tools/autoresearch/autoresearch/agent-optimization.md` — security exemptions to inherit
- `.agents/tools/autoresearch/autoresearch/logging.md` — TSV schema to extend
- `.agents/tools/autoresearch/autoresearch/completion.md` — completion flow to reuse
- `.agents/scripts/commands/autoresearch.md` — command pattern to follow
- `.agents/templates/research-program-template.md` — template to extend
- `.agents/reference/self-improvement.md` — manual process being automated

## Dependencies

- **Blocked by:** t1741 (autoresearch parent) should ideally be implemented first, but autoagent files can be written in parallel since they reference autoresearch infrastructure by path
- **Blocks:** nothing
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Read autoresearch files, autoagent repo, Harbor patterns |
| t1867 metric helper | 2h | Shell script + tests |
| t1871 template | 1.5h | Extend research-program-template |
| t1870 multi-trial | 2h | Extend loop.md + logging.md |
| t1868 subagent + subdocs | 6h | Core agent + 4 subdocs |
| t1869 command doc | 3h | Interactive setup + dispatch |
| Testing | 1.5h | ShellCheck, markdownlint, dry-run |
| **Total** | **~17h** | |
