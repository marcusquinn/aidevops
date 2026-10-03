<!-- aidevops:brief-schema=v2 -->

# t18547: Pulse dispatch: re-resolve worker model after tier guard and stop tier-derived defaults bypassing model A/B

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Found while monitoring pulse cycle `20260929T052653Z-87280` on aidevops 3.37.30 and reading `dispatch-ledger-helper.sh tier-report` and `model-ab-helper.mjs report` output. Issue: GH#33004. Related A/B review task: #32539.

## What

Make the worker model follow the tier the issue actually has at launch, and stop tier-derived default models from bypassing the model A/B experiment. There are two defects in one data path:

1. When the pre-dispatch tier guard swaps `tier:simple` → `tier:standard`, the worker still launches with the simple-tier model resolved before the guard.
2. `_dlw_assign_model_ab` treats every non-empty `model_override` as an explicit pin. The dispatcher passes a tier-derived model for every `tier:*`-labelled candidate, so labelled issues never enroll and enrolled issues can run off-arm.

## Why

- **Misroute (a managed private repo, 4 dispatches on 2026-09-29).** One pulse.log dispatch attempt shows, in order:
  - `DISPATCH_CANDIDATE_ATTEMPT`;
  - `[tier-simple-validator] INFO: downgraded ... tier:simple → tier:standard`;
  - `Dispatched worker`.

  The dispatch comment and ledger record `Model: anthropic/claude-haiku-4-5`, `Tier: standard`. All 4 such workers exited `no_work`, and tier-report shows `tier:standard anthropic/claude-haiku-4-5 — 0/3`, which pollutes standard-tier pass-rate data.
- **Code path:**
  1. `_dispatch_process_candidate` resolves `model_override` from prefetched candidate labels (`.agents/scripts/pulse-dispatch-lib.sh:370`) and passes it as argument 9 (L394-395).
  2. `_dispatch_post_dedup_gates` runs `_run_tier_simple_body_shape_check` (`.agents/scripts/pulse-dispatch-core.sh:1093-1096`) and refreshes `issue_meta_json` (L1108-1109), but `model_override` is never recomputed.
  3. `_dlw_resolve_tier_and_model` lets a non-empty override win over the refreshed tier (`.agents/scripts/pulse-dispatch-worker-launch.sh:315-320`).
- **A/B starvation.** The active experiment (`new-auto-dispatch-issues`, ends 2026-10-04T05:54Z) has enrolled only 5 aidevops issues in two days: openai 4, anthropic 1.
  - #32762 (created after the start, with `auto-dispatch` + `tier:standard`) was dispatched on the default-table `anthropic/claude-sonnet-5-5` with no arm.
  - #32877, enrolled in the openai arm, ran off-arm on `anthropic/claude-sonnet-5-5`.
  - The bypass is `[[ -n "${AIDEVOPS_MODEL_AB_CONFIG:-}" && -z "$model_override" ]] || return 0` (`.agents/scripts/pulse-dispatch-worker-launch.sh:329`). The unit tests only pass `""` or `"explicit/model"` (`.agents/scripts/tests/test-model-ab-dispatch.sh:40-105`), never the tier-derived value production passes.

## Tier

**Selected tier:** `tier:thinking`

`tier:thinking`: it modifies dispatch-path files (`pulse-dispatch-*`), which the t2819 detector normalises to `tier:thinking` (`reference/auto-dispatch.md` "Dispatch-Path Default"). It also needs a design judgment: how to tell an explicit model pin from a tier-derived default without breaking the intended simple-tier pin or the opus concurrency cap.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-core.sh:1061-1063` — in `dispatch_with_dedup`, after `_dispatch_post_dedup_gates` succeeds and `_TIER_LABELS_MUTATED` is 1, recompute `model_override` from the refreshed `issue_meta_json` label CSV with `resolve_dispatch_model_for_labels` (`.agents/scripts/pulse-model-routing.sh:29`). Log `model re-resolved after tier change old_model=... new_model=... tier=...`. This applies only when the incoming override was tier-derived (see next item).
- `EDIT: .agents/scripts/pulse-dispatch-lib.sh:370,394-395` — mark the override as tier-derived when it comes from `resolve_dispatch_model_for_labels`. For example, set a dynamically scoped `_DISPATCH_MODEL_OVERRIDE_SOURCE=tier` that `dispatch_with_dedup` and the launcher read, or append a documented 11th argument. Keep the `_dispatch_check_model_concurrency_cap` call (L377) on the candidate-level model.
- `EDIT: .agents/scripts/pulse-dispatch-worker-launch.sh:324-360,1949-1954` — `_dlw_assign_model_ab` bypasses A/B only for explicit pins. For tier-derived overrides it runs enrollment and honours existing receipts, and an active arm result replaces `_DLW_SELECTED_MODEL`, as the empty-override path does today.
- `EDIT: .agents/scripts/tests/test-model-ab-dispatch.sh:40-105` — add cases for a tier-derived override enrolling, a tier-derived override honouring an existing receipt, and an explicit pin still bypassing (existing L53 case).
- `EDIT: .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh:1187-1305` — keep the existing simple-tier pin assertion (L1295-1298) passing, and add or adjust a case where the stubbed tier guard mutates the label and the launched override follows the new tier.

### Complete Write Surface

- **Callers/readers:** `dispatch_with_dedup` is called from `_dispatch_with_timeout` (`.agents/scripts/pulse-dispatch-lib-candidates.sh:600`) and `.agents/scripts/pulse-wrapper.sh:2002`. `_dispatch_launch_worker` (`.agents/scripts/pulse-dispatch-worker-launch.sh:1925`) consumes `model_override` via `_dlw_resolve_tier_and_model` and `_dlw_assign_model_ab`. `_dispatch_check_model_concurrency_cap` (`.agents/scripts/pulse-dispatch-lib-candidates.sh:767`) reads the candidate-level model.
- **Writers/mutation paths:** `_dispatch_process_candidate` sets the override; `_run_tier_simple_body_shape_check` and `_refresh_issue_meta_after_tier_policy_checks` mutate labels and metadata; `model-ab-helper.mjs assign` writes arm receipts under `~/.aidevops/.agent-workspace/work/model-ab/`; the dispatch ledger and tier telemetry record tier/model.
- **Existing verification/tests:** `.agents/scripts/tests/test-model-ab-dispatch.sh`, `.agents/scripts/tests/test-pulse-wrapper-worker-detection.sh`, `.agents/scripts/tests/test-canonical-tier-routing.sh`, `.agents/scripts/tests/test-pulse-wrapper-characterization.sh`, `.agents/scripts/tests/test-worker-release-scope-propagation.sh`; production evidence from `dispatch-ledger-helper.sh tier-report` and `model-ab-helper.mjs report`.
- **Schemas/config:** no config schema change. `AIDEVOPS_MODEL_AB_CONFIG`, the routing tables and `.agents/configs/dispatch-model-caps.conf` are read unchanged. Any new positional argument or scoped variable must be documented in the function headers (`.agents/scripts/pulse-dispatch-core.sh:824`).
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`, and the pulse loads it via the runtime bundle after release.
- **Migrations/backfills:** N/A because arm receipts and ledger rows are append-only and keep their schema; already-misattributed ledger rows stay historical and age out of the windowed tier-report.
- **Cleanup/rollback paths:** revert the PR touching `.agents/scripts/pulse-dispatch-core.sh`, `.agents/scripts/pulse-dispatch-lib.sh` and `.agents/scripts/pulse-dispatch-worker-launch.sh`. Receipts written by new enrollments under `~/.aidevops/.agent-workspace/work/model-ab/` stay valid for the experiment's report and need no cleanup.

### Implementation Steps

1. Introduce the tier-derived marker in `_dispatch_process_candidate` and thread it to `dispatch_with_dedup` and `_dispatch_launch_worker`.
2. In `dispatch_with_dedup`, after the post-dedup gates, re-resolve a tier-derived override when `_TIER_LABELS_MUTATED=1`, and log old and new values.
3. In `_dlw_assign_model_ab`, bypass only explicit pins; let tier-derived overrides enroll and follow receipts.
4. Extend the two test files, then run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** `dispatch_with_dedup` runs in a background stage per candidate (`run_stage_with_timeout`), so a scoped marker variable must be set in the same process before the call. Receipts are written by `model-ab-helper.mjs` with its existing persistence, and the change adds no shared state.
- **Migration/rollback:** no persisted-format change; roll back with a plain revert. New receipts created after the fix stay attributable to their arm.
- **Mixed-version/backward compatibility:** `dispatch_with_dedup` and `_dispatch_launch_worker` must keep accepting today's positional arguments, so any new argument is optional and defaults to "explicit" semantics. `.agents/scripts/tests/test-worker-release-scope-propagation.sh:21-28` calls `_dlw_resolve_tier_and_model` with an explicit override and must pass unchanged.
- **Idempotency/retry:** re-resolution is a pure read of labels plus the model-availability helper. A/B assignment is idempotent per issue (existing receipt reuse).
- **Partial failure/recovery:** if re-resolution returns empty, pass an empty override, which is the documented "ordered healthy auto-selection" path, rather than the stale model. If the A/B helper fails, keep today's `|| return 1` launch-abort behaviour.

### Complexity Impact

- **Target function:** `_dlw_assign_model_ab` in `.agents/scripts/pulse-dispatch-worker-launch.sh`
- **Current line count:** 37 lines (L324-360; threshold: 100 lines for function-complexity)
- **Estimated growth:** +8 lines (source check, receipt path)
- **Projected post-change:** 45 lines (45% of threshold); `dispatch_with_dedup` (66 lines, L999-1065) grows by about 8, and `_dispatch_process_candidate` (about 105 lines, L326-432) grows by about 2.
- **Action required:** `_dispatch_process_candidate` is already over 100 lines. Keep the added lines minimal, or extract the model-resolution lines (L370-381) into `_dispatch_candidate_model` to net-reduce it.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-dispatch-core.sh .agents/scripts/pulse-dispatch-lib.sh .agents/scripts/pulse-dispatch-worker-launch.sh
bash .agents/scripts/tests/test-model-ab-dispatch.sh
bash .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh
bash .agents/scripts/tests/test-canonical-tier-routing.sh
bash .agents/scripts/tests/test-worker-release-scope-propagation.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
```

- **Surface mapping:** `shellcheck` covers the three modified dispatch scripts. `test-model-ab-dispatch.sh` proves tier-derived enrollment, receipt honouring and the explicit-pin bypass in `_dlw_assign_model_ab` (idempotency and mixed-version hazards). `test-pulse-wrapper-worker-detection.sh` proves the candidate-level override and simple-tier pin in `.agents/scripts/pulse-dispatch-lib.sh` plus re-resolution after a stubbed tier mutation (concurrency and partial-failure hazards). `test-canonical-tier-routing.sh` proves `resolve_dispatch_model_for_labels` is unchanged. `test-worker-release-scope-propagation.sh` and `test-pulse-wrapper-characterization.sh` prove the existing positional contracts and pulse-wide sourcing still hold.
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:** do not change `resolve_dispatch_model_for_labels`, routing tables, A/B eligibility rules (`model-ab-enrollment.mjs`), the opus concurrency cap, or the intended simple-tier pin. Do not rewrite historical ledger or telemetry rows.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-dispatch-core.sh`
- `.agents/scripts/pulse-dispatch-lib.sh`
- `.agents/scripts/pulse-dispatch-worker-launch.sh`
- `.agents/scripts/tests/test-model-ab-dispatch.sh`
- `.agents/scripts/tests/test-pulse-wrapper-worker-detection.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] A candidate resolved at `tier:simple` whose label the tier guard swaps to `tier:standard` launches with the standard-tier model, and the log records the re-resolution.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh"
  ```

- [ ] With `AIDEVOPS_MODEL_AB_CONFIG` set, an eligible labelled issue carrying a tier-derived override is enrolled and routed through its arm table, and an issue with an existing receipt routes on its arm.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-model-ab-dispatch.sh"
  ```

- [ ] Negative/regression: an explicit model pin still bypasses A/B, an unchanged `tier:simple` candidate still gets the simple-tier model, and `resolve_dispatch_model_for_labels` output is unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-canonical-tier-routing.sh && bash .agents/scripts/tests/test-worker-release-scope-propagation.sh"
  ```

- [ ] After release, tier-report shows no new `tier:standard` rows on the simple-tier model, and `model-ab-helper.mjs report` shows new assignments for labelled issues. This is observed after deploy, not in this PR.

## Context & Decisions

- Keeping the candidate-level resolution preserves the intended simple-tier pin and the opus concurrency cap. The fix only makes that value follow label mutations, and stops it from masquerading as an explicit pin.
- The A/B window ends 2026-10-04T05:54Z. The maintainer may choose to extend it after this lands so the review in #32539 has a usable cohort.

## Relevant Files

- `.agents/scripts/pulse-dispatch-lib.sh:326-432` — `_dispatch_process_candidate`
- `.agents/scripts/pulse-dispatch-core.sh:999-1148` — `dispatch_with_dedup` and `_dispatch_post_dedup_gates`
- `.agents/scripts/pulse-dispatch-worker-launch.sh:264-360,1925-1954` — tier/model resolution and A/B assignment
- `.agents/scripts/pulse-model-routing.sh:29-49` — `resolve_dispatch_model_for_labels`
- `.agents/scripts/model-ab-enrollment.mjs:25-34` — enrollment eligibility (read-only)
