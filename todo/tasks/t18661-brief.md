<!-- aidevops:brief-schema=v2 -->

# t18661: keep dependants blocked while a consolidated blocker's successor is open

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `consolidated blocker successor superseded dependency NOT_PLANNED stateReason resolver` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found 0 open related PRs for the target files; last relevant changes are 589016c402 (t18646 blocked-by:GH# labels), 74f9d071c8 (GH#33957 stale sweep), e20544d82e (GH#34056 bounded refresh)
- [x] File refs verified: `_blocked_by_check_native_relationships` / `_blocked_by_check_issue_num_live` (`.agents/scripts/pulse-dep-graph.sh`), `_der_native_blockers_closed` / `_der_all_declared_blockers_closed` (`.agents/scripts/dependency-event-reconciler.sh`), consolidation close step (`.agents/scripts/pulse-triage-dispatch.sh` `_compose_consolidation_worker_instructions`) checked at origin/main 6ac3f12f71
- [x] Tier: `tier:standard` — read-side resolver change on the dispatch/unblock safety path; fails closed on unverifiable supersession
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Found while maximising worker throughput for a managed private repo's enrichment backlog: dependants of consolidated issues were dispatched before the consolidated work existed.

## What

Dependency readiness treats a native or declared blocker that was **closed as superseded** (`stateReason` `NOT_PLANNED`/`DUPLICATE` plus a trusted `Superseded by #S` comment) as unresolved while its successor chain is still open. Dependants stay blocked (dispatch gate, dep-graph refresh, dependency-event reconciler, stale sweep) until the successor finishes, instead of being dispatched against work that has not happened yet.

## Why

Consolidation (`_compose_consolidation_worker_instructions`, `pulse-triage-dispatch.sh`) comments `Superseded by #NEW`, labels the parent `consolidated` and closes it `not planned`. The parent's native `blocking` edges are not moved to the successor, and every resolver treats any `CLOSED` blocker as done:

- `_blocked_by_check_native_relationships` read `blockedBy { nodes { number state } }` and returned "positively clear" for an all-`CLOSED` set; the dispatch gate (`is_blocked_by_unresolved`), final pre-launch attestation and dep-graph refresh rely on it.
- `_der_native_blockers_closed` and `_der_all_declared_blockers_closed` did the same, so close events and the stale sweep flipped dependants to `status:available`.

Read-only scan of one managed private repo (2026-10-11): 482 open issues, **40 dependants with native blockers closed `NOT_PLANNED`**; 39 of those blockers carry a trusted `Superseded by #S` comment whose successor body says `Supersedes #P`; about 14 dependants were `status:available`/`queued` while their successor was still open. Workers dispatched there start before their prerequisite exists, spend tokens and often end in terminal-blocker comments.

## How

### Files to Modify

- `NEW: .agents/scripts/dependency-supersession-lib.sh` — shared resolver `dep_supersession_outstanding <blocker_repo> <blocker_number> <state_reason> [dependant_ref]` plus the logging wrapper `dep_supersession_blocks`; one response-metered GraphQL read per hop (`issueOrPullRequest { state stateReason comments(last:100) }` + `rateLimit { cost }`), modelled on the exact-cost GraphQL pattern in `_blocked_by_check_native_relationships` and the sourced-lib load guard in `task-identity-lib.sh`.
- `EDIT: .agents/scripts/pulse-dep-graph.sh` — source the lib; `_blocked_by_check_native_relationships` also reads `stateReason repository { nameWithOwner }` and blocks a `CLOSED` node whose supersession is outstanding; `_blocked_by_check_issue_num_live` reads `state,stateReason` and applies the same rule. Net +4 lines (file stays under the 1500-line shell size ratchet).
- `EDIT: .agents/scripts/dependency-event-reconciler.sh` — source the lib; `_der_native_blockers_closed` takes an optional `readiness` mode that returns `DER_NOT_READY` for an outstanding superseded node; declared blockers go through the new `_der_live_blocker_resolved`, which applies the rule only when given a dependant ref. `_der_try_unblock` opts in; the closed-event self-check `_der_live_issue_closed` is unchanged.
- `NEW: .agents/scripts/tests/test-dependency-supersession-lib.sh` — resolver semantics with a GraphQL fixture mock.
- `EDIT: .agents/scripts/tests/test-pulse-dep-graph-stale-label-cleanup.sh` and `EDIT: .agents/scripts/tests/test-dependency-event-reconciler.sh` — wiring cases.

### Resolver rules

1. Only `CLOSED` blockers whose reason is `NOT_PLANNED` or `DUPLICATE` are inspected; `COMPLETED`/legacy empty reasons keep the closed-means-resolved rule with no extra request.
2. aidevops:trust-boundary — the successor comes only from the newest `OWNER`/`MEMBER`/`COLLABORATOR` comment whose first non-blank line starts `Superseded by #N` (same repository as the blocker). Other mentions are ignored.
3. Follow the chain at most 3 hops. `OPEN` successor → outstanding. `CLOSED` successor that is itself superseded → next hop. Otherwise (completed, merged PR, closed without a successor) → resolved.
4. A successor equal to the dependant itself resolves (the dependant owns the work; no self-deadlock).
5. Lookup failure, missing cost, unknown state, reopened blocker, cycle or hop limit → outstanding (fail closed), logged with the reason from `DEP_SUPERSESSION_DETAIL`.
6. Readiness only. `_der_completion_blockers_closed` (TODO completion close in `issue-sync-helper-close.sh`) keeps closed-is-done so finished work is never held open by an unrelated successor.

### Complete Write Surface

- **Callers/readers:** `is_blocked_by_unresolved` (dispatch dedup `pulse-dispatch-core.sh`, final attestation `pulse-dispatch-worker-gates.sh`, stale recovery `dispatch-dedup-stale.sh`), `_refresh_dependency_is_resolved` (dep-graph refresh), `_der_try_unblock` (close events, stale sweep). `_der_completion_blockers_closed` is deliberately unchanged.
- **Deliberately unchanged reader:** `_dependency_native_blockers_closed_for` (`issue-sync-relationships-gh.sh`) only exempts an all-closed edge from issue-sync's available→blocked move and never moves blocked→available; the dispatch gate above stays authoritative and refresh corrects the label.
- **Writers/mutation paths:** no new writes; existing label edits (`_refresh_ensure_unresolved_is_blocked`, `_der_try_unblock`) simply see "unresolved" for these blockers, so refresh moves affected `status:available` dependants back to `status:blocked` (queued/in-progress untouched).
- **Existing verification/tests:** `test-pulse-dep-graph-stale-label-cleanup.sh`, `test-dependency-event-reconciler.sh`, `test-dependency-readiness-normalization.sh`, `test-stale-recovery-blocked-by-recheck.sh`, `test-pulse-dep-graph-todo-drift.sh`, `test-pulse-dispatch-worker-launch-lock.sh`, `test-dispatch-candidate-failure-reasons.sh`, `test-pulse-dep-graph-*` siblings, `test-pulse-merge-routine-standalone.sh`, `test-planning-pr-guard.sh`.
- **Schemas/config:** N/A — no config keys; `DEP_SUPERSESSION_MAX_HOPS` env override defaults to 3.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*.sh` to `~/.aidevops/agents/scripts/`; the new lib is picked up by the existing deployment.
- **Migrations/backfills:** none — read-side rule applies to existing edges; no relationship edits.
- **Cleanup/rollback paths:** revert the PR; no persisted state.

### Hazards and Compatibility

- **Concurrency/atomicity:** read-only lookups; existing re-read-before-edit guards in the label writers are unchanged. Consolidation posts `Superseded by` before closing the parent, so a closed parent is observed with its marker.
- **Migration/rollback:** none; reverting restores closed-means-resolved.
- **Mixed-version/backward compatibility:** runners on older versions keep the old rule; GraphQL nodes without `stateReason` behave as before.
- **Idempotency/retry:** pure function of live GitHub state; retries re-read.
- **Partial failure/recovery:** API failure on a superseded blocker blocks (same as the existing unknown-state rule) and recovers on the next cycle; a dangling marker naming a missing issue stays blocked with a logged `lookup failed` reason until a maintainer corrects it.

### Verification

```bash
bash .agents/scripts/tests/test-dependency-supersession-lib.sh
bash .agents/scripts/tests/test-pulse-dep-graph-stale-label-cleanup.sh
bash .agents/scripts/tests/test-dependency-event-reconciler.sh
bash .agents/scripts/tests/test-dependency-readiness-normalization.sh
bash .agents/scripts/tests/test-stale-recovery-blocked-by-recheck.sh
shellcheck .agents/scripts/dependency-supersession-lib.sh .agents/scripts/pulse-dep-graph.sh .agents/scripts/dependency-event-reconciler.sh
.agents/scripts/linters-local.sh --changed
```

- **Runtime:** read-only probe of `_blocked_by_check_native_relationships` on the 40 live dependants: open-successor cases block, completed-successor cases stay clear.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Files Scope

- `.agents/scripts/dependency-supersession-lib.sh`
- `.agents/scripts/pulse-dep-graph.sh`
- `.agents/scripts/dependency-event-reconciler.sh`
- `.agents/scripts/tests/test-dependency-supersession-lib.sh`
- `.agents/scripts/tests/test-pulse-dep-graph-stale-label-cleanup.sh`
- `.agents/scripts/tests/test-dependency-event-reconciler.sh`
- `TODO.md`
- `todo/tasks/t18661-brief.md`

## Acceptance Criteria

- [ ] A dependant whose native blocker is closed `NOT_PLANNED` with a trusted `Superseded by #S` comment and an open `#S` is reported unresolved by `is_blocked_by_unresolved`, `_refresh_dependency_is_resolved` and `_der_native_blockers_closed ... readiness` (`DER_NOT_READY`).
- [ ] When `#S` is closed `COMPLETED`, the same dependant resolves clear (no regression for finished consolidations).
- [ ] Regression: `COMPLETED` blockers trigger no extra API request; `NOT_PLANNED` blockers without a trusted first-line `Superseded by #N` comment keep resolving clear; untrusted commenters cannot redirect a dependency; completion checks keep closed-is-done.
- [ ] Fail closed: lookup failure, unknown state, cycles and chains longer than 3 hops keep the dependant blocked with a logged reason; a successor that is the dependant itself resolves.

## Context & Decisions

- Read-side guard first: covers historical consolidations without relationship backfills or mass label edits. Moving native edges to the successor at consolidation time, and reconciling a superseded parent's dependants when the successor closes (today the stale sweep and refresh catch them), are separate follow-ups.
- The `consolidated` label is not required: any trusted first-line `Superseded by #N` on a not-planned/duplicate closure carries the same meaning.
- Completion sync is excluded on purpose: holding a finished task's issue open until an unrelated successor closes would create stale open issues without protecting any work.
