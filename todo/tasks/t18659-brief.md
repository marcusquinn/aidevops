<!-- aidevops:brief-schema=v2 -->

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse first wave triage enrichment deferred refill starvation cycle budget` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found 0 open related PRs for the target files; last relevant changes are GH#33647 (65cb9ed1f9), GH#33737 (0da80cfd3b), GH#33560 (fd10ec90bd), GH#33743 (849e2c0af5)
- [x] File refs verified: 4 source files, 2 test files and 1 reference doc checked at origin/main db0e6141c9
- [x] Tier: `tier:standard` — dispatch-path scheduling with budget/fairness judgement; no security boundary change
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Found while maximising worker throughput for a managed private repo's enrichment backlog. The host ran 1-2 of 20 workers for hours while 44 issues were `status:available` + `auto-dispatch`.

## Problem

Pulse dispatch leaves most local worker capacity idle. On one runner over ~15 consecutive cycles (~7.5h, 2026-10-11), the host ran 1-2 of 20 workers while a managed private repo had 44 open `status:available` + `auto-dispatch` issues.

Two compounding causes, both observed in `~/.aidevops/logs/pulse.log` and `~/.aidevops/logs/pulse-stage-timings.log`:

1. **Timed-out sentinel-gated stages re-run at full timeout every cycle.**
   - `fix_the_fixer_detector` hits its 60s stage timeout (exit 124) every cycle. `_pulse_run_fix_the_fixer_detector_if_stale` only touches `~/.aidevops/cache/pulse-fix-the-fixer-last-run` *after* the helper returns ("Touch sentinel regardless of outcome (fail-open)"), but the stage wrapper kills the function first, so the sentinel never advances. Observed sentinel age: 4 days; 60s lost in every cycle.
   - `cache_prime` hits its 300s timeout (exit 124) every cycle since the last successful prime aged past `AIDEVOPS_PULSE_PRIME_MAX_AGE` (7200s). Only a successful prime (or a successful prefetch batch refresh) refreshes `pulse-cache-prime-last-run`, so a prime that cannot finish within the bound repeats for 300s every cycle (GH#33737 bounded the duration, not the repetition).
   - Together ~360s of a ~1800s cycle. Every cycle in the window then skipped `Post-label dispatch_max` with `remaining=0..599s, required=600s` (six cycles missed by 1-19s) and skipped the end-of-cycle `Dispatch_max`/cycle-final refill drain (`remaining<0`).

2. **The first dispatch wave stops at the first non-empty repository (GH#33647).** `build_ranked_dispatch_candidates_json` breaks after the first repository with any candidate and rotates `pulse-first-wave-cursor`. Recent first waves entered the loop with `effective_slots=17..20` but `candidates=1..3`. The rotation was even across 17 repositories (~16 first waves each), so the repository with the largest dispatchable backlog got ~7% of first waves. Because normal refills (full census) are budget-skipped every cycle, the first wave is effectively the only dispatch.

## Proposed fix

1. `fix_the_fixer_detector`: claim the cadence slot (touch the sentinel) **before** running the helper, preserving the documented fail-open intent under the stage timeout.
2. `cache_prime`: record a separate attempt marker (`pulse-cache-prime-last-attempt`) before invoking the prime; when the success sentinel exists but is stale, skip priming while the last attempt is younger than the max age. A *missing* success sentinel still primes unconditionally, preserving the incident runbook's "delete sentinel to force a prime" procedure. `prefetch_state` continues to refresh the same caches.
3. First wave: keep polling subsequent repositories (in cursor order) until the accumulated candidate count reaches the free-slot target, or a bounded first-wave enumeration budget (`PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S`, default 180s) elapses, or every repository has been polled. Always include at least the first non-empty repository (current behaviour), keep `product_discovery_complete=false`, and advance the cursor to the last polled repository so rotation continues. Normal (non-first-wave) enumeration is unchanged.

Functions: `_pulse_run_fix_the_fixer_detector_if_stale`, `_pulse_prime_caches_if_stale`, `build_ranked_dispatch_candidates_json`, and `_dispatch_enumerate_ranked_round` (supplies the free-slot target). The runbook gains a note about the attempt marker.

### Files Scope

- `.agents/scripts/pulse-wrapper-cycle-gates.sh`
- `.agents/scripts/pulse-wrapper-cycle.sh`
- `.agents/scripts/pulse-dispatch-engine.sh`
- `.agents/scripts/pulse-dispatch-lib-candidates.sh`
- `.agents/scripts/tests/test-pulse-dispatch-first-wave.sh`
- `.agents/scripts/tests/test-pulse-cache-prime.sh`
- `.agents/reference/incident-recovery-runbook.md`

## Reference pattern

- Sentinel/cadence gates: `_pulse_check_runaway_log` in `.agents/scripts/pulse-wrapper-cycle.sh`.
- First-wave scope and cursor: GH#33647 (`_dispatch_first_wave_advance_cursor`, `_dispatch_repository_rows`).
- Enumeration timing EWMA and admission: `_dispatch_enumeration_expected_seconds`, `_dispatch_record_enumeration_seconds`, `_dispatch_cycle_budget_admits_round` (GH#33560, GH#33737).

## Verification

- `bash .agents/scripts/tests/test-pulse-dispatch-first-wave.sh` passes, with assertions that a first wave whose first non-empty repository has fewer candidates than free slots continues to later repositories, stops at the target, honours the time budget, and still rotates/wraps the cursor.
- `bash .agents/scripts/tests/test-pulse-cache-prime.sh`, `bash .agents/scripts/tests/test-fix-the-fixer-observability.sh`, and the sibling pulse dispatch suites pass; ShellCheck is clean on changed scripts.
- Runtime: after deploy, `pulse-stage-timings.log` no longer shows `fix_the_fixer_detector ... 124` or `cache_prime ... 124` in consecutive cycles, and `pulse.log` first waves show `Dispatch_max: entering candidate loop ... candidates=N` with N at or above free slots when backlog exists.
