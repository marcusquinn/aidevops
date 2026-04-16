<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2151: Phase B — cross-runner coordination for consolidation dispatch

## Origin

- **Created:** 2026-04-16
- **Session:** opencode:interactive
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** t2144 (consolidation cascade fix, PR #19411 merged)
- **Conversation context:** Follow-up from t2144. Phase A (PR #19411) closed two single-runner mechanisms (the `^`-anchored stale-recovery filter regex that did not match HTML-comment prefixes, and a backfill path that bypassed the filter and raced on closed-but-not-yet-consolidated children). The remaining cascade vector is **two pulse runners on different hosts dispatching off the same parent issue independently** — neither sees the other's `gh` write, so both pass dedup, both create children. Production evidence: parent #19321 → child #19341 (marcusquinn pulse) and child #19367 (alex-solovyev pulse, 55 minutes later).

## What

Add a cross-runner advisory lock for consolidation dispatch. Before creating a `consolidation-task` child, the dispatcher applies a `consolidation-in-progress` label on the parent. The label is the lock token — the second runner sees the label, treats it as "another runner is creating a child right now", and skips dispatch. Lock is released when the child issue closes, or after a TTL safety fallback.

The mechanism must:

1. Be atomic-enough at GitHub-API granularity (label-then-create with a short re-check).
2. Not deadlock when the child is created but never closes (TTL fallback).
3. Be visible across runners with no shared filesystem (the `gh` API is the only shared state).
4. Compose cleanly with the existing `_consolidation_child_exists` open/closed-grace check from t2144 — the lock label is an additional gate, not a replacement.

## Why

Phase A (t2144) eliminated all single-runner cascade vectors and added a 30-min closed-child grace window. The grace window incidentally narrows the multi-runner race because a runner that lost the race will see the closed child within the grace window — but only if the first runner's child actually closes within the second runner's pulse cycle. In production, child closure can lag hours behind creation (consolidation worker queues, manual review). The race window in evidence was 55 minutes between dispatches — well within "child still open" territory but the second runner had no way to know the first was about to dispatch.

A label-based advisory lock is the natural fit:

- The `gh` API is the shared coordination plane (all runners use it).
- Labels are atomic-write at the API surface (`gh issue edit --add-label X` is one PATCH).
- Labels are immediately visible to subsequent `gh` reads.
- The existing dispatch-dedup machinery (`dispatch-dedup-helper.sh is-assigned`) already reads labels — the lock fits the same pattern.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Cross-runner coordination design. Multiple plausible lock mechanisms (label, assignee, comment marker, github-actions concurrency), each with different failure modes. The choice is judgment-dependent on TTL behaviour, atomicity guarantees, and how the lock interacts with `dispatch-dedup-helper.sh` and `_consolidation_child_exists`. Not a copy-the-pattern task.

## How

### Files to investigate / modify

- EDIT: `.agents/scripts/pulse-triage.sh` — `_dispatch_issue_consolidation` (apply lock before child create, fail safe if lock already held), `_consolidation_child_exists` (check lock label as a third condition alongside open/closed-grace).
- EDIT: `.agents/scripts/dispatch-dedup-helper.sh` — extend `is-assigned` semantics to recognise `consolidation-in-progress` as a blocking signal (treat like an active claim).
- NEW: `.agents/configs/labels.json` entry for `consolidation-in-progress` (greyish; "Another runner is creating a consolidation child issue").
- EDIT: `.agents/scripts/pulse-triage.sh` — add TTL fallback in `_backfill_stale_consolidation_labels` (clear `consolidation-in-progress` if older than `CONSOLIDATION_LOCK_TTL_HOURS`, default 6h).
- NEW: `.agents/scripts/tests/test-consolidation-multi-runner.sh` — simulate two runners hitting the same parent, assert only one dispatches.

### Reference patterns

- Label-as-lock pattern: `dispatch-dedup-helper.sh is-assigned` already uses status-label semantics (`status:in-review`, `status:claimed`) as blocking signals.
- TTL backfill: `_backfill_stale_consolidation_labels` in `pulse-triage.sh` already auto-clears `needs-consolidation` on already-consolidated parents (added in t2144). Same pattern, different label, different stale criterion.

### Verification

- Test harness simulates two `gh issue list` snapshots arriving 30 seconds apart against the same parent; only one dispatches.
- 7-day production stability window: no parent issue accumulates more than one `consolidation-task` child.

## Acceptance criteria

- [ ] `consolidation-in-progress` label defined in `labels.json` with description and colour.
- [ ] `_dispatch_issue_consolidation` applies the lock label BEFORE creating the child issue, re-reads the parent's labels after applying, and aborts if a competing lock is also present (last-writer-loses tiebreaker via lexicographic actor login).
- [ ] `_consolidation_child_exists` extended to return 0 if `consolidation-in-progress` is present (third blocking signal alongside open child and closed-child-within-grace).
- [ ] `dispatch-dedup-helper.sh is-assigned` honours `consolidation-in-progress` as a blocking signal so unrelated dispatch paths can't sneak past.
- [ ] TTL fallback in backfill: lock auto-released if older than `CONSOLIDATION_LOCK_TTL_HOURS` (default 6).
- [ ] Lock released when child closes (existing label-on-close hook or new one).
- [ ] Multi-runner regression test in `tests/test-consolidation-multi-runner.sh`, 4+ assertions covering happy path, race tiebreaker, TTL expiry, child-close release.
- [ ] All existing `tests/test-consolidation-dispatch.sh` and `tests/test-consolidation-gate-defaults.sh` tests still pass (no regression on Phase A coverage).

## Out of scope

- Single-runner cascade fixes (done in t2144 / PR #19411).
- Changing the consolidation worker behaviour (this task only changes dispatch coordination).
- General-purpose distributed locking infrastructure — this is one label for one use case.

## PR Conventions

Leaf issue (single PR delivering the lock mechanism + test). Use `Resolves #<issue-number>` in the PR body. If investigation surfaces architectural concerns that warrant decomposition, convert to `parent-task` with `For #<issue-number>` keyword discipline.

Ref #19347 (Phase A — t2144)
