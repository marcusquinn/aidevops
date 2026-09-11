<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18428: Fix Dependabot PR lifecycle convergence

## Pre-flight

- [x] Memory recall: `Dependabot Pulse worker intake source PR lifecycle crypto approval policy hold` → 3 hits; prior guidance requires exact-head authenticity, fail-closed authority, and source-terminal completion.
- [x] Discovery pass: 7 recent commits touched the target files; no related open implementation PR was found.
- [x] File refs verified: four implementation/test files are present at current `origin/main`.
- [x] Tier: `tier:thinking` — the change touches Pulse's self-hosting dispatch and authorization path.
- [x] Seeded draft PR decision recorded: skipped because the owning interactive session is implementing and verifying the fix directly.

## Origin

- **Created:** 2026-09-11
- **Session:** OpenCode interactive session
- **Created by:** ai-interactive with maintainer authorization
- **Conversation context:** Investigation found five open Dependabot PRs that Pulse could classify but did not converge. Three had merged worker replacements while their source PRs remained open; one authentic update waited on cryptographic authority without actionable intake; one bot branch contained a human-authored commit.

## What

Make Dependabot handling converge without weakening the existing trust boundary:

- Route an authentic, allowlisted Dependabot update that lacks independent current-head maintainer authority through the existing worker-intake lifecycle.
- Close an exact-head source Dependabot PR when a completed worker intake has a verified merged replacement, even when the policy hold was not represented by a `needs-maintainer-review` label.
- Never create a duplicate intake when completed-intake evidence already exists but cannot yet prove a merged replacement.
- Keep modified or otherwise unauthentic bot branches fail-closed and classify verified non-Dependabot commit authorship for actionable maintainer review.

## Why

The current author gate returns immediately for authentic Dependabot PRs without cryptographic approval. That bypasses the only reconciliation path capable of creating worker intake or closing a superseded source PR. The source-close path also requires an NMR label that the affected policy-held PRs do not carry, so completed replacement work remains stranded.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** This edits the self-hosting worker-dispatch path and exact-head authorization classification. Security invariants are decided, but regression evidence must prove no authority bypass or unauthenticated write.

## PR Conventions

This is a leaf issue. The implementation PR must use the repository's closing-keyword convention for GH#31795.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The primary interactive session owns implementation through merge and release.
- **Status:** `not-created`
- **Freshness evidence:** Rebased onto current `origin/main`; live affected PR state and source functions revalidated on 2026-09-11.
- **Verification run:** Prework discovery and focused source inspection complete; implementation checks pending.
- **Stale-assumption warning:** Revalidate if another PR changes the author gate, intake marker, or source-close evidence contract.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-merge.sh`
- EDIT: `.agents/scripts/pulse-dependabot-intake.sh`
- EDIT: `.agents/scripts/trusted-dependabot-lib.sh`
- EDIT: `.agents/scripts/tests/test-pulse-merge-issue-sync-authority.sh`
- EDIT: `.agents/scripts/tests/test-pulse-dependabot-intake.sh`
- EDIT: `.agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh`

### Complete Write Surface

No other production files are expected. Reuse `_pm_gate_route_ineligible_author`, `_pulse_route_dependabot_pr_to_worker_issue`, `_pulse_dependabot_close_superseded_source_pr`, `_trusted_dependabot_snapshot_is_authentic`, `gh_pr_edit_safe`, and `_gh_idempotent_comment` rather than adding a parallel lifecycle.

### Implementation Steps

1. Send authentic Dependabot policy holds through the existing route helper after cryptographic authority fails.
2. Reconcile completed intake before creating a new issue, requiring exact source head and a different verified merged replacement but not a redundant NMR label.
3. Record typed authentication failure reasons and classify exact-head commit-author mismatch separately from unavailable or ambiguous evidence.
4. For that verified mismatch only, add a maintainer-review hold and one marker-deduplicated explanatory PR comment; all unknown failures remain write-free.
5. Extend focused tests for positive convergence and negative fail-closed behavior.

### Hazards and Compatibility

- Ordinary GitHub approvals must never substitute for cryptographic authority.
- Unknown, paginated, stale-head, or unavailable snapshots must not trigger a GitHub write.
- A completed issue without a verified merged closer must not cause source closure or duplicate intake.
- Source closure must remain same-repository, exact-head, and replacement-provenance bound.
- Existing explicit NMR holds without completed replacement evidence remain preserved.

### Verification Before Dispatch

```bash
.agents/scripts/tests/test-pulse-dependabot-intake.sh
.agents/scripts/tests/test-pulse-merge-issue-sync-authority.sh
.agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh
.agents/scripts/linters-local.sh --changed
```

## Acceptance Criteria

- [ ] Authentic allowlisted Dependabot without crypto authority calls the intake/reconciliation route and remains unmergeable.
- [ ] Completed worker intake plus verified merged replacement closes the unchanged source PR without requiring NMR metadata.
- [ ] Completed intake without verified replacement fails closed and does not create a duplicate issue.
- [ ] A human-authored commit on an otherwise genuine Dependabot PR produces a deduplicated actionable maintainer hold.
- [ ] Unknown authenticity failures remain write-free.
- [ ] Focused tests and changed-file lint pass.
- [ ] The fix is merged, released, deployed, and observed converging the affected live PRs.

## Rollback

Revert the implementation PR. This restores policy-only holding and disables the new reconciliation/classification paths without altering stored credentials or repository history.
