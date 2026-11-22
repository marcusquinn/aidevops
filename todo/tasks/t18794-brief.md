<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18794: Dispatch: minimize finished-attempt lifecycle comments to cut thread noise while keeping the audit trail

## What

When a dispatch attempt reaches its terminal lease (`DISPATCH_LEASE phase=terminal`), the runner that wrote the attempt minimizes that attempt's superseded lifecycle comments with GraphQL `minimizeComment` (classifier `OUTDATED`). That covers `DISPATCH_CLAIM`, `DISPATCH_LEASE phase=prelaunch|ready|terminal` and `Dispatching worker`. Minimized comments stay in the thread (expandable) and in REST/GraphQL reads, so lease, dedup and checkpoint parsers and audits keep working. The attempt's `CLAIM_RELEASED` / terminal-blocker evidence and the latest live attempt stay visible.

## Why

- Each attempt posts 5–6 comments. Example, #35918 on 2026-10-29: 04:28:29 `DISPATCH_CLAIM`, 04:28:46 lease `prelaunch`, 04:29:36 lease `ready`, 04:43:35 `CLAIM_RELEASED`, 04:43:45 lease `terminal`. A second runner repeated the pattern at 05:03–05:21 and added `Dispatching worker`.
- #35689 reached 140 comments and #35751 reached 125, which buries the human-relevant evidence.
- The maintainer chose minimizing (2026-10-29) over a single edited lease comment. Minimizing keeps the full audit trail for diagnosis and needs no coordinated protocol change across runners.

## How

- Reference pattern: `.agents/scripts/stats-quality-sweep-issues.sh` already calls `minimizeComment`.
- Producers: `.agents/scripts/dispatch-claim-helper.sh` (claim and lease comments), `.agents/scripts/pulse-dispatch-worker-launch.sh` (`Dispatching worker`) and `.agents/scripts/shared-claim-lifecycle.sh` (terminal release).
- Add a best-effort step after the terminal lease is written. With one GraphQL query, list this runner's comments for the finished `attempt_id` (node id, body marker, `isMinimized`). Then minimize the lifecycle comments that are not already minimized. Skip release/blocker evidence. Skip the step entirely when GraphQL budget is low. A failure logs and returns success, so the release path never changes. A small new helper under `.agents/scripts/` is acceptable; its exact name is not known in advance.
- Confirm that no comment parser filters on `isMinimized`, including `dispatch-dedup-helper.sh`, `pr_checkpoint_events.py` and `terminal-blocker-circuit.sh`.

### Files Scope

- .agents/scripts/dispatch-claim-helper.sh
- .agents/scripts/shared-claim-lifecycle.sh
- .agents/scripts/pulse-dispatch-worker-launch.sh

## Acceptance

1. After an attempt's terminal lease, that attempt's claim, lease and dispatch comments are minimized as `OUTDATED`. Release and blocker evidence stays visible.
2. Dedup, lease and checkpoint decisions are unchanged when comments are minimized.
3. A minimize failure, or deferral for low budget, never fails or delays the release.

## Verification

- Existing suites pass: `test-dispatch-lifecycle-comms.sh`, `test-dispatch-claim-helper.sh`, `test-dispatch-atomic-lease.sh`, `test-terminal-blocker-circuit.sh`.
- Live check: after one real terminal attempt, `gh api graphql` on the issue shows `isMinimized: true` for that attempt's lifecycle comments and `false` for its `CLAIM_RELEASED` comment.
