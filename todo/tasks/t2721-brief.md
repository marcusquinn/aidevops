<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2721: remove auto-dispatch label and make dispatch the default behaviour

**Type:** parent-task (investigation + phased implementation)
**Parent issue:** GH#20402
**Status:** decomposed; phases filed one at a time as prior phase lands
**Tier:** tier:thinking (for planning decisions; phases are mostly tier:standard)

## Session origin

Interactive session 2026-04-21. User observed doc-level inconsistency — `.agents/AGENTS.md:102` says "Always add `#auto-dispatch` unless an exclusion applies" while `.agents/workflows/plans.md:64` and `.agents/workflows/new-task.md:108` treat the label as a gated quality signal. Request: resolve inconsistency by removing the label entirely and making dispatch the default, with explicit opt-out signals.

## What

Remove the `auto-dispatch` GitHub label as a positive opt-in requirement for pulse dispatch. Invert the semantics so the pulse dispatches any open issue unless an explicit opt-out signal is present (blocker labels, decomposition markers, active claim, closed state).

Retain the label as a recognised-historical-no-op for backward compatibility — old docs, contributor-filed issues, and pre-existing TODO entries should not error. But:

- The framework stops ADDING it.
- Docs stop TEACHING it.
- Dispatch logic stops REQUIRING it.
- Self-assignment logic inverts from "skip when present" to "skip unless `assignee:` set".

## Why

The `auto-dispatch` label is vestigial. It predates the current pulse architecture where comprehensive opt-out machinery already exists:

- **Label blockers** (`pulse-dispatch-core.sh:821`): `persistent | supervisor | contributor | quality-review | on hold | blocked | parent-task | meta`
- **Label opt-outs**: `no-auto-dispatch`, `needs-maintainer-review`, `hold-for-review`, `status:done`, `status:resolved`
- **Claim state**: `status:in-review | status:claimed | status:queued | status:in-progress` + non-self assignee
- **Server-side validators**: `tier-simple-body-shape-helper.sh` (t2389), `pre-dispatch-eligibility-helper.sh` (t2424), `pre-dispatch-validator-helper.sh` (GH#19118)
- **Pulse-level circuit breakers**: rate-limit breaker (t2690), completion-sweep, NMR auto-approval trip detection

With this opt-out machinery, the `auto-dispatch` label adds no dispatch-gating value. It only adds ceremony:

1. Doc inconsistency — contributors reading AGENTS.md vs plans.md get opposite defaults.
2. Dormant issues — filed-without-tag issues sit indefinitely even when dispatchable.
3. Double-gating — doc-level tag guidance duplicates server-side quality validators.
4. Assignment coupling — t2157/t2218/t2406 conditional self-assignment logic exists solely to handle the label; collapses when we invert.

## Why phased

Four reasons:

1. **Review isolation.** Each phase is independently reviewable. A 7-file mega-PR is harder to approve than 7 focused PRs.
2. **Rollback granularity.** If Phase 4 (behaviour flip) misbehaves, revert only that PR.
3. **Scope verification.** Phase 1 inventory gates phases 2-7. If the inventory surfaces unexpected coupling, re-scope before committing to the flip.
4. **Observability.** The pulse runs between phases. Audit logs from Phases 2-3 (label additions, opt-out clarifications) inform Phase 4's behaviour-flip feature-flag logic.

## Measured migration scope

Verified during t2721 investigation (see parent #20402 body):

- 92 total open issues across 14 pulse-enabled repos.
- 4 issues would newly become dispatchable under default-flip (not hundreds, as initially estimated).
- 81 of the 85 issues lacking `auto-dispatch` are already blocked by other signals.

Migration cost is effectively zero.

## How (phase map)

| Phase | Task ID | Deliverable | Tier | Est |
|---|---|---|---|---|
| 1 | t2722 | `todo/tasks/t2721-inventory.md` + briefs + TODO entries | thinking | 1h |
| 2 | TBC | `needs-credentials` label + `reference/dispatch-blockers.md` | standard | 30m |
| 3 | TBC | Backfill 4 at-risk issues | standard | 30m |
| 4 | TBC | `pulse-dispatch-core.sh` flip + feature flag | standard | 1h |
| 5 | TBC | Strip label-adding from 6 scanners + 3 wrappers | standard | 1h |
| 6 | TBC | Invert t2157/t2218/t2406 self-assignment carveouts | standard | 1h |
| 7 | TBC | Doc + test sweep; close parent | standard | 1h |

Total: ~6h spread across 7 PRs over N days. Non-final PRs use `Ref #20402`. Final PR (Phase 7) uses `Closes #20402`.

## Acceptance (parent closes when)

1. All 7 phase PRs merged.
2. Pulse default behaviour is "dispatch open issues unless blocker present" (confirmed via audit log over 24h).
3. Zero new `auto-dispatch` labels added by framework code (scanners, wrappers, helpers).
4. Test suite passes with inverted assertions.
5. Docs have zero "when to add `#auto-dispatch`" instruction (only historical references to the retired label).
6. Label retained as recognised-historical-no-op (no errors when encountered).

## Out of scope

- Removing other dispatch-gating labels (`parent-task`, `needs-maintainer-review`, `hold-for-review`, etc.) — these have distinct semantic purposes that `auto-dispatch` lacks.
- Changing `origin:interactive` vs `origin:worker` model — orthogonal.
- Changing server-side pre-dispatch validators — they are the foundation this change relies on and should stay stable.
- Migrating TODO.md `#auto-dispatch` tags — historical bookkeeping, no behavioural impact.

## Files Scope

Phase 1 only (other phases will add scope when filed):

- `todo/tasks/t2721-brief.md`
- `todo/tasks/t2721-inventory.md`
- `todo/tasks/t2722-brief.md`
- `TODO.md`
