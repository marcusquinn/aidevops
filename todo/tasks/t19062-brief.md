<!-- aidevops:brief-schema=v2 -->

# fix(pulse): two jsonl diagnostics have no rotation while every sibling metrics file does

## Origin

- **Created:** 2026-11-16
- **Created by:** ai-interactive
- **Conversation context:** Interactive log review found `Disk quota exceeded` errors in `pulse-wrapper.log` that had already caused a sqlite `disk-io-error`, then measured which local aidevops artifacts actually lack growth control.

## What

Bring `worktree-recovery-timings.jsonl` and `worker-progress-blockers.jsonl` under the same hot-file cap and gzip archive rotation that `rotate_pulse_log` already applies to `headless-runtime-metrics.jsonl` and `resource-metrics.jsonl`, and register both in the storage inventory so their retention is discoverable.

## Why

Quota exhaustion on this host was not cosmetic. `pulse-wrapper.log` holds **47** `Disk quota exceeded` errors between `2026-11-12T11:13Z` and `2026-11-15T06:16Z`, and they propagated into state and dispatch:

```text
date: write error: Disk quota exceeded
{"cleanup_authorized": false, "detail": "disk-io-error", "mode": "observe-only",
 "reason": "OperationalError", "status": "unavailable"}
[worker-lifecycle] reconcile-gap exit=2
.../agents/scripts/pulse-dispatch-lib.sh: line 1490: echo: write error: Disk quota exceeded
```

Every comparable artifact already has an enforced limit, which makes these two the outliers:

| Artifact | Limit | Enforced by |
|----------|-------|-------------|
| `headless-runtime-metrics.jsonl` | hot cap + gzip archive | `pulse-logging.sh:744` |
| `resource-metrics.jsonl` | 25 MiB + gzip archive | `pulse-logging.sh:745` |
| `pulse-wrapper.log` | `PULSE_LOG_HOT_MAX_BYTES` | `pulse-logging.sh:735-741` |
| `pulse-stage-timings` log | 1 MiB | `pulse-logging.sh:725-731` |
| `runtime-bundles` | 30 bundles / 8 GiB / 30 days, live-lease and pin protected | `agent-deploy-bundle.sh:581-651` |
| `agents-backups` | 10 snapshots / 180 days / 4 GiB | `storage-inventory-helper.sh:836` |
| **`worktree-recovery-timings.jsonl`** | **none** | — |
| **`worker-progress-blockers.jsonl`** | **none** | — |

Observed sizes: `worktree-recovery-timings.jsonl` is **36 MB** in a single file (last write `2026-11-14`), `worker-progress-blockers.jsonl` is 764 KB. Both are mode-600 append-only diagnostics. For comparison, `resource-metrics.jsonl` sits at 1.9 MB precisely because it rotates at 25 MiB. Neither unrotated file appears in `storage-inventory-helper.sh`, so no inventory consumer reports their growth.

`runtime-bundles` measured 5.0 GB across 30 bundles and `agents-backups` 1.6 GB — both at or inside their configured limits, so they are working as designed and are explicitly out of scope.

Current quota headroom is adequate (`143 GB` used of a `200 GB` soft / `250 GB` hard `/home` quota, 32% inodes), so this is recurrence prevention, not an emergency.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The reference pattern, insertion point, and both target paths are verified, but the worker must choose the per-file caps and confirm that `_rotate_metrics_jsonl` preserves mode 600 for these two writers rather than copying a literal edit.

## PR Conventions

Leaf task: use a closing keyword referencing this issue.

## How (Approach)

### Worker Quick-Start

```bash
# The exact reference pattern to extend (two existing calls, add two more):
rg -n '_rotate_metrics_jsonl|_prune_metrics_archive' .agents/scripts/pulse-logging.sh

# The two writers and their default paths:
rg -n 'worktree-recovery-timings' .agents/scripts/worktree_recovery_timing.py   # lines 50, 208
rg -n 'WAH_BLOCKER_LOG_FILE' .agents/scripts/worker-activity-helper.sh          # line 53

# Env overrides that MUST be honoured by the rotation call (same precedence as the writers):
#   AIDEVOPS_RECOVERY_TIMING_LOG   -> worktree-recovery-timings.jsonl
#   WAH_BLOCKER_LOG_FILE           -> worker-progress-blockers.jsonl
#   PULSE_DIAGNOSE_BLOCKER_LOG     -> read-side override (pulse-diagnose-helper.sh:63)

# Mode-600 requirement: the recovery-timing writer hard-fails if the file is not
# exactly mode 600 with st_nlink == 1 (worktree_recovery_timing.py:57-59).
# A rotation that recreates the file with any other mode disables logging entirely.

# Measure before/after:
ls -la ~/.aidevops/logs | rg 'jsonl'
```

### Files to Modify

- `EDIT: .agents/scripts/pulse-logging.sh:744-746` — add two `_rotate_metrics_jsonl` calls, honouring `AIDEVOPS_RECOVERY_TIMING_LOG` and `WAH_BLOCKER_LOG_FILE` with the same defaults the writers use, before the existing `_prune_metrics_archive` call.
- `EDIT: .agents/scripts/storage-inventory-helper.sh:843` — add `_storage_emit_record` entries for both files, modelled on the adjacent `resource-metrics` record, stating the chosen cap and the `rotate_pulse_log` ownership note.
- `EDIT: .agents/scripts/tests/test-storage-inventory-helper.sh:132` — extend the existing store-id selection to cover the two new records.

### Complete Write Surface

- **Callers/readers:** `worker-activity-helper.sh:53,752,1147` and `pulse-diagnose-helper.sh:63,1373` read `worker-progress-blockers.jsonl`; `worktree_recovery_timing.py:50,208` and `worktree-archive-helper.md:207` own the recovery-timing log. Readers must tolerate a rotated (shorter) active file — verify neither assumes unbroken history.
- **Writers/mutation paths:** `worktree_recovery_timing.py:43-72` (`emit()`, `O_APPEND|O_NOFOLLOW`, mode 0600, rejects `st_nlink != 1`); `worker-activity-helper.sh` blocker append path.
- **Existing verification/tests:** `.agents/scripts/tests/test-storage-inventory-helper.sh`, `.agents/scripts/tests/test-pulse-diagnose-helper.sh:91`, `.agents/scripts/tests/test-worker-activity-helper.sh:119,582`, `.agents/scripts/tests/test-pulse-current-state-helper.sh:139` — all four use fixture paths and must keep passing.
- **Schemas/config:** archive naming and the metrics archive directory already exist (`_rotate_metrics_jsonl`, `_prune_metrics_archive`); reuse them rather than adding a new location.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` redeploys `.agents/` to `~/.aidevops/agents/`.
- **Migrations/backfills:** the existing 36 MB file must be rotated on the first cycle after deploy, not left permanently above the cap.
- **Cleanup/rollback paths:** `_prune_metrics_archive` already bounds the cold archive; the new files must be covered by it, not by a parallel pruner.

### Implementation Steps

1. Read `_rotate_metrics_jsonl` and `_prune_metrics_archive` in `.agents/scripts/pulse-logging.sh` and confirm how the archive label, cap, and file mode are handled for `resource-metrics`.
2. Confirm the mode-600 contract: `worktree_recovery_timing.py:57-59` disables logging and prints `recovery-timing: log unavailable` if the active file is not exactly mode 600 with a single link. If `_rotate_metrics_jsonl` does not already recreate with 0600, fix that in the shared helper rather than special-casing one caller.
3. Add the two rotation calls at `.agents/scripts/pulse-logging.sh:744-746`, resolving each path with the same env-override precedence as its writer.
4. Choose caps proportionate to the diagnostic window these files serve (`resource-metrics` uses 25 MiB as the precedent) and state the chosen values and rationale in the PR body.
5. Add both storage-inventory records so `storage-inventory-helper.sh` reports their retention.
6. Extend `test-storage-inventory-helper.sh` for the new store ids, and verify the three existing reader tests still pass.
7. Deploy with `setup.sh --non-interactive`, let one pulse cycle run, and include before/after `ls -la ~/.aidevops/logs | rg jsonl` plus a confirmation that the recovery-timing writer did not emit `log unavailable`.

### Hazards and Compatibility

- **Concurrency/atomicity:** `emit()` uses `O_APPEND` without locking, so rotation must use the existing atomic tmp+`mv` approach; a concurrent append during a non-atomic rotation would lose records.
- **Mode preservation:** this is the sharpest hazard. A rotated file recreated with any mode other than 0600, or with more than one hard link, permanently disables recovery-timing logging via the `unsafe-log-file` branch.
- **Migration/rollback:** the first post-deploy cycle produces a one-off size drop as the 36 MB file is archived; state this in the PR body.
- **Mixed-version/backward compatibility:** an older runtime bundle keeps appending to the same path without rotating. Rotation must tolerate a file that grew past the cap between cycles.
- **Idempotency/retry:** rotation runs once per cycle and must be a no-op below the cap — no rotate/recreate thrash.
- **Partial failure/recovery:** consistent with `rotate_pulse_log`'s documented design, any failure must be logged to `WRAPPER_LOGFILE` and must never block the pulse cycle.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-storage-inventory-helper.sh
bash .agents/scripts/tests/test-pulse-diagnose-helper.sh
bash .agents/scripts/tests/test-worker-activity-helper.sh
.agents/scripts/linters-local.sh --changed
# Production-facing evidence after setup.sh --non-interactive and one pulse cycle:
ls -la ~/.aidevops/logs | rg 'jsonl'
rg -n 'rotate_pulse_log: rotated' ~/.aidevops/logs/pulse-wrapper.log | tail -5
rg -c 'recovery-timing: log unavailable' ~/.aidevops/logs/pulse-wrapper.log
```

- **Surface mapping:** the storage-inventory test covers the new records; the diagnose and worker-activity tests cover the readers of the rotated files; `linters-local.sh --changed` covers the edited shell with zero ShellCheck violations; the three production commands prove rotation fired, the active file shrank, and the mode-600 writer contract still holds.
- **Broad verification trigger:** Not required — the change touches one pulse helper, one inventory helper, and one existing test.

### Scope Boundaries

**Hard boundaries:** Do not change `runtime-bundles` or `agents-backups` retention — both were measured inside their configured limits and are working as designed. Never unlink an active log file; follow the existing `rotate_pulse_log` tmp+`mv` convention. Never relax the mode-600 or `st_nlink == 1` contract in `worktree_recovery_timing.py`. Do not touch anything under `~/.aidevops/state/` or `~/.aidevops/.agent-workspace/memory/`. Do not reduce retention so far that worker diagnostics lose their useful window. Do not add a new test runner — extend the three existing tests.

**AI brief owner:** interactive session that filed this issue.

### Files Scope

- `.agents/scripts/pulse-logging.sh`
- `.agents/scripts/storage-inventory-helper.sh`
- `.agents/scripts/tests/test-storage-inventory-helper.sh`

## Acceptance Criteria

- [ ] `worktree-recovery-timings.jsonl` and `worker-progress-blockers.jsonl` are rotated by `rotate_pulse_log` with a documented cap, using the same archive and prune path as `resource-metrics.jsonl`.

  ```yaml
  verify:
    method: codebase
    pattern: "_rotate_metrics_jsonl.*worktree-recovery-timings"
    path: ".agents/scripts/pulse-logging.sh"
  ```

- [ ] Both files are registered in the storage inventory with their retention stated.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-storage-inventory-helper.sh"
  ```

- [ ] Negative guarantee: after rotation the active recovery-timing file is still mode 600 with a single link, so the writer does not fall into its `unsafe-log-file` branch.

  ```yaml
  verify:
    method: manual
    prompt: "After one pulse cycle post-rotation, confirm ls -l shows -rw------- for worktree-recovery-timings.jsonl and that pulse-wrapper.log contains no new 'recovery-timing: log unavailable' line."
  ```

- [ ] Negative guarantee: `runtime-bundles` and `agents-backups` retention logic is unchanged.

  ```yaml
  verify:
    method: codebase
    pattern: "AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT:-30"
    path: ".agents/scripts/setup/modules/agent-deploy-bundle.sh"
  ```

- [ ] Changed-file lint is clean with zero ShellCheck violations.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- Scope narrowed during investigation. The initial hypothesis was broad artifact growth, but `runtime-bundles` (`agent-deploy-bundle.sh:602-604`: 30 days / 30 bundles / 8 GiB, with live-lease and pinned-root protection) and `agents-backups` (10 snapshots / 180 days / 4 GiB) both already enforce limits and were measured inside them. Only these two jsonl files lack any control.
- Not throttling: per `reference/throughput-throttling-policy.md`, resource pressure is fixed at its cause. This task bounds artifact growth; it does not reduce worker concurrency.
- `~/.aidevops/.agent-workspace/tmp` measured 6.8 GB and is the largest consumer, but it is governed by the existing temp/worktree cleanup routines. Deliberately excluded — file a separate issue if measurement shows it also lacks retention.
- Reuse over invention: `rotate_pulse_log` already solved this exact problem for four other files, including the GH#21729 6 GB runaway fixed by GH#21756. Extending it is strictly preferable to a new rotation path.

## Relevant Files

- `.agents/scripts/pulse-logging.sh:704-747` — `rotate_pulse_log`, the insertion point and the pattern to follow.
- `.agents/scripts/pulse-logging.sh:744-746` — the two existing `_rotate_metrics_jsonl` calls plus `_prune_metrics_archive`.
- `.agents/scripts/worktree_recovery_timing.py:43-72` — the mode-600 / `st_nlink == 1` writer contract that rotation must not break.
- `.agents/scripts/worker-activity-helper.sh:53` — `WAH_BLOCKER_LOG_FILE` default and override.
- `.agents/scripts/pulse-diagnose-helper.sh:63` — the blocker-log reader and its `PULSE_DIAGNOSE_BLOCKER_LOG` override.
- `.agents/scripts/storage-inventory-helper.sh:843` — the `resource-metrics` record to model the new entries on.

## Dependencies

- **Blocked by:** nothing.
- **Blocks:** prevention of the observed sqlite `disk-io-error` / `reconcile-gap exit=2` failure class on long-running installs.
- **External:** none.
