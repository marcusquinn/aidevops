---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18270: Fix issue-sync forge-event checkout of synthetic pull-request refs

## Pre-flight

- [x] Memory recall: `issue-sync forge event coordinator repository projection pull request refs` → 0 relevant hits.
- [x] Discovery pass: 18 recent commits touched target files; 0 merged/open related PRs were returned. The latest relevant projection repair is `b36a83d49` / PR #28468.
- [x] File refs verified: reusable workflow, both caller files, coordinator helpers, projection reducer, and focused tests exist at HEAD `d7e027d33`.
- [x] Tier: `tier:standard` — workflow contract judgment spans callers, reusable jobs, event semantics, and regression coverage.
- [x] Seeded draft PR decision recorded: skipped because research established the contract but no implementation has been verified.

## Origin

- **Created:** 2026-07-22
- **Session:** OpenCode interactive research follow-up.
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none; standalone leaf for GH#28506.
- **Blocked by:** task ID was allocated offline because the configured `origin/main` counter branch rejected CAS pushes; reconcile t18270 before dispatch.
- **Conversation context:** Review of a downstream HTTP 403 checkout failure found that the reusable forge-event checkout implicitly follows synthetic PR merge refs with `SYNC_PAT`. Further research found that a universal default-branch ref would risk stale push projections and that current PR opened/edited/reopened coordinator events have no PR-to-task mapping.

## What

Make the reusable issue-sync workflow choose a deterministic, least-privileged repository projection for every supported event. Pull-request events must never implicitly fetch `refs/pull/*/merge` with `SYNC_PAT`; issue/reconcile events must read canonical planning state; push synchronization must retain immutable triggering-revision semantics. Align canonical caller triggers with the event coordinator behavior that is actually implemented and tested.

## Why

`actions/checkout` follows GitHub's synthetic PR merge ref when no explicit `ref` is supplied. In the `forge-event` job this checkout prefers a fine-grained write PAT, and a valid caller-repository PAT can receive HTTP 403 for the synthetic ref. Restricting a downstream caller to closed PRs avoids the failing runs but causes intentional canonical-template drift. Broadening PAT permissions would violate least privilege, while forcing the default branch for all events could silently process planning contents from the wrong push revision.

## Tier

### Tier checklist

- [ ] **2 or fewer files to modify?** No — reusable workflow, caller contract, and tests may all change.
- [ ] **Every target file under 500 lines?** No — `issue-sync-reusable.yml` and structural test surfaces are large.
- [ ] **Exact `oldString`/`newString` for every edit?** No — event-aware checkout shape must follow verified job boundaries.
- [ ] **No judgment or design decisions?** No — PR trigger semantics must be resolved from the coordinator contract.
- [x] **No new fallback/error system to design?** Yes — select explicit refs and preserve existing publication fencing.
- [ ] **No cross-module changes?** No — workflow YAML, templates, and tests are coupled.
- [ ] **Estimate 1h or less?** No — allow 2–4 hours including downstream event verification.
- [ ] **4 or fewer acceptance criteria?** No.
- [x] **Dispatch-path classification:** workflow files are not self-hosting runtime files; normal dispatch can use the selected tier after offline ID reconciliation.

**Selected tier:** `tier:standard`

**Tier rationale:** The change is bounded but requires event-contract judgment across several workflow and test files. Existing checkout, caller, and coordinator patterns provide sufficient guidance without requiring a new architecture.

## PR Conventions

Leaf issue — PR body should use `Resolves #28506` after the offline task ID is reconciled to that issue.

## Seeded Draft PR

- **Decision:** Skipped.
- **Rationale:** Research identified the safe boundaries but did not implement or validate a final checkout expression and trigger decision.
- **Status:** `not-created`.
- **Freshness evidence:** Files and recent projection changes were inspected at HEAD `d7e027d33`; discovery identified PR #28468 as the newest related semantic change.
- **Verification run:** Research only; no implementation tests run.
- **Stale-assumption warning:** Re-check the reusable workflow and PR mapping behavior if forge coordinator work lands before implementation.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/issue-sync-reusable.yml` — separate the read-oriented forge projection from event-default checkout behavior, use `GITHUB_TOKEN`, and select a trusted deterministic ref.
- `EDIT IF PR trigger contract changes: .github/workflows/issue-sync.yml` — keep self-caller triggers canonical.
- `EDIT IF PR trigger contract changes: .agents/templates/workflows/issue-sync-caller.yml` — remove unsupported PR actions so downstream callers no longer need drift.
- `EDIT: .agents/scripts/tests/test-forge-event-workflow.sh` — assert checkout token/ref safety and supported trigger semantics.
- `EDIT: .agents/scripts/tests/test-reusable-workflow-caller.sh` — preserve explicit secret forwarding and caller/reusable compatibility.
- `EDIT ONLY IF A FAILING FIXTURE REQUIRES IT: .agents/scripts/tests/test-check-workflows-helper.sh` and `.agents/scripts/tests/test-sync-workflows-helper.sh`.

### Complete Write Surface

Do not modify coordinator/reducer implementations unless a new PR-to-task mapping contract is intentionally added and fully tested. Do not modify `check-workflows-helper.sh` or `sync-workflows-helper.sh` merely because the canonical template changes; their existing template rendering should absorb canonical content changes. Do not alter PAT scopes, branch protection, drift normalization, or secret values.

### Current Evidence / Verified Anchors

- `.github/workflows/issue-sync-reusable.yml:59-77` — `forge-event` checkout has no `ref` and uses `${{ secrets.SYNC_PAT || secrets.GITHUB_TOKEN }}`.
- `.github/workflows/issue-sync-reusable.yml:94-115` — repository path is passed into mapping, coordinator ingestion, and publication.
- `.agents/scripts/forge-event-mapping-helper.sh:10-32` — only `issues` events are mapped, using checked-out `TODO.md`.
- `.agents/scripts/task-coordinator.mjs:691-713` — ordinary PR node IDs cannot resolve through issue mappings; unmapped events publish nothing.
- `.agents/scripts/tests/test-task-coordinator.sh:230-233` — unmapped events intentionally produce no publication.
- `.agents/scripts/tests/test-forge-event-workflow.sh:33-39` — current trigger assertions prove presence, not semantic effects.
- `.agents/templates/workflows/issue-sync-caller.yml:37-38` — downstream template declares opened, edited, closed, and reopened PR actions.
- `.github/workflows/issue-sync-reusable.yml:102-104,147-160,200-232` — push identity is immutable `after`, and the co-running push sync consumes repository contents.
- `todo/research/issue-sync-synthetic-ref-checkout.md` — full research notes and event matrix.

### Implementation Steps

1. Add focused structural regression assertions before changing workflow behavior:
   - The forge projection checkout must use `secrets.GITHUB_TOKEN`, not a `SYNC_PAT` fallback.
   - A PR event must not leave checkout to infer `refs/pull/*/merge`.
   - Explicit cross-account `SYNC_PAT` forwarding remains in the downstream caller.
   - Existing write paths that commit/push `TODO.md` continue to use `SYNC_PAT`.
2. Make forge projection checkout event-aware:
   - For `issues` and workflow-dispatch reconcile/audit, select the caller repository default branch as canonical planning state.
   - For `pull_request`, either skip repository projection when the job is metadata-only or select a trusted base/default-branch projection; never checkout the PR head or synthetic merge ref in this privileged workflow.
   - Preserve immutable `github.event.after`/`github.sha` semantics for any push path that consumes event repository contents. Do not replace all event refs with a branch name.
3. Resolve the PR trigger contract using existing behavior:
   - If no PR-to-task mapping is implemented in this change, reduce both canonical callers to `pull_request.types: [closed]`; opened/edited/reopened currently have no observable coordinator effect.
   - Preserve merged and unmerged close handling in the legacy merge hygiene path, including the guard that prevents unmerged closure from completing tasks.
   - If opened/edited/reopened are retained, first implement an explicit immutable PR-to-task mapping and tests that prove each action's transition. Do not retain triggers solely because a structural test expects them.
4. Review `forge-event` permissions after tracing publication:
   - Reduce `contents: write` to `contents: read` only if the job never writes repository contents through `GITHUB_TOKEN`.
   - Keep write authorization on jobs that actually push planning changes.
5. Update canonical caller expectations and workflow sync/check fixtures only where the canonical trigger change produces a real failing assertion.
6. Run focused tests and workflow lint, then execute the downstream event matrix before declaring the caller current.

### Hazards and Compatibility

- Never broaden PAT permissions or expose secret values.
- Never checkout or execute untrusted PR-head code in a job with privileged secrets.
- A branch-name checkout can race with later pushes; use the immutable event revision wherever file contents represent a push event.
- Do not suppress or normalize away canonical caller drift.
- Green workflow execution is insufficient: tests must assert selected token/ref and resulting task behavior.
- Recent PR #28468 changed targeted projection semantics; rebase and inspect conflicts semantically.

### Verification Before Dispatch

The task ID is offline and must be reconciled before worker dispatch:

```bash
# Repair/configure the dedicated unprotected counter branch, then reconcile t18270
# according to claim-task-id.sh offline allocation workflow.
bash .agents/scripts/verify-brief.sh todo/tasks/t18270-brief.md
```

## Acceptance Criteria

- [ ] No canonical PR event causes `forge-event` to fetch `refs/pull/*/merge` with `SYNC_PAT`.
- [ ] The read-oriented forge projection checkout uses `GITHUB_TOKEN` and a deterministic trusted ref.
- [ ] Issue and reconcile ingestion read canonical default-branch `TODO.md`.
- [ ] Push synchronization consumes the immutable triggering revision rather than a later branch tip.
- [ ] Closing an unmerged PR does not mark tasks complete.
- [ ] Merging a PR with a supported linked-task reference still performs completion hygiene exactly once.
- [ ] Every canonical PR trigger has an asserted semantic effect; unsupported triggers are removed from both callers.
- [ ] Write paths that update `TODO.md` retain `SYNC_PAT` and explicit cross-account secret forwarding.
- [ ] A resynced downstream caller classifies as `CURRENT/CALLER` without checkout HTTP 403.
- [ ] Focused workflow, coordinator, sync/check, and lint gates pass.

### Verify

```bash
bash .agents/scripts/tests/test-reusable-workflow-caller.sh
bash .agents/scripts/tests/test-forge-event-workflow.sh
bash .agents/scripts/tests/test-forge-event-mapping.sh
bash .agents/scripts/tests/test-forge-event-reconciliation.sh
bash .agents/scripts/tests/test-task-coordinator.sh
bash .agents/scripts/tests/test-check-workflows-helper.sh
bash .agents/scripts/tests/test-check-workflows-classifier.sh
bash .agents/scripts/tests/test-check-workflows-runner-normalise.sh
bash .agents/scripts/tests/test-sync-workflows-helper.sh
bash .agents/scripts/tests/test-lint-workflows-helper.sh
bash .agents/scripts/lint-workflows-helper.sh \
  .github/workflows/issue-sync-reusable.yml \
  .github/workflows/issue-sync.yml
```

Downstream test repository:

1. Open, edit, and reopen a PR only if those actions remain canonical.
2. Close an unmerged PR and verify no task completion.
3. Merge a PR with a supported closing reference and verify one completion.
4. Push a planning-file commit and prove consumed contents correspond to the event `after` SHA.
5. Run `aidevops check-workflows --repo <owner/repo>` and require `CURRENT/CALLER`.

### Files Scope

```text
.github/workflows/issue-sync-reusable.yml
.github/workflows/issue-sync.yml
.agents/templates/workflows/issue-sync-caller.yml
.agents/scripts/tests/test-forge-event-workflow.sh
.agents/scripts/tests/test-reusable-workflow-caller.sh
.agents/scripts/tests/test-check-workflows-helper.sh       # only if fixtures fail
.agents/scripts/tests/test-sync-workflows-helper.sh        # only if fixtures fail
```

## Context

The immediate downstream workaround restricted its caller to closed PRs. That is acceptable only if the canonical contract reaches the same evidence-based conclusion. The durable fix belongs upstream so `sync-workflows` can restore downstream callers without intentional drift.

## References

- GH#28506 — tracked bug.
- PR #28468 / commit `b36a83d49` — recent targeted forge projection repair.
- `todo/research/issue-sync-synthetic-ref-checkout.md` — research checkpoint.
- Original reviewed brief: `/home/vladimir/.aidevops/.agent-workspace/tmp/aidevops-issue-sync-synthetic-ref-brief.md`.

## Estimate

2–4 hours including tests and downstream event verification.
