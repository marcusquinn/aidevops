<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18118: Bind external approvals and advisory merge evidence to immutable snapshots

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `issue 27530 unknown non-required checks maintainer gate aliases content-bound approval` → 0 hits — no reusable indexed lesson; current-session evidence is recorded below
- [x] Discovery pass: 23 recent commits / 0 merged search hits / 0 open search hits touched or overlapped the target approval and merge files; inspect the recent commits before editing because these files are active
- [x] File refs verified: 10 source/test/reference surfaces checked, all present at `origin/main` after task-ID allocation
- [x] Tier: `tier:thinking` — security trust-boundary redesign across approval, merge, configuration, tests, and compatibility policy
- [x] Seeded draft PR decision recorded: skipped — a seed would prematurely anchor a novel security design before its approval-version and migration trade-offs are resolved

## Origin

- **Created:** 2026-07-13
- **Session:** OpenCode interactive security review
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** None; this is a trusted replacement task, not a child of the external report
- **Blocked by:** None
- **Conversation context:** External report GH#27530 identified Pulse blocking on optional failures. Review found a broader trust gap: current approval signatures bind only target identity and timestamp, so later external content or PR-head drift does not invalidate authority. The maintainer requested a clean, maintainer-authored `tier:thinking` task rather than approving external issue content.

## What

Create a versioned, canonical approval snapshot that binds cryptographic authority to the exact external content and code state a maintainer reviewed. Issue approval may authorise development of that immutable issue snapshot, but must not implicitly authorise a future or changed external PR head. External/fork merge must require verified current-head authority at the final merge call.

Separately harden Pulse's final check snapshot so duplicate maintainer-gate aliases are reported as one logical policy result without becoming advisory. A non-required review-provider failure may be advisory only when repository configuration explicitly names it and current-head authoritative review evidence has passed. Unknown, required, maintainer/NMR, malformed-evidence, and external rate-limit cases remain fail-closed.

## Why

`approval-helper.sh:782-785` signs `APPROVE:<type>:<slug>:<number>:<timestamp>` without a content digest or PR head SHA. Locking reduces new comments but does not make issue/PR bodies, existing comments, links, linked references, or PR commits immutable. Meanwhile `pulse-merge-required-checks.sh:32-63` merges CheckRuns and commit statuses by exact name, so the maintainer workflow's stable context, legacy context, and reusable-workflow CheckRun are counted as separate failures. Its classifier at lines 145-182 has only one hard-coded advisory pair and cannot consume structured current-head evidence.

The task must close both gaps without recreating the GH#17671 external-contributor auto-merge vulnerability or disabling the stale-recovery/cost circuit breakers that stop runaway automation.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — approval producer/consumer, merge classifier, configuration/docs, and tests must coordinate.
- [ ] **Every target file under 500 lines?** No — the approval and merge helpers exceed 500 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — canonical snapshot and compatibility policy require design.
- [ ] **No judgment or design decisions?** No — approval versioning, migration, and final-call authority are architectural choices.
- [ ] **No error handling or fallback logic to design?** No — malformed, stale, mixed-version, API-failure, and partial-update paths must fail closed.
- [ ] **No cross-package or cross-module changes?** No — signing, verification, merge, configuration, and documentation interact.
- [ ] **Estimate 1h or less?** No — estimated eight hours.
- [ ] **4 or fewer acceptance criteria?** No — security invariants require broader regression coverage.
- [x] **Dispatch-path classification:** `pulse-merge.sh` is a self-hosting dispatch/merge path; keep `#auto-dispatch` and force `tier:thinking`.

**Selected tier:** `tier:thinking`

**Tier rationale:** Novel security architecture touches cryptographic approval semantics and the final auto-merge trust boundary. The worker must reason about content canonicalisation, legacy compatibility, current-head binding, and mixed-version deployment rather than copy an existing pattern.

## PR Conventions

This is a leaf task. The implementation PR uses a closing keyword for the new trusted GitHub issue. Reference GH#27530 only as non-authoritative provenance; never use it as the closing target or implementation instruction source.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Security design choices remain open and recent commits touched the same helpers; an unverified code seed would create anchoring risk.
- **Status:** `not-created`
- **Freshness evidence:** Discovery and file verification ran against current `origin/main` after t18118 allocation.
- **Verification run:** Brief validation only; implementation tests are intentionally unrun.
- **Stale-assumption warning:** Re-run discovery if approval, Pulse merge, review-gate, or maintainer-gate code changes before dispatch.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/reference/incident-gh17671-supply-chain.md:1-112`, then `.agents/scripts/approval-helper.sh:404-451,535-651,760-898` — establish the non-negotiable external-contributor defence and current signing/verification contract.
- **Then read:** `.agents/scripts/pulse-merge-gates.sh:358-548`, `.agents/scripts/pulse-merge.sh:292-458,1374-1413`, and `.agents/scripts/pulse-merge-required-checks.sh:32-262` — map every consumer and the final merge ordering.
- **Load only if configuration is chosen:** `.agents/scripts/review-gate-config-helper.sh` and `.agents/reference/repos-json-fields.md:102-125` — extend the existing `review_gate` schema instead of inventing another control plane.
- **Load only if complexity gates approach thresholds:** `.agents/reference/large-file-split.md` — extract new canonicalisation/snapshot helpers before growing existing long functions.
- **Why:** The fix must be self-validating at the final bypass call, not merely inherited from upstream labels or workflow status names.
- **Stop when:** the worker can enumerate the signed snapshot fields, approval-version compatibility matrix, final merge guard ordering, configured advisory evidence, and focused test matrix.

### Worker Quick-Start

```bash
# Confirm current approval payload and consumers.
rg -n 'payload="APPROVE|_verify_comment_signature|_has_maintainer_crypto_approval|_external_pr_linked_issue_crypto_approved' \
  .agents/scripts/approval-helper.sh .agents/scripts/pulse-merge-gates.sh

# Confirm merge ordering and current check classifier.
rg -n '_pulse_merge_admin_safety_check|_pulse_merge_preflight_snapshot_gate|_pmrc_is_explicit_advisory_failure' \
  .agents/scripts/pulse-merge.sh .agents/scripts/pulse-merge-required-checks.sh

# Non-negotiable facts:
# - A v1 payload signs only type/repo/number/timestamp.
# - Maintainer-gate aliases may be canonicalised for diagnostics but never made advisory.
# - Unknown and required failures remain blocking.
# - External contributors never receive review-provider rate-limit grace.
```

### Files to Modify

- `EDIT: .agents/scripts/approval-helper.sh:404-451,535-651,760-898` — produce and verify a versioned canonical content/head snapshot; return a distinct stale/malformed status; keep signing interactive/root-only.
- `EDIT: .agents/scripts/pulse-merge-gates.sh:358-548` — require current-state verification, remove marker-only trust fallback from security decisions, and self-enforce external/fork authority immediately before merge.
- `EDIT: .agents/scripts/pulse-merge.sh:292-458,1374-1413` — carry typed current-head review/approval evidence and run the final trust snapshot after preparatory writes and before every native/admin/direct merge path.
- `EDIT: .agents/scripts/pulse-merge-required-checks.sh:32-262` — retain source identity, canonicalise maintainer-gate aliases, and classify configured advisory failures only with exact-head positive evidence.
- `EDIT: .agents/scripts/review-bot-gate-helper.sh` — expose machine-readable evidence sufficient to distinguish `PASS`, trusted `SKIP`, collaborator-only `PASS_RATE_LIMITED`, and external/malformed outcomes without parsing prose.
- `EDIT: .agents/scripts/review-gate-config-helper.sh` — if explicit advisory check contexts use `repos.json`, validate and manage the new field through the existing CLI.
- `EDIT: .agents/reference/repos-json-fields.md` and `.agents/reference/auto-merge.md` — document the approval version/migration contract and any explicit advisory-context configuration.
- `NEW or EDIT: .agents/scripts/tests/test-approval-helper-content-binding.sh` — fixtures for issue/PR body, comments, links, linked refs, head SHA, legacy payloads, and malformed/API failure.
- `EDIT: .agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh` — alias canonicalisation and evidence-bound advisory cases.
- `EDIT: .agents/scripts/tests/test-pulse-merge-admin-safety-check.sh` and `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh` — final-call external/fork/NMR regressions.

Exact file count may shrink if a dedicated approval-snapshot helper cleanly centralises producer/consumer logic. It must not expand beyond the listed trust boundary without updating this brief and issue first.

### Complete Write Surface

- **Callers/readers:** `aidevops.sh` dispatches `approval-helper.sh`; `pulse-merge-gates.sh` consumes issue/PR approval status in `_external_pr_linked_issue_crypto_approved`, `_has_maintainer_crypto_approval`, and `_pulse_merge_admin_safety_check`; `pulse-merge.sh` invokes those gates and the preflight snapshot; maintainer/review workflows consume approval labels and status contexts.
- **Writers/mutation paths:** `_approve_target` posts signed comments; `_approval_apply_issue_lifecycle_updates` removes NMR, adds auto-dispatch/assignee, and locks; PR approval locks the conversation; external authors may still edit bodies/comments or push commits; Pulse may add approvals and merge through native/admin/direct paths.
- **Tests/fixtures:** existing approval target/state/wrapper tests; `test-pulse-merge-preflight-snapshot.sh`; `test-pulse-merge-admin-safety-check.sh`; `test-pulse-merge-approve-collaborator-guard.sh`; review-gate completion tests; add canonical snapshot fixtures rather than network-dependent tests.
- **Schemas/config:** `repos.json.review_gate` is the preferred explicit policy surface if advisory context names are configurable; update `review-gate-config-helper.sh` and `reference/repos-json-fields.md` together. Do not infer advisory policy solely from branch-protection omission or check name.
- **Generated/deployed mirrors:** source changes under `.agents/` deploy to `~/.aidevops/agents/` via `setup.sh`; reusable workflow files need modification only if structured reason codes cannot be carried safely in the local evaluator. Run incremental deployment after release.
- **Migrations/backfills:** `approval-helper.sh` must define v1/v2 approval compatibility explicitly. A v1 issue approval may remain evidence that development was once authorised, but must not silently authorise a changed or future external PR head. Existing open external PRs requiring v2 may need a fresh maintainer approval; surface this as an actionable blocked state.
- **Cleanup/rollback paths:** reverting `pulse-merge-gates.sh` or `pulse-merge-required-checks.sh` restores prior classifiers but cannot undo merges made under weaker evidence. Therefore ship fail-closed, keep legacy statuses distinguishable, and make rollback preserve NMR/external blocking rather than fallback to marker-only trust.

### Implementation Steps

1. Design a deterministic canonical snapshot and approval payload version. Include target kind/repository/number, immutable object IDs, title/body and external-link-bearing text, pre-approval non-bot comments with identity/association/update timestamps, linked issue references, and—for PRs—the exact head SHA and base target. Exclude the approval comment itself and deterministic aidevops audit/signature comments so verification is stable after approval writes.
2. Make approval verification fetch current state and compare its digest with the signed payload. Return machine-readable `VERIFIED`, `STALE_APPROVAL`, `MALFORMED_APPROVAL`, `NO_APPROVAL`, `NO_KEY`, or API failure; never treat marker presence as authority in a merge decision.
3. Separate development authority from merge authority: issue approval authorises only the signed issue snapshot. An external/fork PR merge requires PR-specific authority bound to the exact current head, or another cryptographically equivalent current-head mechanism chosen and documented by the worker. A new commit, edited external body/comment/link, changed linked refs, or changed base invalidates prior authority.
4. Revalidate trust immediately before every merge bypass path. Preserve the existing collaborator check, linked issue requirement, PR/issue NMR semantics, workflow-file scope check, review decisions, review threads, and exact-head guard. API or parsing uncertainty blocks.
5. Canonicalise the three maintainer-gate aliases (`maintainer-gate`, `Maintainer Review & Assignee Gate`, `gate / Maintainer Review & Assignee Gate`) into one logical diagnostic family while retaining whether any member is required. Any terminal maintainer-family failure remains blocking.
6. Add explicit advisory-context policy, preferably under `repos.json.review_gate`. A non-required configured review-provider failure is advisory only when typed live evidence is for the exact repository/PR/head, the review gate outcome is permitted for that author class, and review threads are clear. `PASS_RATE_LIMITED` must remain unavailable to external contributors.
7. Preserve unknown non-required failures as blockers and active checks as pending. Do not change dispatch assignment, stale-recovery ticks, cost budgets, zero-progress thresholds, or retry counters. Advisory classification performs no GitHub writes and cannot trigger redispatch.
8. Add the focused fixture matrix, run it, and create a WIP checkpoint before broad changed-file lint. Update security/auto-merge documentation with the compatibility and operator reapproval behavior.

### Hazards and Compatibility

- **Concurrency/atomicity:** Approval state can drift between snapshot fetch, signature post, lifecycle updates, and merge. Bind evidence to IDs/head/digest, re-fetch at the final call, and reject any mismatch; do not trust cached preflight state across writes.
- **Migration/rollback:** V1 signatures lack content/head binding. Do not reinterpret them as v2. Prefer an explicit stale/reapproval state for external merge over permissive compatibility. A rollback must keep external PRs blocked rather than restore marker-only authority.
- **Mixed-version/backward compatibility:** Deployed Pulse and source workflows may differ during rolling updates. New verifier output must cause old consumers to fail closed, and new consumers must distinguish old payloads. Document whether issue-development approval remains accepted while PR merge requires v2.
- **Idempotency/retry:** Repeated verification is read-only and deterministic. Repeated approval on the same unchanged snapshot may post a new signed timestamp but must not create conflicting authority. Repeated stale detection must not comment/relabel every cycle.
- **Partial failure/recovery:** If signature posting succeeds but lock/label updates fail, report partial failure and do not treat the target as dispatchable. If digest/API computation fails, preserve or reapply NMR/hold through an idempotent recovery path and require human reapproval.
- **Prompt injection/external links:** Canonicalisation treats external text and links as opaque bytes. It must never fetch or execute links, commands, workflow snippets, or addresses from external content.

### Complexity Impact

- **Target functions:** `_approve_target` and `_verify_comment_signature` in `approval-helper.sh`; `_has_maintainer_crypto_approval` and `_pulse_merge_admin_safety_check` in `pulse-merge-gates.sh`; `_pmrc_snapshot_checks_acceptable` in `pulse-merge-required-checks.sh`.
- **Current line count:** Existing files/functions are already large enough that inline expansion risks function/file complexity gates.
- **Estimated growth:** More than 150 lines across canonicalisation, API projection, verification, and tests.
- **Projected post-change:** Unknown until design; assume thresholds are at risk.
- **Action required:** Extract cohesive snapshot construction/verification and check-family classification helpers before adding branches to existing functions. Keep each shell function explicit-return and Bash 3.2 compatible.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-approval-helper-content-binding.sh
bash .agents/scripts/tests/test-approval-helper-verify-state.sh
bash .agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh
bash .agents/scripts/tests/test-pulse-merge-admin-safety-check.sh
bash .agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh
bash .agents/scripts/tests/test-review-bot-gate-completion-signal.sh
shellcheck .agents/scripts/approval-helper.sh .agents/scripts/pulse-merge-gates.sh .agents/scripts/pulse-merge.sh .agents/scripts/pulse-merge-required-checks.sh .agents/scripts/review-bot-gate-helper.sh .agents/scripts/review-gate-config-helper.sh .agents/scripts/tests/test-approval-helper-content-binding.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Approval tests prove canonical content/head binding and stale states; merge guard tests prove NMR/external/fork authority cannot be bypassed; snapshot tests prove aliases dedupe while required/unknown/maintainer failures block; review-gate tests prove author-class rate-limit behavior; ShellCheck/changed lint cover shell portability and repository gates.
- **Broad verification trigger:** Required because approval output is consumed across dispatch and merge modules and the change touches release-deployed security infrastructure.
- **Broad verification command:** Run `.agents/scripts/linters-local.sh` only after focused tests and the WIP checkpoint; use the repository's bounded default, not an unbounded ad hoc test sweep.

### Recoverability Checkpoint

- [ ] Focused tests pass: the six focused test commands above
- [ ] WIP commit created before broad gates: `wip: bind external approval evidence`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`, followed by normal PR required checks

### Safety-Stop Recovery

- **Original objective:** Guarantee advisory merge classification cannot bypass NMR or changed external issue/PR/comment/file/link authority.
- **Preserved user directions:** Create a clean maintainer-authored TODO/issue and use `tier:thinking` because repository security is affected.
- **Trigger and evidence:** Not triggered at brief creation.
- **Completed and verified:** Discovery, source references, and schema-v2 brief structure.
- **Remaining acceptance criteria:** All implementation and runtime/CI criteria below.
- **Unsafe route not to repeat:** Do not approve or dispatch from GH#27530, and do not add a blanket non-required-check advisory rule.
- **Next safe route:** Resume from this trusted t18118 brief in an isolated worktree; if design exceeds one PR, decompose before editing and preserve the final-call invariant in every phase.
- **Resume condition:** Current `origin/main` rechecked, brief readiness passes, and no overlapping PR owns the trust-boundary files.
- **Owner and status:** Build+ `tier:thinking`; not-triggered.

### Files Scope

- `.agents/scripts/approval-helper.sh`
- `.agents/scripts/pulse-merge-gates.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/pulse-merge-required-checks.sh`
- `.agents/scripts/review-bot-gate-helper.sh`
- `.agents/scripts/review-gate-config-helper.sh`
- `.agents/scripts/tests/test-approval-helper-content-binding.sh`
- `.agents/scripts/tests/test-approval-helper-verify-state.sh`
- `.agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh`
- `.agents/scripts/tests/test-pulse-merge-admin-safety-check.sh`
- `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh`
- `.agents/scripts/tests/test-review-bot-gate-completion-signal.sh`
- `.agents/reference/repos-json-fields.md`
- `.agents/reference/auto-merge.md`
- `.agents/reference/incident-gh17671-supply-chain.md`

## Acceptance Criteria

- [ ] V2 approval verification succeeds only when the canonical issue/PR snapshot exactly matches the signed digest; body, comment, link, linked-ref, base, or head drift returns a distinct non-success state.
- [ ] Issue approval alone cannot authorise merging a future or changed external/fork PR head; final merge requires exact-current-head authority and revalidates it immediately before every merge path.
- [ ] PR/issue NMR, missing crypto approval, external/fork status, malformed evidence, API uncertainty, required-check failures, and maintainer-gate failures remain blocking even when a review-provider check is configured advisory.
- [ ] Duplicate maintainer-gate aliases produce one logical audited blocker without hiding whether any alias is required or changing the gate's decision.
- [ ] A configured non-required review-provider failure becomes advisory only with typed exact-head permitted review evidence and resolved threads; unknown checks and external-contributor rate-limit outcomes still block.
- [ ] Approval and advisory verification are deterministic/read-only on repeated Pulse cycles; they do not modify dispatch counters, assignments, stale-recovery ticks, cost budgets, or repeatedly post comments.
- [ ] V1 payload behavior and mixed-version deployment are documented and tested fail-closed for external merge; operators receive an actionable fresh-approval path.
- [ ] All focused tests, ShellCheck, changed-file lint, required CI, review-bot gate, and a security-focused human review pass before merge.

## Context & Decisions

- The original blanket proposal to treat all non-required failures as advisory is explicitly rejected.
- Branch-protection omission is not proof that a check is safe to ignore.
- Maintainer-gate aliases may be canonicalised for observability but their failures stay blocking.
- A root signature over target ID/time is authentic but not sufficient authority for mutable external content.
- Locked conversations reduce but do not eliminate edits; canonical digest verification is required.
- External links remain opaque content and are never fetched or executed during approval/verification.
- GH#27530 is provenance only. Its NMR status must not be removed to implement this task.

## Relevant Files

- `.agents/scripts/approval-helper.sh:404-451,535-651,760-898` — signature producer, lifecycle writes, and signature verifier.
- `.agents/scripts/pulse-merge-gates.sh:358-548` — crypto consumers and final external/fork admin safety check.
- `.agents/scripts/pulse-merge.sh:292-458,1374-1413` — upstream gates and immediate pre-merge ordering.
- `.agents/scripts/pulse-merge-required-checks.sh:32-262` — check snapshot, advisory classifier, review freshness, exact-head gate.
- `.agents/reference/incident-gh17671-supply-chain.md:18-112` — mandatory threat model and defence-in-depth contract.
- `.agents/reference/repos-json-fields.md:102-125` — existing review-gate configuration surface.

## Dependencies

- **Blocked by:** None.
- **Blocks:** Safe resolution of the behavior reported in GH#27530 and any future relaxation of optional provider failures.
- **External:** GitHub API fixtures only; no new service, secret, purchase, or external URL fetch is permitted.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1.5h | Approval consumers, merge ordering, recent commits, compatibility matrix |
| Design | 1.5h | Canonical snapshot, v1/v2 policy, exact-head authority |
| Implementation | 3h | Approval producer/consumer and evidence-bound classifier |
| Testing/docs | 2h | Fixture matrix, shell gates, compatibility/operator docs |
| **Total** | **8h** | Security-sensitive `tier:thinking` task |
