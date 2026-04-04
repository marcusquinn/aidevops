<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1745: Agent Optimization Integration — Autoresearch + agent-test-helper.sh

## Origin

- **Created:** 2026-04-01
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + AI (interactive)
- **Parent task:** t1741
- **Conversation context:** Agent optimization identified as the highest-value first use case because all measurement infrastructure already exists. Recent work on oauth-pool-unknown-provider branch adds capabilities that could be optimized.

## What

Create a predefined agent optimization research program and the integration layer between the autoresearch subagent and `agent-test-helper.sh`. This makes agent instruction optimization a first-class, turnkey use case — not just a generic "fill in your own metric command."

Deliverables:
1. Predefined research program: `todo/research/agent-optimization.md` (or embedded in the subagent as a known domain)
2. Metric extraction from `agent-test-helper.sh` output (pass rate, token count)
3. Multi-metric handling (optimize token count WHILE maintaining pass rate)
4. Integration with `simplification-state.json` to avoid re-testing unchanged files

## Why

Agent optimization is the proof case for autoresearch because:
- `agent-test-helper.sh` already provides the measurement harness
- The metric is clear: same pass rate with fewer tokens = better
- The target files are well-defined (`.agents/*.md`)
- It directly improves aidevops ROI (cheaper, faster agents)
- It dogfoods autoresearch on itself

## How (Approach)

### Predefined research program

```markdown
---
name: agent-optimization
mode: in-repo
target_repo: .
---
# Research: Agent Instruction Optimization

## Target
files: .agents/{target-agent}.md
branch: experiment/optimize-{target-agent}

## Metric
command: agent-test-helper.sh run --suite {suite} --json
name: composite_score
direction: higher
formula: pass_rate * (1 - 0.3 * token_ratio)
# pass_rate: percentage of tests passing (0-1)
# token_ratio: current_tokens / baseline_tokens (lower = better)
# Weights: 70% pass rate preservation, 30% token reduction

## Constraints
- Pass rate must not drop below baseline - 5%
- No removal of security-related instructions
- No removal of file operation rules
- Agent must still reference correct file paths

## Models
researcher: sonnet
target: sonnet
```

### Multi-metric composite score

Agent optimization has two competing objectives:
- **Reduce tokens** (fewer instructions = cheaper per invocation)
- **Maintain quality** (tests still pass)

The composite score formula balances these: `pass_rate * (1 - 0.3 * token_ratio)`. This means:
- 100% pass rate, 70% of baseline tokens → score 1.0 * (1 - 0.3 * 0.7) = 0.79
- 100% pass rate, 100% of baseline tokens → score 1.0 * (1 - 0.3 * 1.0) = 0.70
- 95% pass rate, 50% of baseline tokens → score 0.95 * (1 - 0.3 * 0.5) = 0.808

So significant token reduction with minor quality loss can still win.

### Metric extraction from agent-test-helper.sh

The subagent runs `agent-test-helper.sh run --suite <suite> --json` and parses:
- `pass_count / total_count` → pass rate
- Sum of response token counts → total tokens
- Compare to baseline values established on first run

### Hypothesis types for agent optimization

1. **Consolidate redundant rules** — merge similar instructions into one
2. **Remove low-value instructions** — delete rules that don't affect test outcomes
3. **Restructure for clarity** — rewrite verbose sections concisely
4. **Move to subagent** — extract domain-specific content to subagent files
5. **Replace inline code with references** — `rg "pattern"` instead of code blocks
6. **Simplify examples** — shorter examples that convey the same information

### Integration with simplification-state.json

Before generating hypotheses, check if the target agent file's hash matches the last-tested hash in `simplification-state.json`. If it does, skip — nothing changed since last optimization. If it doesn't, or no entry exists, proceed with optimization.

After a successful optimization session, update the hash.

## Acceptance Criteria

- [ ] Predefined agent optimization research program exists
  ```yaml
  verify:
    method: codebase
    pattern: "agent-optimization|agent.*instruction.*optim"
    path: ".agents/tools/autoresearch/"
  ```
- [ ] Metric extraction parses agent-test-helper.sh JSON output
  ```yaml
  verify:
    method: codebase
    pattern: "agent-test-helper.*json|pass_rate|token_count"
    path: ".agents/tools/autoresearch/"
  ```
- [ ] Composite score formula handles both pass rate and token count
- [ ] Constraints prevent removal of security/safety instructions
- [ ] Integration with simplification-state.json for dedup
- [ ] Works with existing test suites in `.agents/tests/`
- [ ] Lint clean

## Context & Decisions

- Composite score over separate metrics: two independent metrics create ambiguity (is "95% pass, 50% tokens" better than "100% pass, 90% tokens"?). A weighted formula makes every comparison unambiguous.
- 70/30 weighting (quality/size): quality is more important than size. A 5% quality drop for 50% token savings is acceptable; a 20% quality drop is never acceptable regardless of savings.
- Security instructions exempt: certain instructions (credential handling, secret protection, file operation rules) must never be removed by automated optimization. The constraint list makes this explicit.

## Relevant Files

- `.agents/tools/build-agent/agent-testing.md` — test framework reference
- `.agents/tools/build-agent/agent-review.md` — review checklist (hypothesis source)
- `.agents/scripts/commands/code-simplifier.md` — existing simplification approach
- `.agents/configs/simplification-state.json` — hash registry

## Dependencies

- **Blocked by:** t1744 (needs the loop runner)
- **Blocks:** nothing

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review agent-testing output format, simplification state |
| Composite metric design | 30m | Formula, weighting, edge cases |
| Predefined program | 1h | Program file + constraint definitions |
| Integration code | 30m | JSON parsing, hash checking |
| Testing | 30m | Run against one agent with one suite |
| **Total** | **~3h** | |
