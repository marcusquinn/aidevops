# t2394: fix(pulse-dedup): post CLAIM_VOID comment on worker fast-fail to unblock cross-runner dispatch

## Session origin

- Date: 2026-04-19
- Context: Interactive diagnostic session reviewing why `marcusquinn/aidevops` pulse dispatched zero issues for multiple cycles while 28 issues sat open and worker capacity was idle (0/24).
- Sibling tasks: t2395 (maintainer-gate exemption), t2396 (reassign normalization), t2397 (HARD STOP age-out), t2398 (hot-deploy).

## What

When `pulse-cleanup.sh` tears down a fast-failing worker (unassigns self, resets to `status:available`), it must also post a `CLAIM_VOID nonce=<same-nonce> runner=<runner> ts=<ts>` comment that invalidates the original `DISPATCH_CLAIM` comment. `dispatch-claim-helper.sh` must treat a matching `CLAIM_VOID` as overriding the `DISPATCH_CLAIM` regardless of the claim's `max_age_s`, freeing the issue for immediate re-dispatch by any runner.

## Why

**Root cause confirmed in production 2026-04-19.** Current behaviour traced on issue #19924 (`marcusquinn/aidevops`):

```
16:04:45 alex-solovyev DISPATCH_CLAIM posted (max_age_s=1800)
16:04:46 alex-solovyev assigns self + status:queued
16:05:57 alex-solovyev worker fast-fails (~1 min) — cleanup removes assignee, sets status:available
         BUT: DISPATCH_CLAIM comment stays valid for its full 1800s TTL
16:04:46 → 16:34:46 marcusquinn's healthy pulse sees ACTIVE_CLAIM and skips the issue
```

Over the diagnostic window, alex-solovyev's runner fast-failed 5+ times in 3 hours (likely running pre-t2392 `model-availability-helper.sh` that fails model probes). Each failure poisoned cross-runner dispatch for 30 minutes while the local state was already reset. `marcusquinn`'s pulse logs show `processed=23 dispatched=0` cycle after cycle — every candidate blocked by stale `ACTIVE_CLAIM: runner=alex-solovyev`.

**Design defect:** the claim TTL (`DISPATCH_CLAIM_MAX_AGE=1800`) was sized for long-running workers, but the cleanup path for fast-failing workers (<1 min) has no hook to invalidate the cross-runner claim. Local state (assignee, status label) is already a second-class signal — the comment-based claim is the only cross-runner coordination, and it has no "void" semantic.

## How

### Files to modify

- **EDIT**: `.agents/scripts/pulse-cleanup.sh:729-735` — `recover_from_launch_failure` (the function containing the unassign+status:available transition).
  - After the `set_issue_status ... "available" --remove-assignee` call succeeds, post a `CLAIM_VOID` comment on the issue. The comment body format:
    `CLAIM_VOID nonce=<nonce> runner=<self_login> ts=<ISO-8601 UTC> reason=<failure_reason>`
  - Nonce must match the most recent `DISPATCH_CLAIM` posted by `<self_login>` on this issue. Fetch via `gh api repos/{slug}/issues/{n}/comments --jq '.[] | select(.user.login==env.RUNNER and (.body | startswith("DISPATCH_CLAIM"))) | .body' | tail -n 1 | sed -n 's/^DISPATCH_CLAIM nonce=\\([a-f0-9]*\\).*/\\1/p'`. If no claim is found, skip — void is not required when there is no claim.
  - Use `gh issue comment` with rate-limit tolerance (`|| true`).

- **EDIT**: `.agents/scripts/dispatch-claim-helper.sh` — the function that parses claim comments (likely `check_active_claim` or `has_active_claim`).
  - After collecting `DISPATCH_CLAIM` comments within the TTL window, collect all `CLAIM_VOID` comments within the same window.
  - For each claim, check whether a matching `CLAIM_VOID` comment (same `nonce=`, same `runner=`) exists with a later `ts=`. If so, the claim is voided — skip it when evaluating `is-active`.
  - Preserve existing claim-age / runner-filter semantics.

### Reference pattern

- Model on `_dispatch_ci_fix_worker` in `pulse-merge-feedback.sh:186-211` — that function already uses a marker-guarded idempotent comment pattern (`<!-- ci-feedback:PR{N} -->`). Apply the same pattern here: a worker posting a second `CLAIM_VOID` for the same nonce is a no-op.
- The nonce extraction + gh issue comment pattern is already present in `dispatch-claim-helper.sh` for `post_dispatch_claim`. Mirror its nonce generation (`openssl rand -hex 16` or equivalent) when reading the original claim.

### Logging

Add to `$LOGFILE`: `[pulse-wrapper] recover_from_launch_failure: posted CLAIM_VOID nonce=${nonce} for #${issue_number} (${repo_slug})` when the void comment succeeds.

## Acceptance criteria

1. `recover_from_launch_failure` in `pulse-cleanup.sh` posts a `CLAIM_VOID` comment after a successful unassign+status:available transition, carrying the same `nonce` as the most recent `DISPATCH_CLAIM` by the same runner.
2. `dispatch-claim-helper.sh` `is-active`/`check_active_claim` returns FALSE for a claim when a matching `CLAIM_VOID` with later timestamp exists.
3. Unit test: given a claim comment at T=0 and a void at T=60s, `is-active` at T=600s returns FALSE.
4. Unit test: given a claim comment at T=0 and no void, `is-active` at T=600s returns TRUE (existing behaviour preserved).
5. Unit test: claim from runner A and void from runner B do NOT cancel — only same-runner voids apply.
6. Log line `posted CLAIM_VOID nonce=...` present in `pulse-wrapper.log` after a simulated launch failure.
7. `shellcheck` passes on both modified scripts.

## Verification

```bash
# Regression test — create in .agents/scripts/tests/test-claim-void-invalidation.sh
.agents/scripts/tests/test-claim-void-invalidation.sh

# Manual — simulate fast-fail on a test issue, verify cross-runner skips stop
shellcheck .agents/scripts/pulse-cleanup.sh .agents/scripts/dispatch-claim-helper.sh
```

Live verification: after deploy + pulse restart, observe `CLAIM_VOID nonce=...` comments on next fast-fail event; confirm next pulse cycle on the same issue no longer reports `ACTIVE_CLAIM: runner=<failed-runner>`.

## Context

- Related merged work: PR #19947 (t2392 model-availability OAuth handling) addressed the *proximate cause* of alex-solovyev's fast-fails but not the *structural amplifier* (stale claims). This fix addresses the amplifier — so any future fast-fail class (not just model-availability) is absorbed without cross-runner poisoning.
- Memory lesson: "deploy gap remote runner version old release" (2026-04-17T03:57:35Z) — cross-runner convergence is eventual; framework must tolerate degraded runners.
- Related: `reference/cross-runner-coordination.md`.
- Priority: HIGH — currently the #1 cause of dispatch starvation in multi-runner deployments.
