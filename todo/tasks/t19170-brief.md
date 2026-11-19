# fix(recovery): a trusted retry on a queued hold waits hours for the rearm rotation

## Origin

Interactive productivity mission session, 2026-11-19. Trusted retry comments posted at 19:05Z on three queued starter-sync holds were still `status:blocked` 40 minutes later; one sibling retry applied only because the rotation happened to reach it.

## What

The mechanical rearm pass (`terminal-blocker-recovery-helper.sh rearm`) checks queued holds whose issue changed since their last rearm check (a trusted retry, a maintainer reply, a brief revision) before it continues the normal rotation. A retry is then applied on the next rearm pass, not when the rotation reaches the entry.

## Why

- Evidence, this runner on 2026-11-19: 115 queue entries. Each rearm pass checks about 10 entries within its 45 s budget (41 entry checks over 4 passes in `pulse.log`). Rearm runs once per Pulse cycle; 19 cycles in 18.2 h, about 57 min apart (up to 118 min). A full rotation takes about 11 passes, roughly 11 hours, so a retry waits about 5 hours on average.
- One of the retried holds (a private plugin repository) was queued at 15:01Z and had no `rearm_checked_updated_at` stamp by 19:45Z: it had never been rearm-checked.
- `tbr_discover` already runs first in every rearm pass. Its owner-scoped search (`label:"status:blocked" "Terminal blocker" in:comments updated:>=<last pass − 900 s>`) returned exactly the three retried issues with their new `updated_at`. It then skips them because they are already queued. The changed set therefore costs no extra API read.
- A retry that sits for hours means the person comes back to an interactive session to push the issue through. That is the instigation cost aidevops exists to remove.

## How (Approach)

- `.agents/scripts/terminal-blocker-recovery-helper.sh`:
  - `tbr_discover`: after `_tbr_discovery_candidates`, note queued candidates whose search `updated_at` is newer than the entry's `rearm_checked_updated_at` (or which have no stamp). Skip `unclassified_hold`, `answered_hold` and `unexplained_hold` intakes, which the rearm pass never reads. Merge the names into `${TBR_ROOT}/changed_entries` (sorted, unique, written atomically). This runs before the per-candidate loop, so a discovery cut short by its stage cap still records them. A hold that discovery itself queues in the same pass is appended too.
  - New `_tbr_pending_scan_changed`, called first in `_tbr_pending_scan_queue`, only when `entry_mode == rearm`. It checks the listed entries that are still queued with the same `_tbr_run_stage entry _tbr_check_entry` path, adds them to `observed` so the rotation skips them, and never moves a rotation cursor. It uses at most half the remaining queue window, so backoff expiry and closed dependencies (which do not change `updated_at`) still progress through the rotation. Unreached entries and quick read failures stay listed for the next run. An entry that the share cut short returns to the rotation, so a slow entry cannot take half of every run.
  - Identity is resolved the same way the tier scan does. When it cannot be resolved, the list is left intact for the tier scan to retry.
- Ordering only: no release, trust or eligibility rule changes. `_tbr_check_entry` still decides every release (`#aidevops:trust-boundary` unchanged).
- The supervisor `pending` and `--count` modes are unchanged.

### Files Scope

- `.agents/scripts/terminal-blocker-recovery-helper.sh`

## Acceptance Criteria

- `shellcheck .agents/scripts/terminal-blocker-recovery-helper.sh` is clean; `pipe-early-exit-check.sh --scan-files --diff-base origin/main` reports no violations.
- The existing `tests/test-terminal-blocker-circuit.sh` suite (which sources the discovery cases) passes.
- Synthetic run on a temporary `AIDEVOPS_BLOCKER_RECOVERY_DIR` with stubbed reads: a queued entry whose search `updated_at` is newer than its stamp, or which has no stamp, is checked before the rotation's next entry, and every entry is checked once. An equal stamp, a hold intake and an unqueued ref are not listed. The rearm and decided-tier cursors are unchanged by the changed-first check. Unreached entries and quick failures stay listed; cut-short, missing and invalid names are dropped. Supervisor and `--count` modes ignore the list.
- Live: the next rearm pass after deploy logs `blocker-recovery: queue changed-first entry=<key>` for a freshly retried queued hold before rotation entries.
