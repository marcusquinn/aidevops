<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1987: Phase 12 — simplification sweep (split large modules, ratchet thresholds)

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human, interactive)
- **Parent task:** t1962 / GH#18356 (closed — pulse-wrapper decomposition complete)
- **Conversation context:** The 10-phase t1962 decomposition cleared the 2,000-line simplification gate on `pulse-wrapper.sh` (13,797 → 1,352 lines), but two modules produced during extraction landed above the 1,500-line file-size threshold: `pulse-simplification.sh` (1,990 lines) and `pulse-prefetch.sh` (1,668 lines). The decomposition plan §6 reserved Phase 12 for this follow-up split + threshold ratchet. This task executes Phase 12.

## What

Three parts, each a separate PR:

1. **Part A:** Split `pulse-simplification.sh` (1,990 lines, 29 functions) into 3-4 sub-modules by functional domain. Target: no sub-module >1,000 lines, orchestrator <500 lines.
2. **Part B:** Split `pulse-prefetch.sh` (1,668 lines, 26 functions) into 3-4 sub-modules similarly.
3. **Part C:** Ratchet `.agents/configs/complexity-thresholds.conf` back down toward pre-decomposition values. Measure actual violation counts after Parts A + B land and compute `actual + 2 buffer` for each threshold.

**Out of scope:**
- Per-function simplification (keep byte-identical moves, same as t1962)
- Any renames or API changes
- Any new behaviour
- Rewriting the call graph — extractions preserve current dependencies

## Why

- **File size gate:** `FILE_SIZE_THRESHOLD` was bumped from 56 → 59 in t1975 (#18386) to accommodate these two modules. Other codebase files may cross 1,500 lines in the future; bringing the threshold back down ratchets the quality gate.
- **Cognitive load:** 1,990-line modules are hard to review and reason about. The t1962 plan explicitly deferred splitting them because doing it during Phase 6/7 would have inflated those PRs past the 2,500-line review ceiling.
- **Dead code removal:** during extraction, the call graph inside these modules may have changed. Splitting forces re-analysis and will surface any orphaned helpers.
- **Precedent:** t1962 Phases 1-10 proved the sub-module pattern works. Phase 12 applies the same methodology one layer deeper.

## Tier

### Tier checklist

- [ ] **2 or fewer files to modify?** — 6-8 new sub-modules + 2 parent modules + 1 config + 1 wrapper guard list = **10-12 files**
- [ ] **Complete code blocks for every edit?** — no, the sub-cluster boundaries must be derived by the worker from the current call graph; only guidance is provided
- [ ] **No judgment or design decisions?** — yes, major judgment: which functions go in which sub-cluster
- [x] **No error handling or fallback logic to design?** — correct (byte-preserving moves)
- [ ] **Estimate 1h or less?** — estimated 4-6h across 3 PRs
- [ ] **4 or fewer acceptance criteria?** — 8+ criteria across the 3 parts

Five checkboxes failed → `tier:reasoning` (Opus).

**Selected tier:** `tier:reasoning` (Opus)

**Rationale:** Sub-cluster design requires call-graph analysis, deciding which functions belong together based on internal call patterns, and sizing sub-modules to minimize cross-file edges. This is design work, not mechanical extraction. Byte-preserving extraction mechanics are mechanical (precedent: t1962 extraction scripts), but the *which functions go where* decision is what makes this reasoning-tier.

## How (Approach)

### Methodology — same as t1962 Phases 1-10

For each sub-module:

1. Compute sub-cluster boundaries by call-graph analysis (see §Sub-cluster guidance below)
2. Create a Python extraction helper modelled on `/tmp/extract_phase1.py` through `/tmp/extract_phase10.py` (these no longer exist on disk — regenerate using the same pattern)
3. Two-commit PR structure:
   - Commit 1: add new sub-module files with byte-identical copies
   - Commit 2: remove extracted defs from parent, source the sub-modules, extend `--self-check` guard list
4. Run full verification gauntlet:
   - `bash -n` clean
   - `pulse-wrapper.sh --self-check` reports new guard count
   - `test-pulse-wrapper-characterization.sh` (26 assertions)
   - 7 fast pulse tests (ci-failure-prefetch, complexity-scan, delta-prefetch, ever-nmr-cache, main-commit-check, schedule, terminal-blockers)
   - `PULSE_DRY_RUN=1` sandboxed → rc=0
   - `shellcheck` — no new findings
   - Byte-identical Python brace-counter spot-check of every moved function
5. Interactive session merge with `origin:interactive` label, admin-merge bypass, STOP_FLAG cutover (see precedent in t1962 Phases 1-10)

### Sub-cluster guidance for Part A (`pulse-simplification.sh` — 29 functions)

**Target split (derived from function names — worker must validate via call-graph analysis before committing):**

#### `pulse-simplification-state.sh` — hash registry (~6 fns, ~450 lines)

The simplification-state.json lock-and-update helpers form a self-contained sub-cluster:

- `_simplification_state_check`
- `_simplification_state_record`
- `_simplification_state_refresh`
- `_simplification_state_prune`
- `_simplification_state_push`
- `_simplification_state_backfill_closed`

Plus the related helper:
- `_create_requeue_issue`

#### `pulse-simplification-scan-shell.sh` — shell-file scanning (~5 fns, ~400 lines)

Shell-only complexity scan machinery:

- `_complexity_scan_tree_hash`
- `_complexity_scan_tree_changed`
- `_complexity_scan_find_repo`
- `_complexity_scan_collect_violations`
- `_complexity_scan_create_issues`

#### `pulse-simplification-scan-md.sh` — markdown scanning (~7 fns, ~400 lines)

Markdown-specific scan + dedup + issue creation:

- `_complexity_scan_should_open_md_issue`
- `_complexity_scan_collect_md_violations`
- `_complexity_scan_extract_md_topic_label`
- `_complexity_scan_has_existing_issue`
- `_complexity_scan_close_duplicate_issues_by_title`
- `_complexity_scan_build_md_issue_body`
- `_complexity_scan_check_open_cap`
- `_complexity_scan_process_single_md_file`
- `_complexity_scan_create_md_issues`

#### `pulse-simplification.sh` — slim orchestrator (~6 fns, <500 lines)

Top-level drivers that orchestrate the three sub-clusters:

- `_complexity_scan_check_interval`
- `_coderabbit_review_check_interval`
- `run_daily_codebase_review`
- `_complexity_llm_sweep_due`
- `_complexity_run_llm_sweep`
- `run_simplification_dedup_cleanup`
- `_check_ci_nesting_threshold_proximity`
- `run_weekly_complexity_scan`

**Worker must verify** these boundaries via call-graph analysis before extracting:

```bash
# For each function in the current pulse-simplification.sh, compute its callees
# within the same file. Group functions that form tight call-clusters.
# Use osgrep or grep to find caller→callee edges:
rg -n '_simplification_state_\w+|_complexity_scan_\w+' \
   .agents/scripts/pulse-simplification.sh | \
   awk -F':' '{print $1":"$2":"$3}' | head -50
```

If the boundary map above produces cross-cluster edges that would fragment the call graph badly, revise the clustering. The goal is **each sub-cluster should have fewer outbound edges to other sub-clusters than inbound edges within itself**.

### Sub-cluster guidance for Part B (`pulse-prefetch.sh` — 26 functions)

**Target split:**

#### `pulse-prefetch-cache.sh` — cache primitives (~3 fns, ~200 lines)

- `_prefetch_cache_get`
- `_prefetch_cache_set`
- `_prefetch_needs_full_sweep`
- `_prefetch_repo_daily_cap`

#### `pulse-prefetch-repo.sh` — per-repo prefetch machinery (~8 fns, ~700 lines)

Core delta-fetch + per-repo loop:

- `_prefetch_prs_try_delta`
- `_prefetch_prs_enrich_checks`
- `_prefetch_prs_format_output`
- `_prefetch_repo_prs`
- `_prefetch_issues_try_delta`
- `_prefetch_repo_issues`
- `_prefetch_single_repo`

#### `pulse-prefetch-workers.sh` — top-level prefetch workers (~10 fns, ~700 lines)

All the `prefetch_*` public functions that the orchestrator calls in pre-flight:

- `prefetch_state`
- `prefetch_missions`
- `prefetch_active_workers`
- `prefetch_ci_failures`
- `prefetch_hygiene`
- `prefetch_contribution_watch`
- `prefetch_foss_scan`
- `prefetch_triage_review_status`
- `prefetch_needs_info_replies`
- `prefetch_gh_failure_notifications`

#### `pulse-prefetch.sh` — slim orchestrator (~5 fns, <400 lines)

Parallel execution plumbing + schedule checks:

- `_wait_parallel_pids`
- `_assemble_state_file`
- `_run_prefetch_step`
- `_append_prefetch_sub_helpers`
- `check_repo_pulse_schedule`

### Part C — ratchet thresholds

After Parts A + B land, run the complexity scan and measure actual violations:

```bash
# Run the same awk scanner that CI runs (from .github/workflows/code-quality.yml)
source .agents/scripts/lint-file-discovery.sh && lint_shell_files
while IFS= read -r file; do
  [ -n "$file" ] || continue
  awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
    fname && /^\}$/ { lines=NR-start; if(lines>100) printf "BLOCK %s:%d %s() %d lines\n", FILENAME, start, fname, lines; fname="" }
  ' "$file"
done <<< "$LINT_SH_FILES" | wc -l
# Expected: lower than 43 (current threshold after Phase 3-7 bumps)

# File-size violations (count files >1500 lines)
find .agents -name "*.sh" -exec wc -l {} \; | awk '$1 > 1500 {print $2}' | wc -l
# Expected: lower than 59 (current threshold)

# Nesting-depth violations — use the same methodology as code-quality.yml
# (detailed in .agents/configs/complexity-thresholds.conf line 24)
```

Bump formula: `new_threshold = actual_violations + 2 buffer` (per the documented ratchet pattern in `complexity-thresholds-history.md`).

**Expected final thresholds (approximate, worker must compute actual):**

| Threshold | Current | Target (approx) |
|---|---:|---:|
| `FUNCTION_COMPLEXITY_THRESHOLD` | 43 | ~38 |
| `NESTING_DEPTH_THRESHOLD` | 260 | ~250 |
| `FILE_SIZE_THRESHOLD` | 59 | ~56 |

**Update `complexity-thresholds.conf` AND the history section** following the existing pattern. Document the ratchet reason clearly: "Ratcheted down after t1987 Phase 12 simplification sweep merged (splits pulse-simplification.sh and pulse-prefetch.sh into sub-clusters, eliminating the module-size inflation from t1962 Phases 3-7)."

### Sourcing strategy decision

**Question:** Should the sub-modules be sourced by `pulse-wrapper.sh` directly, or by their parent module (`pulse-simplification.sh` / `pulse-prefetch.sh`)?

**Recommendation:** Source directly from `pulse-wrapper.sh` (same flat structure as Phases 1-10). The parent module becomes a slim orchestrator that calls functions defined in the sub-modules, relying on bash's lazy name resolution (same mechanism already used between all other pulse-* modules).

Advantages:
- Consistent with existing source list in `pulse-wrapper.sh`
- `--self-check` verifies all guards at the wrapper level
- No new sourcing indirection to debug

Alternative (hierarchical sourcing) considered and rejected: adds complexity without clear benefit.

**Worker must update `pulse-wrapper.sh`'s `_sc_expected_guards` list** with one entry per new sub-module.

## Verification — each PR (Parts A, B, C)

```bash
# 1. Syntax
bash -n .agents/scripts/pulse-wrapper.sh
for m in .agents/scripts/pulse-simplification*.sh .agents/scripts/pulse-prefetch*.sh; do
  bash -n "$m" || exit 1
done

# 2. Self-check with updated guard count
.agents/scripts/pulse-wrapper.sh --self-check

# 3. Characterization test (26 assertions)
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# 4. All 7 fast pulse tests
for t in .agents/scripts/tests/test-pulse-wrapper-ci-failure-prefetch.sh \
         .agents/scripts/tests/test-pulse-wrapper-complexity-scan.sh \
         .agents/scripts/tests/test-pulse-wrapper-delta-prefetch.sh \
         .agents/scripts/tests/test-pulse-wrapper-ever-nmr-cache.sh \
         .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh \
         .agents/scripts/tests/test-pulse-wrapper-schedule.sh \
         .agents/scripts/tests/test-pulse-wrapper-terminal-blockers.sh; do
  bash "$t" || exit 1
done

# 5. Sandbox dry-run
SANDBOX=$(mktemp -d); OLDHOME="$HOME"; export HOME="$SANDBOX/home"
mkdir -p "$HOME/.aidevops/logs" "$HOME/.aidevops/.agent-workspace/supervisor" "$HOME/.config/aidevops"
printf '{"initialized_repos":[]}\n' > "$HOME/.config/aidevops/repos.json"
export PULSE_JITTER_MAX=0
PULSE_DRY_RUN=1 .agents/scripts/pulse-wrapper.sh
export HOME="$OLDHOME"; rm -rf "$SANDBOX"

# 6. Shellcheck (zero new findings)
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck \
  .agents/scripts/pulse-wrapper.sh \
  .agents/scripts/pulse-simplification*.sh \
  .agents/scripts/pulse-prefetch*.sh

# 7. Byte-identical Python brace-counter spot-check (model on t1962 Phase 3-10 patterns)
python3 /tmp/verify_phase12_byte_identity.py
```

## Acceptance Criteria

### Part A

- [ ] `pulse-simplification.sh` reduced to orchestrator-only (<500 lines, ≤8 functions)
- [ ] 3 new sub-modules: `pulse-simplification-state.sh`, `pulse-simplification-scan-shell.sh`, `pulse-simplification-scan-md.sh`
- [ ] Each sub-module <1,000 lines
- [ ] All 29 original functions remain defined after sourcing (verified by `--self-check`)
- [ ] `test-pulse-wrapper-complexity-scan.sh` passes (validates the cluster end-to-end)

### Part B

- [ ] `pulse-prefetch.sh` reduced to orchestrator-only (<500 lines, ≤6 functions)
- [ ] 3 new sub-modules: `pulse-prefetch-cache.sh`, `pulse-prefetch-repo.sh`, `pulse-prefetch-workers.sh`
- [ ] Each sub-module <1,000 lines
- [ ] All 26 original functions remain defined after sourcing
- [ ] `test-pulse-wrapper-delta-prefetch.sh` passes
- [ ] `test-pulse-wrapper-ci-failure-prefetch.sh` passes

### Part C

- [ ] `FUNCTION_COMPLEXITY_THRESHOLD` ratcheted to `actual + 2` (target: lower than 43)
- [ ] `NESTING_DEPTH_THRESHOLD` ratcheted to `actual + 2` (target: lower than 260)
- [ ] `FILE_SIZE_THRESHOLD` ratcheted to `actual + 2` (target: lower than 59)
- [ ] `complexity-thresholds-history.md` updated with ratchet rationale

## Context & Decisions

- **Why `tier:reasoning` not `tier:standard`?** Sub-cluster boundaries are not mechanically derivable from function names alone. The worker must examine the call graph (who calls whom inside the module) and design clusters that minimize cross-file edges. This is architectural judgment, not rule-following. A standard-tier model may produce fragmented sub-clusters that increase cross-file calls, making the split worse than the starting state.
- **Why three separate PRs rather than one?** Two reasons: (1) reviewability ceiling of ~2,500 lines per PR; (2) Parts A and B are independent — failure in one shouldn't block the other. Part C depends on A + B landing but is trivial once they do.
- **Why not also simplify individual functions during the split?** Explicitly out of scope per t1962 plan §6 rule 1. Pure moves only. Simplification is a separate class of work.
- **Why not do this during the original decomposition?** t1962 Phase 6 would have become a 4,000-line PR if we had also split simplification.sh at extraction time. The decomposition methodology deliberately saved "split within modules" for a follow-up pass.
- **Sourcing hierarchy decision:** flat (all sub-modules sourced from `pulse-wrapper.sh`). See §How for rationale.

## Relevant Files

- `.agents/scripts/pulse-simplification.sh` — 1,990 lines, 29 functions, target for Part A
- `.agents/scripts/pulse-prefetch.sh` — 1,668 lines, 26 functions, target for Part B
- `.agents/scripts/pulse-wrapper.sh` — source list update + `_sc_expected_guards` extension (both parts)
- `.agents/configs/complexity-thresholds.conf` — Part C threshold ratchet
- `.agents/configs/complexity-thresholds-history.md` — Part C rationale documentation
- `todo/plans/pulse-wrapper-decomposition.md` §6 and §7.3 — methodology precedent
- `todo/plans/t1987-phase12-simplification-sweep.md` — optional extended plan if worker wants more context
- `/tmp/extract_phaseN.py` (no longer on disk) — regenerate as extraction helpers modelled on the Phase 1-10 pattern

## Dependencies

- **Blocked by:** none (t1962 parent merged and deployed)
- **Blocks:** future ratchet-down of complexity thresholds; clean slate for future pulse-wrapper feature work
- **Related:** #18356 (parent decomposition, closed), #18386 (t1975 threshold bump 40→43, 56→59)
- **Internal dependency:** Part C depends on Parts A + B landing first (or at least Part A, if B is deferred)

## Estimate

| Part | Time | Notes |
|---|---|---|
| **A.** Split pulse-simplification.sh | 2h | Call-graph analysis + 3 sub-modules + verification + PR cycle |
| **B.** Split pulse-prefetch.sh | 2h | Same methodology, smaller cluster |
| **C.** Ratchet thresholds | 30m | Measure + update config + history doc + small PR |
| **Total** | **~4.5h** | Across 3 independent PRs, can be parallelised |

## Worker guidance (important)

Do NOT blindly follow the sub-cluster splits in §How. Those are **starting hypotheses** based on function-name heuristics. Before committing Part A:

1. Read the current `pulse-simplification.sh` end-to-end
2. Map the internal call graph (which functions call which others)
3. Count cross-cluster edges for the proposed split
4. Revise the split if any proposed cluster has >3 outbound edges to another proposed cluster
5. Only then commit Part A

Same for Part B. If the revised split differs significantly from the hypotheses in §How, document the reasoning in the PR body.

Extraction mechanics (Python brace-counter + two-commit structure + verification gauntlet) follow t1962 Phases 1-10 exactly. The extraction scripts from /tmp no longer exist — regenerate them using the same pattern. The template is simple enough to write from scratch in ~100 lines.

Preserve all existing signature conventions, include-guard patterns (`_PULSE_*_LOADED`), and SPDX headers.

Do NOT touch any other pulse-*.sh modules during Phase 12 work. Stay strictly inside `pulse-simplification.sh`, `pulse-prefetch.sh`, `pulse-wrapper.sh` (guard list only), and the config files.
