<!-- aidevops:brief-schema=v2 -->

# t18665: rotate dispatch attempts so repeatedly blocked head candidates stop starving the never-attempted backlog

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse dispatch candidate ordering starvation repeated blocked head first wave` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open or recently merged PRs on the dispatch candidate files; no open issue covers dispatch starvation or round-robin ordering. Related history: 035691f2f7 (GH#34331 first-wave capacity), 849e2c0af5 (GH#33743 capability cooldown), 65cb9ed1f9 (GH#33647 first wave), d3c07a1b07 (#32580 benign-block skip; its ledger is now reinitialised on every `dispatch_max` run, `.agents/scripts/pulse-dispatch-lib-capacity.sh:562-570`)
- [x] File refs verified at origin/main 51296462a4: `_dispatch_process_candidate` (`.agents/scripts/pulse-dispatch-lib.sh:515`; attempt log line 574, launch confirmed 598); `dispatch_max` and its ordering call (`.agents/scripts/pulse-dispatch-engine.sh:759`, `:811`); `_dispatch_order_idle_borrowing_candidates` (`pulse-dispatch-engine.sh:570`); ranking sort (`pulse-dispatch-engine.sh:548`); capability-cooldown per-candidate state (`.agents/scripts/pulse-dispatch-lib-candidates.sh:972-1120`)
- [x] Tier: `tier:standard` — order-only change in one round orchestrator plus a runner-local stamp; every dispatch gate unchanged
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Enrichment throughput drive on a managed private repo: the runner sat at 0–2 of 20 worker slots for 12 cycles while that repo's available backlog was non-empty.

## What

`dispatch_max` orders each round so candidates attempted within a window without a worker launch go after the candidates of the same priority tier that were not attempted in that window; the recently attempted ones rotate oldest attempt first. A runner-local per-candidate stamp is written at `DISPATCH_CANDIDATE_ATTEMPT` and removed when a worker launch is confirmed.

## Why

- Rounds are bounded by the cycle wall-clock budget: a round stops taking candidates once less than the 600 s per-candidate floor remains. Two recent large rounds covered only a prefix of the ranked list — `processed=26/82` and `processed=28/80`, both `implementation_dispatched=0` and both ending with `Dispatch_max stopping early: cycle wall-clock budget below per-candidate floor` (28 such stops in the current `pulse.log`). Dedup layers alone took up to 144.5 s per attempt for the managed private repo below (p90 30.9 s; `dispatch-stages.tsv`, 9–11 Oct).
- The ranking is deterministic (priority tier, score, `createdAt`), and the benign-block ledger is deliberately cycle-local so stale active claims cannot suppress later cycles. Every round therefore re-attempts the same head candidates.
- Runner evidence (current `pulse.log`; read-only available-issue probe at 11:06Z): the managed private repo's top head candidates were attempted 15–23 times each (`blocked_by_unresolved`, `footprint_overlap`, `dedup_active_claim`, `consolidated`, `terminal_blocker_circuit`). Meanwhile 24 of its 47 `status:available` issues in the enrichment class (20 of them `auto-dispatch`) had never been attempted on this runner. 17 of those 24 are `tier:thinking`, which the score ranks 1200 points below `tier:standard`.
- Last 12 cycles (`pulse-cycle-index.jsonl`, to 11:02Z): 0–2 of 20 workers active; 9 of the 12 dispatched nothing.
- Order-only rotation lets bounded rounds reach the untried tail without weakening any gate.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-lib-candidates.sh` — after `_dispatch_filter_capability_cooled_candidates`, following its per-candidate state pattern:
  - window knob `AIDEVOPS_DISPATCH_ATTEMPT_RECENCY_SECONDS` (default 86400, `0` disables, capped at 604800);
  - `_dispatch_attempt_recency_path`, `_dispatch_attempt_recency_stamp` (mktemp + mv), `_dispatch_attempt_recency_clear`;
  - `_dispatch_attempt_recency_stamps` (emit in-window stamps; remove expired, future-dated and malformed ones);
  - `_dispatch_order_attempt_recency_candidates`: one jq stable sort by `[-priority_rank, attempted, attempt epoch, original index]`. It fails open and emits one log line plus a stats counter when it demotes anything.
- `EDIT: .agents/scripts/pulse-dispatch-lib.sh` — `_dispatch_process_candidate`: stamp after `attempt_epoch=$(date +%s)`; clear after `dispatch_worker_spawned`.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh` — new `_dispatch_order_round_candidates` (recency order when loaded, then `_dispatch_order_idle_borrowing_candidates`); `dispatch_max` calls it in place of the direct idle-borrowing call.

### Complexity Impact

- `_dispatch_process_candidate`: 96 → 98 body lines (+2).
- `dispatch_max`: 99 → 99 (one call replaced).
- New functions each stay under 40 lines.

### Complete Write Surface

- **Callers/readers:** `_dispatch_process_candidate` is the only attempt path for the floor, parallel and priority loops. `dispatch_max` runs every round:
  - via `apply_dispatch_max`: normal passes, event refills, preflight/post-label refills;
  - directly: `_dispatch_min_worker_floor_refill`, `maybe_refill_underfilled_pool_during_active_pulse` and `_run_early_exit_recycle_loop`.
  - The priority phases (`_dispatch_priority_phase_candidates`) and the floor/max loops consume candidates in input order.
- **Writers/mutation paths:** new runner-local soft state `~/.aidevops/cache/dispatch-attempt-recency/<owner>--<repo>--<issue>` (one epoch per file). No GitHub writes, and no label, claim, ledger or reservation changes.
- **Existing verification/tests:** the suites that drive `dispatch_max` or `_dispatch_process_candidate` isolate `HOME`, so they see no stamps and today's order.
- **Schemas/config:** one environment knob; no config file change.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*.sh` into the runtime bundle.
- **Migrations/backfills:** none. Stamps start empty, so the first round after deploy keeps today's order and stamps what it attempts.
- **Cleanup/rollback paths:** `AIDEVOPS_DISPATCH_ATTEMPT_RECENCY_SECONDS=0` disables the rotation; reverting the PR restores today's order; leftover stamps are inert once the code is gone.

### Hazards and Compatibility

- **Priority:** `priority:critical`/`priority:high` tiers still lead strictly (GH#32703). Only the order inside a tier changes, and score order is kept among candidates not attempted recently.
- **Retry latency:** a recently attempted, still-blocked candidate is retried after its tier's fresher candidates, and at most one window later (default 24 h).
- **Safety:** ordering only. Dedup, claim, footprint, dependency, capability, eligibility and budget gates are unchanged and still run for every attempted candidate.
- **Concurrency:** parallel candidate subshells write distinct files atomically; a prune race can only lose a stamp, which falls back to today's order.
- **Bash 3.2:** no associative arrays or `mapfile`.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-dispatch-lib-candidates.sh .agents/scripts/pulse-dispatch-lib.sh .agents/scripts/pulse-dispatch-engine.sh
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
bash .agents/scripts/tests/test-pulse-dispatch-idle-debt-borrowing.sh
bash .agents/scripts/tests/test-pulse-dispatch-first-wave.sh
bash .agents/scripts/tests/test-pulse-wrapper-silent-dispatch.sh
bash .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** a scratch harness sources the real libraries under a sandbox `HOME` and checks:
  - no stamps → identical order;
  - stamps → fresh first within each tier, oldest attempt first, critical tier still first;
  - expired, future-dated and malformed stamps are removed;
  - window `0` or malformed JSON → unchanged order.
- **Pre-existing failure:** `test-pulse-wrapper-silent-dispatch.sh` fails 4/21 identically on an untouched `git archive` of origin/main 51296462a4. The secret-name gate from #32748 preempts the expected skip lines; tracked by t18666 (GH#34364).
- **Runtime:** after deploy, `pulse.log` shows the rotation line. On a later private-repo wave, the read-only available-issue probe shows previously never-attempted candidates being attempted and some launching.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Files Scope

- `.agents/scripts/pulse-dispatch-lib-candidates.sh`
- `.agents/scripts/pulse-dispatch-lib.sh`
- `.agents/scripts/pulse-dispatch-engine.sh`
- `TODO.md`
- `todo/tasks/t18665-brief.md`

## Acceptance Criteria

- [ ] A candidate attempted without a launch inside the window is ordered after every not-recently-attempted candidate of its priority tier, and recently attempted candidates rotate oldest attempt first.
- [ ] `priority:critical`/`priority:high` candidates still lead lower tiers regardless of stamps. With no stamps, or with the window set to `0`, round order is identical to today's.
- [ ] A confirmed launch removes the stamp. Expired, future-dated and malformed stamps are removed, and any state or jq failure returns the original order.
- [ ] ShellCheck, the listed dispatch suites and `linters-local.sh --changed` pass, apart from the pre-existing silent-dispatch failures noted above, which must match base exactly.

## Context & Decisions

- **Order, don't skip:** a cross-cycle skip ledger was rejected. The benign-block ledger is cycle-local on purpose (active claims clear), and skipping could starve a candidate whose blocker cleared. Demotion keeps every candidate reachable and every gate authoritative.
- **Time window, not `updatedAt`:** Pulse housekeeping updates issues itself, so an `updatedAt` reset could re-promote the same heads every cycle.
- **Applied in `dispatch_max`, after the 120 s ranked snapshot:** stamps written by the previous round's parallel subshells take effect in the next round.
- **Not in scope:** cycle-budget reserve sizing for refill rounds and per-candidate ceremony cost. Each needs its own fresh evidence before a separate task.
