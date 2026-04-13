<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Plan: `stats-functions.sh` phased decomposition

**Task:** t2010 (parent) — `.agents/scripts/stats-functions.sh` (3,164 lines, 48 functions)
**Precedent:** [`todo/plans/pulse-wrapper-decomposition.md`](pulse-wrapper-decomposition.md) (t1962, 10 phases, 90% reduction, zero regressions)
**Status:** plan-only. No code is moved by this document. Implementation lives in subtask issues filed sequentially as each prior phase merges.

---

## 1. Problem statement

`.agents/scripts/stats-functions.sh` is **3,164 lines, 48 functions, the second-largest file in the codebase post-t1962**. It exists because t1431 extracted it from `pulse-wrapper.sh` to break the stats subsystem out of the pulse process — but that single move kept the stats domain monolithic. Since extraction the file has accreted three roughly co-equal subsystems:

1. **Daily code-quality sweep** — ShellCheck, Qlty, SonarCloud, Codacy, CodeRabbit, post-merge review scanner. Builds a per-repo "Code Quality" health issue and drives simplification work. ~23 functions, ~1,692 lines.
2. **Health dashboard** — per-repo pinned issues showing active workers, system resources, recent activity, contributor stats, session time, and cross-repo summaries. ~22 functions, ~1,252 lines.
3. **Shared utilities** — repo-slug validation, runner-role resolution (supervisor vs contributor), persistent role cache. ~3 functions, ~120 lines.

Three observable symptoms motivate decomposition now:

- **`FILE_SIZE_THRESHOLD` is currently 59** (the simplification gate's per-file complexity threshold for stats-functions.sh, raised over time to keep the file from blocking unrelated PRs). With t1962 cleared, `stats-functions.sh` is now the dominant file in `--complexity-scan` runs and the residual reason the global threshold can't ratchet back down.
- **Quality-sweep PRs and health-dashboard PRs sit in the same blast radius.** Touching the dashboard renderer requires reviewing the entire 3,164-line file, even though the sweep code is functionally disjoint. Reviewers cannot scope attention.
- **The simplification routine cannot decompose this file in-place.** Function-by-function shrinking has been attempted (t1992 quality-sweep serialization fix, several smaller fixes); the file keeps growing because new sweep tools are co-located with the existing ones.

The methodology that worked for `pulse-wrapper.sh` (13,797 → ~804 lines across 10 phases, zero regressions) applies directly here. Because `stats-functions.sh` is **~23% the size** of pre-decomposition `pulse-wrapper.sh` and has **fewer external callers** (one sourcer vs many), this should be a 3-phase project rather than 10.

---

## 2. Constraints

These are non-negotiable for every phase:

- **Byte-preserving moves only.** No refactoring during extraction. No rename, no signature change, no logic edit. Function bodies move character-for-character. Simplification (renaming long parameter lists, factoring duplicate idioms, removing dead branches) is **deferred** to follow-up tasks once each module exists in isolation.
- **Sourcer compatibility.** `stats-wrapper.sh` (the only sourcer) must continue to work without modification, OR with a single `source` line addition per extracted module. No API change to the public entry points (`update_health_issues`, `run_daily_quality_sweep`).
- **Include guards on every new module.** The same `[[ -n "${_FOO_LOADED:-}" ]] && return 0` pattern used by `stats-functions.sh` itself. Prevents double-sourcing during cron startup.
- **Preserve `LOGFILE` semantics.** The sourcer assigns `LOGFILE="$STATS_LOGFILE"` before sourcing so all log output goes to `~/.aidevops/logs/stats.log`. Every extracted module must continue to write to `$LOGFILE`, not hardcode a path.
- **Preserve `_validate_int` graceful detection.** Lines 44-50 of the current file probe for `_validate_int` (defined in `worker-lifecycle-common.sh`) and gracefully fall back if absent. Each module that owns numeric config must replicate this `type _validate_int &>/dev/null` guard.
- **No new dependencies.** No new `gh`, `jq`, `awk`, or external tool requirements. The decomposition is structural, not functional.
- **One module per PR maximum** for code-moving phases. Plan + Phase 0 may share one PR if scoped tightly.
- **Two-commit PR structure** for every extraction PR (see §8.3): commit 1 = create module + add `source` line; commit 2 = remove the now-duplicated original definitions from `stats-functions.sh`. This makes review trivial — diff commit 2 against the new module file and prove the bytes are identical.

---

## 3. Cluster map (the authoritative 48-function decomposition)

### 3.1 Full function → cluster mapping

Format: `LINES name (entry-point | private | shared)`. Lines are body lines (function declaration through closing `}`).

#### Cluster A: `stats-shared.sh` (3 fns, ~120 lines incl. include guard + config)

These functions have **no callers within stats-functions.sh except from the health dashboard cluster**, but they are pure-ish utilities that may be reused by future stats subsystems. Extract first because they have zero dependencies and are the smallest leaf set.

```text
10  _validate_repo_slug              (shared, leaf — pure regex)
96  _get_runner_role                 (shared — calls _validate_repo_slug, _persist_role_cache)
11  _persist_role_cache              (shared, leaf — pure file write)
```

Plus the bootstrap section (lines 1-50): include guard, config defaults (`REPOS_JSON`, `LOGFILE`, `QUALITY_SWEEP_INTERVAL`, `PERSON_STATS_INTERVAL`, `QUALITY_SWEEP_LAST_RUN`, `PERSON_STATS_LAST_RUN`, `PERSON_STATS_CACHE_DIR`, `QUALITY_SWEEP_STATE_DIR`, `CODERABBIT_ISSUE_SPIKE`, `SESSION_COUNT_WARN`), and the `_validate_int` graceful detection block.

**Decision (Phase 1):** keep the bootstrap + config defaults in `stats-functions.sh` as the orchestrator residual, and extract only the 3 functions to `stats-shared.sh`. Rationale: the config defaults are read by both cluster B and cluster C — putting them in a "shared" module would mean every other module has to source `stats-shared.sh` first, while keeping them in the orchestrator means each module sources `stats-functions.sh` (which sources stats-shared.sh once) and inherits the config naturally.

#### Cluster B: `stats-health-dashboard.sh` (22 fns, ~1,252 lines)

Public entry: `update_health_issues` (line 1395, 58 lines). Reachable subgraph:

```text
58  update_health_issues             (PUBLIC entry — calls _refresh_person_stats_cache, _update_health_issue_for_repo)

89  _refresh_person_stats_cache      (private — pure cache refresh, no callers within file)

97  _update_health_issue_for_repo    (private — the workhorse)
                                       calls: _get_runner_role (Cluster A),
                                              _resolve_health_issue_number,
                                              _scan_active_workers,
                                              _update_health_issue_title,
                                              _assemble_health_issue_body,
                                              _resolve_runner_role_config,
                                              _ensure_health_issue_pinned,
                                              _extract_body_counts

25  _resolve_health_issue_number     (private — calls _find_health_issue, _create_health_issue)
73  _find_health_issue               (private — calls _unpin_health_issue)
59  _create_health_issue             (private, leaf)
19  _unpin_health_issue              (private, leaf)
20  _ensure_health_issue_pinned      (private — calls _cleanup_stale_pinned_issues)
46  _cleanup_stale_pinned_issues     (private, leaf)
38  _update_health_issue_title       (private, leaf)

56  _scan_active_workers             (private, leaf — also called by _gather_health_stats)

63  _assemble_health_issue_body      (private — calls _gather_health_stats, _build_health_issue_body,
                                                    _gather_activity_stats_for_repo,
                                                    _gather_session_time_for_repo,
                                                    _read_person_stats_cache)
101 _gather_health_stats             (private — calls _scan_active_workers, _gather_system_resources)
62  _gather_system_resources         (private, leaf)
93  _build_health_issue_body         (private, leaf — 20-arg formatter)
10  _gather_activity_stats_for_repo  (private, leaf — wraps contributor-activity-helper.sh)
10  _gather_session_time_for_repo    (private, leaf — wraps contributor-activity-helper.sh)
10  _read_person_stats_cache         (private, leaf — pure cat)

24  _resolve_runner_role_config      (private, leaf)
20  _extract_body_counts             (private, leaf — pure parse)
```

**Total: 22 functions, ~1,252 lines.** Reads config: `REPOS_JSON`, `LOGFILE`, `PERSON_STATS_INTERVAL`, `PERSON_STATS_LAST_RUN`, `PERSON_STATS_CACHE_DIR`, `SESSION_COUNT_WARN`. Writes no module globals.

#### Cluster C: `stats-quality-sweep.sh` (23 fns, ~1,692 lines)

Public entry: `run_daily_quality_sweep` (line 1473, 74 lines). Reachable subgraph:

```text
74  run_daily_quality_sweep          (PUBLIC entry — calls _quality_sweep_for_repo)

66  _quality_sweep_for_repo          (private — calls _ensure_quality_issue, _build_sweep_comment,
                                                       _run_sweep_tools, _update_quality_issue_body)

76  _ensure_quality_issue            (private, leaf)
16  _load_sweep_state                (private, leaf — also called by _sweep_coderabbit)
17  _save_sweep_state                (private, leaf — also called by _run_sweep_tools)

73  _run_sweep_tools                 (private — orchestrates all _sweep_* tools)
                                       calls: _save_sweep_state, _sweep_shellcheck, _sweep_qlty,
                                              _sweep_sonarcloud, _sweep_codacy, _sweep_coderabbit,
                                              _sweep_review_scanner

104 _sweep_shellcheck                (private, leaf)
95  _sweep_qlty                      (private — calls _create_simplification_issues)
82  _sweep_sonarcloud                (private — calls _sweep_sonarcloud_issues, _sweep_sonarcloud_diagnostics)
59  _sweep_sonarcloud_issues         (private, leaf)
53  _sweep_sonarcloud_diagnostics    (private, leaf)
26  _sweep_codacy                    (private, leaf)
53  _sweep_coderabbit                (private — calls _load_sweep_state)
44  _sweep_review_scanner            (private, leaf)
32  _build_sweep_comment             (private, leaf — pure formatter)

33  _build_simplification_issue_body (private, leaf — pure formatter)
100 _create_simplification_issues    (private — calls _build_simplification_issue_body)

65  _update_quality_issue_body       (private — calls _gather_quality_issue_stats, _build_quality_issue_body,
                                                       _update_quality_issue_title)
55  _gather_quality_issue_stats      (private — calls _compute_debt_stats, _compute_bot_coverage,
                                                        _compute_badge_indicator)
35  _compute_debt_stats              (private, leaf)
72  _compute_bot_coverage            (private — calls _check_pr_bot_coverage)
52  _check_pr_bot_coverage           (private, leaf)
38  _compute_badge_indicator         (private, leaf)
60  _build_quality_issue_body        (private, leaf)
15  _update_quality_issue_title      (private, leaf)
```

**Total: 23 functions, ~1,692 lines.** Reads config: `REPOS_JSON`, `LOGFILE`, `QUALITY_SWEEP_INTERVAL`, `QUALITY_SWEEP_LAST_RUN`, `QUALITY_SWEEP_STATE_DIR`, `CODERABBIT_ISSUE_SPIKE`, plus environment overrides `QUALITY_SWEEP_OFFPEAK`, `QUALITY_SWEEP_PEAK_START`, `QUALITY_SWEEP_PEAK_END`. Writes no module globals.

### 3.2 Inter-cluster edges (the entire surface)

Verified by full per-function call-graph scan over `stats-functions.sh`:

| From cluster | From function | To cluster | To function |
|---|---|---|---|
| B (health) | `_update_health_issue_for_repo` | A (shared) | `_get_runner_role` |
| A (shared) | `_get_runner_role` | A (shared) | `_validate_repo_slug`, `_persist_role_cache` |

**That is the entire cross-cluster edge set. One edge from B to A. Zero edges between B and C. Zero edges from C to A. Zero edges from A to B or C.**

This is dramatically cleaner than t1962, where Phases 7-9 had to handle dozens of cross-cluster edges. Here:

- **Cluster A is a true leaf.** Extract it first; nothing else needs to change.
- **Clusters B and C are functionally disjoint.** They can be extracted in either order, in parallel sessions if desired.
- **Cluster B has exactly one edge into cluster A** (`_get_runner_role`). After extracting A, B can `source stats-shared.sh` once and resolve that edge.

### 3.3 External callers (from outside `stats-functions.sh`)

Verified via `rg -l "stats-functions"`:

```text
.agents/scripts/stats-wrapper.sh           — sources stats-functions.sh; calls run_daily_quality_sweep + update_health_issues
.agents/scripts/pulse-wrapper.sh           — historical reference comments only; no source/call
.agents/scripts/pulse-prefetch.sh          — historical reference comments only; no source/call
.agents/scripts/worker-lifecycle-common.sh — historical reference comments only; no source/call
.agents/scripts/tests/test-quality-sweep-serialization.sh — sources stats-functions.sh; stubs _sweep_* fixtures, calls _run_sweep_tools and _quality_sweep_for_repo (Cluster C only)
```

**Two real external dependents: `stats-wrapper.sh` and `test-quality-sweep-serialization.sh`.** Both source `stats-functions.sh` directly. After decomposition, both will continue to source `stats-functions.sh` (now an orchestrator residual that sources its sibling modules), so neither needs modification. This is the same pattern that t1431 used to extract this very file from `pulse-wrapper.sh`.

---

## 4. Global state audit

### 4.1 Configuration constants (read-only after init)

Defined at the top of `stats-functions.sh` (lines 33-42):

```text
REPOS_JSON                = ${HOME}/.config/aidevops/repos.json
LOGFILE                   = ${HOME}/.aidevops/logs/stats.log     (overridden by sourcer to STATS_LOGFILE)
QUALITY_SWEEP_INTERVAL    = 86400 seconds (1 day)
PERSON_STATS_INTERVAL     = 3600 seconds (1 hour)
QUALITY_SWEEP_LAST_RUN    = ${HOME}/.aidevops/logs/quality-sweep-last-run
PERSON_STATS_LAST_RUN     = ${HOME}/.aidevops/logs/person-stats-last-run
PERSON_STATS_CACHE_DIR    = ${HOME}/.aidevops/logs
QUALITY_SWEEP_STATE_DIR   = ${HOME}/.aidevops/logs/quality-sweep-state
CODERABBIT_ISSUE_SPIKE    = 10
SESSION_COUNT_WARN        = 5
```

All 10 are read by either Cluster B, Cluster C, or both. **Decision:** keep these in the orchestrator residual (`stats-functions.sh`) so every sourced module inherits them. This avoids the multi-module init-order problem that would arise from putting them in `stats-shared.sh` and requiring every other module to source it first.

### 4.2 Module globals (mutable, set after init)

`_STATS_FUNCTIONS_LOADED=1` — include guard. Each new module gets its own equivalent: `_STATS_SHARED_LOADED=1`, `_STATS_HEALTH_DASHBOARD_LOADED=1`, `_STATS_QUALITY_SWEEP_LOADED=1`.

No mutable counters. No per-cycle state held in shell variables. Stats state lives entirely on disk under `~/.aidevops/logs/`.

### 4.3 Sourced dependencies (from other scripts)

The orchestrator `stats-wrapper.sh` sources these BEFORE sourcing `stats-functions.sh`:

```text
shared-constants.sh             — provides timeouts, limits, color codes
worker-lifecycle-common.sh      — provides _validate_int, _kill_tree, _force_kill_tree, check_session_count
```

**Critical:** every extracted module must rely on the orchestrator having sourced these first. Modules MUST NOT re-source either dependency. The graceful detection in `stats-functions.sh` lines 44-50 (`if type _validate_int &>/dev/null`) is the pattern — copy it into any module that uses these helpers.

### 4.4 External commands

`gh`, `jq`, `awk`, `sed`, `grep`, `cat`, `date`, `ps`, `wc`, `git`, `printf`, `cut`, `sort`, `uniq`, `tr`. All POSIX-standard except `gh` (GitHub CLI) and `jq` (JSON processor). Both gated by `command -v gh &>/dev/null || return 0` checks at the entry points.

---

## 5. Regression safety net (Phase 0 — MUST precede Phase 1)

This is the entire purpose of Phase 0. Before any code moves, build the harness that will detect regressions.

### 5.1 Characterization test harness

New file: `.agents/scripts/tests/test-stats-functions-characterization.sh`. Mirrors `test-pulse-wrapper-characterization.sh` (t1963).

```bash
#!/usr/bin/env bash
# Characterization tests for stats-functions.sh (t2010 Phase 0).
set -euo pipefail

STATS_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

setup_sandbox() {
    TEST_ROOT=$(mktemp -d)
    export HOME="${TEST_ROOT}/home"
    mkdir -p "$HOME/.aidevops/logs" "$HOME/.config/aidevops"
    echo '{"initialized_repos": []}' > "$HOME/.config/aidevops/repos.json"
    export LOGFILE="$HOME/.aidevops/logs/stats.log"
}

# Source dependencies in the same order stats-wrapper.sh does
source "${STATS_SCRIPTS_DIR}/shared-constants.sh"
source "${STATS_SCRIPTS_DIR}/worker-lifecycle-common.sh"
setup_sandbox
source "${STATS_SCRIPTS_DIR}/stats-functions.sh"

# Golden function list — every function we plan to extract must exist after sourcing
EXPECTED_FUNCTIONS=(
    # Cluster A (3)
    _validate_repo_slug _get_runner_role _persist_role_cache
    # Cluster B (22)
    update_health_issues _refresh_person_stats_cache _update_health_issue_for_repo
    _resolve_health_issue_number _find_health_issue _create_health_issue _unpin_health_issue
    _ensure_health_issue_pinned _cleanup_stale_pinned_issues _update_health_issue_title
    _scan_active_workers _assemble_health_issue_body _gather_health_stats _gather_system_resources
    _build_health_issue_body _gather_activity_stats_for_repo _gather_session_time_for_repo
    _read_person_stats_cache _resolve_runner_role_config _extract_body_counts
    # Cluster C (23)
    run_daily_quality_sweep _quality_sweep_for_repo _ensure_quality_issue _load_sweep_state _save_sweep_state
    _run_sweep_tools _sweep_shellcheck _sweep_qlty _sweep_sonarcloud _sweep_sonarcloud_issues
    _sweep_sonarcloud_diagnostics _sweep_codacy _sweep_coderabbit _sweep_review_scanner _build_sweep_comment
    _build_simplification_issue_body _create_simplification_issues _update_quality_issue_body
    _gather_quality_issue_stats _compute_debt_stats _compute_bot_coverage _check_pr_bot_coverage
    _compute_badge_indicator _build_quality_issue_body _update_quality_issue_title
)

# Assert each is defined
for fn in "${EXPECTED_FUNCTIONS[@]}"; do
    declare -F "$fn" >/dev/null || { echo "FAIL: $fn missing"; exit 1; }
done
echo "PASS: all 48 functions present"

# Pure-function golden outputs (catch semantic drift)
# _validate_repo_slug — pure regex
_validate_repo_slug "owner/repo" || { echo "FAIL: _validate_repo_slug rejected valid slug"; exit 1; }
! _validate_repo_slug "../etc/passwd" || { echo "FAIL: _validate_repo_slug accepted traversal"; exit 1; }
echo "PASS: _validate_repo_slug pure cases"

# Add 3-5 more pure cases as you discover them during Phase 0
```

This harness must pass before AND after every extraction PR. Running it takes <1 second.

### 5.2 `--self-check` mode in `stats-wrapper.sh`

Extend `stats-wrapper.sh` to accept `--self-check` and do nothing except source `stats-functions.sh` and assert all 48 functions are defined. Used in CI gates and post-merge validation.

```bash
# Near the top of main(), before check_stats_dedup
if [[ "${1:-}" == "--self-check" ]]; then
    source "${SCRIPT_DIR}/stats-functions.sh" || { echo "source failed"; exit 1; }
    for fn in update_health_issues run_daily_quality_sweep _validate_repo_slug; do
        declare -F "$fn" >/dev/null || { echo "missing: $fn"; exit 1; }
    done
    echo "stats-wrapper self-check OK"
    exit 0
fi
```

Add a CI step: `bash .agents/scripts/stats-wrapper.sh --self-check`. Catches any extraction PR that drops a function name without re-sourcing it.

### 5.3 `--dry-run` mode in `stats-wrapper.sh`

Source everything, exercise the entry points with mocked `gh` and `git`, but skip actual API calls. Verifies the call graph is intact end-to-end without touching real GitHub state.

```bash
if [[ "${1:-}" == "--dry-run" ]]; then
    export STATS_DRY_RUN=1
    # ... existing main flow, with sentinel checks in run_daily_quality_sweep / update_health_issues
    # to return early when STATS_DRY_RUN=1 just before the first gh call
fi
```

The early-return sentinels are the same pattern t1962 used in the pulse wrapper. They are **temporary scaffolding**, removed after decomposition completes.

### 5.4 Git diff guard for extraction PRs

Per t1962 §5.4: verify each extraction PR is a pure move by comparing the extracted module against the deleted lines from the original.

```bash
# After commit 2 of each extraction PR, before pushing:
git show HEAD~1:.agents/scripts/stats-functions.sh > /tmp/before.txt
git show HEAD:.agents/scripts/stats-functions.sh > /tmp/after.txt
# Get the lines deleted in the second commit
diff /tmp/before.txt /tmp/after.txt | grep '^<' | sed 's/^< //' > /tmp/deleted.txt
# Compare against the new module file (excluding the new boilerplate header)
tail -n +30 .agents/scripts/stats-<cluster>.sh > /tmp/new-module-body.txt
diff /tmp/deleted.txt /tmp/new-module-body.txt
# Expected: zero diff (or only whitespace at module boundaries)
```

If the diff is non-empty, the PR is doing more than a pure move and must be rejected.

### 5.5 Live cron smoke test after each cutover

Per t1962 §5.5:

1. Stop the launchd `stats-wrapper.sh` cron job.
2. Wait for any in-flight stats process (check `~/.aidevops/logs/stats.pid`).
3. Pull main, rerun `setup.sh --non-interactive` to redeploy.
4. Run `bash .agents/scripts/stats-wrapper.sh --self-check`.
5. Run `bash .agents/scripts/stats-wrapper.sh --dry-run`.
6. Run one real cycle manually: `bash .agents/scripts/stats-wrapper.sh`. Watch `~/.aidevops/logs/stats.log` for ERROR, "function not found", "unbound variable".
7. Restart the launchd job.
8. Watch the next two real cycles in the log to confirm health issues update and quality sweeps run.

### 5.6 Rollback plan

Each PR is a single-commit revert away from the prior state. Because every PR is a pure move (commit 1 adds the module + source line; commit 2 removes the now-duplicated definitions), `git revert <PR_merge_sha>` restores the previous file structure exactly.

If a PR causes a runtime regression that's only visible in production (cron-only failure mode), the revert restores the monolithic file in seconds. The characterization test in §5.1 should catch most regressions before merge, but the revert path is the backup.

---

## 6. Phase sequence

### Phase 0 — Safety net (1 PR, no code moved)

**Subtask:** filed immediately after this plan merges. Estimated 2-3h. `tier:standard`.

Deliverables:

1. New file `.agents/scripts/tests/test-stats-functions-characterization.sh` (per §5.1).
2. `--self-check` mode added to `stats-wrapper.sh` (per §5.2).
3. `--dry-run` mode added to `stats-wrapper.sh` (per §5.3).
4. CI step added that runs both `--self-check` and the characterization test on every PR that touches `.agents/scripts/stats-*.sh`.
5. Exit criteria: characterization test passes against the current monolithic `stats-functions.sh`. `stats-wrapper.sh --self-check` passes. `stats-wrapper.sh --dry-run` passes.

This is the gate. No extraction phase starts until Phase 0 has merged.

### Phase 1 — Extract `stats-shared.sh` (1 PR, ~120 lines moved)

**Subtask:** filed after Phase 0 merges. Estimated 1-2h. `tier:standard`.

Move 3 functions to a new file:

- `_validate_repo_slug`
- `_get_runner_role`
- `_persist_role_cache`

`stats-functions.sh` adds `source "${SCRIPT_DIR}/stats-shared.sh"` near the top, after the bootstrap config block. The 3 function definitions are deleted from `stats-functions.sh`.

Why first: zero callers from clusters B and C — wait, that's not quite right. Cluster B's `_update_health_issue_for_repo` calls `_get_runner_role`. After extraction, B continues to call it the same way; it's just defined in a sibling file that the orchestrator residual sources before B. **No call-site changes required in clusters B or C.** That's the whole point of leaf-first extraction.

Verification gauntlet (§8.4) must pass.

### Phase 2 — Extract `stats-quality-sweep.sh` (1 PR, ~1,692 lines moved)

**Subtask:** filed after Phase 1 merges. Estimated 3-4h. `tier:standard`.

Move 23 functions to a new file:

```text
run_daily_quality_sweep _quality_sweep_for_repo
_ensure_quality_issue _load_sweep_state _save_sweep_state _run_sweep_tools
_sweep_shellcheck _sweep_qlty _sweep_sonarcloud _sweep_sonarcloud_issues
_sweep_sonarcloud_diagnostics _sweep_codacy _sweep_coderabbit _sweep_review_scanner
_build_sweep_comment _build_simplification_issue_body _create_simplification_issues
_update_quality_issue_body _gather_quality_issue_stats _compute_debt_stats
_compute_bot_coverage _check_pr_bot_coverage _compute_badge_indicator
_build_quality_issue_body _update_quality_issue_title
```

`stats-functions.sh` adds `source "${SCRIPT_DIR}/stats-quality-sweep.sh"` after the `stats-shared.sh` source line. Definitions deleted from `stats-functions.sh`.

Why second (rather than parallel with Phase 3): Phase 2 is the larger and more independent cluster. Doing it in isolation makes it easier to bisect any regression. Also, the existing `test-quality-sweep-serialization.sh` test exercises this cluster directly — it should continue to pass without modification, providing a second safety check beyond the characterization test.

### Phase 3 — Extract `stats-health-dashboard.sh` (1 PR, ~1,252 lines moved)

**Subtask:** filed after Phase 2 merges. Estimated 3-4h. `tier:standard`.

Move 22 functions to a new file:

```text
update_health_issues _refresh_person_stats_cache _update_health_issue_for_repo
_resolve_health_issue_number _find_health_issue _create_health_issue _unpin_health_issue
_ensure_health_issue_pinned _cleanup_stale_pinned_issues _update_health_issue_title
_scan_active_workers _assemble_health_issue_body _gather_health_stats _gather_system_resources
_build_health_issue_body _gather_activity_stats_for_repo _gather_session_time_for_repo
_read_person_stats_cache _resolve_runner_role_config _extract_body_counts
```

`stats-functions.sh` adds `source "${SCRIPT_DIR}/stats-health-dashboard.sh"` after the `stats-quality-sweep.sh` source line. Definitions deleted from `stats-functions.sh`.

After this phase, `stats-functions.sh` is reduced to:
- File header + provenance comments (~20 lines)
- Include guard (~5 lines)
- Bootstrap config block + `_validate_int` graceful detection (~25 lines)
- Three `source` lines for the sibling modules (~5 lines)
- **Total: ~55 lines.** Down from 3,164. **98% reduction in the orchestrator residual.**

### Phase 4 — Clear the gate (0 code change)

**Optional, mostly bookkeeping.** After Phase 3 lands:

1. Lower `FILE_SIZE_THRESHOLD` for `stats-functions.sh` in the simplification config (currently 59) back to the global default. Verify the file no longer triggers `--complexity-scan` warnings.
2. Update any docs that reference "stats-functions.sh as the second-largest file" — the largest-file ranking shifts.
3. File a follow-up task per module if `--complexity-scan` flags any of the three new files individually. Each new module is small enough to be simplified normally now.

---

## 7. What this plan explicitly does NOT do

- **No function-internal refactoring** during extraction phases. No long-parameter-list reduction (`_build_health_issue_body` has 20 args — that's a separate task). No factoring of duplicate idioms across `_sweep_*` functions. No dead-code removal.
- **No API surface changes.** The two public entry points (`update_health_issues`, `run_daily_quality_sweep`) keep their signatures. The sourcer continues to call them by the same names.
- **No splitting of `stats-wrapper.sh`.** It's already small (189 lines).
- **No introduction of a "stats-config.sh" module** to hold the bootstrap config defaults. Keeping them in the orchestrator residual avoids init-order bugs.
- **No parallel execution of phases.** Phase N must merge before Phase N+1 starts. This is the same single-thread rule t1962 enforced — concurrent extraction PRs guarantee merge conflicts.

---

## 8. Extraction methodology (subsequent sessions read this)

### 8.1 Module template

Every new `stats-<cluster>.sh` file uses this skeleton. Copy verbatim, fill in the placeholders.

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# stats-<cluster>.sh - <one-line description of the cluster's responsibility>
#
# Extracted from stats-functions.sh via the phased decomposition plan:
#   todo/plans/stats-functions-decomposition.md  (Phase N)
#
# This module is sourced by stats-functions.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all stats-* configuration constants in the bootstrap
# section of stats-functions.sh.
#
# Dependencies on other stats modules:
#   - <list each, e.g., stats-shared.sh (calls _get_runner_role)>
#
# Globals read:
#   - <list, e.g., LOGFILE, REPOS_JSON, QUALITY_SWEEP_INTERVAL>
# Globals written:
#   - none (stats modules write only to disk under ~/.aidevops/logs/)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_<CLUSTER>_LOADED:-}" ]] && return 0
_STATS_<CLUSTER>_LOADED=1

# <verbatim copy of every function in this cluster, in original line order>
```

### 8.2 Orchestrator change per PR

In `stats-functions.sh`, after the bootstrap config block (currently ending at line ~50), add one source line per phase:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Phase 1
# shellcheck source=stats-shared.sh
source "${SCRIPT_DIR}/stats-shared.sh"

# Phase 2
# shellcheck source=stats-quality-sweep.sh
source "${SCRIPT_DIR}/stats-quality-sweep.sh"

# Phase 3
# shellcheck source=stats-health-dashboard.sh
source "${SCRIPT_DIR}/stats-health-dashboard.sh"
```

The `SCRIPT_DIR` line is added in Phase 1 and reused thereafter. It mirrors the same pattern in `stats-wrapper.sh`.

### 8.3 Two-commit PR structure (within one PR branch)

This is the critical reviewability pattern. Every extraction PR has exactly two commits:

**Commit 1:** `Phase N (1/2): create stats-CLUSTER.sh + add source line`

- Adds the new file `.agents/scripts/stats-CLUSTER.sh` containing the full module with all functions
- Adds the `source` line in `stats-functions.sh`
- **Does NOT delete anything from `stats-functions.sh`**
- After this commit, every function in the cluster is defined twice. The include guard prevents double-define errors at runtime, but `declare -F` will still find the function — the most recently sourced wins.

**Commit 2:** `Phase N (2/2): remove now-duplicated definitions from stats-functions.sh`

- Deletes the function definitions from `stats-functions.sh`
- Touches no other file
- Diff for commit 2 is exclusively deletions; reviewer can `git show HEAD --stat` to confirm

This structure makes review trivial: commit 1 is the new module + 1 line in the orchestrator. Commit 2 is pure deletion. Anyone can verify "the deleted bytes match the added bytes" with the §5.4 git-diff guard.

### 8.4 PR gate checklist (reviewer runs before merge)

- [ ] PR title is `tNNNN: stats-functions decomposition Phase N — extract stats-<cluster>.sh`
- [ ] PR body links the plan: `Decomposition plan: todo/plans/stats-functions-decomposition.md (§6 Phase N)`
- [ ] PR has exactly 2 commits in the structure above
- [ ] `bash .agents/scripts/tests/test-stats-functions-characterization.sh` passes locally
- [ ] `bash .agents/scripts/stats-wrapper.sh --self-check` passes locally
- [ ] `bash .agents/scripts/stats-wrapper.sh --dry-run` passes locally
- [ ] `shellcheck .agents/scripts/stats-functions.sh .agents/scripts/stats-<cluster>.sh` clean
- [ ] §5.4 git-diff guard shows the deleted bytes match the new module body
- [ ] CI: all framework validation jobs green
- [ ] No new functions introduced. No function bodies modified (verified by §5.4)

### 8.5 Cutover steps (maintainer runs after merge)

1. Pull main on the canonical repo.
2. `bash setup.sh --non-interactive` to redeploy the modified script set to `~/.aidevops/agents/scripts/`.
3. Stop the launchd `stats-wrapper.sh` job: `launchctl stop sh.aidevops.stats-wrapper` (or whatever the actual label is — check `launchctl list | grep aidevops` first).
4. Wait for any in-flight stats process to exit (check `~/.aidevops/logs/stats.pid`).
5. Run one manual cycle: `bash ~/.aidevops/agents/scripts/stats-wrapper.sh`. Watch `~/.aidevops/logs/stats.log` for ERROR, function-not-found, or unbound-variable.
6. Restart the launchd job.
7. Watch the next two real cycles in the log.

If anything goes wrong: `git revert <PR_merge_sha>` and redeploy.

---

## 9. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Function dropped during extraction (typo, missed copy) | Medium | Characterization test §5.1 enumerates all 48 names; CI runs it on every PR |
| Inter-module init order wrong (cluster B sources before stats-shared.sh is loaded) | Low | Orchestrator (`stats-functions.sh`) controls source order; modules cannot self-source siblings |
| `LOGFILE` semantics broken (module writes to default path instead of `STATS_LOGFILE`) | Low | All log writes use `>>"$LOGFILE"`; never hardcode a path. PR gate checklist verifies |
| Sourcer (`stats-wrapper.sh`) relies on a function that gets renamed/moved | Very low | No renaming permitted (§2). `--self-check` mode catches missing public entries |
| Test file `test-quality-sweep-serialization.sh` breaks due to source path change | Low | The test sources `stats-functions.sh` directly; the orchestrator residual continues to source the new module, so the test sees the same functions |
| Live cron job runs mid-cutover and hits a half-deployed state | Medium | Cutover §8.5 requires stopping the launchd job before redeploying |
| Reviewer can't verify "pure move" claim | Low | Two-commit structure §8.3 makes commit 2 pure deletion; §5.4 git-diff guard provides automated proof |
| Cross-merge interference between concurrent extraction sessions | Eliminated | §7: phases are strictly sequential, no parallelism |

---

## 10. Decisions (resolved 2026-04-13)

1. **Three modules, not four.** Initially considered splitting `stats-quality-sweep.sh` into `stats-sweep-tools.sh` (the `_sweep_*` family) and `stats-sweep-orchestration.sh` (everything else). Rejected because the resulting two files would be ~900 and ~800 lines respectively — neither would benefit meaningfully from the split, and the call-graph density between them is too high. Single quality-sweep module is cleaner.
2. **Bootstrap config stays in the orchestrator residual.** Considered moving it to `stats-shared.sh`. Rejected because every other module would then need to source `stats-shared.sh` first, multiplying init-order surface. Orchestrator-controlled source order is simpler.
3. **Extract shared utilities first, not the largest cluster first.** Leaf-first matches the t1962 precedent and minimizes cross-cluster edge churn during the larger phases.
4. **Phase 0 is its own PR, not bundled with Phase 1.** Forces the safety net to land independently. Lets us verify the harness passes against the unchanged monolithic file before any code moves — proving the harness actually works.
5. **No "stats-config.sh" module.** See decision 2.
6. **No simplification during extraction.** Per t1962 precedent. Function shrinking is filed as Phase 4+ tasks once the modules exist in isolation.

---

## 11. Next action

After this plan PR merges:

1. File `tNNNN: stats-functions decomposition Phase 0 — characterization safety net` with brief at `todo/tasks/tNNNN-brief.md`. Tier `tier:standard`. Auto-dispatch eligible.
2. Phase 0 implements §5.1, §5.2, §5.3 deliverables.
3. After Phase 0 merges, file Phase 1 (`tNNNN: stats-functions decomposition Phase 1 — extract stats-shared.sh`).
4. Continue sequentially through Phase 3.

DO NOT file all four phase subtasks upfront. The t1962 pattern (file each phase only after the prior one merges) prevents workers from picking up phases that depend on un-landed prior work.

---

## Appendix A: Session-local analysis artefacts

```text
# Function inventory (48 functions verified)
grep -nE "^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{" .agents/scripts/stats-functions.sh | wc -l

# Per-function size distribution (sorted largest first)
awk '
/^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ { fname=$1; sub(/\(\)/,"",fname); start=NR; next }
fname && /^\}$/ { lines=NR-start+1; print lines, fname; fname="" }
' .agents/scripts/stats-functions.sh | sort -rn

# Largest 10 functions:
#   104 _sweep_shellcheck
#   101 _gather_health_stats
#   100 _create_simplification_issues
#    97 _update_health_issue_for_repo
#    96 _get_runner_role
#    95 _sweep_qlty
#    93 _build_health_issue_body
#    89 _refresh_person_stats_cache
#    82 _sweep_sonarcloud
#    76 _ensure_quality_issue

# External callers (verified):
rg -l "stats-functions" .agents/scripts/ --type sh
# .agents/scripts/stats-wrapper.sh                                   ← real sourcer
# .agents/scripts/tests/test-quality-sweep-serialization.sh          ← real sourcer (test)
# .agents/scripts/pulse-wrapper.sh                                   ← historical comment only
# .agents/scripts/pulse-prefetch.sh                                  ← historical comment only
# .agents/scripts/worker-lifecycle-common.sh                         ← historical comment only
# .agents/scripts/stats-functions.sh                                 ← itself
```

## Appendix B: History

- **2026-04-13** — Plan filed (this document). Authored interactively as part of t2010 lifecycle recovery after three failed worker dispatches between 23:08-00:19 UTC on 2026-04-12. Root cause of the dispatch loop was the `parent-task` guard's jq filter (`.labels[].name`) crashing on null labels — fixed independently by GH#18537. The plan-writing work was completed manually because the original t2010 brief misclassified itself as `#parent` while simultaneously specifying substantive deliverables; the t1962 precedent has plan documents land BEFORE the parent task is filed, not as part of it.
- **Precedent:** [`todo/plans/pulse-wrapper-decomposition.md`](pulse-wrapper-decomposition.md) (t1962). 826 lines, 10 phases, merged across PRs #18366-#18392. Zero regressions across the entire decomposition. This plan is a direct adaptation — same methodology, smaller scope.
