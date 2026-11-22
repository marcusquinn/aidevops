## Origin

Interactive productivity mission (pulse/worker throughput mining). Of 75 `runner_capability_unmet` deferrals in the current `~/.aidevops/logs/pulse.log` window, 41 (55%) are `signal=check_timeout cooldown=none`, all on beta-QA-gated award-enrichment candidates in a managed private repo. They arrive in bursts (8 within ~120 log lines; 14 within ~1300 lines) while parallel dispatch is running.

## What

Cache a successful `aidevops secret check NAME` result per pulse cycle, names and timestamps only, for a bounded TTL inside the existing runner-capability cycle state. Parallel and repeated candidates that need the same secret names then run one decrypt per name per TTL instead of one per candidate per gate.

## Why

- `.agents/scripts/runner-capability-helper.sh` (`_runner_capability_python_requirements`, the `with cycle_state(cycle)` block near the end) checks every required secret with a fresh `aidevops secret check` while holding the exclusive per-cycle `flock`. The cycle state caches only `secret_unreadable` (locked store); success is never cached.
- Every candidate is checked twice (early admission and final pre-claim gate, GH#33399). The log window contains 4708 `runner_capability_check source=fresh` lines and 0 cached ones. Award candidates each declare the same 5 beta secrets.
- `cmd_check` in `.agents/scripts/secret-helper.sh` runs `gopass ls --flat` and then a full `gopass show -n` decrypt per name. Normal latency is 0.3–0.7 s (GH#38172 evidence; 0.71 s observed on this host), but under gpg-agent contention from parallel candidates plus live workers decrypting the same names, single checks exceed the 12 s inner / 15 s outer bound and defer the candidate (`check_timeout`, retried next cycle; no cooldown).
- Each deferral wastes a dispatch slot and lengthens candidate stages (observed 120–260 s `dispatch_candidate_*` stages).

## Tier

`tier:standard` — one embedded-Python change plus a doc paragraph. It must preserve the locked-store and timeout semantics.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/runner-capability-helper.sh` — `_runner_capability_python_cycle` (add readable-cache helpers) and the secret loop in `_runner_capability_python_requirements`.
- EDIT: `.agents/reference/secret-handling.md` — "Headless runner GPG availability" paragraph (around lines 201–211) documents the new cache and env var.

### Implementation Steps

1. Add `AIDEVOPS_RUNNER_CAPABILITY_READABLE_TTL_SECONDS` (default 300, clamped 0–1800, invalid → default; 0 disables).
2. Under the existing lock, skip `run_check` for a name whose `state['readable'][name]` timestamp is within TTL. After a successful check, record `time.time()` for that name and persist the state. Store only names and timestamps, never values.
3. Keep invalidation semantics: `unreadable()` rewrites the state without `readable` (a locked store invalidates all cached readability); timeouts and missing results are never cached; `check_rejections` still runs first on every call; no cycle ID (empty `_PULSE_CYCLE_ID` or non-`fresh` source) means no caching.
4. Do not reuse cached requirements/metadata (GH#33399): only per-name readability is cached; the requirement set stays freshly derived.

### Files Scope

- `.agents/scripts/runner-capability-helper.sh`
- `.agents/reference/secret-handling.md`

## Acceptance Criteria

- `bash .agents/scripts/tests/test-runner-capability.sh` passes unchanged (locked-store, expiry and timeout contracts intact).
- Two fresh checks in the same cycle for an issue requiring `GOOD` invoke the secret check once. A different cycle, TTL expiry, or TTL 0 re-checks.
- A cycle with a cached `GOOD` followed by an unreadable result clears the readable cache.
- ShellCheck clean; the cycle-state file contains no secret values.
- Post-deploy: `rg -c "signal=check_timeout" ~/.aidevops/logs/pulse.log` growth rate falls relative to `runner_capability_check source=fresh` lines.

## Relevant Files

- `.agents/scripts/runner-capability-helper.sh:177-239` — `cycle_state`, `unreadable`, `check_cached_unreadable`
- `.agents/scripts/runner-capability-helper.sh:481-500` — secret timeout and check loop
- `.agents/scripts/secret-helper.sh:887-908` — `cmd_check` (status-only; decrypts)
- `.agents/scripts/tests/test-runner-capability.sh:433-491` — existing cycle-cache contract tests
- `.agents/reference/secret-handling.md:186-211` — documented capability timeout/cache behaviour
