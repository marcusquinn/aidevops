<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `approval continuity stale label origin:worker source:ci-feedback signed approval` → 0 hits
- [x] Discovery pass: no open issue or PR. Same pattern as merged GH#36746 (fix-the-fixer), GH#37762 (needs-maintainer-permissions), GH#37993 (persistent): a trusted framework label transition must not stale a signed approval.
- [x] File refs verified at `main` (`approval-helper-continuity.sh:142-191`, `:608-616`)
- [x] Tier: `tier:standard`. Trust-boundary allowlist change plus regression cases in an existing suite.

## Origin

- **Created:** 2026-11-14
- **Created by:** ai-interactive (productivity mission session)
- **Conversation context:** Mining pulse dispatch blocks found #37919 retried every cycle since 2026-11-13T01:58Z with `missing_worker_context signal=brief_scope_untrusted_author`, costing 35-67s per attempt. The maintainer had already signed an approval for it. The pulse's own CI feedback route then invalidated that approval.

## Reproducer

**Symptom command:** `bash .agents/scripts/approval-helper.sh verify 37919 marcusquinn/aidevops`

**Actual output:**

```text
APPROVAL_REASON: stale-or-unproven-continuity
STALE_APPROVAL
```

Post-approval timeline of #37919. Every mutation was made by the maintainer account (the pulse runner):

```text
20:38 labeled status:available, auto-dispatch, tier:standard; unlabeled needs-maintainer-review   (approval lifecycle, allowed)
23:47 status:queued -> status:in-progress -> status:in-review                                     (dispatch, allowed)
01:58 labeled origin:worker, labeled source:ci-feedback, unlabeled origin:interactive              (CI feedback route, REJECTED)
01:58 unassigned, status:in-review -> status:available                                            (allowed)
```

The three 01:58 provenance events come from `_transition_issue_for_redispatch` (`.agents/scripts/pulse-merge-feedback-review.sh:605-642`). They are not in the continuity allowlists, so `_approval_verify_locked_issue_continuity` returns 1 and the approval becomes stale. The body edit (CI feedback section) by the same trusted account is already authenticated by `_approval_continuity_body_edits_authorized`.

## What

A signed issue approval stays valid when an authorized collaborator applies framework provenance labels after signing: `origin:worker`, `origin:interactive`, `origin:worker-takeover`, `source:ci-feedback`, `source:review-feedback`, `source:conflict-feedback`, `source:review-repair`. Any other label change, and any change by an unauthorized actor, still stales the approval.

## Why

Every approved external-contributor issue whose first worker PR fails CI, gets review feedback or conflicts loses its approval through the pulse's own redispatch transition. The issue then needs the maintainer to re-sign with `sudo aidevops approve`, but nothing tells them: the dispatch block reads as `missing_worker_context`. This turns a one-time maintainer decision into a silent permanent block, which costs human time the approval was meant to save.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Narrow allowlist extension following three merged precedents, with mirrored positive and negative regression cases.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/approval-helper-continuity.sh:14-22`: add a provenance label list constant beside `_APPROVAL_OBSERVABILITY_LABEL`.
- `EDIT: .agents/scripts/approval-helper-continuity.sh:142-191`: allow those labels in `allowed_label` (add and remove) in `_approval_continuity_lifecycle_change_allowed`.
- `EDIT: .agents/scripts/approval-helper-continuity.sh:608-616`: accept `labeled`/`unlabeled` events for those labels in the replay loop. The actor authorization below stays in force.
- `EDIT: .agents/scripts/tests/test-approval-helper-content-binding.sh`: in `test_locked_issue_tier_backfill_continuity` (pattern: the GH#36746 fix-the-fixer cases), replay the #37919 sequence with a trusted actor (VERIFIED) and an untrusted actor (STALE_APPROVAL), and add an unrelated label (`hold-for-review`) case that stays stale.

### Files Scope

- `.agents/scripts/approval-helper-continuity.sh`
- `.agents/scripts/tests/test-approval-helper-content-binding.sh`

### Complete Write Surface

- **Callers/readers:** `approval-helper.sh verify` (`_approval_classify_digest_mismatch`), used by `pulse-dispatch-brief-scope.sh:_brief_scope_signed_approval_valid`, NMR approval gates and `ever-NMR` checks.
- **Writers/mutation paths:** none; verification only.
- **Schemas/config:** none. The signed payload format is unchanged.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts`.
- **Migrations/backfills:** N/A. Existing stale approvals such as #37919 verify again once the fix is deployed.
- **Cleanup/rollback paths:** revert the PR.
- **Existing verification/tests:** `.agents/scripts/tests/test-approval-helper-content-binding.sh`.

### Hazards and Compatibility

- **Trust boundary:** provenance labels describe who routed work. They never widen the approved title/body, which keep their separate authenticated-edit checks. Every provenance mutation still requires a live admin/maintain/write actor in the ordered replay.
- **Mixed-version:** older runners keep reporting stale until updated. That fails closed.
- **Idempotency/retry:** n/a.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-approval-helper-content-binding.sh
shellcheck .agents/scripts/approval-helper-continuity.sh
bash .agents/scripts/approval-helper.sh verify 37919 marcusquinn/aidevops   # after deploy: VERIFIED
```

- **Surface mapping:** content-binding suite covers locked-issue continuity.
- **Broad verification trigger:** Not required.

## Acceptance Criteria

- [ ] A trusted post-approval `origin:worker`/`source:ci-feedback` add and `origin:interactive` removal preserves a locked issue approval (VERIFIED).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-approval-helper-content-binding.sh"
  ```

- [ ] The same events by an untrusted actor stay STALE_APPROVAL.
- [ ] Negative: a trusted `hold-for-review` (non-provenance) label change still stales the approval.
- [ ] After deploy, `approval-helper.sh verify 37919 marcusquinn/aidevops` prints VERIFIED and the pulse dispatches #37919 without a new signature.

## Context & Decisions

- Related: GH#36746, GH#37762, GH#37993 (same allowlist pattern), GH#33097 (authenticated body edits), GH#37052 (signed approval authorizes worker-owned scope discovery).
