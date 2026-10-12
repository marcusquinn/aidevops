<!-- aidevops:brief-schema=v2 -->

# fix(pulse): keep process-lifetime EXIT cleanup off the shared RETURN-trap cleanup stack

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `cleanup stack RETURN trap _run_cleanups pulse lifetime lease lock` → 0 hits
- [x] Discovery pass: `prework-discovery-helper.sh` found no open or recently merged PR touching the Pulse lifetime cleanup; origin of the current design is GH#23728 (PR cache EXIT cleanup) and GH#28141 (bundle lease release)
- [x] File refs verified at origin/main b58d326852: direct EXIT trap `.agents/scripts/pulse-wrapper.sh:1517`; stack registration `:1541-1612` (`_save_cleanup_scope` `:1555`/`:1582`, `trap '_run_cleanups' EXIT` `:1568`/`:1592`); cleanup stack `.agents/scripts/shared-constants.sh:1294-1356`; helper `.agents/scripts/shared-gh-wrappers.sh:108-114`; lock release `.agents/scripts/pulse-instance-lock.sh:318`; static ratchet `.agents/scripts/tests/test-pulse-wrapper-canary.sh:193-246`
- [x] Tier: `tier:standard` — three files, one new small function, no new interfaces
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the filing session

## Origin

- **Created:** 2026-10-12
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation after t18675; a live Pulse kept running after its runtime bundle lease and per-cycle caches had disappeared.

## What

The Pulse process-lifetime cleanup (per-cycle PR list caches, benign-block ledger, cycle cache, LLM lock, interrupted-cycle state, cycle index record, efficiency record, instance lock, runtime bundle lease) runs exactly once, at process EXIT, from a dedicated handler. Nested functions that use the shared `push_cleanup`/`_run_cleanups` stack can no longer run it mid-cycle.

## Why

- **Live evidence (2026-10-12):** the launchd Pulse that started 23:20:32Z on the v3.39.21 bundle had no runtime-bundle lease file at ~00:09Z, about 10 minutes before its terminal cycle-index row (00:19:21Z), while the deterministic pipeline was still running. After that row, and while the process was still alive, both per-cycle dirs `$TMPDIR/aidevops-pulse-pr-list-cache-<pid>` and `...-provider-cache-<pid>` had been deleted. Neither is released by design before exit; only the instance lock is (deliberately, before the LLM supervisor, `pulse-wrapper.sh:1822-1826`).
- **Mechanism:** `pulse-wrapper.sh:1555-1596` pushes the lifetime cleanups onto the shared function-scoped stack and replaces the direct EXIT trap with `trap '_run_cleanups' EXIT`. In bash, a RETURN trap set inside a function stays installed after that function returns (the caller's saved trap is only restored when the caller had one), so it fires again at each caller's return. Every fire runs `_run_cleanups`, which executes the current scope and pops the save stack. `_gh_wrapper_enter_cleanup_scope` (`shared-gh-wrappers.sh:108-114`, used by `gh_issue_edit_safe`, `gh_issue_comment`, `gh_pr_comment`, `gh_create_issue`, `gh_create_pr`, `gh_issue_close_safe`, `gh_pr_edit_safe`, `gh_write_batch`) even sets the trap inside the helper, so it fires at the helper's own return, pops straight back to the Pulse lifetime scope, and the wrapper's return then runs the whole lifetime list.
- **Reproduction with the deployed v3.39.22 `shared-constants.sh` under bash 5.3.20** (no network, stubs only): a stage function calling a wrapper that uses `_gh_wrapper_enter_cleanup_scope` printed the stubbed "lease release / instance lock release" before "stage continues after wrapper"; the same happened inside `$(...)` and in a `( ... ) &` stage subshell (as `_pulse_run_stage_with_timeout` runs stages), where the side effects hit the filesystem with the parent PID (`$$`). A plain `_save_cleanup_scope; trap '_run_cleanups' RETURN` helper called from a trap-less stage reproduced the same early run at the stage's return.
- **Impact:** the lease protecting the executing bundle from setup pruning (the t18675 safety contract) disappears mid-cycle; per-cycle PR list caches are deleted, so later gates re-fetch and the recreated dirs are never removed (120 leaked `aidevops-pulse-pr-list-cache-*` dirs observed in the temp root); the cycle-local benign-block ledger is deleted, so dedup-blocked candidates are re-evaluated in the same cycle; the instance and LLM locks can be released early. The `_dispatch_cleanup_cycle_cache` step of the original direct trap is also silently dropped whenever the stack trap replaces it.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** a bounded refactor of one registration block plus a small handler and a static test update; bash trap semantics need care but the change removes, rather than adds, coupling.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-instance-lock.sh` — add `_pulse_exit_cleanup` after `release_instance_lock` and list it in the module header.
- `EDIT: .agents/scripts/pulse-wrapper.sh` — register `trap '_pulse_exit_cleanup' EXIT` at `:1517`; remove `_pulse_pr_cache_cleanup_scope`, `_pulse_rm_rf`, both `_save_cleanup_scope`/`push_cleanup`/`trap '_run_cleanups' EXIT` blocks; record the two per-cycle cache dirs in dedicated globals that the handler removes; add `_pulse_exit_cleanup` to `_pulse_execute_self_check`'s expected functions.
- `EDIT: .agents/scripts/tests/test-pulse-wrapper-canary.sh` — replace the `trap '_run_cleanups' EXIT` / push-registration ratchet with checks that the dedicated handler is installed before `acquire_instance_lock` and that no lifetime cleanup is pushed onto the shared stack; assert the canary run removes its per-cycle cache dirs.

### Complete Write Surface

- **Callers/readers:** `pulse-wrapper.sh` `main()` is the only registrant; `release_instance_lock`, `aidevops_runtime_bundle_lease_release`, `_pulse_cycle_index_record_once`, `_pulse_cycle_state_finish_interrupted`, `_pulse_efficiency_cycle_finish`, `_pulse_release_llm_lock`, `_dispatch_cleanup_benign_blocks_cycle`, `_dispatch_cleanup_cycle_cache` keep their existing idempotent contracts.
- **Writers/mutation paths:** the t3033 re-exec path (`pulse-wrapper.sh:1868-1875`) already releases the lock and lease explicitly; unchanged.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-wrapper-canary.sh` (real `pulse-wrapper.sh --canary` in a sandbox HOME plus static ratchets).
- **Schemas/config:** N/A because no config key changes.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` into the runtime bundle; no generated copy.
- **Migrations/backfills:** N/A because leaked historical cache dirs are already removed after seven days by `.agents/scripts/setup/modules/migrations.sh:112-113`.
- **Cleanup/rollback paths:** `git revert` restores the stack-based registration.

### Implementation Steps

1. `pulse-instance-lock.sh`: add `_pulse_exit_cleanup` — remove `_PULSE_EXIT_PR_LIST_CACHE_DIR` and `_PULSE_EXIT_PR_LIST_PROVIDER_CACHE_DIR` when set, then call, each with `|| true`, `_dispatch_cleanup_benign_blocks_cycle`, `_dispatch_cleanup_cycle_cache`, `_pulse_release_llm_lock`, `_pulse_cycle_state_finish_interrupted`, `_pulse_cycle_index_record_once`, `_pulse_efficiency_cycle_finish`, `release_instance_lock`, `aidevops_runtime_bundle_lease_release` (the original direct-trap order, caches first, bundle lease last).
2. `pulse-wrapper.sh:1517`: `trap '_pulse_exit_cleanup' EXIT`.
3. `pulse-wrapper.sh:1541-1612`: drop the stack registration; set the two globals immediately after exporting the per-cycle cache dir variables (only this process's own dirs, never inherited environment values).
4. Update the canary test as listed above and run the verification below.

### Hazards and Compatibility

- **Concurrency/atomicity:** the handler runs only in the main shell (subshells reset EXIT traps); each callee keeps its own ownership checks (`_LOCK_OWNED` + PID match, lease PID file, LLM lock PID, executor-owner checks).
- **Migration/rollback:** no ordering concerns; revert restores the previous registration.
- **Mixed-version/backward compatibility:** the shared stack is untouched, so other scripts keep their behaviour; only Pulse stops depending on it for process-lifetime resources.
- **Idempotency/retry:** every step is idempotent; the voluntary pre-LLM lock release and t3033 re-exec release paths stay valid.
- **Partial failure/recovery:** `|| true` per step guarantees the lock and lease releases still run if an earlier step fails.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/pulse-instance-lock.sh .agents/scripts/pulse-wrapper.sh .agents/scripts/tests/test-pulse-wrapper-canary.sh
bash .agents/scripts/tests/test-pulse-wrapper-canary.sh
/bin/bash .agents/scripts/tests/test-pulse-wrapper-canary.sh
```

- **Surface mapping:** production proof is a live launchd Pulse cycle on the released bundle: its lease file and both per-cycle cache dirs exist until the process exits, and a cycle-index row is still written once.
- **Broad verification trigger:** Not required — no shared contract, root tooling or release infrastructure change.

### Scope Boundaries

**Hard boundaries:** do not change `shared-constants.sh` cleanup-stack semantics or `_gh_wrapper_enter_cleanup_scope` in this task; do not change the deliberate pre-LLM instance lock release or the t3033 re-exec path.

**Not in scope (follow-up):** the shared cleanup stack itself — RETURN traps leak into trap-less callers and `_gh_wrapper_enter_cleanup_scope` fires at its own return, so wrapper and helper scopes elsewhere can still run a caller's cleanups early. Tracked as a separate owner-aware `_run_cleanups` task.

**AI brief owner:** interactive maintainer session that filed this task.

### Files Scope

- `.agents/scripts/pulse-instance-lock.sh`
- `.agents/scripts/pulse-wrapper.sh`
- `.agents/scripts/tests/test-pulse-wrapper-canary.sh`

## Acceptance Criteria

- [ ] Pulse registers the dedicated handler and no lifetime cleanup on the shared stack.

  ```yaml
  verify:
    method: codebase
    pattern: "trap '_pulse_exit_cleanup' EXIT"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```

- [ ] ShellCheck reports no findings for the changed files.

  ```yaml
  verify:
    method: bash
    run: "shellcheck -x .agents/scripts/pulse-instance-lock.sh .agents/scripts/pulse-wrapper.sh .agents/scripts/tests/test-pulse-wrapper-canary.sh"
  ```

- [ ] The canary test passes, including lock release and per-cycle cache removal at exit.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-canary.sh"
  ```

- [ ] A live Pulse cycle on the released bundle keeps its lease and per-cycle cache dirs until exit.

  ```yaml
  verify:
    method: manual
    prompt: "During a live Pulse cycle, confirm runtime-bundles/.leases/<bundle>/<pid> and both per-cycle PR list cache dirs exist until the process exits"
  ```
