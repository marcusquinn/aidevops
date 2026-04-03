# Autoagent — Hypothesis Types

Sub-doc for `autoagent.md`. Loaded during Step 2 loop for hypothesis generation.

---

## The 6 Hypothesis Types

| Type | Edit surface | Signal source | Example |
|------|-------------|---------------|---------|
| Self-healing | Scripts, error handlers, workflow docs | Error-feedback patterns, session failures | Fix recurring `read:file_not_found` pattern in build.txt |
| Tool optimization | Helper scripts, tool docs | Command frequency, error rates, timeout patterns | Reduce `webfetch` failure rate by adding URL validation |
| Instruction refinement | Agent `.md` files, prompts | Comprehension test results, token usage | Consolidate redundant file-discovery rules |
| Tool creation | New helper scripts | Capability gaps from failed tasks | Create missing helper for a repeated manual pattern |
| Agent composition | Subagent routing, model tiers | Task taxonomy, cost/quality tradeoffs | Change default tier for a task category |
| Workflow optimization | Command docs, routines | Pulse throughput, PR merge rates | Modify dispatch pattern to reduce failure rate |

---

## Type Definitions

### 1. Self-Healing

**Definition:** Fix a recurring failure mode so it stops happening automatically.

**Edit surface:** Scripts that fail, workflow docs that cause misexecution, error handlers that don't recover.

**Good hypothesis:** "Add URL validation guard to webfetch calls in build.txt to prevent the 94% guessed-URL failure rate."

**Bad hypothesis:** "Improve error handling generally." (too vague, no specific file or failure)

**Overfitting test:** If this exact error pattern disappeared tomorrow, would the fix still be a worthwhile framework improvement? If yes → keep. If no → too narrow.

### 2. Tool Optimization

**Definition:** Make an existing tool faster, more reliable, or easier to use correctly.

**Edit surface:** Helper scripts (`.agents/scripts/*.sh`), tool documentation, command wrappers.

**Good hypothesis:** "Add `--json` flag to `session-miner-pulse.sh` to enable structured output for signal mining."

**Bad hypothesis:** "Rewrite session-miner-pulse.sh in Python." (architectural decision, not optimization)

**Overfitting test:** Does this optimization help the metric without breaking other tools that depend on the same script?

### 3. Instruction Refinement

**Definition:** Make agent instructions clearer, shorter, or more precise so models follow them correctly.

**Edit surface:** Agent `.md` files, `prompts/build.txt`, workflow docs.

**Good hypothesis:** "Merge the two 'Read before Edit' rules in build.txt into one — they say the same thing with different wording."

**Bad hypothesis:** "Add more examples to build.txt." (more is not better; test first)

**Overfitting test:** "If this exact test disappeared, would this still be a worthwhile framework improvement?" If the instruction only helps one specific test case → too narrow.

### 4. Tool Creation

**Definition:** Create a new helper script for a pattern that currently requires manual steps.

**Edit surface:** New files in `.agents/scripts/`, new command docs in `.agents/scripts/commands/`.

**Good hypothesis:** "Create `autoagent-signal-aggregator.sh` to combine findings from all signal sources into a single ranked list."

**Bad hypothesis:** "Create a tool for everything." (tool creation has high cost; only when pattern repeats 3+ times)

**Overfitting test:** Has this manual pattern appeared in 3+ different sessions or tasks? If yes → tool creation is justified.

### 5. Agent Composition

**Definition:** Change how agents are routed, composed, or tiered to improve cost/quality tradeoffs.

**Edit surface:** Subagent routing tables, model tier assignments, dispatch logic.

**Good hypothesis:** "Route comprehension-test tasks to haiku instead of sonnet — they're pattern-matching, not reasoning."

**Bad hypothesis:** "Use opus for everything." (cost explosion, not an improvement)

**Overfitting test:** Does this routing change improve the metric without degrading quality on other task types?

### 6. Workflow Optimization

**Definition:** Change a workflow or command doc to improve throughput, reduce failures, or eliminate unnecessary steps.

**Edit surface:** Command docs (`.agents/scripts/commands/*.md`), workflow docs (`.agents/workflows/*.md`), routine docs.

**Good hypothesis:** "Remove the 'ask user for confirmation' step from the preflight workflow — it blocks headless dispatch."

**Bad hypothesis:** "Simplify the full-loop workflow." (too vague; identify the specific step causing friction)

**Overfitting test:** Does removing/changing this step break any other workflow that depends on it?

---

## Progression Strategy

| Phase | Iterations | Primary types | Rationale |
|-------|-----------|---------------|-----------|
| 1 | 1–5 | Self-healing, Instruction refinement | Low risk, high signal, direct feedback loop |
| 2 | 6–15 | Tool optimization, Instruction refinement | Systematic single-variable changes |
| 3 | 16–25 | Tool creation, Agent composition | Higher complexity, builds on earlier findings |
| 4 | 26–35 | Workflow optimization, combinations | Cross-cutting changes |
| 5 | 36+ | Simplification across all types | Equal-or-better with less is always a win |

**Progression rules:**

1. Never skip to a later phase if earlier phases still have high-severity findings.
2. Combination hypotheses (phase 26–35) must combine two individually-successful changes.
3. Simplification (phase 36+) is always valid — less code with equal-or-better metric is a win.
4. If a phase produces 3+ consecutive discards, advance to the next phase.

---

## Hypothesis Generation Rules

1. **Never repeat a discarded hypothesis** — check FAILED_HYPOTHESES before generating.
2. **One change per hypothesis** — single-variable changes are measurable; combinations are not.
3. **Specific file + specific change** — "improve build.txt" is not a hypothesis; "remove lines 47-52 of build.txt (duplicate rule)" is.
4. **Signal-driven** — prefer hypotheses that address a finding in SIGNAL_FINDINGS.
5. **Safety-gated** — reject any hypothesis that touches NEVER_MODIFY files or ELEVATED_ONLY files at standard safety level.

---

## Overfitting Test (Universal)

Before committing to any hypothesis, ask:

> "If this exact test case disappeared from the metric suite, would this change still be a worthwhile framework improvement?"

- **Yes** → proceed. The change has intrinsic value.
- **No** → discard. The change is overfitted to the metric, not the framework.

This test prevents gaming the metric at the expense of real framework quality.
