---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2159: Replace shell-complexity bump-and-ratchet treadmill with per-function regression check

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:t2153-followup
- **Created by:** ai-interactive (marcusquinn directing)
- **Parent task:** none
- **Conversation context:** While diagnosing why PR #19456 (planning-only, briefs + TODO) was failing CI, discovered that the `Complexity Analysis` job in `.github/workflows/code-quality.yml` had failed on every PR opened against main since 2026-04-17 ~00:46Z (5 consecutive run failures: 24541744895, 24541756977, 24541769836, 24541780357, 24541783024). Root cause: 29 violations vs threshold 28, drift introduced by recently-merged PRs that didn't add explicit complexity violations themselves. Bumped to 31 in #19457 as immediate unblock. The deeper issue: `.agents/configs/complexity-thresholds.conf` shows 35+ bump entries for `FUNCTION_COMPLEXITY_THRESHOLD` alone, all following the same pattern (bump +2..+7 → ratchet -2..-5 → bump again). The check measures total codebase violations against a threshold, so any PR can fail for drift it didn't cause.

## What

Convert the `Complexity Analysis` → `Shell function complexity` step in `.github/workflows/code-quality.yml` from a **total-count-vs-threshold** model to a **per-function regression** model — same architectural pattern that t2065/GH#18773 introduced for Qlty smells (`.github/workflows/qlty-regression.yml`).

New behaviour:

1. Compute the set of `(file, function_name, line_count)` tuples for all functions over 100 lines at the PR base SHA (`origin/main`).
2. Compute the same set at the PR head SHA.
3. Compute the set difference: NEW violations are functions in the head set that are NOT in the base set (matched by `(file, function_name)`).
4. Fail the check if any NEW violations exist, with a per-violation report listing file:line, function name, and line count.
5. Pass if no NEW violations, even if the total count exceeds the historical threshold.

The existing `FUNCTION_COMPLEXITY_THRESHOLD` value remains as a **secondary** ceiling — the check still warns if total exceeds threshold, but does not fail on total alone. The threshold becomes a slow-moving aspirational target that the simplification routine ratchets down naturally as PRs decompose existing offenders, rather than a brittle gate that explodes on every drift event.

## Why

The current model has three failure modes that the per-function model eliminates:

1. **Drift-blame: PRs fail for violations they didn't cause.** A PR that touches zero shell scripts can fail because another PR merged 5 minutes earlier added a 101-line function. Observed today: PR #19456 (briefs + TODO only) blocked by drift caused by alex-solovyev's #19450/#19455 hotfix sequence.

2. **Bump-without-attribution.** Threshold bumps absorb drift but do not record WHICH function caused the bump. The history file shows generic "drift absorption" entries with no link to the offending function, so the simplification routine can't target ratchet-down work — it has to scan the entire codebase to find candidates. Per-function reporting in the regression check would name the offender on the very PR that introduced it.

3. **Treadmill cost.** 35+ bump entries for FUNCTION_COMPLEXITY_THRESHOLD over the project's history. Each bump is a chore PR, with PR ceremony, CI minutes, review-bot scans, and merge gate cycles. Per-function regression eliminates the bump cycle entirely — once landed, drift PRs simply don't trigger the gate.

The Qlty regression gate (t2065/GH#18773) already proves the per-function/per-file model works for similar metrics. The same approach applied to shell complexity closes a recurring cost the project has paid 35+ times.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — at least 3 (workflow YAML, helper script, regression test). Possibly 4 if a new helper is extracted (`.agents/scripts/complexity-regression-helper.sh` would mirror `.agents/scripts/qlty-regression-helper.sh`).
- [ ] **Every target file under 500 lines?** `code-quality.yml` is ~705 lines; the modified step is ~50 lines. Helper script TBD.
- [ ] **Exact `oldString`/`newString` for every edit?** No — needs new function/script + workflow restructuring.
- [ ] **No judgment or design decisions?** No — must decide: (a) helper-script vs inline-in-workflow, (b) base SHA computation (`merge-base` vs `origin/main`), (c) function identity rule (file+name? what about renames?), (d) override label semantics, (e) interaction with the existing threshold (kept as warning, removed entirely, kept as hard ceiling above per-function gate).
- [x] **No error handling or fallback logic to design?** Has fallback: missing base SHA = pass with warning (mirrors qlty-regression-helper.sh `--allow-missing-base`).
- [x] **No cross-package or cross-module changes?** Workflow + helper + test, all in `.github/` and `.agents/scripts/`.
- [ ] **Estimate ≤ 1 hour?** No — ~3-4h including helper extraction + test harness + dry-run on prior failing PRs.
- [ ] **4 or fewer acceptance criteria?** No — see below, 5 criteria.

**Verdict: tier:standard.** Multiple files, design decisions, follows established pattern (qlty-regression).

## How

### Files to modify

- **EDIT: `.github/workflows/code-quality.yml`** (lines 376-414, the `Shell function complexity` step in the `complexity-check` job). Replace the current "count and compare to threshold" loop with a call to the new helper, then keep the threshold check as a non-blocking warning.

- **NEW: `.agents/scripts/complexity-regression-helper.sh`** (model on `.agents/scripts/qlty-regression-helper.sh`). Subcommands:
  - `scan-base --base <sha> --output <file>` — scan base SHA, write JSON list of `[{file, function, lines, start_line}, ...]`
  - `scan-head --output <file>` — scan working tree, same format
  - `diff --base-set <file> --head-set <file>` — compute set difference, output NEW violations as Markdown report
  - `check --base <sha> [--allow-missing-base]` — orchestrator, used by CI; exit 1 if any NEW violations

- **EDIT: `.github/workflows/code-quality.yml`** (the `complexity-check` job's permissions block) — add `pull-requests: write` if not already present, so the workflow can comment on the PR with the per-function report (mirror qlty-regression-helper.sh comment behaviour).

- **NEW: `.agents/scripts/tests/test-complexity-regression-helper.sh`** (model on `.agents/scripts/tests/test-qlty-regression-helper.sh` if it exists, else on `.agents/scripts/tests/test-pulse-wrapper-canary.sh`). Test cases:
  - Empty diff → 0 NEW violations, exit 0
  - PR adds new 101-line function → 1 NEW violation, exit 1
  - PR adds new 99-line function → 0 NEW violations (under threshold)
  - PR removes a 101-line function → 0 NEW violations, exit 0 (under set-diff this is a NEGATIVE delta, not positive)
  - PR moves a 101-line function to a different file → 0 NEW violations IF function name is the same (set-difference key is `file+function` though, so this WOULD register as new — design decision: do we key on function name only? File+name? Tracked in the per-function ID design decision below).
  - Missing base SHA → exit 0 with warning

### Reference patterns

- Model on `.agents/scripts/qlty-regression-helper.sh` for the overall structure (scan-base / scan-head / diff / check subcommands)
- Model on `.github/workflows/qlty-regression.yml` for the workflow integration (checkout base, scan, checkout head, scan, diff, comment)
- Existing AWK scanner at `.github/workflows/code-quality.yml:391-404` is the function-detection logic to reuse — extract verbatim into the helper

### Design decision: function identity

The set-difference key must handle these realistic scenarios:
- Pure addition (new function in new or existing file) — should register as NEW
- Pure removal — should NOT register
- Rename within file (function added new, old function removed) — should register as NEW (the new function is new code)
- Move between files (same function, different file) — should NOT register if size ≤ base size
- Inline expansion of an existing function past 100 lines — should register as NEW (this is the drift case the gate must catch)

Recommendation: key on `(basename(file), function_name)` for the matching, and additionally check `head_lines > base_lines` for matched pairs (so growth-induced violations register). Alternative: key on `(file, function_name)` and accept that file moves register as new — simpler, false positives easy to override.

### Override mechanism

Mirror qlty-regression: a `complexity-bump-ok` label on the PR + a `## Complexity Bump Justification` section in the PR body together allow the gate to pass with a warning. The label alone is insufficient — the justification section is what forces the author to think about the cost.

### Verification

```bash
# Local dry-run after implementation
.agents/scripts/complexity-regression-helper.sh check --base origin/main

# Replay against a known-failing PR
git checkout chore/t2155-t2156-systemic-fix-briefs
.agents/scripts/complexity-regression-helper.sh check --base 8e01f22da
# Expected: 0 NEW violations (PR is briefs-only), exit 0
# Compare with current behaviour: same PR fails because total 29 > threshold 28
```

## Acceptance Criteria

1. `.github/workflows/code-quality.yml` `Shell function complexity` step calls the new helper and uses set-difference logic.
2. `.agents/scripts/complexity-regression-helper.sh` exists with the four subcommands above and exits with the correct codes.
3. `.agents/scripts/tests/test-complexity-regression-helper.sh` covers all 6 test cases above and passes locally + in CI.
4. The existing `FUNCTION_COMPLEXITY_THRESHOLD` value is kept but downgraded to a non-blocking warning (so the simplification routine can still target the most-violating subsystems).
5. PR description includes a dry-run run on a recently-merged PR that introduced a 100+ line function (e.g., `alex-solovyev/t2151` PRs #19450 or #19455 if they introduced any), demonstrating the new gate would have caught it (or correctly not caught it).

## Dependencies

- None blocking. The bump in #19457 unblocks the immediate queue; this work can land at the worker's pace.

## Out of scope

- Per-function gates for `NESTING_DEPTH_THRESHOLD`, `FILE_SIZE_THRESHOLD`, `BASH32_COMPAT_THRESHOLD` — same systemic problem applies, but those are 3 separate follow-ups (one per metric) once t2159 proves the pattern.
- Removing `complexity-thresholds.conf` entirely — keep the file as the warning-threshold source and as the simplification routine's target.
- Migrating qlty-regression-helper.sh to share code — premature, do after t2159 lands and the patterns crystallize.

## Context

- **Symptom**: 5 consecutive code-quality runs on main failed with `Function complexity regression: 29 violations (threshold: 28)` — runs 24541744895, 24541756977, 24541769836, 24541780357, 24541783024.
- **Treadmill evidence**: `.agents/configs/complexity-thresholds.conf` lines 13-46 show 35+ FUNCTION_COMPLEXITY_THRESHOLD bump entries.
- **Same pattern in sibling thresholds**: NESTING_DEPTH_THRESHOLD shows 50+ bumps (lines 49-150), BASH32_COMPAT_THRESHOLD shows 20+ bumps (lines 162-215). t2159 establishes the pattern; subsequent tasks port it to the siblings.
- **Pattern proof**: t2065/GH#18773 introduced per-function Qlty regression and has not had a single bump cycle since merge.
