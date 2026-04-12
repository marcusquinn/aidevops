---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1963: pulse decomposition Phase 0 — safety net (characterization tests, --self-check, --dry-run)

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human, interactive)
- **Parent task:** t1962 / GH#18356 (pulse-wrapper.sh phased decomposition)
- **Conversation context:** Phase 0 of the 10-phase decomposition plan. Gate to every subsequent phase. No code is moved from `pulse-wrapper.sh`; this PR only adds infrastructure that future extraction PRs rely on for regression detection.

## What

Build the regression safety net for the pulse-wrapper decomposition:

1. **Characterization test harness** — `test-pulse-wrapper-characterization.sh` that sources `pulse-wrapper.sh` via the existing `_pulse_is_sourced` guard, verifies all 201 functions are defined via `declare -F`, and exercises the 20 most-called hotspots with targeted behavioural tests.
2. **`--self-check` mode** in `pulse-wrapper.sh` — short-circuit early in `main()` that sources everything, verifies every expected function is defined, and exits 0/1. Basis for CI gate and post-install verification.
3. **`--dry-run` mode / `PULSE_DRY_RUN=1`** — full-cycle run with destructive commands shimmed to no-op logging. Exercises the complete code path without side effects.

No code is moved out of `pulse-wrapper.sh` in this phase. The file grows by ~100 lines (flag handling + dry-run guards).

## Why

- **Regression prevention is the only reason this decomposition is safe.** Without characterization tests, each extraction PR is a blind leap; breakage is only caught by a live pulse cycle, which runs every 120 seconds across all repos and can damage production dispatch state.
- **`--self-check` catches the #1 failure mode of module extraction** — a function that disappears because its definition was removed from `pulse-wrapper.sh` but the extracted module failed to source. Cheap, fast, runs in CI and in `setup.sh` post-install.
- **`--dry-run` is the cheap end-to-end smoke test** for each extraction PR. Instead of running a live pulse cycle (which dispatches workers, edits issues, merges PRs), the maintainer runs `PULSE_DRY_RUN=1 pulse-wrapper.sh` and verifies the full code path executes without errors. Catches missing function definitions, broken cross-module calls, and unbound variable errors.
- **Phase 0 must land first because every subsequent phase uses it as its acceptance gate.** Plan §6 mandates all four checks in the PR gate checklist (§7.4) — `--self-check`, `--dry-run`, characterization tests, existing pulse tests.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 1 new file + edit `pulse-wrapper.sh` = **2 files**
- [ ] **Complete code blocks for every edit?** — characterization test is ~400 lines, flag handling is prescribed, destructive shim guards require judgment on which call sites to wrap
- [x] **No judgment or design decisions?** — mostly no; some judgment needed on which commands to shim for `--dry-run`
- [x] **No error handling or fallback logic to design?** — none beyond the flag parsing
- [ ] **Estimate 1h or less?** — estimated 2.5-3h (characterization test + two flags + shim audit + smoke test)
- [x] **4 or fewer acceptance criteria?** — 6 criteria (see below). **More than 4.**

Three unchecked = `tier:standard`, not `tier:simple`.

**Selected tier:** `tier:standard`

**Tier rationale:** The characterization test is ~400 lines with judgment calls on which hotspots to cover and what behavioural assertions make sense for each. The `--dry-run` shim requires identifying every destructive call site in `pulse-wrapper.sh` (see Implementation §2 below) — non-mechanical. Sonnet-tier judgment is appropriate.

## How (Approach)

### Files to Modify

- **`NEW: .agents/scripts/tests/test-pulse-wrapper-characterization.sh`** — ~400 lines. Sources `pulse-wrapper.sh` (relies on `_pulse_is_sourced` guard at L13786 preventing `main` from running), asserts all 201 functions defined, plus behavioural tests for the hotspots listed in plan §3.2.
- **`EDIT: .agents/scripts/pulse-wrapper.sh`** — add two new flag handlers:
  - `--self-check`: new handler at the very top of `main()` (before `trap`, before `acquire_instance_lock`), ~15 lines
  - `--dry-run` / `PULSE_DRY_RUN=1`: env var check, plus inline guards at destructive call sites. Estimated 30-50 lines of guards spread across 8-12 locations.

### Implementation Steps

#### Step 1 — Characterization test harness

Template: follow `test-pulse-wrapper-main-commit-check.sh` (existing test in the same directory for style and the PASS/FAIL helper pattern).

```bash
#!/usr/bin/env bash
# SPDX headers
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'
TESTS_RUN=0
TESTS_FAILED=0

print_result() { ... }  # standard pattern from existing tests

# Sandbox HOME so the sourced wrapper doesn't touch live files
TEST_ROOT=$(mktemp -d)
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# Source the wrapper. The _pulse_is_sourced guard at L13786 prevents main() from running.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-wrapper.sh"

# Test 1: all 201 expected functions are defined
EXPECTED_FUNCTIONS=(
  resolve_dispatch_model_for_labels acquire_instance_lock release_instance_lock
  # ... all 201 from plan §3.1
)
missing=()
for fn in "${EXPECTED_FUNCTIONS[@]}"; do
  declare -F "$fn" >/dev/null || missing+=("$fn")
done
if [[ ${#missing[@]} -eq 0 ]]; then
  print_result "all 201 functions defined after sourcing" 0
else
  print_result "all 201 functions defined after sourcing" 1 "missing: ${missing[*]}"
fi

# Test 2-21: behavioural tests for the 20 hotspots (plan §3.2)
# - main, prefetch_state, unlock_issue_after_worker, dispatch_with_dedup,
#   _extract_linked_issue, run_stage_with_timeout,
#   list_dispatchable_issue_candidates_json, has_worker_for_repo_issue,
#   _gh_idempotent_comment, _ff_with_lock, _ff_key, _ff_save,
#   normalize_count_output, _prefetch_single_repo, run_cmd_with_timeout,
#   fast_fail_reset, _complexity_scan_has_existing_issue, fast_fail_record,
#   _issue_targets_large_files, run_underfill_worker_recycler
```

Behavioural tests per hotspot focus on **parse/format/return-value** behaviour, not side effects:

- `_ff_key "owner/repo" "123"` → verify it returns `owner/repo:123` (or whatever the current format is) — locks the key format so extraction doesn't change it
- `normalize_count_output` with various inputs → lock output format
- `_extract_linked_issue` with sample PR body → lock regex behaviour
- `_gh_idempotent_comment` in a way that doesn't call `gh` (stub `gh` via PATH override) → verify it reads/writes the cache file correctly
- etc.

**Authoritative 201-function list:** generate from the current wrapper with:

```bash
awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ {gsub(/\(\)/,""); print $1}' .agents/scripts/pulse-wrapper.sh
```

Paste the output into `EXPECTED_FUNCTIONS` verbatim.

#### Step 2 — `--self-check` flag

Add to the very top of `main()`, before the `trap` line at L12084:

```bash
main() {
    # Phase 0 (t1963): --self-check short-circuit for CI and post-install verification.
    if [[ "${1:-}" == "--self-check" ]]; then
        local missing=()
        # After all sourced modules load, every expected function must be defined.
        # Future phases will extend this list with _PULSE_<CLUSTER>_LOADED guards.
        local expected_functions=(
            # All 201 function names, identical to test harness list
        )
        for fn in "${expected_functions[@]}"; do
            declare -F "$fn" >/dev/null || missing+=("$fn")
        done
        if [[ ${#missing[@]} -eq 0 ]]; then
            printf 'self-check: ok (201 functions defined)\n'
            return 0
        fi
        printf 'self-check: missing: %s\n' "${missing[*]}" >&2
        return 1
    fi

    # GH#4513: Acquire exclusive instance lock FIRST [...]
    trap 'release_instance_lock' EXIT
    ...
```

**Design note:** the expected function list is duplicated between the characterization test and `--self-check`. Acceptable — they serve different purposes (test harness catches current drift; `--self-check` catches future extraction errors). Future phase may DRY this via a shared sourced list, but not in Phase 0.

#### Step 3 — `--dry-run` flag / `PULSE_DRY_RUN=1`

Add env var check at the top of `main()`, alongside `--self-check`:

```bash
    if [[ "${1:-}" == "--dry-run" ]]; then
        export PULSE_DRY_RUN=1
    fi
```

Then identify every **destructive** call site in the wrapper that needs guarding. Use `grep` to find them, then wrap each with `[[ "${PULSE_DRY_RUN:-0}" == "1" ]] && { log_dry_run "..."; continue/return/true; }`.

Call sites to audit:

- `gh issue edit` (label writes)
- `gh issue create` (new issues)
- `gh issue comment` (comments)
- `gh pr edit`, `gh pr comment`, `gh pr merge`, `gh pr close`
- `gh label create` (only if repo doesn't already have it)
- `git push`
- `git worktree add`, `git worktree remove`
- `rm -rf` (lock dirs, worktrees)
- `launchctl` (pulse control)
- `mv` of state files (to prevent partial writes from leaking)

**Important:** READ operations (`gh issue view`, `gh api`, `gh pr list`, `gh issue list`) must still run — dry-run exercises the code path, not replaces the API.

A helper function:

```bash
# Phase 0 (t1963): log-only shim for destructive operations under --dry-run.
_dry_run_log() {
    local action="$1"
    shift
    printf '[pulse-wrapper:dry-run] %s: %s\n' "$action" "$*" >&2
    return 0
}
```

Then at each destructive site:

```bash
if [[ "${PULSE_DRY_RUN:-0}" == "1" ]]; then
    _dry_run_log "gh issue edit" "#${issue_num} --add-label status:queued"
else
    gh issue edit "$issue_num" --repo "$slug" --add-label "status:queued" 2>/dev/null || true
fi
```

**Scope decision:** Phase 0 covers the 10-12 most obvious destructive sites. A follow-up pass during Phase 9 (when dispatch-core is extracted) can sweep for any missed sites.

### Verification

```bash
cd ~/Git/aidevops.feature-t1963-pulse-safety-net

# 1. Syntax check
bash -n .agents/scripts/pulse-wrapper.sh
bash -n .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# 2. Shellcheck clean
shellcheck .agents/scripts/pulse-wrapper.sh
shellcheck .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# 3. New characterization test green
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# 4. All existing pulse tests still green
for t in .agents/scripts/tests/test-pulse-wrapper-*.sh; do
    bash "$t" || echo "FAIL: $t"
done

# 5. --self-check exits 0
.agents/scripts/pulse-wrapper.sh --self-check

# 6. --dry-run completes a full cycle (may take up to ~5 min depending on repo count)
PULSE_DRY_RUN=1 .agents/scripts/pulse-wrapper.sh

# 7. Normal invocation still works (optional manual test on laptop)
# Do NOT run on the live pulse — the smoke test is for the cutover after merge
```

## Acceptance Criteria

- [ ] `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` exists and passes

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh"
  ```

- [ ] All existing `test-pulse-wrapper-*.sh` tests still pass

  ```yaml
  verify:
    method: bash
    run: "for t in .agents/scripts/tests/test-pulse-wrapper-*.sh; do bash \"$t\" || exit 1; done"
  ```

- [ ] `shellcheck` is clean on both modified files

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-wrapper.sh .agents/scripts/tests/test-pulse-wrapper-characterization.sh"
  ```

- [ ] `pulse-wrapper.sh --self-check` exits 0 with `self-check: ok (201 functions defined)`

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/pulse-wrapper.sh --self-check"
  ```

- [ ] `PULSE_DRY_RUN=1 pulse-wrapper.sh` completes a full cycle and exits 0 without any destructive side effects

  ```yaml
  verify:
    method: bash
    run: "PULSE_DRY_RUN=1 .agents/scripts/pulse-wrapper.sh"
  ```

- [ ] Normal invocation (no flag, no env var) runs unchanged — manual smoke test by the maintainer after merge, before re-enabling the launchd pulse.

## Context & Decisions

- **Why not extract the 201-function list to a separate file?** Two copies (one in the test, one in `--self-check`) is fine for now. Extracting creates a new coupling that would have to be re-extracted later. YAGNI in Phase 0.
- **Why `--self-check` before the lock?** Because it's pure verification — it doesn't need the lock, and running it while another pulse holds the lock should still succeed. Useful for operators debugging a stuck pulse.
- **Why `PULSE_DRY_RUN` env var in addition to `--dry-run` flag?** The env var propagates through subshells and child processes, which matters for the few call sites that spawn helpers. The flag is a convenience for the command line; both set the same env var.
- **Why not shim every destructive call site?** Phase 0 scope is "exercise the full code path without the most damaging side effects". A missed shim means `--dry-run` may make one or two API calls; acceptable. Phase 9 (dispatch extraction) will do a complete audit when it refactors `dispatch_with_dedup`.
- **Why behavioural tests only for hotspots, not all 201 functions?** Budget. A 400-line test file covers the 20 hotspots plus the function-existence check. Lower-priority functions get characterization only through the "function exists" check. Individual extraction PRs may add behavioural tests for the functions they move if the reviewer wants stronger coverage.

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh` (13,797 lines) — edit `main()` L12075 to add flag handlers; edit destructive call sites throughout
- `.agents/scripts/tests/test-pulse-wrapper-*.sh` — 9 existing tests to preserve
- `.agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh` — follow this test's style pattern (PASS/FAIL helper, mktemp sandbox)
- `todo/plans/pulse-wrapper-decomposition.md` — §5 (safety net), §3.1 (201-function list), §3.2 (20 hotspots)

## Dependencies

- **Blocked by:** none
- **Blocks:** t1962.1 (Phase 1 — first extraction PR) and all subsequent phases
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Characterization test harness (boilerplate + 201-fn list) | 30m | mostly mechanical; use `awk` to generate the function list |
| Behavioural tests for 20 hotspots | 1h | per-hotspot test ~3-5 lines; most are parser/format locks |
| `--self-check` flag | 20m | short handler, duplicates the 201-fn list |
| `--dry-run` shim + destructive site audit | 1h | grep for destructive sites, add ~10 inline guards |
| Verification (shellcheck, existing tests, smoke) | 20m | mostly waiting on test output |
| **Total** | **~3h** | |
