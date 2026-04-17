<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2171: Extend t2159 per-function regression to nesting/bash32/file-size + retire ratchet treadmill

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:interactive (marcusquinn directing)
- **Created by:** ai-interactive
- **Parent task:** none (follow-up to t2159/PR#19463)
- **Conversation context:** While looking at a 7-hour screenshot of GitHub notifications, observed 11 identical "CI nesting threshold proximity: 283/285 violations (2 headroom)" issues (#19526 through #19582) and 5+ bouncing ratchet-down/bump PRs on `NESTING_DEPTH_THRESHOLD` and `BASH32_COMPAT_THRESHOLD`. Traced to the bump-and-ratchet treadmill: t2159/PR#19463 shipped per-function regression for `FUNCTION_COMPLEXITY_THRESHOLD` but explicitly scoped the remaining three metrics (nesting depth, file size, bash32) as out-of-scope follow-ups. Those three are exactly the ones still looping. This task completes the migration: the pulse treadmill ends when all four metrics use set-difference gating, the proximity scanner is retired, and the ratchet-down dispatch routine no longer auto-files PRs.

## What

Extend `.agents/scripts/complexity-regression-helper.sh` to gate on four metrics via a `--metric` parameter, wire each gate into `.github/workflows/code-quality.yml` replacing the current total-count blocking checks, and neutralize the two pulse routines that drove the bump-and-ratchet treadmill.

After this ships:

1. `complexity-regression-helper.sh scan --metric <name>` supports `function-complexity` (existing behaviour, the default), `nesting-depth`, `file-size`, and `bash32-compat`. Each metric's scanner emits a TSV of violations keyed on `(file, identifier)` so the existing `compute_new_violations` set-difference logic works unchanged.
2. `.github/workflows/code-quality.yml` "Shell nesting depth", "File size check", and "Bash 3.2 compatibility" steps follow the same shape as "Shell function complexity":
   - Total-count is printed as a `::warning::` against the existing threshold (informational target for the simplification routine)
   - PR events run `complexity-regression-helper.sh check --metric <name> --base <merge-base>` as a blocking gate
   - Override: `complexity-bump-ok` label + `## Complexity Bump Justification` PR body section
3. `_check_ci_nesting_threshold_proximity` (pulse-simplification.sh:1416) and `_complexity_scan_ratchet_check` (pulse-simplification.sh:1699) short-circuit with a `return 0` and a log line pointing to t2171. They no longer file issues or trigger auto-dispatched PRs. The legacy `complexity-scan-helper.sh ratchet-check` subcommand remains callable for human/interactive use — it just doesn't auto-dispatch anymore.
4. Tests in `.agents/scripts/tests/test-complexity-regression-helper.sh` cover the three new metrics with at least one clean-to-new case each plus one stable-existing case (so we catch accidental regressions in the set-difference keying).

## Why

Evidence from the last 7 hours (2026-04-17 ~06:00–13:15 UTC):

- **11 identical proximity-warning issues**: #19526, #19530, #19536, #19543, #19550, #19557, #19565, #19572, #19577, #19581, #19582 — all titled "CI nesting threshold proximity: 283/285 violations (2 headroom)". Each one triggered a worker to file a ratchet-down or bump PR.
- **5 bounce iterations for BASH32_COMPAT_THRESHOLD** (74 ↔ 78): #19553, #19562, #19568, #19571, #19576. Ratchet-check picks `actual + 2` (74 when actual=72), next drift tips over 74, hotfix bumps back to 78, next ratchet-check proposes 74 again.
- **PR #19584** was the 12th iteration in the sequence, closed at the start of this task.

Each iteration consumes a worker dispatch (tokens + CI minutes + review-bot cycles + merge gate). The codebase never gets simpler — only the threshold moves.

t2159 proved the solution works: `FUNCTION_COMPLEXITY_THRESHOLD` has not been bumped since PR#19463 merged 12h ago, despite a dozen PRs landing through this same period with no drift failures. The fix transfers directly to the remaining three metrics.

The t2159 issue body (GH#19459) explicitly listed this extension as out-of-scope follow-up once the pattern proved itself. It has.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — 4 files: `complexity-regression-helper.sh` (extend), `test-complexity-regression-helper.sh` (extend), `code-quality.yml` (3 steps rewritten), `pulse-simplification.sh` (2 helpers neutralized).
- [ ] **Every target file under 500 lines?** No — `complexity-regression-helper.sh` is 503 lines; `code-quality.yml` is 773 lines; `pulse-simplification.sh` is 1871 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — new scanner functions, not replacements.
- [ ] **No judgment or design decisions?** Some — bash32 violation identity key design (see How below), choice of whether to keep or retire `complexity-scan-helper.sh ratchet-check` as a user-facing tool (decision: keep, just don't auto-dispatch).
- [x] **No error handling or fallback logic to design?** The fallback logic is inherited from t2159 (merge-base detection, missing base SHA, override label).
- [x] **No cross-package or cross-module changes?** All in `.agents/` + `.github/workflows/`.
- [ ] **Estimate ≤ 1 hour?** No — ~2–3h including tests and dry-run verification.
- [ ] **4 or fewer acceptance criteria?** No — 6 criteria below.

**Selected tier:** `tier:standard`

**Tier rationale:** Follows an established pattern (t2159) but extends it across three new metrics with new scanner functions, workflow wiring, and pulse neutralization. Not novel design (tier:thinking) but not purely mechanical (tier:simple). Interactive session; no tier label needed since the PR is `origin:interactive`.

## PR Conventions

Leaf task (no parent-task label). PR body uses `Resolves #NNN` as normal.

## How (Approach)

### Files to Modify

- **EDIT: `.agents/scripts/complexity-regression-helper.sh`**
  - Add `--metric <name>` flag to `scan` and `check` subcommands (default: `function-complexity` for back-compat).
  - Add `scan_dir_nesting_depth()`, `scan_dir_file_size()`, `scan_dir_bash32_compat()` functions. Each emits the same `<file>\t<identifier>\t<value>` TSV format so `compute_new_violations` works unchanged.
  - Extend `write_report()` to accept a metric label for the report title / column headers.
  - Update the usage/help text.

- **EDIT: `.agents/scripts/tests/test-complexity-regression-helper.sh`**
  - Add tests for the three new metrics (at minimum: clean-to-new + stable-existing for each).
  - Keep the existing 6 tests passing unchanged.

- **EDIT: `.github/workflows/code-quality.yml`**
  - "Shell nesting depth" step (484-523): rewrite to match the "Shell function complexity" pattern — non-blocking warning on total, blocking regression gate on PRs.
  - "File size check" step (525-561): same treatment.
  - "Bash 3.2 compatibility check" step (113-201): same treatment. (This step is in a separate `bash32-compat` job, not the `complexity-check` job, so permissions and checkout need to be handled separately there.)

- **EDIT: `.agents/scripts/pulse-simplification.sh`**
  - `_check_ci_nesting_threshold_proximity` (1416): replace body with early `return 0` + log line "t2171: proximity scanner retired; per-function regression in code-quality.yml replaces this". Leave the function signature + surrounding helpers intact so nothing else breaks.
  - `_complexity_scan_ratchet_check` (1699): same treatment. Log line "t2171: auto-dispatch ratchet-down retired; thresholds are warnings now".
  - Optional: remove the call sites (line 1831, 1852) entirely, but the early-return approach is safer for rollback.

### Reference Patterns

- **t2159 / PR #19463** established the pattern. `complexity-regression-helper.sh` already has the right architecture; just generalise the scanner.
- **`.github/workflows/qlty-regression.yml`** is the sibling regression gate (t2065). Structure of the new steps mirrors it.
- Existing AWK scanners in `code-quality.yml` are the source of truth for each metric's detection logic — copy them verbatim into the helper's new scan functions.

### Identity key design per metric

`compute_new_violations` treats `(col1, col2)` as the identity key. Per metric:

- `function-complexity`: `<file>\t<function_name>\t<lines>` — unchanged from t2159.
- `nesting-depth`: `<file>\tNEST\t<max_depth>` — one row per file, fixed literal "NEST" in col 2. A file that was already in violation at base and is still in violation at head matches on the key; only newly-violating files register as new.
- `file-size`: `<file>\tSIZE\t<line_count>` — same pattern as nesting-depth.
- `bash32-compat`: `<file>\t<pattern>:<line_num>\t1` — each individual violation is keyed separately so moving a line doesn't cloak a new violation as existing. Pattern examples: `backslash-tn`, `assoc-array`, `nameref`, `heredoc-in-subshell` (same categories as the existing CI check).

### Workflow step template

Each metric gets a step like:

```yaml
- name: Shell nesting depth
  env:
    BASE_SHA: ${{ github.event.pull_request.base.sha || github.event.before }}
    HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}
    PR_NUMBER: ${{ github.event.pull_request.number }}
    REPO: ${{ github.repository }}
    HAS_OVERRIDE: ${{ contains(github.event.pull_request.labels.*.name, 'complexity-bump-ok') }}
    EVENT_NAME: ${{ github.event_name }}
    GH_TOKEN: ${{ github.token }}
  run: |
    set -euo pipefail
    # (non-blocking total-count warning against THRESHOLD from conf file)
    # (blocking per-function regression gate on PRs via --metric nesting-depth)
```

Copy the structure from the existing "Shell function complexity" step (381-482). The bash32-compat job is in a separate top-level job; it'll need `permissions: pull-requests: write` and `fetch-depth: 0` added.

### Implementation Steps

1. Extend `complexity-regression-helper.sh`: add three new scanner functions, wire them through the `--metric` flag, update `write_report` for metric-aware headers.
2. Extend the test script with new test cases (at least 6 new tests — 2 per new metric).
3. Run the test script locally; all 12+ cases pass.
4. Rewrite the three workflow steps following the t2159 template.
5. Neutralize the two pulse helpers with early-return + log line.
6. Dry-run the helper against the current tree to confirm expected total counts (nest=283, size=57, bash32=72).
7. Commit, push, PR — Resolves #NNN.

### Verification

```bash
# All tests pass
bash .agents/scripts/tests/test-complexity-regression-helper.sh

# Dry-run totals match code-quality.yml's current totals
.agents/scripts/complexity-regression-helper.sh check --metric nesting-depth --dry-run
.agents/scripts/complexity-regression-helper.sh check --metric file-size --dry-run
.agents/scripts/complexity-regression-helper.sh check --metric bash32-compat --dry-run

# Replay against a known-clean PR (this one) — all four metrics exit 0
.agents/scripts/complexity-regression-helper.sh check --metric nesting-depth --base origin/main
.agents/scripts/complexity-regression-helper.sh check --metric file-size --base origin/main
.agents/scripts/complexity-regression-helper.sh check --metric bash32-compat --base origin/main
```

## Acceptance Criteria

1. `.agents/scripts/complexity-regression-helper.sh` supports `--metric function-complexity | nesting-depth | file-size | bash32-compat` on both `scan` and `check` subcommands. Default value is `function-complexity` (back-compat).
2. `.agents/scripts/tests/test-complexity-regression-helper.sh` has ≥12 tests covering all four metrics; all pass.
3. `.github/workflows/code-quality.yml` "Shell nesting depth", "File size check", and "Bash 3.2 compatibility check" steps follow the t2159 pattern (non-blocking total warning + blocking PR regression gate with `complexity-bump-ok` override).
4. `.agents/scripts/pulse-simplification.sh` `_check_ci_nesting_threshold_proximity` and `_complexity_scan_ratchet_check` are neutralized (early `return 0` + log line referencing t2171). No ratchet-down or proximity-warning issues/PRs are filed on the next pulse cycle.
5. Local dry-run of all four metrics against this PR's head shows zero NEW violations (the PR adds scanner/workflow code, no 100+ line shell functions, no deep nesting, no bash32 violations).
6. After merge and a full pulse cycle, no new "CI nesting threshold proximity" or "ratchet-down complexity thresholds" issues/PRs are filed.

## Dependencies

- None blocking. t2159 is the direct prerequisite (already merged).

## Out of Scope

- Removing `complexity-thresholds.conf` — keep as the warning-threshold source and the simplification routine's input. Thresholds can still be adjusted manually or via the legacy `complexity-scan-helper.sh ratchet-check` command (just no longer auto-dispatched).
- Per-function regression for `QLTY_SMELL_THRESHOLD` — qlty-regression.yml (t2065) already covers that.
- Migrating `qlty-regression-helper.sh` to share code with this one — premature; both now work, keep them decoupled.

## Context

- **Symptom**: 11 identical proximity-warning issues and 5+ bounce PRs on nesting/bash32 in 7 hours. See #19526–#19584 for the full sequence.
- **Prior art**: t2159 (GH#19459 / PR#19463) — same pattern for `FUNCTION_COMPLEXITY_THRESHOLD`. Zero bumps since merge.
- **Pulse routines involved**: `_check_ci_nesting_threshold_proximity` and `_complexity_scan_ratchet_check` in `.agents/scripts/pulse-simplification.sh`. Both are invoked from `run_weekly_complexity_scan` (line 1831, 1852). They're the dispatch source of every loop artifact.
- **Why merge-base, not raw base SHA**: same reason as t2159 — PRs that rebased mid-flight otherwise see drift from recently-merged commits as "their" new violations. `git merge-base HEAD "$BASE_SHA"` handles this correctly.
