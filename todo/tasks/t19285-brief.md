## What

Add a transient terminal-blocker class, `resource_contended`. It covers a shared lock, lease or other serialized resource that another live session holds and that did not free within the helper's bounded wait (for example a sign-in or publication lock). A worker reporting it releases the issue as `status:available`, with no hold, no maintainer label, no runner-capability cooldown and no runner-health burst count, and the issue is redispatched after a short per-issue backoff.

## Why

- Workers have no class for live contention, so the model picks the nearest wrong one. In `~/.aidevops/logs/worker-progress-blockers.jsonl`, 14 `terminal_blocker_captured` events since 2026-10-21 mention a shared sign-in lock, most of them as contention. They span five classes: `unknown` ×5, `runner_capability_unmet` ×4, `input_required:maintainer` ×2, `target_code_blocker` ×2 and `permission_required` ×1. On 2026-11-22, four workers in one managed product repo stopped on the same contended lock within about five hours; each had waited 300s while another live worker held it.
- Each wrong class costs throughput or human time:
  - `input_required:maintainer` sets `status:blocked` and `needs-maintainer-input`, and asks the maintainer something like "Retry in a fresh session once the lock frees?". A person is asked to schedule a retry the pulse could schedule itself.
  - `unknown` is held as `status:blocked` by `_hrff_blocked_exit_holds` (`.agents/scripts/headless-runtime-failure.sh:541-546`, GH#35745) until a brief revision or trusted retry.
  - `runner_capability_unmet` arms the worker-observation capability cooldown (`.agents/scripts/pulse-dispatch-lib-candidates.sh:1479-1501`). The cooldown lasts until the brief changes, a trusted retry arrives or the runner's capability inputs change (GH#37752), so on a repo only this runner can serve, a lock that frees minutes later stalls the issue. These stops also count toward the runner-health burst alarm (`.agents/scripts/pulse-runner-health-helper.sh:74`, GH#38977), which is a false runner fault.
- `.agents/scripts/headless-runtime-contract.sh:201` covers only "a host-local lock or serialization guard held on this runner pending its operator's reconciliation". It does not cover a lock held by a live peer session, which frees by itself.

## How

1. `.agents/scripts/terminal-blocker-circuit.sh`
   - Add `resource_contended` to the class loop in `_terminal_blocker_reason` (line 171) and to the Python `allowed` set in `_TBC_CAPTURE_PY` (line 256).
   - In `terminal_blocker_release_mode` (lines 720-725), return `first` for `resource_contended`, as for `push_policy_timeout | network_policy_timeout | runner_capability_unmet`. No observation or circuit becomes durable.
   - In `_terminal_blocker_recovery` (lines 1112-1124), add the case with `owner="$_TBC_RUNNER_RECOVERY_OWNER"` and an action such as: "Redispatch after the session holding the shared lock or lease ends; no person needs to act. Preserve every lock and publication guard." Do not add the class to `_TBC_REVISION_REARM_REASONS` or `_TBC_RETRY_ONLY_REARM_REASONS` (lines 39-42).
2. `.agents/scripts/headless-runtime-failure.sh`: exempt `resource_contended` from `_hrff_blocked_exit_holds` (line 543) and project an open draft as `available` (lines 1149-1154), in the same way as `runner_capability_unmet`.
3. `.agents/scripts/approval-snapshot-v2.sh`: allow `resource_contended owner=runner-recovery` in the release-line regex (line 106, next to `push_policy_timeout|network_policy_timeout|runner_capability_unmet`) and add an action prefix in the map (line 134).
4. `.agents/scripts/headless-runtime-contract.sh`: after line 201, add guidance. A shared lock, lease or serialized resource held by another live session that did not free within the helper's wait is `TERMINAL_BLOCKER_REASON=resource_contended`, never `input_required`, `unknown` or `runner_capability_unmet`. Name the lock and the observed wait in the dossier, and stop without retrying in-session when the helper says so. Keep line 201 for operator-reconciliation locks.
5. `.agents/scripts/dispatch-backoff-helper.sh`: add a per-issue contention backoff, following the existing graduated `rate_limit` schedule (lines 16-23, 88-90). Count `terminal_blocker_captured` events with `reason == "resource_contended"` for the issue and repo in `~/.aidevops/logs/worker-progress-blockers.jsonl` (the file `pulse-runner-health-helper.sh` already reads). Use a short schedule, for example 10 min, 20 min, 40 min, capped at 60 min, keyed on the latest event, so a redispatch is unlikely to meet the same holder. Report it through the existing `check` exit 1 contract with `BACKOFF_ACTIVE reason=resource_contended_cooldown`. Fail open on read errors, as the helper already does.

### Complexity Impact

`_terminal_blocker_recovery` grows by about 4 lines and `terminal_blocker_release_mode` by about 1. The backoff should be a new function in `dispatch-backoff-helper.sh` called from its `check` path, not an expansion of an existing function past 80 lines.

### Non-goals

- Serializing dispatch across issues that need the same lock (a repository-declared concurrency class). That is a larger scheduling change; capture it separately if contention persists after this fix.
- Reclassifying existing holds. Already-misclassified holds are left to the recovery supervisor.

### Files Scope

- `.agents/scripts/terminal-blocker-circuit.sh`
- `.agents/scripts/headless-runtime-failure.sh`
- `.agents/scripts/approval-snapshot-v2.sh`
- `.agents/scripts/headless-runtime-contract.sh`
- `.agents/scripts/dispatch-backoff-helper.sh`

## Acceptance

- A worker final message with `BLOCKED: ...` and `TERMINAL_BLOCKER_REASON=resource_contended` releases the issue with `Terminal blocker: reason=resource_contended owner=runner-recovery ...` and `Projected state: status:available`. No `status:blocked`, no `needs-maintainer-*` label, and no circuit marker is written.
- The release does not record a `runner_capability_unmet` cooldown and does not count toward the runner-health burst alarm.
- `dispatch-backoff-helper.sh check <issue> <slug>` returns exit 1 with `reason=resource_contended_cooldown` inside the window after such an event, and exit 0 once the window has passed.
- Existing classes, their release modes and the CLAIM_RELEASED validator behaviour are unchanged.

## Verification

- `shellcheck -x` on the changed shell files.
- `.agents/scripts/affected-tests-helper.sh run --base origin/main` passes. It covers `test-terminal-blocker-circuit*.sh`, `test-dispatch-backoff-helper.sh`, `test-approval-helper-content-binding.sh` and `test-claim-release-retry.sh`.
- Product path: after deploy, `jq -r 'select(.event=="terminal_blocker_captured" and .reason=="resource_contended") | [.timestamp,.repo_slug,.issue_number] | @tsv' ~/.aidevops/logs/worker-progress-blockers.jsonl` lists contention stops, and each listed issue is `status:available` (not `status:blocked`) after release. `rg "resource_contended_cooldown" ~/.aidevops/logs/pulse.log` shows the backoff skipping it.
