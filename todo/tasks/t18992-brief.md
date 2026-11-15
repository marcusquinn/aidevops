<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `interactive PR idle handover review-thread worktree ownership` → 0 relevant hits
- [x] Discovery pass: no open issue covers this. GH#36647 (merged #36649) added the `origin:interactive` guard to the repo-wide scan only. t2189 added `_interactive_pr_is_stale`/`_interactive_pr_trigger_handover` for the CI/conflict fix-worker route only.
- [x] File refs verified at `main`: `pr-review-thread-response-scanner.sh:681-728` (`cmd_scan_pr`, the targeted path; no label guard), `:730-741` (`_prrts_labels_block_response`) and `:771-777` (scan-loop guard), `pr-review-thread-response-scanner-worktree.sh:271-306` (`_prrts_apply_expected_worktree_owner`) and `:356-376` (reused-worktree path), `pulse-merge.sh:164-214` (`_pulse_merge_dispatch_review_thread_remediation` → `dispatch-pr`), `pulse-merge-conflict.sh:269-387` (`_interactive_pr_is_stale`, Gates 2 and 3 at `:370-380`), `pulse-merge-process.sh:1304-1320` (handover → fix-worker route), `release-lane-liveness.sh:69-86` (bounded `session-bus-helper.sh show --json` liveness read).
- [x] Tier: `tier:thinking`. This changes the interactive-ownership boundary across the scanner, the handover detector and worker worktree selection.

## Origin

- **Created:** 2026-11-14
- **Created by:** ai-interactive (productivity mission session)
- **Conversation context:** While attributing slow merge passes (GH#38259), wpallstars/seoproanalytics#98 (`origin:interactive`) failed review-thread remediation with `review_worktree_ownership_unverified` 8 times between 07:39Z and 13:44Z, about every 30-80 minutes, and tripped the infrastructure circuit breaker once. It is one unresolved minor CodeRabbit thread (`README.md:577`) plus a `qlty check` ERROR away from merge. The interactive TUI session that claimed #97 (06:04Z) and opened #98 (06:08Z) is still running, with PID alive and claim stamp present. Its session-bus record shows `status=idle` and `last_activity_epoch` at about 06:47Z (7.6h idle), and it has moved on to a different objective. With the current gates, nothing will finish this PR until the user returns to that terminal.

## What

Interactive PRs left idle by a still-running session should reach merge without the user, while keeping GH#36647's rule that workers never write concurrently with an *active* interactive session.

1. **Targeted-path guard (certain defect).** In `cmd_scan_pr` (`dispatch-pr`), apply the same rule as the scan loop. For `origin:interactive` without `origin:worker-takeover`, log `dispatch-pr: <repo>#<n> skipped — interactive PR owned by its session (no worker-takeover)` and return the existing deferred outcome (10) before any worktree work. This stops the misclassified retryable-infrastructure loop. It also closes a latent GH#36647 gap: today, once the owner process exits, this path would launch a worker onto an interactive PR without any handover.
2. **Idle-session handover evidence.** `_interactive_pr_is_stale` treats `status:claimed|in-review` (Gate 2) and an existing claim stamp (Gate 3) as proof of an active human. A long-lived TUI therefore holds a PR indefinitely. Add one evidence path: resolve the stamp's owner session (the claim stamp has `pid` and `worktree_path`; the worktree registry row for that path has `owner_session`), then read it with a bounded `session-bus-helper.sh show <session> --json`, following `release-lane-liveness.sh:69-86`. Treat Gates 2 and 3 as satisfied only when all of these hold: the session's `status=idle`, `last_activity_epoch` is older than `AIDEVOPS_IDLE_SESSION_HANDOVER_SECONDS` (new, default 14400 = 4h), PR activity is older than the same threshold, and the session's current `issue`/`pr` is not this issue or PR. A busy session, recent activity, an unknown or timed-out bus, or a missing mapping keeps the current behaviour (not stale). `no-takeover` still opts out.
3. **Route review-thread blockers through handover.** When the merge pass finds review-thread blockers on an `origin:interactive` PR that item 2 reports as stale, call `_interactive_pr_trigger_handover` (as `pulse-merge-process.sh:1304-1320` already does for CI/conflict) before `dispatch-pr`. Then send one non-waking session-bus `send` notice to the owner session: PR, reason, idle duration, and that adding `no-takeover` reclaims it.
4. **Takeover worktree.** After `origin:worker-takeover`, never transfer or write the live idle owner's worktree. The scanner refuses it today (`:271-306`). Use a worker-owned worktree on the PR head instead. The branch is checked out in the owner's worktree, so verify how `_prrts_prepare_worker_worktree` (`:610`) creates worktrees and use a distinct local branch tracking `origin/<head_ref>` that pushes to `<head_ref>`. The owner's worktree is then stale relative to the remote, which is the normal, recoverable resume case.

## Why

The user launches interactive sessions to go faster. A session that opens a PR and moves on, leaving one minor thread, should not turn that PR into a standing request for user attention. In this case the system knew the session was idle, the PR was one quick fix from merge, and the only gate was a liveness proxy (PID plus claim stamp) that cannot tell "open in a terminal" from "being worked on". Each cycle also re-ran merge gates and the failing remediation for the PR.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Changes the interactive-ownership trust boundary (GH#36647, t2189) and worktree ownership transfer rules across three scripts. Item 1 alone would be standard.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pr-review-thread-response-scanner.sh`: add the interactive guard to `cmd_scan_pr` (`:681-728`), using the labels already fetched at `:702-708`, so no extra API call.
- `EDIT: .agents/scripts/pulse-merge-conflict.sh`: add the idle-session evidence helper and use it in `_interactive_pr_is_stale` Gates 2 and 3 (`:370-380`). Add the owner notice in `_interactive_pr_trigger_handover` (`:407+`).
- `EDIT: .agents/scripts/pulse-merge.sh`: in `_pulse_merge_dispatch_review_thread_remediation` (`:164-214`), or its review-thread callers (`:216-246`), run stale check → handover before `dispatch-pr` for `origin:interactive` PRs.
- `EDIT: .agents/scripts/pr-review-thread-response-scanner-worktree.sh`: takeover-mode worktree selection when the existing worktree has a live owner and the PR carries `origin:worker-takeover`.
- `EDIT: .agents/scripts/tests/test-pr-review-thread-response-scanner-dispatch.sh`, `.agents/scripts/tests/test-pulse-merge-interactive-handover.sh`: add cases.

### Files Scope

- `.agents/scripts/pr-review-thread-response-scanner.sh`
- `.agents/scripts/pr-review-thread-response-scanner-worktree.sh`
- `.agents/scripts/pulse-merge-conflict.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/tests/test-pr-review-thread-response-scanner-dispatch.sh`
- `.agents/scripts/tests/test-pulse-merge-interactive-handover.sh`

### Complete Write Surface

- **Callers/readers:** `pulse-merge.sh` review-thread remediation callers; `pulse-merge-process.sh:1304-1320` (existing handover route, unchanged behaviour); `pulse-merge-author-checks.sh:337-346` (also calls `_interactive_pr_is_stale`; confirm the new evidence path is acceptable there or gate it behind an argument).
- **Writers/mutation paths:** `origin:worker-takeover` label plus the one-time handover comment (existing); one session-bus notice; a worker-owned worktree.
- **Schemas/config:** new env `AIDEVOPS_IDLE_SESSION_HANDOVER_SECONDS` (default 14400).
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts`.
- **Migrations/backfills:** none. The scanner's existing infrastructure-failure state for such PRs clears on the next deferred outcome.
- **Cleanup/rollback paths:** revert; `AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=detect` logs would-handover decisions without acting.
- **Existing verification/tests:** `test-pulse-merge-interactive-handover.sh`, `test-pulse-merge-pr-context.sh`, `test-pulse-merge-origin-interactive-auto-merge.sh`, `test-pr-review-thread-response-scanner-dispatch.sh`, `test-pr-review-thread-response-scanner-worktrees.sh`.

### Hazards and Compatibility

- **Fail closed:** any missing, unknown or timed-out liveness evidence keeps the PR with its session. A busy session, or one whose current issue/PR is this one, is never handed over.
- **Never write the owner's worktree:** no reset, stash, transfer or checkout in it.
- **Bounded bus call:** reuse the timeout pattern from `release-lane-liveness.sh:45-67`; the merge pass must not block on the bus.
- **Bash 3.2:** no associative arrays; `local var="$1"`; explicit returns.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-merge-interactive-handover.sh
bash .agents/scripts/tests/test-pulse-merge-pr-context.sh
bash .agents/scripts/tests/test-pulse-merge-origin-interactive-auto-merge.sh
bash .agents/scripts/tests/test-pr-review-thread-response-scanner-dispatch.sh
bash .agents/scripts/tests/test-pr-review-thread-response-scanner-worktrees.sh
shellcheck .agents/scripts/pr-review-thread-response-scanner.sh .agents/scripts/pr-review-thread-response-scanner-worktree.sh .agents/scripts/pulse-merge-conflict.sh .agents/scripts/pulse-merge.sh
```

- **Surface mapping:** the handover suite covers stale gates; the scanner suites cover the guard and worktree selection.
- **Broad verification trigger:** Not required.

## Acceptance Criteria

- [ ] `dispatch-pr` on an `origin:interactive` PR without `origin:worker-takeover` returns 10 with the skip log and performs no worktree or ownership work.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pr-review-thread-response-scanner-dispatch.sh"
  ```

- [ ] `_interactive_pr_is_stale` returns stale for a live-PID claim only when bus evidence shows idle beyond the threshold, both PR and session are idle, and the session is not on this issue or PR. Busy, recent, unknown or mapping-missing cases return not-stale.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-interactive-handover.sh"
  ```

- [ ] After handover, the review-thread worker uses a worker-owned worktree and pushes to the PR head without touching the owner's worktree.
- [ ] After deploy: wpallstars/seoproanalytics#98, or the next PR in the same situation, stops logging `review_worktree_ownership_unverified` every cycle. It is either handed over and merged, or shows an evidenced different blocker, and the owner session receives one notice.

## Context & Decisions

- GH#36647 keeps workers off interactive PRs to prevent head drift and surprise commits. This preserves that rule for active sessions and narrows "active" from "process exists" to "process exists and is not idle beyond the threshold".
- The 4h default (versus 12h for PR-age-only handover) is justified by the double signal: PR idle and session idle. `no-takeover` remains the explicit opt-out.
- Related: GH#38259 (merge-pass attribution that surfaced this), GH#38290 (upstream routing of review findings).
