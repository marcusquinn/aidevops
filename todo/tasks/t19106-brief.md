## What

This follows up GH#39008 (PR #39009, merged as 7369e72f7a). `_pulse_blocker_recovery_due` in `.agents/scripts/pulse-dispatch-engine-supervisor.sh` re-probes early after a zero-count `pending --count` exit 2. Two cases are wrong:

1. **API pressure after scheduling.** `_pulse_blocker_partial_reprobe` checks `_pulse_blocker_api_pressure_active` only when it writes the deadline. If the GraphQL circuit breaker or secondary cooldown starts later, reaching the deadline still runs `pending --count` before the normal interval. The early path should check pressure again and, while pressure is active, leave the deadline file in place.
2. **Partial discovery with a fully read queue.** `pending --count` also exits 2 with count 0 when the queue pass finished and only a discovery stage (`seed`, `holds`, `unclassified`) was incomplete. GH#35945 notes the seed rarely finishes in one call, so after deploy almost every zero-count probe would re-probe every 600s, not every 3h. A persistent seed failure would repeat the same probe each time. GH#39008's premise is unread *queue* work, so only queue-side incompleteness should schedule the early probe.

Source: CodeRabbit review on PR #39011, threads on `pulse-dispatch-engine-supervisor.sh` lines 189 and 206.

## How

- EDIT `.agents/scripts/pulse-dispatch-engine-supervisor.sh`:
  - `_pulse_blocker_recovery_due`, early path (the `partial_due` branch): after the deadline test passes, `! _pulse_blocker_api_pressure_active || return 1`. Do not remove the deadline file.
  - Capture the probe's stderr to a fixed diagnostics file, `${PULSE_DIR}/last_blocker_recovery_probe.err`, overwritten each probe (it was `2>/dev/null`). Call `_pulse_blocker_partial_reprobe` only when that file contains `incomplete stage=(queue|identity|entry)`. These are the helper's own markers from `_tbr_run_stage` and `_tbr_pending_scan_tier` in `.agents/scripts/terminal-blocker-recovery-helper.sh`. An unwritable file means no early probe, which is the safe default.
  - Leave the positive-count trigger and the exit-code contract of `terminal-blocker-recovery-helper.sh` unchanged.

### Files Scope

- .agents/scripts/pulse-dispatch-engine-supervisor.sh
- todo/tasks/t19106-brief.md
- TODO.md

## Acceptance Criteria

- [ ] When a partial deadline is reached while API pressure is active, there is no probe, and the deadline file still exists afterwards.
- [ ] A zero-count exit-2 probe whose stderr shows only `stage=seed|holds|unclassified` incompleteness writes no partial deadline.
- [ ] A zero-count exit-2 probe that shows `stage=queue`, `stage=identity` or `stage=entry` incompleteness still writes the deadline (GH#39008 behaviour).
- [ ] `bash .agents/scripts/tests/test-pulse-supervisor-starvation-escape.sh` passes, and ShellCheck is clean.

## Verification

- `shellcheck .agents/scripts/pulse-dispatch-engine-supervisor.sh`
- `bash .agents/scripts/tests/test-pulse-supervisor-starvation-escape.sh`
- Ad hoc: run the real `_pulse_blocker_recovery_due` with a stub helper that prints `0`, exits 2, and writes chosen `incomplete stage=` lines to stderr, plus a stub `_pulse_blocker_api_pressure_active`.
- After deploy: `~/.aidevops/logs/pulse.log` shows "re-probe in" only after queue-partial probes, and `last_blocker_recovery_probe.err` holds the last probe's stage markers.
