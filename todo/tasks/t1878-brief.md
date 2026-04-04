---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1878: Ratchet Pattern for Code Quality Regression Prevention

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + ai-interactive
- **Conversation context:** Analysis of imbue-ai/mngr repo revealed their `test_ratchets.py` pattern — quality metrics that can only stay the same or decrease, never increase. We have linters but no directional quality metric. Ratchets prevent regression without requiring zero violations immediately.

## What

Add a ratchet quality check to `linters-local.sh` that:
1. Counts known anti-patterns across `.agents/scripts/`
2. Compares against a stored baseline in `.agents/configs/ratchets.json`
3. Fails if any count increases (regression)
4. Provides `--update-baseline` to lock in improvements
5. Reports which patterns improved and which regressed

The experience: a developer runs `linters-local.sh`, ratchets pass if they haven't introduced new violations, fail with a clear message if they have. On improvement, they run `--update-baseline` to lock in the new lower count.

## Why

Linters catch syntax issues but don't prevent gradual quality degradation. A script that "passes shellcheck" can still be full of anti-patterns (direct `$1` usage, missing returns, hardcoded paths). Ratchets formalize "the codebase only gets better" — each commit must be at least as good as the last, measured by concrete counts.

This is the highest-ROI quality improvement identified: small implementation, prevents regression, works incrementally (no "fix everything at once" requirement).

## How (Approach)

### 1. Define ratchet patterns

Add a `ratchet_check()` function to `linters-local.sh` (or a new `ratchet-check.sh` sourced from it). Patterns to track:

| Pattern | What it catches | How to count |
|---------|----------------|--------------|
| `bare_positional_params` | `$1`, `$2` etc. used directly in function bodies (should be `local var="$1"`) | `rg '\$[1-9]' --type sh .agents/scripts/ -c` minus known exceptions |
| `missing_return` | Functions without explicit `return 0` or `return 1` | Parse functions, check last statement |
| `hardcoded_aidevops_path` | Literal `~/.aidevops` or `/Users/` instead of `${HOME}/.aidevops` or variable | `rg '~/.aidevops\|/Users/' --type sh .agents/scripts/ -c` minus shebangs/comments |
| `broad_catch` | `\|\| true` or `2>/dev/null` without specific error handling | `rg '\|\| true\|2>/dev/null' --type sh .agents/scripts/ -c` |
| `unquoted_variable` | ShellCheck SC2086 violations (count from shellcheck output) | `shellcheck --format=json .agents/scripts/*.sh \| jq '[.[] \| select(.code==2086)] \| length'` |

### 2. Baseline file

`.agents/configs/ratchets.json`:
```json
{
  "version": 1,
  "updated": "2026-04-03T00:00:00Z",
  "ratchets": {
    "bare_positional_params": { "count": 142, "description": "$1/$2 used directly in function bodies" },
    "missing_return": { "count": 87, "description": "Functions without explicit return" },
    "hardcoded_aidevops_path": { "count": 23, "description": "Literal ~/.aidevops instead of variable" },
    "broad_catch": { "count": 56, "description": "|| true or 2>/dev/null without specific handling" },
    "unquoted_variable_sc2086": { "count": 340, "description": "ShellCheck SC2086 violations" }
  }
}
```

### 3. Integration

- `linters-local.sh` calls `ratchet_check()` after shellcheck/markdownlint
- Reports: `PASS: bare_positional_params 142 -> 138 (improved by 4)` or `FAIL: bare_positional_params 142 -> 145 (regressed by 3)`
- Exit code: 0 if all ratchets pass, 1 if any regressed
- `--update-baseline` mode: re-counts everything, writes new baseline, shows diff

### 4. Safeguards (per user's concern about false positives)

- Each pattern has an **exceptions file** (`.agents/configs/ratchet-exceptions/{pattern}.txt`) listing known false positives (line-by-line: `file:line reason`)
- Exception count is subtracted from raw count
- First run (`--init-baseline`) sets the baseline from current state — no immediate failures
- Ratchets are advisory warnings when `--strict` is not passed (default for interactive), blocking only in CI/pre-commit mode

Key files:
- `.agents/scripts/linters-local.sh` — add ratchet integration
- `.agents/configs/ratchets.json` — NEW baseline file
- `.agents/configs/ratchet-exceptions/` — NEW exceptions directory (optional)

Pattern to follow: existing shellcheck integration in `linters-local.sh`.

## Acceptance Criteria

- [ ] Ratchet baseline file exists at `.agents/configs/ratchets.json`
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/configs/ratchets.json && jq .version .agents/configs/ratchets.json"
  ```
- [ ] `linters-local.sh` includes ratchet check that compares current counts against baseline
  ```yaml
  verify:
    method: codebase
    pattern: "ratchet"
    path: ".agents/scripts/linters-local.sh"
  ```
- [ ] At least 3 anti-patterns tracked with counts
  ```yaml
  verify:
    method: bash
    run: "jq '.ratchets | length' .agents/configs/ratchets.json | awk '{exit ($1 >= 3) ? 0 : 1}'"
  ```
- [ ] `--update-baseline` flag works (re-counts and writes new baseline)
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --update-baseline --dry-run 2>&1 | grep -q 'ratchet'"
  ```
- [ ] Regression produces clear error message identifying which pattern regressed and by how much
  ```yaml
  verify:
    method: subagent
    prompt: "Review the ratchet check output format. Does it clearly show which patterns regressed, by how much, and what the baseline was?"
    files: ".agents/scripts/linters-local.sh"
  ```
- [ ] ShellCheck clean on modified scripts

## Context & Decisions

- Inspired by imbue-ai/mngr `test_ratchets.py` pattern
- Default mode is advisory (warnings), not blocking — to avoid disrupting productivity. `--strict` for CI.
- Exception files prevent false positives from blocking work
- `--init-baseline` sets initial counts from current state — no need to fix everything at once
- Patterns chosen based on actual anti-patterns observed in our codebase (from build.txt error prevention rules)
- User explicitly cautioned about false positives disrupting productivity — conservative approach preferred

## Relevant Files

- `.agents/scripts/linters-local.sh` — integration point
- `.agents/configs/ratchets.json` — NEW baseline
- `.agents/configs/ratchet-exceptions/` — NEW exceptions dir
- `.agents/prompts/build.txt` — source of anti-pattern rules (lines referencing error patterns)

## Dependencies

- **Blocked by:** nothing
- **Blocks:** nothing
- **External:** shellcheck, rg (ripgrep) must be installed

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Read linters-local.sh, identify anti-patterns |
| Implementation | 3h | Counting functions, baseline management, integration |
| Testing | 40m | Run against real codebase, verify counts, test regression detection |
| **Total** | **4h** | |
