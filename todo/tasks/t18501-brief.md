<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18501: Keep pending auto-dispatch issues dispatchable and make priority:critical/high lead dispatch order

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `origin:interactive auto-assign status:in-review auto-dispatch pulse skip assigned` → 0 hits — no relevant lessons
- [x] Discovery pass: GH#32608 (`ffdf8bd98`, merged 2026-09-27) is the only recent change to `issue-sync-helper-push.sh`, and it covers the TODO-assignee path only; no open PR touches the shim normalizer or the ranking function
- [x] File refs verified: 5 refs checked, all present at `5a2a4dc46`
- [x] Tier: `tier:standard` — two known boundaries with verified patterns; the change touches dispatch-path ranking, so the implementing session reviews it
- [x] Seeded draft PR decision recorded: skipped — implemented directly in the originating interactive session

## Origin

- **Created:** 2026-09-28
- **Session:** opencode:ses_f1ae20a63ffeFJycVVOT3WXoWq
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** #32694 (t18498) was filed with `#auto-dispatch` from an interactive session. It came out self-assigned and labelled `status:in-review`, which blocks workers permanently. The maintainer also asked us to confirm that priority labels order dispatch.

## What

1. An interactive `issue-sync-helper.sh push` of a TODO entry tagged `#auto-dispatch` creates a `publication:pending` issue with no assignee and no active `status:*` label. After planning publication lands, `planning-publication-reconcile.sh` projects `auto-dispatch` and `status:available`, so the pulse can dispatch it.
2. Pulse ranking always places `priority:critical` candidates first, then `priority:high`, then the rest. This matches the existing `urgent` phase in `_dispatch_priority_loop`, so a lower-priority `tier:simple` item or old-age bonus can no longer outrank urgent work on the non-reserved floor/max paths.

## Why

Evidence from #32694 (t18498), created with `issue-sync-helper.sh push t18498` on 2026-09-28. Labels after creation were `publication:pending,status:in-review,origin:interactive,tier:standard`, and it was assigned to `marcusquinn`. The cause is a two-part chain:

- `_push_pending_publication_labels` (`.agents/scripts/issue-sync-helper-push.sh:270-279`) removes `auto-dispatch` from the pending labels, and `_push_prepare_creation_labels` (`:224-253`) deliberately adds no status label while pending. `_push_create_issue` (`:214-217`) then passes those projected labels to `_push_auto_assign_interactive`. Its t2157 `auto-dispatch` skip (`:79`) never matches, so the issue is self-assigned.
- The gh shim `_shim_normalize_interactive_tracking_issue_create` (`.agents/scripts/gh-write-policy-lib.sh:739-752`) adds `status:in-review` to any interactive `tNNN:` issue created without a `status:` label. That includes pending issues.
- After publication, `_publication_status_label` (`.agents/scripts/planning-publication-reconcile.sh:130-151`) sees the active `status:in-review` and never projects `status:available`. The owner assignment plus `status:in-review` also hits the GH#18352 dispatch block. Every interactively filed auto-dispatch task is therefore stranded.

Priority ordering: `_append_ranked_repo_candidates` (`.agents/scripts/pulse-dispatch-engine.sh:313-365`) folds `priority:high` (+9000) into a single additive score. With the tooling base (2000), a `tier:simple` bug with the maximum age bonus scores 2000+2500+1000+300+7000+900 = 13700. That beats a fresh `priority:high` `tier:standard` issue at 13500. A `priority:high` `tier:thinking` issue (#32688 today) scores 11100 and falls below ordinary `tier:standard` bugs. Only the product-reservation path (`_dispatch_priority_loop` phase `urgent`, `.agents/scripts/pulse-dispatch-lib.sh:833-849,915`) orders urgent work strictly. The floor and max paths (`pulse-dispatch-engine.sh:721-728`) follow the score order.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Skeletons, not complete oldString blocks.
- [x] **Targets and reference pattern verified?**
- [x] **No semantic or design decision remains?**
- [ ] **Bounded, reversible, low-consequence impact?** It changes dispatch ordering.
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [ ] **No dispatch-path risk override?** It edits pulse ranking.

**Selected tier:** `tier:standard`

**Tier rationale:** The boundaries and patterns are verified and the implementation choices are small. The dispatch-path edit gets focused verification in the interactive session.

## PR Conventions

Leaf issue: the PR uses a closing keyword for this issue.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/issue-sync-helper-push.sh:214-217` — decide auto-assign from the pre-projection TODO labels (`labels` argument), not the pending-projected `all_labels`.
- `EDIT: .agents/scripts/gh-write-policy-lib.sh:749` — skip `status:in-review` injection when the create args carry `publication:pending`. A pending issue intentionally has no status until reconcile.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh:354-362,456-462` — add `priority_rank` (critical 2, high 1, else 0) to each candidate and make `-.priority_rank` the leading sort key.
- `EDIT: .agents/scripts/tests/test-issue-sync-publication-pending.sh` — assert that pending `auto-dispatch` creation does not self-assign.
- `EDIT: .agents/scripts/tests/test-gh-shim-routing-cases.sh` — assert that pending creation receives no `status:in-review`.

### Complete Write Surface

- **Callers/readers:** `issue-sync-helper.sh push` (`claim-task-id.sh`, `/new-task`, `new-task-helper.sh batch`); `gh` shim for every interactive raw `issue create`; `build_ranked_dispatch_candidates_json` consumers in `pulse-dispatch-engine.sh:690-730`.
- **Writers/mutation paths:** `_push_create_issue` / `_push_auto_assign_interactive` in `issue-sync-helper-push.sh`; `_shim_normalize_interactive_tracking_issue_create` in `gh-write-policy-lib.sh`; `_append_ranked_repo_candidates` in `pulse-dispatch-engine.sh`.
- **Existing verification/tests:** `.agents/scripts/tests/test-issue-sync-publication-pending.sh`, `.agents/scripts/tests/test-gh-shim-routing-cases.sh`, `.agents/scripts/tests/test-dispatch-max-parallel.sh`, `.agents/scripts/tests/test-pulse-dispatch-candidate-snapshot.sh`.
- **Schemas/config:** N/A because no config schema changes; the candidate JSON gains one additive `priority_rank` field.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`; the pulse reads the deployed copy after `setup.sh --non-interactive`.
- **Migrations/backfills:** N/A for code, because already-stranded issues (for example #32694) are repaired manually by the originating session.
- **Cleanup/rollback paths:** revert the PR touching `issue-sync-helper-push.sh`, `gh-write-policy-lib.sh`, and `pulse-dispatch-engine.sh`.

### Implementation Steps

1. In `_push_create_issue`, pass the original `labels` (TODO intent) to `_push_auto_assign_interactive` instead of `all_labels`, and explain in a comment that the pending projection strips `auto-dispatch`.
2. In `_shim_normalize_interactive_tracking_issue_create`, change the status line to
   `_shim_issue_create_has_label_prefix "status:" || _shim_issue_create_has_label "publication:pending" || _modified_args+=(--label "status:in-review")`.
3. In `_append_ranked_repo_candidates`, add
   `priority_rank: (if ($labels | index("priority:critical")) != null then 2 elif ($labels | index("priority:high")) != null then 1 else 0 end)`,
   and in `build_ranked_dispatch_candidates_json` sort by `[-.priority_rank, -.score, ...]`, keeping the existing ties.
4. Add the regression assertions listed above and run the tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** Per-call label arrays only; there is no shared state.
- **Migration/rollback:** A revert restores the prior behaviour. Stranded issues filed before the fix need a manual label repair; this is not a code migration.
- **Mixed-version/backward compatibility:** A candidate without `priority_rank`, from a stale in-flight file, sorts as `null`. `-null` fails in jq, so use `-(.priority_rank // 0)`.
- **Idempotency/retry:** Issue creation keeps its existing race guards, and ranking is deterministic.
- **Partial failure/recovery:** If the shim change deploys without the push change, the issue is still self-assigned but has no active status. It then becomes dispatchable after publication because it lacks the in-review label.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-issue-sync-publication-pending.sh
bash .agents/scripts/tests/test-gh-shim-routing-cases.sh
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
bash .agents/scripts/tests/test-pulse-dispatch-candidate-snapshot.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The publication-pending test proves no self-assignment. The shim routing test proves pending issues get no injected `status:in-review` while non-pending issues still do. The dispatch tests prove ranking and loop behaviour are intact. Lint covers ShellCheck.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** Do not change `planning-publication-reconcile.sh` semantics or the GH#18352 owner+in-review dispatch block.

**AI brief owner:** marcusquinn interactive session.

**Recovery:** Preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/issue-sync-helper-push.sh`
- `.agents/scripts/gh-write-policy-lib.sh`
- `.agents/scripts/pulse-dispatch-engine.sh`
- `.agents/scripts/tests/test-issue-sync-publication-pending.sh`
- `.agents/scripts/tests/test-gh-shim-routing-cases.sh`

## Acceptance Criteria

- [ ] Pending interactive creation of an `auto-dispatch` TODO entry performs no `--add-assignee` call.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-issue-sync-publication-pending.sh"
  ```

- [ ] A `publication:pending` interactive `tNNN:` issue created through the shim receives no `status:in-review`, while a plain interactive tracking issue still does.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-gh-shim-routing-cases.sh"
  ```

- [ ] Ranked candidates order `priority:critical`, then `priority:high`, then all others, regardless of tier or age bonus.
- [ ] Regression guarantee: existing dispatch loop tests still pass, and non-pending interactive tracking issues still receive `status:in-review`.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dispatch-max-parallel.sh"
  ```

- [ ] ShellCheck clean on changed files (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- The fix belongs at creation time; the reconciler stays strict about active statuses.
- `priority:medium` stays inside the additive score; only the `urgent` set used by `_dispatch_priority_loop` becomes strict, so the reserved and non-reserved paths agree.
- Separately, the originating session repairs issues already stranded by this bug (#32694 and the t18502 issue).

## Relevant Files

- `.agents/scripts/issue-sync-helper-push.sh:76-99,214-217,224-279`
- `.agents/scripts/gh-write-policy-lib.sh:739-752`
- `.agents/scripts/planning-publication-reconcile.sh:104-151`
- `.agents/scripts/pulse-dispatch-engine.sh:313-365,456-462,710-729`
- `.agents/scripts/pulse-dispatch-lib.sh:833-849,909-959`

## Dependencies

- **Blocked by:** none
- **Blocks:** reliable dispatch of every interactively filed auto-dispatch task
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | the anchors above |
| Implementation | 30m | three small edits and two test assertions |
| Verification | 20m | four focused tests and lint |
| **Total** | **1h** | |
