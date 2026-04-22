# t2744 — Raise GraphQL throttle defaults and reduce pulse/stats cycle pressure

## Session Origin

Interactive session investigation triggered by user noting frequent "GraphQL budget exhausted" events. Diagnosis confirmed: per-cycle GraphQL cost (400-700 pts × 30 cycles/hr × 14 repos) chronically exceeds the 5000/hr budget by 2-4×. Existing protections fire too late — circuit breaker at 5% remaining (250/5000), REST fallback at 10 remaining — both engage after 95-99% of budget is already spent.

## What

Tier-1 (config-only) optimisations to GraphQL budget protection, addressing items 1-4 from the broader investigation:

1. Raise pulse circuit breaker default from 5% (`0.05`) to 30% (`0.30`) so worker dispatch pauses with headroom in reserve, not after the budget is gone.
2. Raise REST fallback default threshold from `10` to `1000` so read-heavy operations route through the separate 5000/hr REST core pool while GraphQL still has reserve.
3. Increase stats-wrapper interval from `900s` (15 min) to `3600s` (1 hour). Health dashboard data is not realtime; an hourly refresh cuts ~80% of stats-driven GraphQL spend.
4. Increase pulse cycle interval default from `120s` (2 min) to `180s` (3 min). 33% fewer cycles. Bonus: macOS launchd path currently hardcodes `120` and ignores `supervisor.pulse_interval_seconds` from settings (Linux/cron path already respects it) — fix that gap so the setting is honoured uniformly.

All four are env-overridable / config-overridable. Users wanting prior behaviour can revert via env vars or `aidevops settings set`.

## Why

Direct evidence at investigation time:

- GraphQL = `0/5000` remaining; REST core = `4044/5000` remaining (split-pool headroom is plentiful but unused).
- 21 distinct `[circuit-breaker-rl] GraphQL budget EXHAUSTED` events in current pulse log.
- Sawtooth pattern in log: breaker recovers to `4980/5000` then burns back to `0` within minutes.
- Circuit breaker tripping at `remaining=235` means ~95% of budget was already spent by the time the breaker fired.
- Worker dispatches were failing at step 1 (`gh issue read`, `gh pr create`) with `RATE_LIMIT_EXHAUSTED` errors, wasting $0.05-$0.25 per doomed dispatch + watchdog kill.

The existing layered protections (t2574, t2689, t2690) are correctly designed but tuned for "GraphQL exhaustion is rare". Reality: under realistic load (10+ pulse-enabled repos), exhaustion is the steady state. Raising the trip thresholds turns these from "last-ditch reactive" into "proactive headroom preservation", which is what the user actually wants from a circuit breaker.

## How

### Files to modify

- EDIT: `.agents/scripts/pulse-rate-limit-circuit-breaker.sh:87` — default `0.05` → `0.30`. Update header comment block (lines 24-28) accordingly.
- EDIT: `.agents/scripts/shared-gh-wrappers-rest-fallback.sh:34` — default `10` → `1000`. Update header comment.
- EDIT: `setup-modules/schedulers.sh:271` — `_read_pulse_interval_seconds` fallback `120` → `180`.
- EDIT: `setup-modules/schedulers.sh:535` — `_generate_pulse_plist_content` hardcoded `<integer>120</integer>` replaced with the value returned by `_read_pulse_interval_seconds` (so macOS plist respects settings.json the way Linux already does).
- EDIT: `setup-modules/schedulers.sh:587` — update "every 2 min" log message to be dynamic / accurate.
- EDIT: `setup-modules/schedulers.sh:977,998,1006-1011` — stats-wrapper `StartInterval` `900` → `3600`; cron schedule `*/15` → `0`; "every 15 min" message → "every hour".
- EDIT: `.agents/scripts/settings-helper.sh:65` — default seed value `120` → `180`.
- EDIT: `.agents/AGENTS.md:274` — update the t2690 doc line ("< 5% (250/5000)") to reflect the new default.
- EDIT: `.agents/reference/settings.md:34` — update the default column for `supervisor.pulse_interval_seconds`.
- EDIT: `.agents/reference/configuration.md:108,417` — update "every 2 minutes" prose and table default.
- EDIT: `.agents/reference/worker-diagnostics.md:17` — "Pulse cycle (every 2 min)" → "Pulse cycle (every 3 min, configurable)".
- EDIT: `.agents/reference/planning-detail.md:25` — "Phase 0 picks these up every 2 minutes" → "every 3 minutes" or remove the time stamp (it's now a soft default).

### Reference patterns

- Model the macOS launchd interval wiring on the existing Linux path at `setup-modules/schedulers.sh:336-337` (`_pulse_interval_sec=$(_read_pulse_interval_seconds)`). The plist generator function takes the value as an argument and substitutes it into the heredoc the same way `${pulse_label}` is substituted today.

### Files Scope

- `.agents/scripts/pulse-rate-limit-circuit-breaker.sh`
- `.agents/scripts/shared-gh-wrappers-rest-fallback.sh`
- `.agents/scripts/settings-helper.sh`
- `setup-modules/schedulers.sh`
- `.agents/AGENTS.md`
- `.agents/reference/settings.md`
- `.agents/reference/configuration.md`
- `.agents/reference/worker-diagnostics.md`
- `.agents/reference/planning-detail.md`
- `todo/tasks/t2744-brief.md`
- `TODO.md`

### Verification

```bash
# 1. Lint the changed shell files
shellcheck .agents/scripts/pulse-rate-limit-circuit-breaker.sh \
           .agents/scripts/shared-gh-wrappers-rest-fallback.sh \
           .agents/scripts/settings-helper.sh \
           setup-modules/schedulers.sh

# 2. Confirm circuit breaker still trips correctly with new default (no env override)
unset AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD
.agents/scripts/pulse-rate-limit-circuit-breaker.sh status
# Expect: status line showing threshold=1500 (30% of 5000)

# 3. Run the existing circuit-breaker tests — they pass explicit thresholds
.agents/scripts/tests/test-rate-limit-circuit-breaker.sh

# 4. Run the REST fallback tests
.agents/scripts/tests/test-gh-wrapper-rest-fallback.sh
.agents/scripts/tests/test-gh-issue-read-rest-fallback.sh

# 5. Confirm settings validation still accepts 180 in the existing range [30,3600]
.agents/scripts/settings-helper.sh validate

# 6. Smoke-test setup.sh dry-run (don't actually reload launchd)
bash -n setup-modules/schedulers.sh
```

## Acceptance criteria

- [ ] `pulse-rate-limit-circuit-breaker.sh` default threshold is `0.30`; header comment reflects "30% = 1500/5000".
- [ ] `shared-gh-wrappers-rest-fallback.sh` default threshold is `1000`; header comment reflects the new behaviour ("REST takes over while GraphQL has 20% reserve").
- [ ] `_read_pulse_interval_seconds` fallback returns `180` when settings.json is absent or the key is missing.
- [ ] macOS plist generator substitutes the value from `_read_pulse_interval_seconds` instead of hardcoding `120`.
- [ ] Stats wrapper plist `StartInterval` is `3600`; Linux cron schedule is `0 * * * *` (or `@hourly`).
- [ ] All four tests above pass on the worktree.
- [ ] Doc references in `.agents/AGENTS.md`, `.agents/reference/{settings,configuration,worker-diagnostics,planning-detail}.md` reflect the new defaults.

## Tier checklist (tier:standard)

- [x] >2 files (10+ files) → not tier:simple
- [x] Some files >500 lines (`schedulers.sh` is 2032 lines) → not tier:simple
- [x] Coordinated edits across config defaults + plist generator + docs → standard tier appropriate
- [x] Estimate: 1-2h interactive
- [x] No novel architecture, no security audit needed → not tier:thinking

## Notes

- This is the first phase of broader GraphQL optimisation work. Tiers 2 and 3 (consolidating repeated `gh issue list` calls in `pulse-issue-reconcile.sh` / `pulse-triage.sh`, ETag/conditional requests, multi-token rotation) are separate follow-up tasks.
- `origin:interactive` — implementing in current session.

<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.8.94 plugin for [OpenCode](https://opencode.ai) v1.14.20 with claude-opus-4-7 spent 46m and 33,397 tokens on this with the user in an interactive session.
