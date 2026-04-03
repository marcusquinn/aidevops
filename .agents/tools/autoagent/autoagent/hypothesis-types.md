# Autoagent — Hypothesis Types

Sub-doc for `autoagent.md`. Loaded during Step 2 (Loop) for hypothesis generation.

---

## The 6 Hypothesis Types

| # | Type | Edit surface | Primary signal source |
|---|------|-------------|----------------------|
| 1 | Self-healing | Scripts, error handlers, workflow docs | Error-feedback patterns, session failures |
| 2 | Tool optimization | Helper scripts, tool docs | Command frequency, error rates, timeout patterns |
| 3 | Instruction refinement | Agent `.md` files, prompts | Comprehension test results, token usage |
| 4 | Tool creation | New helper scripts | Capability gaps from failed tasks |
| 5 | Agent composition | Subagent routing, model tiers | Task taxonomy, cost/quality tradeoffs |
| 6 | Workflow optimization | Command docs, routines | Pulse throughput, PR merge rates |

---

## Type Definitions

### Type 1: Self-Healing

**Definition:** Fix recurring failure patterns so the framework recovers automatically instead of requiring manual intervention.

**Edit surface:**
- Helper scripts: add retry logic, better error messages, fallback paths
- Workflow docs: add explicit recovery steps for known failure modes
- Error handlers: convert silent failures to actionable errors

**Signal sources:** Error-feedback patterns, session miner failures, pulse dispatch failures

**Examples of good hypotheses:**
- "Add retry loop (3x) to `gh` API calls in `dispatch-helper.sh` to handle transient 503s"
- "Add `set -e` guard to `pre-edit-check.sh` to prevent silent failures on missing git"
- "Document recovery steps for `worktree already exists` error in `git-workflow.md`"

**Examples of bad hypotheses:**
- "Rewrite dispatch-helper.sh from scratch" (too broad, high constraint-failure risk)
- "Add logging to every function" (low signal value, high noise)

**Overfitting test:** If this exact error pattern disappeared tomorrow, would the fix still improve the framework? If yes → keep. If no → too narrow.

---

### Type 2: Tool Optimization

**Definition:** Improve existing helper scripts to reduce failure rates, execution time, or token usage.

**Edit surface:**
- Helper scripts: optimize command sequences, reduce subprocess spawning
- Tool docs: clarify usage patterns that cause errors
- Configuration: tune timeouts, retry counts, batch sizes

**Signal sources:** Command error rates, timeout patterns, linter violations

**Examples of good hypotheses:**
- "Replace sequential `gh api` calls with `--jq` flag to reduce subprocess count in `issue-sync-helper.sh`"
- "Add `--no-pager` to `git log` calls in `session-miner-pulse.sh` to prevent TTY hangs"
- "Cache `gh auth status` result in `pulse-wrapper.sh` instead of calling per-repo"

**Examples of bad hypotheses:**
- "Rewrite helper in Python" (language change = architectural decision, not optimization)
- "Add more comments" (no metric impact)

**Overfitting test:** Does this optimization apply to the general pattern, or only to one specific invocation?

---

### Type 3: Instruction Refinement

**Definition:** Improve agent `.md` files and prompts to increase comprehension test pass rates and reduce token usage.

**Edit surface:**
- Agent `.md` files: consolidate redundant rules, remove low-value instructions, shorten verbose phrasing
- `prompts/build.txt`: merge thin sections, replace inline code with references
- Subagent docs: improve progressive disclosure structure

**Signal sources:** Comprehension test failures, token ratio from metric, git churn on agent files

**Examples of good hypotheses:**
- "Consolidate the two 'Read before Edit' rules in build.txt into one authoritative rule"
- "Replace 3-sentence webfetch warning with 1-sentence rule + link to reference"
- "Move inline bash examples in `git-workflow.md` to a reference file, replace with `file:line` refs"

**Examples of bad hypotheses:**
- "Remove all security rules" (blocked by safety constraints)
- "Add more examples to every rule" (increases tokens, likely hurts metric)

**Overfitting test:** If this exact comprehension test disappeared, would the instruction change still make the framework clearer? If yes → keep.

---

### Type 4: Tool Creation

**Definition:** Create new helper scripts to fill capability gaps identified from failed tasks.

**Edit surface:**
- New scripts in `.agents/scripts/`
- New reference docs in `.agents/reference/`
- New command docs in `.agents/scripts/commands/`

**Signal sources:** Capability gaps from failed tasks, repeated manual workarounds in session transcripts

**Examples of good hypotheses:**
- "Create `worktree-status-helper.sh` to list all active worktrees with their task IDs and ages"
- "Create `pr-health-helper.sh` to check PR age, review status, and CI state in one command"
- "Create `signal-aggregator.sh` to run all signal sources and output ranked findings JSON"

**Examples of bad hypotheses:**
- "Create a helper for every existing command" (no signal, preemptive bloat)
- "Create a GUI dashboard" (out of scope for CLI framework)

**Overfitting test:** Has this capability gap appeared in at least 2 independent signal sources? If not → defer.

---

### Type 5: Agent Composition

**Definition:** Improve subagent routing, model tier assignments, or agent boundaries to reduce cost and improve quality.

**Edit surface:**
- `reference/agent-routing.md`: routing table updates
- `reference/task-taxonomy.md`: model tier assignments
- Subagent index: add/remove/rename subagents
- Agent frontmatter: change `model:` tier

**Signal sources:** Task taxonomy analysis, cost/quality tradeoffs from pulse logs, PR merge rates by agent

**Examples of good hypotheses:**
- "Downgrade `code-simplifier` default tier from sonnet to haiku — task is pattern-matching, not reasoning"
- "Add explicit routing rule for 'audit' tasks → `auditing` subagent (currently falls through to general)"
- "Split `build-agent.md` into separate 'compose' and 'review' agents — different tools needed"

**Examples of bad hypotheses:**
- "Use opus for everything" (cost increase without signal)
- "Merge all subagents into one" (destroys progressive disclosure)

**Overfitting test:** Does this routing change apply to a class of tasks, or just one specific task?

---

### Type 6: Workflow Optimization

**Definition:** Improve command docs and routines to increase pulse throughput and PR merge rates.

**Edit surface:**
- Command docs in `.agents/scripts/commands/`
- Workflow docs in `.agents/workflows/`
- Routine configs in `.agents/configs/`

**Signal sources:** Pulse throughput metrics, PR merge rates, time-to-merge distributions

**Examples of good hypotheses:**
- "Add explicit 'check for existing PR before creating' step to `full-loop.md` to prevent duplicate PRs"
- "Move review bot polling from 60s to 30s intervals in `review-bot-gate.md` — bots respond faster"
- "Add `--skip-preflight` shortcut to `full-loop.md` for hotfix tasks (currently requires manual flag)"

**Examples of bad hypotheses:**
- "Remove all quality gates" (blocked by safety constraints)
- "Add more steps to every workflow" (increases complexity without signal)

**Overfitting test:** Does this workflow change improve the general case, or only a specific edge case?

---

## Progression Strategy

Apply hypothesis types in phases based on iteration count and available signals:

| Phase | Iterations | Primary types | Rationale |
|-------|-----------|--------------|-----------|
| 1 | 1–5 | Self-healing (1), Instruction refinement (3) | Low risk, high signal, direct feedback loop |
| 2 | 6–15 | Tool optimization (2), Instruction refinement (3) | Systematic single-variable changes |
| 3 | 16–25 | Tool creation (4), Agent composition (5) | Higher complexity, builds on earlier findings |
| 4 | 26–35 | Workflow optimization (6), combinations | Cross-cutting changes |
| 5 | 36+ | Simplification across all types | Equal-or-better with less is always a win |

**Override rules:**
- If `HYPOTHESIS_TYPES` is set in the research program, only use listed types regardless of phase
- If a signal source produces high-priority findings for a specific type, prioritize that type regardless of phase
- Never repeat a discarded hypothesis (check `FAILED_HYPOTHESES`)

---

## Hypothesis Generation Rules

1. **One change per hypothesis.** Never bundle multiple changes — makes keep/discard ambiguous.
2. **Prefer high-impact, low-risk changes.** Estimate constraint-failure probability before applying.
3. **Use signal findings as input.** Hypotheses without signal backing are lower priority.
4. **Check safety constraints first.** Load `autoagent/safety.md` before generating hypotheses that touch sensitive files.
5. **Simplification is always valid.** Less code with equal-or-better metric is a win at any phase.

---

## Overfitting Test (Universal)

Before committing to any hypothesis, ask: **"If this exact test/signal disappeared, would this still be a worthwhile framework improvement?"**

- **Yes** → proceed (generalizable improvement)
- **No** → discard (overfitting to current test suite or signal)

This prevents the autoagent from gaming its own metric.
