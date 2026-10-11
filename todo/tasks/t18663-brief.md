<!-- aidevops:brief-schema=v2 -->

# t18663: stop stale-blocked sweep and dep-graph refresh starving repos with real backlogs

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `stale blocked sweep fair share starvation dep-graph refresh budget` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found 0 open related PRs for the target files; last relevant changes are 0e83416a58 (t18661 supersession readiness), 035691f2f7 (GH#34331 first-wave capacity), 589016c402 (t18646 blocked-by:GH# labels), e20544d82e (#34056 bounded dep-graph refresh), 74f9d071c8 (GH#33957 resumable stale sweep)
- [x] File refs verified at origin/main 34247feb1f: `_pulse_reconcile_stale_blocked_if_due`, `_pulse_stale_blocked_sweep_deadline` (`.agents/scripts/pulse-wrapper-cycle.sh`); `refresh_blocked_status_from_graph`, `_refresh_graph_repo` (`.agents/scripts/pulse-dep-graph.sh`); `reconcile_stale_blocked_issues` (`.agents/scripts/dependency-event-reconciler.sh`, unchanged)
- [x] Tier: `tier:standard` — scheduling-only change in two bounded pulse stages; no unblock decision changes
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Found while maximising worker throughput for a managed private repo's enrichment backlog: after t18662 the reconciler could release dependency-ready issues, but the two periodic recovery stages reached that repo's backlog at about one issue per cycle.

## What

Both periodic recovery stages spend their time budget on repos that still have work:

1. **Stale-blocked sweep** (`_pulse_reconcile_stale_blocked_if_due`): each repo records its own completion stamp after a clean, complete pass. A repo whose stamp is younger than `PULSE_STALE_BLOCKED_RECONCILE_INTERVAL` is not re-listed; the sweep budget is shared only among due repos (partial, failed or never swept). The global sentinel, rotation offset, fair-share deadlines and hard stop keep their current meaning.
2. **Dep-graph refresh** (`refresh_blocked_status_from_graph`): `DEP_GRAPH_REFRESH_BUDGET_SECS` is shared only among repos with dependency entries. They run smallest backlog first, and each share is recomputed from the time actually left, so unused time rolls forward to the largest backlog. Repos without entries keep a 1s share; they do no candidate work.

## Why

Pulse log evidence (2026-10-11):

- **Stale sweep never converges.** The last 8 sweep summaries report `failures=0 partial_repos=31..51 repos=57`. The sweep budget is about 45s (`PULSE_STALE_BLOCKED_RECONCILE_TIMEOUT_SECONDS` 60 minus the 15s margin) split across all 57 repos, so the integer share is 0–1s. `reconcile_stale_blocked_issues` stops after its first visit once the share deadline passes, so repos with only 2 candidates log `visited=1 ... complete=false`. Because some repo is always partial, the global sentinel is never touched and every cycle re-lists every repo, including repos that already finished. The managed private repo with ~340 blocked candidates advanced one issue per visit.
- **Dep-graph refresh share rounds down to 1s.** The graph cache holds 57 repos, but only 6 have `blocked_by` entries (162 entries, the largest has 152). The 30s budget is divided by all 57 repos (`30 / 57 = 0`, clamped to 1), so recent full-cycle refresh lines all log `budget_secs=1`; the 153-candidate repo logs `visited=1 ... complete=false` on each refresh, as does a 6-candidate repo. Repo-scoped refreshes (`normalize_repo_dependency_readiness`) build a one-repo graph and keep the full budget.

Neither stage changes what is released; both only control how quickly dependency-ready issues are found. Close events (`reconcile_dependants_after_verified_closure`) remain the primary release path; these stages recover missed events.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-wrapper-cycle.sh`
  - New `_pulse_stale_blocked_repo_stamp <slug>`: `~/.aidevops/cache/stale-blocked-complete/<owner>__<repo>`; rejects slugs outside `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` (same `/` → `__` mapping as `_der_stale_cursor_file`).
  - New `_pulse_stale_blocked_repo_fresh <slug> <interval> <now>`: true only for a readable stamp with `0 <= now - mtime < interval`; missing, unreadable or future-dated stamps make the repo due.
  - New `_pulse_stale_blocked_repo_mark_complete <slug>`: best-effort `touch`; a write failure only keeps the repo due.
  - `_pulse_reconcile_stale_blocked_if_due`: build the due list in rotation order, skip fresh repos, divide the remaining budget by the due count, and stamp a repo only when `reconcile_stale_blocked_issues` returns 0. Log `fresh_repos=<n>` in the summary line.
- `EDIT: .agents/scripts/pulse-dep-graph.sh` — `refresh_blocked_status_from_graph`: list repos as `<entry_count>\t<slug>` sorted by count then slug; count active repos (entries > 0); for each active repo `share = (budget - elapsed) / active_left`, minimum 1s.
- `EDIT: .agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh` — the rotation scenario clears per-repo stamps between sweeps; new cases: a fresh repo is skipped and the due repo gets the whole budget; a partial pass stamps neither the repo nor the sentinel; a clean pass stamps both; a failed pass stays due; a future-dated stamp never suppresses a repo; `fresh_repos` is logged.
- `EDIT: .agents/scripts/tests/test-pulse-dep-graph-stale-label-cleanup.sh` — new `test_refresh_budget_shared_by_active_repos`: idle repos do not dilute the share (`budget_secs=30` with one active repo among four); a small backlog runs first and the large backlog receives the rolled-forward time and completes.

### Complexity Impact

- `_pulse_reconcile_stale_blocked_if_due` 59 → 76 lines; three new helpers of 6–9 lines; `refresh_blocked_status_from_graph` 34 → 45 lines. All below the 100-line gate.

### Complete Write Surface

- **Callers/readers:** `_pulse_reconcile_stale_blocked_if_due` is called once per cycle from `pulse-wrapper.sh` under `PULSE_STALE_BLOCKED_RECONCILE_TIMEOUT_SECONDS`. `refresh_blocked_status_from_graph` is called from the in-cycle pipeline after `build_dependency_graph_cache` (`pulse-wrapper.sh`), from `_pulse_run_blocker_refresh_catchup` (`pulse-dispatch-engine.sh`) and from `normalize_repo_dependency_readiness` with a one-repo graph (`pulse-dep-graph.sh`). No other code reads the summary log line (`rg 'partial_repos='`) or `DEP_GRAPH_REFRESH_BUDGET_SECS`.
- **Writers/mutation paths:** no new GitHub writes. New local state: one empty stamp file per repo under `~/.aidevops/cache/stale-blocked-complete/`. Unblock decisions remain `_der_try_unblock` (stale sweep) and `_refresh_try_unblock_issue` (graph refresh), unchanged; `reconcile_stale_blocked_issues`, its cursor, batch limit and deadline contract, `_refresh_graph_repo` and `DEP_GRAPH_REFRESH_MAX_CANDIDATES` are untouched.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh` (sweep cadence, rotation, fair share, stage wiring) and `.agents/scripts/tests/test-pulse-dep-graph-stale-label-cleanup.sh` (bounded traversal, cursor, elapsed budget); runtime evidence is the sweep summary and `dep-graph-cache: refresh` lines in `~/.aidevops/logs/pulse.log`.
- **Schemas/config:** N/A because no schema or config file changes; `PULSE_STALE_BLOCKED_RECONCILE_INTERVAL`, `PULSE_STALE_BLOCKED_RECONCILE_TIMEOUT_SECONDS` and `DEP_GRAPH_REFRESH_BUDGET_SECS` keep their meaning and defaults.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*.sh` to `~/.aidevops/agents/scripts/`.
- **Migrations/backfills:** N/A because no backfill is needed: with no stamps after deploy every repo is due on the first sweep, which is the current behaviour; `~/.aidevops/cache/stale-blocked-complete/` is created on the first clean pass.
- **Cleanup/rollback paths:** revert the PR; older code ignores `~/.aidevops/cache/stale-blocked-complete/`, and deleting it only makes every repo due again.

### Implementation Steps

1. In `.agents/scripts/pulse-wrapper-cycle.sh`, add `_pulse_stale_blocked_repo_stamp`, `_pulse_stale_blocked_repo_fresh` and `_pulse_stale_blocked_repo_mark_complete` above `_pulse_reconcile_stale_blocked_if_due`.
2. In `_pulse_reconcile_stale_blocked_if_due`, build the due list in rotation order (skipping fresh repos), share the remaining budget by the due count, stamp only on return 0, and add `fresh_repos=` to the summary line.
3. In `.agents/scripts/pulse-dep-graph.sh` `refresh_blocked_status_from_graph`, sort repos by entry count, count active repos, and recompute each active share from the time left.
4. Extend both existing test scripts with the cases listed above, confirm the new cases fail against the previous implementation, then run the Verification Before Dispatch commands.

### Hazards and Compatibility

- **Concurrency/atomicity:** the mkdir-based pulse instance lock (`acquire_instance_lock`, `pulse-wrapper.sh`) allows one sweep at a time; stamps are single `touch` calls, and a stamp racing a manual run can only make a repo due early or late by one interval.
- **Migration/rollback:** no ordering requirement; deploy and revert are both safe at any point because a missing stamp means due, and old code never reads stamps.
- **Mixed-version/backward compatibility:** older runners ignore stamps and sweep every repo as today; the summary log line only gains a trailing `fresh_repos=` field, which no code parses.
- **Idempotency/retry:** a repo is skipped only after a clean, complete pass inside the configured interval, the cadence the global sentinel already promised; partial and failed passes stay due and retry next cycle as today. `/` → `__` stamp names match the existing stale cursor files, and GitHub owners cannot contain `_`, so names do not collide.
- **Partial failure/recovery:** a killed sweep leaves stamps only for repos that finished cleanly and persists the rotation offset before each start, so the next cycle resumes with the remaining due repos; unreadable or future-dated stamps make a repo due; a stamp write failure only keeps the repo due. The dep-graph refresh still checks elapsed time before each new candidate and visits at least one.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh
bash .agents/scripts/tests/test-pulse-dep-graph-stale-label-cleanup.sh
bash .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh
bash .agents/scripts/tests/test-dependency-readiness-normalization.sh
bash .agents/scripts/tests/test-pulse-graphql-budget-priority.sh
bash .agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh
shellcheck .agents/scripts/pulse-wrapper-cycle.sh .agents/scripts/pulse-dep-graph.sh .agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh .agents/scripts/tests/test-pulse-dep-graph-stale-label-cleanup.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** `test-pulse-stale-blocked-reconcile.sh` proves the per-repo cadence, due-only budget share, partial/failed/future-stamp hazards and stage wiring (acceptance 1–2); `test-pulse-dep-graph-stale-label-cleanup.sh` proves the active-repo share and rollover (acceptance 3) plus the unchanged cursor and elapsed-budget contract; the non-dep-block, readiness-normalization, budget-priority and housekeeping suites cover the other callers of `refresh_blocked_status_from_graph`; ShellCheck and `linters-local.sh --changed` cover both edited scripts (acceptance 4).
- **Runtime:** after deployment, sweep summaries report a growing `fresh_repos` count and a shrinking `partial_repos` count over consecutive cycles until the sentinel is touched; dep-graph refresh lines for repos with entries report `budget_secs` above 1.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Files Scope

- `.agents/scripts/pulse-wrapper-cycle.sh`
- `.agents/scripts/pulse-dep-graph.sh`
- `.agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh`
- `.agents/scripts/tests/test-pulse-dep-graph-stale-label-cleanup.sh`
- `TODO.md`
- `todo/tasks/t18663-brief.md`

## Acceptance Criteria

- [ ] A repo with a clean pass inside the interval is not re-listed, and the remaining due repos share the whole sweep budget.
- [ ] Partial and failed passes never stamp the repo; a partial pass never touches the global sentinel; missing or future-dated stamps keep a repo due.
- [ ] Dep-graph refresh gives each repo with entries `(budget - elapsed) / remaining active repos` seconds (minimum 1), smallest backlog first, so idle repos no longer reduce the share.
- [ ] The new tests fail against the previous implementation and pass with the change; existing stale-sweep, dep-graph, readiness and budget-priority suites pass; ShellCheck and `linters-local.sh --changed` are clean.

## Context & Decisions

- Per-repo stamps instead of a smaller global sentinel: the global sentinel can only mark a traversal of all repos, which one large backlog prevents indefinitely.
- Failed passes stay due, as today, so transient listing failures retry on the next cycle; once no repo is partial the global sentinel still rests the whole sweep for the interval.
- Smallest-first ordering for the graph refresh is deterministic, and it lets each small backlog finish its batch before the largest one takes the remaining time. Ordering within the stale sweep keeps the persisted rotation.
- Not in scope: raising stage timeouts, batch limits or dispatch capacity; host CPU gate tuning; changing what either stage releases.
