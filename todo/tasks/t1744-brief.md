<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1744: Autoresearch Subagent — Autonomous Experiment Loop Runner

## Origin

- **Created:** 2026-04-01
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + AI (interactive)
- **Parent task:** t1741
- **Conversation context:** Core implementation of the autonomous experiment loop inspired by karpathy/autoresearch's program.md pattern and binary keep/discard decision model.

## What

Create `.agents/tools/autoresearch/autoresearch.md` — the subagent that runs the autonomous experiment loop. This is the engine that reads a research program, generates hypotheses, modifies code, measures results, and iterates within budget constraints.

## Why

This is the core deliverable of the autoresearch epic. Without it, the command doc (t1743) has nothing to dispatch to. The subagent closes the gap between existing analysis-only tools and autonomous optimization.

## How (Approach)

### The experiment loop

```
SETUP:
  1. Read research program file
  2. Create experiment worktree (experiment/{name})
  3. Register in mailbox: mail-helper.sh register --agent "autoresearch-{name}" --role worker --worktree {path}
  4. Recall cross-session memory for this research domain
  5. Check mailbox for peer discoveries (if concurrent agents exist)
  6. Read previous results.tsv if resuming
  7. Run baseline measurement (first iteration only)

LOOP (until budget exhausted):
  8. Check mailbox for new peer discoveries (mail-helper.sh check --unread-only)
     - Incorporate peer findings into hypothesis generation context
  9. Generate hypothesis
     - Read current code state
     - Consider: what hasn't been tried, what worked in memory, program hints, peer discoveries
     - Prioritize: high-expected-impact changes first, diminishing returns later
  10. Modify target files in worktree
  11. Run constraint checks (each constraint command must exit 0)
      - If constraint fails → revert, log "constraint_fail", skip to step 9
  12. Run metric command, extract numeric value
      - If measurement crashes → revert, log "crash", attempt diagnosis, skip to step 9
  13. Compare to current best
      - If improved (metric moves in desired direction) → git commit, update best, log "keep"
      - If equal or worse → git reset --hard, log "discard"
  14. Send discovery to peers via mailbox:
      mail-helper.sh send --to "broadcast" --type discovery \
        --payload '{"hypothesis":"...","status":"keep|discard","metric_delta":...,"files_changed":[...]}' \
        --convoy "autoresearch-{campaign-id}"
  15. Store finding in cross-session memory
  16. Check budget (wall clock, iteration count, goal condition)
      - If any budget exceeded → exit loop
  17. GOTO 8

COMPLETION:
  18. Write results summary (total iterations, improvement, best metric, key findings)
  19. Create PR from experiment branch with summary in body
  20. Store final learnings in memory
  21. Deregister from mailbox: mail-helper.sh deregister --agent "autoresearch-{name}"
```

### Concurrency modes

The subagent supports three concurrency strategies, selected via the research program or CLI flags:

**Sequential (default):** One hypothesis at a time. Simplest, lowest cost. Default for single-dimension research.

**Population-based (`--population N`):** Within a single agent session, generate N hypotheses per iteration, apply each to a temporary worktree fork, measure all in parallel, keep the best. No inter-agent communication needed — this is internal parallelism.

```
Iteration K:
  Generate 4 hypotheses from current best state
  Fork experiment worktree → 4 temp copies
  Run constraint + metric on all 4 in parallel (via background bash jobs)
  Compare all 4 results
  Best result → commit to experiment branch
  Discard other 3 temp worktrees
  Log all 4 results to results.tsv (status: keep for winner, discard for others)
```

Trade-offs: N× measurement cost per iteration (but parallel, same wall-clock), N× hypothesis generation tokens. Benefit: N× exploration per iteration, faster convergence on complex search spaces.

**Multi-dimension (`--dimensions "dim1,dim2,dim3"`):** The orchestrator (command doc) dispatches separate agent sessions, each targeting non-overlapping file sets. Agents communicate via the mailbox system using `discovery` messages grouped by `convoy` ID.

```
Orchestrator splits research program into dimension-specific sub-programs:
  Dimension A: build-perf → modifies webpack.config.js, src/utils/
  Dimension B: test-speed → modifies jest.config.ts, tests/
  Dimension C: bundle-size → modifies rollup.config.js, src/index.ts

Each dimension gets:
  - Own worktree: experiment/{campaign}-{dimension}
  - Own results.tsv
  - Shared convoy ID for mailbox grouping
  - Non-overlapping file targets (enforced — overlapping files trigger error)
```

### Mailbox integration

The mailbox (`mail-helper.sh`) provides inter-agent communication for concurrent autoresearch sessions:

| Action | When | Mailbox call |
|---|---|---|
| Register | Loop setup | `register --agent "autoresearch-{name}" --role worker --worktree {path}` |
| Check inbox | Before each hypothesis | `check --agent "autoresearch-{name}" --unread-only` |
| Send discovery | After each keep/discard | `send --type discovery --convoy "autoresearch-{id}" --payload {JSON}` |
| Deregister | Loop completion | `deregister --agent "autoresearch-{name}"` |

Discovery payload format:

```json
{
  "campaign": "autoresearch-widget-2026-04-01",
  "dimension": "build-perf",
  "hypothesis": "removed lodash, replaced with native Array methods",
  "status": "keep",
  "metric_name": "build_time_s",
  "metric_before": 12.4,
  "metric_after": 11.1,
  "metric_delta": -1.3,
  "files_changed": ["src/utils/index.ts", "package.json"],
  "iteration": 5,
  "timestamp": "2026-04-01T10:48:00Z"
}
```

The `convoy` field groups all messages from one research campaign — reviewable as a thread after completion. In sequential mode with no concurrent peers, mailbox calls are skipped (check returns empty, discoveries go to memory only).

### Hypothesis generation strategy

The researcher model should follow a progression:
1. **Low-hanging fruit first** — obvious improvements from hints, memory recalls, code smells
2. **Systematic exploration** — vary one parameter at a time, measure effect
3. **Combination attempts** — combine two individually-successful changes
4. **Radical departures** — try fundamentally different approaches if incremental gains stall
5. **Simplification** — try removing things; equal-or-better with less code is a win (Karpathy principle)

### Crash recovery

- If the subagent session crashes mid-loop, the worktree and results.tsv persist
- On resume (`/autoresearch --resume`), read results.tsv to reconstruct state
- The current best is always the HEAD of the experiment branch
- Uncommitted changes on crash → `git reset --hard` to last known good state

### YAML frontmatter for subagent

```yaml
---
description: Autonomous experiment loop runner for code/agent/config optimization
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---
```

Reference: karpathy/autoresearch `program.md` for the loop design pattern.
Reference: `.agents/tools/build-agent/agent-testing.md` for measurement integration.

## Acceptance Criteria

- [ ] Subagent file exists at `.agents/tools/autoresearch/autoresearch.md`
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Implements full loop: setup → hypothesis → modify → constrain → measure → keep/discard → log → repeat
  ```yaml
  verify:
    method: codebase
    pattern: "hypothesis|constraint|measure|keep|discard|revert"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Creates experiment worktree using existing worktree workflow
  ```yaml
  verify:
    method: codebase
    pattern: "experiment/|worktree"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Budget enforcement: wall-clock, iteration count, and goal-based termination
  ```yaml
  verify:
    method: codebase
    pattern: "timeout|max_iterations|budget"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Results logged to results.tsv with: commit, metric, status, hypothesis, timestamp
- [ ] Creates PR on completion with results summary in body
- [ ] Crash recovery: resume from results.tsv + worktree state
- [ ] Cross-session memory integration (store and recall)
- [ ] Mailbox integration: register/deregister, check inbox, send discoveries
  ```yaml
  verify:
    method: codebase
    pattern: "mail-helper|discovery|convoy|register.*agent"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Population-based mode: generate N hypotheses, fork N worktrees, measure in parallel, keep best
  ```yaml
  verify:
    method: codebase
    pattern: "population|parallel.*hypothesis|fork.*worktree"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Multi-dimension mode: non-overlapping file targets, separate worktrees per dimension
  ```yaml
  verify:
    method: codebase
    pattern: "dimension|non-overlapping|file.*target"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Mailbox calls skipped gracefully when no concurrent peers exist
- [ ] Lint clean (markdownlint)

## Context & Decisions

- **Subagent, not a shell script**: the loop requires creative reasoning (hypothesis generation), code understanding (what to modify), and interpretation (why did the metric change). This is fundamentally an LLM task, not a deterministic script.
- **Git as state machine**: the experiment branch HEAD is always the best known state. `git commit` = keep, `git reset --hard` = discard. No separate state file needed for the experiment state — git IS the state.
- **Constraint checks before metric**: don't waste time measuring if tests are broken. Fail fast on constraint violations.
- **Simplification as a positive outcome**: removing code and getting equal or better results is explicitly encouraged. This aligns with aidevops's efficiency-drive aims.
- **Mailbox for concurrent peers, memory for cross-session**: live concurrent agents share via mailbox (real-time). Across sessions, memory carries forward findings. Both use the same discovery content format.
- **Population-based is internal, multi-dimension is inter-agent**: population mode is one orchestrator managing N temp worktrees (no mailbox). Multi-dimension mode is N independent agents with mailbox coordination. Don't conflate them.
- **Non-overlapping files enforced**: multi-dimension mode errors if two dimensions claim overlapping file targets. This prevents merge conflicts and makes parallel execution safe.

## Relevant Files

- `.agents/scripts/commands/full-loop.md` — autonomous code work pattern
- `.agents/tools/build-agent/agent-review.md` — analysis pattern to extend
- `.agents/tools/build-agent/agent-testing.md` — measurement harness
- `.agents/workflows/git-workflow.md` — worktree creation conventions
- `.agents/scripts/mail-helper.sh` — inter-agent mailbox (discovery, convoy, register/deregister)
- `~/.aidevops/.agent-workspace/mail/mailbox.db` — SQLite mailbox database

## Dependencies

- **Blocked by:** t1742 (schema), t1743 (command doc)
- **Blocks:** t1745 (agent optimization needs this), t1747 (results tracking)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review full-loop, agent-testing, git-workflow |
| Loop design | 1h | State machine, transitions, edge cases |
| Hypothesis strategy | 1h | Progression logic, memory integration |
| Crash recovery | 30m | Resume, state reconstruction |
| Mailbox integration | 1h | Register, check, send, deregister, convoy grouping |
| Concurrency modes | 1.5h | Population-based logic, multi-dimension dispatch |
| Write subagent | 1.5h | Full markdown with all sections |
| Review | 30m | Lint, cross-reference checks |
| **Total** | **~8h** | |
