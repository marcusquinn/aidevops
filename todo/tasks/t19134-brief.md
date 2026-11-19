<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `gh shim fork overhead gh-api-instrument _gh_append_v2 command substitution performance` → 0 hits.
- [x] Discovery pass: prework-discovery found no open PRs or claimed issues on the target files; precedent #38896/#39002 (git-shim per-call cost) and #33062 (gh-shim REST overhead).
- [x] File refs verified: all target paths exist at `HEAD`.
- [x] Tier: `tier:standard` — mechanical, behaviour-preserving fork removal in hot-path shell helpers; existing focused tests cover record format.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (productivity mission: pulse/worker throughput)
- **Conversation context:** Host-load investigation of slow dispatch ceremonies (mean 231 s per launch). The runner averaged load 36–74 on 16 CPUs for five days, ~1,178 process spawns/s, with ~half of busy CPU in short-lived processes. Every `gh` call goes through the aidevops shim.

## What

Cut per-invocation bash forks in the `gh` shim hot path without changing any record, verdict or output:

1. `gh-api-instrument.sh`: `_gh_append_v2`, `gh_record_call`, `gh_record_attempt` and `gh_new_logical_id` sanitise each field through `$(...)` (one subshell fork per field, ~20 per record, two records per call). Assign through fork-free helpers (`printf -v`) instead. `_gh_now_ms` spawns perl twice per call; use bash `EPOCHREALTIME` when available, falling back to the current perl/python/seconds chain.
2. `gh-native-transport-lib.sh`: `_shim_canonical_path` runs `$(dirname)`/`$(basename)` per PATH candidate; use parameter expansion while keeping the `cd -P` physical resolution.
3. `shared-gh-secondary-cooldown.sh`: `_gh_secondary_cooldown_now` (`date`), `_gh_secondary_system_boot_ts` (`sysctl | sed | sed`) and file-path getters fork per call; use builtins (`printf '%(%s)T'`, bash regex) with the existing fallbacks.

## Why

Measured on the production runner (2026-11-19, 16 CPUs): one REST read costs 0.66 s wall / 58 ms CPU via native `gh` but 1.24 s wall / 391 ms CPU through the shim; an xtrace shows 102 bash forks per call, 39 of them in `_gh_append_v2`. The runner makes ~12,000 logical `gh` calls/hour (~3.4/s), so shim overhead alone is ~1.1 cores and ~0.6 s added latency per call on the dispatch critical path. Fewer forks lower host load (which inflates every Pulse stage) and shorten each ceremony gate.

## Tier

`tier:standard`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/gh-api-instrument.sh` — fork-free field sanitisation and ms clock.
- EDIT: `.agents/scripts/gh-native-transport-lib.sh` — `_shim_canonical_path` builtins.
- EDIT: `.agents/scripts/shared-gh-secondary-cooldown.sh` — builtin clock/boot-time/path getters.
- EDIT: `.agents/scripts/gh` — shim startup path resolution without `dirname`/`basename` execs (added during implementation: 3 forks per call).
- EDIT: `.agents/scripts/gh-transport-controls.sh` — REST timing via `_gh_now_ms_into`; skip `cat` of an empty error file (added during implementation).

### Implementation Steps

1. Add `_gh_safe_text_into <var> <value> <fallback>` / `_gh_safe_number_into <var> <value>` (assign via `printf -v`), keep the stdout helpers for existing callers, and switch `_gh_append_v2` to them. Same for caller resolution and default pool/auth.
2. `_gh_now_ms`: if `EPOCHREALTIME` is set, derive ms with pure arithmetic; otherwise keep the current chain.
3. `_shim_canonical_path`: replace `dirname`/`basename` execs with parameter expansion (same `.`/`/` edge semantics).
4. Secondary cooldown: builtin `now`, regex-parsed boot time, direct variable reads.

### Hazards and Compatibility

Bash 3.2 must keep working (`printf -v` is 3.1+; `%(...)T` and `EPOCHREALTIME` need runtime guards with existing fallbacks). Log record bytes must stay identical (tests in `.agents/scripts/tests/test-gh-api-instrument.sh`).

### Files Scope

- `.agents/scripts/gh-api-instrument.sh`
- `.agents/scripts/gh-native-transport-lib.sh`
- `.agents/scripts/shared-gh-secondary-cooldown.sh`
- `.agents/scripts/gh`
- `.agents/scripts/gh-transport-controls.sh`

## Acceptance Criteria

- [ ] An xtrace fork count of one shim REST read (`PS4='+${BASHPID} ' bash -x .agents/scripts/gh api repos/<owner>/<repo>/issues/<n> --jq .state`) drops from 102 to at most 60 distinct bash PIDs.
- [ ] Existing focused tests pass unchanged: `test-gh-api-instrument.sh`, the gh shim tests, and the secondary-cooldown tests; ShellCheck is clean on the three files.
- [ ] Negative/regression: log records (field order, sanitisation, enum allowlists) are unchanged, and Bash 3.2 (`/bin/bash`) still sources and runs the helpers.

## Relevant Files

- `.agents/scripts/gh` — shim entry point.
- `.agents/scripts/tests/test-gh-api-instrument.sh` — record-format tests.
