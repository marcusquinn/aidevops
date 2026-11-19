<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `kern.boottime usec boot ramp macOS` → 0 relevant hits.
- [x] Discovery pass: no open issue/PR covers the macOS boot-time parse (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:simple` — replace one sed pipeline with the already-reviewed builtin parse.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (found while implementing GH#39187)
- **Conversation context:** `sysctl -n kern.boottime` prints `{ sec = 1794166500, usec = 274703 } <date>`. The greedy sed `.*sec = ([0-9]+).*` matches the *last* `sec = `, which is inside `usec`, so it returns the microseconds (274703) instead of the boot epoch. GH#39187 fixes this in `_gh_secondary_system_boot_ts`; the Pulse dispatch fallback still has the same pipeline.

## What

Make `_dispatch_ramp_system_boot_ts` in `.agents/scripts/pulse-dispatch-lib-capacity.sh` return the real boot epoch on macOS when `_gh_secondary_system_boot_ts` is not loaded, so the dispatch boot ramp (default 180 s via `AIDEVOPS_PULSE_DISPATCH_RAMP_BOOT_SECS`) actually applies after a reboot.

## Why

With the boot epoch parsed as ~274703, `now - boot` is always huge, so the post-boot dispatch stagger never engages on macOS when the fallback path runs. After a reboot, Pulse can launch a full dispatch wave into a cold host and cold GitHub caches, which is the burst the ramp exists to prevent.

## Tier

`tier:simple`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-dispatch-lib-capacity.sh:1529-1560` — `_dispatch_ramp_system_boot_ts` fallback branch.

### Implementation Steps

1. Replace the `sysctl | sed | sed` pipeline (around line 1550) with the builtin parse that GH#39187 introduced in `.agents/scripts/shared-gh-secondary-cooldown.sh` `_gh_secondary_system_boot_ts`: capture `sysctl -n kern.boottime` once, then match `^\{[[:space:]]*sec[[:space:]]*=[[:space:]]*([0-9]+)`.
2. Optionally use the same `while read` loop for the `/proc/stat` `btime` branch (line ~1543) to drop the sed execs there too.

### Files Scope

- `.agents/scripts/pulse-dispatch-lib-capacity.sh`

## Acceptance Criteria

- [ ] On macOS, with `_gh_secondary_system_boot_ts` undefined, `_dispatch_ramp_system_boot_ts ""` equals `sysctl -n kern.boottime | perl -ne 'print $1 if /sec = (\d+),/'`.
- [ ] Existing dispatch ramp tests pass (`.agents/scripts/tests/test-pulse-dispatch-staggering.sh`).
- [ ] ShellCheck clean; Bash 3.2 (`/bin/bash`) parses the file.
