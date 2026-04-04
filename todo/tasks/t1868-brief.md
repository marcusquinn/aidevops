---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1868: autoagent subagent — main agent doc with 4 subdocs

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** ai-interactive
- **Parent task:** t1866
- **Conversation context:** Core of the autoagent system. Extends autoresearch loop machinery with framework-specific capabilities. The subagent is what actually runs the autonomous self-improvement loop.

## What

Create the autoagent subagent at `.agents/tools/autoagent/autoagent.md` plus 4 subdocs:

1. **`autoagent.md`** — Main agent doc with YAML frontmatter, quick reference, steps 0-3 (parse, setup, loop, completion). Follows exact same structure as `.agents/tools/autoresearch/autoresearch.md` but with autoagent-specific variables and dispatch.

2. **`autoagent/signal-mining.md`** — How to extract actionable signals from:
   - Session miner data (`session-miner-pulse.sh` output)
   - Pulse dispatch outcomes (worker success/failure rates)
   - Error-feedback patterns (recurring errors from `error-feedback.md`)
   - Comprehension test results (which tests fail, which agent files cause confusion)
   - Git log patterns (which files change most, which PRs get reverted)

3. **`autoagent/hypothesis-types.md`** — The 6 hypothesis types with:
   - Definition and edit surface for each type
   - Progression strategy (which types to try first based on iteration count and available signals)
   - Examples of good and bad hypotheses for each type
   - Overfitting test: "If this exact test disappeared, would this still be a worthwhile framework improvement?"
   - Cross-references to which signals feed which hypothesis types

4. **`autoagent/safety.md`** — Safety constraints for framework self-modification:
   - Security instruction exemptions (inherited from `autoresearch/agent-optimization.md`)
   - Core workflow preservation (git workflow, PR flow, task management must not break)
   - Regression enforcement (no existing passing comprehension test may start failing)
   - Rollback procedure (git reset --hard HEAD, same as autoresearch)
   - Files that are NEVER modifiable (build.txt security sections, credentials handling)
   - Files that require elevated approval (AGENTS.md, build.txt non-security sections)

5. **`autoagent/evaluation.md`** — Multi-trial evaluation and trajectory recording:
   - How to run multi-trial evaluation (run METRIC_CMD N times, take median)
   - Statistical significance: require improvement in >50% of trials
   - Trajectory recording: structured JSON log of what changes were made and why
   - Failure analysis: how to extract actionable information from failed hypotheses
   - Cross-reference to autoagent-metric-helper.sh subcommands

## Why

- The subagent is the engine that actually runs the self-improvement loop
- Separating into subdocs follows the autoresearch pattern (progressive disclosure, loaded on demand)
- Each subdoc addresses a distinct concern that can be developed and tested independently
- sonnet needs detailed, explicit instructions — the subdocs provide the specificity that makes autonomous execution possible

## How (Approach)

### Main agent (`autoagent.md`)

**Follow the exact structure of `autoresearch.md`:**

```markdown
---
description: Autonomous framework self-improvement loop — mines signals, generates hypotheses, modifies framework files, measures improvement, keeps only what helps
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Autoagent Subagent

Runs signal-mining -> hypothesis generation -> modification -> multi-trial evaluation -> keep/discard -> log -> repeat.

Arguments: `--program <path>` (required)
```

**Step 0 (Parse Arguments):** Same as autoresearch but parse additional autoagent-specific fields from research program:
- `HYPOTHESIS_TYPES` — which of the 6 types are enabled
- `SIGNAL_SOURCES` — which signal sources to mine
- `SAFETY_LEVEL` — `standard` (default) or `elevated` (allows AGENTS.md/build.txt changes)
- `TRIALS_PER_HYPOTHESIS` — number of evaluation trials (default: 2)

**Step 1 (Setup):** Same as autoresearch (resolve repo, create/resume worktree, load prior results, recall memory) plus:
- Mine signals from enabled sources (load `signal-mining.md`)
- Load safety constraints (load `safety.md`)

**Step 2 (Loop):** Same structure as autoresearch loop but:
- Hypothesis generation uses signal-mined data + 6 hypothesis types (load `hypothesis-types.md`)
- Metric measurement uses multi-trial evaluation (load `evaluation.md`)
- Keep/discard uses median of N trials, not single measurement

**Step 3 (Completion):** Same as autoresearch (deregister, memory, summary, PR).

### Signal mining subdoc (`signal-mining.md`)

Define how to extract each signal type:

```bash
# Session miner signals
session-miner-pulse.sh --output json | jq '.error_patterns'

# Comprehension test failures
agent-test-helper.sh run --suite <suite> --json | jq '.failures'

# Linter violations
linters-local.sh --json 2>&1 | jq '.violations'

# Git churn (files that change most = likely pain points)
git log --since="30 days ago" --name-only --format="" -- .agents/ | sort | uniq -c | sort -rn | head -20
```

Each signal source produces a structured list of "findings" — specific file + issue pairs that feed hypothesis generation.

### Hypothesis types subdoc (`hypothesis-types.md`)

Define the 6 types with explicit edit surfaces:

| Type | Edit surface | Signal source | Example |
|---|---|---|---|
| Self-healing | Scripts, error handlers, workflow docs | Error-feedback patterns, session failures | Fix recurring `read:file_not_found` pattern |
| Tool optimization | Helper scripts, tool docs | Command frequency, error rates, timeout patterns | Reduce `webfetch` failure rate |
| Instruction refinement | Agent .md files, prompts | Comprehension test results, token usage | Consolidate redundant rules |
| Tool creation | New helper scripts | Capability gaps from failed tasks | Create missing helper for a pattern |
| Agent composition | Subagent routing, model tiers | Task taxonomy, cost/quality tradeoffs | Change default tier for task category |
| Workflow optimization | Command docs, routines | Pulse throughput, PR merge rates | Modify dispatch pattern |

**Progression strategy:**

| Phase | Iterations | Primary types | Why |
|---|---|---|---|
| 1-5 | Self-healing, Instruction refinement | Low risk, high signal, direct feedback |
| 6-15 | Tool optimization, Instruction refinement | Systematic single-variable changes |
| 16-25 | Tool creation, Agent composition | Higher complexity, builds on earlier findings |
| 26-35 | Workflow optimization, combinations | Cross-cutting changes |
| 36+ | Simplification across all types | Equal-or-better with less is always a win |

### Safety subdoc (`safety.md`)

**Inherit from `autoresearch/agent-optimization.md`** the security exemption table. Add:

- **Never-modify files:** `prompts/build.txt` security sections (rules 7-8), `tools/credentials/gopass.md`, `tools/security/prompt-injection-defender.md`
- **Elevated-only files:** `AGENTS.md`, `prompts/build.txt` non-security sections, `workflows/git-workflow.md`
- **Regression gate:** Before keep decision, verify ALL comprehension tests still pass (not just the composite score)
- **Rollback is always safe:** `git -C WORKTREE_PATH reset --hard HEAD` reverts to last known-good state

### Evaluation subdoc (`evaluation.md`)

**Multi-trial evaluation pseudocode:**

```text
function multi_trial_evaluate(metric_cmd, n_trials):
    results = []
    for i in 1..n_trials:
        result = run_metric(metric_cmd)
        if result == ERROR:
            return ERROR  # any trial error = overall error
        results.append(result)
    return median(results)
```

**Trajectory recording format:**

```json
{
  "iteration": 5,
  "hypothesis": "Consolidate file discovery rules",
  "hypothesis_type": "instruction_refinement",
  "files_modified": [".agents/prompts/build.txt"],
  "diff_summary": "+3/-7 lines",
  "trials": [
    {"trial": 1, "score": 0.87, "sub_scores": {"comprehension": 0.90, "lint": 0.95, "tokens": 0.82}},
    {"trial": 2, "score": 0.85, "sub_scores": {"comprehension": 0.88, "lint": 0.95, "tokens": 0.80}}
  ],
  "median_score": 0.86,
  "baseline": 0.83,
  "decision": "keep",
  "timestamp": "2026-04-03T15:00:00Z"
}
```

## Acceptance Criteria

- [ ] Main agent doc exists at `.agents/tools/autoagent/autoagent.md` with valid YAML frontmatter
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/tools/autoagent/autoagent.md && head -10 .agents/tools/autoagent/autoagent.md | grep -q 'mode: subagent'"
  ```
- [ ] All 4 subdocs exist
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/tools/autoagent/autoagent/signal-mining.md && test -f .agents/tools/autoagent/autoagent/hypothesis-types.md && test -f .agents/tools/autoagent/autoagent/safety.md && test -f .agents/tools/autoagent/autoagent/evaluation.md"
  ```
- [ ] Main agent references all 4 subdocs in Quick Reference
  ```yaml
  verify:
    method: codebase
    pattern: "signal-mining\\.md.*hypothesis-types\\.md.*safety\\.md.*evaluation\\.md"
    path: ".agents/tools/autoagent/autoagent.md"
  ```
- [ ] Safety doc inherits security exemptions from agent-optimization.md
  ```yaml
  verify:
    method: codebase
    pattern: "Security Instruction Exemptions|NEVER expose|credentials"
    path: ".agents/tools/autoagent/autoagent/safety.md"
  ```
- [ ] Hypothesis types doc defines all 6 types with edit surfaces
  ```yaml
  verify:
    method: codebase
    pattern: "Self-healing|Tool optimization|Instruction refinement|Tool creation|Agent composition|Workflow optimization"
    path: ".agents/tools/autoagent/autoagent/hypothesis-types.md"
  ```
- [ ] Evaluation doc includes multi-trial pseudocode
  ```yaml
  verify:
    method: codebase
    pattern: "multi_trial|median|n_trials"
    path: ".agents/tools/autoagent/autoagent/evaluation.md"
  ```
- [ ] All markdown files pass markdownlint
  ```yaml
  verify:
    method: bash
    run: "markdownlint-cli2 .agents/tools/autoagent/**/*.md 2>&1; exit 0"
  ```

## Context & Decisions

- **Why follow autoresearch.md structure exactly?** Consistency means the loop infrastructure (worktrees, results tracking, memory) works identically. The subagent inherits battle-tested patterns.
- **Why 4 subdocs not inline?** Progressive disclosure — the main agent is ~120 lines, each subdoc is loaded on demand when that phase begins. Keeps initial context load small.
- **Why not a Python agent?** All our agents are markdown instruction files. The runtime (Claude Code / OpenCode) executes them as subagent prompts.

## Relevant Files

- `.agents/tools/autoresearch/autoresearch.md` — EXACT structure to follow (Steps 0-3, YAML frontmatter, Quick Reference)
- `.agents/tools/autoresearch/autoresearch/loop.md` — loop pseudocode to reference
- `.agents/tools/autoresearch/autoresearch/agent-optimization.md` — security exemptions to inherit
- `.agents/tools/autoresearch/autoresearch/logging.md` — TSV schema to reuse
- `.agents/tools/autoresearch/autoresearch/completion.md` — completion flow to reuse
- `.agents/reference/self-improvement.md` — signals and routing to operationalize
- `.agents/scripts/autoagent-metric-helper.sh` — metric command the subagent invokes (t1867)

## Dependencies

- **Blocked by:** t1867 (metric helper — the subagent's METRIC_CMD), t1871 (template — defines the research program format the subagent reads)
- **Blocks:** t1869 (command dispatches to this subagent)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Re-read autoresearch.md structure closely |
| Main agent doc | 2h | Steps 0-3, YAML frontmatter, Quick Reference |
| signal-mining.md | 1h | Signal extraction commands and finding format |
| hypothesis-types.md | 1h | 6 types, progression, examples, overfitting test |
| safety.md | 45m | Exemptions, never-modify, regression gate |
| evaluation.md | 45m | Multi-trial, trajectory recording, failure analysis |
| **Total** | **~6h** | |
