---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1867: autoagent-metric-helper.sh — composite scorer for framework self-improvement

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** ai-interactive
- **Parent task:** t1866
- **Conversation context:** Part of autoagent implementation. The metric helper is the fitness function — everything else in the autoagent loop depends on being able to score a framework change numerically.

## What

A shell script at `.agents/scripts/autoagent-metric-helper.sh` that computes a composite fitness score for framework changes. The autoagent subagent uses this as its `METRIC_CMD` in research programs.

**Subcommands:**

| Subcommand | Output | Purpose |
|---|---|---|
| `score` | Single float (0.0-1.0) | Composite score for keep/discard |
| `comprehension` | Float (0.0-1.0) | Agent comprehension test pass rate |
| `lint` | Float (0.0-1.0) | Linter pass rate (shellcheck + markdownlint) |
| `tokens` | Float (ratio) | Token cost ratio vs baseline |
| `baseline` | JSON | Establish baseline measurements, write to sidecar |
| `compare` | JSON | Compare current vs baseline, show all sub-scores |

**Composite formula (v1):**

```
composite = 0.6 * comprehension_score + 0.3 * linter_score - 0.1 * max(0, token_cost_ratio - 1.0)
```

- `comprehension_score`: `agent-test-helper.sh run --suite <suite> --json | jq '.pass_rate'` (0.0-1.0)
- `linter_score`: fraction of files passing lint checks (0.0-1.0)
- `token_cost_ratio`: current avg tokens / baseline avg tokens (>1.0 means more expensive)

Weights configurable via `--weights "0.6,0.3,0.1"` flag.

**Baseline sidecar:** `todo/research/.autoagent-baseline.json` stores baseline measurements. Created by `baseline` subcommand, read by `score`/`compare`.

## Why

- The autoagent loop needs a single numeric fitness function to make keep/discard decisions
- Multiple signal sources (comprehension, lint, tokens) must be combined into one value
- Baseline comparison is essential — "did this change help?" requires knowing where we started
- The script must be reusable across different autoagent research programs with different weight emphases

## How (Approach)

**Pattern to follow:** `.agents/scripts/agent-test-helper.sh` for shell script structure, argument parsing, subcommand dispatch.

**Key implementation details:**

1. **Argument parsing:** Standard `case "$1" in` dispatch. Flags: `--suite <path>` (comprehension test suite), `--weights <w1,w2,w3>` (composite weights), `--baseline-file <path>` (baseline sidecar location), `--json` (machine-readable output).

2. **`cmd_baseline()`:** Run comprehension tests, count lintable files, measure token usage. Write JSON sidecar:
   ```json
   {
     "created": "ISO-8601",
     "comprehension_score": 0.85,
     "linter_score": 0.92,
     "avg_tokens": 1234,
     "files_checked": 45,
     "suite": ".agents/tests/agent-optimization.test.json"
   }
   ```

3. **`cmd_comprehension()`:** Wrapper around `agent-test-helper.sh`. If agent-test-helper.sh is not available or the suite doesn't exist, return 1.0 (neutral) with a warning to stderr. This keeps the metric helper functional even when the full test infrastructure isn't present.

4. **`cmd_lint()`:** Run shellcheck on `.agents/scripts/*.sh` and markdownlint on `.agents/**/*.md`. Count pass/fail. Return `passed / total` as float.

5. **`cmd_tokens()`:** If baseline exists, run comprehension suite and compare avg_response_chars to baseline. Return ratio. If no baseline, return 1.0 (neutral).

6. **`cmd_score()`:** Run all three sub-scorers, apply weights, output single float. Exit 0 on success, exit 1 on any sub-scorer failure.

7. **`cmd_compare()`:** Run `cmd_score()` and also output the JSON breakdown showing each sub-score and the delta from baseline.

**Error handling:**
- Missing `agent-test-helper.sh` → warn, return neutral score for that component
- Missing baseline → warn, skip token ratio (use 1.0)
- Linter not installed → warn, return 1.0 for lint score
- All warnings to stderr, scores to stdout

**ShellCheck compliance:** `local var="$1"` pattern, explicit returns, quoting, no bashisms beyond what's in `.agents/scripts/` convention.

## Acceptance Criteria

- [ ] Script exists at `.agents/scripts/autoagent-metric-helper.sh` and is executable
  ```yaml
  verify:
    method: bash
    run: "test -x .agents/scripts/autoagent-metric-helper.sh"
  ```
- [ ] ShellCheck passes with zero violations
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/autoagent-metric-helper.sh"
  ```
- [ ] `score` subcommand outputs a single float to stdout
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/autoagent-metric-helper.sh score 2>/dev/null | grep -qE '^[0-9]+\\.[0-9]+$'"
  ```
- [ ] `baseline` subcommand creates a JSON sidecar file
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/autoagent-metric-helper.sh baseline --baseline-file /tmp/test-baseline.json 2>/dev/null && test -f /tmp/test-baseline.json && python3 -c 'import json; json.load(open(\"/tmp/test-baseline.json\"))'"
  ```
- [ ] `--help` shows usage for all subcommands
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/autoagent-metric-helper.sh --help 2>&1 | grep -q 'score'"
  ```
- [ ] Graceful degradation: works even if agent-test-helper.sh or linters are missing (returns neutral scores with warnings)
  ```yaml
  verify:
    method: subagent
    prompt: "Read .agents/scripts/autoagent-metric-helper.sh and verify that each sub-scorer (comprehension, lint, tokens) has a fallback path that returns a neutral value (1.0 or similar) when the underlying tool is unavailable, with a warning to stderr."
  ```
- [ ] Follows existing script conventions (argument parsing, error output, return codes)
  ```yaml
  verify:
    method: subagent
    prompt: "Compare the structure of .agents/scripts/autoagent-metric-helper.sh with .agents/scripts/agent-test-helper.sh. Verify it follows the same patterns: case-based subcommand dispatch, local variable declarations, explicit return statements, stderr for diagnostics, stdout for data."
  ```

## Context & Decisions

- **Why a shell script not Python?** All existing aidevops helpers are shell scripts. Consistency matters more than convenience. The computation is simple arithmetic.
- **Why configurable weights?** Different autoagent research programs may emphasize different aspects (e.g., a self-healing focus cares more about comprehension; a simplification focus cares more about tokens).
- **Why graceful degradation?** The metric helper must work in partial environments (e.g., when agent-test-helper.sh test suites don't exist yet). Returning neutral scores with warnings allows the loop to proceed.
- **v2 signal sources** (session miner, pulse outcomes) are NOT in this task — they'll be added later when the basic loop is proven.

## Relevant Files

- `.agents/scripts/agent-test-helper.sh` — pattern to follow for script structure; also the comprehension test runner
- `.agents/tools/autoresearch/autoresearch/loop.md:109-112` — how METRIC_CMD is invoked (timeout, stdout parsing)
- `.agents/scripts/linters-local.sh` — existing linter runner to reference for lint scoring

## Dependencies

- **Blocked by:** nothing (first in chain)
- **Blocks:** t1868 (subagent uses this as METRIC_CMD)
- **External:** none (graceful degradation if tools missing)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Read agent-test-helper.sh structure |
| Implementation | 1.5h | Script with 6 subcommands |
| Testing | 15m | ShellCheck + manual test of each subcommand |
| **Total** | **~2h** | |
