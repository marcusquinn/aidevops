<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Plan: `pulse-wrapper.sh` phased decomposition

**Status:** draft — awaiting task ID + GH issue
**Owner:** @marcusquinn
**File under decomposition:** `.agents/scripts/pulse-wrapper.sh` (13,797 lines, 201 functions)
**Target:** orchestrator under 2,000 lines; ~15 sourced modules; no behaviour change
**Why now:** the 2,000-line simplification gate (`_issue_targets_large_files`) blocks any issue whose `EDIT:` targets list `pulse-wrapper.sh`, creating a self-imposed freeze on a critical file that grows ~1,000 lines/month from new features.

This plan is the **authoritative source** for the decomposition work. Subsequent phase PRs do not re-derive the analysis; they execute against this document.

---

## 1. Problem statement

`pulse-wrapper.sh` is the heart of the supervisor pulse. It runs every 120s via launchd across all pulse-enabled repos and performs: instance locking, state prefetch, cleanup, dependency graph, PR merge, worker dispatch, simplification scanning, routines, quality gates, watchdog recovery. It is critical infrastructure.

- **13,797 lines**, **201 functions**. Largest: `dispatch_with_dedup` (370), `dispatch_triage_reviews` (303), `run_weekly_complexity_scan` (298), `_merge_ready_prs_for_repo` (259), `cleanup_worktrees` (250), `main` (211).
- Function size distribution: 5,291 lines in functions ≥100 lines (38%); 5,189 lines in 50–99 line functions (38%); 2,881 lines in smaller functions (21%).
- Six or more prior simplification PRs tightened individual functions. The file kept growing because new subsystems (queue governor, fast-fail, FOSS scan, simplification-state, NMR cache, dep-graph, routines, cycle index) were co-located.
- **Precedent:** t1431 already extracted 12 stats functions (~1,473 lines) into `stats-functions.sh` using an include-guard pattern. The extraction pattern works.
- In-place per-function shrinking cannot clear the gate on a reasonable timeline. Module extraction is the only path.

---

## 2. Constraints

1. **No behaviour change.** Each PR moves code; it does not rewrite it. Diffs between the old definition and the new-location definition must be byte-identical except for leading whitespace if the function was inside a block (it isn't — all are top-level). `git diff -M -w` must show no content changes.
2. **Live system.** Pulse fires every 120s. Each PR must land cleanly; a broken merge silently halts dispatch across every repo until a human notices. Cutover per PR: stop launchd → merge → `setup.sh --non-interactive` → self-check → start launchd. Window: ~60 seconds.
3. **Shared globals.** Pulse has ~100 top-level env vars and 10 mutable `_PULSE_HEALTH_*` counters (see §6). Every extracted module must be sourceable in any order without reordering breaking reads.
4. **Existing tests must keep passing.** Nine `test-pulse-wrapper-*.sh` tests already source the wrapper directly. They must still work after every phase.
5. **No PR exceeds ~2,500 lines of extracted code.** This is a reviewability ceiling, not a hard mechanical limit. Splitting large clusters across two PRs is fine.
6. **Do not refactor during extraction.** Name changes, simplification, dedup, "while I'm here" improvements are forbidden inside extraction PRs. Separate follow-up PRs only. This keeps reviews trivial (`git diff -M` shows rename-only) and eliminates the risk of subtle regressions hiding in a large move.

---

## 3. Cluster map (the authoritative 201-function decomposition)

Produced by call-graph analysis over the current `pulse-wrapper.sh`. Each cluster maps to one new module file. Line numbers are as of the file at the time this plan was written — they will drift; subsequent phases should verify by function name, not by line.

Legend: **In** = number of inter-cluster callers; **Out** = number of inter-cluster callees; **Lines** = total lines in cluster.

| # | Cluster → module | Fns | Lines | In | Out | Risk | Phase |
|---|---|---:|---:|---:|---:|---|---:|
| 1 | `model-routing` → `pulse-model-routing.sh` | 1 | 47 | 1 | 0 | low | 1 |
| 2 | `instance-lock` → `pulse-instance-lock.sh` | 5 | 329 | 1 | 0 | low | 1 |
| 3 | `meta-parse` → `pulse-meta-parse.sh` | 2 | 103 | 1 | 0 | low | 1 |
| 4 | `repo-meta` → `pulse-repo-meta.sh` | 6 | 169 | 3 | 0 | low | 1 |
| 5 | `routines` → `pulse-routines.sh` | 4 | 218 | 1 | 0 | low | 1 |
| 6 | `queue-governor` → `pulse-queue-governor.sh` | 7 | 388 | 1 | 0 | low | 2 |
| 7 | `nmr-approval` → `pulse-nmr-approval.sh` | 10 | 314 | 2 | 0 | low | 2 |
| 8 | `dep-graph` → `pulse-dep-graph.sh` | 3 | 361 | 2 | 0 | low | 2 |
| 9 | `fast-fail` → `pulse-fast-fail.sh` | 13 | 482 | 6 | 0 | med | 2 |
| 10 | `capacity` → `pulse-capacity.sh` | 5 | 193 | 2 | 2 | low | 3 |
| 11 | `logging` → `pulse-logging.sh` | 3 | 272 | 2 | 1 | low | 3 |
| 12 | `watchdog` → `pulse-watchdog.sh` | 7 | 437 | 3 | 2 | med | 3 |
| 13 | `capacity-alloc` → `pulse-capacity-alloc.sh` | 8 | 513 | 2 | 1 | med | 3 |
| 14 | `pr-gates` + `merge` → `pulse-merge.sh` | 14 | 973 | 2 | 2 | med | 4 |
| 15 | `cleanup` → `pulse-cleanup.sh` | 7 | 783 | 2 | 4 | med | 5 |
| 16 | `issue-reconcile` → `pulse-issue-reconcile.sh` | 3 | 402 | 1 | 2 | med | 5 |
| 17 | `simplification` → `pulse-simplification.sh` | 29 | 1,973 | 1 | 2 | high | 6 |
| 18 | `prefetch` → `pulse-prefetch.sh` | 26 | 1,625 | 2 | 4 | high | 7 |
| 19 | `triage` → `pulse-triage.sh` | 10 | 428 | 3 | 2 | high | 8 |
| 20 | `dispatch-core` → `pulse-dispatch-core.sh` | 13 | 1,312 | 5 | 6 | high | 9 |
| 21 | `dispatch-engine` → `pulse-dispatch-engine.sh` | 13 | 954 | 1 | 17 | high | 9 |
| 22 | `quality-debt` → `pulse-quality-debt.sh` | 3 | 270 | 1 | 1 | med | 10 |
| 23 | `ancillary-dispatch` → `pulse-ancillary-dispatch.sh` | 4 | 447 | 1 | 2 | med | 10 |
| 24 | `sync` → inline in orchestrator | 1 | 25 | 0 | 1 | low | — |
| — | **orchestrator** (stays in `pulse-wrapper.sh`) | 4 | 344 | — | — | — | — |
| | **Total extracted** | 197 | 13,018 | | | | |

Orchestrator residual after full extraction: `run_pulse`, `check_session_gate`, `main`, `_pulse_is_sourced` (344 lines) + bootstrap section (435 lines) + `source` lines (~40 lines) = **~820 lines**. Under the 2,000 gate with headroom.

### 3.1 Full function → cluster mapping

*The function list per cluster is long; embedded below so Phase N workers don't have to re-derive it. Sorted by cluster, then by current line number.*

<details>
<summary>Click to expand: all 201 functions with line ranges and cluster assignments</summary>

```text
cluster                fn                                            lines  start..end
---------------------- --------------------------------------------- -----  ------------
model-routing          resolve_dispatch_model_for_labels              47    436..482
instance-lock          acquire_instance_lock                         118    483..600
instance-lock          release_instance_lock                          37    601..637
instance-lock          _handle_setup_sentinel                         57    638..694
instance-lock          _handle_running_pulse_pid                      49    695..743
instance-lock          check_dedup                                    68    744..811
prefetch               _prefetch_cache_get                            23    812..834
prefetch               _prefetch_cache_set                            35    835..869
prefetch               _prefetch_needs_full_sweep                     43    870..912
prefetch               _prefetch_prs_try_delta                        58    913..970
prefetch               _prefetch_prs_enrich_checks                    28    971..998
prefetch               _prefetch_prs_format_output                    36    999..1034
prefetch               _prefetch_repo_prs                             75    1035..1109
prefetch               _prefetch_repo_daily_cap                       61    1110..1170
prefetch               _prefetch_issues_try_delta                     52    1171..1222
prefetch               _prefetch_repo_issues                          92    1223..1314
prefetch               _prefetch_single_repo                          65    1315..1379
prefetch               _wait_parallel_pids                            51    1380..1430
prefetch               _assemble_state_file                           37    1431..1467
prefetch               _run_prefetch_step                             16    1468..1483
prefetch               _append_prefetch_sub_helpers                   91    1484..1574
prefetch               check_repo_pulse_schedule                      68    1575..1642
prefetch               prefetch_state                                109    1643..1751
prefetch               prefetch_missions                              90    1752..1841
meta-parse             _extract_frontmatter_field                     42    1842..1883
meta-parse             _extract_milestone_summary                     61    1884..1944
pr-gates               check_external_contributor_pr                  88    1945..2032
pr-gates               _external_pr_has_linked_issue                  20    2033..2052
pr-gates               _external_pr_linked_issue_crypto_approved      33    2053..2085
pr-gates               check_permission_failure_pr                    58    2086..2143
pr-gates               approve_collaborator_pr                        75    2144..2218
pr-gates               check_pr_modifies_workflows                    38    2219..2256
pr-gates               check_gh_workflow_scope                        40    2257..2296
pr-gates               check_workflow_merge_guard                     94    2297..2390
prefetch               prefetch_active_workers                        69    2391..2459
prefetch               prefetch_ci_failures                           48    2460..2507
capacity-alloc         _append_priority_allocations                   67    2508..2574
capacity-alloc         _check_repo_hygiene                            81    2575..2655
capacity-alloc         _scan_pr_salvage                               32    2656..2687
prefetch               prefetch_hygiene                               68    2688..2755
watchdog               guard_child_processes                          97    2756..2852
watchdog               run_cmd_with_timeout                           40    2853..2892
watchdog               run_stage_with_timeout                        112    2893..3004
watchdog               _watchdog_check_progress                       45    3005..3049
watchdog               _watchdog_check_idle                           27    3050..3076
watchdog               _check_watchdog_conditions                     54    3077..3130
watchdog               _run_pulse_watchdog                            62    3131..3192
orchestrator           run_pulse                                      85    3193..3277
cleanup                cleanup_worktrees                             250    3278..3527
cleanup                cleanup_stashes                                72    3528..3599
orchestrator           check_session_gate                             36    3600..3635
prefetch               prefetch_contribution_watch                    53    3636..3688
prefetch               prefetch_foss_scan                            108    3689..3796
prefetch               prefetch_triage_review_status                 107    3797..3903
prefetch               prefetch_needs_info_replies                   103    3904..4006
issue-reconcile        normalize_active_issue_assignments            189    4007..4195
issue-reconcile        close_issues_with_merged_prs                  106    4196..4301
issue-reconcile        reconcile_stale_done_issues                   107    4302..4408
nmr-approval           _ever_nmr_cache_key                             7    4409..4415
nmr-approval           _ever_nmr_cache_load                           16    4416..4431
nmr-approval           _ever_nmr_cache_with_lock                      18    4432..4449
nmr-approval           _ever_nmr_cache_get                            29    4450..4478
nmr-approval           _ever_nmr_cache_set_locked                     28    4479..4506
nmr-approval           _ever_nmr_cache_set                            17    4507..4523
nmr-approval           issue_was_ever_nmr                             52    4524..4575
nmr-approval           issue_has_required_approval                    36    4576..4611
nmr-approval           _nmr_applied_by_maintainer                     35    4612..4646
nmr-approval           auto_approve_maintainer_issues                 76    4647..4722
simplification         _complexity_scan_check_interval                21    4723..4743
simplification         _coderabbit_review_check_interval              31    4744..4774
simplification         run_daily_codebase_review                      54    4775..4828
simplification         _complexity_scan_tree_hash                     18    4829..4846
simplification         _complexity_scan_tree_changed                  27    4847..4873
simplification         _complexity_llm_sweep_due                      77    4874..4950
simplification         _complexity_run_llm_sweep                      84    4951..5034
simplification         _complexity_scan_find_repo                     29    5035..5063
simplification         _complexity_scan_collect_violations            45    5064..5108
simplification         _complexity_scan_should_open_md_issue          38    5109..5146
simplification         _complexity_scan_collect_md_violations         49    5147..5195
simplification         _complexity_scan_extract_md_topic_label        45    5196..5240
simplification         _simplification_state_check                    52    5241..5292
simplification         _simplification_state_record                   44    5293..5336
simplification         _simplification_state_refresh                  62    5337..5398
simplification         _simplification_state_prune                    58    5399..5456
simplification         _simplification_state_push                     35    5457..5491
simplification         _create_requeue_issue                          85    5492..5576
simplification         _simplification_state_backfill_closed         122    5577..5698
simplification         _complexity_scan_has_existing_issue            41    5699..5739
simplification         _complexity_scan_close_duplicate_issues_b...   55    5740..5794
simplification         _complexity_scan_build_md_issue_body           58    5795..5852
simplification         _complexity_scan_check_open_cap                27    5853..5879
simplification         _complexity_scan_process_single_md_file       115    5880..5994
simplification         _complexity_scan_create_md_issues              51    5995..6045
simplification         _complexity_scan_create_issues                153    6046..6198
simplification         run_simplification_dedup_cleanup               90    6199..6288
simplification         _check_ci_nesting_threshold_proximity         109    6289..6397
simplification         run_weekly_complexity_scan                    298    6398..6695
prefetch               prefetch_gh_failure_notifications              39    6696..6734
cleanup                reap_zombie_workers                            57    6735..6791
repo-meta              get_repo_path_by_slug                          22    6792..6813
repo-meta              get_repo_owner_by_slug                         17    6814..6830
repo-meta              get_repo_maintainer_by_slug                    22    6831..6852
repo-meta              get_repo_priority_by_slug                      23    6853..6875
repo-meta              list_dispatchable_issue_candidates_json        63    6876..6938
repo-meta              list_dispatchable_issue_candidates             22    6939..6960
dispatch-core          has_worker_for_repo_issue                      89    6961..7049
dispatch-core          check_dispatch_dedup                          145    7050..7194
dispatch-core          lock_issue_for_worker                          23    7195..7217
dispatch-core          _lock_linked_prs                               26    7218..7243
dispatch-core          unlock_issue_after_worker                      20    7244..7263
dispatch-core          _unlock_linked_prs                             41    7264..7304
triage                 _triage_content_hash                           22    7305..7326
triage                 _triage_is_cached                              18    7327..7344
triage                 _triage_update_cache                           33    7345..7377
triage                 _triage_increment_failure                      43    7378..7420
triage                 _triage_awaiting_contributor_reply             37    7421..7457
dispatch-core          _count_impl_commits                            48    7458..7505
dispatch-core          _is_task_committed_to_main                    189    7506..7694
triage                 _gh_idempotent_comment                         68    7695..7762
triage                 _issue_needs_consolidation                     75    7763..7837
triage                 _reevaluate_consolidation_labels               43    7838..7880
triage                 _reevaluate_simplification_labels              38    7881..7918
triage                 _dispatch_issue_consolidation                  51    7919..7969
dispatch-core          _issue_targets_large_files                    211    7970..8180
dispatch-core          dispatch_with_dedup                           370    8181..8550
dispatch-core          _match_terminal_blocker_pattern                44    8551..8594
dispatch-core          _apply_terminal_blocker                        42    8595..8636
dispatch-core          check_terminal_blockers                        64    8637..8700
queue-governor         _fetch_queue_metrics                           63    8701..8763
queue-governor         _load_queue_metrics_history                    41    8764..8804
queue-governor         _compute_queue_deltas                          58    8805..8862
queue-governor         _compute_queue_mode                            77    8863..8939
queue-governor         _emit_queue_governor_state                     72    8940..9011
queue-governor         _compute_queue_governor_guidance               53    9012..9064
queue-governor         append_adaptive_queue_governor                 24    9065..9088
capacity               get_max_workers_target                         20    9089..9108
capacity               count_runnable_candidates                      43    9109..9151
capacity               count_queued_without_worker                    63    9152..9214
capacity               pulse_count_debug_log                          21    9215..9235
capacity               normalize_count_output                         46    9236..9281
cleanup                recover_failed_launch_state                   105    9282..9386
fast-fail              _ff_key                                        11    9387..9397
fast-fail              _ff_load                                       33    9398..9430
fast-fail              _ff_query_pool_retry_seconds                   51    9431..9481
fast-fail              _ff_with_lock                                  21    9482..9502
fast-fail              _ff_save                                       36    9503..9538
fast-fail              fast_fail_record                                5    9539..9543
fast-fail              _fast_fail_record_locked                      127    9544..9670
fast-fail              fast_fail_reset                                 5    9671..9675
fast-fail              _fast_fail_reset_locked                        40    9676..9715
fast-fail              fast_fail_is_skipped                           51    9716..9766
fast-fail              fast_fail_prune_expired                         5    9767..9771
fast-fail              _fast_fail_prune_expired_locked                65    9772..9836
dep-graph              build_dependency_graph_cache                  121    9837..9957
dep-graph              refresh_blocked_status_from_graph             118    9958..10075
dep-graph              is_blocked_by_unresolved                      122    10076..10197
dispatch-engine        check_worker_launch                            56    10198..10253
dispatch-engine        build_ranked_dispatch_candidates_json          64    10254..10317
dispatch-engine        dispatch_deterministic_fill_floor             166    10318..10483
merge                  merge_ready_prs_all_repos                      51    10484..10534
merge                  _merge_ready_prs_for_repo                     259    10535..10793
merge                  _is_collaborator_author                        28    10794..10821
merge                  _extract_linked_issue                          40    10822..10861
merge                  _extract_merge_summary                         60    10862..10921
merge                  _close_conflicting_pr                          89    10922..11010
dispatch-engine        _should_run_llm_supervisor                     73    11011..11083
dispatch-engine        _update_backlog_snapshot                       29    11084..11112
dispatch-engine        _adaptive_launch_settle_wait                   37    11113..11149
dispatch-engine        apply_deterministic_fill_floor                 28    11150..11177
dispatch-engine        enforce_utilization_invariants                 25    11178..11202
dispatch-engine        run_underfill_worker_recycler                 104    11203..11306
dispatch-engine        maybe_refill_underfilled_pool_during_act...    77    11307..11383
dispatch-engine        _run_preflight_stages                         130    11384..11513
dispatch-engine        _compute_initial_underfill                     52    11514..11565
dispatch-engine        _run_early_exit_recycle_loop                  113    11566..11678
logging                rotate_pulse_log                               98    11679..11776
logging                append_cycle_index                             80    11777..11856
routines               _routine_last_run_epoch                        25    11857..11881
routines               _routine_update_state                          35    11882..11916
routines               _routine_execute                               77    11917..11993
routines               evaluate_routines                              81    11994..12074
orchestrator           main                                          211    12075..12285
logging                write_pulse_health_file                        94    12286..12379
cleanup                cleanup_stalled_workers                        95    12380..12474
cleanup                cleanup_orphans                                93    12475..12567
cleanup                cleanup_stale_opencode                        111    12568..12678
capacity-alloc         apply_peak_hours_cap                           82    12679..12760
capacity-alloc         calculate_max_workers                          57    12761..12817
capacity-alloc         calculate_priority_allocations                114    12818..12931
capacity-alloc         count_debt_workers                             44    12932..12975
capacity-alloc         check_repo_worker_cap                          36    12976..13011
quality-debt           create_quality_debt_worktree                   42    13012..13053
quality-debt           close_stale_quality_debt_prs                   62    13054..13115
quality-debt           dispatch_enrichment_workers                   166    13116..13281
fast-fail              _ff_mark_enrichment_done                       32    13282..13313
ancillary-dispatch     dispatch_triage_reviews                       303    13314..13616
ancillary-dispatch     relabel_needs_info_replies                     44    13617..13660
ancillary-dispatch     dispatch_routine_comment_responses             38    13661..13698
ancillary-dispatch     dispatch_foss_workers                          62    13699..13760
sync                   sync_todo_refs_for_repo                        25    13761..13785
orchestrator           _pulse_is_sourced                              12    13786..13797
```

</details>

### 3.2 Known inter-cluster edges (Phase N workers: use this, don't re-scan)

Edges are `caller-cluster → callee-cluster (count)`. Direction: caller depends on callee being loaded.

```text
ancillary-dispatch → triage (5), dispatch-core (2)
capacity           → repo-meta (1), dispatch-core (1)
capacity-alloc     → orchestrator (2)
cleanup            → dispatch-core (2), orchestrator (1), prefetch (1), fast-fail (1)
dispatch-core      → triage (5), orchestrator (3), repo-meta (1), fast-fail (1),
                     dep-graph (1), nmr-approval (1)
dispatch-engine    → cleanup (7), prefetch (4), capacity (4), dispatch-core (3),
                     issue-reconcile (3), simplification (3), repo-meta (2),
                     ancillary-dispatch (2), fast-fail (2), triage (2),
                     capacity-alloc (2), orchestrator (2), watchdog (2),
                     quality-debt (1), model-routing (1), nmr-approval (1),
                     logging (1)
issue-reconcile    → fast-fail (2), dispatch-core (2)
logging            → capacity (2)
merge              → pr-gates (5), orchestrator (2), fast-fail (1), dispatch-core (1)
orchestrator       → dispatch-engine (4), instance-lock (3), logging (3),
                     watchdog (2), prefetch (2), dep-graph (2), cleanup (1),
                     routines (1), merge (1)
pr-gates           → merge (4)
prefetch           → watchdog (3), capacity-alloc (3), meta-parse (2),
                     queue-governor (1)
quality-debt       → fast-fail (3)
simplification     → dispatch-core (4), orchestrator (4)
sync               → orchestrator (1)
triage             → dispatch-core (2), repo-meta (1)
watchdog           → prefetch (1), dispatch-engine (1)
```

**Implication for sourcing order in the orchestrator:** because bash allows mutual recursion between sourced files (the orchestrator sources everything upfront before calling any function), exact load order does not matter for correctness. It matters only for diagnosing "function not found" errors during partial rollout.

**Most-called hotspots** (if touched, blast radius is large):

```text
fn                                   called-by-cluster-count
main                                  15  (mostly self-calls — false positives from regex)
prefetch_state                         6
unlock_issue_after_worker              5
dispatch_with_dedup                    5
_extract_linked_issue                  4
run_stage_with_timeout                 4
list_dispatchable_issue_candidates_json 4
has_worker_for_repo_issue              4
_gh_idempotent_comment                 4
_ff_with_lock                          4
_ff_key                                4
_ff_save                               4
normalize_count_output                 4
```

---

## 4. Global state audit

Modules that are extracted must be able to read every global they use. There are three categories.

### 4.1 Configuration constants (read-only after init)

Declared once during the bootstrap section (lines 142–430). Safe for any module to read because they are set before any function is called. Examples:

```text
PULSE_STALE_THRESHOLD PULSE_IDLE_TIMEOUT PULSE_IDLE_CPU_THRESHOLD
PULSE_PROGRESS_TIMEOUT PULSE_COLD_START_TIMEOUT ORPHAN_MAX_AGE
ORPHAN_WORKTREE_GRACE_SECS RAM_PER_WORKER_MB RAM_RESERVE_MB
MAX_WORKERS_CAP DAILY_PR_CAP PRODUCT_RESERVATION_PCT
QUALITY_DEBT_CAP_PCT PULSE_PREFETCH_*  FAST_FAIL_*  EVER_NMR_*
CHILD_RSS_LIMIT_KB CHILD_RUNTIME_LIMIT SHELLCHECK_*
LARGE_FILE_LINE_THRESHOLD PULSE_LLM_STALL_THRESHOLD
PULSE_MERGE_BATCH_LIMIT PULSE_MERGE_CLOSE_CONFLICTING
PIDFILE LOCKFILE LOCKDIR LOGFILE WRAPPER_LOGFILE SESSION_FLAG STOP_FLAG
OPENCODE_BIN PULSE_DIR HEADLESS_RUNTIME_HELPER MODEL_AVAILABILITY_HELPER
REPOS_JSON STATE_FILE QUEUE_METRICS_FILE SCOPE_FILE PULSE_HEALTH_FILE
COMPLEXITY_* DEDUP_CLEANUP_* CODERABBIT_* WORKER_WATCHDOG_HELPER
FAST_FAIL_STATE_FILE DEP_GRAPH_CACHE_FILE DEP_GRAPH_CACHE_TTL_SECS
PULSE_LOG_HOT_MAX_BYTES PULSE_LOG_COLD_MAX_BYTES PULSE_LOG_ARCHIVE_DIR
PULSE_CYCLE_INDEX_FILE PULSE_CYCLE_INDEX_MAX_LINES
SCRIPT_DIR PULSE_START_EPOCH TRIAGE_CACHE_DIR TRIAGE_MAX_RETRIES
ISSUE_CONSOLIDATION_COMMENT_* ROUTINE_STATE_FILE ROUTINE_SCHEDULE_HELPER
ROUTINE_LOG_HELPER STALLED_WORKER_MIN_AGE STALLED_WORKER_MAX_LOG_BYTES
STALE_OPENCODE_MAX_AGE ENRICHMENT_MAX_PER_CYCLE
```

**Rule:** constants stay in `pulse-wrapper.sh` bootstrap. Modules only read them.

### 4.2 Mutable module globals (per-cycle counters)

```text
_LOCK_OWNED
_PULSE_HEALTH_PRS_MERGED
_PULSE_HEALTH_PRS_CLOSED_CONFLICTING
_PULSE_HEALTH_STALLED_KILLED
_PULSE_HEALTH_PREFETCH_ERRORS
_PULSE_HEALTH_DEADLOCK_DETECTED
_PULSE_HEALTH_DEADLOCK_HOLDER_PID
_PULSE_HEALTH_DEADLOCK_HOLDER_CMD
_PULSE_HEALTH_DEADLOCK_BOUNCES
_PULSE_HEALTH_DEADLOCK_RECOVERED
```

These are written by several functions (cleanup, merge, instance-lock) and read by `write_pulse_health_file`. Bash globals are process-wide, so they remain accessible after extraction — but every module that writes them must not declare them `local`. **Rule:** all `_PULSE_HEALTH_*` declarations stay in `pulse-wrapper.sh` bootstrap (lines 398–412) so every module sees the initial zero value. Modules mutate them via bare assignment.

### 4.3 Sourced dependencies (from other scripts)

Pulse sources three helper libraries at startup:

```text
${SCRIPT_DIR}/config-helper.sh          (optional — config_get fallback if missing)
${SCRIPT_DIR}/shared-constants.sh
${SCRIPT_DIR}/worker-lifecycle-common.sh   (provides _validate_int, _sanitize_*)
```

**Rule:** the orchestrator continues to source these once. Extracted modules do NOT re-source them — they rely on the orchestrator having done so. If a module is ever run standalone (tests), the test harness must source them first.

### 4.4 External commands

`gh`, `jq`, `git`, `sqlite3`, `flock` (Linux), `mkdir` (lock primitive), `python3` (used nowhere now that GH#18264 removed it), `awk`, `sed`, `grep`, `ps`, `sysctl`, `wc`, `sort`, `date`, `tr`, `cut`, `mktemp`, `rm`, `ln`, `basename`, `cat`. All universally available. No module needs to declare a tool prerequisite.

---

## 5. Regression safety net (Phase 0 — MUST precede Phase 1)

**No extraction PR lands until Phase 0 is complete and green.**

### 5.1 Characterization test harness

New file: `.agents/scripts/tests/test-pulse-wrapper-characterization.sh`.

Purpose: lock in current observable behaviour of every extractable function with tests that source `pulse-wrapper.sh` (it already has a sourced-vs-executed guard at line 13786, `_pulse_is_sourced`). After each extraction PR, this test file still passes unchanged.

Test style, per the existing `test-pulse-wrapper-*` pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-wrapper.sh"  # sourced, main() not invoked

# Golden: every function we plan to extract must exist after sourcing
EXPECTED_FUNCTIONS=(
  resolve_dispatch_model_for_labels acquire_instance_lock
  release_instance_lock check_dedup prefetch_state
  # ... all 201
)
for fn in "${EXPECTED_FUNCTIONS[@]}"; do
  if ! declare -F "$fn" >/dev/null; then
    echo "FAIL: $fn not defined"; exit 1
  fi
done
echo "PASS: all 201 functions defined after sourcing"
```

Extend with targeted behavioural tests for the 20 most-called functions (list in §3.2). Use `mktemp -d` sandboxes, stub `gh` via PATH shim, feed known inputs, assert on output.

**Estimated size:** ~400 lines, ~20 test cases. One PR before Phase 1.

### 5.2 `--self-check` mode in pulse-wrapper

New top-level flag in `main()`:

```bash
# At top of main(), before lock acquisition:
if [[ "${1:-}" == "--self-check" ]]; then
  # Every expected function defined
  local missing=()
  for fn in $(declare -F | awk '{print $3}'); do :; done
  # Every sourced module loaded (check _*_LOADED guards)
  for guard in _INSTANCE_LOCK_LOADED _PREFETCH_LOADED _DISPATCH_CORE_LOADED ...; do
    if [[ -z "${!guard:-}" ]]; then missing+=("$guard"); fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "self-check: ok"; return 0
  fi
  printf 'self-check: missing: %s\n' "${missing[*]}" >&2
  return 1
fi
```

Add to CI and to the pre-merge gate for every extraction PR. Add to `setup.sh --non-interactive` post-install verification.

### 5.3 `--dry-run` mode

New top-level flag: `pulse-wrapper.sh --dry-run`. Behaviour:

- Sources everything.
- Calls `main` with `gh`, `git`, `setup.sh`, and all destructive commands shimmed to no-op echo.
- Implemented as: `PULSE_DRY_RUN=1` env var checked in a handful of choke points (`gh issue edit`, `gh pr merge`, `git push`, `git worktree`, `rm -rf`, `launchctl`).
- Returns 0 on full cycle completion.

**Estimated size:** ~100 lines of guards added to existing functions. One PR before Phase 1.

### 5.4 Git diff guard for extraction PRs

Shell one-liner that every extraction PR reviewer runs:

```bash
# After the PR: extract should be pure move, no content changes.
git log --format=%H main..HEAD | while read sha; do
  git show --stat "$sha" | grep -E '\.sh' | \
    awk '{ins+=$2; del+=$3} END { if (ins+del > 0 && ins != del) print "NOT_PURE_MOVE" }'
done
```

More robust check: `git diff -w -M --find-renames=90 main..HEAD -- ':!*.md'` should show zero non-rename, non-whitespace content.

### 5.5 Live pulse smoke test after each PR cutover

Manual procedure per merge:

```bash
# 1. Stop launchd pulse
launchctl unload ~/Library/LaunchAgents/sh.aidevops.supervisor-pulse.plist

# 2. Wait for in-flight pulse to complete (check PIDFILE)
while [[ -f ~/.aidevops/logs/pulse.pid ]]; do
  content=$(cat ~/.aidevops/logs/pulse.pid)
  [[ "$content" == IDLE:* ]] && break
  sleep 5
done

# 3. Pull main, rerun setup to deploy
cd ~/Git/aidevops && git pull --ff-only main
./setup.sh --non-interactive

# 4. Self-check and dry-run
~/.aidevops/agents/scripts/pulse-wrapper.sh --self-check
PULSE_DRY_RUN=1 ~/.aidevops/agents/scripts/pulse-wrapper.sh

# 5. One real cycle under manual control, watch the log
~/.aidevops/agents/scripts/pulse-wrapper.sh 2>&1 | tee /tmp/pulse-smoke.log
# Look for ERROR, "function not found", "unbound variable"

# 6. Reload launchd
launchctl load ~/Library/LaunchAgents/sh.aidevops.supervisor-pulse.plist

# 7. Watch the next two live cycles
tail -f ~/.aidevops/logs/pulse.log
```

### 5.6 Rollback plan

If any smoke test fails, or a live cycle errors after launchd reload:

```bash
launchctl unload ~/Library/LaunchAgents/sh.aidevops.supervisor-pulse.plist
git -C ~/Git/aidevops revert --no-edit HEAD
git -C ~/Git/aidevops push origin main
./setup.sh --non-interactive
launchctl load ~/Library/LaunchAgents/sh.aidevops.supervisor-pulse.plist
```

Revertible window: 60–120 seconds per PR. Workers dispatched before the revert continue running on their sandboxed copy of the script (launchd re-exec only affects the next pulse cycle).

---

## 6. Phase sequence

### Phase 0 — Safety net (1 PR, no code moved)

Deliverables: `test-pulse-wrapper-characterization.sh`, `--self-check`, `--dry-run`, git-diff-guard one-liner documented in this plan.

**Gate to Phase 1:** all existing pulse tests green, new characterization test green, `--self-check` and `--dry-run` both exit 0, live pulse cycle completes cleanly after deploy.

### Phase 1 — Leaf extractions, trivial scope (1 PR)

Modules (5): `pulse-model-routing.sh`, `pulse-instance-lock.sh`, `pulse-meta-parse.sh`, `pulse-repo-meta.sh`, `pulse-routines.sh`.

Total moved: ~866 lines. File: 13,797 → ~12,930.

All five are leaf clusters (no outbound inter-cluster edges). They establish the extraction pattern. One PR for all five because each individual diff is small and review benefits from seeing the pattern repeated.

**Worker guidance for Phase 1**:

- Use the "Module template" in §7.1 verbatim.
- Copy functions by exact line range from this plan's §3.1 table. Do NOT edit the function bodies.
- After copy, delete the original definitions from `pulse-wrapper.sh`. Insert `source "${SCRIPT_DIR}/pulse-<cluster>.sh"` immediately after `source "${SCRIPT_DIR}/worker-lifecycle-common.sh"` (line 102).
- The `_sync_todo_refs_for_repo` function (25 lines) stays inline in the orchestrator — too small to extract.

### Phase 2 — Leaf extractions with higher fan-in (1 or 2 PRs)

Modules (4): `pulse-queue-governor.sh`, `pulse-nmr-approval.sh`, `pulse-dep-graph.sh`, `pulse-fast-fail.sh`.

Total moved: ~1,545 lines. File: ~12,930 → ~11,385.

`fast-fail` is called by 6 other clusters — high blast radius. Characterization tests must cover `fast_fail_record`, `fast_fail_is_skipped`, `fast_fail_reset`, `_ff_save`, `_ff_load` before this PR lands.

### Phase 3 — Operational plumbing (1–2 PRs)

Modules (4): `pulse-capacity.sh`, `pulse-logging.sh`, `pulse-watchdog.sh`, `pulse-capacity-alloc.sh`.

Total moved: ~1,415 lines. File: ~11,385 → ~9,970.

`watchdog` calls `run_cmd_with_timeout` / `run_stage_with_timeout`, which are called from every prefetch and stage wrapper. Do NOT extract prefetch before watchdog (although source order doesn't technically matter, diagnosis is easier this way).

### Phase 4 — Merge + PR gates (1 PR)

Module: `pulse-merge.sh` (contains both `pr-gates` and `merge` clusters — they form a 2-cycle: `pr-gates → merge → pr-gates`).

Total moved: ~973 lines. File: ~9,970 → ~8,997.

Co-extracted because splitting them would force one to `source` the other, creating a circular source dependency that bash handles but confuses review.

### Phase 5 — Cleanup + issue reconciliation (1 PR)

Modules (2): `pulse-cleanup.sh`, `pulse-issue-reconcile.sh`.

Total moved: ~1,185 lines. File: ~8,997 → ~7,812.

Note: `cleanup_worktrees` is 250 lines and has its own known silent-skip bug (GH#18346). Do not fix during extraction — file a follow-up.

### Phase 6 — Simplification (1 PR)

Module: `pulse-simplification.sh`.

Total moved: ~1,973 lines. File: ~7,812 → ~5,839.

29 functions, 1,973 lines — the largest single extraction. Low coupling (only `dispatch-core:4` and `orchestrator:4` call into it). Owns its own state file (`simplification-state.json`) and LLM sweep logic. This is where the 2,000-line gate function `_issue_targets_large_files` lives — it is currently in `dispatch-core`, not `simplification`, because it is called from `dispatch_with_dedup`. **Keep it in `dispatch-core`** — moving it would split the dispatch logic.

### Phase 7 — Prefetch (1 PR)

Module: `pulse-prefetch.sh`.

Total moved: ~1,625 lines. File: ~5,839 → ~4,214.

26 functions. Calls watchdog, capacity-alloc, meta-parse, queue-governor — all already extracted (Phases 1–3). This PR validates that the cross-module call graph works end-to-end.

### Phase 8 — Triage (1 PR)

Module: `pulse-triage.sh`.

Total moved: ~428 lines. File: ~4,214 → ~3,786.

10 functions, small but called by dispatch-core and ancillary-dispatch. Extract BEFORE dispatch-core so the latter sources the former.

### Phase 9 — Dispatch (2 PRs — the highest-risk step)

Modules (2): `pulse-dispatch-core.sh`, `pulse-dispatch-engine.sh`.

Total moved: ~2,266 lines. File: ~3,786 → ~1,520.

- **9a**: `pulse-dispatch-core.sh` (1,312 lines, 13 fns, including `dispatch_with_dedup`, `check_dispatch_dedup`, `_is_task_committed_to_main`, `_issue_targets_large_files`). This is the heart of the pulse. Extended characterization tests required before this PR.
- **9b**: `pulse-dispatch-engine.sh` (954 lines, 13 fns, including `dispatch_deterministic_fill_floor`, `_run_preflight_stages`, `run_underfill_worker_recycler`, `_run_early_exit_recycle_loop`). Calls into almost every other module.

**Extra care for 9a**: `dispatch_with_dedup` is called directly from `main()` and from `dispatch_deterministic_fill_floor`. Both call sites must see the extracted function.

### Phase 10 — Tail (1 PR)

Modules (2): `pulse-quality-debt.sh`, `pulse-ancillary-dispatch.sh`.

Total moved: ~717 lines. File: ~1,520 → ~803.

### Phase 11 — Clear the gate (0 code change)

File is now ~803 lines, under the 2,000-line threshold. The `needs-simplification` label can be removed from any issue that was gated on this file alone. The large-file gate continues to fire for `stats-functions.sh` (3,125 lines) and any other files still above the threshold — scope those as separate decomposition plans.

### Phase 12 — Follow-ups (multiple PRs over time, no schedule)

Now that modules exist, per-module simplification is cheap and can go through the normal pulse dispatch. Candidates:

- `dispatch_with_dedup` (370 lines) — split into decision + action.
- `dispatch_triage_reviews` (303 lines) — extract prompt building.
- `run_weekly_complexity_scan` (298 lines) — extract per-language scanners.
- `_merge_ready_prs_for_repo` (259 lines) — extract the per-PR inner loop.
- `cleanup_worktrees` (250 lines) — fix the GH#18346 silent-skip bug in the same PR.
- `_is_task_committed_to_main` (189 lines), `normalize_active_issue_assignments` (189 lines), `calculate_priority_allocations` (114 lines) — split per concern.

Each is now a normal `simplification-debt` issue and a normal worker dispatch, not a special case.

---

## 7. Extraction methodology (subsequent sessions read this)

This is the pattern every phase follows. It is deliberately mechanical so the work is reviewable and reversible.

### 7.1 Module template

New file `.agents/scripts/pulse-<cluster>.sh`:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-<cluster>.sh - <one-line description>
#
# Extracted from pulse-wrapper.sh via the phased decomposition plan:
#   todo/plans/pulse-wrapper-decomposition.md  (Phase N)
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Dependencies on other pulse modules:
#   - <list each, e.g., pulse-triage.sh (calls _gh_idempotent_comment)>
#
# Globals read:
#   - <list>
# Globals written:
#   - <list, usually _PULSE_HEALTH_* counters>

# Include guard — prevent double-sourcing
[[ -n "${_PULSE_<CLUSTER>_LOADED:-}" ]] && return 0
_PULSE_<CLUSTER>_LOADED=1

# <verbatim copy of every function in this cluster, in original order>
```

### 7.2 Orchestrator change per PR

In `pulse-wrapper.sh`, the source block after `worker-lifecycle-common.sh` becomes (growing with each phase):

```bash
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"
# Phase 1 modules
source "${SCRIPT_DIR}/pulse-model-routing.sh"
source "${SCRIPT_DIR}/pulse-instance-lock.sh"
source "${SCRIPT_DIR}/pulse-meta-parse.sh"
source "${SCRIPT_DIR}/pulse-repo-meta.sh"
source "${SCRIPT_DIR}/pulse-routines.sh"
# Phase 2 modules
# ...
```

Each subsequent phase appends lines here. Never rewrite the block — always append at the end of its phase group.

### 7.3 Two-commit PR structure (within one PR branch)

```text
commit 1: Add pulse-<cluster>.sh with copies of functions (no deletions)
commit 2: Remove duplicate definitions from pulse-wrapper.sh, add source line
```

Reason: bash redefines functions on each definition — the last wins. After commit 1, both the inline version and the module version exist; bash picks the later-sourced one. The script still works. After commit 2, only the module version exists. If commit 2 breaks, revert commit 2 only. If the whole PR breaks post-merge, revert the merge commit; the file returns to the pre-PR state.

### 7.4 PR gate checklist (reviewer runs before merge)

- [ ] `bash -n pulse-wrapper.sh` — syntax check
- [ ] `shellcheck pulse-wrapper.sh .agents/scripts/pulse-<cluster>.sh` — lint clean
- [ ] `pulse-wrapper.sh --self-check` — all modules loaded
- [ ] `PULSE_DRY_RUN=1 pulse-wrapper.sh` — full cycle completes
- [ ] `bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh` — golden tests green
- [ ] `bash .agents/scripts/tests/test-pulse-wrapper-*.sh` — pre-existing tests green
- [ ] `git diff -w -M --find-renames=90 main...HEAD -- '*.sh' | wc -l` — should be near zero (pure rename)
- [ ] `wc -l .agents/scripts/pulse-wrapper.sh` — matches plan's projected line count ±100
- [ ] Manual review: the diff inside `pulse-<cluster>.sh` has no edits vs the removed block in `pulse-wrapper.sh`

### 7.5 Cutover steps (maintainer runs after merge)

Documented in §5.5. Condensed:

```bash
launchctl unload sh.aidevops.supervisor-pulse
./setup.sh --non-interactive
~/.aidevops/agents/scripts/pulse-wrapper.sh --self-check && \
  PULSE_DRY_RUN=1 ~/.aidevops/agents/scripts/pulse-wrapper.sh && \
  launchctl load sh.aidevops.supervisor-pulse
tail -f ~/.aidevops/logs/pulse.log  # watch two live cycles
```

---

## 8. What this plan explicitly does NOT do

- **Does not refactor.** Every extraction is a pure move. Improvements are Phase 12, separate PRs.
- **Does not add tests to subsystems that had none.** Characterization tests lock current behaviour, not correctness. If current behaviour has a bug, the bug survives the extraction. Bug fixes are separate PRs.
- **Does not touch `stats-functions.sh`** (3,125 lines, already over the gate). Scope it separately after this plan completes.
- **Does not change the pulse cadence, launchd plist, or supervisor-pulse invocation.**
- **Does not split `dispatch_with_dedup` or other large functions.** They move intact. Per-function simplification is Phase 12.
- **Does not merge or rename clusters.** Cluster boundaries in §3 are authoritative for this plan. Future plans may revisit.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Pulse hangs on next launchd cycle after merge | `--self-check` in CI, manual cutover with smoke test, 60-second rollback via `git revert` |
| Cross-module function not found at runtime | Orchestrator sources all modules upfront. `--self-check` verifies every expected function is defined. |
| Global variable not visible to extracted function | Audit in §4. All constants stay in orchestrator bootstrap. Mutable `_PULSE_HEALTH_*` globals stay in bootstrap. Test with `set -u`. |
| Characterization test false-positive (test passes but behaviour changed) | Tests should cover actual outputs, not just "function exists". Extend characterization tests before each phase for the functions it moves. |
| Line-range drift between plan and current file | Plan §3.1 is authoritative by function name, not line. Phase workers verify by grepping `^<function_name>\(\)` before extraction. |
| Merge conflicts with unrelated pulse PRs in flight | Pause unrelated pulse-wrapper PRs during decomposition phases. Communicate via a tracking GH issue (`parent` issue for the decomposition). Rebase extraction PRs, never merge unrelated changes into them. |
| Worker dispatched against this plan mid-decomposition | Tag all decomposition issues with a `blocked-by:decomposition` label so the pulse skips them until their phase is next. |
| Unknown call site missed by call-graph regex | Edge cases (dynamic dispatch, `eval`, indirect calls) not detected. Characterization test coverage for hotspots in §3.2 catches this. `--self-check` catches missing definitions. |

---

## 10. Open questions (resolve before Phase 0 PR)

1. **Module file location.** `.agents/scripts/pulse-<cluster>.sh` (flat, sibling to `pulse-wrapper.sh`) or `.agents/scripts/pulse/<cluster>.sh` (subdirectory)? Flat is simpler but crowds the `scripts/` dir with 15 new files. Subdirectory is cleaner but requires updating `setup.sh` to deploy the subdirectory.
   - Recommendation: flat. Consistent with `stats-functions.sh` precedent. `setup.sh` already uses `find` or glob to deploy scripts.
2. **Parent task ID.** Claim `t1961` (next in sequence) as the parent decomposition task. Each phase gets a subtask `t1961.N` with its own brief and GH issue.
3. **Pulse pause during each merge.** Manual (`launchctl unload`) or gate via the `STOP_FLAG` mechanism? STOP_FLAG is non-destructive and lets in-flight workers finish — preferred.
4. **Characterization test scope.** Just "functions exist" (cheap, weak) or per-function behavioural tests (expensive, strong)? Recommendation: hybrid. "Exists" check for all 201 + behavioural tests for the 20 hotspots in §3.2.
5. **Extraction authorisation model.** These PRs are high-risk. Recommend **`origin:interactive` with human-in-the-loop review**, not worker dispatch. Rationale: post-merge smoke test requires maintainer laptop access to pause launchd and tail the log. Worker cannot do that.

---

## 11. Next action

1. User reviews this plan; opens GH issue; claims task ID `t1961`; creates `todo/tasks/t1961-brief.md` pointing here.
2. Open child issues for Phase 0 (safety net) as `t1961.0`; assign `origin:interactive`; work in a worktree from `main`.
3. Repeat for Phase 1 once Phase 0 is green.
4. Do NOT dispatch Phase 0 or Phase 1 to a worker. The pulse-wrapper touching its own critical infrastructure via its own worker pool is too fragile. Interactive execution only for Phases 0–9. Phases 10+ may use workers once the pattern is proven.

---

## Appendix A: Session-local analysis artefacts

These files were produced during planning in a scratch directory and are not committed. Regeneration commands in case subsequent sessions want to rebuild them:

```bash
# Function map
awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ {
  if (prev_name) print prev_line "-" (NR-1) "\t" (NR-1-prev_line+1) "\t" prev_name
  prev_name=$1; prev_line=NR
} END { if (prev_name) print prev_line "-" NR "\t" (NR-prev_line+1) "\t" prev_name }
' .agents/scripts/pulse-wrapper.sh

# Call graph (Python snippet — see the source of this plan for the full version)
```

## Appendix B: History

- 2026-03 through 2026-04: six prior simplification issues closed against `pulse-wrapper.sh` (GH#5627, GH#6770, GH#11066, GH#12095, GH#14960, GH#17497). Each tightened individual functions. None reduced total line count materially because new features were added in parallel.
- t1431 (2026-03-10): extracted `stats-functions.sh` (~1,473 lines). Precedent for this plan.
- GH#17422 (2026-04-05): "simplification debt stalled — LLM sweep needed". Root cause: in-place shrinking has reached diminishing returns.
- GH#18042: exempted `simplification` / `simplification-debt` labelled issues from the large-file gate, partially unblocking simplification work on the file itself. This plan executes the remaining work.
- This plan: 2026-04-12.
