<!-- aidevops:brief-schema=v2 -->

# t18667: reserve the post-label refill's real dispatch admission budget so pre-refill stages cannot spend it

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `post-label refill dispatch admission budget enumeration reserve` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open related PR or issue. Related history: GH#32259 (#32264, sized the post-label refill reserve at 600 s), GH#33560 (#33561, added the enumeration estimate to dispatch admission), GH#33944 (#34075, refill skips dependency normalization), GH#33737 (first-wave reserve for pre-dispatch stages), GH#34302 (#34306, bounded/resumable label maintenance)
- [x] File refs verified at origin/main 8e0ba8c1c0: `_preflight_refill_reserved_timeout` (`.agents/scripts/pulse-dispatch-preflight-lib.sh:454`), `_preflight_post_label_refill_wall_clock_allows` (`:523`), `_preflight_post_label_refill` (`:555`); call sites `.agents/scripts/pulse-dispatch-engine.sh:1971`, `:1978`, `:1986`; admission `_dispatch_cycle_budget_admits_round` (`.agents/scripts/pulse-dispatch-lib-candidates.sh:747`); estimator `_dispatch_enumeration_expected_seconds` (`:702`)
- [x] Tier: `tier:standard` — budget arithmetic in one preflight library; no dispatch gate weakened
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Enrichment throughput drive: the runner sat at 0–3 of 20 worker slots while the post-label refill, the cycle's second dispatch opportunity, never reached candidate enumeration.

## What

The post-label refill and the optional stages before it (label maintenance, trusted-NMR reconciliation) use the refill's real dispatch admission budget — finalise reserve + per-candidate floor + measured full-scan enumeration estimate (990 s with the 300 s cold estimate) — instead of the configured 600 s minimum:

- while the cycle can still admit the refill, optional stages are clamped to leave that budget plus a 60 s margin;
- once it cannot, they keep today's 605 s clamp;
- the refill's wall-clock gate requires the same budget, so it no longer starts a refill that admission must skip.

## Why

- `dispatch_max` enumerates only while `remaining − finalise ≥ floor + enumeration` (`_dispatch_cycle_budget_admits_round`, GH#33560): 990 s raw by default, 1093 s with the recent 403 s estimate. GH#32259 sized the post-label reserve and gate at 600 s before that admission reserve existed, and it was never raised.
- Current `pulse.log`: 26 of the 30 post-label refills that passed the 600 s gate were then skipped before candidate enumeration — `remaining=505–803s` (after the finalise reserve) against `floor=600s enumeration=300–448s`. The `Dispatch current-state guardrail` lines at those refills show 17–20 of 20 slots available.
- In the two recent cycles with fast first waves (172 s and 184 s), 1444 s or more remained when label maintenance started. Label maintenance (527–555 s) and trusted-NMR reconciliation (103–108 s) ran under the 605 s clamp and left the refill 790–814 s raw.
- Clamped stages also overran the 5 s margin by 6, 10 and 24 s (70 s with REST degraded), so even the 600 s gate skipped at 599/595/581/535 s.
- In both of those cycles the next dispatch admission was skipped with negative remaining (−10 s, −11 s), so a dead refill left the cycle with only its first wave.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-preflight-lib.sh`
  - new `_preflight_post_label_refill_required_seconds`: max(configured minimum, finalise + floor + full-scan estimate), mirroring `_dispatch_cycle_budget_admits_round`. It uses the configured minimum when the admission reserve is disabled (`AIDEVOPS_PULSE_DISPATCH_BUDGET_RESERVE` ≠ 1), the estimator is not loaded, the cycle length is unknown, or the reserve could never fit one cycle.
  - `_preflight_refill_reserved_timeout`: reserve that budget + 60 s while the refill still fits; otherwise the configured minimum + 5 s (today).
  - `_preflight_post_label_refill_wall_clock_allows`: require the same budget.

### Complexity Impact

- New `_preflight_post_label_refill_required_seconds`: 17 body lines.
- `_preflight_refill_reserved_timeout`: 10 → 19 body lines.
- `_preflight_post_label_refill_wall_clock_allows`: +3 lines.

### Complete Write Surface

- **Callers/readers:** `_run_preflight_stages` only (`pulse-dispatch-engine.sh:1971`, `:1978`, `:1986`).
- **Writers/mutation paths:** none — no state files, labels, claims or GitHub writes. Log line text is unchanged; `required=` now reports the real budget.
- **Existing verification/tests:** `test-pulse-dispatch-engine-stage-wiring.sh` sources only the preflight library (no estimator), so its contracts keep the configured 600 s path. `test-pulse-dispatch-first-wave.sh` uses a 2476 s estimate that exceeds the cycle, so it also keeps 600 s.
- **Schemas/config:** no new knob. `PULSE_POST_LABEL_REFILL_MIN_REMAINING_SECONDS` stays a lower bound; `AIDEVOPS_PULSE_DISPATCH_BUDGET_RESERVE`, `DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR` and `AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S` are read as admission reads them.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*.sh` into the runtime bundle.
- **Migrations/backfills:** none.
- **Cleanup/rollback paths:** revert the PR. `AIDEVOPS_PULSE_DISPATCH_BUDGET_RESERVE=0` restores the 600 s path but also disables the admission reserve.

### Hazards and Compatibility

- **Optional work:** in cycles where the refill fits, label maintenance and trusted-NMR reconciliation get up to 445 s less. Label maintenance is bounded and resumable per key (GH#34302); trusted-NMR reconciliation runs every cycle.
- **No starvation for a refill that cannot run:** when the refill cannot fit, optional stages keep today's clamp and the gate skips the refill without invalidating the candidate snapshot.
- **Safety:** no dispatch, claim, dedup, trust or budget gate changes; admission stays authoritative.
- **Known limit:** the 60 s margin does not cover the 70 s overrun seen with degraded REST; that refill is skipped as today.
- **Bash 3.2:** no new constructs beyond those already used by the admission code.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-dispatch-preflight-lib.sh
bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh
bash .agents/scripts/tests/test-pulse-dispatch-first-wave.sh
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
bash .agents/scripts/tests/test-pulse-graphql-budget-priority.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** a scratch harness sources the real watchdog, candidates and preflight libraries under a sandbox `HOME` with a mocked clock (32 cases, Bash 5.3 and 3.2) and checks:
  - required-budget fallbacks;
  - stage clamp fits/defers/falls back;
  - gate decisions;
  - the gate matches `_dispatch_cycle_budget_admits_round` at every second of an 1800 s cycle (300 s and 403 s estimates);
  - a replay of the 172 s first-wave cycle: legacy admits the refill at 600 s and admission then skips it; the new path reaches enumeration with 951 s.
- **shfmt advisory:** pre-existing `case` formatting in untouched label-maintenance code.
- **Runtime:** after deploy, `pulse.log` shows either `Post-label dispatch_max: refilling` with enumeration proceeding, or `Post-label dispatch_max skipped: insufficient wall-clock budget (... required=990s)`. An admitted refill should no longer be followed by `Dispatch_max skipped before candidate enumeration`.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Files Scope

- `.agents/scripts/pulse-dispatch-preflight-lib.sh`
- `TODO.md`
- `todo/tasks/t18667-brief.md`

## Acceptance Criteria

- [ ] While the cycle can still admit the refill, label maintenance and trusted-NMR reconciliation leave finalise + floor + full-scan estimate + 60 s; otherwise they keep today's configured-minimum clamp.
- [ ] The refill gate admits exactly when `_dispatch_cycle_budget_admits_round` would admit before enumeration at the same instant. It falls back to the configured minimum when the admission reserve is disabled, the estimator is unavailable, or the reserve exceeds the cycle.
- [ ] `PULSE_POST_LABEL_REFILL_MIN_REMAINING_SECONDS` remains a lower bound; an invalid value still skips with `wall-clock budget unavailable`.
- [ ] ShellCheck, the listed suites and `linters-local.sh --changed` pass.

## Context & Decisions

- **Mirror, don't call:** `_dispatch_cycle_budget_admits_round` logs and counts a skip, so the preflight repeats its arithmetic instead of probing it.
- **Fall back when the refill cannot fit:** holding the full reserve would starve optional work for a refill that admission will skip anyway.
- **60 s margin:** observed overruns of 6–24 s plus 2–5 s between the gate and admission; the 70 s degraded-REST overrun is accepted.
- **Not in scope:** first-wave duration (754–1996 s in most recent cycles, which is why most refills cannot fit), trusted-NMR reconciliation starving behind label maintenance, and the end-of-cycle dispatch budget. Each needs its own evidence before a separate task.
