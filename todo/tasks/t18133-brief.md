<!-- aidevops:brief-schema=v2 -->

# t18133: Normalize raw PR creation origin provenance

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `27802 origin provenance auto-dispatch` → 0 hits — no relevant stored lessons
- [x] Discovery pass: 0 relevant commits / 0 relevant merged PRs / 0 relevant open PRs touch the target behavior since GH#27802 was filed
- [x] File refs verified: 6 refs checked against current `origin/main`, all present
- [x] Tier: `tier:standard` — two files, but the 1,574-line shim and provenance/error-path judgment disqualify `tier:simple`
- [x] Seeded draft PR decision recorded: skipped — this planning handoff contains no implementation code

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive review and auto-dispatch handoff
- **Created by:** AI DevOps (ai-interactive), directed and cryptographically approved by the maintainer
- **Parent task:** None; leaf task for GH#27802
- **Blocked by:** None
- **Conversation context:** Review confirmed that raw headless `gh pr create` receives signature and safety handling but no origin label, while stale recovery requires worker provenance to distinguish a checkpoint from a protected draft.

## What

Normalize raw PR creation at the gh PATH shim so a managed headless worker-created PR receives exactly one correct session-origin label when the caller supplied none. Preserve explicit origin labels, interactive provenance, protected-draft immutability, linked-issue enforcement, privacy scanning, and external-repository write controls.

## Why

Workers are instructed to create draft PRs early. A labelless worker draft blocks ordinary redispatch but is classified as `protected_draft`, so stale recovery cannot continue or escalate it. The wrapper path already applies provenance; the raw shim path must provide equivalent defence-in-depth.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The edit is bounded to the shim and its focused test, but it must reconcile explicit labels, session origin, managed-repository scope, and label-availability failure behavior without weakening trust boundaries.

## PR Conventions

Leaf task: title the implementation PR `t18133: ...` and use `Resolves #27802`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A worker should implement from the verified current shim rather than inherit untested code.
- **Status:** `not-created`
- **Freshness evidence:** Current `origin/main` and affected call sites were checked on 2026-07-15.
- **Verification run:** Planning readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-check `.agents/scripts/gh` and origin-label helpers if a PR touching raw create normalization lands first.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/gh:260-265,1243-1257,1401-1435` — add focused `pr:create` origin normalization using existing headless detection and target-repo policy.
- `EDIT: .agents/scripts/tests/test-gh-shim.sh:278-357` — prove worker, interactive, explicit-origin, and failure/bypass behavior.

### Complete Write Surface

- **Callers/readers:** Raw `gh pr create` enters `.agents/scripts/gh`; `.agents/scripts/dispatch-dedup-stale.sh:200-243` reads PR origin labels; `.agents/scripts/dispatch-dedup-pr.sh:68-93` blocks competing dispatch on drafts.
- **Writers/mutation paths:** `.agents/scripts/shared-gh-wrappers-create.sh:595-646` is the canonical wrapped PR creator and reference behavior; the shim mutates `_modified_args` before native gh execution.
- **Tests/fixtures:** `.agents/scripts/tests/test-gh-shim.sh` owns raw shim argv fixtures; existing stale-recovery tests preserve protected/worker draft semantics and should remain green.
- **Schemas/config:** N/A because scoped searches found no schema/config owner for creation-time origin labels; existing label names and mutual exclusion remain unchanged.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/gh`; no generated source copy should be edited.
- **Migrations/backfills:** N/A because the task changes only future PR creation; existing labelless PRs are intentionally not mutated.
- **Cleanup/rollback paths:** N/A for persistent cleanup because the shim writes no local state; rollback is a git revert of the helper and focused tests.

### Implementation Steps

1. Add a small helper that runs only for `pr:create`, returns immediately when an `origin:*` label is already present, and selects provenance from the same session signals used by existing wrapper behavior.

```bash
_shim_normalize_pr_create_origin() {
	[[ "${_modified_args[0]:-}:${_modified_args[1]:-}" == "pr:create" ]] || return 0
	_shim_issue_create_has_label_prefix "origin:" && return 0
	# Resolve target/session policy, then append exactly one origin label.
	return 0
}
```

2. Scope automatic labeling to repositories where aidevops manages worker lifecycle and ensure label availability through the trusted native gh path or an existing equivalent. Do not infer ownership from branch names.
3. Invoke normalization before linked-issue/privacy/native execution so all later gates inspect the final argv.
4. Extend the shim harness with positive headless and interactive cases plus negative cases for explicit labels, unmanaged external targets, and duplicate-origin prevention.

### Hazards and Compatibility

- **Concurrency/atomicity:** Argument normalization is process-local; GitHub label creation/checks must be idempotent if required.
- **Migration/rollback:** No backfill. Revert removes only future normalization.
- **Mixed-version/backward compatibility:** Older workers remain readable; new PR labels are already understood by current stale recovery.
- **Idempotency/retry:** Re-running through wrappers/shims must keep exactly one origin label and preserve caller-supplied provenance.
- **Partial failure/recovery:** Never silently create a labelless managed worker PR after deciding provenance is required; emit a clear failure while leaving unrelated external contribution flows usable.

### Complexity Impact

- **Target function:** Add a new focused helper rather than growing `_shim_block_pr_create_without_linked_issue_if_needed`.
- **Current line count:** New helper, target under 30 lines; shell function threshold is 100 lines.
- **Estimated growth:** +20-35 lines including comments.
- **Projected post-change:** Under 40% of threshold.
- **Action required:** Keep normalization and label-availability logic in separate small helpers if either grows.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-gh-shim.sh
bash .agents/scripts/tests/test-stale-recovery-escalation.sh
shellcheck .agents/scripts/gh .agents/scripts/tests/test-gh-shim.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Shim tests prove argv normalization and safety gates; stale recovery proves labels drive the intended classification without mutating protected drafts; ShellCheck/lint cover shell correctness.
- **Broad verification trigger:** Not required unless implementation changes shared origin helpers or dispatch-dedup code outside declared scope.

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-gh-shim.sh`
- [ ] WIP commit created before broad gates: `wip: normalize raw PR origin provenance`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/scripts/gh`
- `.agents/scripts/tests/test-gh-shim.sh`

## Acceptance Criteria

- [ ] A managed headless raw `gh pr create` with no origin argument reaches native gh with exactly one `origin:worker` label.
- [ ] Interactive or explicitly labelled PR creation preserves the correct/supplied single origin and never adds a second origin label.
- [ ] Unmanaged external PR creation, linked-issue enforcement, privacy scanning, and protected-draft behavior are not weakened.
- [ ] Focused tests, ShellCheck, and changed-file lint pass.

## Context & Decisions

- Normalize at the raw shim boundary; do not add spoofable branch-name fallback to stale recovery.
- Origin labels represent creation provenance, not current issue ownership.
- Preserve the external-write and privacy gates as independent mandatory checks.

## Relevant Files

- `.agents/scripts/gh:260-265` — current headless-session detector.
- `.agents/scripts/gh:1243-1257` — existing issue-create normalization pattern.
- `.agents/scripts/shared-gh-wrappers-create.sh:604-631` — canonical PR origin-label behavior.
- `.agents/scripts/dispatch-dedup-stale.sh:200-243` — downstream worker/protected classification.
- `.agents/scripts/tests/test-gh-shim.sh:278-357` — focused raw PR and recursion tests.

## Dependencies

- **Blocked by:** None.
- **Blocks:** Reliable continuation/escalation of raw worker draft PRs.
- **External:** No credentials, purchases, or external setup.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Reconfirm origin helper and target-repo patterns |
| Implementation | 55m | Add normalization and safe label handling |
| Testing | 45m | Focused lifecycle, ShellCheck, changed lint |
| **Total** | **2h** | |
