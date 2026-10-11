<!-- aidevops:brief-schema=v2 -->

# t18662: release dependency-ready issues held only by brief terminal-blocker text

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `dependency event reconciler terminal blocker vocabulary body hold false positive` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found 0 open related PRs for the target files; last relevant changes are 0e83416a58 (t18661 supersession readiness), 589016c402 (t18646 blocked-by:GH# labels), 74f9d071c8 (GH#33957 resumable stale sweep), 2227f6fcf7 (GH#33881 blocked-by value grammar)
- [x] File refs verified at origin/main c30e0ba4fd: `_der_text_has_strong_hold`, `_der_has_hold`, `_der_try_unblock`, `reconcile_dependants_after_verified_closure` (`.agents/scripts/dependency-event-reconciler.sh`); runtime terminal-blocker writers `_apply_terminal_blocker` (`pulse-dispatch-core.sh`) and `_terminal_blocker_recovery` / `terminal_blocker_circuit_comment` (`terminal-blocker-circuit.sh`) post comments only
- [x] Tier: `tier:standard` — narrow change on the unblock safety path; every new branch keeps or adds a hold, except the documented body-vocabulary exemption
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Found while maximising worker throughput for a managed private repo's enrichment backlog: issues whose dependencies had all closed stayed `status:blocked` indefinitely.

## What

The dependency-event reconciler (close events and the periodic stale sweep) releases `status:blocked` issues whose dependencies are resolved, without treating worker-protocol documentation in the issue body as a hold, and without overriding blocks that no dependency explains:

1. Terminal-blocker vocabulary (`Terminal[_ -]blocker`, which also matches `TERMINAL_BLOCKER_REASON=` and `terminal-blocker circuit`) is hold evidence only in trusted comments, not in the issue body. Every other strong marker, operational hold line and hold label keeps its current scope.
2. The reconciler only removes `status:blocked` with positive dependency evidence: at least one native `blockedBy` edge, or a declared blocker ref in the body or a `blocked-by:` label. Without either, the block came from another mechanism and is left alone.
3. A close event keeps reconciling the remaining dependants when one dependant is still waiting on another open blocker (`DER_NOT_READY`), instead of stopping at it. Hard failures still stop the pass.

## Why

`_der_has_hold` runs `_der_text_has_strong_hold` over `body + trusted comments`, and its pattern includes `Terminal[_ -]blocker([_ -]detected)?`. Briefs routinely document the worker protocol in the body, for example: "On exit 1 ... emit `TERMINAL_BLOCKER_REASON=runner_capability_unmet`. Do not set `status:blocked`: the terminal-blocker circuit keeps this issue `status:available`". The runtime never records terminal-blocker state in bodies — `_apply_terminal_blocker` and the terminal-blocker circuit post comments — so in a body this vocabulary is documentation, not a hold. The dep-graph refresh body gate (`issue_body_has_defer_marker`) already ignores it.

Read-only census of one managed private repo (2026-10-11, 340 open `status:blocked` issues):

- 237 bodies (70%) contain terminal-blocker vocabulary; no other strong hold token appears in any body.
- 11 issues with every dependency closed (10 native, 1 declared) had the body text as their only hold signal, so neither close events nor the stale sweep could release them.
- 3 issues with no dependency at all were blocked by mechanisms the reconciler does not recognise (two cost-circuit-breaker trips, one dispatch infrastructure failure). Only the body text stopped the reconciler from releasing them, because with no native edge and no declared ref `_der_all_declared_blockers_closed` is vacuously true. Change 1 alone would release them, so change 2 is required. It also matches the existing contract in `_hold_dependency_sync_retry` (`issue-sync-relationships-gh.sh`): "Pulse supplies the positive proof required to unblock it".

Change 3 is a code-level defect present since GH#27338: in `reconcile_dependants_after_verified_closure`, `_der_try_unblock ... || return 1` treats `DER_NOT_READY` (the dependant has another open blocker) as fatal. All later dependants of the closed issue then wait for the stale sweep instead of being released by the close event.

## How

### Files to Modify

- `EDIT: .agents/scripts/dependency-event-reconciler.sh`
  - Split the strong-hold pattern into `DER_STRONG_HOLD_RE` (`HUMAN_UNBLOCK_REQUIRED|Worker Watchdog Kill|ACTION REQUIRED|worker[_ -]blocked|aidevops:brief-hold`) and `DER_TERMINAL_BLOCKER_RE` (`Terminal[_ -]blocker([_ -]detected)?`).
  - `_der_text_has_strong_hold <text> <comments>`: `DER_STRONG_HOLD_RE` over `<text>` (body + comments, unchanged scope), `DER_TERMINAL_BLOCKER_RE` over `<comments>` only, and the existing `**BLOCKED**` + `cannot proceed` pair over `<text>`.
  - `_der_has_hold`: pass `"$text" "$comments"`; the expired-brief-hold rewrite still applies to `comments` first.
  - New `_der_declares_blockers <candidate_json>`: true when `_der_issue_refs` or `_der_task_refs` yields a ref from body + label names (same text construction as `_der_all_declared_blockers_closed`); jq failure is false.
  - `_der_try_unblock`: when `_DER_NATIVE_BLOCKERS_PRESENT` is not `true`, `_der_declares_blockers "$candidate_json" || return 0` before `_der_all_declared_blockers_closed`.
  - `reconcile_dependants_after_verified_closure`: capture the `_der_try_unblock` status per candidate; continue on `0` or `DER_NOT_READY`, `return 1` otherwise.
- `EDIT: .agents/scripts/tests/test-dependency-event-reconciler.sh` — classifier cases for body vs comment terminal-blocker vocabulary; stale-sweep cases for body-documented protocol (released) and a no-evidence block (kept); a two-dependant close event where the first is still blocked and the second is released. Add fixture knobs `STALE_DEP_LABEL` (stale-sweep dependency label, default `blocked-by:#10`), `EXTRA_DEPENDANT` (second search candidate #21) and `NATIVE_EXTRA_FOR` (restrict the extra open native blocker to one issue number).

### Complexity Impact

- `_der_text_has_strong_hold` 10 → ~13 lines; `_der_try_unblock` 24 → ~26; `reconcile_dependants_after_verified_closure` 32 → ~35; new helper ~10 lines. All far below the 100-line gate; file ~720 lines.

### Complete Write Surface

- **Callers/readers:** `_der_try_unblock` from `reconcile_dependants_after_verified_closure` (close hooks in `pulse-merge.sh`, `full-loop-helper-merge.sh`, `issue-sync-helper-close.sh`, `github-cli-helper.sh`) and `reconcile_stale_blocked_issues` (`pulse-wrapper-cycle.sh`). `_der_completion_blockers_closed` does not use the hold classifier and is unchanged.
- **Deliberately unchanged:** dep-graph refresh (`pulse-dep-graph.sh`) only visits issues with dependency entries and already ignores body terminal-blocker text; dispatch-time `terminal_blocker_circuit_active` / `terminal_blocker_backoff_active` remain the authority for re-dispatch after a worker BLOCKED exit.
- **Writers/mutation paths:** no new writes; the only label edit is the existing re-read-guarded `status:blocked` → `status:available` in `_der_try_unblock`.
- **Schemas/config:** none.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*.sh` to `~/.aidevops/agents/scripts/`.
- **Migrations/backfills:** none; the next stale sweep applies the rule to existing issues.
- **Cleanup/rollback paths:** revert the PR; no persisted state.

### Hazards and Compatibility

- **Safety direction:** change 1 can only release issues whose dependencies are positively resolved and that carry no comment, label or operational hold; changes 2 and 3 never release anything new on their own (2 adds a hold, 3 continues to the same per-candidate checks).
- **Comment-side vocabulary unchanged:** trusted terminal-blocker comments (observations, circuit comments, `Terminal blocker detected`) still hold, including after this change.
- **Evidence removed after blocking:** an issue whose only dependency declaration was deleted stays `status:blocked` until a maintainer or the owning mechanism releases it — the conservative outcome the dependency-sync retry hold already relies on.
- **Mixed versions:** older runners keep the old classifier; both only ever release fully resolved dependants.
- **Partial failure:** API/jq failures keep returning 1 (fail closed); `DER_NOT_READY` is no longer escalated to a failure in the close-event loop.

### Verification

```bash
bash .agents/scripts/tests/test-dependency-event-reconciler.sh
bash .agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh
bash .agents/scripts/tests/test-dependency-supersession-lib.sh
bash .agents/scripts/tests/test-full-loop-closing-reconciliation.sh
shellcheck .agents/scripts/dependency-event-reconciler.sh .agents/scripts/tests/test-dependency-event-reconciler.sh
.agents/scripts/linters-local.sh --changed
```

- **Runtime:** after deployment, the next stale sweep of the census repo releases the dependency-resolved issues whose only hold was body text (stale-sweep log line plus label timeline), while the no-dependency cost-breaker and infrastructure-failure blocks stay `status:blocked`.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Files Scope

- `.agents/scripts/dependency-event-reconciler.sh`
- `.agents/scripts/tests/test-dependency-event-reconciler.sh`
- `TODO.md`
- `todo/tasks/t18662-brief.md`

## Acceptance Criteria

- [ ] `_der_has_hold` returns no hold for a body containing only terminal-blocker worker-protocol text, and still returns a hold for the same vocabulary in a trusted comment, for `HUMAN_UNBLOCK_REQUIRED` / `ACTION REQUIRED` in the body, and for every existing classifier case.
- [ ] The stale sweep releases a `status:blocked` issue whose dependencies are closed and whose body documents the terminal-blocker protocol.
- [ ] The stale sweep leaves a `status:blocked` issue with no native edge, no declared ref and no `blocked-by:` label unchanged, even with no hold markers.
- [ ] A close event with two dependants, where the first still has another open blocker, releases the second.
- [ ] Existing reconciler, supersession and stale-recovery suites pass; ShellCheck and `linters-local.sh --changed` are clean.

## Context & Decisions

- Only the terminal-blocker family moves to comment scope: it is the only strong token observed in bodies, and every runtime writer of it posts comments. `HUMAN_UNBLOCK_REQUIRED`, `ACTION REQUIRED`, `aidevops:brief-hold`, watchdog and `worker_blocked` markers keep body scope; the existing "strong machine markers remain authoritative inside examples" decision stands.
- Not in scope: relaxing comment-side terminal-blocker holds (the dispatch-time circuit already decides retries, but trusted comments stay holds here), teaching the reconciler cost-breaker or infrastructure-failure markers (the evidence guard leaves those blocks to their own release paths), and dep-graph refresh budget or starvation.
- A worker BLOCKED release without an observation comment (`CLAIM_RELEASED reason=blocked` alone) is not a reconciler hold today and stays that way; the dispatch-time backoff and circuit handle repeated blocked releases.
