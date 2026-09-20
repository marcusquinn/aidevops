<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18457: Approval-bound local marketing changes and rollback

## Pre-flight

- [x] Memory recall: parent query returned no relevant lessons.
- [x] Discovery pass: existing marketing recommendations are handoffs only; no evidence authorizes autonomous account mutation.
- [x] File refs verified: optimization projections, pre-edit and safety-stop guidance exist; new executor targets declared below.
- [x] Tier: thinking; approval provenance, stale-state checks and recoverable multi-file local mutation need explicit design.
- [x] Seeded draft PR skipped: do not anchor security design to unverified code.

## Origin

2026-09-20 OpenCode interactive background request. Parent: t18444. blocked-by:t18454,t18456. Authority is to implement/test guarded tooling, NOT to activate it against a real account/site.

## What

Deliver proposal/diff, approval-bound application and rollback tooling for a narrow allowlist of local version-controlled internal-link/title/meta edits. Higher-impact recommendations remain handoffs. Default is dry-run; no remote account/CMS/publishing operation is implemented here.

## Why

Close the loop for reversible work without treating classification confidence, a generated approval file or an old approval as current authority.

## Tier

Selected tier: `tier:thinking`; consequential cross-component authorization, concurrency and recovery design remains to be proven.

## How

### Files to Modify

- `NEW: .agents/scripts/marketing-action-helper.py` — plan/apply/rollback CLI.
- `NEW: .agents/scripts/marketing_actions.py` — bounded local mutation engine.
- `NEW: .agents/workflows/marketing-actions.md` — exact supported actions and trusted approval/recovery contract.
- `NEW: .agents/scripts/tests/test-marketing-actions.py` — focused isolated-worktree tests and scoped plan fixture.

Reference `.agents/aidevops/performance/03-optimization-projections.md:59-63`, `.agents/workflows/pre-edit.md`, `.agents/reference/safety-stop-recovery.md` and existing runtime tool-approval mechanisms. Never repurpose GitHub issue signatures as generic website mutation consent.

### Files Scope

- `.agents/scripts/marketing-action-helper.py`
- `.agents/scripts/marketing_actions.py`
- `.agents/workflows/marketing-actions.md`
- `.agents/scripts/tests/test-marketing-actions.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/actions-plan.json`

### Complete Write Surface

- **Callers/readers:** `.agents/workflows/marketing-actions.md` receives schema-bound proposals from domain leaves.
- **Writers/mutation paths:** `.agents/scripts/marketing_actions.py` may change only approved exact local project-worktree paths after pre-edit/authority checks.
- **Tests/fixtures:** `.agents/scripts/tests/test-marketing-actions.py` builds isolated synthetic worktrees; actions-plan.json contains no private paths.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json`; document executor-local approval/receipt versioning.
- **Generated/deployed mirrors:** N/A because canonical checkouts, deployed agents, CMS/ad accounts and generated site artifacts are prohibited targets.
- **Migrations/backfills:** N/A because no irreversible migration is supported; before/after receipts support guarded inverse patches.
- **Cleanup/rollback paths:** `.agents/scripts/marketing-action-helper.py` rollback verifies current hashes before restoring owned changes; never reset/clean unrelated work.

### Implementation Steps

1. Implement `plan --input FILE --dry-run` with exact diff, target identity/content hashes, source evidence, allowed action, scope, limits and rollback plan. Exclude noindex/canonical/redirect/delete, budget/bid/negative keywords, campaign/pixel/conversion changes and community moderation/posting from execution.
2. Bind permission to a trusted runtime/operator approval mechanism with exact plan digest, project/worktree, action set, freshness/expiry and owner. An LLM-authored JSON flag or probability is never proof of approval. If the runtime cannot supply trustworthy approval evidence, support plan-only there and fail apply closed.
3. Recheck authority, cancellation, worktree ownership, paths/symlinks, freshness and before-hashes immediately before mutation. Do not auto-commit/push/publish or overwrite unexpected edits. Define atomicity/recovery for interrupted multi-file operations.
4. Record private before/after receipts and verify postconditions; rollback only if current bytes match this operation's after-state. On mismatch preserve evidence and require recovery instead of deleting others' work. Add dry-run diffs for all excluded action families as handoffs only.
5. Require explicit opt-in and validation evidence before any scheduled use. Completion proves guarded tooling in synthetic worktrees, not real-world ROI or authorization to apply proposals.

### Hazards and Compatibility

- **Concurrency/atomicity:** design and test competing edits, approval-check/write races, locks or compare-and-swap and interrupted batch recovery.
- **Migration/rollback:** inverse patches must be evidence-bound and preserve unrelated changes; no destructive global reset.
- **Mixed-version/backward compatibility:** unknown plan/approval/receipt versions fail closed; existing recommendation helpers remain read-only.
- **Idempotency/retry:** exact applied-plan replay is a no-op or clear receipt; partial application cannot blindly repeat changes.
- **Partial failure/recovery:** persist checkpoint, applied/unapplied files and remaining criteria; a fuse never means complete or renews approval.

### Verification Before Dispatch

```bash
python3 .agents/scripts/marketing-action-helper.py plan --input .agents/scripts/tests/fixtures/marketing-decisions/actions-plan.json --dry-run
python3 .agents/scripts/tests/test-marketing-actions.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** plan path proves reviewable diffs; isolated-worktree tests prove denied/stale/forged approval, allowed application, concurrent edits, interruption/replay and guarded rollback. No live account/site is used.
- **Recoverability:** commit focused verified progress; if trusted approval integration is unavailable, retain fail-closed plan mode and document the exact unsupported route, never invent authority. Finish supported adapter proof or preserve the unmet criterion explicitly.

## Acceptance Criteria

- [ ] Supported trusted-approval route applies and verifies only allowed exact local edits in an isolated worktree, with an auditable rollback receipt.
- [ ] Forged/stale/mismatched approval, changed content, cancellation, symlinks and unsupported runtimes/actions cannot mutate files.
- [ ] Rollback preserves unrelated changes and repeated/interrupted execution has deterministic recovery without resets, remote publication or account operations.
