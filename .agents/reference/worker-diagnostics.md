<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worker Diagnostics and Architecture

<!-- AI-CONTEXT-START -->

Reference for diagnosing headless worker failures. Workers are OpenCode instances dispatched by the pulse to solve GitHub issues autonomously.

**Scripts**: `headless-runtime-helper.sh` (worker lifecycle), `pulse-wrapper.sh` (dispatch), `dispatch-dedup-helper.sh` (dedup), `dispatch-claim-helper.sh` (claims).

<!-- AI-CONTEXT-END -->

## Worker Lifecycle

```text
Pulse cycle (every 3 min, configurable)
  → Version guard (enforce OPENCODE_PINNED_VERSION)
  → Canary smoke test (cached 30 min)
  → dispatch_with_dedup (claim + dedup check)
  → nohup worker launch (survives pulse-wrapper exit)
    → DB isolation (XDG_DATA_HOME per worker)
    → Activity watchdog (standalone process, monitors output growth)
    → OpenCode run (headless, direct to Anthropic API via OAuth)
    → On completion: merge worker DB back to shared DB, cleanup
    → On failure: CLAIM_RELEASED posted, issue available for re-dispatch
```

## Architecture Decisions

### SQLite DB Isolation (v3.6.130)

**Problem**: All headless workers shared `~/.local/share/opencode/opencode.db` with `busy_timeout=0`. Concurrent writes caused `SQLITE_BUSY` which silently broke OpenCode's streaming connection handler. Workers stalled at `step_start` with zero API errors logged.

**Why it was hard to find**: Interactive sessions (single instance) never hit contention. Version bisecting was misleading — fewer workers = less contention = fewer failures, creating a false correlation with OpenCode versions.

**Fix**: Each worker gets its own DB via `XDG_DATA_HOME=/tmp/aidevops-worker-auth.XXXXXX`. After completion, `_merge_worker_db()` copies session/message rows back to the shared DB using `ATTACH DATABASE` + `INSERT OR IGNORE` with a 5s timeout.

**Diagnostic**: If workers stall at `step_start` with no API errors, check:

```bash
# Are isolated dirs being created?
ls -d /tmp/aidevops-worker-auth.* 2>/dev/null || ls -d "$TMPDIR"/aidevops-worker-auth.* 2>/dev/null
# Is OPENCODE_DB still set? (it should NOT be)
grep 'OPENCODE_DB' ~/.aidevops/agents/scripts/headless-runtime-helper.sh
```

### Activity Watchdog (v3.6.126, fixed v3.6.140)

**Problem**: The original watchdog was a bash function backgrounded with `&` inside the worker's subshell. When `nohup` launched the worker (to survive pulse-wrapper exit), the backgrounded function died with its parent context. Stalled workers sat indefinitely with no kill mechanism.

**Fix**: Watchdog launched as a standalone process that outlives the worker subshell.

**Diagnostic**: If workers stall past the 300s timeout:

```bash
# Are watchdog processes alive?
ps aux | grep 'worker-activity-watchdog\|activity_watchdog' | grep -v grep
# Check worker log for WATCHDOG_KILL marker
grep WATCHDOG_KILL /tmp/pulse-*-<issue>.log
# Check for CLAIM_RELEASED on the issue
gh api repos/<slug>/issues/<num>/comments --jq '.[] | select(.body | test("CLAIM_RELEASED")) | .created_at'
```

### Canary Smoke Test (v3.6.123)

**Rules**:
1. Must use a **verified-working** model name (currently `anthropic/claude-sonnet-4-20250514`)
2. Must run **before** any side effects (claims, locks, ledger updates) — a failed canary must not block re-dispatch
3. Cached for 30 min (`~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass`)
4. Version guard runs on every dispatch (not cached)

**Diagnostic**: If no workers dispatch at all:

```bash
# Check canary cache
cat ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass
# Clear cache to force re-test
rm -f ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass
# Test canary manually
opencode run "Reply with exactly: CANARY_OK" -m anthropic/claude-sonnet-4-20250514 --dir "$HOME"
```

### Version Guard

**Problem**: Something outside aidevops periodically upgrades OpenCode to latest. The version guard in `headless-runtime-helper.sh` runs on every dispatch and reinstalls `OPENCODE_PINNED_VERSION` from `shared-constants.sh` if drift is detected.

**When to pin**: Set `OPENCODE_PINNED_VERSION` in `.agents/scripts/shared-constants.sh` to a specific version when a known-broken release exists. Set to `"latest"` when no pin is needed.

## `launch_recovery:no_worker_process` Failure Mode (t2804)

**Signature**: Worker process never appears within the grace period after dispatch. The pulse posts `CLAIM_RELEASED reason=launch_recovery:no_worker_process` on the issue and returns the issue to `status:available`. No worker log at `/tmp/pulse-*-<issue>.log`.

**Log message**:
```
[pulse-wrapper] Launch validation failed for issue #N (slug) — no active worker process within Xs
```

**GitHub audit trail**:
```
CLAIM_RELEASED reason=launch_recovery:no_worker_process runner=<login> ts=<ISO>
```

**Observed pattern (2026-04-20 to 2026-04-24 data, t2812)**:
- Occurs in **time-correlated clusters**, not random transients. A single runner experiences 30+ failures across many issues within a 2–4 hour window, then recovers.
- **Self-heals**: the underlying infrastructure issue (canary auth expiry, session lock collision) typically clears within minutes. The issue retries at the same tier — cascade tier escalation is NOT used for `no_worker_process` failures (t2815). 63/65 affected issues in the observed window resolved within the same day.
- **Runner-specific**: 82% of events attributed to one runner (`alex-solovyev`), 17% to the other (`marcusquinn`). Likely reflects resource constraints on the failing runner at time of cluster.
- **Cross-repo**: affects all pulse-enabled repos simultaneously (observed in `marcusquinn/aidevops` ~112 events, `awardsapp/awardsapp` ~130 events in 5-day window).

**Mitigation already in place**:
- After 3 consecutive `no_worker_process` failures in a round, the canary cache is invalidated — next dispatch re-runs the canary to detect broken runtimes.
- `no_worker_process` failures are classified as `crash_type=no_work` (t2815) — cascade tier escalation is **skipped** (t2387). The issue retries at the same tier so the next attempt runs cheaply once the infrastructure issue clears.
- After `NO_WORK_NMR_THRESHOLD` (default 3) consecutive infra failures per issue, the per-issue no_work circuit breaker (t2769) applies `needs-maintainer-review` with a `cost-circuit-breaker:no_work_loop` marker.
- `fast_fail_record` increments the per-issue failure counter for backoff.

**Diagnostic**:

```bash
# Check if this is happening right now
grep "no active worker process" ~/.aidevops/logs/pulse-wrapper.log | tail -20

# Count failures in last hour
grep "$(date -u +%Y-%m-%dT%H)" ~/.aidevops/logs/pulse-wrapper.log | grep -c "no active worker process" || true

# Check canary cache freshness (stale cache may mask broken runtime)
cat ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass

# Is the CLI itself broken? Test outside of pulse:
opencode run "Reply with exactly: CANARY_OK" -m anthropic/claude-sonnet-4-20250514 --dir "$HOME"

# Check system load at failure time
uptime
```

**When to escalate to Phase 2 analysis**: If clusters recur with the same runner >3 times per day, or if the cascade escalation to `tier:thinking` fails to resolve the issue, investigate runtime-level causes (resource exhaustion, auth token expiry, network drop) on the failing runner.

### Root Cause Analysis (Phase 2 — t2813)

**Root cause class**: Worker process exits before `check_worker_launch` observes it. Not a
single bug but a **class of early-exit paths** in the worker startup sequence, combined with
a **diagnostic gap** that prevents the pulse from determining WHY the worker exited.

#### Dispatch → spawn → detection chain

The chain has three stages with a critical timing dependency between them:

1. **Dispatch stage** (pulse-dispatch-engine.sh:519–522 subshell):
   - `dispatch_with_dedup` → 9-layer dedup check → `_dispatch_launch_worker`
   - `_dlw_exec_detached` (pulse-dispatch-worker-launch.sh:395–418): launches worker via
     `setsid nohup env ... headless-runtime-helper.sh run ... &` — returns immediately with `$!` PID.
   - `_dlw_post_launch_hooks` (pulse-dispatch-worker-launch.sh:535–580): **sleeps 8 seconds**
     (stagger delay), posts dispatch comment. Total subshell time: ~15–20s.

2. **Worker startup** (headless-runtime-helper.sh `cmd_run`, runs in parallel after nohup):
   - Arg parsing, `choose_model` (~instant)
   - `_enforce_opencode_version_pin` (headless-runtime-lib.sh:808–831, ~1–2s)
   - `_run_canary_test` (headless-runtime-lib.sh:833–951): instant if cached, up to 60s if
     running fresh. **If canary fails → process exits immediately** (return 1 at line 950).
   - `_acquire_session_lock` (headless-runtime-lib.sh:733–767): **if lock collision → exit 0**
     (returns 2, which `cmd_run` treats as clean exit at line 1447–1448).
   - `_execute_run_attempt` → `_invoke_opencode` → actual OpenCode binary.

3. **Detection stage** (pulse-dispatch-engine.sh:534):
   - `check_worker_launch` polls `has_worker_for_repo_issue` every 2s for up to 35s
     (`PULSE_LAUNCH_GRACE_SECONDS`).
   - `has_worker_for_repo_issue` (pulse-dispatch-core.sh:113–165) → `list_active_worker_processes`
     (worker-lifecycle-common.sh:730–747) → `ps axwwo pid,stat,etime,command | awk -f
     list_active_workers.awk`.
   - Awk matches: `headless-runtime-helper.sh` + `run` + `--role worker` + `/full-loop`.

#### Why workers disappear before detection

The 8-second stagger delay inside the dispatch subshell (step 1) means `check_worker_launch`
starts polling ~15–20 seconds after the worker was nohup'd. If the worker exits within those
first 15–20 seconds (e.g., canary failure at 8s, model selection failure at 1s), the process
is already dead by the time the first poll runs. All 17 subsequent polls (every 2s for 35s)
find nothing → `no_worker_process`.

#### Identified early-exit paths (ranked by likelihood)

**Path 1 — Canary test failure (PRIMARY)**: `headless-runtime-lib.sh:833–951`
- When the canary test runs a fresh OpenCode invocation (not cached), and the API call
  fails (auth token expired, rate limit, provider outage), the canary returns 1.
  `cmd_run` (headless-runtime-helper.sh:1432–1434) exits immediately.
- **Why it matches Phase 1 clusters**: Each runner has its own auth tokens (isolated via
  `XDG_DATA_HOME`). Auth token expiry affects one runner at a time. The canary cache
  (30-min TTL) means: a passed canary protects subsequent dispatches, but a failed canary
  has **no negative cache** — each dispatch attempt re-runs it.
- **Why cascade escalation "works"**: The escalation delay (~5–10 min) allows time for
  tokens to refresh. Different tier → different model → potentially different API
  key/provider. The delay alone is often sufficient for recovery.

**Path 2 — Model selection failure**: `headless-runtime-helper.sh:1418–1422`
- `choose_model` returns non-zero → `cmd_run` calls `_cmd_run_finish` and exits.
  Caused by: all providers in backoff, model routing table empty, config corruption.

**Path 3 — Session lock collision**: `headless-runtime-lib.sh:742–757`
- If a previous dispatch's lock file exists with a PID that `_is_process_alive_and_matches`
  considers alive (PID reuse on macOS — mitigated by t2421 argv hash, but not eliminated),
  the worker exits cleanly (exit 0, invisible to fast-fail counters).

**Path 4 — File descriptor exhaustion (SUSPECTED but unconfirmed)**:
- `_dlw_exec_detached` (pulse-dispatch-worker-launch.sh:402) launches the worker via
  `setsid nohup ... &`. The `setsid` creates a new session but does NOT close inherited
  file descriptors. If the pulse process has accumulated many open FDs (from GitHub API
  calls, log files, temp files), the worker inherits them and may hit `EMFILE` when
  trying to open new connections.
- This would explain runner-specific clusters (FD accumulation depends on runner's pulse
  uptime and workload) and self-healing (pulse restart resets FDs).
- **Cannot confirm without data**: FD counts were not logged during the observed clusters.

#### Investigation candidates assessment

**(a) Worker launch script exits 0 without spawning — CONFIRMED (Path 3)**

`headless-runtime-helper.sh` CAN exit 0 without spawning a worker when
`_acquire_session_lock` detects a lock collision (headless-runtime-lib.sh:753, return 1
→ `cmd_run:1447` `prepare_exit=2` → `return 0`). The nohup wrapper `_dlw_exec_detached`
always returns 0 (line 417), so `dispatch_with_dedup` returns 0 regardless of what happens
inside the worker process — the "dispatch succeeded" signal is emitted before the worker
has finished starting.

**(b) Spawn races with dedup guard — RULED OUT by design**

The 7-layer dedup chain (`check_dispatch_dedup`, pulse-dispatch-core.sh:172–188) and the
per-session-key lock file (`_acquire_session_lock`, headless-runtime-lib.sh:733) together
prevent duplicate spawns. No code path was found that bypasses both layers. The session
lock is acquired inside the worker process (not the dispatcher), which means a race between
two workers for the same session key would be caught by the lock.

**(c) Canary check passes but exec into runtime silently fails — PARTIALLY CONFIRMED**

The canary test uses a SEPARATE OpenCode invocation with its own isolated DB dir
(headless-runtime-lib.sh:884–891). The worker process uses a DIFFERENT isolated DB dir
(headless-runtime-helper.sh:421). Both copy the same `auth.json`, but the canary validates
model connectivity only — it does not test the full worker exec chain (sandbox, worktree,
plugin loading). A canary pass does not guarantee the worker's OpenCode will succeed.
However, the more impactful failure mode is the canary FAILING (Path 1), not passing-then-failing.

**(d) Cascade escalation on missing worker — FIXED by t2815**

`recover_failed_launch_state` (pulse-cleanup.sh) now maps `no_worker_process` to
`crash_type=no_work` before calling `fast_fail_record`. This routes through the t2387
infra-failure guard in `escalate_issue_tier`, which skips tier escalation and keeps
the issue at its current tier. Same-tier retry applies; after `NO_WORK_NMR_THRESHOLD`
(default 3) consecutive failures the t2769 no_work circuit breaker applies
`needs-maintainer-review`. The cascade no longer fires on infrastructure failures where
the worker never spawned.

#### Diagnostic gap (the core infrastructure finding)

The pulse has no visibility into WHY a worker exited early. The gaps:

1. **Worker log exists but is not read during recovery**: `_dlw_setup_worker_log` creates
   `/tmp/pulse-${safe_slug}-${issue_number}.log`. The nohup'd process writes to this log
   (stdout/stderr). But `recover_failed_launch_state` (pulse-cleanup.sh:728) never reads
   it — the exit reason is lost.

2. **Canary output is discarded**: The canary test writes diagnostics to a temp file
   (headless-runtime-lib.sh:850) and logs the last 20 lines to stderr (line 948). This
   output goes to the worker log (via nohup stderr redirection), but again, nobody reads
   the worker log during recovery.

3. **`check_worker_launch` discards its own output**: Line 534 in pulse-dispatch-engine.sh:
   `check_worker_launch "$issue_number" "$repo_slug" >/dev/null 2>&1`. The launch check's
   diagnostic messages (including the specific failure reason) are thrown away.

4. **No spawn-time exit code capture**: `_dlw_exec_detached` captures `$!` (nohup PID) but
   never waits for it or checks its exit code. The dispatch subshell exits before the worker
   does. When the worker dies, its exit code is reaped by init (PID 1) and lost.

#### Recommended Phase 3 fix targets

1. **Read worker log tail during recovery**: In `recover_failed_launch_state`
   (pulse-cleanup.sh), after confirming the worker is gone, read the last 20 lines of the
   worker log and include them in the `CLAIM_RELEASED` comment and `$LOGFILE` entry. This
   turns every `no_worker_process` event into a diagnosed failure.

2. **Add spawn-time exit monitoring**: After `_dlw_exec_detached` returns, start a
   lightweight background monitor that waits for the nohup'd PID (or its child, since
   `setsid` may fork) and logs the exit code. This captures fast failures synchronously.

3. **Close inherited FDs before exec**: In `_dlw_exec_detached`, close FDs >2 before
   the `setsid nohup` invocation to prevent FD leak from the pulse into workers:
   `for fd in /proc/self/fd/*; do fd_num=${fd##*/}; [[ $fd_num -gt 2 ]] && exec {fd_num}>&-; done`

4. **Negative canary cache with short TTL**: When the canary fails, cache the failure for
   60–120 seconds. This prevents N consecutive dispatch attempts from each spending up to
   60 seconds on canary runs that will all fail for the same reason. The batch throttle
   (pulse-dispatch-engine.sh:559) partially addresses this but only after 80% failure ratio.

### Phase 3 — Fixes Landed (t2814)

All four Phase 2 recommended fixes are deployed. Regression coverage:
`.agents/scripts/tests/test-no-worker-process-fix.sh` (15 assertions).

#### Fix 1 — Worker-log tail in `CLAIM_RELEASED` comment

`_post_launch_recovery_claim_released` (pulse-cleanup.sh) now reads the
worker log at `/tmp/pulse-${safe_slug}-${issue_number}.log`, takes the
last 20 lines (capped at 4KB to stay under GitHub's body limit and limit
credential-leak surface), and embeds them in a `<details>` block on the
`CLAIM_RELEASED` comment. Closes the diagnostic gap: every
`no_worker_process` event now ships its own canary diagnostics in the
audit trail. No log forensics required.

#### Fix 2 — Spawn-time exit monitor

`_dlw_exec_detached` (pulse-dispatch-worker-launch.sh) forks a detached
`bash -c` watcher (`_dlw_spawn_early_exit_monitor`) that polls the
nohup'd worker PID for the first `DLW_EARLY_EXIT_WINDOW_SECONDS`
(default 20s, override via env). On early death, the watcher appends a
`[t2814:early_exit] worker PID N for issue #M exited within Ks spawn
window at <ts>` marker to the worker log — which Fix 1 then includes in
the `CLAIM_RELEASED` comment.

The watcher is itself wrapped in `setsid nohup` so it survives pulse
exit; it self-terminates after the window regardless of worker outcome.
Cost: ~5 sleep iterations of 4s each, near-zero CPU.

#### Fix 3 — Close inherited FDs before exec

Both the `setsid nohup` path and the fallback `nohup` path in
`_dlw_exec_detached` now include explicit `3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-`
redirections after the standard `</dev/null >>"$worker_log" 2>&1`.
Closes the suspected FD-leak path that may have caused `EMFILE`
early-exit clusters on long-running pulse instances. Bash 3.2 compatible
(no `{fd}>&-` syntax). No-op when the FDs are not open.

#### Fix 4 — Negative canary cache

`_run_canary_test` (headless-runtime-lib.sh) now stamps a
`canary-last-fail` cache file on failure and short-circuits subsequent
calls within `CANARY_NEGATIVE_TTL_SECONDS` (default 90s, override via
env or `AIDEVOPS_SKIP_CANARY_NEG_CACHE=1` to bypass). Success clears the
file. Cuts the wasted-canary cost during a 90s auth/rate-limit blip from
N × `CANARY_TIMEOUT_SECONDS` (default 60s each) to a single failure plus
N short-circuit returns.

#### Verification

```bash
# Unit + behavioural regression test (15 assertions)
bash .agents/scripts/tests/test-no-worker-process-fix.sh

# After deploy: confirm subsequent no_worker_process events carry log tails
gh api repos/<slug>/issues/<num>/comments --jq \
  '.[] | select(.body | test("CLAIM_RELEASED.*no_worker_process")) | .body' | head -50
```

If a fresh `no_worker_process` event appears without a `<details>` block
on the `CLAIM_RELEASED` comment, the worker log was missing at recovery
time — investigate _dlw_setup_worker_log creation order.

#### Phase 4 fix applied — t2815

**Prevent cascade tier escalation on `no_worker_process` failures** (shipped):

In `recover_failed_launch_state` (pulse-cleanup.sh), when `failure_reason == "no_worker_process"`
and no explicit `crash_type` was provided, the effective crash type is now forced to `"no_work"`.
This routes through the t2387 infra-failure guard in `escalate_issue_tier`, which skips tier
escalation entirely. Observable change:
- Before: 2 consecutive `no_worker_process` → tier:standard upgraded to tier:thinking → opus dispatch → same infra failure.
- After: 2 consecutive `no_worker_process` → same-tier retry (no tier change). After `NO_WORK_NMR_THRESHOLD` (default 3) failures, the t2769 no_work circuit breaker applies `needs-maintainer-review`.

**Crash type classification for `recover_failed_launch_state`**:

| `failure_reason` | Effective `crash_type` | Cascade escalation? | Notes |
|-----------------|------------------------|---------------------|-------|
| `no_worker_process` | `no_work` (t2815) | No | Worker never spawned — infra failure |
| `cli_usage_output` | caller-supplied (empty→unclassified) | Yes (at threshold) | CLI invoked incorrectly |
| `premature_exit` | caller-supplied (explicit crash type from watchdog) | Depends on crash_type | Worker exited during execution |
| `stale_timeout` | caller-supplied (from stale-recovery) | Depends on crash_type | Worker was stalled |

#### Phase 5 — `worker_failed` reclassification via log tail (t2820)

**Problem.** Phases 3-4 fixed the `no_worker_process` slice — the worker
never spawned. The remaining `worker_failed` bucket conflates two distinct
modes that demand opposite responses:

- **Real coding failure** — worker spawned, loaded context, executed tool
  calls, produced bad code. Escalation to opus-4-7 is correct.
- **Late infra failure** — worker spawned, ran canary OK, hit a mid-session
  blip (auth refresh timeout, plugin hook deadlock, provider rate limit)
  BEFORE producing tool calls. Escalation wastes opus tokens.

**Fix.** `escalate_issue_tier` (worker-lifecycle-common.sh) now consults
the worker-log tail (Phase 3 t2814 collection) BEFORE deciding between
escalation and skip. When `crash_type` is empty AND `reason` matches a
generic worker-failure bucket (`worker_failed`, `premature_exit`,
`worker_noop_zero_output`), the helper `_maybe_reclassify_worker_failed_as_no_work`
inspects the log tail and applies one of these rules:

| Log tail signal | Subtype assigned | Cascade fires? | Skip-comment marker |
|-----------------|------------------|----------------|---------------------|
| `[t2814:early_exit]` marker OR `canary` keyword | `canary_post_spawn_failure` | No (skip via t2387 path) | `<!-- no-work-escalation-skip -->` |
| No tool-use markers AND log age ≤ `NO_WORK_RECLASS_ELAPSED_MAX` (default 180s) | `no_tool_calls_in_log` | No | `<!-- no-work-escalation-skip -->` |
| Tool-use / Edit / Write / Bash / `git commit` markers present | `real_coding` (no reclassification) | Yes (normal cascade) | n/a |
| Log file missing OR tail empty | `unknown` (no reclassification) | Yes (existing behaviour) | n/a |

**DRY architecture.** The log-tail reader is now a shared helper —
`_read_worker_log_tail_classified` in `shared-claim-lifecycle.sh` — used by
both consumers:

1. `_post_launch_recovery_claim_released` (pulse-cleanup.sh) — embeds the
   tail in the `CLAIM_RELEASED` comment for diagnosability.
2. `_maybe_reclassify_worker_failed_as_no_work` (worker-lifecycle-common.sh)
   — uses the classification for the reclassification decision above.

This keeps log-path conventions and bounds (last 20 lines, 4KB cap) in one
place. A future refactor that touches one consumer cannot drift the other.

**Tunables.**

- `NO_WORK_RECLASS_ELAPSED_MAX` (default `180` seconds) — the runtime cap
  under which a `no_tool_calls` tail triggers reclassification. The
  `canary_post_spawn` rule fires regardless of runtime (explicit infra
  marker is decisive). Override via env when investigating long-running
  incidents that should not reclassify.

**Backward compatibility.** When the log file is missing (e.g., older
dispatch records pre-Phase 3, or rotated-away logs), the reclassification
helper returns 1 and the existing `worker_failed` → escalation behaviour
fires unchanged. No regression on pre-Phase 3 records.

**Verification.**

```bash
shellcheck .agents/scripts/worker-lifecycle-common.sh \
           .agents/scripts/shared-claim-lifecycle.sh
bash .agents/scripts/tests/test-no-work-reclassification.sh
# After deploy: audit the reclassification subtypes that fired
gh api repos/marcusquinn/aidevops/issues/<N>/comments --jq \
  '.[] | select(.body | test("no_work.*(no_tool_calls_in_log|canary_post_spawn_failure)")) | .body' | head -20
# Tail-side audit (operator log)
grep -E '\[worker-lifecycle\]\[t2820\]' /tmp/pulse-*.log | head
```

#### Self-hosting tier override — t2819

**Pre-dispatch short-circuit for dispatch-path tasks.**

Issues that modify the worker dispatch path (`pulse-wrapper.sh`, `pulse-dispatch-*.sh`, `headless-runtime-helper.sh`, `worker-lifecycle-common.sh`, etc.) have a self-referential property: workers dispatched to fix them run through the code being fixed. When `tier:thinking` starts at opus-4-6, the cascade wastes 1-2 attempts before reaching opus-4-7, which these task sizes require.

The self-hosting detector in `pre-dispatch-validator-helper.sh` runs BEFORE generator-marker validators. It scans the issue body for dispatch-path file patterns and, when found on a `tier:thinking` issue without `model:opus-4-7`, applies the label pre-dispatch. This eliminates wasted cascade attempts.

- **Trigger:** issue body references any of the canonical dispatch-path files (array in `_SELF_HOSTING_PATTERNS`)
- **Precondition:** issue has `tier:thinking` label, lacks `model:opus-4-7`
- **Action:** applies `model:opus-4-7` label + posts provenance-wrapped audit comment
- **Non-blocking:** always exits 0 (advisory, not a dispatch gate)
- **Idempotent:** marker comment `<!-- self-hosting-tier-override -->` prevents duplicate posts
- **Bypass:** `AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1`
- **Dry-run:** `AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN=1`

Observed on GH#20765 (t2814): 2 opus-4-6 attempts (~40K wasted tokens) before cascade reached opus-4-7. This short-circuit eliminates that waste for the self-hosting task class.

## Diagnostic Quick Reference

| Symptom | Check | Likely cause |
|---------|-------|-------------|
| Workers stall at `step_start`, no errors | Isolated DBs exist? Watchdog alive? | SQLite contention (if no isolation) or stream drop (if isolated) |
| No workers dispatched | Canary cache, pulse log | Broken canary, dedup blocking, no dispatchable issues |
| Workers rejected immediately | `grep "Claim guard" /tmp/pulse-*.log` | Claim format mismatch (removed in v3.6.138) |
| Workers dispatch but produce 0 bytes | Version check, `opencode --version` | Wrong OpenCode version, auth failure |
| PRs created but not merged | `review-bot-gate-helper.sh check <PR>` | Review bot rate-limited (passes immediately since v3.6.136) |
| Claim/release loop | Comment history on issue | Stale claims, guard rejections — recreate issue with clean context |
| Watchdog doesn't fire | `ps aux \| grep watchdog` | Watchdog process died with subshell |
| `CLAIM_RELEASED reason=launch_recovery:no_worker_process` on multiple issues | `grep "no active worker process" ~/.aidevops/logs/pulse-wrapper.log` | Cluster failure on one runner — retries at same tier (no cascade escalation, t2815); check system load |

## Proving Workers Are Doing Real Work

Don't trust process counts or log existence. Prove output growth:

```bash
# Measure actual output growth over 15 seconds
for log in $(ls -t /tmp/pulse-*-*.log | head -3); do
  issue=$(basename "$log" .log | sed 's/pulse-[^-]*-[^-]*-//')
  s1=$(wc -c < "$log" | tr -d ' ')
  sleep 15
  s2=$(wc -c < "$log" | tr -d ' ')
  echo "#$issue: +$((s2-s1))b in 15s"
done

# Check GitHub notifications for actual PRs
gh api notifications --jq '.[0:5] | .[] | "\(.updated_at[0:16]) \(.subject.type): \(.subject.title)"'
```

## Multi-Runner Environments

When multiple pulse runners are operating across machines, single-worker diagnostics above
remain valid. For cross-runner race conditions, stale-recovery loops, and new runner setup,
see `reference/cross-runner-coordination.md`.

## `gh pr checks` cancelled-vs-fail

`gh pr checks` renders the GitHub Actions `cancelled` conclusion as
`fail` in its TSV/default output. Only `success` becomes `pass`; all
of `cancelled`, `timed_out`, `action_required`, `failure` collapse to
`fail`.

Before assuming a PR is broken, run:

```bash
gh api repos/OWNER/REPO/actions/runs -f branch=BRANCH \
  -q '.workflow_runs[] | [.conclusion, .name] | @tsv'
```

If all "fail"s are `cancelled`, the CI is not actually broken — a
concurrency cascade (or manual cancel) produced them. See parent issue
GH#19736 for the cascade class.

## Recovery Checklist

When workers are failing systemically:

1. **Version**: `opencode --version` — matches pin in `shared-constants.sh`?
2. **Canary**: `rm -f ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass` and check next cycle
3. **Processes**: `ps aux | grep opencode` — stale processes? Kill with `pkill -f 'opencode.*run'`
4. **Isolation**: `grep 'db_isolated' /tmp/pulse-*.log` — are workers getting isolated DBs?
5. **Watchdog**: `ps aux | grep watchdog` — are watchdog processes surviving?
6. **Pulse log**: `tail -30 ~/.aidevops/logs/pulse.log` — dedup blocked? backoff? claim errors?
7. **Issue comments**: check for `CLAIM_RELEASED` / `DISPATCH_CLAIM` comment loops
8. **Review gate**: `review-bot-gate-helper.sh check <PR>` — `WAITING` means bot is blocking merge

## Pre-Dispatch Eligibility Gate (t2424)

Runs after all dedup/claim/validator layers pass, before the worker spawns. Catches issues that are already resolved:
- CLOSED state
- `status:done` or `status:resolved` label
- Linked PR merged in the last 5 minutes (window: `AIDEVOPS_PREDISPATCH_RECENT_MERGE_WINDOW`, default 300s)

Behaviour: fail-open on API errors (logs warning, dispatch proceeds). Each abort increments `pre_dispatch_aborts` in `~/.aidevops/logs/pulse-stats.json` (visible via `aidevops status`).

Emergency bypass: `AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1`

Test coverage: `.agents/scripts/tests/test-pre-dispatch-eligibility.sh`

## Pulse Decision Correlation

When a PR doesn't auto-merge (or merges unexpectedly), use `pulse-diagnose-helper.sh` to
correlate pulse.log entries with the PR's GitHub state:

```bash
pulse-diagnose-helper.sh pr <N> --repo <owner/repo>
```

The helper reads `~/.aidevops/logs/pulse.log` (and rotated companions), filters lines
mentioning the PR, classifies each against a 60+ rule inventory, and cross-references
`gh pr view` metadata to produce a chronological report.

### Worked example

```text
$ pulse-diagnose-helper.sh pr 20329 --repo marcusquinn/aidevops

PR #20329 (marcusquinn, CLOSED 2026-04-21T18:01:09Z, merged=no)
  Title: t2710: fix dirty-pr-sweep
  Created: 2026-04-20T09:00:00Z  Review: CHANGES_REQUESTED  MergeState: DIRTY

  2026-04-20T10:00:00Z  pulse-wrapper.sh                pw-merge-skip-changes-requested
              Merge pass skipped — review decision is CHANGES_REQUESTED
              source: pulse-wrapper.sh:968

  2026-04-21T17:45:03Z  pulse-dirty-pr-sweep.sh         dps-classify
              Dirty PR sweep classification decision
              source: pulse-dirty-pr-sweep.sh:788

  2026-04-21T17:45:04Z  pulse-dirty-pr-sweep.sh         dps-notify
              Dirty PR notification posted
              source: pulse-dirty-pr-sweep.sh:721

Summary:
  Total pulse events: 3
  Last pulse decision: dps-notify
  Outcome: PR was closed without merge.
```

Each event line shows: timestamp, source script, rule ID, human description, and the
exact `script:line` of the rule that produced the log entry. Use `--verbose` to see raw
log lines alongside classifications. Use `--json` for programmatic consumption.

### Subcommands

| Command | Description |
|---------|-------------|
| `pr <N> [--repo <slug>] [--verbose] [--json]` | Diagnose pulse behaviour for PR #N |
| `rules [--json]` | List the full rule inventory (60+ entries) |
| `help` | Show usage |

### Limitations

- Read-only diagnostic — does not change pulse behaviour.
- Covers PR merge/sweep decisions only. Issue-lifecycle (dispatch, NMR, parent-task)
  is a candidate follow-up (`pulse-diagnose-helper.sh issue <N>`).
- Log lines without timestamps are sorted lexically (best effort).
- Rotated `.gz` logs require `zcat` to be available.
