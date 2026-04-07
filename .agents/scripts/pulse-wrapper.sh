#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-wrapper.sh - Wrapper for supervisor pulse with dedup and lifecycle management
#
# Solves: opencode run enters idle state after completing the pulse prompt
# but never exits, blocking all future pulses via the pgrep dedup guard.
#
# This wrapper:
#   1. mkdir-based atomic instance lock prevents concurrent pulses (GH#4513)
#      Falls back to flock on Linux when util-linux flock is available.
#      mkdir is POSIX-guaranteed atomic on all filesystems (APFS, HFS+, ext4)
#      and does not require util-linux, which is absent on macOS.
#   2. Uses a PID file with staleness check (not pgrep) for dedup
#   3. Cleans up orphaned opencode processes before each pulse
#   4. Kills runaway processes exceeding RSS or runtime limits (t1398.1)
#   5. Calculates dynamic worker concurrency from available RAM
#   6. Internal watchdog kills stuck pulses after PULSE_STALE_THRESHOLD (t1397)
#   7. Self-watchdog: idle detection kills pulse when CPU drops to zero (t1398.3)
#   8. Progress-based watchdog: kills if log output stalls for PULSE_PROGRESS_TIMEOUT (GH#2958)
#   9. Provider-aware pulse sessions via headless-runtime-helper.sh
#  10. Per-issue fast-fail counter skips issues with repeated launch deaths (t1888)
#
# Lifecycle: launchd fires every 120s. If a pulse is still running, the
# dedup check skips. run_pulse() has an internal watchdog that polls every
# 60s and checks three conditions:
#   a) Wall-clock timeout: kills if elapsed > PULSE_STALE_THRESHOLD (60 min)
#   b) Idle detection: kills if CPU usage stays below PULSE_IDLE_CPU_THRESHOLD
#      for PULSE_IDLE_TIMEOUT consecutive seconds (default 5 min). This catches
#      the opencode idle-state bug where the process completes but sits in a
#      file watcher consuming no CPU. Without this, zombies persist until the
#      next launchd invocation detects staleness — which fails if launchd
#      stops firing (sleep, plist unloaded).
#   c) Progress detection (GH#2958): kills if the log file hasn't grown for
#      PULSE_PROGRESS_TIMEOUT seconds. A process that's running but producing
#      no output is stuck — not productive. This catches cases where CPU is
#      nonzero (network I/O, spinning) but no actual work is being done.
# check_dedup() serves as a secondary safety net for edge cases where the
# wrapper itself gets stuck.
#
# PID file sentinel protocol (GH#4324):
#   The PID file is NEVER deleted at run end. Instead it is overwritten with
#   an "IDLE:<timestamp>" sentinel. check_dedup() treats any content that is
#   not a live numeric PID as "safe to proceed". This closes the race window
#   where launchd fires between rm -f and the next write, which caused the
#   82-concurrent-pulse incident (2026-03-13T02:06:01Z, issue #4318).
#
# Instance lock protocol (GH#4513):
#   Uses mkdir atomicity as the primary lock primitive. mkdir is guaranteed
#   atomic by POSIX on all local filesystems — the kernel ensures only one
#   process succeeds even under concurrent invocations. The lock directory
#   contains a PID file so stale locks (from SIGKILL/power loss) can be
#   detected and cleared on the next startup. A trap ensures cleanup on
#   normal exit and SIGTERM. flock (Linux util-linux) is used as an
#   additional layer when available, but mkdir is the primary guard.
#
# Called by launchd every 120s via the supervisor-pulse plist.

set -euo pipefail

#######################################
# PATH normalisation
# The MCP shell environment may have a minimal PATH that excludes /bin
# and other standard directories, causing `env bash` to fail. Ensure
# essential directories are always present.
#######################################
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

#######################################
# Startup jitter — desynchronise concurrent pulse instances
#
# When multiple runners share the same launchd interval (120s), their
# pulses fire simultaneously, creating a race window where both evaluate
# the same issue before either can self-assign. A random 0-30s delay at
# startup staggers the pulses so the first runner to wake assigns the
# issue before the second runner evaluates it.
#
# PULSE_JITTER_MAX: max jitter in seconds (default 30, set to 0 to disable)
#######################################
PULSE_JITTER_MAX="${PULSE_JITTER_MAX:-30}"
if [[ "$PULSE_JITTER_MAX" =~ ^[0-9]+$ && "$PULSE_JITTER_MAX" -gt 0 ]]; then
	# $RANDOM is 0-32767; modulo gives 0 to PULSE_JITTER_MAX
	jitter_seconds=$((RANDOM % (PULSE_JITTER_MAX + 1)))
	if [[ "$jitter_seconds" -gt 0 ]]; then
		sleep "$jitter_seconds"
	fi
fi

# Track pulse start time for signature footer elapsed time (GH#13099)
PULSE_START_EPOCH=$(date +%s)

# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
# in zsh, which is the MCP shell environment. This fallback ensures SCRIPT_DIR
# resolves correctly whether the script is executed directly (bash) or sourced
# from zsh. See GH#3931.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || return 2>/dev/null || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

#######################################
# SSH agent integration for commit signing (t1882)
# Source the persisted agent.env so headless workers can sign commits
# without a passphrase prompt. Safe to source even if the file doesn't
# exist — the conditional guard prevents errors.
#######################################
if [[ -f "$HOME/.ssh/agent.env" ]]; then
	# shellcheck source=/dev/null
	. "$HOME/.ssh/agent.env" >/dev/null 2>&1 || true
fi

#######################################
# Source credentials.sh for model config and API keys (GH#17546)
# Launchd plists bake env vars at setup time — they go stale when
# credentials.sh is later updated. Sourcing at runtime ensures the
# pulse always uses the current AIDEVOPS_HEADLESS_MODELS, PULSE_MODEL,
# and provider API keys, regardless of what the plist embedded.
#######################################
if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
	# shellcheck source=/dev/null
	. "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null || true
fi

if ! type config_get >/dev/null 2>&1; then
	CONFIG_GET_FALLBACK_WARNED=0
	config_get() {
		local requested_key="$1"
		local default_value="$2"
		if [[ "$CONFIG_GET_FALLBACK_WARNED" -eq 0 ]]; then
			printf '[pulse-wrapper] WARN: config_get fallback active; config-helper unavailable, so default config values are being applied starting with key "%s"\n' "$requested_key" >&2
			CONFIG_GET_FALLBACK_WARNED=1
		fi
		printf '%s\n' "$default_value"
		return 0
	}
fi

#######################################
# Configuration
#######################################
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-900}"                                       # 15 min hard ceiling (was 60 min; deterministic fill floor handles dispatch every 2-min cycle)
PULSE_IDLE_TIMEOUT="${PULSE_IDLE_TIMEOUT:-600}"                                             # 10 min idle before kill (reduces false positives during active triage)
PULSE_IDLE_CPU_THRESHOLD="${PULSE_IDLE_CPU_THRESHOLD:-5}"                                   # CPU% below this = idle (0-100 scale)
PULSE_PROGRESS_TIMEOUT="${PULSE_PROGRESS_TIMEOUT:-600}"                                     # 10 min no log output = stuck (GH#2958)
PULSE_COLD_START_TIMEOUT="${PULSE_COLD_START_TIMEOUT:-1200}"                                # 20 min grace before first output (prevents false early watchdog kills)
PULSE_COLD_START_TIMEOUT_UNDERFILLED="${PULSE_COLD_START_TIMEOUT_UNDERFILLED:-600}"         # 10 min grace when below worker target to recover capacity faster
PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT="${PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT:-900}" # 15 min stale-process cutoff when worker pool is underfilled
PULSE_ACTIVE_REFILL_INTERVAL="${PULSE_ACTIVE_REFILL_INTERVAL:-120}"                         # Min seconds between wrapper-side refill attempts during an active pulse
PULSE_ACTIVE_REFILL_IDLE_MIN="${PULSE_ACTIVE_REFILL_IDLE_MIN:-60}"                          # Idle seconds before wrapper-side refill may intervene during monitoring sleep
PULSE_ACTIVE_REFILL_STALL_MIN="${PULSE_ACTIVE_REFILL_STALL_MIN:-120}"                       # Progress stall seconds before wrapper-side refill may intervene during an active pulse
ORPHAN_MAX_AGE="${ORPHAN_MAX_AGE:-7200}"                                                    # 2 hours — kill orphans older than this
ORPHAN_WORKTREE_GRACE_SECS="${ORPHAN_WORKTREE_GRACE_SECS:-1800}"                            # 30 min grace for 0-commit worktrees with no open PR (t1884)
RAM_PER_WORKER_MB="${RAM_PER_WORKER_MB:-512}"                                               # 512 MB per worker (opencode headless is lightweight)
RAM_RESERVE_MB="${RAM_RESERVE_MB:-6144}"                                                    # 6 GB reserved for OS + user apps
# Compute sensible default cap from total RAM (not free RAM — that's volatile).
# Formula: (total_ram_mb - reserve) / ram_per_worker, clamped to [4, 32].
# This replaces the old static default of 8 which silently throttled capable machines (t1532).
_default_cap=8
if [[ "$(uname)" == "Darwin" ]]; then
	_total_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1048576}')
elif [[ -f /proc/meminfo ]]; then
	_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
fi
if [[ "${_total_mb:-0}" -gt 0 ]]; then
	_default_cap=$(((_total_mb - RAM_RESERVE_MB) / RAM_PER_WORKER_MB))
	[[ "$_default_cap" -lt 4 ]] && _default_cap=4
	[[ "$_default_cap" -gt 32 ]] && _default_cap=32
fi
MAX_WORKERS_CAP="${MAX_WORKERS_CAP:-$(config_get "orchestration.max_workers_cap" "$_default_cap")}"     # Derived from total RAM; override via config or env
DAILY_PR_CAP="${DAILY_PR_CAP:-1000}"                                                                    # Max PRs created per repo per day (GH#3821)
PRODUCT_RESERVATION_PCT="${PRODUCT_RESERVATION_PCT:-60}"                                                # % of worker slots reserved for product repos (t1423)
QUALITY_DEBT_CAP_PCT="${QUALITY_DEBT_CAP_PCT:-$(config_get "orchestration.quality_debt_cap_pct" "30")}" # % cap for quality-debt dispatch share
if [[ -z "${PULSE_MODEL:-}" ]]; then
	PULSE_MODEL=$(config_get "orchestration.pulse_model" "")
	if [[ "$PULSE_MODEL" == "null" ]]; then
		PULSE_MODEL=""
	fi
fi
if [[ -z "${AIDEVOPS_HEADLESS_MODELS:-}" ]]; then
	AIDEVOPS_HEADLESS_MODELS=$(config_get "orchestration.headless_models" "")
	if [[ "$AIDEVOPS_HEADLESS_MODELS" == "null" ]]; then
		AIDEVOPS_HEADLESS_MODELS=""
	fi
	if [[ -n "$AIDEVOPS_HEADLESS_MODELS" ]]; then
		export AIDEVOPS_HEADLESS_MODELS
	fi
fi
PULSE_BACKFILL_MAX_ATTEMPTS="${PULSE_BACKFILL_MAX_ATTEMPTS:-3}"                                            # Additional pulse passes when below utilization target (t1453)
PULSE_LAUNCH_GRACE_SECONDS="${PULSE_LAUNCH_GRACE_SECONDS:-35}"                                             # Max grace window for worker process to appear after dispatch (t1453) — raised from 20s to 35s: sandbox-exec + opencode cold-start takes ~25-30s
PULSE_LAUNCH_SETTLE_BATCH_MAX="${PULSE_LAUNCH_SETTLE_BATCH_MAX:-5}"                                        # Dispatch count at which the full PULSE_LAUNCH_GRACE_SECONDS wait applies (t1887)
PRE_RUN_STAGE_TIMEOUT="${PRE_RUN_STAGE_TIMEOUT:-600}"                                                      # 10 min cap per pre-run stage (cleanup/prefetch)
PULSE_PREFETCH_PR_LIMIT="${PULSE_PREFETCH_PR_LIMIT:-200}"                                                  # Open PR list window per repo for pre-fetched state
PULSE_PREFETCH_ISSUE_LIMIT="${PULSE_PREFETCH_ISSUE_LIMIT:-200}"                                            # Open issue list window for pulse prompt payload (keep compact)
PULSE_PREFETCH_CACHE_FILE="${PULSE_PREFETCH_CACHE_FILE:-${HOME}/.aidevops/logs/pulse-prefetch-cache.json}" # Delta prefetch state cache (GH#15286)
PULSE_PREFETCH_FULL_SWEEP_INTERVAL="${PULSE_PREFETCH_FULL_SWEEP_INTERVAL:-86400}"                          # Full sweep interval in seconds (default 24h) (GH#15286)
PULSE_RUNNABLE_PR_LIMIT="${PULSE_RUNNABLE_PR_LIMIT:-200}"                                                  # Open PR sample size for runnable-candidate counting
PULSE_RUNNABLE_ISSUE_LIMIT="${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}"                                           # Open issue sample size for runnable-candidate counting
PULSE_QUEUED_SCAN_LIMIT="${PULSE_QUEUED_SCAN_LIMIT:-1000}"                                                 # Queued/in-progress scan window per repo
UNDERFILL_RECYCLE_DEFICIT_MIN_PCT="${UNDERFILL_RECYCLE_DEFICIT_MIN_PCT:-25}"                               # Run worker recycler when underfill reaches this threshold
UNDERFILL_RECYCLE_THROTTLE_SECS="${UNDERFILL_RECYCLE_THROTTLE_SECS:-300}"                                  # Min seconds between recycler runs when candidates are scarce (t1885)
UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD="${UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD:-3}"                # Candidate count at or below which throttle applies (t1885)
UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT="${UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT:-75}"                         # Deficit % at or above which throttle is bypassed (t1885)
PULSE_PR_BACKLOG_HEAVY_THRESHOLD="${PULSE_PR_BACKLOG_HEAVY_THRESHOLD:-100}"                                # Stronger PR-first mode when open backlog reaches this size
PULSE_PR_BACKLOG_CRITICAL_THRESHOLD="${PULSE_PR_BACKLOG_CRITICAL_THRESHOLD:-175}"                          # Merge-first mode when open backlog becomes severe
PULSE_READY_PR_MERGE_HEAVY_THRESHOLD="${PULSE_READY_PR_MERGE_HEAVY_THRESHOLD:-10}"                         # Merge-first when enough PRs are ready immediately
PULSE_FAILING_PR_HEAVY_THRESHOLD="${PULSE_FAILING_PR_HEAVY_THRESHOLD:-25}"                                 # PR-first when failing/review-blocked queue is large
GH_FAILURE_PREFETCH_HOURS="${GH_FAILURE_PREFETCH_HOURS:-24}"                                               # Window for failed-notification mining summary
GH_FAILURE_PREFETCH_LIMIT="${GH_FAILURE_PREFETCH_LIMIT:-100}"                                              # Notification page size for failed-notification mining
GH_FAILURE_SYSTEMIC_THRESHOLD="${GH_FAILURE_SYSTEMIC_THRESHOLD:-3}"                                        # Cluster threshold for systemic-failure flag
GH_FAILURE_MAX_RUN_LOGS="${GH_FAILURE_MAX_RUN_LOGS:-6}"                                                    # Max failed workflow runs to sample for signatures per pulse
FOSS_SCAN_TIMEOUT="${FOSS_SCAN_TIMEOUT:-30}"                                                               # Timeout for FOSS contribution scan prefetch (t1702)
FOSS_MAX_DISPATCH_PER_CYCLE="${FOSS_MAX_DISPATCH_PER_CYCLE:-2}"                                            # Max FOSS contribution workers per pulse cycle (t1702)

# Per-issue retry state (t1888, GH#2076, GH#17384)
#
# Cause-aware retry backoff per issue. Different failure types get
# different retry strategies:
#
#   RATE LIMIT (reason starts with "rate_limit"):
#     1. Query oauth pool — are other accounts available for this provider?
#     2. YES → retry_after = now (immediate retry on next pulse with rotated account)
#              Do NOT increment the failure counter.
#     3. NO  → retry_after = earliest account recovery time from pool cooldowns.
#              Increment counter (all accounts exhausted = genuine capacity failure).
#
#   NON-RATE-LIMIT (crash, context overflow, local_error, etc.):
#     1. Exponential backoff: FAST_FAIL_INITIAL_BACKOFF_SECS doubled each failure.
#     2. Cap at FAST_FAIL_MAX_BACKOFF_SECS (7 days).
#     3. retry_after = now + backoff_seconds.
#     4. Counter increments. At ESCALATION_FAILURE_THRESHOLD → cascade escalation
#        (tier:simple → tier:standard → tier:reasoning).
#
# State file format:
#   { "slug/number": {
#       "count": N,           # consecutive non-rate-limit failures
#       "ts": epoch,          # last update timestamp
#       "reason": "...",      # last failure reason
#       "retry_after": epoch, # earliest next dispatch time (0 = immediate)
#       "backoff_secs": N     # current backoff interval (doubles each failure)
#   }}
#
# The dispatch check (fast_fail_is_skipped) returns "skip" when:
#   - retry_after is in the future, OR
#   - count >= FAST_FAIL_SKIP_THRESHOLD (hard stop regardless of retry_after)
#
# All functions are best-effort — failures are logged but never fatal.
FAST_FAIL_SKIP_THRESHOLD="${FAST_FAIL_SKIP_THRESHOLD:-5}"               # Hard stop after N non-rate-limit failures
FAST_FAIL_EXPIRY_SECS="${FAST_FAIL_EXPIRY_SECS:-604800}"                # 7-day expiry (matches max backoff)
FAST_FAIL_INITIAL_BACKOFF_SECS="${FAST_FAIL_INITIAL_BACKOFF_SECS:-600}" # 10 min initial backoff
FAST_FAIL_MAX_BACKOFF_SECS="${FAST_FAIL_MAX_BACKOFF_SECS:-604800}"      # 7-day max backoff
EVER_NMR_CACHE_FILE="${EVER_NMR_CACHE_FILE:-${HOME}/.aidevops/.agent-workspace/supervisor/ever-nmr-cache.json}"
EVER_NMR_NEGATIVE_CACHE_TTL_SECS="${EVER_NMR_NEGATIVE_CACHE_TTL_SECS:-300}" # Recheck negative results after 5 min

# Process guard limits (t1398)
CHILD_RSS_LIMIT_KB="${CHILD_RSS_LIMIT_KB:-2097152}"           # 2 GB default — kill child if RSS exceeds this
CHILD_RUNTIME_LIMIT="${CHILD_RUNTIME_LIMIT:-1800}"            # 30 min default — raised from 10 min (GH#2958, quality scans need time)
SHELLCHECK_RSS_LIMIT_KB="${SHELLCHECK_RSS_LIMIT_KB:-1048576}" # 1 GB — ShellCheck-specific (lower due to exponential expansion)
SHELLCHECK_RUNTIME_LIMIT="${SHELLCHECK_RUNTIME_LIMIT:-300}"   # 5 min — ShellCheck-specific
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-5}"                 # Warn when >N concurrent sessions detected

# Validate numeric configuration (uses _validate_int from worker-lifecycle-common.sh)
PULSE_STALE_THRESHOLD=$(_validate_int PULSE_STALE_THRESHOLD "$PULSE_STALE_THRESHOLD" 3600)
PULSE_IDLE_TIMEOUT=$(_validate_int PULSE_IDLE_TIMEOUT "$PULSE_IDLE_TIMEOUT" 300 60)
PULSE_IDLE_CPU_THRESHOLD=$(_validate_int PULSE_IDLE_CPU_THRESHOLD "$PULSE_IDLE_CPU_THRESHOLD" 5)
PULSE_PROGRESS_TIMEOUT=$(_validate_int PULSE_PROGRESS_TIMEOUT "$PULSE_PROGRESS_TIMEOUT" 600 120)
PULSE_COLD_START_TIMEOUT=$(_validate_int PULSE_COLD_START_TIMEOUT "$PULSE_COLD_START_TIMEOUT" 1200 300)
PULSE_COLD_START_TIMEOUT_UNDERFILLED=$(_validate_int PULSE_COLD_START_TIMEOUT_UNDERFILLED "$PULSE_COLD_START_TIMEOUT_UNDERFILLED" 600 120)
PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT=$(_validate_int PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT "$PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT" 900 300)
ORPHAN_MAX_AGE=$(_validate_int ORPHAN_MAX_AGE "$ORPHAN_MAX_AGE" 7200)
ORPHAN_WORKTREE_GRACE_SECS=$(_validate_int ORPHAN_WORKTREE_GRACE_SECS "$ORPHAN_WORKTREE_GRACE_SECS" 1800 60)
RAM_PER_WORKER_MB=$(_validate_int RAM_PER_WORKER_MB "$RAM_PER_WORKER_MB" 512 1)
RAM_RESERVE_MB=$(_validate_int RAM_RESERVE_MB "$RAM_RESERVE_MB" 6144)
MAX_WORKERS_CAP=$(_validate_int MAX_WORKERS_CAP "$MAX_WORKERS_CAP" "${_default_cap:-8}")
DAILY_PR_CAP=$(_validate_int DAILY_PR_CAP "$DAILY_PR_CAP" 5 1)
PRODUCT_RESERVATION_PCT=$(_validate_int PRODUCT_RESERVATION_PCT "$PRODUCT_RESERVATION_PCT" 60 0)
QUALITY_DEBT_CAP_PCT=$(_validate_int QUALITY_DEBT_CAP_PCT "$QUALITY_DEBT_CAP_PCT" 30 0)
if [[ "$QUALITY_DEBT_CAP_PCT" -gt 100 ]]; then
	QUALITY_DEBT_CAP_PCT=100
fi
PULSE_BACKFILL_MAX_ATTEMPTS=$(_validate_int PULSE_BACKFILL_MAX_ATTEMPTS "$PULSE_BACKFILL_MAX_ATTEMPTS" 3 0)
PULSE_LAUNCH_GRACE_SECONDS=$(_validate_int PULSE_LAUNCH_GRACE_SECONDS "$PULSE_LAUNCH_GRACE_SECONDS" 35 5)
PULSE_LAUNCH_SETTLE_BATCH_MAX=$(_validate_int PULSE_LAUNCH_SETTLE_BATCH_MAX "$PULSE_LAUNCH_SETTLE_BATCH_MAX" 5 1)
PRE_RUN_STAGE_TIMEOUT=$(_validate_int PRE_RUN_STAGE_TIMEOUT "$PRE_RUN_STAGE_TIMEOUT" 600 30)
PULSE_PREFETCH_PR_LIMIT=$(_validate_int PULSE_PREFETCH_PR_LIMIT "$PULSE_PREFETCH_PR_LIMIT" 200 1)
PULSE_PREFETCH_ISSUE_LIMIT=$(_validate_int PULSE_PREFETCH_ISSUE_LIMIT "$PULSE_PREFETCH_ISSUE_LIMIT" 200 1)
PULSE_RUNNABLE_PR_LIMIT=$(_validate_int PULSE_RUNNABLE_PR_LIMIT "$PULSE_RUNNABLE_PR_LIMIT" 200 1)
PULSE_RUNNABLE_ISSUE_LIMIT=$(_validate_int PULSE_RUNNABLE_ISSUE_LIMIT "$PULSE_RUNNABLE_ISSUE_LIMIT" 1000 1)
PULSE_QUEUED_SCAN_LIMIT=$(_validate_int PULSE_QUEUED_SCAN_LIMIT "$PULSE_QUEUED_SCAN_LIMIT" 1000 1)
UNDERFILL_RECYCLE_DEFICIT_MIN_PCT=$(_validate_int UNDERFILL_RECYCLE_DEFICIT_MIN_PCT "$UNDERFILL_RECYCLE_DEFICIT_MIN_PCT" 25 1)
if [[ "$UNDERFILL_RECYCLE_DEFICIT_MIN_PCT" -gt 100 ]]; then
	UNDERFILL_RECYCLE_DEFICIT_MIN_PCT=100
fi
UNDERFILL_RECYCLE_THROTTLE_SECS=$(_validate_int UNDERFILL_RECYCLE_THROTTLE_SECS "$UNDERFILL_RECYCLE_THROTTLE_SECS" 300 0)
UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD=$(_validate_int UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD "$UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD" 3 0)
UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT=$(_validate_int UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT "$UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT" 75 1)
if [[ "$UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT" -gt 100 ]]; then
	UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT=100
fi
PULSE_PR_BACKLOG_HEAVY_THRESHOLD=$(_validate_int PULSE_PR_BACKLOG_HEAVY_THRESHOLD "$PULSE_PR_BACKLOG_HEAVY_THRESHOLD" 100 1)
PULSE_PR_BACKLOG_CRITICAL_THRESHOLD=$(_validate_int PULSE_PR_BACKLOG_CRITICAL_THRESHOLD "$PULSE_PR_BACKLOG_CRITICAL_THRESHOLD" 175 1)
PULSE_READY_PR_MERGE_HEAVY_THRESHOLD=$(_validate_int PULSE_READY_PR_MERGE_HEAVY_THRESHOLD "$PULSE_READY_PR_MERGE_HEAVY_THRESHOLD" 10 1)
PULSE_FAILING_PR_HEAVY_THRESHOLD=$(_validate_int PULSE_FAILING_PR_HEAVY_THRESHOLD "$PULSE_FAILING_PR_HEAVY_THRESHOLD" 25 1)
if [[ "$PULSE_PR_BACKLOG_CRITICAL_THRESHOLD" -lt "$PULSE_PR_BACKLOG_HEAVY_THRESHOLD" ]]; then
	PULSE_PR_BACKLOG_CRITICAL_THRESHOLD="$PULSE_PR_BACKLOG_HEAVY_THRESHOLD"
fi
GH_FAILURE_PREFETCH_HOURS=$(_validate_int GH_FAILURE_PREFETCH_HOURS "$GH_FAILURE_PREFETCH_HOURS" 24 1)
GH_FAILURE_PREFETCH_LIMIT=$(_validate_int GH_FAILURE_PREFETCH_LIMIT "$GH_FAILURE_PREFETCH_LIMIT" 100 1)
GH_FAILURE_SYSTEMIC_THRESHOLD=$(_validate_int GH_FAILURE_SYSTEMIC_THRESHOLD "$GH_FAILURE_SYSTEMIC_THRESHOLD" 3 1)
GH_FAILURE_MAX_RUN_LOGS=$(_validate_int GH_FAILURE_MAX_RUN_LOGS "$GH_FAILURE_MAX_RUN_LOGS" 6 0)
FOSS_SCAN_TIMEOUT=$(_validate_int FOSS_SCAN_TIMEOUT "$FOSS_SCAN_TIMEOUT" 30 5)
FOSS_MAX_DISPATCH_PER_CYCLE=$(_validate_int FOSS_MAX_DISPATCH_PER_CYCLE "$FOSS_MAX_DISPATCH_PER_CYCLE" 2 0)
PULSE_PREFETCH_FULL_SWEEP_INTERVAL=$(_validate_int PULSE_PREFETCH_FULL_SWEEP_INTERVAL "$PULSE_PREFETCH_FULL_SWEEP_INTERVAL" 86400 60)
CHILD_RSS_LIMIT_KB=$(_validate_int CHILD_RSS_LIMIT_KB "$CHILD_RSS_LIMIT_KB" 2097152 1)
CHILD_RUNTIME_LIMIT=$(_validate_int CHILD_RUNTIME_LIMIT "$CHILD_RUNTIME_LIMIT" 1800 1)
SHELLCHECK_RSS_LIMIT_KB=$(_validate_int SHELLCHECK_RSS_LIMIT_KB "$SHELLCHECK_RSS_LIMIT_KB" 1048576 1)
SHELLCHECK_RUNTIME_LIMIT=$(_validate_int SHELLCHECK_RUNTIME_LIMIT "$SHELLCHECK_RUNTIME_LIMIT" 300 1)
SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 1)
EVER_NMR_NEGATIVE_CACHE_TTL_SECS=$(_validate_int EVER_NMR_NEGATIVE_CACHE_TTL_SECS "$EVER_NMR_NEGATIVE_CACHE_TTL_SECS" 300 0)

# _sanitize_markdown and _sanitize_log_field provided by worker-lifecycle-common.sh

PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
LOCKFILE="${HOME}/.aidevops/logs/pulse-wrapper.lock"
LOCKDIR="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
SESSION_FLAG="${HOME}/.aidevops/logs/pulse-session.flag"
STOP_FLAG="${HOME}/.aidevops/logs/pulse-session.stop"
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || echo "opencode")}"
# PULSE_DIR: working directory for the supervisor pulse session.
# Defaults to a neutral workspace path so pulse sessions are not associated
# with any specific managed repo in the host app's session database.
# Previously defaulted to ~/Git/aidevops, which caused 155+ orphaned sessions
# to accumulate under that project even when it had pulse:false (GH#5136).
# Override via env var if a specific directory is needed.
PULSE_DIR="${PULSE_DIR:-${HOME}/.aidevops/.agent-workspace}"
PULSE_MODEL="${PULSE_MODEL:-}"
HEADLESS_RUNTIME_HELPER="${HEADLESS_RUNTIME_HELPER:-${SCRIPT_DIR}/headless-runtime-helper.sh}"
MODEL_AVAILABILITY_HELPER="${MODEL_AVAILABILITY_HELPER:-${SCRIPT_DIR}/model-availability-helper.sh}"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
SCOPE_FILE="${HOME}/.aidevops/logs/pulse-scope-repos"
COMPLEXITY_SCAN_LAST_RUN="${HOME}/.aidevops/logs/complexity-scan-last-run"
COMPLEXITY_SCAN_INTERVAL="${COMPLEXITY_SCAN_INTERVAL:-900}"                       # 15 min — runs each pulse cycle, per-run cap governs throughput
COMPLEXITY_SCAN_TREE_HASH_FILE="${HOME}/.aidevops/logs/complexity-scan-tree-hash" # cached git tree hash for skip-if-unchanged
COMPLEXITY_LLM_SWEEP_LAST_RUN="${HOME}/.aidevops/logs/complexity-llm-sweep-last-run"
COMPLEXITY_LLM_SWEEP_INTERVAL="${COMPLEXITY_LLM_SWEEP_INTERVAL:-21600}"   # 6h — daily LLM sweep when debt is stalled
COMPLEXITY_DEBT_COUNT_FILE="${HOME}/.aidevops/logs/complexity-debt-count" # tracks open simplification-debt count for stall detection
DEDUP_CLEANUP_LAST_RUN="${HOME}/.aidevops/logs/dedup-cleanup-last-run"
DEDUP_CLEANUP_INTERVAL="${DEDUP_CLEANUP_INTERVAL:-86400}"  # 1 day in seconds
DEDUP_CLEANUP_BATCH_SIZE="${DEDUP_CLEANUP_BATCH_SIZE:-50}" # Max issues to close per run
CODERABBIT_REVIEW_LAST_RUN="${HOME}/.aidevops/logs/coderabbit-review-last-run"
CODERABBIT_REVIEW_INTERVAL="${CODERABBIT_REVIEW_INTERVAL:-86400}"               # 1 day in seconds
CODERABBIT_REVIEW_ISSUE="2632"                                                  # Issue where CodeRabbit full reviews are requested
COMPLEXITY_FUNC_LINE_THRESHOLD="${COMPLEXITY_FUNC_LINE_THRESHOLD:-100}"         # Functions longer than this are violations
COMPLEXITY_FILE_VIOLATION_THRESHOLD="${COMPLEXITY_FILE_VIOLATION_THRESHOLD:-1}" # Files with >= this many violations get an issue (was 5)
COMPLEXITY_MD_MIN_LINES="${COMPLEXITY_MD_MIN_LINES:-50}"                        # Agent docs shorter than this are not actionable for simplification
WORKER_WATCHDOG_HELPER="${SCRIPT_DIR}/worker-watchdog.sh"
PULSE_HEALTH_FILE="${HOME}/.aidevops/logs/pulse-health.json"
FAST_FAIL_STATE_FILE="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"

# Log sharding: hot/cold split + append-only cycle index (t1886)
#
# Hot log (pulse.log): active writes, capped at PULSE_LOG_HOT_MAX_BYTES.
#   When the hot log exceeds the cap, it is gzip-compressed and moved to
#   the cold archive directory before the next cycle begins. This keeps
#   the hot log small for fast tail/grep operations.
#
# Cold archive (pulse-archive/): compressed rotated logs, total size capped
#   at PULSE_LOG_COLD_MAX_BYTES. Oldest archives are pruned when the cap is
#   exceeded. Archives are named pulse-YYYYMMDD-HHMMSS.log.gz.
#
# Cycle index (pulse-cycle-index.jsonl): append-only JSONL file. One record
#   per cycle with timestamp, duration, dispatch/merge/kill counters, and
#   worker utilisation. Enables fast cycle-level analytics without parsing
#   the full log. Capped at PULSE_CYCLE_INDEX_MAX_LINES lines; oldest lines
#   are pruned when the cap is exceeded.
PULSE_LOG_HOT_MAX_BYTES="${PULSE_LOG_HOT_MAX_BYTES:-52428800}"     # 50 MB hot log cap
PULSE_LOG_COLD_MAX_BYTES="${PULSE_LOG_COLD_MAX_BYTES:-1073741824}" # 1 GB cold archive cap
PULSE_LOG_ARCHIVE_DIR="${PULSE_LOG_ARCHIVE_DIR:-${HOME}/.aidevops/logs/pulse-archive}"
PULSE_CYCLE_INDEX_FILE="${PULSE_CYCLE_INDEX_FILE:-${HOME}/.aidevops/logs/pulse-cycle-index.jsonl}"
PULSE_CYCLE_INDEX_MAX_LINES="${PULSE_CYCLE_INDEX_MAX_LINES:-10000}" # ~10k cycles ≈ ~14 days at 2-min intervals

# Per-cycle health counters — incremented by merge/cleanup/dispatch functions
# and flushed to PULSE_HEALTH_FILE by write_pulse_health_file() at cycle end.
_PULSE_HEALTH_PRS_MERGED=0
_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=0
_PULSE_HEALTH_STALLED_KILLED=0
_PULSE_HEALTH_PREFETCH_ERRORS=0

# Validate complexity scan configuration (defined above, validated here)
COMPLEXITY_SCAN_INTERVAL=$(_validate_int COMPLEXITY_SCAN_INTERVAL "$COMPLEXITY_SCAN_INTERVAL" 900 300)
COMPLEXITY_LLM_SWEEP_INTERVAL=$(_validate_int COMPLEXITY_LLM_SWEEP_INTERVAL "$COMPLEXITY_LLM_SWEEP_INTERVAL" 21600 3600)
COMPLEXITY_FUNC_LINE_THRESHOLD=$(_validate_int COMPLEXITY_FUNC_LINE_THRESHOLD "$COMPLEXITY_FUNC_LINE_THRESHOLD" 100 50)
COMPLEXITY_FILE_VIOLATION_THRESHOLD=$(_validate_int COMPLEXITY_FILE_VIOLATION_THRESHOLD "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" 1 1)
COMPLEXITY_MD_MIN_LINES=$(_validate_int COMPLEXITY_MD_MIN_LINES "$COMPLEXITY_MD_MIN_LINES" 50 10)
CODERABBIT_REVIEW_INTERVAL=$(_validate_int CODERABBIT_REVIEW_INTERVAL "$CODERABBIT_REVIEW_INTERVAL" 86400 3600)
FAST_FAIL_SKIP_THRESHOLD=$(_validate_int FAST_FAIL_SKIP_THRESHOLD "$FAST_FAIL_SKIP_THRESHOLD" 5 1)
FAST_FAIL_EXPIRY_SECS=$(_validate_int FAST_FAIL_EXPIRY_SECS "$FAST_FAIL_EXPIRY_SECS" 604800 60)
FAST_FAIL_INITIAL_BACKOFF_SECS=$(_validate_int FAST_FAIL_INITIAL_BACKOFF_SECS "$FAST_FAIL_INITIAL_BACKOFF_SECS" 600 60)
FAST_FAIL_MAX_BACKOFF_SECS=$(_validate_int FAST_FAIL_MAX_BACKOFF_SECS "$FAST_FAIL_MAX_BACKOFF_SECS" 604800 600)

# Validate log sharding configuration (t1886)
PULSE_LOG_HOT_MAX_BYTES=$(_validate_int PULSE_LOG_HOT_MAX_BYTES "$PULSE_LOG_HOT_MAX_BYTES" 52428800 1048576)
PULSE_LOG_COLD_MAX_BYTES=$(_validate_int PULSE_LOG_COLD_MAX_BYTES "$PULSE_LOG_COLD_MAX_BYTES" 1073741824 10485760)
PULSE_CYCLE_INDEX_MAX_LINES=$(_validate_int PULSE_CYCLE_INDEX_MAX_LINES "$PULSE_CYCLE_INDEX_MAX_LINES" 10000 100)

if [[ ! -x "$HEADLESS_RUNTIME_HELPER" ]]; then
	printf '[pulse-wrapper] ERROR: headless runtime helper is missing or not executable: %s (SCRIPT_DIR=%s)\n' "$HEADLESS_RUNTIME_HELPER" "$SCRIPT_DIR" >&2
	exit 1
fi

resolve_dispatch_model_for_labels() {
	local labels_csv="$1"
	local tier=""
	local resolved_model=""

	# Tier label resolution — tier:thinking is backward-compat alias for tier:reasoning
	case ",${labels_csv}," in
	*,tier:reasoning,* | *,tier:thinking,*) tier="opus" ;;
	*,tier:standard,*) tier="sonnet" ;;
	*,tier:simple,*) tier="haiku" ;;
	esac

	if [[ -z "$tier" || ! -x "$MODEL_AVAILABILITY_HELPER" ]]; then
		printf '%s' ""
		return 0
	fi

	resolved_model=$("$MODEL_AVAILABILITY_HELPER" resolve "$tier" --quiet 2>/dev/null || true)
	printf '%s' "$resolved_model"
	return 0
}

#######################################
# Ensure log and workspace directories exist
#######################################
mkdir -p "$(dirname "$PIDFILE")"
mkdir -p "$PULSE_DIR"

#######################################
# Acquire an exclusive instance lock using mkdir atomicity (GH#4513)
#
# Primary defense against concurrent pulse instances on macOS and Linux.
# mkdir is POSIX-guaranteed atomic — the kernel ensures only one process
# succeeds even under concurrent invocations. No TOCTOU race is possible.
#
# The lock directory (LOCKDIR) contains a PID file so stale locks from
# SIGKILL or power loss can be detected and cleared on the next startup.
# A trap registered by the caller releases the lock on normal exit and
# SIGTERM. SIGKILL cannot be trapped — the stale-lock detection handles
# that case on the next invocation.
#
# On Linux with util-linux flock available, flock is used as an additional
# layer on the LOCKFILE (FD 9) for belt-and-suspenders protection. The
# mkdir guard is the primary atomic primitive; flock is supplementary.
#
# Returns: 0 if lock acquired, 1 if another instance holds the lock
#######################################
acquire_instance_lock() {
	# Step 1: mkdir-based atomic lock (primary — works on macOS and Linux)
	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		# Lock directory already exists — check if the owning process is alive
		local lock_pid=""
		local lock_pid_file="${LOCKDIR}/pid"
		if [[ -f "$lock_pid_file" ]]; then
			lock_pid=$(cat "$lock_pid_file" 2>/dev/null || echo "")
		fi

		if [[ -n "$lock_pid" ]] && [[ "$lock_pid" =~ ^[0-9]+$ ]] && ps -p "$lock_pid" >/dev/null 2>&1; then
			# Lock owner is alive — genuine concurrent instance
			local lock_age
			lock_age=$(_get_process_age "$lock_pid")
			echo "[pulse-wrapper] Another pulse instance holds the mkdir lock (PID ${lock_pid}, age ${lock_age}s) — exiting immediately (GH#4513)" >>"$WRAPPER_LOGFILE"
			return 1
		fi

		# Lock owner is dead (SIGKILL, power loss, OOM) — stale lock
		# Remove and re-acquire atomically. If two instances race here,
		# only one will succeed at the mkdir below.
		echo "[pulse-wrapper] Stale mkdir lock detected (owner PID ${lock_pid:-unknown} is dead) — clearing and re-acquiring" >>"$WRAPPER_LOGFILE"
		rm -rf "$LOCKDIR" 2>/dev/null || true

		if ! mkdir "$LOCKDIR" 2>/dev/null; then
			# Another instance won the race to re-acquire
			echo "[pulse-wrapper] Lost mkdir lock race after stale-lock clear — another instance acquired it first" >>"$WRAPPER_LOGFILE"
			return 1
		fi
	fi

	# Write our PID into the lock directory for stale-lock detection
	echo "$$" >"${LOCKDIR}/pid"

	# Step 2: flock as supplementary layer on Linux (belt-and-suspenders)
	# flock is not available on macOS without util-linux — skip silently.
	if command -v flock &>/dev/null; then
		if ! flock -n 9 2>/dev/null; then
			# flock says another instance holds it — release our mkdir lock
			# and exit. This handles the edge case where flock and mkdir
			# disagree (e.g., NFS with broken mkdir atomicity).
			echo "[pulse-wrapper] flock secondary guard: another instance holds the flock — releasing mkdir lock and exiting" >>"$WRAPPER_LOGFILE"
			rm -rf "$LOCKDIR" 2>/dev/null || true
			return 1
		fi
		echo "[pulse-wrapper] Instance lock acquired via mkdir+flock (PID $$)" >>"$WRAPPER_LOGFILE"
	else
		# yeah, mkdir atomicity is sufficient on macOS without flock
		echo "[pulse-wrapper] Instance lock acquired via mkdir (PID $$, flock not available on this platform)" >>"$WRAPPER_LOGFILE"
	fi

	return 0
}

#######################################
# Release the instance lock (mkdir-based)
#
# Called by the EXIT trap to ensure the lock directory is removed
# on normal exit and SIGTERM. SIGKILL cannot be trapped — the
# stale-lock detection in acquire_instance_lock() handles that case.
#
# Safe to call multiple times (idempotent).
#######################################
release_instance_lock() {
	rm -rf "$LOCKDIR" 2>/dev/null || true
	return 0
} # nice — idempotent cleanup

#######################################
# Check for stale PID file and clean up
# Returns: 0 if safe to proceed, 1 if another pulse is genuinely running
#
# PID file sentinel protocol (GH#4324):
#   The PID file is never deleted — only overwritten. Valid states:
#     <numeric PID>  — a pulse may be running; verify with ps
#     IDLE:<ts>      — last run completed normally; safe to proceed
#     empty / other  — treat as safe to proceed (first run or corrupt)
#######################################
#######################################
# Handle SETUP sentinel in PID file (GH#5627, extracted from check_dedup)
#
# SETUP sentinel (t1482): another wrapper is running pre-flight stages
# (cleanup, prefetch). The instance lock already prevents true concurrency,
# so if we got past acquire_instance_lock, the SETUP wrapper is dead or
# we ARE that wrapper.
#
# Arguments:
#   $1 - pid_content (the raw SETUP:NNN string from the PID file)
# Exit codes:
#   0 - safe to proceed (sentinel handled)
#   1 - should not happen (fallthrough)
#######################################
_handle_setup_sentinel() {
	local pid_content="$1"
	local setup_pid="${pid_content#SETUP:}"

	# Numeric validation — corrupt sentinel gets reset (GH#4575)
	if ! [[ "$setup_pid" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] check_dedup: invalid SETUP sentinel '${pid_content}' — resetting to IDLE" >>"$LOGFILE"
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi
	if [[ "$setup_pid" == "$$" ]]; then
		# We wrote this ourselves — proceed
		return 0
	fi

	# Check if the process is still alive via its cmdline (GH#4575)
	local setup_cmd=""
	setup_cmd=$(ps -p "$setup_pid" -o command= 2>/dev/null || echo "")

	if [[ -z "$setup_cmd" ]]; then
		echo "[pulse-wrapper] check_dedup: SETUP wrapper $setup_pid is dead — proceeding" >>"$LOGFILE"
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi

	# PID reuse guard: verify the process is actually a pulse-wrapper
	# before killing. PID reuse can assign the old PID to an unrelated
	# process between cycles. (GH#4575)
	if [[ "$setup_cmd" != *"pulse-wrapper.sh"* ]]; then
		echo "[pulse-wrapper] check_dedup: SETUP PID $setup_pid belongs to non-wrapper process ('${setup_cmd%%' '*}'); refusing kill, resetting sentinel" >>"$LOGFILE"
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi
	# SETUP wrapper is alive but we hold the instance lock — it's a zombie
	# from a previous cycle. Kill it and proceed.
	echo "[pulse-wrapper] check_dedup: killing zombie SETUP wrapper $setup_pid" >>"$LOGFILE"
	_kill_tree "$setup_pid" || true
	sleep 1
	if kill -0 "$setup_pid" 2>/dev/null; then
		_force_kill_tree "$setup_pid" || true
	fi
	echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
	return 0
}

#######################################
# Handle a live numeric PID in the PID file (GH#5627, extracted from check_dedup)
#
# Checks if the process is stale (exceeds threshold) and kills it,
# or reports genuine dedup (another pulse is legitimately running).
#
# Arguments:
#   $1 - old_pid (numeric PID from the PID file)
# Exit codes:
#   0 - safe to proceed (process was dead or stale and killed)
#   1 - genuine dedup (another pulse is running within limits)
#######################################
_handle_running_pulse_pid() {
	local old_pid="$1"

	# Check if the process is still running
	if ! ps -p "$old_pid" >/dev/null 2>&1; then
		# Process is dead — write IDLE sentinel so the file is never absent
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi

	# Process is running — check how long
	local elapsed_seconds
	elapsed_seconds=$(_get_process_age "$old_pid")

	if [[ "$elapsed_seconds" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		# Process has been running too long — it's stuck.
		# Guard kill commands with || true so set -e doesn't abort cleanup
		# if the target process has already exited between checks.
		echo "[pulse-wrapper] Killing stale pulse process $old_pid (running ${elapsed_seconds}s, threshold ${PULSE_STALE_THRESHOLD}s)" >>"$LOGFILE"
		_kill_tree "$old_pid" || true
		sleep 2
		# Force kill if still alive
		if kill -0 "$old_pid" 2>/dev/null; then
			_force_kill_tree "$old_pid" || true
		fi
		# Write IDLE sentinel — never leave the file absent (GH#4324)
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi

	# Underfill is now intelligence-managed by the pulse session itself.
	# Do not recycle running pulse processes based only on elapsed time while
	# underfilled — that creates churn loops and suppresses transcript analysis.
	local max_workers active_workers deficit_pct
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	deficit_pct=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		deficit_pct=$(((max_workers - active_workers) * 100 / max_workers))
		echo "[pulse-wrapper] Underfilled ${active_workers}/${max_workers} (${deficit_pct}%) but preserving active pulse PID $old_pid for transcript-driven decisions" >>"$LOGFILE"
	fi

	# Process is running and within time limit — genuine dedup
	echo "[pulse-wrapper] Pulse already running (PID $old_pid, ${elapsed_seconds}s elapsed). Skipping." >>"$LOGFILE"
	return 1
}

check_dedup() {
	if [[ ! -f "$PIDFILE" ]]; then
		return 0
	fi

	local pid_content
	pid_content=$(cat "$PIDFILE" 2>/dev/null || echo "")

	# Empty file or IDLE sentinel — safe to proceed (GH#4324)
	if [[ -z "$pid_content" ]] || [[ "$pid_content" == IDLE:* ]]; then
		return 0
	fi

	# SETUP sentinel — delegate to helper
	if [[ "$pid_content" == SETUP:* ]]; then
		_handle_setup_sentinel "$pid_content"
		return $?
	fi

	# Non-numeric content (corrupt/unknown) — safe to proceed
	local old_pid="$pid_content"
	if ! [[ "$old_pid" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] check_dedup: unrecognised PID file content '${old_pid}' — treating as idle" >>"$LOGFILE"
		return 0
	fi

	# Self-detection (t1482): if the PID file contains our own PID, we wrote
	# it in a previous code path (e.g., early PID write at main() entry).
	# Never block on ourselves.
	if [[ "$old_pid" == "$$" ]]; then
		return 0
	fi

	# Delegate live PID handling (stale check, dedup)
	_handle_running_pulse_pid "$old_pid"
	return $?
}

# Process lifecycle functions (_kill_tree, _force_kill_tree, _get_process_age,
# _get_pid_cpu, _get_process_tree_cpu) provided by worker-lifecycle-common.sh

#######################################
# Delta prefetch cache helpers (GH#15286)
#
# The cache file is a JSON object keyed by repo slug:
#   {
#     "owner/repo": {
#       "last_prefetch": "2026-04-01T12:00:00Z",
#       "last_full_sweep": "2026-04-01T00:00:00Z",
#       "issues": [...],   # full issue list from last full sweep
#       "prs": [...]       # full PR list from last full sweep
#     }
#   }
#
# Delta cycle: fetch only items with updatedAt > last_prefetch, merge into
# cached full list, update last_prefetch timestamp.
# Full sweep: fetch everything, replace cached list, update both timestamps.
# Fallback: if delta fetch fails or cache is corrupt, fall back to full fetch.
#######################################

#######################################
# Load the prefetch cache for a single repo slug.
#
# Outputs the JSON object for the slug, or "{}" if not found/corrupt.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#######################################
_prefetch_cache_get() {
	local slug="$1"
	local cache_file="$PULSE_PREFETCH_CACHE_FILE"
	if [[ ! -f "$cache_file" ]]; then
		echo "{}"
		return 0
	fi
	local entry
	entry=$(jq -r --arg slug "$slug" '.[$slug] // {}' "$cache_file" 2>/dev/null) || entry="{}"
	[[ -n "$entry" ]] || entry="{}"
	echo "$entry"
	return 0
}

#######################################
# Write updated cache entry for a repo slug.
#
# Merges the new entry into the cache file atomically (write to tmp, mv).
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - JSON object to store for this slug
#######################################
_prefetch_cache_set() {
	local slug="$1"
	local entry="$2"
	local cache_file="$PULSE_PREFETCH_CACHE_FILE"
	local cache_dir
	cache_dir=$(dirname "$cache_file")
	mkdir -p "$cache_dir" 2>/dev/null || true

	local existing="{}"
	if [[ -f "$cache_file" ]]; then
		existing=$(cat "$cache_file" 2>/dev/null) || existing="{}"
		# Validate JSON; reset if corrupt
		echo "$existing" | jq empty 2>/dev/null || existing="{}"
	fi

	local tmp_file
	tmp_file=$(mktemp "${cache_dir}/.pulse-prefetch-cache.XXXXXX")
	echo "$existing" | jq --arg slug "$slug" --argjson entry "$entry" \
		'.[$slug] = $entry' >"$tmp_file" 2>/dev/null && mv "$tmp_file" "$cache_file" || {
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _prefetch_cache_set: failed to write cache for ${slug}" >>"$LOGFILE"
	}
	return 0
}

#######################################
# Determine whether a full sweep is needed for a repo.
#
# Returns 0 (true) if:
#   - Cache entry missing or has no last_full_sweep
#   - last_full_sweep is older than PULSE_PREFETCH_FULL_SWEEP_INTERVAL seconds
#
# Arguments:
#   $1 - cache entry JSON (from _prefetch_cache_get)
#######################################
_prefetch_needs_full_sweep() {
	local entry="$1"
	local last_full_sweep
	last_full_sweep=$(echo "$entry" | jq -r '.last_full_sweep // ""' 2>/dev/null) || last_full_sweep=""
	if [[ -z "$last_full_sweep" || "$last_full_sweep" == "null" ]]; then
		return 0 # No prior full sweep — must do one
	fi

	# Convert ISO timestamp to epoch (macOS date -j -f)
	local last_epoch now_epoch
	# GH#17699: TZ=UTC required — macOS date interprets input as local time
	last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_full_sweep" "+%s" 2>/dev/null) || last_epoch=0
	now_epoch=$(date -u +%s)
	local age=$((now_epoch - last_epoch))
	if [[ "$age" -ge "$PULSE_PREFETCH_FULL_SWEEP_INTERVAL" ]]; then
		return 0 # Sweep interval elapsed
	fi
	return 1 # Delta is sufficient
}

#######################################
# Print the Open PRs section for a repo (GH#5627, GH#15286)
#
# Fetches open PRs and emits a markdown section to stdout.
# Called from _prefetch_single_repo inside a subshell redirect.
#
# Delta prefetch (GH#15286): on non-full-sweep cycles, fetches only PRs
# updated since last_prefetch and merges into the cached full list.
# Falls back to full fetch if delta fails or cache is missing.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - cache entry JSON (from _prefetch_cache_get)
#   $3 - "full" for full sweep, "delta" for delta fetch
#   $4 - output variable name for updated prs JSON (nameref not available in bash 3.2;
#        caller reads PREFETCH_UPDATED_PRS after return)
#######################################
#######################################
# Attempt delta PR fetch and merge into cached list (GH#15286).
# Sets PREFETCH_PR_SWEEP_MODE="full" on failure (caller falls through).
# Sets PREFETCH_PR_RESULT on success.
# Arguments: $1=slug, $2=cache_entry, $3=pr_err_file
#######################################
_prefetch_prs_try_delta() {
	local slug="$1"
	local cache_entry="$2"
	local pr_err="$3"

	local last_prefetch
	last_prefetch=$(echo "$cache_entry" | jq -r '.last_prefetch // ""' 2>/dev/null) || last_prefetch=""

	# No usable timestamp — fall back to full
	if [[ -z "$last_prefetch" || "$last_prefetch" == "null" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_prs: delta fetch failed for ${slug} (falling back to full): no timestamp or fetch error" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="full"
		return 0
	fi

	local delta_json=""
	delta_json=$(gh pr list --repo "$slug" --state open \
		--json number,title,reviewDecision,updatedAt,headRefName,createdAt,author \
		--search "updated:>=${last_prefetch}" \
		--limit "$PULSE_PREFETCH_PR_LIMIT" 2>"$pr_err") || delta_json=""

	if [[ -z "$delta_json" || "$delta_json" == "null" ]]; then
		local _delta_err_msg
		_delta_err_msg=$(cat "$pr_err" 2>/dev/null || echo "no timestamp or fetch error")
		echo "[pulse-wrapper] _prefetch_repo_prs: delta fetch failed for ${slug} (falling back to full): ${_delta_err_msg}" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="full"
		return 0
	fi

	# Merge delta into cached full list: replace matching numbers, append new ones
	local cached_prs
	cached_prs=$(echo "$cache_entry" | jq '.prs // []' 2>/dev/null) || cached_prs="[]"
	local merged
	merged=$(echo "$cached_prs" | jq --argjson delta "$delta_json" '
		($delta | map(.number) | map(tostring) | map({(.) : true}) | add // {}) as $delta_nums |
		[.[] | select((.number | tostring) as $n | $delta_nums[$n] | not)] +
		$delta
	' 2>/dev/null) || merged=""

	if [[ -z "$merged" || "$merged" == "null" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_prs: delta merge failed for ${slug} (falling back to full)" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="full"
		return 0
	fi

	local delta_count
	delta_count=$(echo "$delta_json" | jq 'length' 2>/dev/null) || delta_count=0
	echo "[pulse-wrapper] _prefetch_repo_prs: delta for ${slug}: ${delta_count} changed PRs merged into cache" >>"$LOGFILE"
	PREFETCH_PR_RESULT="$merged"
	return 0
}

#######################################
# Fetch statusCheckRollup enrichment for open PRs (GH#15060).
# Non-fatal: returns empty string on failure.
# Arguments: $1=slug, $2=checks_limit
# Output: JSON array to stdout (or empty string)
#######################################
_prefetch_prs_enrich_checks() {
	local slug="$1"
	local checks_limit="$2"

	local checks_err
	checks_err=$(mktemp)
	local checks_json=""
	checks_json=$(gh pr list --repo "$slug" --state open \
		--json number,statusCheckRollup \
		--limit "$checks_limit" 2>"$checks_err") || checks_json=""

	if [[ -z "$checks_json" || "$checks_json" == "null" ]]; then
		local _checks_err_msg
		_checks_err_msg=$(cat "$checks_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] _prefetch_repo_prs: statusCheckRollup enrichment FAILED for ${slug} (non-fatal, PRs shown without check status): ${_checks_err_msg}" >>"$LOGFILE"
		checks_json=""
	fi
	rm -f "$checks_err"

	printf '%s' "$checks_json"
	return 0
}

#######################################
# Format PR list as markdown with optional check status enrichment.
# Arguments: $1=pr_json, $2=pr_count, $3=checks_json
# Output: markdown to stdout
#######################################
_prefetch_prs_format_output() {
	local pr_json="$1"
	local pr_count="$2"
	local checks_json="$3"

	if [[ "$pr_count" -le 0 ]]; then
		echo "### Open PRs (0)"
		echo "- None"
		return 0
	fi

	echo "### Open PRs ($pr_count)"
	if [[ -n "$checks_json" && "$checks_json" != "[]" ]]; then
		echo "$pr_json" | jq -r --argjson checks "${checks_json:-[]}" '
			($checks | map({(.number | tostring): .statusCheckRollup}) | add // {}) as $check_map |
			.[] |
			(.number | tostring) as $num |
			($check_map[$num] // null) as $rolls |
			"- PR #\(.number): \(.title) [checks: \(
				if $rolls == null or ($rolls | length) == 0 then "none"
				elif ($rolls | all((.conclusion // .state) == "SUCCESS")) then "PASS"
				elif ($rolls | any((.conclusion // .state) == "FAILURE")) then "FAIL"
				else "PENDING"
				end
			)] [review: \(
				if .reviewDecision == null or .reviewDecision == "" then "NONE"
				else .reviewDecision
				end
			)] [author: \(.author.login // "unknown")] [branch: \(.headRefName)] [updated: \(.updatedAt)]"
		'
	else
		echo "$pr_json" | jq -r '.[] | "- PR #\(.number): \(.title) [checks: unknown] [review: \(if .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end)] [author: \(.author.login // "unknown")] [branch: \(.headRefName)] [updated: \(.updatedAt)]"'
	fi
	return 0
}

_prefetch_repo_prs() {
	local slug="$1"
	local cache_entry="${2:-{}}"
	local sweep_mode="${3:-full}"

	# PRs (createdAt included for daily PR cap — GH#3821)
	# GH#15060: statusCheckRollup is the heaviest field in the GraphQL payload —
	# each PR's full check suite data can be kilobytes. With 100+ PRs, the
	# response exceeds GitHub's internal timeout and `gh` returns an error that
	# the `2>/dev/null || pr_json="[]"` pattern silently swallows, producing
	# "Open PRs (0)" when hundreds exist. This was the root cause of the pulse
	# seeing 0 PRs and never merging anything.
	#
	# Fix: fetch without statusCheckRollup first (fast, always works), then
	# enrich with check status in a separate lightweight call. If the enrichment
	# fails, the pulse still sees the PR list and can act on review status.
	#
	# GH#15286: Delta mode — fetch only PRs updated since last_prefetch, then
	# merge into cached full list. Full sweep replaces the cache entirely.
	local pr_json="" pr_err
	pr_err=$(mktemp)

	# Delta fetch: try merging recent changes into cache (GH#15286)
	PREFETCH_PR_SWEEP_MODE="$sweep_mode"
	PREFETCH_PR_RESULT=""
	if [[ "$sweep_mode" == "delta" ]]; then
		_prefetch_prs_try_delta "$slug" "$cache_entry" "$pr_err"
		sweep_mode="$PREFETCH_PR_SWEEP_MODE"
		pr_json="$PREFETCH_PR_RESULT"
	fi

	# Full fetch: either requested directly or delta fell back
	if [[ "$sweep_mode" == "full" ]]; then
		pr_json=$(gh pr list --repo "$slug" --state open \
			--json number,title,reviewDecision,updatedAt,headRefName,createdAt,author \
			--limit "$PULSE_PREFETCH_PR_LIMIT" 2>"$pr_err") || pr_json=""

		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
			local err_msg
			err_msg=$(cat "$pr_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] _prefetch_repo_prs: gh pr list FAILED for ${slug}: ${err_msg}" >>"$LOGFILE"
			pr_json="[]"
		fi
	fi
	rm -f "$pr_err"

	# Export updated PR list for cache update by caller (Bash 3.2: no namerefs)
	PREFETCH_UPDATED_PRS="$pr_json"

	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	# Enrichment: fetch statusCheckRollup separately (GH#15060)
	local checks_json=""
	if [[ "$pr_count" -gt 0 ]]; then
		checks_json=$(_prefetch_prs_enrich_checks "$slug" 50)
	fi

	_prefetch_prs_format_output "$pr_json" "$pr_count" "$checks_json"

	echo ""
	return 0
}

#######################################
# Print the Daily PR Cap section for a repo (GH#5627)
#
# Counts ALL PRs created today (open+merged+closed) to enforce the
# daily cap. Must use --state all — open-only undercounts (GH#3821,
# GH#4412). Emits a markdown section to stdout.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#######################################
_prefetch_repo_daily_cap() {
	local slug="$1"

	local today_utc
	today_utc=$(date -u +%Y-%m-%d)
	local daily_cap_json daily_cap_err
	daily_cap_err=$(mktemp)
	daily_cap_json=$(gh pr list --repo "$slug" --state all \
		--json createdAt --limit 200 2>"$daily_cap_err") || daily_cap_json="[]"
	if [[ -z "$daily_cap_json" || "$daily_cap_json" == "null" ]]; then
		local _daily_cap_err_msg
		_daily_cap_err_msg=$(cat "$daily_cap_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] _prefetch_repo_daily_cap: gh pr list FAILED for ${slug}: ${_daily_cap_err_msg}" >>"$LOGFILE"
		daily_cap_json="[]"
	fi
	rm -f "$daily_cap_err"
	local daily_pr_count
	daily_pr_count=$(echo "$daily_cap_json" | jq --arg today "$today_utc" \
		'[.[] | select(.createdAt | startswith($today))] | length') || daily_pr_count=0
	[[ "$daily_pr_count" =~ ^[0-9]+$ ]] || daily_pr_count=0
	local daily_pr_remaining=$((DAILY_PR_CAP - daily_pr_count))
	if [[ "$daily_pr_remaining" -lt 0 ]]; then
		daily_pr_remaining=0
	fi

	echo "### Daily PR Cap"
	if [[ "$daily_pr_count" -ge "$DAILY_PR_CAP" ]]; then
		echo "- **DAILY PR CAP REACHED** — ${daily_pr_count}/${DAILY_PR_CAP} PRs created today (UTC)"
		echo "- **DO NOT dispatch new workers for this repo.** Wait for the next UTC day."
		echo "[pulse-wrapper] Daily PR cap reached for ${slug}: ${daily_pr_count}/${DAILY_PR_CAP}" >>"$LOGFILE"
	else
		echo "- PRs created today: ${daily_pr_count}/${DAILY_PR_CAP} (${daily_pr_remaining} remaining)"
	fi

	echo ""
	return 0
}

#######################################
# Print the Open Issues sections for a repo (GH#5627, GH#15286)
#
# Fetches open issues, filters managed labels, splits into dispatchable
# vs quality-sweep-tracked, and emits markdown sections to stdout.
# Called from _prefetch_single_repo inside a subshell redirect.
#
# Delta prefetch (GH#15286): on non-full-sweep cycles, fetches only issues
# updated since last_prefetch and merges into the cached full list.
# Falls back to full fetch if delta fails or cache is missing.
# Sets PREFETCH_UPDATED_ISSUES for cache update by caller.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - cache entry JSON (from _prefetch_cache_get)
#   $3 - "full" for full sweep, "delta" for delta fetch
#######################################
#######################################
# Attempt delta issue fetch and merge into cached list (GH#15286).
# Sets PREFETCH_ISSUE_SWEEP_MODE="full" on failure (caller falls through).
# Sets PREFETCH_ISSUE_RESULT on success.
# Arguments: $1=slug, $2=cache_entry, $3=issue_err_file
#######################################
_prefetch_issues_try_delta() {
	local slug="$1"
	local cache_entry="$2"
	local issue_err="$3"

	local last_prefetch
	last_prefetch=$(echo "$cache_entry" | jq -r '.last_prefetch // ""' 2>/dev/null) || last_prefetch=""

	# No usable timestamp — fall back to full
	if [[ -z "$last_prefetch" || "$last_prefetch" == "null" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_issues: delta fetch failed for ${slug} (falling back to full): no timestamp or fetch error" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="full"
		return 0
	fi

	local delta_json=""
	delta_json=$(gh issue list --repo "$slug" --state open \
		--json number,title,labels,updatedAt,assignees \
		--search "updated:>=${last_prefetch}" \
		--limit "$PULSE_PREFETCH_ISSUE_LIMIT" 2>"$issue_err") || delta_json=""

	if [[ -z "$delta_json" || "$delta_json" == "null" ]]; then
		local _delta_issue_err
		_delta_issue_err=$(cat "$issue_err" 2>/dev/null || echo "no timestamp or fetch error")
		echo "[pulse-wrapper] _prefetch_repo_issues: delta fetch failed for ${slug} (falling back to full): ${_delta_issue_err}" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="full"
		return 0
	fi

	# Merge delta into cached full list
	local cached_issues
	cached_issues=$(echo "$cache_entry" | jq '.issues // []' 2>/dev/null) || cached_issues="[]"
	local merged
	merged=$(echo "$cached_issues" | jq --argjson delta "$delta_json" '
		($delta | map(.number) | map(tostring) | map({(.) : true}) | add // {}) as $delta_nums |
		[.[] | select((.number | tostring) as $n | $delta_nums[$n] | not)] +
		$delta
	' 2>/dev/null) || merged=""

	if [[ -z "$merged" || "$merged" == "null" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_issues: delta merge failed for ${slug} (falling back to full)" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="full"
		return 0
	fi

	local delta_count
	delta_count=$(echo "$delta_json" | jq 'length' 2>/dev/null) || delta_count=0
	echo "[pulse-wrapper] _prefetch_repo_issues: delta for ${slug}: ${delta_count} changed issues merged into cache" >>"$LOGFILE"
	PREFETCH_ISSUE_RESULT="$merged"
	return 0
}

_prefetch_repo_issues() {
	local slug="$1"
	local cache_entry="${2:-{}}"
	local sweep_mode="${3:-full}"

	# Issues (include assignees for dispatch dedup)
	# Filter out supervisor/contributor/persistent/quality-review issues —
	# these are managed by pulse-wrapper.sh and must not be touched by the
	# pulse agent. Exposing them in pre-fetched state causes the LLM to
	# close them as "stale", creating churn (wrapper recreates on next cycle).
	# GH#15060: Log errors instead of silently swallowing them with 2>/dev/null.
	# GH#15286: Delta mode — fetch only recently-updated issues, merge into cache.
	local issue_json="" issue_err
	issue_err=$(mktemp)

	# Delta fetch: try merging recent changes into cache (GH#15286)
	PREFETCH_ISSUE_SWEEP_MODE="$sweep_mode"
	PREFETCH_ISSUE_RESULT=""
	if [[ "$sweep_mode" == "delta" ]]; then
		_prefetch_issues_try_delta "$slug" "$cache_entry" "$issue_err"
		sweep_mode="$PREFETCH_ISSUE_SWEEP_MODE"
		issue_json="$PREFETCH_ISSUE_RESULT"
	fi

	# Full fetch: either requested directly or delta fell back
	if [[ "$sweep_mode" == "full" ]]; then
		issue_json=$(gh issue list --repo "$slug" --state open \
			--json number,title,labels,updatedAt,assignees \
			--limit "$PULSE_PREFETCH_ISSUE_LIMIT" 2>"$issue_err") || issue_json=""

		if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
			local issue_err_msg
			issue_err_msg=$(cat "$issue_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] _prefetch_repo_issues: gh issue list FAILED for ${slug}: ${issue_err_msg}" >>"$LOGFILE"
			issue_json="[]"
		fi
	fi
	rm -f "$issue_err"

	# Export updated issue list for cache update by caller (Bash 3.2: no namerefs)
	PREFETCH_UPDATED_ISSUES="$issue_json"

	# Remove issues with supervisor, contributor, persistent, or quality-review labels
	local filtered_json
	filtered_json=$(echo "$issue_json" | jq '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("needs-maintainer-review")) | not)]')

	# GH#10308: Split issues into dispatchable vs quality-sweep-tracked.
	local dispatchable_json sweep_tracked_json
	dispatchable_json=$(echo "$filtered_json" | jq '[.[] | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")) | not)]')
	sweep_tracked_json=$(echo "$filtered_json" | jq '[.[] | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")))]')

	local dispatchable_count sweep_tracked_count
	dispatchable_count=$(echo "$dispatchable_json" | jq 'length')
	sweep_tracked_count=$(echo "$sweep_tracked_json" | jq 'length')

	if [[ "$dispatchable_count" -gt 0 ]]; then
		echo "### Open Issues ($dispatchable_count)"
		echo "$dispatchable_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)] [updated: \(.updatedAt)]"'
	else
		echo "### Open Issues (0)"
		echo "- None"
	fi

	echo ""

	# GH#10308: Show quality-sweep-tracked issues so the LLM knows what's
	# already filed and avoids creating duplicates from sweep findings.
	if [[ "$sweep_tracked_count" -gt 0 ]]; then
		echo "### Already Tracked by Quality Sweep ($sweep_tracked_count)"
		echo "_These issues were auto-created by the quality sweep or review feedback pipeline._"
		echo "_DO NOT create new issues for findings already covered below. Dispatch these as normal quality-debt/simplification-debt work._"
		echo "$sweep_tracked_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)]"'
		echo ""
	fi
	return 0
}

#######################################
# Fetch PR, issue, and daily-cap data for a single repo (GH#5627, GH#15286)
#
# Runs inside a subshell (called from prefetch_state parallel loop).
# Writes a compact markdown summary to the specified output file.
# Delegates to focused helpers for each data section.
#
# Delta prefetch (GH#15286): determines sweep mode from cache, calls helpers
# with cache entry, then updates the cache file with fresh data.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path
#   $3 - output file path
#######################################
_prefetch_single_repo() {
	local slug="$1"
	local path="$2"
	local outfile="$3"

	# GH#15286: Determine sweep mode from cache
	local cache_entry
	cache_entry=$(_prefetch_cache_get "$slug")
	local sweep_mode="delta"
	if _prefetch_needs_full_sweep "$cache_entry"; then
		sweep_mode="full"
		echo "[pulse-wrapper] _prefetch_single_repo: full sweep for ${slug}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] _prefetch_single_repo: delta prefetch for ${slug}" >>"$LOGFILE"
	fi

	# Reset shared output vars (subshell-safe: each repo runs in its own subshell)
	PREFETCH_UPDATED_PRS="[]"
	PREFETCH_UPDATED_ISSUES="[]"

	{
		echo "## ${slug} (${path})"
		echo ""
		_prefetch_repo_prs "$slug" "$cache_entry" "$sweep_mode"
		_prefetch_repo_daily_cap "$slug"
		_prefetch_repo_issues "$slug" "$cache_entry" "$sweep_mode"
	} >"$outfile"

	# GH#15286: Update cache with fresh data
	local now_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local new_entry
	if [[ "$sweep_mode" == "full" ]]; then
		new_entry=$(jq -n \
			--arg now "$now_iso" \
			--argjson prs "${PREFETCH_UPDATED_PRS:-[]}" \
			--argjson issues "${PREFETCH_UPDATED_ISSUES:-[]}" \
			'{last_prefetch: $now, last_full_sweep: $now, prs: $prs, issues: $issues}')
	else
		local last_full_sweep
		last_full_sweep=$(echo "$cache_entry" | jq -r '.last_full_sweep // ""' 2>/dev/null) || last_full_sweep=""
		new_entry=$(jq -n \
			--arg now "$now_iso" \
			--arg lfs "$last_full_sweep" \
			--argjson prs "${PREFETCH_UPDATED_PRS:-[]}" \
			--argjson issues "${PREFETCH_UPDATED_ISSUES:-[]}" \
			'{last_prefetch: $now, last_full_sweep: $lfs, prs: $prs, issues: $issues}')
	fi
	_prefetch_cache_set "$slug" "$new_entry"

	return 0
}

#######################################
# Wait for parallel PIDs with a hard timeout (GH#5627)
#
# Poll-based approach (kill -0) instead of blocking wait — wait $pid
# blocks until the process exits, so a timeout check between waits is
# ineffective when a single wait hangs for minutes.
#
# Arguments:
#   $1 - timeout in seconds
#   $2..N - PIDs to wait for (passed as remaining args)
# Returns: 0 always (best-effort — kills stragglers on timeout)
#######################################
_wait_parallel_pids() {
	local timeout_secs="$1"
	shift
	local pids=("$@")

	local wait_elapsed=0
	local all_done=false
	while [[ "$all_done" != "true" ]] && [[ "$wait_elapsed" -lt "$timeout_secs" ]]; do
		all_done=true
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				all_done=false
				break
			fi
		done
		if [[ "$all_done" != "true" ]]; then
			sleep 2
			wait_elapsed=$((wait_elapsed + 2))
		fi
	done
	if [[ "$all_done" != "true" ]]; then
		echo "[pulse-wrapper] Parallel gh fetch timeout after ${wait_elapsed}s — killing remaining fetches" >>"$LOGFILE"
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				_kill_tree "$pid" || true
			fi
		done
		sleep 1
		# Force-kill any survivors
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				_force_kill_tree "$pid" || true
			fi
		done
	fi
	# Reap all child processes (non-blocking since they're dead or killed)
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

#######################################
# Assemble state file from parallel fetch results (GH#5627)
#
# Concatenates numbered output files from tmpdir into STATE_FILE
# with a header timestamp.
#
# Arguments:
#   $1 - tmpdir containing numbered .txt files
#######################################
_assemble_state_file() {
	local tmpdir="$1"

	{
		echo "# Pre-fetched Repo State ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
		echo ""
		echo "This state was fetched by pulse-wrapper.sh BEFORE the pulse started."
		echo "Do NOT re-fetch — act on this data directly. See pulse.md Step 2."
		echo ""
		local i=0
		while [[ -f "${tmpdir}/${i}.txt" ]]; do
			cat "${tmpdir}/${i}.txt"
			i=$((i + 1))
		done
	} >"$STATE_FILE"
	return 0
}

#######################################
# Append sub-helper data sections to STATE_FILE (GH#5627)
#
# Runs each sub-helper with individual timeouts. If a helper times out,
# the pulse proceeds without that section — degraded but functional.
# Shell functions that only read local state run directly (instant).
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
#######################################
#######################################
# Run a prefetch sub-command with timeout and append output to a target file.
# Encapsulates the repeated pattern: mktemp → run_cmd_with_timeout → cat → rm.
# Arguments:
#   $1 - timeout in seconds
#   $2 - target file to append output to
#   $3 - label for log messages
#   $4..N - command and arguments to run
#######################################
_run_prefetch_step() {
	local timeout="$1"
	local target_file="$2"
	local label="$3"
	shift 3

	local tmp_file
	tmp_file=$(mktemp)
	run_cmd_with_timeout "$timeout" "$@" >"$tmp_file" 2>/dev/null || {
		echo "[pulse-wrapper] ${label} timed out after ${timeout}s (non-fatal)" >>"$LOGFILE"
	}
	cat "$tmp_file" >>"$target_file"
	rm -f "$tmp_file"
	return 0
}

_append_prefetch_sub_helpers() {
	local repo_entries="$1"

	# Append mission state (reads local files — fast)
	prefetch_missions "$repo_entries" >>"$STATE_FILE"

	# Append active worker snapshot for orphaned PR detection (t216, local ps — fast)
	prefetch_active_workers >>"$STATE_FILE"

	# Append repo hygiene data for LLM triage (t1417)
	# Total prefetch budget: 60s (parallel) + 30s + 30s + 30s = 150s max,
	# well within the 600s stage timeout.
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_hygiene" prefetch_hygiene

	# Append CI failure patterns from notification mining (GH#4480)
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_ci_failures" prefetch_ci_failures

	# Append priority-class worker allocations (t1423, reads local file — fast)
	_append_priority_allocations >>"$STATE_FILE"

	# Append adaptive queue-governor guidance (t1455, local computation — fast)
	append_adaptive_queue_governor

	# Append external contribution watch summary (t1419, local state — fast)
	prefetch_contribution_watch >>"$STATE_FILE"

	# Append failed-notification systemic summary (t3960)
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_gh_failure_notifications" prefetch_gh_failure_notifications

	# Write needs-maintainer-review triage status to a SEPARATE file (t1894).
	# This data is used only by the deterministic dispatch_triage_reviews()
	# function — it must NOT appear in the LLM's STATE_FILE. NMR issues are
	# a security gate; the LLM should never see or act on them.
	# Uses overwrite (>) not append (>>) — triage file is written once per cycle.
	TRIAGE_STATE_FILE="${STATE_FILE%.txt}-triage.txt"
	local triage_tmp
	triage_tmp=$(mktemp)
	run_cmd_with_timeout 30 prefetch_triage_review_status "$repo_entries" >"$triage_tmp" 2>/dev/null || {
		echo "[pulse-wrapper] prefetch_triage_review_status timed out after 30s (non-fatal)" >>"$LOGFILE"
	}
	cat "$triage_tmp" >"$TRIAGE_STATE_FILE"
	rm -f "$triage_tmp"

	# Append status:needs-info contributor reply status
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_needs_info_replies" prefetch_needs_info_replies "$repo_entries"

	# Append FOSS contribution scan results (t1702)
	_run_prefetch_step "$FOSS_SCAN_TIMEOUT" "$STATE_FILE" "prefetch_foss_scan" prefetch_foss_scan

	return 0
}

#######################################
# Pre-fetch state for ALL pulse-enabled repos
#
# Runs gh pr list + gh issue list for each repo in parallel, formats
# a compact summary, and writes it to STATE_FILE. This is injected
# into the pulse prompt so the agent sees all repos from the start —
# preventing the "only processes first repo" problem.
#
# This is a deterministic data-fetch utility. The intelligence about
# what to DO with this data stays in pulse.md.
#######################################
########################################
# Check per-repo pulse schedule constraints (GH#6510)
#
# Enforces two optional repos.json fields:
#   pulse_hours: {"start": N, "end": N}  — 24h local time window
#   pulse_expires: "YYYY-MM-DD"          — ISO date after which pulse stops
#
# When pulse_expires is past today, this function atomically sets
# pulse: false in repos.json (temp file + mv) and returns 1 (skip).
# When pulse_hours is set and the current hour is outside the window,
# returns 1 (skip). Overnight windows (start > end, e.g., 17→5) are
# supported. Repos without either field always return 0 (include).
#
# Bash 3.2 compatible: no associative arrays, no bash 4+ features.
# date +%H returns zero-padded strings — strip with 10# prefix for
# arithmetic to avoid octal interpretation (e.g., 08 → 10#08 = 8).
#
# Arguments:
#   $1 - slug (owner/repo, for log messages)
#   $2 - pulse_hours_start (integer 0-23, or "" if not set)
#   $3 - pulse_hours_end   (integer 0-23, or "" if not set)
#   $4 - pulse_expires     (YYYY-MM-DD string, or "" if not set)
#   $5 - repos_json        (path to repos.json, for expiry auto-disable)
#
# Exit codes:
#   0 - repo is in schedule window (include in this pulse)
#   1 - repo is outside window or expired (skip this pulse)
########################################
check_repo_pulse_schedule() {
	local slug="$1"
	local ph_start="$2"
	local ph_end="$3"
	local expires="$4"
	local repos_json="$5"

	# --- pulse_expires check ---
	if [[ -n "$expires" ]]; then
		local today_date
		today_date=$(date +%Y-%m-%d)
		# String comparison works for ISO dates (lexicographic == chronological)
		if [[ "$today_date" > "$expires" ]]; then
			echo "[pulse-wrapper] pulse_expires reached for ${slug} (expires=${expires}, today=${today_date}) — auto-disabling pulse" >>"$LOGFILE"
			# Atomic write: temp file + mv (POSIX-guaranteed atomic on local fs)
			# Last-writer-wins is acceptable since expiry is idempotent.
			if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
				local tmp_json
				tmp_json=$(mktemp)
				if jq --arg slug "$slug" '
					.initialized_repos |= map(
						if .slug == $slug then .pulse = false else . end
					)
				' "$repos_json" >"$tmp_json" 2>/dev/null && jq empty "$tmp_json" 2>/dev/null; then
					mv "$tmp_json" "$repos_json"
					echo "[pulse-wrapper] Set pulse:false for ${slug} in repos.json (expiry auto-disable)" >>"$LOGFILE"
				else
					rm -f "$tmp_json"
					echo "[pulse-wrapper] WARNING: jq produced invalid JSON for ${slug} expiry — aborting write (GH#16746)" >>"$LOGFILE"
				fi
			fi
			return 1
		fi
	fi

	# --- pulse_hours check ---
	if [[ -n "$ph_start" && -n "$ph_end" ]]; then
		# Strip leading zeros before arithmetic to avoid octal interpretation
		# (bash treats 08/09 as invalid octal without the 10# prefix)
		local current_hour
		current_hour=$(date +%H)
		local cur ph_s ph_e
		cur=$((10#${current_hour}))
		ph_s=$((10#${ph_start}))
		ph_e=$((10#${ph_end}))

		local in_window=false
		if [[ "$ph_s" -le "$ph_e" ]]; then
			# Normal window (e.g., 9→17): in window when cur >= start AND cur < end
			if [[ "$cur" -ge "$ph_s" && "$cur" -lt "$ph_e" ]]; then
				in_window=true
			fi
		else
			# Overnight window (e.g., 17→5): in window when cur >= start OR cur < end
			if [[ "$cur" -ge "$ph_s" || "$cur" -lt "$ph_e" ]]; then
				in_window=true
			fi
		fi

		if [[ "$in_window" != "true" ]]; then
			echo "[pulse-wrapper] pulse_hours window ${ph_s}→${ph_e} not active for ${slug} (current hour: ${cur}) — skipping" >>"$LOGFILE"
			return 1
		fi
	fi

	return 0
}

prefetch_state() {
	local repos_json="$REPOS_JSON"

	if [[ ! -f "$repos_json" ]]; then
		echo "[pulse-wrapper] repos.json not found at $repos_json — skipping prefetch" >>"$LOGFILE"
		echo "ERROR: repos.json not found" >"$STATE_FILE"
		return 1
	fi

	echo "[pulse-wrapper] Pre-fetching state for all pulse-enabled repos..." >>"$LOGFILE"

	# Extract pulse-enabled, non-local-only repos as slug|path|ph_start|ph_end|expires
	# pulse_hours fields default to "" when absent; pulse_expires defaults to "".
	# Bash 3.2: no associative arrays — use pipe-delimited fields.
	local repo_entries_raw
	repo_entries_raw=$(jq -r '.initialized_repos[] |
		select(.pulse == true and (.local_only // false) == false and .slug != "") |
		[
			.slug,
			.path,
			(if .pulse_hours then (.pulse_hours.start | tostring) else "" end),
			(if .pulse_hours then (.pulse_hours.end   | tostring) else "" end),
			(.pulse_expires // "")
		] | join("|")
	' "$repos_json")

	# Filter repos through schedule check; build slug|path pairs for downstream use
	local repo_entries=""
	while IFS='|' read -r slug path ph_start ph_end expires; do
		[[ -n "$slug" ]] || continue
		if check_repo_pulse_schedule "$slug" "$ph_start" "$ph_end" "$expires" "$repos_json"; then
			if [[ -z "$repo_entries" ]]; then
				repo_entries="${slug}|${path}"
			else
				repo_entries="${repo_entries}"$'\n'"${slug}|${path}"
			fi
		fi
	done <<<"$repo_entries_raw"

	if [[ -z "$repo_entries" ]]; then
		echo "[pulse-wrapper] No pulse-enabled repos in schedule window" >>"$LOGFILE"
		echo "No pulse-enabled repos in schedule window in repos.json" >"$STATE_FILE"
		return 1
	fi

	# Temp dir for parallel fetches
	local tmpdir
	tmpdir=$(mktemp -d)

	# Launch parallel gh fetches for each repo
	local pids=()
	local idx=0
	while IFS='|' read -r slug path; do
		(
			_prefetch_single_repo "$slug" "$path" "${tmpdir}/${idx}.txt"
		) &
		pids+=($!)
		idx=$((idx + 1))
	done <<<"$repo_entries"

	# Wait for all parallel fetches with a hard timeout (t1482).
	# Each repo does 3 gh API calls (pr list, pr list --state all, issue list).
	# GH#15060: Raised from 60s to 120s. With 13 repos and repos having 100+ PRs,
	# the GraphQL responses are large and rate limiting serializes parallel calls.
	# 60s caused silent timeouts producing "Open PRs (0)" on large backlogs.
	_wait_parallel_pids 120 "${pids[@]}"

	# Assemble state file in repo order
	_assemble_state_file "$tmpdir"

	# Clean up
	rm -rf "$tmpdir"

	# t1482: Sub-helpers that call external scripts (gh API, pr-salvage,
	# gh-failure-miner) get individual timeouts via run_cmd_with_timeout.
	# If a helper times out, the pulse proceeds without that section —
	# degraded but functional. Shell functions that only read local state
	# (priority allocations, queue governor, contribution watch) run
	# directly since they complete instantly.
	_append_prefetch_sub_helpers "$repo_entries"

	# Export PULSE_SCOPE_REPOS — comma-separated list of repo slugs that
	# workers are allowed to create PRs/branches on (t1405, GH#2928).
	# Workers CAN file issues on any repo (cross-repo self-improvement),
	# but code changes (branches, PRs) are restricted to this list.
	local scope_slugs
	scope_slugs=$(echo "$repo_entries" | cut -d'|' -f1 | grep . | paste -sd ',' -)
	export PULSE_SCOPE_REPOS="$scope_slugs"
	echo "$scope_slugs" >"$SCOPE_FILE"
	echo "[pulse-wrapper] PULSE_SCOPE_REPOS=${scope_slugs}" >>"$LOGFILE"

	local repo_count
	repo_count=$(echo "$repo_entries" | wc -l | tr -d ' ')
	echo "[pulse-wrapper] Pre-fetched state for $repo_count repos → $STATE_FILE" >>"$LOGFILE"
	return 0
}

#######################################
# Pre-fetch active mission state files
#
# Scans todo/missions/ and ~/.aidevops/missions/ for mission.md files
# with status: active|paused|blocked|validating. Extracts a compact
# summary (id, status, current milestone, pending features) so the
# pulse agent can act on missions without reading full state files.
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: mission summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_missions() {
	local repo_entries="$1"
	local found_any=false

	# Collect mission files from repo-attached locations
	local mission_files=()
	while IFS='|' read -r slug path; do
		local missions_dir="${path}/todo/missions"
		if [[ -d "$missions_dir" ]]; then
			while IFS= read -r mfile; do
				[[ -n "$mfile" ]] && mission_files+=("${slug}|${path}|${mfile}")
			done < <(find "$missions_dir" -name "mission.md" -type f 2>/dev/null || true)
		fi
	done <<<"$repo_entries"

	# Also check homeless missions
	local homeless_dir="${HOME}/.aidevops/missions"
	if [[ -d "$homeless_dir" ]]; then
		while IFS= read -r mfile; do
			[[ -n "$mfile" ]] && mission_files+=("|homeless|${mfile}")
		done < <(find "$homeless_dir" -name "mission.md" -type f 2>/dev/null || true)
	fi

	if [[ ${#mission_files[@]} -eq 0 ]]; then
		return 0
	fi

	local active_count=0

	for entry in "${mission_files[@]}"; do
		local slug path mfile
		IFS='|' read -r slug path mfile <<<"$entry"

		# Extract frontmatter status — look for status: in YAML frontmatter
		local status
		status=$(_extract_frontmatter_field "$mfile" "status")

		# Only include active/paused/blocked/validating missions
		case "$status" in
		active | paused | blocked | validating) ;;
		*) continue ;;
		esac

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Active Missions"
			echo ""
			echo "Mission state files detected by pulse-wrapper.sh. See pulse.md Step 3.5."
			echo ""
			found_any=true
		fi

		local mission_id
		mission_id=$(_extract_frontmatter_field "$mfile" "id")
		local title
		title=$(_extract_frontmatter_field "$mfile" "title")
		local mode
		mode=$(_extract_frontmatter_field "$mfile" "mode")
		local mission_dir
		mission_dir=$(dirname "$mfile")

		echo "## Mission: ${mission_id} — ${title}"
		echo ""
		echo "- **Status:** ${status}"
		echo "- **Mode:** ${mode}"
		echo "- **Repo:** ${slug:-homeless}"
		echo "- **Path:** ${mfile}"
		echo ""

		# Extract milestone summaries — find lines matching "### Milestone N:"
		# and their status lines
		_extract_milestone_summary "$mfile"

		echo ""
		active_count=$((active_count + 1))
	done

	if [[ "$active_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Found $active_count active mission(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Extract a field value from YAML frontmatter
# Arguments:
#   $1 - file path
#   $2 - field name
# Output: field value to stdout (trimmed, comments stripped)
#######################################
_extract_frontmatter_field() {
	local file="$1"
	local field="$2"

	# Read frontmatter (between first --- and second ---)
	local in_frontmatter=false
	local value=""
	while IFS= read -r line; do
		if [[ "$line" == "---" ]]; then
			if [[ "$in_frontmatter" == true ]]; then
				break
			fi
			in_frontmatter=true
			continue
		fi
		if [[ "$in_frontmatter" == true ]]; then
			# Match field: value (strip inline comments and quotes)
			if [[ "$line" =~ ^${field}:[[:space:]]*(.*) ]]; then
				value="${BASH_REMATCH[1]}"
				# Strip inline comments (# ...)
				value="${value%%#*}"
				# Trim whitespace
				value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				# Strip surrounding quotes
				value="${value#\"}"
				value="${value%\"}"
				break
			fi
		fi
	done <"$file"

	echo "$value"
	return 0
}

#######################################
# Extract milestone summary from a mission state file
# Outputs a compact table of milestones and their feature statuses
# Arguments:
#   $1 - mission.md file path
# Output: milestone summary to stdout
#######################################
_extract_milestone_summary() {
	local file="$1"
	local current_milestone=""
	local milestone_status=""

	while IFS= read -r line; do
		# Detect milestone headers: ### Milestone N: Name
		if [[ "$line" =~ ^###[[:space:]]+Milestone[[:space:]]+([0-9]+):[[:space:]]+(.*) ]]; then
			current_milestone="${BASH_REMATCH[1]}: ${BASH_REMATCH[2]}"
		fi

		# Detect milestone status: **Status:** value
		if [[ -n "$current_milestone" && "$line" =~ \*\*Status:\*\*[[:space:]]*(.*) ]]; then
			milestone_status="${BASH_REMATCH[1]}"
			# Strip HTML comments
			milestone_status="${milestone_status%%<!--*}"
			milestone_status=$(echo "$milestone_status" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			echo "- **Milestone ${current_milestone}** — ${milestone_status}"
			current_milestone=""
		fi

		# Detect feature rows in tables: | N.N | Feature | tNNN | status | ...
		if [[ "$line" =~ ^\|[[:space:]]*([0-9]+\.[0-9]+)[[:space:]]*\|[[:space:]]*(.*)\|[[:space:]]*(t[0-9.]+)[[:space:]]*\|[[:space:]]*([a-z]+)[[:space:]]*\| ]]; then
			local feat_num="${BASH_REMATCH[1]}"
			local feat_name="${BASH_REMATCH[2]}"
			local task_id="${BASH_REMATCH[3]}"
			local feat_status="${BASH_REMATCH[4]}"
			# Trim feature name
			feat_name=$(echo "$feat_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			echo "  - F${feat_num}: ${feat_name} (${task_id}) — ${feat_status}"
		fi
	done <"$file"
	return 0
}

# _compute_struggle_ratio provided by worker-lifecycle-common.sh

#######################################
# Check and flag external-contributor PRs (t1391)
#
# Deterministic idempotency guard for the external-contributor comment.
# Moved from pulse.md inline bash to a shell function because the LLM
# kept getting the fail-closed logic wrong (4 prior fix attempts:
# PRs #2794, #2796, #2801, #2803 — all in pulse.md prompt text).
#
# This is exactly the kind of logic that belongs in the harness, not
# the prompt: it has one correct answer regardless of context.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login
#
# Exit codes:
#   0 - already flagged (label or comment exists) — no action needed
#   1 - not yet flagged AND API calls succeeded — caller should post
#   2 - API error (fail closed) — caller must skip, next pulse retries
#
# Side effects when exit=1 (caller invokes with --post):
#   Posts the external-contributor comment and adds the label.
#######################################
check_external_contributor_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local do_post="${4:-}"

	# Validate arguments
	if [[ -z "$pr_number" || -z "$repo_slug" || -z "$pr_author" ]]; then
		echo "[pulse-wrapper] check_external_contributor_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Step 1: Check for existing label (capture exit code separately from output)
	local label_output
	label_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels --jq '.labels[].name')
	local label_exit=$?

	local has_label=false
	if [[ $label_exit -eq 0 ]] && echo "$label_output" | grep -q '^external-contributor$'; then
		has_label=true
	fi

	# Step 2: Check for existing comment
	local comment_output
	comment_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local comment_exit=$?

	local has_comment=false
	if [[ $comment_exit -eq 0 ]] && echo "$comment_output" | grep -qiF 'external contributor'; then
		has_comment=true
	fi

	# Step 3: Decide action based on results
	if [[ $label_exit -ne 0 || $comment_exit -ne 0 ]]; then
		# API error on label or comment check — fail closed, skip posting entirely.
		# The next pulse cycle will retry. Never post when we can't confirm absence.
		echo "[pulse-wrapper] check_external_contributor_pr: API error (label_exit=$label_exit, comment_exit=$comment_exit) for PR #$pr_number in $repo_slug — skipping (fail closed)" >>"$LOGFILE"
		return 2
	fi

	if [[ "$has_label" == "true" || "$has_comment" == "true" ]]; then
		# Already flagged. Re-add label if missing (comment exists but label doesn't).
		if [[ "$has_label" == "false" ]]; then
			gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
				-X POST -f 'labels[]=external-contributor' || true
		fi
		return 0
	fi

	# Both API calls succeeded AND neither label nor comment exists.
	if [[ "$do_post" == "--post" ]]; then
		# Safe to post — this is the only code path that creates a comment.
		gh pr comment "$pr_number" --repo "$repo_slug" \
			--body "This PR is from an external contributor (@${pr_author}). Auto-merge is disabled for external PRs — a maintainer must review and approve manually.

---
**To approve or decline**, comment on this PR:
- \`approved\` — removes the review gate and allows merge (CI permitting)
- \`declined: <reason>\` — closes this PR (include your reason after the colon)" &&
			gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
				-X POST -f 'labels[]=external-contributor' \
				-f 'labels[]=needs-maintainer-review' || true
		echo "[pulse-wrapper] check_external_contributor_pr: flagged PR #$pr_number in $repo_slug as external contributor (@$pr_author)" >>"$LOGFILE"
	fi
	return 1
}

#######################################
# Check and post permission-failure comment on a PR (t1391)
#
# Companion to check_external_contributor_pr() for the case where the
# collaborator permission API itself fails (403, 429, 5xx, network error).
# Posts a distinct "Permission check failed" comment so a maintainer
# knows to review manually. Idempotent — checks for existing comment
# before posting, fails closed on API errors.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login
#   $4 - HTTP status code from the failed permission check
#
# Exit codes:
#   0 - comment already exists or was just posted
#   2 - API error checking for existing comment (fail closed, skip)
#######################################
check_permission_failure_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local http_status="${4:-unknown}"

	if [[ -z "$pr_number" || -z "$repo_slug" || -z "$pr_author" ]]; then
		echo "[pulse-wrapper] check_permission_failure_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Check for existing permission-failure comment (fail closed on API error)
	local perm_comments
	perm_comments=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local perm_exit=$?

	if [[ $perm_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_permission_failure_pr: API error (exit=$perm_exit) for PR #$pr_number in $repo_slug — skipping (fail closed)" >>"$LOGFILE"
		return 2
	fi

	if echo "$perm_comments" | grep -qF 'Permission check failed'; then
		# Already posted — nothing to do
		return 0
	fi

	# Safe to post — no existing comment and API call succeeded
	gh pr comment "$pr_number" --repo "$repo_slug" \
		--body "Permission check failed for this PR (HTTP ${http_status} from collaborator permission API). Unable to determine if @${pr_author} is a maintainer or external contributor. **A maintainer must review and merge this PR manually.** This is a fail-closed safety measure — the pulse will not auto-merge until the permission API succeeds." || true

	echo "[pulse-wrapper] check_permission_failure_pr: posted permission-failure comment on PR #$pr_number in $repo_slug (HTTP $http_status)" >>"$LOGFILE"
	return 0
}

#######################################
# Auto-approve a collaborator's PR before merging (GH#10522, t1691)
#
# Branch protection requires required_approving_review_count=1.
# The pulse runs with the repo admin's token, which can approve PRs.
# This function approves the PR so that gh pr merge succeeds.
#
# SAFETY: Only call this AFTER the external contributor gate has
# confirmed the PR author is a collaborator (admin/maintain/write).
# NEVER call this for external contributor PRs.
#
# Idempotent — if the PR already has an approving review from the
# current user, this is a no-op (GitHub ignores duplicate approvals).
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login (for logging only)
#
# Exit codes:
#   0 - PR approved (or already approved)
#   1 - approval failed (caller should skip merge this cycle)
#   2 - missing arguments
#######################################
approve_collaborator_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="${3:-unknown}"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] approve_collaborator_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Check if we already approved (avoid noisy duplicate approvals in the timeline)
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")

	if [[ -n "$current_user" ]]; then
		# Skip self-approval — GitHub rejects it and the failed review state
		# blocks subsequent --admin merge. Admin bypass works without approval
		# when the PR author is the authenticated user (repo admin).
		if [[ "$current_user" == "$pr_author" ]]; then
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number is self-authored ($current_user) — skipping approval (--admin handles it)" >>"$LOGFILE"
			return 0
		fi

		# Guard: only collaborators (write/maintain/admin) may approve.
		# Non-collaborator approvals are accepted by GitHub on public repos
		# but don't count toward branch protection — they just create noise.
		if ! _is_collaborator_author "$current_user" "$repo_slug"; then
			echo "[pulse-wrapper] approve_collaborator_pr: current user ($current_user) lacks write access to $repo_slug — skipping approval" >>"$LOGFILE"
			return 0
		fi

		local existing_approval
		existing_approval=$(gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" \
			--jq "[.[] | select(.user.login == \"${current_user}\" and .state == \"APPROVED\")] | length" 2>/dev/null || echo "0")

		if [[ "$existing_approval" -gt 0 ]]; then
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number in $repo_slug already approved by $current_user — skipping" >>"$LOGFILE"
			return 0
		fi
	fi

	# Approve the PR
	local approve_output
	approve_output=$(gh pr review "$pr_number" --repo "$repo_slug" --approve --body "Auto-approved by pulse — collaborator PR (author: @${pr_author}). All pre-merge checks passed." 2>&1)
	local approve_exit=$?

	if [[ $approve_exit -eq 0 ]]; then
		echo "[pulse-wrapper] approve_collaborator_pr: approved PR #$pr_number in $repo_slug (author: $pr_author)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] approve_collaborator_pr: failed to approve PR #$pr_number in $repo_slug — $approve_output" >>"$LOGFILE"
	return 1
}

#######################################
# Check if a PR modifies GitHub Actions workflow files (t3934)
#
# PRs that modify .github/workflows/ files require the `workflow` scope
# on the GitHub OAuth token. Without it, `gh pr merge` fails with:
#   "refusing to allow an OAuth App to create or update workflow ... without workflow scope"
#
# This function checks the PR's changed files for workflow modifications
# so the pulse can skip auto-merge and post a helpful comment instead of
# failing with a cryptic GraphQL error.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Exit codes:
#   0 - PR modifies workflow files
#   1 - PR does NOT modify workflow files
#   2 - API error (fail open — let merge attempt proceed)
#######################################
check_pr_modifies_workflows() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: missing arguments" >>"$LOGFILE"
		return 2
	fi

	local files_output
	files_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path')
	local files_exit=$?

	if [[ $files_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: API error (exit=$files_exit) for PR #$pr_number in $repo_slug — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$files_output" | grep -qE '^\.github/workflows/'; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: PR #$pr_number in $repo_slug modifies workflow files" >>"$LOGFILE"
		return 0
	fi

	return 1
}

#######################################
# Check if the current GitHub token has the `workflow` scope (t3934)
#
# The `workflow` scope is required to merge PRs that modify
# .github/workflows/ files. This function checks the current
# token's scopes via `gh auth status`.
#
# Exit codes:
#   0 - token HAS workflow scope
#   1 - token does NOT have workflow scope
#   2 - unable to determine (fail open)
#######################################
check_gh_workflow_scope() {
	local auth_output
	auth_output=$(gh auth status 2>&1)
	local auth_exit=$?

	if [[ $auth_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_gh_workflow_scope: gh auth status failed (exit=$auth_exit) — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$auth_output" | grep -q "'workflow'"; then
		return 0
	fi

	# Also check for the scope without quotes (format varies by gh version)
	if echo "$auth_output" | grep -qiE 'Token scopes:.*workflow'; then
		return 0
	fi

	echo "[pulse-wrapper] check_gh_workflow_scope: token lacks workflow scope" >>"$LOGFILE"
	return 1
}

#######################################
# Guard merge of PRs that modify workflow files (t3934)
#
# Combines check_pr_modifies_workflows() and check_gh_workflow_scope()
# into a single pre-merge guard. If the PR modifies workflow files and
# the token lacks the workflow scope, posts a comment explaining the
# issue and how to fix it. Idempotent — checks for existing comment.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Exit codes:
#   0 - safe to merge (no workflow files, or token has scope)
#   1 - blocked (workflow files + missing scope, comment posted)
#   2 - API error (fail open — let merge attempt proceed)
#######################################
check_workflow_merge_guard() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_workflow_merge_guard: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Step 1: Check if PR modifies workflow files
	check_pr_modifies_workflows "$pr_number" "$repo_slug"
	local wf_exit=$?

	if [[ $wf_exit -eq 1 ]]; then
		# No workflow files modified — safe to merge
		return 0
	fi

	if [[ $wf_exit -eq 2 ]]; then
		# API error — fail open, let merge attempt proceed
		return 2
	fi

	# Step 2: PR modifies workflow files — check token scope
	check_gh_workflow_scope
	local scope_exit=$?

	if [[ $scope_exit -eq 0 ]]; then
		# Token has workflow scope — safe to merge
		return 0
	fi

	if [[ $scope_exit -eq 2 ]]; then
		# Unable to determine — fail open
		return 2
	fi

	# Step 3: PR modifies workflows AND token lacks scope — check for existing comment
	local comments_output
	comments_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local comments_exit=$?

	if [[ $comments_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_workflow_merge_guard: API error reading comments for PR #$pr_number — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$comments_output" | grep -qF 'workflow scope'; then
		# Already commented — still blocked
		echo "[pulse-wrapper] check_workflow_merge_guard: PR #$pr_number already has workflow scope comment — skipping merge" >>"$LOGFILE"
		return 1
	fi

	# Post comment explaining the issue
	gh pr comment "$pr_number" --repo "$repo_slug" \
		--body "**Cannot auto-merge: workflow scope required** (GH#3934)

This PR modifies \`.github/workflows/\` files but the GitHub OAuth token used by the pulse lacks the \`workflow\` scope. GitHub requires this scope to merge PRs that modify workflow files.

**To fix:**
1. Run \`gh auth refresh -s workflow\` to add the \`workflow\` scope to your token
2. The next pulse cycle will merge this PR automatically

**Alternatively:** Merge manually via the GitHub UI." ||
		true

	# Add a label for visibility
	gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
		-X POST -f 'labels[]=needs-workflow-scope' || true

	echo "[pulse-wrapper] check_workflow_merge_guard: blocked PR #$pr_number in $repo_slug — workflow files + missing scope" >>"$LOGFILE"
	return 1
}

#######################################
# Pre-fetch active worker processes (t216, t1367)
#
# Captures a snapshot of running worker processes so the pulse agent
# can cross-reference open PRs with active workers. This is the
# deterministic data-fetch part — the intelligence about which PRs
# are orphaned stays in pulse.md.
#
# t1367: Also computes struggle_ratio for each worker with a worktree.
# High ratio = active but unproductive (thrashing). Informational only.
#
# Output: worker summary to stdout (appended to STATE_FILE by caller)
#######################################
# list_active_worker_processes: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate divergence with stats-functions.sh.
# See worker-lifecycle-common.sh for the canonical implementation with:
#   - process chain deduplication (t5072)
#   - headless-runtime-helper.sh wrapper support (GH#12361, GH#14944)
#   - zombie/stopped process filtering (GH#6413)

prefetch_active_workers() {
	local worker_lines
	worker_lines=$(list_active_worker_processes || true)

	echo ""
	echo "# Active Workers"
	echo ""
	echo "Snapshot of running worker processes at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
	echo "Use this to determine whether a PR has an active worker (not orphaned)."
	echo "Struggle ratio: messages/max(1,commits) — high ratio + time = thrashing. See pulse.md."
	echo ""

	if [[ -z "$worker_lines" ]]; then
		echo "- No active workers"
	else
		local count
		count=$(echo "$worker_lines" | wc -l | tr -d ' ')
		echo "### Running Workers ($count)"
		echo ""
		echo "$worker_lines" | while IFS= read -r line; do
			local pid etime cmd
			read -r pid etime cmd <<<"$line"

			# Compute elapsed seconds for struggle ratio.
			# This is the AUTHORITATIVE process age — use it for kill comments.
			# Do NOT compute duration from dispatch comment timestamps or
			# branch/worktree creation times, which may reflect prior attempts.
			local elapsed_seconds
			elapsed_seconds=$(_get_process_age "$pid")
			local formatted_duration
			formatted_duration=$(_format_duration "$elapsed_seconds")

			# Compute struggle ratio (t1367)
			local sr_result
			sr_result=$(_compute_struggle_ratio "$pid" "$elapsed_seconds" "$cmd")
			local sr_ratio sr_commits sr_messages sr_flag
			IFS='|' read -r sr_ratio sr_commits sr_messages sr_flag <<<"$sr_result"

			local sr_display=""
			if [[ "$sr_ratio" != "n/a" ]]; then
				sr_display=" [struggle_ratio: ${sr_ratio} (${sr_messages}msgs/${sr_commits}commits)"
				if [[ -n "$sr_flag" ]]; then
					sr_display="${sr_display} **${sr_flag}**"
				fi
				sr_display="${sr_display}]"
			fi

			echo "- PID $pid (process_uptime: ${formatted_duration}, elapsed_seconds: ${elapsed_seconds}): $cmd${sr_display}"
		done
	fi

	echo ""
	return 0
}

#######################################
# Pre-fetch CI failure patterns from notification mining (GH#4480)
#
# Runs gh-failure-miner-helper.sh prefetch to detect systemic CI
# failures across managed repos. The prefetch command mines ci_activity
# notifications (which contribution-watch-helper.sh explicitly excludes)
# and identifies checks that fail on multiple PRs — indicating workflow
# bugs rather than per-PR code issues.
#
# Previously used the removed 'scan' command (GH#4586). Now uses
# 'prefetch' which is the correct supported command.
#
# Output: CI failure summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_ci_failures() {
	local miner_script="${SCRIPT_DIR}/gh-failure-miner-helper.sh"

	if [[ ! -x "$miner_script" ]]; then
		echo ""
		echo "# CI Failure Patterns: miner script not found"
		echo ""
		return 0
	fi

	# Guard: verify the helper supports the 'prefetch' command before calling.
	# If the contract drifts again, this produces a clear compatibility warning
	# rather than a silent [ERROR] Unknown command in the log.
	if ! "$miner_script" --help 2>&1 | grep -q 'prefetch'; then
		echo "[pulse-wrapper] gh-failure-miner-helper.sh does not support 'prefetch' command — skipping CI failure prefetch (compatibility warning)" >>"$LOGFILE"
		echo ""
		echo "# CI Failure Patterns: helper command contract mismatch (see pulse.log)"
		echo ""
		return 0
	fi

	# Run prefetch — outputs compact pulse-ready summary to stdout
	"$miner_script" prefetch \
		--pulse-repos \
		--since-hours "$GH_FAILURE_PREFETCH_HOURS" \
		--limit "$GH_FAILURE_PREFETCH_LIMIT" \
		--systemic-threshold "$GH_FAILURE_SYSTEMIC_THRESHOLD" \
		--max-run-logs "$GH_FAILURE_MAX_RUN_LOGS" 2>/dev/null || {
		echo ""
		echo "# CI Failure Patterns: prefetch failed (non-fatal)"
		echo ""
	}

	return 0
}

#######################################
# Append priority-class worker allocations to state file (t1423)
#
# Reads the allocation file written by calculate_priority_allocations()
# and formats it as a section the pulse agent can act on.
#
# The pulse agent uses this to enforce soft reservations: product repos
# get a guaranteed minimum share of worker slots, tooling gets the rest.
# When one class has no pending work, the other can use freed slots.
#
# Output: allocation summary to stdout (appended to STATE_FILE by caller)
#######################################
_append_priority_allocations() {
	local alloc_file="${HOME}/.aidevops/logs/pulse-priority-allocations"

	echo ""
	echo "# Priority-Class Worker Allocations (t1423)"
	echo ""

	if [[ ! -f "$alloc_file" ]]; then
		echo "- Allocation data not available — using flat pool (no reservations)"
		echo ""
		return 0
	fi

	# Read allocation values
	local max_workers product_repos tooling_repos dispatchable_product_repos product_min tooling_max reservation_pct quality_debt_cap_pct
	max_workers=$(grep '^MAX_WORKERS=' "$alloc_file" | cut -d= -f2) || max_workers=4
	product_repos=$(grep '^PRODUCT_REPOS=' "$alloc_file" | cut -d= -f2) || product_repos=0
	tooling_repos=$(grep '^TOOLING_REPOS=' "$alloc_file" | cut -d= -f2) || tooling_repos=0
	dispatchable_product_repos=$(grep '^DISPATCHABLE_PRODUCT_REPOS=' "$alloc_file" | cut -d= -f2) || dispatchable_product_repos="$product_repos"
	product_min=$(grep '^PRODUCT_MIN=' "$alloc_file" | cut -d= -f2) || product_min=0
	tooling_max=$(grep '^TOOLING_MAX=' "$alloc_file" | cut -d= -f2) || tooling_max=0
	reservation_pct=$(grep '^PRODUCT_RESERVATION_PCT=' "$alloc_file" | cut -d= -f2) || reservation_pct=60
	quality_debt_cap_pct=$(grep '^QUALITY_DEBT_CAP_PCT=' "$alloc_file" | cut -d= -f2) || quality_debt_cap_pct=30

	echo "Worker pool: **${max_workers}** total slots"
	echo "Product repos (${product_repos}, dispatchable now: ${dispatchable_product_repos}): **${product_min}** reserved slots (${reservation_pct}% target minimum)"
	echo "Tooling repos (${tooling_repos}): **${tooling_max}** slots (remainder)"
	echo "Quality-debt cap: **${quality_debt_cap_pct}%** of worker pool"
	echo ""
	echo "**Enforcement rules:**"
	echo "- Reservations are soft targets, not hard gates. If one class has no dispatchable candidates, immediately reassign its unused slots to the other class."
	echo "- Product repos at daily PR cap are treated as temporarily non-dispatchable for reservation purposes."
	echo "- Do not leave slots idle when runnable scoped work exists in any class."
	echo "- If all ${max_workers} slots are needed for product work, tooling gets 0 (product reservation is a minimum, not a maximum)."
	echo "- Merges (priority 1) and CI fixes (priority 2) are exempt — they always proceed regardless of class."
	echo ""

	return 0
}

#######################################
# Pre-fetch repo hygiene data for LLM triage (t1417)
#
# Appends a "Repo Hygiene" section to the state file with:
#   1. Orphan worktrees — branches with 0 commits ahead of main,
#      no PR (open or merged), and no active worker process.
#   2. Stash summary — count of needs-review stashes per repo.
#   3. Uncommitted changes on main — repos with dirty main worktree.
#
# This data enables the pulse LLM to make intelligent triage decisions
# about cleanup. Deterministic cleanup (merged-PR worktrees, safe stashes)
# is handled by cleanup_worktrees() and cleanup_stashes() before this runs.
# What remains here requires judgment.
#
# Output: hygiene summary to stdout (appended to STATE_FILE by caller)
#######################################
#######################################
# Check a single repo for hygiene issues (GH#5627, extracted from prefetch_hygiene)
#
# Checks for orphan worktrees, stale stashes, and uncommitted changes
# on the default branch. Returns issue descriptions via stdout.
#
# Arguments:
#   $1 - repo_path
#   $2 - repos_json path (for slug lookup)
# Output: issue lines to stdout (empty if no issues)
#######################################
_check_repo_hygiene() {
	local repo_path="$1"
	local repos_json="$2"
	local repo_issues=""

	# 1. Orphan worktrees: 0 commits ahead of default branch, no PR
	local default_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || default_branch="main"
	[[ -z "$default_branch" ]] && default_branch="main"

	local wt_branch wt_path
	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			wt_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			wt_branch="${BASH_REMATCH[1]}"
		elif [[ -z "$line" && -n "$wt_branch" ]]; then
			# Skip the default branch
			if [[ "$wt_branch" != "$default_branch" ]]; then
				local commits_ahead
				commits_ahead=$(git -C "$repo_path" rev-list --count "${default_branch}..${wt_branch}" 2>/dev/null) || commits_ahead="?"

				if [[ "$commits_ahead" == "0" ]]; then
					# Check if any PR exists (open or merged)
					local has_pr="false"
					if command -v gh &>/dev/null; then
						local pr_check
						pr_check=$(gh pr list --repo "$(jq -r --arg p "$repo_path" '.initialized_repos[] | select(.path == $p) | .slug' "$repos_json" 2>/dev/null)" \
							--head "$wt_branch" --state all --json number --jq 'length' 2>/dev/null) || pr_check="0"
						[[ "${pr_check:-0}" -gt 0 ]] && has_pr="true"
					fi

					if [[ "$has_pr" == "false" ]]; then
						# Check for dirty state
						local dirty=""
						local change_count
						change_count=$(git -C "${wt_path:-$repo_path}" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || change_count=0
						[[ "${change_count:-0}" -gt 0 ]] && dirty=" (${change_count} uncommitted files)"

						repo_issues="${repo_issues}  - Orphan worktree: \`${wt_branch}\` — 0 commits, no PR${dirty} (${wt_path})\n"
					fi
				fi
			fi
			wt_path=""
			wt_branch=""
		fi
	done < <(
		git -C "$repo_path" worktree list --porcelain 2>/dev/null
		echo ""
	)

	# 2. Stash summary (needs-review count)
	local stash_count
	stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
	if [[ "${stash_count:-0}" -gt 0 ]]; then
		repo_issues="${repo_issues}  - ${stash_count} stash(es) remaining (safe-to-drop already cleaned; these need review)\n"
	fi

	# 3. Uncommitted changes on main worktree
	local main_wt_path="$repo_path"
	local current_branch
	current_branch=$(git -C "$main_wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch=""
	if [[ "$current_branch" == "$default_branch" ]]; then
		local main_dirty
		main_dirty=$(git -C "$main_wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || main_dirty=0
		if [[ "${main_dirty:-0}" -gt 0 ]]; then
			repo_issues="${repo_issues}  - ${main_dirty} uncommitted file(s) on ${default_branch} branch\n"
		fi
	fi

	echo -n "$repo_issues"
	return 0
}

#######################################
# Scan for salvageable closed-unmerged PRs (GH#5627, extracted from prefetch_hygiene)
#
# Arguments:
#   $1 - repos_json path
# Output: salvage summary to stdout
#######################################
_scan_pr_salvage() {
	local repos_json="$1"
	local salvage_helper="${SCRIPT_DIR}/pr-salvage-helper.sh"

	if [[ ! -x "$salvage_helper" ]]; then
		return 0
	fi

	echo ""
	echo "# PR Salvage (closed-unmerged with recoverable code)"
	echo ""

	local salvage_found=false
	local slug path
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		local salvage_output
		salvage_output=$("$salvage_helper" prefetch "$slug" "$path" 2>/dev/null) || true
		if [[ -n "$salvage_output" ]]; then
			salvage_found=true
			echo "$salvage_output"
		fi
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$salvage_found" == "false" ]]; then
		echo "- No salvageable closed-unmerged PRs detected"
		echo ""
	fi

	return 0
}

prefetch_hygiene() {
	local repos_json="${HOME}/.config/aidevops/repos.json"

	echo ""
	echo "# Repo Hygiene"
	echo ""
	echo "Non-deterministic cleanup candidates requiring LLM assessment."
	echo "Merged-PR worktrees and safe-to-drop stashes were already cleaned by the shell layer."
	echo ""

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "- repos.json not available — skipping hygiene prefetch"
		echo ""
		return 0
	fi

	local repo_paths
	repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

	local found_any=false

	local repo_path
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		[[ ! -d "$repo_path/.git" ]] && continue

		local repo_name
		repo_name=$(basename "$repo_path")

		local repo_issues
		repo_issues=$(_check_repo_hygiene "$repo_path" "$repos_json")

		# Output repo section if any issues found
		if [[ -n "$repo_issues" ]]; then
			found_any=true
			echo "### ${repo_name}"
			echo -e "$repo_issues"
		fi
	done <<<"$repo_paths"

	if [[ "$found_any" == "false" ]]; then
		echo "- All repos clean — no hygiene issues detected"
		echo ""
	fi

	_scan_pr_salvage "$repos_json"

	return 0
}

#######################################
# Process guard: kill child processes exceeding RSS or runtime limits (t1398)
#
# Scans all child processes of the current pulse (and their descendants)
# for resource violations. ShellCheck processes get stricter limits due
# to their known exponential expansion risk (see t1398.2).
#
# This is a secondary defense — the primary defense is the hardened
# ShellCheck invocation (no -x, --norc, per-file timeout, ulimit -v).
# This guard catches any ShellCheck process that escapes those limits.
#
# Called from the watchdog loop inside run_pulse() every 60s.
#
# Arguments:
#   $1 - (optional) PID of the primary pulse process to exempt from
#        CHILD_RUNTIME_LIMIT (governed by PULSE_STALE_THRESHOLD instead)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
guard_child_processes() {
	local pulse_pid="${1:-}"
	local killed=0
	local total_freed_mb=0

	# Get all descendant PIDs of the current shell process.
	# Use 'command' (full command line) instead of 'comm' (basename only)
	# so that patterns like 'node.*opencode' can match. (CodeRabbit review)
	local descendants
	descendants=$(ps -eo pid,ppid,rss,etime,command | awk -v parent=$$ '
		BEGIN { pids[parent]=1 }
		{ if ($2 in pids) { pids[$1]=1; print $0 } }
	') || return 0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		# Fields from ps -eo pid,ppid,rss,etime,command
		# command is last and may contain spaces — read captures the rest
		local pid _ppid rss etime cmd_full
		read -r pid _ppid rss etime cmd_full <<<"$line"

		# Validate numeric fields
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0

		local age_seconds
		age_seconds=$(_get_process_age "$pid")

		# Extract basename for limit selection (e.g., /usr/bin/shellcheck → shellcheck)
		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"

		# Determine limits: ShellCheck gets stricter limits
		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi

		local violation=""
		if [[ "$rss" -gt "$rss_limit" ]]; then
			local rss_mb=$((rss / 1024))
			local limit_mb=$((rss_limit / 1024))
			violation="RSS ${rss_mb}MB > ${limit_mb}MB limit"
		elif [[ -n "$pulse_pid" && "$pid" == "$pulse_pid" ]]; then
			# Primary pulse process — runtime governed by PULSE_STALE_THRESHOLD,
			# not CHILD_RUNTIME_LIMIT. Skip runtime check but keep RSS check.
			:
		elif [[ "$age_seconds" -gt "$runtime_limit" ]]; then
			violation="runtime ${age_seconds}s > ${runtime_limit}s limit"
		fi

		if [[ -n "$violation" ]]; then
			local rss_mb=$((rss / 1024))
			# Sanitise cmd_base before logging to prevent log injection via
			# crafted process names containing control characters. (GH#2892)
			local safe_cmd_base
			safe_cmd_base=$(_sanitize_log_field "$cmd_base")
			echo "[pulse-wrapper] Process guard: killing PID $pid ($safe_cmd_base) — $violation" >>"$LOGFILE"
			_kill_tree "$pid" || true
			sleep 1
			if kill -0 "$pid" 2>/dev/null; then
				_force_kill_tree "$pid" || true
			fi
			killed=$((killed + 1))
			total_freed_mb=$((total_freed_mb + rss_mb))
		fi
	done <<<"$descendants"

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Process guard: killed $killed process(es), freed ~${total_freed_mb}MB" >>"$LOGFILE"
	fi
	return 0
}

# check_session_count: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate the duplicate. The shared version
# returns the count; callers handle warning logs independently.

#######################################
# Run a command with a per-call timeout (t1482)
#
# Lighter than run_stage_with_timeout — no logging, no stage semantics.
# Designed for sub-helpers inside prefetch_state that can hang on gh API
# calls. Kills the entire process group on timeout.
#
# Arguments:
#   $1 - timeout in seconds
#   $2..N - command and arguments
#
# Returns:
#   0   - command completed successfully
#   124 - command timed out and was killed
#   else- command exit code
#######################################
run_cmd_with_timeout() {
	local timeout_secs="$1"
	shift
	[[ "$timeout_secs" =~ ^[0-9]+$ ]] || timeout_secs=60

	"$@" &
	local cmd_pid=$!

	local elapsed=0
	while kill -0 "$cmd_pid" 2>/dev/null; do
		if [[ "$elapsed" -ge "$timeout_secs" ]]; then
			_kill_tree "$cmd_pid" || true
			sleep 1
			if kill -0 "$cmd_pid" 2>/dev/null; then
				_force_kill_tree "$cmd_pid" || true
			fi
			wait "$cmd_pid" 2>/dev/null || true
			return 124
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done

	wait "$cmd_pid"
	return $?
}

#######################################
# Run a stage with a wall-clock timeout
#
# Arguments:
#   $1 - stage name (for logs)
#   $2 - timeout seconds
#   $3... - command/function to execute
#
# Exit codes:
#   0   - stage completed successfully
#   124 - stage timed out and was killed
#   else- stage exited with command exit code
#######################################
run_stage_with_timeout() {
	local stage_name="$1"
	local timeout_seconds="$2"
	shift 2

	if [[ -z "$stage_name" ]] || [[ "$#" -lt 1 ]]; then
		echo "[pulse-wrapper] run_stage_with_timeout: invalid arguments" >>"$LOGFILE"
		return 1
	fi
	[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds="$PRE_RUN_STAGE_TIMEOUT"
	if [[ "$timeout_seconds" -lt 1 ]]; then
		timeout_seconds=1
	fi

	local stage_start
	stage_start=$(date +%s)
	echo "[pulse-wrapper] Stage start: ${stage_name} (timeout ${timeout_seconds}s)" >>"$LOGFILE"

	"$@" &
	local stage_pid=$!

	while kill -0 "$stage_pid" 2>/dev/null; do
		local now
		now=$(date +%s)
		local elapsed=$((now - stage_start))
		if [[ "$elapsed" -gt "$timeout_seconds" ]]; then
			echo "[pulse-wrapper] Stage timeout: ${stage_name} exceeded ${timeout_seconds}s (pid ${stage_pid})" >>"$LOGFILE"
			_kill_tree "$stage_pid" || true
			sleep 2
			if kill -0 "$stage_pid" 2>/dev/null; then
				_force_kill_tree "$stage_pid" || true
			fi
			wait "$stage_pid" 2>/dev/null || true
			return 124
		fi
		sleep 2
	done

	wait "$stage_pid"
	local stage_status=$?
	if [[ "$stage_status" -ne 0 ]]; then
		echo "[pulse-wrapper] Stage failed: ${stage_name} exited with ${stage_status}" >>"$LOGFILE"
		return "$stage_status"
	fi

	local stage_end
	stage_end=$(date +%s)
	echo "[pulse-wrapper] Stage complete: ${stage_name} (${stage_status}, $((stage_end - stage_start))s)" >>"$LOGFILE"
	return 0
}

#######################################
# Run the pulse — with internal watchdog timeout (t1397, t1398, t1398.3, GH#2958)
#
# The pulse runs until opencode exits naturally. A watchdog loop checks
# every 60s for three termination conditions:
#
#   1. Wall-clock timeout (t1397): kills if elapsed > PULSE_STALE_THRESHOLD.
#      This is the hard ceiling — no pulse should ever run longer than this.
#      Raised to 60 min (from 30 min) because quality sweeps across 8+ repos
#      legitimately need more time (GH#2958).
#
#   2. Idle detection (t1398.3): tracks consecutive seconds where the
#      process tree's CPU usage is below PULSE_IDLE_CPU_THRESHOLD. When
#      idle time exceeds PULSE_IDLE_TIMEOUT, the process is killed. This
#      catches the opencode idle-state bug much faster than the wall-clock
#      timeout — typically within 5 minutes of the pulse completing, vs
#      60 minutes for the stale threshold.
#
#   3. Progress detection (GH#2958): tracks whether the log file is growing.
#      If the log file size hasn't changed for PULSE_PROGRESS_TIMEOUT seconds,
#      the process is stuck — producing no output despite running. This catches
#      cases where CPU is nonzero (network I/O wait, spinning) but no actual
#      work is being done. Resets whenever new output appears.
#
# The watchdog also runs guard_child_processes() every 60s to kill any
# child process exceeding RSS or runtime limits (t1398).
#
# Previous design relied on the NEXT launchd invocation's check_dedup()
# to kill stale processes. This failed because launchd StartInterval only
# fires when the previous invocation has exited — and the wrapper blocks
# on `wait`, so the next invocation never starts. The watchdog is now
# internal to the same process that spawned opencode.
#######################################
#######################################
# Check watchdog termination conditions for a single poll iteration (GH#5627)
#
# Evaluates stop flag, wall-clock, progress, and idle conditions.
# Returns the kill reason via stdout (empty if no kill needed).
#
# Arguments (positional — avoids associative arrays for bash 3.2):
#   $1 - opencode_pid
#   $2 - start_epoch
#   $3 - effective_cold_start_timeout
#   $4 - last_log_size (current value)
#   $5 - progress_stall_seconds (current value)
#   $6 - has_seen_progress ("true" or "false")
#   $7 - idle_seconds (current value)
#
# Outputs (3 lines to stdout, read by caller):
#   Line 1: kill_reason (empty string if none)
#   Line 2: updated last_log_size
#   Line 3: updated progress_stall_seconds
#   Line 4: updated has_seen_progress
#   Line 5: updated idle_seconds
#######################################
#######################################
# Check log progress and detect stalls (GH#2958).
# Updates WD_LAST_LOG_SIZE, WD_PROGRESS_STALL_SECONDS,
# WD_HAS_SEEN_PROGRESS, WD_KILL_REASON via dynamic scoping.
# Arguments: $1=effective_cold_start_timeout
#######################################
_watchdog_check_progress() {
	local effective_cold_start_timeout="$1"

	local current_log_size=0
	if [[ -f "$LOGFILE" ]]; then
		current_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || echo "0")
		current_log_size="${current_log_size// /}"
	fi
	[[ "$current_log_size" =~ ^[0-9]+$ ]] || current_log_size=0

	# Log grew — process is making progress
	if [[ "$current_log_size" -gt "$WD_LAST_LOG_SIZE" ]]; then
		WD_HAS_SEEN_PROGRESS=true
		if [[ "$WD_PROGRESS_STALL_SECONDS" -gt 0 ]]; then
			echo "[pulse-wrapper] Progress resumed after ${WD_PROGRESS_STALL_SECONDS}s stall (log grew by $((current_log_size - WD_LAST_LOG_SIZE)) bytes)" >>"$LOGFILE"
		fi
		WD_LAST_LOG_SIZE="$current_log_size"
		WD_PROGRESS_STALL_SECONDS=0
		return 0
	fi

	# Log hasn't grown — increment stall counter
	WD_PROGRESS_STALL_SECONDS=$((WD_PROGRESS_STALL_SECONDS + 60))
	local progress_timeout="$PULSE_PROGRESS_TIMEOUT"
	if [[ "$WD_HAS_SEEN_PROGRESS" == false ]]; then
		progress_timeout="$effective_cold_start_timeout"
	fi

	if [[ "$WD_PROGRESS_STALL_SECONDS" -lt "$progress_timeout" ]]; then
		return 0
	fi

	if [[ "$WD_HAS_SEEN_PROGRESS" == false ]]; then
		WD_KILL_REASON="Pulse cold-start stalled for ${WD_PROGRESS_STALL_SECONDS}s — no first output (log size: ${current_log_size} bytes, threshold: ${effective_cold_start_timeout}s)"
	else
		WD_KILL_REASON="Pulse stalled for ${WD_PROGRESS_STALL_SECONDS}s — no log output (log size: ${current_log_size} bytes, threshold: ${PULSE_PROGRESS_TIMEOUT}s) (GH#2958)"
	fi
	return 0
}

#######################################
# Check CPU idle detection (t1398.3).
# Updates WD_IDLE_SECONDS, WD_KILL_REASON via dynamic scoping.
# Arguments: $1=opencode_pid
#######################################
_watchdog_check_idle() {
	local opencode_pid="$1"

	if [[ "$WD_HAS_SEEN_PROGRESS" != true ]]; then
		WD_IDLE_SECONDS=0
		return 0
	fi

	local tree_cpu
	tree_cpu=$(_get_process_tree_cpu "$opencode_pid")

	# Process is active — reset idle counter
	if [[ "$tree_cpu" -ge "$PULSE_IDLE_CPU_THRESHOLD" ]]; then
		if [[ "$WD_IDLE_SECONDS" -gt 0 ]]; then
			echo "[pulse-wrapper] Pulse active again (CPU ${tree_cpu}%) after ${WD_IDLE_SECONDS}s idle — resetting idle counter" >>"$LOGFILE"
		fi
		WD_IDLE_SECONDS=0
		return 0
	fi

	WD_IDLE_SECONDS=$((WD_IDLE_SECONDS + 60))
	if [[ "$WD_IDLE_SECONDS" -ge "$PULSE_IDLE_TIMEOUT" ]]; then
		WD_KILL_REASON="Pulse idle for ${WD_IDLE_SECONDS}s (CPU ${tree_cpu}% < ${PULSE_IDLE_CPU_THRESHOLD}%, threshold ${PULSE_IDLE_TIMEOUT}s) (t1398.3)"
	fi
	return 0
}

_check_watchdog_conditions() {
	local opencode_pid="$1"
	local start_epoch="$2"
	local effective_cold_start_timeout="$3"
	local last_log_size="$4"
	local progress_stall_seconds="$5"
	local has_seen_progress="$6"
	local idle_seconds="$7"

	local now
	now=$(date +%s)
	local elapsed=$((now - start_epoch))

	# Use WD_ prefixed vars for dynamic scoping with sub-helpers
	WD_KILL_REASON=""
	WD_LAST_LOG_SIZE="$last_log_size"
	WD_PROGRESS_STALL_SECONDS="$progress_stall_seconds"
	WD_HAS_SEEN_PROGRESS="$has_seen_progress"
	WD_IDLE_SECONDS="$idle_seconds"

	# Check 0: Stop flag — user ran `aidevops pulse stop` during this cycle (t2943)
	if [[ -f "$STOP_FLAG" ]]; then
		WD_KILL_REASON="Stop flag detected during active pulse — user requested stop"
	# Check 1: Wall-clock stale threshold (hard ceiling)
	elif [[ "$elapsed" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		WD_KILL_REASON="Pulse exceeded stale threshold (${elapsed}s > ${PULSE_STALE_THRESHOLD}s)"
	# Skip checks 2 and 3 during the first 3 minutes to allow startup/init.
	elif [[ "$elapsed" -ge 180 ]]; then
		_watchdog_check_progress "$effective_cold_start_timeout"
		if [[ -z "$WD_KILL_REASON" ]]; then
			_watchdog_check_idle "$opencode_pid"
		fi
	fi

	# Output updated state (one value per line for caller to read)
	echo "$WD_KILL_REASON"
	echo "$WD_LAST_LOG_SIZE"
	echo "$WD_PROGRESS_STALL_SECONDS"
	echo "$WD_HAS_SEEN_PROGRESS"
	echo "$WD_IDLE_SECONDS"
	return 0
}

#######################################
# Run the pulse watchdog loop (GH#5627, extracted from run_pulse)
#
# Polls every 60s for termination conditions and resource violations.
# Kills the pulse process when any condition triggers.
#
# Arguments:
#   $1 - opencode_pid
#   $2 - start_epoch
#   $3 - effective_cold_start_timeout
#######################################
_run_pulse_watchdog() {
	local opencode_pid="$1"
	local start_epoch="$2"
	local effective_cold_start_timeout="$3"
	local last_active_refill_epoch=0

	# Idle detection state (t1398.3)
	local idle_seconds=0

	# Progress detection state (GH#2958)
	local last_log_size=0
	local progress_stall_seconds=0
	local has_seen_progress=false
	if [[ -f "$LOGFILE" ]]; then
		last_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || echo "0")
		last_log_size="${last_log_size// /}"
	fi

	while ps -p "$opencode_pid" >/dev/null; do
		# Read watchdog state from the check function.
		# _check_watchdog_conditions outputs 5 lines; we read them back.
		# This avoids subshell variable scoping issues while keeping the
		# check logic in a testable function.
		local watchdog_output
		watchdog_output=$(_check_watchdog_conditions "$opencode_pid" "$start_epoch" \
			"$effective_cold_start_timeout" "$last_log_size" "$progress_stall_seconds" \
			"$has_seen_progress" "$idle_seconds")

		local kill_reason
		kill_reason=$(echo "$watchdog_output" | sed -n '1p')
		last_log_size=$(echo "$watchdog_output" | sed -n '2p')
		progress_stall_seconds=$(echo "$watchdog_output" | sed -n '3p')
		has_seen_progress=$(echo "$watchdog_output" | sed -n '4p')
		idle_seconds=$(echo "$watchdog_output" | sed -n '5p')

		# Single kill block — avoids duplicating the kill+force-kill sequence.
		if [[ -n "$kill_reason" ]]; then
			echo "[pulse-wrapper] ${kill_reason} — killing" >>"$LOGFILE"
			_kill_tree "$opencode_pid" || true
			sleep 2
			if kill -0 "$opencode_pid" 2>/dev/null; then
				_force_kill_tree "$opencode_pid" || true
			fi
			break
		fi

		# Process guard: kill children exceeding RSS/runtime limits (t1398)
		guard_child_processes "$opencode_pid"

		if [[ -z "$kill_reason" ]]; then
			last_active_refill_epoch=$(maybe_refill_underfilled_pool_during_active_pulse \
				"$last_active_refill_epoch" "$progress_stall_seconds" "$idle_seconds" "$has_seen_progress")
		fi
		# Sleep 60s then re-check. Portable across bash 3.2+ (macOS default).
		sleep 60
	done

	# Reap the process (may already be dead)
	wait "$opencode_pid" 2>/dev/null || true
	return 0
}

run_pulse() {
	local underfilled_mode="${1:-0}"
	local underfill_pct="${2:-0}"
	# trigger_mode: "daily_sweep" uses /pulse-sweep (full edge-case agent);
	# "stall" and "first_run" use /pulse (lightweight dispatch+merge agent).
	local trigger_mode="${3:-stall}"
	local effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT"
	if [[ "$underfilled_mode" == "1" ]]; then
		effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT_UNDERFILLED"
	fi
	[[ "$underfill_pct" =~ ^[0-9]+$ ]] || underfill_pct=0
	if [[ "$effective_cold_start_timeout" -gt "$PULSE_COLD_START_TIMEOUT" ]]; then
		effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT"
	fi

	local start_epoch
	start_epoch=$(date +%s)
	echo "[pulse-wrapper] Starting pulse at $(date -u +%Y-%m-%dT%H:%M:%SZ) (trigger=${trigger_mode})" >>"$WRAPPER_LOGFILE"
	echo "[pulse-wrapper] Watchdog cold-start timeout: ${effective_cold_start_timeout}s (underfilled_mode=${underfilled_mode}, underfill_pct=${underfill_pct})" >>"$LOGFILE"

	# Select agent prompt based on trigger mode:
	#   daily_sweep → /pulse-sweep (full edge-case triage, quality review, mission awareness)
	#   stall / first_run → /pulse (lightweight dispatch+merge, unblocks the stall faster)
	# The state is NOT inlined into the prompt — on Linux, execve() enforces
	# MAX_ARG_STRLEN (128KB per argument) and the state routinely exceeds this,
	# causing "Argument list too long" on every pulse invocation. The agent
	# reads the file via its Read tool instead. See: #4257
	local pulse_command="/pulse"
	if [[ "$trigger_mode" == "daily_sweep" ]]; then
		pulse_command="/pulse-sweep"
	fi
	local prompt="$pulse_command"
	if [[ -f "$STATE_FILE" ]]; then
		prompt="${pulse_command}

Pre-fetched state file: ${STATE_FILE}
Read this file before proceeding — it contains the current repo/PR/issue state
gathered by pulse-wrapper.sh BEFORE this session started."
	fi

	# Run the provider-aware headless wrapper in background.
	local -a pulse_cmd=("$HEADLESS_RUNTIME_HELPER" run --role pulse --session-key supervisor-pulse --dir "$PULSE_DIR" --title "Supervisor Pulse" --agent Automate --prompt "$prompt")
	if [[ -n "$PULSE_MODEL" ]]; then
		pulse_cmd+=(--model "$PULSE_MODEL")
	fi
	"${pulse_cmd[@]}" >>"$LOGFILE" 2>&1 &

	local opencode_pid=$!
	echo "$opencode_pid" >"$PIDFILE"

	echo "[pulse-wrapper] opencode PID: $opencode_pid" >>"$LOGFILE"

	# Run the watchdog loop (checks stale/idle/progress, guards children)
	_run_pulse_watchdog "$opencode_pid" "$start_epoch" "$effective_cold_start_timeout"

	# Write IDLE sentinel — never delete the PID file (GH#4324).
	echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"

	local end_epoch
	end_epoch=$(date +%s)
	local duration=$((end_epoch - start_epoch))
	echo "[pulse-wrapper] Pulse completed at $(date -u +%Y-%m-%dT%H:%M:%SZ) (ran ${duration}s)" >>"$LOGFILE"
	return 0
}

#######################################
# Clean up worktrees for merged/closed PRs across ALL managed repos
#
# Iterates repos.json (.initialized_repos[]) and runs
# worktree-helper.sh clean --auto --force-merged in each repo directory.
# This prevents stale worktrees from accumulating on disk after PR merges
# — including squash merges that git branch --merged cannot detect.
#
# worktree-helper.sh clean internally:
#   1. Runs git fetch --prune origin (prunes deleted remote branches)
#   2. Checks refs/remotes/origin/<branch> for each worktree
#   3. Detects squash merges via gh pr list --state merged
#   4. Removes worktrees + deletes local branches for merged PRs
#
# --force-merged: force-removes dirty worktrees when the PR is confirmed
# merged (dirty state = abandoned WIP from a completed worker).
#
# Safety: skips worktrees owned by active sessions (handled by
# worktree-helper.sh ownership registry, t189).
#######################################
cleanup_worktrees() {
	local helper="${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_removed=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Iterate all initialized repos — clean worktrees for any repo with
		# a git directory, not just pulse-enabled ones. Workers can create
		# worktrees in any managed repo. Skip local_only repos since
		# worktree-helper.sh uses gh pr list for squash-merge detection.
		local repo_paths
		repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			local wt_count
			wt_count=$(git -C "$repo_path" worktree list | wc -l | tr -d ' ')
			# Skip repos with only 1 worktree (the main one) — nothing to clean
			if [[ "${wt_count:-0}" -le 1 ]]; then
				continue
			fi

			# Run helper in a subshell cd'd to the repo (it uses git rev-parse --show-toplevel)
			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" clean --auto --force-merged 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Removing') || count=0
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Worktree cleanup ($repo_name): $count worktree(s) removed" >>"$LOGFILE"
				total_removed=$((total_removed + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo (legacy behaviour)
		local clean_result
		clean_result=$(bash "$helper" clean --auto --force-merged 2>&1) || true
		local fallback_count
		fallback_count=$(echo "$clean_result" | grep -c 'Removing') || fallback_count=0
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Worktree cleanup: $fallback_count worktree(s) removed" >>"$LOGFILE"
			total_removed=$((total_removed + fallback_count))
		fi
	fi

	# --- Age-based orphan cleanup (GH#16830, t1884) ---
	# Workers that crash leave worktrees with 0 commits / no PR. The
	# --force-merged pass above won't touch them. Clean based on age:
	#   0 commits, no open PR, >30m → crashed worker, safe to remove fast (t1884)
	#   0 commits, 0 dirty,   >3h  → empty, safe to remove
	#   0 commits, dirty,     >6h  → worker died mid-edit, no process
	#   any commits, no PR,   >24h → abandoned, issue will be re-dispatched
	local now_epoch
	now_epoch=$(date +%s)
	local age_grace="$ORPHAN_WORKTREE_GRACE_SECS"
	local age_3h=$((3 * 3600))
	local age_6h=$((6 * 3600))
	local age_24h=$((24 * 3600))

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local repo_paths_age
		repo_paths_age=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

		local rp_age
		while IFS= read -r rp_age; do
			[[ -z "$rp_age" ]] && continue
			[[ ! -d "$rp_age/.git" ]] && continue

			local main_branch
			main_branch=$(git -C "$rp_age" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || main_branch="main"

			local repo_slug_age
			repo_slug_age=$(git -C "$rp_age" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||') || repo_slug_age=""

			# Parse worktree list — non-porcelain: "path  hash [branch]" per line.
			# Using process substitution (not pipe) so total_removed propagates.
			local wt_line_age
			while IFS= read -r wt_line_age; do
				# Extract path (first field, before double-space)
				local wt_path_age
				wt_path_age=$(printf '%s' "$wt_line_age" | awk '{print $1}')
				[[ -z "$wt_path_age" ]] && continue
				[[ "$wt_path_age" == "$rp_age" ]] && continue
				[[ ! -d "$wt_path_age" ]] && continue

				# Extract branch name from [branch] at end of line
				local wt_branch_age=""
				if [[ "$wt_line_age" == *"["*"]"* ]]; then
					wt_branch_age=$(printf '%s' "$wt_line_age" | sed 's/.*\[//;s/\]//')
				fi

				# Get worktree creation time from .git file mtime
				local wt_created=0
				if [[ -f "$wt_path_age/.git" ]]; then
					wt_created=$(stat -f '%m' "$wt_path_age/.git" 2>/dev/null) || wt_created=0
				fi
				[[ "$wt_created" -eq 0 ]] && continue
				local wt_age_secs=$((now_epoch - wt_created))

				# Count commits ahead of main
				local commits_ahead=0
				commits_ahead=$(git -C "$wt_path_age" rev-list --count "HEAD" "^${main_branch}" 2>/dev/null) || commits_ahead=0

				# Count dirty files
				local dirty_count=0
				dirty_count=$(git -C "$wt_path_age" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty_count=0

				# Check for active worker process using this worktree
				if pgrep -f "$wt_path_age" >/dev/null 2>&1; then
					continue
				fi

				local should_remove=false
				local reason=""

				# Fast-path: 0 commits + no open PR + past grace period → crashed worker (t1884)
				# Check this before the 3h/6h thresholds — no PR means no risk of losing work.
				# Only check GitHub if we have a slug and branch name; skip if either is missing.
				if [[ "$commits_ahead" -eq 0 && "$wt_age_secs" -ge "$age_grace" ]]; then
					local has_open_pr=false
					if [[ -n "$repo_slug_age" && -n "$wt_branch_age" ]]; then
						local open_pr_count
						open_pr_count=$(gh pr list --repo "$repo_slug_age" --head "$wt_branch_age" --state open --limit 1 2>/dev/null | wc -l | tr -d ' ') || open_pr_count=0
						[[ "$open_pr_count" -gt 0 ]] && has_open_pr=true
					fi
					if [[ "$has_open_pr" == "false" ]]; then
						should_remove=true
						reason="0 commits, no open PR, age $((wt_age_secs / 60))m (crashed worker)"
					fi
				elif [[ "$commits_ahead" -eq 0 && "$dirty_count" -eq 0 && "$wt_age_secs" -ge "$age_3h" ]]; then
					should_remove=true
					reason="0 commits, clean, age $((wt_age_secs / 3600))h"
				elif [[ "$commits_ahead" -eq 0 && "$dirty_count" -gt 0 && "$wt_age_secs" -ge "$age_6h" ]]; then
					should_remove=true
					reason="0 commits, ${dirty_count} dirty files, age $((wt_age_secs / 3600))h"
				elif [[ "$commits_ahead" -gt 0 && "$wt_age_secs" -ge "$age_24h" ]]; then
					# Only if no PR exists for this branch
					local has_pr=false
					if [[ -n "$repo_slug_age" && -n "$wt_branch_age" ]]; then
						local pr_count
						pr_count=$(gh pr list --repo "$repo_slug_age" --head "$wt_branch_age" --state all --limit 1 2>/dev/null | wc -l | tr -d ' ') || pr_count=0
						[[ "$pr_count" -gt 0 ]] && has_pr=true
					fi
					if [[ "$has_pr" == "false" ]]; then
						should_remove=true
						reason="${commits_ahead} commits, no PR, age $((wt_age_secs / 3600))h"
					fi
				fi

				if [[ "$should_remove" == "true" ]]; then
					local repo_name_age
					repo_name_age=$(basename "$rp_age")
					echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — $reason" >>"$LOGFILE"

					# GH#17436: Record fast-fail for crashed worker worktrees so the
					# escalation threshold (cascade tier escalation at count=2) can trigger.
					# Extract issue number from branch name (pattern: gh-NNN or ghNNNNN).
					if [[ "$reason" == *"crashed worker"* && -n "$wt_branch_age" && -n "$repo_slug_age" ]]; then
						local orphan_issue_num=""
						if [[ "$wt_branch_age" =~ gh[-]?([0-9]+) ]]; then
							orphan_issue_num="${BASH_REMATCH[1]}"
						fi
						if [[ -n "$orphan_issue_num" ]]; then
							recover_failed_launch_state "$orphan_issue_num" "$repo_slug_age" "premature_exit"
							echo "[pulse-wrapper] Orphan cleanup: recorded premature_exit for #${orphan_issue_num} (${repo_slug_age}) — triggers fast-fail escalation" >>"$LOGFILE"
						fi
					fi

					git -C "$rp_age" worktree remove --force "$wt_path_age" 2>/dev/null || rm -rf "$wt_path_age"
					if [[ -n "$wt_branch_age" ]]; then
						git -C "$rp_age" branch -D "$wt_branch_age" 2>/dev/null || true
						git -C "$rp_age" push origin --delete "$wt_branch_age" 2>/dev/null || true
					fi
					total_removed=$((total_removed + 1))
				fi
			done < <(git -C "$rp_age" worktree list 2>/dev/null)
		done <<<"$repo_paths_age"
	fi

	if [[ "$total_removed" -gt 0 ]]; then
		echo "[pulse-wrapper] Worktree cleanup total: $total_removed worktree(s) removed across all repos" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Clean up safe-to-drop stashes across ALL managed repos (t1417)
#
# Iterates repos.json (.initialized_repos[]) and runs
# stash-audit-helper.sh auto-clean in each repo directory.
# Only drops stashes whose content is already in HEAD — safe
# and deterministic, no judgment needed.
#
# Stashes classified as "needs-review" or "obsolete" are left
# for the LLM hygiene triage (see prefetch_hygiene + pulse.md).
#######################################
cleanup_stashes() {
	local helper="${HOME}/.aidevops/agents/scripts/stash-audit-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_dropped=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local repo_paths
		repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			# Skip repos with no stashes
			local stash_count
			stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
			if [[ "${stash_count:-0}" -eq 0 ]]; then
				continue
			fi

			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" auto-clean 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Dropped') || count=0
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Stash cleanup ($repo_name): $count stash(es) dropped" >>"$LOGFILE"
				total_dropped=$((total_dropped + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo
		local clean_result
		clean_result=$(bash "$helper" auto-clean 2>&1) || true
		local fallback_count
		fallback_count=$(echo "$clean_result" | grep -c 'Dropped') || fallback_count=0
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Stash cleanup: $fallback_count stash(es) dropped" >>"$LOGFILE"
			total_dropped=$((total_dropped + fallback_count))
		fi
	fi

	if [[ "$total_dropped" -gt 0 ]]; then
		echo "[pulse-wrapper] Stash cleanup total: $total_dropped stash(es) dropped across all repos" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Check if the pulse is allowed to run.
#
# Consent model (layered, highest priority first):
#   1. Session stop flag — `aidevops pulse stop` creates this to pause
#      the pulse without uninstalling it. Checked first so stop always wins.
#   2. Session start flag — `aidevops pulse start` creates this. If present,
#      the pulse runs regardless of config (explicit user action).
#   3. Config consent — setup.sh writes orchestration.supervisor_pulse=true
#      when the user consents. This is the persistent, reboot-surviving gate.
#
# If none of the above are set, the pulse was installed without config
# consent (shouldn't happen after GH#2926) — skip as a safety fallback.
#
# Returns: 0 if pulse should run, 1 if not
#######################################
check_session_gate() {
	# Stop flag takes priority — user explicitly paused
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Pulse paused (stop flag present) — resume with: aidevops pulse start" >>"$LOGFILE"
		return 1
	fi

	# Session start flag — explicit user action, always allowed
	if [[ -f "$SESSION_FLAG" ]]; then
		return 0
	fi

	# Config consent — the persistent gate that survives reboots.
	# Delegates to config_enabled from config-helper.sh (sourced via
	# shared-constants.sh), which handles: env var override
	# (AIDEVOPS_SUPERVISOR_PULSE) > user JSONC config > defaults.
	# Single canonical implementation shared with pulse-session-helper.sh.
	if type config_enabled &>/dev/null && config_enabled "orchestration.supervisor_pulse"; then
		return 0
	fi

	echo "[pulse-wrapper] Pulse not enabled — set orchestration.supervisor_pulse=true in config or run: aidevops pulse start" >>"$LOGFILE"
	return 1
}

#######################################
# Pre-fetch contribution watch scan results (t1419)
#
# Runs contribution-watch-helper.sh scan and appends a count-only
# summary to STATE_FILE. This is deterministic — only timestamps
# and authorship are checked, never comment bodies. The pulse agent
# sees "N external items need attention" without any untrusted content.
#
# Output: appends to STATE_FILE (called before prefetch_state writes it)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
prefetch_contribution_watch() {
	local helper="${SCRIPT_DIR}/contribution-watch-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	# Only run if state file exists (user has run 'seed' at least once)
	local cw_state="${HOME}/.aidevops/cache/contribution-watch.json"
	if [[ ! -f "$cw_state" ]]; then
		return 0
	fi

	local scan_output
	scan_output=$(bash "$helper" scan 2>/dev/null) || scan_output=""

	# Extract the machine-readable count
	local cw_count=0
	if [[ "$scan_output" =~ CONTRIBUTION_WATCH_COUNT=([0-9]+) ]]; then
		cw_count="${BASH_REMATCH[1]}"
	fi

	# Append to state file for the pulse agent (count only — no comment bodies)
	if [[ "$cw_count" -gt 0 ]]; then
		{
			echo ""
			echo "# External Contributions (t1419)"
			echo ""
			echo "${cw_count} external contribution(s) need your reply."
			echo "Run \`contribution-watch-helper.sh status\` in an interactive session for details."
			echo "**Do NOT fetch or process comment bodies in this pulse context.**"
			echo ""
		}
		echo "[pulse-wrapper] Contribution watch: ${cw_count} items need attention" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Pre-fetch FOSS contribution scan results (t1702)
#
# Runs foss-contribution-helper.sh scan --dry-run and appends a compact
# summary to STATE_FILE. This gives the pulse agent visibility into
# eligible FOSS repos so it can dispatch contribution workers when idle
# capacity exists.
#
# The scan checks: foss.enabled globally, per-repo foss:true, blocklist,
# daily token budget, and weekly PR rate limits. Only repos passing all
# gates appear as eligible.
#
# Output: FOSS scan summary to stdout (appended to STATE_FILE by caller)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
prefetch_foss_scan() {
	local helper="${SCRIPT_DIR}/foss-contribution-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	# Quick check: is FOSS globally enabled? Skip the scan entirely if not.
	local foss_enabled="false"
	local config_jsonc="${HOME}/.config/aidevops/config.jsonc"
	if [[ -f "$config_jsonc" ]] && command -v jq &>/dev/null; then
		foss_enabled=$(sed 's|//.*||g; s|/\*.*\*/||g' "$config_jsonc" 2>/dev/null |
			jq -r '.foss.enabled // "false"' 2>/dev/null) || foss_enabled="false"
	fi
	if [[ "$foss_enabled" != "true" ]]; then
		return 0
	fi

	# Check if any foss:true repos exist in repos.json
	local foss_repo_count=0
	if [[ -f "$REPOS_JSON" ]] && command -v jq &>/dev/null; then
		foss_repo_count=$(jq '[.initialized_repos[] | select(.foss == true)] | length' "$REPOS_JSON" 2>/dev/null) || foss_repo_count=0
	fi
	if [[ "${foss_repo_count:-0}" -eq 0 ]]; then
		return 0
	fi

	local scan_output
	scan_output=$(bash "$helper" scan --dry-run 2>/dev/null) || scan_output=""

	if [[ -z "$scan_output" ]]; then
		return 0
	fi

	# Extract eligible and skipped counts from the summary line
	local eligible_count=0
	local skipped_count=0
	if [[ "$scan_output" =~ ([0-9]+)\ eligible ]]; then
		eligible_count="${BASH_REMATCH[1]}"
	fi
	if [[ "$scan_output" =~ ([0-9]+)\ skipped ]]; then
		skipped_count="${BASH_REMATCH[1]}"
	fi

	# Get budget info
	local budget_output
	budget_output=$(bash "$helper" budget 2>/dev/null) || budget_output=""
	local daily_used=0
	local daily_max=200000
	local daily_remaining=0
	if [[ "$budget_output" =~ Used\ today:\ +([0-9]+) ]]; then
		daily_used="${BASH_REMATCH[1]}"
	fi
	if [[ "$budget_output" =~ Max\ daily\ tokens:\ +([0-9]+) ]]; then
		daily_max="${BASH_REMATCH[1]}"
	fi
	daily_remaining=$((daily_max - daily_used))
	if [[ "$daily_remaining" -lt 0 ]]; then
		daily_remaining=0
	fi

	# Extract per-repo eligible details (lines matching ELIGIBLE)
	local eligible_details
	eligible_details=$(echo "$scan_output" | grep -i 'ELIGIBLE' | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^[[:space:]]*/  - /' || true)

	{
		echo ""
		echo "# FOSS Contribution Scan (t1702)"
		echo ""
		echo "FOSS contributions are **enabled**. Scan results from \`foss-contribution-helper.sh scan --dry-run\`."
		echo ""
		echo "- Eligible repos: **${eligible_count}**"
		echo "- Skipped repos: ${skipped_count} (blocklisted, budget exceeded, or rate limited)"
		echo "- Daily token budget: ${daily_used}/${daily_max} used (${daily_remaining} remaining)"
		echo "- Max FOSS dispatches per cycle: ${FOSS_MAX_DISPATCH_PER_CYCLE}"
		echo ""
		if [[ -n "$eligible_details" && "$eligible_count" -gt 0 ]]; then
			echo "### Eligible FOSS Repos"
			echo ""
			echo "$eligible_details"
			echo ""
		fi
		echo "**Dispatch rule:** When idle worker capacity exists (all managed repo issues dispatched"
		echo "and worker slots remain), dispatch contribution workers for eligible FOSS repos."
		echo "Max ${FOSS_MAX_DISPATCH_PER_CYCLE} FOSS dispatches per pulse cycle. Use \`foss-contribution-helper.sh check <slug>\`"
		echo "before each dispatch. Record token usage after completion with \`foss-contribution-helper.sh record <slug> <tokens>\`."
		echo ""
	}

	echo "[pulse-wrapper] FOSS scan: ${eligible_count} eligible, ${skipped_count} skipped, budget ${daily_used}/${daily_max}" >>"$LOGFILE"
	return 0
}

#######################################
# Pre-fetch triage review status for needs-maintainer-review issues
#
# For each pulse-enabled repo, finds issues with the needs-maintainer-review
# label and checks whether an agent triage review comment already exists.
# This data enables the pulse to dispatch opus-tier review workers only
# for issues that haven't been reviewed yet.
#
# Detection: an agent review comment contains "## Review:" or
# "## Issue/PR Review:" in the body (the structured output format
# from review-issue-pr.md).
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: triage review status section to stdout
#######################################
prefetch_triage_review_status() {
	local repo_entries="$1"
	local found_any=false
	local total_pending=0

	while IFS='|' read -r slug path; do
		[[ -n "$slug" ]] || continue

		# Get needs-maintainer-review issues for this repo
		local nmr_json nmr_err
		nmr_err=$(mktemp)
		nmr_json=$(gh issue list --repo "$slug" --label "needs-maintainer-review" \
			--state open --json number,title,createdAt,updatedAt \
			--limit 50 2>"$nmr_err") || nmr_json="[]"
		if [[ -z "$nmr_json" || "$nmr_json" == "null" ]]; then
			local _nmr_err_msg
			_nmr_err_msg=$(cat "$nmr_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] prefetch_triage_review_status: gh issue list FAILED for ${slug}: ${_nmr_err_msg}" >>"$LOGFILE"
			nmr_json="[]"
		fi
		rm -f "$nmr_err"

		local nmr_count
		nmr_count=$(echo "$nmr_json" | jq 'length')
		[[ "$nmr_count" -gt 0 ]] || continue

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Needs Maintainer Review — Triage Status"
			echo ""
			echo "Issues with \`needs-maintainer-review\` label and their automated triage review status."
			echo "Dispatch an opus-tier \`/review-issue-pr\` worker for items marked **needs-review**."
			echo "Max 2 triage review dispatches per pulse cycle."
			echo ""
			found_any=true
		fi

		echo "## ${slug}"
		echo ""

		# Check each issue for an existing agent review comment
		local i=0
		while [[ "$i" -lt "$nmr_count" ]]; do
			local number title created_at
			number=$(echo "$nmr_json" | jq -r ".[$i].number")
			title=$(echo "$nmr_json" | jq -r ".[$i].title")
			created_at=$(echo "$nmr_json" | jq -r ".[$i].createdAt")

			# Check for agent review comment (contains "## Review:" or "## Issue/PR Review:")
			# Use --paginate to handle issues with many comments (default page size is 30).
			# On API failure, mark as "unknown" rather than falsely reporting "needs-review".
			local review_response=""
			local review_exists=0
			local api_ok=true
			review_response=$(gh api "repos/${slug}/issues/${number}/comments" --paginate \
				--jq '[.[] | select(.body | test("## (Issue/PR )?Review:"))] | length' 2>/dev/null) || api_ok=false

			if [[ "$api_ok" == true ]]; then
				review_exists="$review_response"
				[[ "$review_exists" =~ ^[0-9]+$ ]] || review_exists=0
			fi

			local status_label
			if [[ "$api_ok" != true ]]; then
				status_label="unknown"
				echo "[pulse-wrapper] API error checking review status for ${slug}#${number}" >>"$LOGFILE"
			elif [[ "$review_exists" -gt 0 ]]; then
				status_label="reviewed"
			else
				status_label="needs-review"
				total_pending=$((total_pending + 1))
			fi

			echo "- Issue #${number}: ${title} [status: **${status_label}**] [created: ${created_at}]"

			i=$((i + 1))
		done

		echo ""
	done <<<"$repo_entries"

	if [[ "$found_any" == true ]]; then
		echo "**Total pending triage reviews: ${total_pending}**"
		echo ""
		echo "[pulse-wrapper] Triage review status: ${total_pending} issues pending review" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Pre-fetch contributor reply status for status:needs-info issues
#
# For each pulse-enabled repo, finds issues with the status:needs-info
# label and checks whether the original issue author has commented since
# the label was applied. This enables the pulse to relabel issues back
# to needs-maintainer-review when the contributor provides the requested
# information.
#
# Detection: compare the label event timestamp (from timeline API) or
# issue updatedAt against the most recent comment from the issue author.
# If the author commented after the label was applied, mark as "replied".
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: needs-info reply status section to stdout
#######################################
prefetch_needs_info_replies() {
	local repo_entries="$1"
	local found_any=false
	local total_replied=0

	while IFS='|' read -r slug path; do
		[[ -n "$slug" ]] || continue

		# Get status:needs-info issues for this repo
		local ni_json ni_err
		ni_err=$(mktemp)
		ni_json=$(gh issue list --repo "$slug" --label "status:needs-info" \
			--state open --json number,title,author,createdAt,updatedAt \
			--limit 50 2>"$ni_err") || ni_json="[]"
		if [[ -z "$ni_json" || "$ni_json" == "null" ]]; then
			local _ni_err_msg
			_ni_err_msg=$(cat "$ni_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] prefetch_needs_info_replies: gh issue list FAILED for ${slug}: ${_ni_err_msg}" >>"$LOGFILE"
			ni_json="[]"
		fi
		rm -f "$ni_err"

		local ni_count
		ni_count=$(echo "$ni_json" | jq 'length')
		[[ "$ni_count" -gt 0 ]] || continue

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Needs Info — Contributor Reply Status"
			echo ""
			echo "Issues with \`status:needs-info\` label. For items marked **replied**, relabel to"
			echo "\`needs-maintainer-review\` so the triage pipeline re-evaluates with the new information."
			echo ""
			found_any=true
		fi

		echo "## ${slug}"
		echo ""

		local i=0
		while [[ "$i" -lt "$ni_count" ]]; do
			local number title author created_at
			number=$(echo "$ni_json" | jq -r ".[$i].number")
			title=$(echo "$ni_json" | jq -r ".[$i].title")
			author=$(echo "$ni_json" | jq -r ".[$i].author.login")
			created_at=$(echo "$ni_json" | jq -r ".[$i].createdAt")

			# Find when status:needs-info was applied via timeline events
			# Fall back to updatedAt if timeline API fails
			local label_date=""
			local api_ok=true
			label_date=$(gh api "repos/${slug}/issues/${number}/timeline" --paginate \
				--jq '[.[] | select(.event == "labeled" and .label.name == "status:needs-info")] | last | .created_at' 2>/dev/null) || api_ok=false

			if [[ "$api_ok" != true || -z "$label_date" || "$label_date" == "null" ]]; then
				# Fall back: use issue updatedAt as approximate label time
				label_date=$(echo "$ni_json" | jq -r ".[$i].updatedAt")
			fi

			# Check for author comments after the label was applied
			local author_replied=false
			local latest_author_comment_date=""
			latest_author_comment_date=$(gh api "repos/${slug}/issues/${number}/comments" --paginate \
				--jq "[.[] | select(.user.login == \"${author}\")] | last | .created_at" 2>/dev/null) || latest_author_comment_date=""

			if [[ -n "$latest_author_comment_date" && "$latest_author_comment_date" != "null" && "$latest_author_comment_date" > "$label_date" ]]; then
				author_replied=true
			fi

			local status_label
			if [[ "$author_replied" == true ]]; then
				status_label="replied"
				total_replied=$((total_replied + 1))
			else
				status_label="waiting"
			fi

			echo "- Issue #${number}: ${title} [author: @${author}] [status: **${status_label}**] [labeled: ${label_date}]"

			i=$((i + 1))
		done

		echo ""
	done <<<"$repo_entries"

	if [[ "$found_any" == true ]]; then
		echo "**Total contributor replies pending action: ${total_replied}**"
		echo ""
		echo "[pulse-wrapper] Needs-info reply status: ${total_replied} issues with contributor replies" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Ensure active issues have an assignee
#
# Prevent overlap by normalizing assignment on issues already marked as
# actively worked (`status:queued` or `status:in-progress`). If an issue
# has one of these labels but no assignee, assign it to the runner user.
#
# Returns: 0 always (best-effort)
#######################################
normalize_active_issue_assignments() {
	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local runner_user
	runner_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$runner_user" ]]; then
		echo "[pulse-wrapper] Assignment normalization skipped: unable to resolve runner user" >>"$LOGFILE"
		return 0
	fi

	local total_checked=0
	local total_assigned=0
	local now_epoch
	now_epoch=$(date +%s)

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local issue_rows issue_rows_json issue_rows_err
		issue_rows_err=$(mktemp)
		issue_rows_json=$(gh issue list --repo "$slug" --state open --json number,assignees,labels --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>"$issue_rows_err") || issue_rows_json=""
		if [[ -z "$issue_rows_json" || "$issue_rows_json" == "null" ]]; then
			local _issue_rows_err_msg
			_issue_rows_err_msg=$(cat "$issue_rows_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] normalize_active_issue_assignments: gh issue list FAILED for ${slug}: ${_issue_rows_err_msg}" >>"$LOGFILE"
			rm -f "$issue_rows_err"
			continue
		fi
		rm -f "$issue_rows_err"
		issue_rows=$(printf '%s' "$issue_rows_json" | jq -r '.[] | select(((.labels | map(.name) | index("status:queued")) or (.labels | map(.name) | index("status:in-progress"))) and ((.assignees | length) == 0)) | .number' 2>/dev/null) || issue_rows=""
		if [[ -z "$issue_rows" ]]; then
			continue
		fi

		while IFS= read -r issue_number; do
			[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
			total_checked=$((total_checked + 1))
			if gh issue edit "$issue_number" --repo "$slug" --add-assignee "$runner_user" >/dev/null 2>&1; then
				total_assigned=$((total_assigned + 1))
			fi
		done <<<"$issue_rows"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_checked" -gt 0 ]]; then
		echo "[pulse-wrapper] Assignment normalization: assigned ${total_assigned}/${total_checked} active unassigned issues to ${runner_user}" >>"$LOGFILE"
	fi

	# --- Pass 2: Reset stale assignments (GH#16842) ---
	# Workers that crash after the launch validation window leave issues with
	# assignees + status:queued/in-progress but no running worker process.
	# The dedup guard then blocks re-dispatch indefinitely. Reset these so
	# the deterministic fill floor can re-dispatch them.
	local total_reset=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Find issues assigned to runner_user with active-dispatch labels
		local stale_json
		stale_json=$(gh issue list --repo "$slug" --assignee "$runner_user" --state open \
			--json number,labels,updatedAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || stale_json=""
		[[ -n "$stale_json" && "$stale_json" != "null" ]] || continue

		# Filter: has status:queued or status:in-progress, updated >1h ago
		local stale_issues
		stale_issues=$(printf '%s' "$stale_json" | jq -r --arg cutoff "$((now_epoch - 3600))" '
			[.[] | select(
				((.labels | map(.name)) | (index("status:queued") or index("status:in-progress")))
				and ((.updatedAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < ($cutoff | tonumber))
			) | .number] | .[]
		' 2>/dev/null) || stale_issues=""
		[[ -n "$stale_issues" ]] || continue

		# For each candidate, verify no active worker process exists
		local repo_path_for_slug
		repo_path_for_slug=$(jq -r --arg s "$slug" '.initialized_repos[] | select(.slug == $s) | .path' "$repos_json" 2>/dev/null) || repo_path_for_slug=""

		local stale_num
		while IFS= read -r stale_num; do
			[[ "$stale_num" =~ ^[0-9]+$ ]] || continue

			# Check if any worker process references this issue
			if pgrep -f "issue.*${stale_num}" >/dev/null 2>&1 || pgrep -f "#${stale_num}" >/dev/null 2>&1; then
				continue
			fi
			# Also check worker log recency — if log was written in last 10 min, worker may still be active
			local safe_slug_check
			safe_slug_check=$(printf '%s' "$slug" | tr '/:' '--')
			local worker_log="/tmp/pulse-${safe_slug_check}-${stale_num}.log"
			if [[ -f "$worker_log" ]]; then
				local log_mtime
				log_mtime=$(stat -f '%m' "$worker_log" 2>/dev/null) || log_mtime=0
				if [[ $((now_epoch - log_mtime)) -lt 600 ]]; then
					continue
				fi
			fi

			# No worker — reset the issue for re-dispatch
			echo "[pulse-wrapper] Stale assignment reset: #${stale_num} in ${slug} — assigned to ${runner_user} with active label but no worker process" >>"$LOGFILE"
			gh issue edit "$stale_num" --repo "$slug" \
				--remove-assignee "$runner_user" \
				--remove-label "status:queued" --remove-label "status:in-progress" \
				--add-label "status:available" >/dev/null 2>&1 || true
			total_reset=$((total_reset + 1))
		done <<<"$stale_issues"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_reset" -gt 0 ]]; then
		echo "[pulse-wrapper] Stale assignment cleanup: reset ${total_reset} issues for re-dispatch" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Close open issues whose work is already done — a merged PR exists
# that references the issue via "Closes #N" or matching task ID in
# the PR title (GH#16851).
#
# The dedup guard (Layer 4) detects these and blocks re-dispatch,
# but the issue stays open forever. This stage closes them with a
# comment linking to the merged PR, cleaning the backlog.
#######################################
close_issues_with_merged_prs() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"

	local total_closed=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Only check issues marked available for dispatch. Capped at 20
		# per repo to limit API calls (dedup helper makes 1 call per issue).
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "status:available" \
			--json number,title --limit 20 2>/dev/null) || issues_json="[]"
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
			issue_title=$(printf '%s' "$issues_json" | jq -r ".[$i].title // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Skip management issues (supervisor, persistent, quality-review)
			# — these are intentionally kept open
			local labels_csv
			labels_csv=$(printf '%s' "$issues_json" | jq -r ".[$((i - 1))].labels // [] | map(.name) | join(\",\")" 2>/dev/null) || labels_csv=""

			# Ask dedup helper if a merged PR exists for this issue
			local dedup_output=""
			if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
				# has-open-pr returns 0 when merged PR evidence found (confusing name but correct)
				local pr_ref
				pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
				local pr_num
				pr_num=$(printf '%s' "$pr_ref" | tr -d '#')

				# GH#17372: Verify PR diff actually touches files from the issue.
				# A merged PR with "closes #NNN" may reference the issue without
				# fixing it (e.g., mentioned in a comment, not the actual fix).
				if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
					if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
						echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} does not touch files from issue (GH#17372 guard)" >>"$LOGFILE"
						continue
					fi
				fi

				gh issue close "$issue_num" --repo "$slug" \
					--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup helper)"}. Issue was open but dedup guard was blocking re-dispatch." \
					>/dev/null 2>&1 || continue

				# Reset fast-fail counter now that the issue is confirmed resolved (GH#17384)
				fast_fail_reset "$issue_num" "$slug" || true

				echo "[pulse-wrapper] Auto-closed #${issue_num} in ${slug} — merged PR evidence: ${dedup_output:-"found"}" >>"$LOGFILE"
				total_closed=$((total_closed + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Close issues with merged PRs: closed ${total_closed} issue(s)" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Reconcile status:done issues that are still open.
#
# Workers set status:done when they believe work is complete, but the
# issue may stay open if: (1) PR merged but Closes #N was missing,
# (2) worker declared done but never created a PR, (3) PR was rejected.
#
# Case 1: merged PR found → close the issue (work verified done).
# Cases 2+3: no merged PR → reset to status:available for re-dispatch.
#
# Capped at 20 per repo per cycle to limit API calls.
#######################################
reconcile_stale_done_issues() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"

	local total_closed=0
	local total_reset=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "status:done" \
			--json number,title --limit 20 2>/dev/null) || issues_json="[]"
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
			issue_title=$(printf '%s' "$issues_json" | jq -r ".[$i].title // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Check if a merged PR exists for this issue
			local dedup_output=""
			if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
				# Merged PR found — verify diff overlap before closing (GH#17372)
				local pr_ref
				pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
				local pr_num
				pr_num=$(printf '%s' "$pr_ref" | tr -d '#')

				if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
					if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
						echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} does not touch issue files (GH#17372 guard)" >>"$LOGFILE"
						# Reset to available for re-evaluation instead of closing
						gh issue edit "$issue_num" --repo "$slug" \
							--remove-label "status:done" \
							--add-label "status:available" >/dev/null 2>&1 || continue
						total_reset=$((total_reset + 1))
						continue
					fi
				fi

				gh issue close "$issue_num" --repo "$slug" \
					--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup)"}." \
					>/dev/null 2>&1 || continue

				# Reset fast-fail counter now that the issue is confirmed resolved (GH#17384)
				fast_fail_reset "$issue_num" "$slug" || true

				echo "[pulse-wrapper] Reconcile done: closed #${issue_num} in ${slug} — merged PR: ${dedup_output:-"found"}" >>"$LOGFILE"
				total_closed=$((total_closed + 1))
			else
				# No merged PR — reset for re-evaluation
				gh issue edit "$issue_num" --repo "$slug" \
					--remove-label "status:done" \
					--add-label "status:available" >/dev/null 2>&1 || continue
				echo "[pulse-wrapper] Reconcile done: reset #${issue_num} in ${slug} to status:available — no merged PR evidence" >>"$LOGFILE"
				total_reset=$((total_reset + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$((total_closed + total_reset))" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile stale done issues: closed=${total_closed}, reset=${total_reset}" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Cached ever-NMR provenance helpers (GH#17458)
#
# Positive results are immutable and can be cached indefinitely.
# Negative results are cached for a short TTL to avoid a timeline API call
# on every dispatch candidate while still noticing new NMR labels promptly.
#######################################
_ever_nmr_cache_key() {
	local issue_num="$1"
	local slug="$2"
	printf '%s\n' "${slug}#${issue_num}"
	return 0
}

_ever_nmr_cache_load() {
	if [[ ! -f "$EVER_NMR_CACHE_FILE" ]]; then
		printf '{}\n'
		return 0
	fi

	local content
	content=$(cat "$EVER_NMR_CACHE_FILE" 2>/dev/null) || content="{}"
	if ! printf '%s' "$content" | jq empty >/dev/null 2>&1; then
		content="{}"
	fi

	printf '%s\n' "$content"
	return 0
}

_ever_nmr_cache_with_lock() {
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		sleep 0.1
	done

	local rc=0
	"$@" || rc=$?
	rmdir "$lock_dir" 2>/dev/null || true
	return "$rc"
}

_ever_nmr_cache_get() {
	local issue_num="$1"
	local slug="$2"
	local key now_epoch cache_json cache_value checked_at age

	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	cache_json=$(_ever_nmr_cache_load)
	cache_value=$(printf '%s' "$cache_json" | jq -r --arg key "$key" 'if .[$key] == null then "unknown" elif .[$key].ever_nmr == true then "true" elif .[$key].ever_nmr == false then "false" else "unknown" end' 2>/dev/null) || cache_value="unknown"
	checked_at=$(printf '%s' "$cache_json" | jq -r --arg key "$key" '.[$key].checked_at // 0' 2>/dev/null) || checked_at=0
	[[ "$checked_at" =~ ^[0-9]+$ ]] || checked_at=0

	if [[ "$cache_value" == "true" ]]; then
		printf 'true\n'
		return 0
	fi

	if [[ "$cache_value" == "false" ]]; then
		age=$((now_epoch - checked_at))
		if [[ "$age" -lt "$EVER_NMR_NEGATIVE_CACHE_TTL_SECS" ]]; then
			printf 'false\n'
			return 0
		fi
	fi

	printf 'unknown\n'
	return 0
}

_ever_nmr_cache_set_locked() {
	local issue_num="$1"
	local slug="$2"
	local cache_value="$3"
	local state_dir cache_json key now_epoch tmp_file

	[[ "$cache_value" == "true" || "$cache_value" == "false" ]] || return 1

	state_dir=$(dirname "$EVER_NMR_CACHE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	cache_json=$(_ever_nmr_cache_load)
	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	tmp_file=$(mktemp "${state_dir}/.ever-nmr-cache.XXXXXX" 2>/dev/null) || return 0

	if printf '%s' "$cache_json" | jq --arg key "$key" --argjson checked_at "$now_epoch" --argjson ever_nmr "$cache_value" '.[$key] = {ever_nmr: $ever_nmr, checked_at: $checked_at}' >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$EVER_NMR_CACHE_FILE" || {
			rm -f "$tmp_file"
			echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to move cache file" >>"$LOGFILE"
		}
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to write cache entry" >>"$LOGFILE"
	fi

	return 0
}

_ever_nmr_cache_set() {
	_ever_nmr_cache_with_lock _ever_nmr_cache_set_locked "$@" || return 0
	return 0
}

#######################################
# Check if an issue was ever labeled needs-maintainer-review (t1894).
# Uses the immutable GitHub timeline API — label removal does not erase
# the history. This is the provenance gate: once an issue is tagged NMR,
# it requires cryptographic approval forever, regardless of current labels.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional precomputed status: true|false|unknown
# Returns: 0 if the issue was ever NMR-labeled, 1 otherwise
#######################################
issue_was_ever_nmr() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 1

	case "$known_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local cache_status
	cache_status=$(_ever_nmr_cache_get "$issue_num" "$slug")
	case "$cache_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local ever_count
	ever_count=$(gh api "repos/${slug}/issues/${issue_num}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "needs-maintainer-review")] | length' \
		2>/dev/null) || ever_count=0
	[[ "$ever_count" =~ ^[0-9]+$ ]] || ever_count=0

	if [[ "$ever_count" -gt 0 ]]; then
		_ever_nmr_cache_set "$issue_num" "$slug" "true"
		return 0
	fi

	_ever_nmr_cache_set "$issue_num" "$slug" "false"
	return 1
}

#######################################
# Check if an issue requires cryptographic approval and has it (t1894).
# Combines the "ever-NMR" provenance check with signature verification.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional precomputed status: true|false|unknown
# Returns: 0 if the issue is approved (or never needed approval), 1 if blocked
#######################################
issue_has_required_approval() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"

	# If it was never NMR-labeled, no approval needed
	if ! issue_was_ever_nmr "$issue_num" "$slug" "$known_status"; then
		return 0
	fi

	# It was NMR-labeled at some point — check for cryptographic approval
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	if [[ -f "$approval_helper" ]]; then
		local verify_result
		verify_result=$(bash "$approval_helper" verify "$issue_num" "$slug" 2>/dev/null) || verify_result=""
		if [[ "$verify_result" == "VERIFIED" ]]; then
			return 0
		fi
	fi

	# Was ever NMR, no signed approval found — blocked
	return 1
}

#######################################
# Check if the needs-maintainer-review label was most recently applied
# by the maintainer themselves (indicating a manual hold).
#
# Arguments:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - maintainer : maintainer GitHub login
#
# Returns 0 if the maintainer applied NMR (manual hold — do NOT auto-approve).
# Returns 1 if NMR was applied by automation or the actor is unknown.
#######################################
_nmr_applied_by_maintainer() {
	local issue_num="$1"
	local slug="$2"
	local maintainer="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$maintainer" ]] || return 1

	local nmr_actor
	nmr_actor=$(gh api "repos/${slug}/issues/${issue_num}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "needs-maintainer-review")] | last | .actor.login // empty' \
		2>/dev/null) || nmr_actor=""

	if [[ "$nmr_actor" == "$maintainer" ]]; then
		return 0
	fi

	return 1
}

#######################################
# Auto-approve needs-maintainer-review issues using cryptographic
# signature verification (t1894, replaces GH#16842 comment-based check).
#
# The review gate exists for external contributions. Approval requires
# a cryptographically signed comment posted via `sudo aidevops approve
# issue <number>`. This ensures only a human with the system password
# (and root access to the approval signing key) can approve issues.
#
# Fallback: maintainer-authored issues are still auto-approved (the
# maintainer wouldn't gate their own issues), UNLESS the maintainer
# manually applied NMR themselves — that signals an intentional hold
# and must be preserved. Comment-based approval is removed — workers
# share the same GitHub account so any comment from the account is
# indistinguishable from a human comment.
#######################################
auto_approve_maintainer_issues() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_approved=0
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"

	while IFS='|' read -r slug maintainer; do
		[[ -n "$slug" && -n "$maintainer" ]] || continue

		# Get all open needs-maintainer-review issues
		local nmr_json
		nmr_json=$(gh issue list --repo "$slug" --label "needs-maintainer-review" \
			--state open --json number,author --limit 100 2>/dev/null) || nmr_json="[]"
		[[ -n "$nmr_json" && "$nmr_json" != "null" ]] || continue

		local nmr_count
		nmr_count=$(printf '%s' "$nmr_json" | jq 'length' 2>/dev/null) || nmr_count=0
		[[ "$nmr_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$nmr_count" ]]; do
			local issue_num issue_author
			issue_num=$(printf '%s' "$nmr_json" | jq -r ".[$i].number" 2>/dev/null)
			issue_author=$(printf '%s' "$nmr_json" | jq -r ".[$i].author.login // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			local should_approve=false
			local approval_reason=""

			# Case 1: maintainer created the issue — auto-approve unless NMR
			# was manually applied by the maintainer (intentional hold).
			if [[ "$issue_author" == "$maintainer" ]]; then
				if _nmr_applied_by_maintainer "$issue_num" "$slug" "$maintainer"; then
					echo "[pulse-wrapper] Skipping auto-approve for #${issue_num} in ${slug} — NMR manually applied by maintainer" >>"$LOGFILE"
				else
					should_approve=true
					approval_reason="maintainer is author, NMR applied by automation"
				fi
			fi

			# Case 2: cryptographic approval signature found
			if [[ "$should_approve" == "false" && -f "$approval_helper" ]]; then
				local verify_result
				verify_result=$(bash "$approval_helper" verify "$issue_num" "$slug" 2>/dev/null) || verify_result=""
				if [[ "$verify_result" == "VERIFIED" ]]; then
					should_approve=true
					approval_reason="cryptographic approval verified"
				fi
			fi

			if [[ "$should_approve" == "true" ]]; then
				gh issue edit "$issue_num" --repo "$slug" \
					--remove-label "needs-maintainer-review" \
					--add-label "auto-dispatch" >/dev/null 2>&1 || true
				echo "[pulse-wrapper] Auto-approved #${issue_num} in ${slug} — ${approval_reason}" >>"$LOGFILE"
				total_approved=$((total_approved + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.maintainer // (.slug | split("/")[0]))"' "$repos_json" 2>/dev/null)

	if [[ "$total_approved" -gt 0 ]]; then
		echo "[pulse-wrapper] Auto-approve maintainer issues: approved ${total_approved} issue(s)" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Daily complexity scan helpers (GH#5628, GH#15285)
#######################################

# Check if the complexity scan interval has elapsed.
# Arguments: $1 - now_epoch (current epoch seconds)
# Returns: 0 if scan is due, 1 if not yet due
_complexity_scan_check_interval() {
	local now_epoch="$1"
	if [[ ! -f "$COMPLEXITY_SCAN_LAST_RUN" ]]; then
		return 0
	fi
	local last_run
	last_run=$(cat "$COMPLEXITY_SCAN_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	local elapsed=$((now_epoch - last_run))
	if [[ "$elapsed" -lt "$COMPLEXITY_SCAN_INTERVAL" ]]; then
		local remaining=$(((COMPLEXITY_SCAN_INTERVAL - elapsed) / 3600))
		echo "[pulse-wrapper] Complexity scan not due yet (${remaining}h remaining)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

# Check if the daily CodeRabbit codebase review interval has elapsed.
# Models on _complexity_scan_check_interval which has never regressed (GH#17640).
# Arguments: $1 - now_epoch (current epoch seconds)
# Returns: 0 if review is due, 1 if not yet due
_coderabbit_review_check_interval() {
	local now_epoch="$1"
	if [[ ! -f "$CODERABBIT_REVIEW_LAST_RUN" ]]; then
		return 0
	fi
	local last_run
	last_run=$(cat "$CODERABBIT_REVIEW_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	local elapsed=$((now_epoch - last_run))
	if [[ "$elapsed" -lt "$CODERABBIT_REVIEW_INTERVAL" ]]; then
		local remaining=$(((CODERABBIT_REVIEW_INTERVAL - elapsed) / 3600))
		echo "[pulse-wrapper] CodeRabbit codebase review not due yet (${remaining}h remaining)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Daily full codebase review via CodeRabbit (GH#17640).
#
# Posts "@coderabbitai Please run a full codebase review" on issue #2632
# once per 24h. Uses a simple timestamp file gate (same pattern as
# _complexity_scan_check_interval) to avoid duplicate posts.
#
# Previous implementations regressed because they checked complex quality
# gate status instead of a plain time-based interval. This version uses
# the same pattern as the complexity scan which has never regressed.
#
# Actionable findings from the review are routed through
# quality-feedback-helper.sh to create tracked issues.
#######################################
run_daily_codebase_review() {
	local aidevops_slug="marcusquinn/aidevops"
	local now_epoch
	now_epoch=$(date +%s)

	# Time gate: skip if last review was <24h ago
	_coderabbit_review_check_interval "$now_epoch" || return 0

	# Permission gate: only collaborators with write+ may trigger reviews
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null) || current_user=""
	if [[ -z "$current_user" ]]; then
		echo "[pulse-wrapper] CodeRabbit review: skipped — cannot determine current user" >>"$LOGFILE"
		return 0
	fi
	local perm_level
	perm_level=$(gh api "repos/${aidevops_slug}/collaborators/${current_user}/permission" \
		--jq '.permission' 2>/dev/null) || perm_level=""
	case "$perm_level" in
	admin | maintain | write) ;; # allowed
	*)
		echo "[pulse-wrapper] CodeRabbit review: skipped — user '$current_user' has '$perm_level' permission on $aidevops_slug (need write+)" >>"$LOGFILE"
		return 0
		;;
	esac

	echo "[pulse-wrapper] Posting daily CodeRabbit full codebase review request on #${CODERABBIT_REVIEW_ISSUE} (GH#17640)..." >>"$LOGFILE"

	# Post the review trigger comment
	if gh issue comment "$CODERABBIT_REVIEW_ISSUE" \
		--repo "$aidevops_slug" \
		--body "@coderabbitai Please run a full codebase review" 2>>"$LOGFILE"; then
		# Update timestamp only on successful post
		printf '%s\n' "$now_epoch" >"$CODERABBIT_REVIEW_LAST_RUN"
		echo "[pulse-wrapper] CodeRabbit review: posted successfully, next review in ~24h" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] CodeRabbit review: failed to post comment on #${CODERABBIT_REVIEW_ISSUE}" >>"$LOGFILE"
		return 1
	fi

	# Route actionable findings through quality-feedback-helper if available
	local qfh="${SCRIPT_DIR}/quality-feedback-helper.sh"
	if [[ -x "$qfh" ]]; then
		echo "[pulse-wrapper] CodeRabbit review: findings will be processed by quality-feedback-helper.sh on next cycle" >>"$LOGFILE"
	fi

	return 0
}

# Compute a deterministic tree hash for the files the complexity scan cares about.
# Uses git ls-tree to hash the current state of .agents/ *.sh and *.md files.
# This is O(1) — a single git command, not per-file iteration.
# Arguments: $1 - repo_path
# Outputs: tree hash string to stdout (empty on failure)
_complexity_scan_tree_hash() {
	local repo_path="$1"
	# Hash the tree of .agents/ tracked files — covers both .sh and .md targets.
	# git ls-tree -r HEAD outputs blob hashes + paths; piping through sha256sum
	# gives a single stable hash that changes iff any tracked file changes.
	git -C "$repo_path" ls-tree -r HEAD -- .agents/ 2>/dev/null |
		awk '{print $3, $4}' |
		sha256sum 2>/dev/null |
		awk '{print $1}' ||
		true
	return 0
}

# Check whether the repo tree has changed since the last complexity scan.
# Compares current tree hash against the cached value in COMPLEXITY_SCAN_TREE_HASH_FILE.
# Arguments: $1 - repo_path
# Returns: 0 if changed (scan needed), 1 if unchanged (skip)
# Side effect: updates COMPLEXITY_SCAN_TREE_HASH_FILE when changed
_complexity_scan_tree_changed() {
	local repo_path="$1"
	local current_hash
	current_hash=$(_complexity_scan_tree_hash "$repo_path")
	if [[ -z "$current_hash" ]]; then
		# Cannot compute hash — proceed with scan to be safe
		return 0
	fi
	local cached_hash=""
	if [[ -f "$COMPLEXITY_SCAN_TREE_HASH_FILE" ]]; then
		cached_hash=$(cat "$COMPLEXITY_SCAN_TREE_HASH_FILE" 2>/dev/null || true)
	fi
	if [[ "$current_hash" == "$cached_hash" ]]; then
		echo "[pulse-wrapper] Complexity scan: tree unchanged since last scan — skipping file iteration" >>"$LOGFILE"
		return 1
	fi
	# Tree changed — update cache and signal scan needed
	printf '%s\n' "$current_hash" >"$COMPLEXITY_SCAN_TREE_HASH_FILE"
	return 0
}

# Check if the daily LLM sweep is due and debt is stalled.
# The LLM sweep fires when:
#   1. COMPLEXITY_LLM_SWEEP_INTERVAL has elapsed since last sweep, AND
#   2. The open simplification-debt count has not decreased since last check
# Arguments: $1 - now_epoch, $2 - aidevops_slug
# Returns: 0 if sweep is due, 1 if not due
_complexity_llm_sweep_due() {
	local now_epoch="$1"
	local aidevops_slug="$2"

	# Interval guard
	if [[ -f "$COMPLEXITY_LLM_SWEEP_LAST_RUN" ]]; then
		local last_sweep
		last_sweep=$(cat "$COMPLEXITY_LLM_SWEEP_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_sweep" =~ ^[0-9]+$ ]] || last_sweep=0
		local elapsed=$((now_epoch - last_sweep))
		if [[ "$elapsed" -lt "$COMPLEXITY_LLM_SWEEP_INTERVAL" ]]; then
			return 1
		fi
	fi

	# Fetch current open debt count
	local current_count
	current_count=$(gh api graphql \
		-f query="query { repository(owner:\"${aidevops_slug%%/*}\", name:\"${aidevops_slug##*/}\") { issues(labels:[\"simplification-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || current_count=""
	[[ "$current_count" =~ ^[0-9]+$ ]] || return 1

	# Compare against last recorded count
	local prev_count=""
	if [[ -f "$COMPLEXITY_DEBT_COUNT_FILE" ]]; then
		prev_count=$(cat "$COMPLEXITY_DEBT_COUNT_FILE" 2>/dev/null || true)
	fi

	# Always update the count file
	printf '%s\n' "$current_count" >"$COMPLEXITY_DEBT_COUNT_FILE"

	# No sweep needed when debt is already zero — nothing to act on (GH#17422)
	if [[ "$current_count" -eq 0 ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: debt is zero, no sweep required" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 1
	fi

	# Sweep is due if debt count has not decreased (stalled or growing)
	if [[ -n "$prev_count" && "$prev_count" =~ ^[0-9]+$ ]]; then
		if [[ "$current_count" -lt "$prev_count" ]]; then
			echo "[pulse-wrapper] Complexity LLM sweep: debt reduced (${prev_count} → ${current_count}) — sweep not needed" >>"$LOGFILE"
			printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
			return 1
		fi
	fi

	# GH#17536: Skip sweep when all remaining debt issues are already dispatched.
	# If every open simplification-debt issue (excluding sweep meta-issues) has
	# status:queued or status:in-progress, the pipeline is working — no sweep needed.
	local dispatched_count
	dispatched_count=$(gh issue list --repo "$aidevops_slug" \
		--label "simplification-debt" --state open \
		--json number,title,labels --jq '
		[.[] | select(.title | test("stalled|LLM sweep") | not)] |
		if length == 0 then 0
		else
			[.[] | select(.labels | map(.name) | (index("status:queued") or index("status:in-progress")))] | length
		end' 2>/dev/null) || dispatched_count=""
	local actionable_count
	actionable_count=$(gh issue list --repo "$aidevops_slug" \
		--label "simplification-debt" --state open \
		--json number,title --jq '[.[] | select(.title | test("stalled|LLM sweep") | not)] | length' 2>/dev/null) || actionable_count=""
	if [[ "$actionable_count" =~ ^[0-9]+$ && "$dispatched_count" =~ ^[0-9]+$ && "$actionable_count" -gt 0 && "$dispatched_count" -ge "$actionable_count" ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: all ${actionable_count} debt issues are dispatched — sweep not needed" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 1
	fi

	echo "[pulse-wrapper] Complexity LLM sweep: debt stalled at ${current_count} (prev: ${prev_count:-unknown}, dispatched: ${dispatched_count:-?}/${actionable_count:-?}) — sweep due" >>"$LOGFILE"
	return 0
}

# Run the daily LLM sweep: create a GitHub issue asking the LLM to review
# why simplification debt is stalled and suggest approach adjustments.
# Arguments: $1 - aidevops_slug, $2 - now_epoch, $3 - maintainer
# Returns: 0 always (best-effort)
_complexity_run_llm_sweep() {
	local aidevops_slug="$1"
	local now_epoch="$2"
	local maintainer="$3"

	# Dedup: check if an open sweep issue already exists (t1855).
	# Both sweep code paths use different title patterns — check both.
	local sweep_exists
	sweep_exists=$(gh issue list --repo "$aidevops_slug" \
		--label "simplification-debt" --state open \
		--search "in:title \"simplification debt stalled\"" \
		--json number --jq 'length' 2>/dev/null) || sweep_exists="0"
	if [[ "${sweep_exists:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: skipping — open stall issue already exists" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 0
	fi

	local current_count=""
	if [[ -f "$COMPLEXITY_DEBT_COUNT_FILE" ]]; then
		current_count=$(cat "$COMPLEXITY_DEBT_COUNT_FILE" 2>/dev/null || true)
	fi

	local sweep_body
	sweep_body="## Simplification debt stall — LLM sweep (automated, GH#15285)

**Open simplification-debt issues:** ${current_count:-unknown}

The simplification debt count has not decreased in the last $((COMPLEXITY_LLM_SWEEP_INTERVAL / 3600))h. This issue is a prompt for the LLM to review the current state and suggest approach adjustments.

### Questions to investigate

1. Are the open simplification-debt issues actionable? Check for issues that are blocked, stale, or need maintainer review.
2. Are workers dispatching on simplification-debt issues? Check recent pulse logs for dispatch activity.
3. Is the open cap (500) being hit? If so, consider raising it or closing stale issues.
4. Are there systemic blockers (e.g., all remaining issues require architectural decisions)?

### Suggested actions

- Review the oldest 10 open simplification-debt issues and close any that are no longer relevant.
- Check if \`tier:simple\` and \`tier:standard\` issues are being dispatched — if not, verify the pulse is routing them correctly.
- If debt is growing, consider lowering \`COMPLEXITY_MD_MIN_LINES\` or \`COMPLEXITY_FILE_VIOLATION_THRESHOLD\` to catch more candidates.

### Confidence: low

This is an automated stall-detection sweep. The LLM should review the actual issue list before acting.

---
**To dismiss**, comment \`dismissed: <reason>\` on this issue."

	# Append signature footer
	local sig_footer="" _sweep_elapsed=""
	_sweep_elapsed=$((now_epoch - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$sweep_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_sweep_elapsed" --session-type routine 2>/dev/null || true)
	sweep_body="${sweep_body}${sig_footer}"

	# Skip needs-maintainer-review when user is maintainer (GH#16786)
	local sweep_review_label=""
	if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
		sweep_review_label="--label needs-maintainer-review"
	fi
	# shellcheck disable=SC2086
	if gh_create_issue --repo "$aidevops_slug" \
		--title "perf: simplification debt stalled — LLM sweep needed ($(date -u +%Y-%m-%d))" \
		--label "simplification-debt" $sweep_review_label --label "tier:reasoning" \
		--assignee "$maintainer" \
		--body "$sweep_body" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Complexity LLM sweep: created stall-review issue" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Complexity LLM sweep: failed to create stall-review issue" >>"$LOGFILE"
	fi

	printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	return 0
}

# Resolve the aidevops repo path and validate lint-file-discovery.sh exists.
# Arguments: $1 - repos_json path, $2 - aidevops_slug, $3 - now_epoch
# Outputs: aidevops_path via stdout (empty on failure)
# Returns: 0 on success, 1 on failure (also writes last-run timestamp on failure)
_complexity_scan_find_repo() {
	local repos_json="$1"
	local aidevops_slug="$2"
	local now_epoch="$3"
	local aidevops_path=""
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .path' \
			"$repos_json" 2>/dev/null | head -n 1)
	fi
	if [[ -z "$aidevops_path" || "$aidevops_path" == "null" || ! -d "$aidevops_path" ]]; then
		echo "[pulse-wrapper] Complexity scan: aidevops repo path not found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	local lint_discovery="${aidevops_path}/.agents/scripts/lint-file-discovery.sh"
	if [[ ! -f "$lint_discovery" ]]; then
		echo "[pulse-wrapper] Complexity scan: lint-file-discovery.sh not found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	echo "$aidevops_path"
	return 0
}

# Collect per-file violation counts from shell files in the repo.
# Arguments: $1 - aidevops_path, $2 - now_epoch
# Outputs: scan_results (pipe-delimited lines: file_path|count) via stdout
# Side effect: logs total violation count; writes last-run on no files found
_complexity_scan_collect_violations() {
	local aidevops_path="$1"
	local now_epoch="$2"
	local shell_files
	shell_files=$(git -C "$aidevops_path" ls-files '*.sh' | grep -Ev '_archive/' || true)
	if [[ -z "$shell_files" ]]; then
		echo "[pulse-wrapper] Complexity scan: no shell files found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	local scan_results=""
	local total_violations=0
	local files_with_violations=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${aidevops_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local result
		result=$(awk '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
			fname && /^\}$/ { lines=NR-start; if(lines>'"$COMPLEXITY_FUNC_LINE_THRESHOLD"') printf "%s() %d lines\n", fname, lines; fname="" }
		' "$full_path")
		if [[ -n "$result" ]]; then
			local count
			count=$(echo "$result" | wc -l | tr -d ' ')
			total_violations=$((total_violations + count))
			files_with_violations=$((files_with_violations + 1))
			if [[ "$count" -ge "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" ]]; then
				# Use repo-relative path as dedup key (not basename — avoids collisions
				# between files with the same name in different directories, GH#5630)
				scan_results="${scan_results}${file}|${count}"$'\n'
			fi
		fi
	done <<<"$shell_files"
	echo "[pulse-wrapper] Complexity scan: ${total_violations} violations across ${files_with_violations} files" >>"$LOGFILE"
	printf '%s' "$scan_results"
	return 0
}

# Determine whether an agent doc qualifies for a simplification issue.
# Not every .agents/*.md file is actionable — very short files, empty stubs,
# and YAML-only frontmatter files are not candidates. This gate prevents
# flooding the issue tracker with non-actionable entries (CodeRabbit GH#6879).
# Arguments: $1 - full_path, $2 - line_count
# Returns: 0 if the file should get an issue, 1 if it should be skipped
_complexity_scan_should_open_md_issue() {
	local full_path="$1"
	local line_count="$2"

	# Skip files below the minimum actionable size
	if [[ "$line_count" -lt "$COMPLEXITY_MD_MIN_LINES" ]]; then
		return 1
	fi

	# Skip files that are mostly YAML frontmatter (e.g., stub agent definitions).
	# If >60% of lines are inside the frontmatter block, there's no prose to simplify.
	local frontmatter_end=0
	if head -1 "$full_path" 2>/dev/null | grep -q '^---$'; then
		frontmatter_end=$(awk 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { print NR; exit }' "$full_path" 2>/dev/null)
		frontmatter_end=${frontmatter_end:-0}
	fi
	if [[ "$frontmatter_end" -gt 0 ]]; then
		local content_lines=$((line_count - frontmatter_end))
		# If content after frontmatter is less than 40% of total, skip
		local threshold=$(((line_count * 40) / 100))
		if [[ "$content_lines" -lt "$threshold" ]]; then
			return 1
		fi
	fi

	return 0
}

# Collect agent docs (.md files in .agents/) for simplification analysis.
# No hard file size gate — classification (instruction doc vs reference corpus)
# determines the action, not line count (t1679, code-simplifier.md).
# Files must pass _complexity_scan_should_open_md_issue to be included —
# this filters out stubs, short files, and frontmatter-only definitions.
# Protected files (build.txt, AGENTS.md, pulse.md, pulse-sweep.md) are excluded — these are
# core infrastructure that must be simplified manually with a maintainer present.
# Results are sorted longest-first so biggest wins come early.
# Arguments: $1 - aidevops_path
# Outputs: scan_results (pipe-delimited lines: file_path|line_count) via stdout
_complexity_scan_collect_md_violations() {
	local aidevops_path="$1"

	# Protected files and directories — excluded from automated simplification.
	# - build.txt, AGENTS.md, pulse.md, pulse-sweep.md: core infrastructure (code-simplifier.md)
	# - templates/: template files meant to be copied, not compressed
	# - README.md: navigation/index docs, not instruction docs
	# - todo/: planning files, not code
	local protected_pattern='prompts/build\.txt|^\.agents/AGENTS\.md|^AGENTS\.md|scripts/commands/pulse\.md|scripts/commands/pulse-sweep\.md'
	local excluded_dirs='_archive/|/templates/|/todo/'
	local excluded_files='/README\.md$'

	local md_files
	md_files=$(git -C "$aidevops_path" ls-files '*.md' | grep -E '^\.agents/' | grep -Ev "$excluded_dirs" | grep -Ev "$excluded_files" | grep -Ev "$protected_pattern" || true)
	if [[ -z "$md_files" ]]; then
		echo "[pulse-wrapper] Complexity scan (.md): no agent doc files found" >>"$LOGFILE"
		return 1
	fi

	local scan_results=""
	local file_count=0
	local skipped_count=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${aidevops_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local lc
		lc=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ')
		if _complexity_scan_should_open_md_issue "$full_path" "$lc"; then
			scan_results="${scan_results}${file}|${lc}"$'\n'
			file_count=$((file_count + 1))
		else
			skipped_count=$((skipped_count + 1))
		fi
	done <<<"$md_files"

	# Sort longest-first (descending by line count after the pipe)
	scan_results=$(printf '%s' "$scan_results" | sort -t'|' -k2 -rn)

	echo "[pulse-wrapper] Complexity scan (.md): ${file_count} agent docs qualified, ${skipped_count} skipped (below ${COMPLEXITY_MD_MIN_LINES}-line threshold or stub)" >>"$LOGFILE"
	printf '%s' "$scan_results"
	return 0
}

# Extract a concise, meaningful topic label from a markdown file's H1 heading.
# For chapter-style headings such as "# Chapter 13: Heatmap Analysis", returns
# "Heatmap Analysis" so issue titles stay semantic instead of numeric-only.
# Arguments: $1 - aidevops_path, $2 - file_path (repo-relative)
# Outputs: topic label via stdout
_complexity_scan_extract_md_topic_label() {
	local aidevops_path="$1"
	local file_path="$2"
	local full_path="${aidevops_path}/${file_path}"

	if [[ ! -f "$full_path" ]]; then
		return 1
	fi

	local heading
	heading=$(awk '/^# / { print; exit }' "$full_path" 2>/dev/null)
	if [[ -z "$heading" ]]; then
		return 1
	fi

	local topic
	topic=$(printf '%s' "$heading" | sed -E 's/^#[[:space:]]*//; s/^[Cc][Hh][Aa][Pp][Tt][Ee][Rr][[:space:]]*[0-9]+[[:space:]]*[:.-]?[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//')
	if [[ -z "$topic" ]]; then
		return 1
	fi

	# Keep issue titles concise and stable
	topic=$(printf '%s' "$topic" | cut -c1-80)
	printf '%s' "$topic"
	return 0
}

#######################################
# Simplification state tracking — git-committed registry of simplified files.
#
# State file: .agents/configs/simplification-state.json (in repo, on main)
# Format: { "files": { "path": { "hash": "<git blob sha>", "at": "ISO", "pr": N } } }
#
# - "hash" is the git blob SHA of the file at simplification time
# - When scan sees a file in state with matching hash → skip (already done)
# - When hash differs → file changed since simplification → create recheck issue
# - State is committed to main and pushed, so all users share it
#######################################

# Check if a file has already been simplified and is unchanged.
# Arguments: $1 - repo_path, $2 - file_path (repo-relative), $3 - state_file path
# Returns: 0 = already simplified (unchanged/converged), 1 = not simplified or changed
# Outputs to stdout: "unchanged" | "converged" | "recheck" | "new"
# "converged" means the file has been through SIMPLIFICATION_MAX_PASSES passes
# and should not be re-flagged until it is genuinely modified by non-simplification work.
_simplification_state_check() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"
	local max_passes="${SIMPLIFICATION_MAX_PASSES:-3}"

	if [[ ! -f "$state_file" ]]; then
		echo "new"
		return 1
	fi

	local recorded_hash
	recorded_hash=$(jq -r --arg fp "$file_path" '.files[$fp].hash // empty' "$state_file" 2>/dev/null) || recorded_hash=""

	if [[ -z "$recorded_hash" ]]; then
		echo "new"
		return 1
	fi

	# Compute current git blob hash
	local current_hash
	local full_path="${repo_path}/${file_path}"
	if [[ ! -f "$full_path" ]]; then
		echo "new"
		return 1
	fi
	current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || current_hash=""

	if [[ "$current_hash" == "$recorded_hash" ]]; then
		echo "unchanged"
		return 0
	fi

	# Hash differs — check pass count before flagging for recheck (t1754).
	# Files that have been through max_passes simplification rounds are
	# considered converged. They won't be re-flagged until the hash is
	# refreshed by _simplification_state_refresh (which resets passes to 0
	# only when the file is genuinely modified by non-simplification work).
	local passes
	passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$state_file" 2>/dev/null) || passes=0
	if [[ "$passes" -ge "$max_passes" ]]; then
		echo "converged"
		return 0
	fi

	echo "recheck"
	return 1
}

# Record a file as simplified in the state file.
# Increments the pass counter each time a file is re-simplified (t1754).
# Arguments: $1 - repo_path, $2 - file_path, $3 - state_file, $4 - pr_number
_simplification_state_record() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"
	local pr_number="${4:-0}"

	local current_hash
	local full_path="${repo_path}/${file_path}"
	current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || current_hash=""
	[[ -z "$current_hash" ]] && return 1

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Ensure state file exists with valid structure
	if [[ ! -f "$state_file" ]]; then
		printf '{"files":{}}\n' >"$state_file"
	fi

	# Read existing pass count and increment (t1754 — convergence tracking)
	local prev_passes
	prev_passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$state_file" 2>/dev/null) || prev_passes=0
	local new_passes=$((prev_passes + 1))

	# Update the entry using jq — includes pass counter
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg fp "$file_path" --arg hash "$current_hash" --arg at "$now_iso" \
		--argjson pr "$pr_number" --argjson passes "$new_passes" \
		'.files[$fp] = {"hash": $hash, "at": $at, "pr": $pr, "passes": $passes}' \
		"$state_file" >"$tmp_file" 2>/dev/null && mv "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
	return 0
}

# Refresh all hashes in the simplification state file against current main (t1754).
# This replaces the fragile timeline-API-based backfill. For every file already
# in state, recompute git hash-object. If the hash matches, do nothing. If it
# differs, update the hash AND increment the pass counter (the file was changed
# by a simplification PR that merged since the last scan).
# Arguments: $1 - repo_path, $2 - state_file path
# Returns: 0 on success. Outputs refreshed count to stdout.
_simplification_state_refresh() {
	local repo_path="$1"
	local state_file="$2"
	local refreshed=0

	if [[ ! -f "$state_file" ]]; then
		echo "0"
		return 0
	fi

	local file_paths
	file_paths=$(jq -r '.files | keys[]' "$state_file" 2>/dev/null) || file_paths=""
	[[ -z "$file_paths" ]] && {
		echo "0"
		return 0
	}

	local tmp_state
	tmp_state=$(mktemp)
	cp "$state_file" "$tmp_state"

	while IFS= read -r fp; do
		[[ -z "$fp" ]] && continue
		local full_path="${repo_path}/${fp}"
		[[ ! -f "$full_path" ]] && continue

		local current_hash stored_hash
		current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || continue
		stored_hash=$(jq -r --arg fp "$fp" '.files[$fp].hash // empty' "$tmp_state" 2>/dev/null) || stored_hash=""

		# Also fix any non-SHA1 hashes (wrong algorithm, t1754)
		local stored_len=${#stored_hash}
		if [[ "$current_hash" != "$stored_hash" || "$stored_len" -ne 40 ]]; then
			local now_iso prev_passes new_passes
			now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
			prev_passes=$(jq -r --arg fp "$fp" '.files[$fp].passes // 0' "$tmp_state" 2>/dev/null) || prev_passes=0
			new_passes=$((prev_passes + 1))
			local inner_tmp
			inner_tmp=$(mktemp)
			jq --arg fp "$fp" --arg hash "$current_hash" --arg at "$now_iso" \
				--argjson passes "$new_passes" \
				'.files[$fp].hash = $hash | .files[$fp].at = $at | .files[$fp].passes = $passes' \
				"$tmp_state" >"$inner_tmp" 2>/dev/null && mv "$inner_tmp" "$tmp_state" || rm -f "$inner_tmp"
			refreshed=$((refreshed + 1))
		fi
	done <<<"$file_paths"

	if [[ "$refreshed" -gt 0 ]]; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
	fi
	echo "$refreshed"
	return 0
}

# Prune stale entries from simplification state (files that no longer exist).
# This handles file moves/renames/deletions — entries for non-existent files
# are removed so they don't cause false "recheck" status or accumulate.
# Arguments: $1 - repo_path, $2 - state_file path
# Returns: 0 = pruned (or nothing to prune), 1 = error
# Outputs to stdout: number of entries pruned
_simplification_state_prune() {
	local repo_path="$1"
	local state_file="$2"

	if [[ ! -f "$state_file" ]]; then
		echo "0"
		return 0
	fi

	local all_paths
	all_paths=$(jq -r '.files | keys[]' "$state_file" 2>/dev/null) || {
		echo "0"
		return 1
	}

	local pruned=0
	local stale_paths=""
	while IFS= read -r file_path; do
		[[ -z "$file_path" ]] && continue
		local full_path="${repo_path}/${file_path}"
		if [[ ! -f "$full_path" ]]; then
			stale_paths="${stale_paths}${file_path}\n"
			pruned=$((pruned + 1))
		fi
	done <<<"$all_paths"

	if [[ "$pruned" -gt 0 ]]; then
		local tmp_file
		tmp_file=$(mktemp)
		# Remove all stale entries in one jq pass
		local jq_filter=".files"
		while IFS= read -r sp; do
			[[ -z "$sp" ]] && continue
			jq_filter="${jq_filter} | del(.[\"${sp}\"])"
		done < <(printf '%b' "$stale_paths")
		jq "${jq_filter} | {\"files\": .}" "$state_file" >"$tmp_file" 2>/dev/null || {
			# Fallback: remove one at a time
			cp "$state_file" "$tmp_file"
			while IFS= read -r sp; do
				[[ -z "$sp" ]] && continue
				local tmp2
				tmp2=$(mktemp)
				jq --arg fp "$sp" 'del(.files[$fp])' "$tmp_file" >"$tmp2" 2>/dev/null && mv "$tmp2" "$tmp_file" || rm -f "$tmp2"
			done < <(printf '%b' "$stale_paths")
		}
		mv "$tmp_file" "$state_file" || {
			rm -f "$tmp_file"
			echo "0"
			return 1
		}
	fi

	echo "$pruned"
	return 0
}

# Commit and push simplification state to main (planning data, not code).
# Arguments: $1 - repo_path
_simplification_state_push() {
	local repo_path="$1"
	local state_rel=".agents/configs/simplification-state.json"

	# Only push from the canonical (main) worktree
	local main_branch
	main_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || main_branch="main"
	local current_branch
	current_branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch=""

	if [[ "$current_branch" != "$main_branch" ]]; then
		echo "[pulse-wrapper] simplification-state: skipping push — not on $main_branch (on $current_branch)" >>"$LOGFILE"
		return 0
	fi

	if ! git -C "$repo_path" diff --quiet -- "$state_rel" 2>/dev/null; then
		git -C "$repo_path" add "$state_rel" 2>/dev/null || return 1
		git -C "$repo_path" commit -m "chore: update simplification state registry" --no-verify 2>/dev/null || return 1
		git -C "$repo_path" push origin "$main_branch" 2>/dev/null || return 1
		echo "[pulse-wrapper] simplification-state: pushed updated state to $main_branch" >>"$LOGFILE"
	fi
	return 0
}

# Backfill simplification state for recently closed issues (t1855).
#
# The critical bug: _simplification_state_record() was defined but never called.
# Workers complete simplification PRs and issues auto-close via "Closes #NNN",
# but the state file never gets updated. This function runs each scan cycle
# to detect recently closed simplification issues and record their file hashes.
#
# Arguments: $1 - repo_path, $2 - state_file, $3 - aidevops_slug
# Returns: 0. Outputs count of entries added to stdout.
_simplification_state_backfill_closed() {
	local repo_path="$1"
	local state_file="$2"
	local aidevops_slug="$3"
	local added=0

	# Fetch recently closed simplification issues (last 7 days, max 50)
	local closed_issues
	closed_issues=$(gh issue list --repo "$aidevops_slug" \
		--label "simplification-debt" --state closed \
		--limit 50 --json number,title,closedAt 2>/dev/null) || {
		echo "0"
		return 0
	}
	[[ -z "$closed_issues" || "$closed_issues" == "[]" ]] && {
		echo "0"
		return 0
	}

	local tmp_state
	tmp_state=$(mktemp)
	cp "$state_file" "$tmp_state"

	# Use process substitution to avoid subshell variable propagation bug (t1855).
	# A pipe (| while read) runs the loop in a subshell where $added won't propagate.
	while IFS= read -r issue; do
		[[ -z "$issue" ]] && continue
		local title file_path issue_num

		title=$(echo "$issue" | jq -r '.title') || continue
		issue_num=$(echo "$issue" | jq -r '.number') || continue

		# Extract file path from title — pattern: "simplification: tighten agent doc ... (path, N lines)"
		# or "simplification: reduce function complexity in path (N functions ...)"
		file_path=$(echo "$title" | grep -oE '\.[a-z][^ ,)]+\.(md|sh)' | head -1) || continue
		[[ -z "$file_path" ]] && continue

		# Skip if file doesn't exist
		[[ ! -f "${repo_path}/${file_path}" ]] && continue

		# Skip if already in state with matching hash
		local existing_hash
		existing_hash=$(jq -r --arg fp "$file_path" '.files[$fp].hash // empty' "$tmp_state" 2>/dev/null) || existing_hash=""
		local current_hash
		current_hash=$(git -C "$repo_path" hash-object "${repo_path}/${file_path}" 2>/dev/null) || continue

		if [[ "$existing_hash" == "$current_hash" ]]; then
			continue
		fi

		# Record the file in state — either new entry or updated hash
		local now_iso prev_passes new_passes
		now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
		prev_passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$tmp_state" 2>/dev/null) || prev_passes=0
		new_passes=$((prev_passes + 1))

		local inner_tmp
		inner_tmp=$(mktemp)
		jq --arg fp "$file_path" --arg hash "$current_hash" --arg at "$now_iso" \
			--argjson pr "$issue_num" --argjson passes "$new_passes" \
			'.files[$fp] = {"hash": $hash, "at": $at, "pr": $pr, "passes": $passes}' \
			"$tmp_state" >"$inner_tmp" 2>/dev/null && mv "$inner_tmp" "$tmp_state" || {
			rm -f "$inner_tmp"
			continue
		}
		added=$((added + 1))
	done < <(echo "$closed_issues" | jq -c '.[]')

	if [[ "$added" -gt 0 ]]; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
	fi
	echo "$added"
	return 0
}

# Check if an open simplification-debt issue already exists for a given file.
#
# Uses GitHub search API via `gh issue list --search` to query server-side,
# avoiding the --limit 200 cap that caused duplicate issues (GH#10783).
# Previous approach fetched 200 issues locally and checked with jq, but with
# 3000+ open simplification-debt issues, most were invisible to the dedup check.
#
# Arguments:
#   $1 - repo_slug (owner/repo for gh commands)
#   $2 - issue_key (repo-relative file path used as dedup key)
# Exit codes:
#   0 - existing issue found (skip creation)
#   1 - no existing issue (safe to create)
_complexity_scan_has_existing_issue() {
	local repo_slug="$1"
	local issue_key="$2"

	# Server-side search by file path in title — accurate across all issues,
	# not limited by --limit pagination. The file path is always in the title.
	local match_count
	match_count=$(gh issue list --repo "$repo_slug" \
		--label "simplification-debt" --state open \
		--search "in:title \"$issue_key\"" \
		--json number --jq 'length' 2>/dev/null) || match_count="0"
	if [[ "${match_count:-0}" -gt 0 ]]; then
		return 0
	fi

	# Fallback: search in issue body for the structured **File:** field.
	# This catches issues where the title format differs (e.g., Qlty issues).
	match_count=$(gh issue list --repo "$repo_slug" \
		--label "simplification-debt" --state open \
		--search "\"$issue_key\" in:body" \
		--json number --jq 'length' 2>/dev/null) || match_count="0"

	if [[ "$match_count" -gt 0 ]]; then
		return 0
	fi

	return 1
}

# Close open duplicate simplification-debt issues for an exact title.
#
# This is a post-create race repair for cross-machine TOCTOU collisions:
# two runners can both pass pre-create dedup checks, then both create the
# same issue title seconds apart. This helper converges to a single open
# issue by keeping the newest and closing older duplicates immediately.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - issue_title (exact title match)
# Returns:
#   0 always (best-effort)
_complexity_scan_close_duplicate_issues_by_title() {
	local repo_slug="$1"
	local issue_title="$2"

	local issue_numbers=""
	if ! issue_numbers=$(T="$issue_title" gh issue list --repo "$repo_slug" \
		--label "simplification-debt" --state open \
		--search "in:title \"${issue_title}\"" \
		--limit 100 --json number,title \
		--jq 'map(select(.title == env.T) | .number) | sort | .[]'); then
		echo "[pulse-wrapper] Complexity scan: failed to query duplicates for title: ${issue_title}" >>"$LOGFILE"
		return 0
	fi

	[[ -z "$issue_numbers" ]] && return 0

	local issue_count=0
	local keep_number=""
	local issue_number
	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		issue_count=$((issue_count + 1))
		# Keep the newest issue (largest number) for consistency with
		# run_simplification_dedup_cleanup.
		keep_number="$issue_number"
	done <<<"$issue_numbers"

	if [[ "$issue_count" -le 1 || -z "$keep_number" ]]; then
		return 0
	fi

	local closed_count=0
	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		[[ "$issue_number" == "$keep_number" ]] && continue
		if gh issue close "$issue_number" --repo "$repo_slug" --reason "not planned" \
			--comment "Auto-closing duplicate from concurrent simplification scan run. Keeping newest issue #${keep_number}." \
			>/dev/null 2>&1; then
			closed_count=$((closed_count + 1))
		fi
	done <<<"$issue_numbers"

	if [[ "$closed_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Complexity scan: closed ${closed_count} duplicate simplification-debt issue(s) for title: ${issue_title}" >>"$LOGFILE"
	fi

	return 0
}

# Build the GitHub issue body for an agent doc flagged for simplification review.
# Arguments:
#   $1 - file_path (repo-relative)
#   $2 - line_count
#   $3 - topic_label (may be empty)
# Output: issue body text to stdout
_complexity_scan_build_md_issue_body() {
	local file_path="$1"
	local line_count="$2"
	local topic_label="$3"

	cat <<ISSUE_BODY_EOF
## Agent doc simplification (automated scan)

**File:** \`${file_path}\`
**Detected topic:** ${topic_label:-Unknown}
**Current size:** ${line_count} lines

### Classify before acting

**First, determine the file type** — the correct action depends on whether this is an instruction doc or a reference corpus:

- **Instruction doc** (agent rules, workflows, decision trees, operational procedures): Tighten prose, reorder by importance, split if multiple concerns. Follow guidance below.
- **Reference corpus** (SKILL.md, domain knowledge base, textbook-style content with self-contained sections): Do NOT compress content. Instead, split into chapter files with a slim index. See \`tools/code-review/code-simplifier.md\` "Reference corpora" classification (GH#6432).

### For instruction docs — proposed action

Tighten and restructure this agent doc. Follow \`tools/build-agent/build-agent.md\` guidance. Key principles:

1. **Preserve all institutional knowledge** — every verbose rule exists because something broke without it. Do not remove task IDs, incident references, error statistics, or decision rationale. Compress prose, not knowledge.
2. **Order by importance** — most critical instructions first (primacy effect: LLMs weight earlier context more heavily). Security rules, core workflow, then edge cases.
3. **Split if needed** — if the file covers multiple distinct concerns, extract sub-docs with a parent index. Use progressive disclosure (pointers, not inline content).
4. **Use search patterns, not line numbers** — any \`file:line_number\` references to other files go stale on every edit. Use \`rg "pattern"\` or section heading references instead.

### For reference corpora — proposed action

1. **Extract each major section** into its own file (e.g., \`01-introduction.md\`, \`02-fundamentals.md\`)
2. **Replace the original with a slim index** (~100-200 lines) — table of contents with one-line descriptions and file pointers
3. **Zero content loss** — every line moves to a chapter file, nothing is deleted or compressed
4. **Reconcile existing chapter files** — if partial splits already exist, deduplicate and keep the most complete version

### Verification

- Content preservation: all code blocks, URLs, task ID references (\`tNNN\`, \`GH#NNN\`), and command examples must be present before and after
- No broken internal links or references
- Agent behaviour unchanged (test with a representative query if possible)
- For reference corpora: \`wc -l\` total of chapter files >= original line count minus index overhead

### Confidence: medium

Automated scan flagged this file for maintainer review. The best simplification strategy requires human judgment — some files are appropriately structured already. Reference corpora (SKILL.md, domain knowledge bases) need restructuring into chapters, not content reduction.

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)
ISSUE_BODY_EOF
	return 0
}

# Check if the open simplification-debt issue backlog exceeds the cap.
# Arguments: $1 - aidevops_slug, $2 - cap (default 100), $3 - log_prefix
# Exit codes: 0 = under cap (safe to create), 1 = at/over cap (skip)
_complexity_scan_check_open_cap() {
	local aidevops_slug="$1"
	local cap="${2:-200}"
	local log_prefix="${3:-Complexity scan}"

	local total_open
	total_open=$(gh api graphql -f query="query { repository(owner:\"${aidevops_slug%%/*}\", name:\"${aidevops_slug##*/}\") { issues(labels:[\"simplification-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || total_open="0"
	if [[ "${total_open:-0}" -ge "$cap" ]]; then
		echo "[pulse-wrapper] ${log_prefix}: skipping — ${total_open} open simplification-debt issues (cap: ${cap})" >>"$LOGFILE"
		return 1
	fi
	return 0
}

# Process a single agent doc file for simplification issue creation (GH#5627).
# Checks simplification state, dedup, changed-since-simplification status,
# builds title/body, and creates issue.
#
# Arguments:
#   $1 - file_path (repo-relative)
#   $2 - line_count
#   $3 - aidevops_slug
#   $4 - aidevops_path
#   $5 - state_file (may be empty)
#   $6 - maintainer
# Output: single line to stdout — "created", "skipped", or "failed"
_complexity_scan_process_single_md_file() {
	local file_path="$1"
	local line_count="$2"
	local aidevops_slug="$3"
	local aidevops_path="$4"
	local state_file="$5"
	local maintainer="$6"

	# Cache simplification state to avoid redundant jq + git hash-object calls
	local file_status="new"
	if [[ -n "$state_file" && -n "$aidevops_path" ]]; then
		file_status=$(_simplification_state_check "$aidevops_path" "$file_path" "$state_file")
		if [[ "$file_status" == "unchanged" ]]; then
			echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — already simplified (hash unchanged)" >>"$LOGFILE"
			echo "skipped"
			return 0
		fi
		if [[ "$file_status" == "converged" ]]; then
			echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — converged after ${SIMPLIFICATION_MAX_PASSES:-3} passes (t1754)" >>"$LOGFILE"
			echo "skipped"
			return 0
		fi
		# "recheck" files fall through — they get a new issue with recheck label
	fi

	if _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
		echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — existing open issue" >>"$LOGFILE"
		echo "skipped"
		return 0
	fi

	local topic_label=""
	if [[ -n "$aidevops_path" ]]; then
		topic_label=$(_complexity_scan_extract_md_topic_label "$aidevops_path" "$file_path" 2>/dev/null || true)
	fi

	# Determine whether this file needs simplification recheck
	local needs_recheck=false
	if [[ "$file_status" == "recheck" ]]; then
		needs_recheck=true
	fi

	local issue_title="simplification: tighten agent doc ${file_path} (${line_count} lines)"
	if [[ -n "$topic_label" ]]; then
		issue_title="simplification: tighten agent doc ${topic_label} (${file_path}, ${line_count} lines)"
	fi
	if [[ "$needs_recheck" == true ]]; then
		issue_title="recheck: ${issue_title}"
	fi

	local issue_body
	issue_body=$(_complexity_scan_build_md_issue_body "$file_path" "$line_count" "$topic_label")
	if [[ "$needs_recheck" == true ]]; then
		local prev_pr
		prev_pr=$(jq -r --arg fp "$file_path" '.files[$fp].pr // 0' "$state_file" 2>/dev/null) || prev_pr="0"
		issue_body="${issue_body}

### Recheck note

This file was previously simplified (PR #${prev_pr}) but has since been modified. The content hash no longer matches the post-simplification state. Please re-evaluate."
	fi

	# Append signature footer. The pulse-wrapper runs as standalone bash via
	# launchd (not inside OpenCode), so --no-session skips session DB lookups.
	# Pass elapsed time and 0 tokens to show honest stats (GH#13099).
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	issue_body="${issue_body}${sig_footer}"

	# Build label list — skip needs-maintainer-review when user is maintainer (GH#16786)
	local review_label=""
	if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
		review_label="--label needs-maintainer-review"
	fi

	local create_ok=false
	if [[ "$needs_recheck" == true ]]; then
		# shellcheck disable=SC2086
		gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "simplification-debt" $review_label --label "tier:standard" --label "recheck-simplicity" \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	else
		# shellcheck disable=SC2086
		gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "simplification-debt" $review_label --label "tier:standard" \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	fi

	if [[ "$create_ok" == true ]]; then
		_complexity_scan_close_duplicate_issues_by_title "$aidevops_slug" "$issue_title"
		local log_suffix=""
		if [[ "$needs_recheck" == true ]]; then log_suffix=" [RECHECK]"; fi
		echo "[pulse-wrapper] Complexity scan (.md): created issue for ${file_path} (${line_count} lines)${log_suffix}" >>"$LOGFILE"
		echo "created"
	else
		echo "[pulse-wrapper] Complexity scan (.md): failed to create issue for ${file_path}" >>"$LOGFILE"
		echo "failed"
	fi
	return 0
}

# Create GitHub issues for agent docs flagged for simplification review.
# Default to tier:standard — simplification requires reading the file, understanding
# its structure, deciding what to extract vs compress, and preserving institutional
# knowledge. Haiku-tier models lack the judgment for this; they over-compress,
# lose task IDs, or restructure without understanding the reasoning behind the
# original layout. Maintainers can raise to tier:reasoning for architectural docs.
# Arguments: $1 - scan_results (pipe-delimited: file_path|line_count), $2 - repos_json, $3 - aidevops_slug
_complexity_scan_create_md_issues() {
	local scan_results="$1"
	local repos_json="$2"
	local aidevops_slug="$3"
	local max_issues_per_run=5
	local issues_created=0
	local issues_skipped=0

	# Total-open cap: stop creating when backlog is already large
	_complexity_scan_check_open_cap "$aidevops_slug" 500 "Complexity scan (.md)" || return 0

	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	if [[ -z "$maintainer" ]]; then
		maintainer=$(echo "$aidevops_slug" | cut -d/ -f1)
	fi

	local aidevops_path
	aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .path' \
		"$repos_json" 2>/dev/null | head -n 1)

	# Simplification state file — tracks already-simplified files by git blob hash
	local state_file=""
	if [[ -n "$aidevops_path" ]]; then
		state_file="${aidevops_path}/.agents/configs/simplification-state.json"
	fi

	while IFS='|' read -r file_path line_count; do
		[[ -n "$file_path" ]] || continue
		[[ "$issues_created" -ge "$max_issues_per_run" ]] && break

		local result
		result=$(_complexity_scan_process_single_md_file "$file_path" "$line_count" \
			"$aidevops_slug" "$aidevops_path" "$state_file" "$maintainer")

		case "$result" in
		created) issues_created=$((issues_created + 1)) ;;
		skipped) issues_skipped=$((issues_skipped + 1)) ;;
		*) ;; # failed — logged by helper, no counter change
		esac
	done <<<"$scan_results"
	echo "[pulse-wrapper] Complexity scan (.md) complete: ${issues_created} issues created, ${issues_skipped} skipped (existing/simplified)" >>"$LOGFILE"
	return 0
}

# Create GitHub issues for qualifying files (dedup via server-side title search).
# Arguments: $1 - scan_results (pipe-delimited: file_path|count), $2 - repos_json, $3 - aidevops_slug
# Returns: 0 always
_complexity_scan_create_issues() {
	local scan_results="$1"
	local repos_json="$2"
	local aidevops_slug="$3"
	local max_issues_per_run=5
	local issues_created=0
	local issues_skipped=0

	# Total-open cap: stop creating when backlog is already large
	_complexity_scan_check_open_cap "$aidevops_slug" 500 "Complexity scan" || return 0

	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	if [[ -z "$maintainer" ]]; then
		maintainer=$(echo "$aidevops_slug" | cut -d/ -f1)
	fi

	while IFS='|' read -r file_path violation_count; do
		[[ -n "$file_path" ]] || continue
		[[ "$issues_created" -ge "$max_issues_per_run" ]] && break

		# Skip nesting-only violations (GH#17632): files flagged solely for max_nesting
		# exceeding the threshold have violation_count=0 (no long functions). The current
		# issue template is function-length-specific; creating a "0 functions >100 lines"
		# issue is misleading and produces false-positive dispatch work.
		if [[ "${violation_count:-0}" -eq 0 ]]; then
			echo "[pulse-wrapper] Complexity scan: skipping ${file_path} — nesting-only violation (0 long functions)" >>"$LOGFILE"
			issues_skipped=$((issues_skipped + 1))
			continue
		fi

		# Dedup via server-side title search — accurate across all issues (GH#5630)
		if _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
			echo "[pulse-wrapper] Complexity scan: skipping ${file_path} — existing open issue" >>"$LOGFILE"
			issues_skipped=$((issues_skipped + 1))
			continue
		fi

		# Compute details inside the issue-creation loop (not stored in scan_results
		# to avoid multiline values breaking the IFS='|' parser, GH#5630)
		local aidevops_path
		aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .path' \
			"$repos_json" 2>/dev/null | head -n 1)
		local details=""
		if [[ -n "$aidevops_path" && -f "${aidevops_path}/${file_path}" ]]; then
			details=$(awk '
				/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
				fname && /^\}$/ { lines=NR-start; if(lines>'"$COMPLEXITY_FUNC_LINE_THRESHOLD"') printf "%s() %d lines\n", fname, lines; fname="" }
			' "${aidevops_path}/${file_path}" | head -10)
		fi

		local issue_body
		issue_body="## Complexity scan finding (automated, GH#5628)

**File:** \`${file_path}\`
**Violations:** ${violation_count} functions exceed ${COMPLEXITY_FUNC_LINE_THRESHOLD} lines

### Functions exceeding threshold

\`\`\`
${details}
\`\`\`

### Proposed action

Break down the listed functions into smaller, focused helper functions. Each function should ideally be under ${COMPLEXITY_FUNC_LINE_THRESHOLD} lines.

### Verification

- \`bash -n <file>\` (syntax check)
- \`shellcheck <file>\` (lint)
- Run existing tests if present
- Confirm no functionality is lost

### Confidence: medium

This is an automated scan. The function lengths are factual, but the best decomposition strategy requires human judgment.

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)"
		# Append signature footer (--no-session + elapsed time, GH#13099)
		local sig_footer2="" _pulse_elapsed2=""
		_pulse_elapsed2=$(($(date +%s) - PULSE_START_EPOCH))
		sig_footer2=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
			--body "$issue_body" --cli "OpenCode" --no-session \
			--tokens 0 --time "$_pulse_elapsed2" --session-type routine 2>/dev/null || true)
		issue_body="${issue_body}${sig_footer2}"

		local issue_key="$file_path"
		local issue_title="simplification: reduce function complexity in ${issue_key} (${violation_count} functions >${COMPLEXITY_FUNC_LINE_THRESHOLD} lines)"
		# Skip needs-maintainer-review when user is maintainer (GH#16786)
		local review_label_sh=""
		if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
			review_label_sh="--label needs-maintainer-review"
		fi
		# shellcheck disable=SC2086
		if gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "simplification-debt" $review_label_sh \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1; then
			_complexity_scan_close_duplicate_issues_by_title "$aidevops_slug" "$issue_title"
			issues_created=$((issues_created + 1))
			echo "[pulse-wrapper] Complexity scan: created issue for ${file_path} (${violation_count} violations)" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Complexity scan: failed to create issue for ${file_path}" >>"$LOGFILE"
		fi
	done <<<"$scan_results"
	echo "[pulse-wrapper] Complexity scan complete: ${issues_created} issues created, ${issues_skipped} skipped (existing)" >>"$LOGFILE"
	return 0
}

#######################################
# Complexity scan (GH#5628, GH#15285)
#
# Deterministic scan using shell-based heuristics via complexity-scan-helper.sh:
# - Batch hash comparison against simplification-state.json (skip unchanged files)
# - Shell heuristics: line count, function count, nesting depth
# - No per-file LLM analysis — LLM reserved for daily deep sweep only
#
# Scans both shell scripts (.sh) and agent docs (.md) for complexity:
# - .sh files: functions exceeding COMPLEXITY_FUNC_LINE_THRESHOLD lines
# - .md files: all agent docs (no size gate — classification determines action, t1679)
#
# Protected files (build.txt, AGENTS.md, pulse.md, pulse-sweep.md) are excluded.
# Results processed longest-first. .md issues get tier:standard by default.
#
# Daily LLM sweep (GH#15285): if simplification debt hasn't decreased in 6h,
# creates a tier:reasoning issue for LLM-powered deep review of stalled debt.
#
# Runs at most once per COMPLEXITY_SCAN_INTERVAL (default 15 min).
# Creates up to 5 issues per run; open cap (500) prevents backlog flooding.
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################

#######################################
# Close duplicate simplification-debt issues across pulse-enabled repos.
#
# For each repo, fetches open simplification-debt issues and groups by
# file path extracted from the title. When multiple issues exist for the
# same file, keeps the newest and closes the rest as "not planned".
#
# Rate-limited: closes at most DEDUP_CLEANUP_BATCH_SIZE issues per run
# and runs at most once per DEDUP_CLEANUP_INTERVAL (default: daily).
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
run_simplification_dedup_cleanup() {
	local now_epoch
	now_epoch=$(date +%s)

	# Interval guard
	if [[ -f "$DEDUP_CLEANUP_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$DEDUP_CLEANUP_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
		local elapsed=$((now_epoch - last_run))
		if [[ "$elapsed" -lt "$DEDUP_CLEANUP_INTERVAL" ]]; then
			return 0
		fi
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local repo_slugs
	repo_slugs=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null) || repo_slugs=""
	[[ -z "$repo_slugs" ]] && return 0

	local total_closed=0
	local batch_limit="$DEDUP_CLEANUP_BATCH_SIZE"

	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		[[ "$total_closed" -ge "$batch_limit" ]] && break

		# Use jq to extract file paths from titles and find duplicates server-side.
		# Strategy: fetch issues sorted by number ascending (oldest first), extract
		# file path from title via jq regex, group by path, and collect all but the
		# last (newest) issue number from each group as duplicates to close.
		local dupe_numbers
		dupe_numbers=$(gh issue list --repo "$slug" \
			--label "simplification-debt" --state open \
			--limit 500 --json number,title \
			--jq '
				sort_by(.number) |
				[.[] | {
					number,
					file: (
						(.title | capture("\\((?<p>[^,)]+\\.(sh|md|py|ts|js))[,)]") // null | .p) //
						(.title | capture("in (?<p>[^ ]+\\.(sh|md|py|ts|js))") // null | .p) //
						null
					)
				}] |
				[.[] | select(.file != null)] |
				group_by(.file) |
				[.[] | select(length > 1) | .[:-1][].number] |
				.[]
			' 2>/dev/null) || dupe_numbers=""

		[[ -z "$dupe_numbers" ]] && continue

		while IFS= read -r dupe_num; do
			[[ -z "$dupe_num" ]] && continue
			[[ "$total_closed" -ge "$batch_limit" ]] && break
			if gh issue close "$dupe_num" --repo "$slug" --reason "not planned" \
				--comment "Auto-closing duplicate: another simplification-debt issue exists for this file. Keeping the newest." \
				>/dev/null 2>&1; then
				total_closed=$((total_closed + 1))
			fi
		done <<<"$dupe_numbers"
	done <<<"$repo_slugs"

	echo "$now_epoch" >"$DEDUP_CLEANUP_LAST_RUN"
	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Dedup cleanup: closed ${total_closed} duplicate simplification-debt issue(s)" >>"$LOGFILE"
	fi
	return 0
}

run_weekly_complexity_scan() {
	local repos_json="$REPOS_JSON"
	local aidevops_slug="marcusquinn/aidevops"

	local now_epoch
	now_epoch=$(date +%s)

	_complexity_scan_check_interval "$now_epoch" || return 0

	# Permission gate: only collaborators/maintainers/admins may create
	# simplification issues. Non-collaborator instances running a pulse with
	# this repo in their repos.json were filing spurious issues (GH#16786).
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null) || current_user=""
	if [[ -n "$current_user" ]]; then
		local perm_level
		perm_level=$(gh api "repos/${aidevops_slug}/collaborators/${current_user}/permission" \
			--jq '.permission' 2>/dev/null) || perm_level=""
		case "$perm_level" in
		admin | maintain | write) ;; # allowed
		*)
			echo "[pulse-wrapper] Complexity scan: skipped — user '$current_user' has '$perm_level' permission on $aidevops_slug (need write+)" >>"$LOGFILE"
			return 0
			;;
		esac
	fi

	# When the authenticated user IS the repo maintainer, skip the
	# needs-maintainer-review label — the standard auto-dispatch + PR
	# review flow provides sufficient gating (GH#16786).
	local maintainer_from_config
	maintainer_from_config=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$REPOS_JSON" 2>/dev/null)
	[[ -z "$maintainer_from_config" ]] && maintainer_from_config=$(printf '%s' "$aidevops_slug" | cut -d/ -f1)
	_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=false
	if [[ "$current_user" == "$maintainer_from_config" ]]; then
		_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=true
	fi

	local aidevops_path
	aidevops_path=$(_complexity_scan_find_repo "$repos_json" "$aidevops_slug" "$now_epoch") || return 0

	# Deterministic skip: if no tracked files changed since last scan, skip all
	# file iteration (O(1) tree hash check vs O(n) per-file awk/wc scan).
	# GH#15285: this is the primary perf fix — most pulse cycles see no changes.
	local tree_changed=true
	if ! _complexity_scan_tree_changed "$aidevops_path"; then
		tree_changed=false
	fi

	# Daily LLM sweep: check independently of tree change — debt can stall even
	# when no files changed (workers not dispatching, issues blocked, etc.).
	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	if [[ -z "$maintainer" ]]; then
		maintainer=$(printf '%s' "$aidevops_slug" | cut -d/ -f1)
	fi
	if _complexity_llm_sweep_due "$now_epoch" "$aidevops_slug"; then
		_complexity_run_llm_sweep "$aidevops_slug" "$now_epoch" "$maintainer"
	fi

	# If tree unchanged, update last-run timestamp and return — no file work needed.
	if [[ "$tree_changed" == false ]]; then
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 0
	fi

	echo "[pulse-wrapper] Running deterministic complexity scan (GH#5628, GH#15285)..." >>"$LOGFILE"

	# Ensure recheck label exists (used when a simplified file changes)
	gh label create "recheck-simplicity" --repo "$aidevops_slug" --color "D4C5F9" \
		--description "File changed since last simplification and needs recheck" --force 2>/dev/null || true

	# Phase 1: Refresh simplification state hashes against current main (t1754).
	# Replaces the previous timeline-API-based backfill which was fragile and
	# frequently missed state updates, causing infinite recheck loops.
	# Now simply recomputes git hash-object for every file in state and updates
	# any that differ. This catches all modifications (simplification PRs,
	# feature work, refactors) without depending on GitHub API link resolution.
	local state_file="${aidevops_path}/.agents/configs/simplification-state.json"
	local state_updated=false

	# Prune stale entries (files moved/renamed/deleted since last scan)
	local pruned_count
	pruned_count=$(_simplification_state_prune "$aidevops_path" "$state_file")
	if [[ "$pruned_count" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: pruned $pruned_count stale entries (files no longer exist)" >>"$LOGFILE"
		state_updated=true
	fi

	# Refresh all hashes — O(n) git hash-object calls, no API requests (t1754)
	local refreshed_count
	refreshed_count=$(_simplification_state_refresh "$aidevops_path" "$state_file")
	if [[ "$refreshed_count" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: refreshed $refreshed_count hashes (files changed since last scan)" >>"$LOGFILE"
		state_updated=true
	fi

	# Backfill state for recently closed issues (t1855).
	# _simplification_state_record() was defined but never called — workers
	# complete simplification and close issues, but the state file was never
	# updated. This backfill detects closed issues and records their file hashes
	# so the scanner knows they're done and doesn't create duplicate issues.
	local backfilled_count
	backfilled_count=$(_simplification_state_backfill_closed "$aidevops_path" "$state_file" "$aidevops_slug")
	if [[ "${backfilled_count:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: backfilled $backfilled_count entries from recently closed issues (t1855)" >>"$LOGFILE"
		state_updated=true
	fi

	# Push state file if updated (planning data — direct to main)
	if [[ "$state_updated" == true ]]; then
		_simplification_state_push "$aidevops_path"
	fi

	# Phase 2+3: Deterministic complexity scan via helper (GH#15285)
	# Uses shell-based heuristics (line count, function count, nesting depth)
	# with batch hash comparison against simplification-state.json.
	# Only processes files whose hash has changed since last scan.
	local scan_helper="${SCRIPT_DIR}/complexity-scan-helper.sh"
	if [[ -x "$scan_helper" ]]; then
		# Shell files — convert helper output to existing issue creation format
		local sh_scan_output
		sh_scan_output=$("$scan_helper" scan "$aidevops_path" --type sh --state-file "$state_file" 2>>"$LOGFILE") || true
		if [[ -n "$sh_scan_output" ]]; then
			# Helper outputs: status|file_path|line_count|func_count|long_func_count|max_nesting|file_type
			# Issue creation expects: file_path|violation_count
			local sh_results=""
			while IFS='|' read -r _status file_path _lines _funcs long_funcs _nesting _type; do
				[[ -n "$file_path" ]] || continue
				sh_results="${sh_results}${file_path}|${long_funcs}"$'\n'
			done <<<"$sh_scan_output"
			if [[ -n "$sh_results" ]]; then
				sh_results=$(printf '%s' "$sh_results" | sort -t'|' -k2 -rn)
				_complexity_scan_create_issues "$sh_results" "$repos_json" "$aidevops_slug"
			fi
		fi

		# Markdown files — convert helper output to existing issue creation format
		local md_scan_output
		md_scan_output=$("$scan_helper" scan "$aidevops_path" --type md --state-file "$state_file" 2>>"$LOGFILE") || true
		if [[ -n "$md_scan_output" ]]; then
			# Helper outputs: status|file_path|line_count|func_count|long_func_count|max_nesting|file_type
			# Issue creation expects: file_path|line_count
			local md_results=""
			while IFS='|' read -r _status file_path lines _funcs _long_funcs _nesting _type; do
				[[ -n "$file_path" ]] || continue
				md_results="${md_results}${file_path}|${lines}"$'\n'
			done <<<"$md_scan_output"
			if [[ -n "$md_results" ]]; then
				md_results=$(printf '%s' "$md_results" | sort -t'|' -k2 -rn)
				_complexity_scan_create_md_issues "$md_results" "$repos_json" "$aidevops_slug"
			fi
		fi

		# Phase 4: Daily LLM sweep check (GH#15285)
		# If simplification debt hasn't decreased in 6h, flag for LLM review.
		# The sweep itself runs as a separate worker dispatch, not inline.
		local sweep_result
		sweep_result=$("$scan_helper" sweep-check "$aidevops_slug" 2>>"$LOGFILE") || sweep_result=""
		if [[ "$sweep_result" == needed* ]]; then
			echo "[pulse-wrapper] LLM sweep triggered: ${sweep_result}" >>"$LOGFILE"
			# Create a one-off issue for the LLM sweep if none exists (t1855: check both title patterns)
			local sweep_issue_exists
			sweep_issue_exists=$(gh issue list --repo "$aidevops_slug" \
				--label "simplification-debt" --state open \
				--search "in:title \"simplification debt stalled\" OR in:title \"LLM complexity sweep\"" \
				--json number --jq 'length' 2>/dev/null) || sweep_issue_exists="0"
			if [[ "${sweep_issue_exists:-0}" -eq 0 ]]; then
				local sweep_reason
				sweep_reason=$(echo "$sweep_result" | cut -d'|' -f2)
				gh_create_issue --repo "$aidevops_slug" \
					--title "LLM complexity sweep: review stalled simplification debt" \
					--label "simplification-debt" --label "auto-dispatch" --label "tier:reasoning" \
					--body "## Daily LLM sweep (automated, GH#15285)

**Trigger:** ${sweep_reason}

The deterministic complexity scan detected that simplification debt has not decreased in the configured stall window. An LLM-powered deep review is needed to:

1. Identify why existing simplification issues are not being resolved
2. Re-prioritize the backlog based on actual impact
3. Close issues that are no longer relevant (files deleted, already simplified)
4. Suggest new decomposition strategies for stuck files

### Scope

Review all open \`simplification-debt\` issues and the current \`simplification-state.json\`. Focus on the top 10 largest files first." >/dev/null 2>&1 || true
				"$scan_helper" sweep-done 2>>"$LOGFILE" || true
			fi
		fi
	else
		# Fallback to inline scan if helper not available
		echo "[pulse-wrapper] complexity-scan-helper.sh not found, using inline scan" >>"$LOGFILE"
		local sh_results
		sh_results=$(_complexity_scan_collect_violations "$aidevops_path" "$now_epoch") || true
		if [[ -n "$sh_results" ]]; then
			sh_results=$(printf '%s' "$sh_results" | sort -t'|' -k2 -rn)
			_complexity_scan_create_issues "$sh_results" "$repos_json" "$aidevops_slug"
		fi
		local md_results
		md_results=$(_complexity_scan_collect_md_violations "$aidevops_path") || true
		if [[ -n "$md_results" ]]; then
			_complexity_scan_create_md_issues "$md_results" "$repos_json" "$aidevops_slug"
		fi
	fi

	printf '%s\n' "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
	return 0
}

#######################################
# Pre-fetch failed notification summary (t3960)
#
# Uses gh-failure-miner-helper.sh to mine ci_activity notifications,
# cluster recurring failures, and append a compact summary to STATE_FILE.
# This gives the pulse early signal on systemic CI breakages.
#
# Returns: 0 always (best-effort)
#######################################
prefetch_gh_failure_notifications() {
	local helper="${SCRIPT_DIR}/gh-failure-miner-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local summary
	summary=$(bash "$helper" prefetch \
		--pulse-repos \
		--since-hours "$GH_FAILURE_PREFETCH_HOURS" \
		--limit "$GH_FAILURE_PREFETCH_LIMIT" \
		--systemic-threshold "$GH_FAILURE_SYSTEMIC_THRESHOLD" \
		--max-run-logs "$GH_FAILURE_MAX_RUN_LOGS" 2>/dev/null || true)

	if [[ -z "$summary" ]]; then
		return 0
	fi

	echo ""
	echo "$summary"
	echo "- action: for systemic clusters, create/update one bug+auto-dispatch issue per affected repo"
	echo ""
	echo "[pulse-wrapper] Failed-notification summary appended (hours=${GH_FAILURE_PREFETCH_HOURS}, threshold=${GH_FAILURE_SYSTEMIC_THRESHOLD})" >>"$LOGFILE"
	return 0
}

#######################################
# Reap zombie workers whose PRs have already been merged (t1751/GH#15489)
#
# Workers don't detect when the deterministic merge pass merges their PR.
# This function runs each pulse cycle (before worker counting) to kill
# workers that are still running after their work is done.
#
# Uses the dispatch ledger session keys (issue-{N}) to find the issue
# number, then checks if a merged PR exists for that issue. If so,
# sends SIGTERM to the worker process tree.
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
reap_zombie_workers() {
	local reaped=0
	local worker_pids worker_key issue_number

	# Get unique session keys from active worker processes
	local session_keys
	session_keys=$(ps aux | grep '[h]eadless-runtime.*--role worker' | grep -v grep |
		sed 's/.*--session-key //' | awk '{print $1}' | sort -u) || return 0

	while IFS= read -r worker_key; do
		[[ -z "$worker_key" ]] && continue
		issue_number="${worker_key#issue-}"
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue

		# Check dispatch ledger for the repo slug
		local repo_slug=""
		local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
		if [[ -x "$_ledger_helper" ]]; then
			repo_slug=$("$_ledger_helper" get-repo --session-key "$worker_key" 2>/dev/null) || repo_slug=""
		fi
		# Fallback: check all pulse-enabled repos
		if [[ -z "$repo_slug" ]]; then
			repo_slug=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | .slug' "$REPOS_JSON" 2>/dev/null | head -1) || continue
		fi
		[[ -n "$repo_slug" ]] || continue

		# Check if a merged PR exists that closes this issue
		local merged_pr
		merged_pr=$(gh pr list --repo "$repo_slug" --state merged --search "closes #${issue_number} OR Closes #${issue_number}" \
			--limit 1 --json number --jq '.[0].number' 2>/dev/null) || merged_pr=""

		if [[ -n "$merged_pr" && "$merged_pr" != "null" ]]; then
			# Kill the worker process tree
			worker_pids=$(ps aux | grep "[h]eadless-runtime.*--session-key ${worker_key}" | grep -v grep | awk '{print $2}')
			if [[ -n "$worker_pids" ]]; then
				echo "[pulse-wrapper] Reaping zombie worker ${worker_key}: PR #${merged_pr} already merged in ${repo_slug}" >>"$LOGFILE"
				echo "$worker_pids" | xargs kill 2>/dev/null || true
				reaped=$((reaped + 1))
			fi
		fi
	done <<<"$session_keys"

	if [[ "$reaped" -gt 0 ]]; then
		echo "[pulse-wrapper] Reaped ${reaped} zombie worker(s) with merged PRs (t1751)" >>"$LOGFILE"
	fi
	return 0
}

# count_active_workers: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate divergence with stats-functions.sh.

#######################################
# Resolve managed repo path from slug
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: path via stdout (empty if not found)
#######################################
get_repo_path_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo ""
		return 0
	fi

	local repo_path
	repo_path=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .path' "$REPOS_JSON" 2>/dev/null | head -n 1)
	if [[ "$repo_path" == "null" ]]; then
		repo_path=""
	fi
	echo "$repo_path"
	return 0
}

#######################################
# Resolve repo owner login from slug
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: owner login via stdout (empty if invalid)
#######################################
get_repo_owner_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ "$repo_slug" != */* ]]; then
		echo ""
		return 0
	fi

	echo "${repo_slug%%/*}"
	return 0
}

#######################################
# Resolve repo maintainer login from repos.json
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: maintainer login via stdout (empty if missing)
#######################################
get_repo_maintainer_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo ""
		return 0
	fi

	local maintainer
	maintainer=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' "$REPOS_JSON" 2>/dev/null) || maintainer=""
	if [[ "$maintainer" == "null" ]]; then
		maintainer=""
	fi
	printf '%s\n' "$maintainer"
	return 0
}

#######################################
# Resolve repo priority class from repos.json
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: priority via stdout (product/tooling/profile, default tooling)
#######################################
get_repo_priority_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo "tooling"
		return 0
	fi

	local repo_priority
	repo_priority=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .priority // "tooling"' "$REPOS_JSON" 2>/dev/null | head -n 1)
	if [[ -z "$repo_priority" || "$repo_priority" == "null" ]]; then
		repo_priority="tooling"
	fi
	printf '%s\n' "$repo_priority"
	return 0
}

#######################################
# Return dispatchable issue candidates as JSON for one repo.
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - max issues to fetch (optional, default 100)
# Returns: JSON array of issue objects
#######################################
list_dispatchable_issue_candidates_json() {
	local repo_slug="$1"
	local limit="${2:-100}"

	if [[ -z "$repo_slug" ]]; then
		printf '[]\n'
		return 0
	fi
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=100

	local issue_json issue_dispatch_err
	issue_dispatch_err=$(mktemp)
	issue_json=$(gh issue list --repo "$repo_slug" --state open --json number,title,url,assignees,labels,updatedAt --limit "$limit" 2>"$issue_dispatch_err") || issue_json="[]"
	if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
		local _issue_dispatch_err_msg
		_issue_dispatch_err_msg=$(cat "$issue_dispatch_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] list_dispatchable_issue_candidates: gh issue list FAILED for ${repo_slug}: ${_issue_dispatch_err_msg}" >>"$LOGFILE"
		issue_json="[]"
	fi
	rm -f "$issue_dispatch_err"

	printf '%s' "$issue_json" | jq -c '
		[
			.[] |
			(.labels | map(.name)) as $labels |
			(.assignees | map(.login)) as $assignees |
			select(($labels | index("status:blocked")) == null) |
			select(([$labels[] | select(startswith("needs-"))] | length) == 0) |
			select(($labels | index("supervisor")) == null) |
			select(($labels | index("persistent")) == null) |
			{
				number,
				title,
				url,
				updatedAt,
				labels: $labels,
				assignees: $assignees
			}
		]
	' 2>/dev/null || printf '[]\n'
	return 0
}

#######################################
# List inactive backlog issues that are eligible for dispatch evaluation
# in a single repo.
#
# Candidate rules:
# - open and not blocked
# - exclude any issue carrying a needs-* label (e.g. needs-maintainer-review)
# - include queued/in-progress/in-review states (status labels are not blockers)
# - include assigned issues (assignment state is resolved by dedup/claim checks)
# - exclude supervisor/persistent telemetry issues
#
# Active PR/worker overlap is handled later by deterministic dedup guards.
# This helper only answers: "should the pulse look at this issue at all?"
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - max issues to fetch (optional, default 100)
# Returns: pipe-delimited rows number|title|labels|updatedAt
#######################################
list_dispatchable_issue_candidates() {
	local repo_slug="$1"
	local limit="${2:-100}"

	if [[ -z "$repo_slug" ]]; then
		return 0
	fi
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=100

	list_dispatchable_issue_candidates_json "$repo_slug" "$limit" | jq -r '.[] | "\(.number)|\(.title)|\(.labels | join(","))|\(.updatedAt // "")"' 2>/dev/null || true
	return 0
}

#######################################
# Check if a worker exists for a specific repo+issue pair
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
# Exit codes:
#   0 - matching worker exists
#   1 - no matching worker
#######################################
has_worker_for_repo_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local repo_path
	repo_path=$(get_repo_path_by_slug "$repo_slug")

	local worker_lines
	worker_lines=$(list_active_worker_processes) || worker_lines=""

	# Primary match: repo path + issue number in command line.
	# Requires get_repo_path_by_slug to return a non-empty path.
	if [[ -n "$repo_path" ]]; then
		local matches
		matches=$(printf '%s\n' "$worker_lines" | awk -v issue="$issue_number" -v path="$repo_path" '
			BEGIN {
				esc = path
				gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc)
			}
			$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") &&
			($0 ~ ("issue-" issue "([^0-9]|$)") || $0 ~ ("Issue #" issue "([^0-9]|$)")) { count++ }
			END { print count + 0 }
		') || matches=0
		[[ "$matches" =~ ^[0-9]+$ ]] || matches=0
		if [[ "$matches" -gt 0 ]]; then
			return 0
		fi
	fi

	# Fallback: match by session-key alone (GH#6453).
	# When get_repo_path_by_slug returns empty (slug not in repos.json,
	# path mismatch, or repos.json unavailable), the primary match above
	# always returns 0 matches — a false-negative that causes the backfill
	# cycle to re-dispatch already-running workers.
	# The session-key "issue-<number>" is always present in the command line
	# of workers dispatched via headless-runtime-helper.sh run --session-key.
	# This fallback catches those workers regardless of path resolution.
	local sk_matches
	sk_matches=$(printf '%s\n' "$worker_lines" | awk -v issue="$issue_number" '
		$0 ~ ("--session-key[[:space:]]+issue-" issue "([^0-9]|$)") { count++ }
		END { print count + 0 }
	') || sk_matches=0
	[[ "$sk_matches" =~ ^[0-9]+$ ]] || sk_matches=0
	if [[ "$sk_matches" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Check if dispatching a worker would be a duplicate (GH#4400, GH#5210, GH#6696, GH#11086)
#
# Seven-layer dedup:
#   1. dispatch-ledger-helper.sh check-issue — in-flight ledger (GH#6696)
#   2. has_worker_for_repo_issue() — exact repo+issue process match
#   3. dispatch-dedup-helper.sh is-duplicate — normalized title key match
#   4. dispatch-dedup-helper.sh has-open-pr — merged PR evidence for issue/task
#   5. dispatch-dedup-helper.sh has-dispatch-comment — cross-machine dispatch comment (GH#11141)
#   6. dispatch-dedup-helper.sh is-assigned — cross-machine assignee guard (GH#6891)
#   7. dispatch-dedup-helper.sh claim — cross-machine optimistic lock (GH#11086)
#
# Layer 1 (ledger) is checked first because it's the fastest (local file
# read, no process scanning or GitHub API calls) and catches the primary
# failure mode: workers dispatched but not yet visible in process lists
# or GitHub PRs (the 10-15 minute gap between dispatch and PR creation).
#
# Layer 6 (claim) is last because it's the slowest (posts a GitHub comment,
# sleeps DISPATCH_CLAIM_WINDOW seconds, re-reads comments). It's the final
# cross-machine safety net: two runners that pass layers 1-5 simultaneously
# will both post a claim, but only the oldest claim wins. Previously this
# was an LLM-instructed step in pulse.md that runners could skip — the
# GH#11086 incident showed both marcusquinn and johnwaldo dispatching on
# the same issue 45 seconds apart because the LLM skipped the claim step.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - dispatch title (e.g., "Issue #42: Fix auth")
#   $4 - issue title (optional; used for merged-PR task-id fallback)
#   $5 - self login (optional; runner's GitHub login for assignee check)
# Exit codes:
#   0 - duplicate detected (do NOT dispatch)
#   1 - no duplicate (safe to dispatch)
#######################################
check_dispatch_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"

	# Layer 1 (GH#6696): in-flight dispatch ledger — catches workers between
	# dispatch and PR creation (the 10-15 min gap that caused duplicate dispatches)
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		if "$ledger_helper" check-issue --issue "$issue_number" --repo "$repo_slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Dedup: in-flight ledger entry for #${issue_number} in ${repo_slug} (GH#6696)" >>"$LOGFILE"
			return 0
		fi
	fi

	# Layer 2: exact repo+issue process match
	if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] Dedup: worker already running for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Layer 3: normalized title key match via dispatch-dedup-helper
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	if [[ -x "$dedup_helper" ]] && [[ -n "$title" ]]; then
		if "$dedup_helper" is-duplicate "$title" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Dedup: title match for '${title}' — worker already running" >>"$LOGFILE"
			return 0
		fi
	fi

	# Layer 4: merged PR evidence for this issue/task
	local dedup_helper_output=""
	if [[ -x "$dedup_helper" ]]; then
		if dedup_helper_output=$("$dedup_helper" has-open-pr "$issue_number" "$repo_slug" "$issue_title" 2>>"$LOGFILE"); then
			if [[ -n "$dedup_helper_output" ]]; then
				echo "[pulse-wrapper] Dedup: ${dedup_helper_output}" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Dedup: merged PR evidence already exists for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
			fi
			return 0
		fi
	fi

	# Layer 5 (GH#11141): cross-machine dispatch comment check — detects
	# "Dispatching worker" comments posted by other runners. This is the
	# persistent cross-machine signal that survives beyond the claim lock's
	# 8-second window. The GH#11141 incident: marcusquinn dispatched at
	# 02:36, johnwaldo dispatched at 03:18 (42 min later). The claim lock
	# had long expired, the ledger is local-only, and the assignee guard
	# excluded the repo owner. But the "Dispatching worker" comment was
	# sitting right there on the issue — visible to all runners.
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		local dispatch_comment_output=""
		if dispatch_comment_output=$("$dedup_helper" has-dispatch-comment "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE"); then
			echo "[pulse-wrapper] Dedup: #${issue_number} in ${repo_slug} has active dispatch comment — ${dispatch_comment_output}" >>"$LOGFILE"
			return 0
		fi
	fi

	# Layer 6 (GH#6891): cross-machine assignee guard — prevents runners from
	# dispatching workers for issues already assigned to another login. Only
	# self_login is excluded; repo owner and maintainer are NOT excluded since
	# they may also be runners (GH#11141 fix — reverts the GH#10521 exclusion).
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		local assigned_output=""
		if assigned_output=$("$dedup_helper" is-assigned "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE"); then
			echo "[pulse-wrapper] Dedup: #${issue_number} in ${repo_slug} already assigned — ${assigned_output}" >>"$LOGFILE"
			return 0
		fi
	fi

	# Layer 7 (GH#11086): cross-machine optimistic claim lock — the final safety
	# net for multi-runner environments. Posts a plain-text claim comment on the issue,
	# sleeps the consensus window (default 8s), then checks if this runner's claim
	# is the oldest. Only the first claimant proceeds; others back off.
	#
	# Previously this was an LLM-instructed step in pulse.md that runners could
	# skip. The GH#11086 incident: marcusquinn dispatched at 23:07:43, johnwaldo
	# dispatched at 23:08:28 — 45 seconds apart on the same issue because the
	# LLM skipped the claim step. Moving it here makes it deterministic.
	#
	# Exit codes from claim: 0=won, 1=lost, 2=error (fail-open).
	# On error (exit 2), we allow dispatch to proceed — better to risk a rare
	# duplicate than to block all dispatch on a transient GitHub API failure.
	#
	# GH#15317: Capture claim output to extract comment_id for cleanup after
	# the deterministic dispatch comment is posted. Uses the caller's
	# _claim_comment_id variable (declared in dispatch_with_dedup) via bash
	# dynamic scoping — do NOT declare local here or the value is lost on return.
	_claim_comment_id=""
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		# GH#17590: Pre-check for existing claims BEFORE posting our own.
		# Without this, two runners both post claims within seconds, then
		# the consensus window resolves the race — but the losing claim
		# comment is left on the issue, wasting a GitHub API call and
		# cluttering the issue. The pre-check is cheap (read-only) and
		# catches the common case where another runner already claimed.
		local _precheck_output="" _precheck_exit=0
		_precheck_output=$("$dedup_helper" check-claim "$issue_number" "$repo_slug") || _precheck_exit=$?
		if [[ "$_precheck_exit" -eq 0 ]]; then
			# Active claim exists from another runner — skip claim entirely
			echo "[pulse-wrapper] Dedup: pre-check found active claim on #${issue_number} in ${repo_slug} — skipping (${_precheck_output})" >>"$LOGFILE"
			return 0
		fi
		# No active claim found (exit 1) or error (exit 2, fail-open) — proceed to claim
		local claim_exit=0 claim_output=""
		claim_output=$("$dedup_helper" claim "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE") || claim_exit=$?
		echo "$claim_output" >>"$LOGFILE"
		if [[ "$claim_exit" -eq 1 ]]; then
			echo "[pulse-wrapper] Dedup: claim lost for #${issue_number} in ${repo_slug} — another runner claimed first (GH#11086)" >>"$LOGFILE"
			return 0
		fi
		if [[ "$claim_exit" -eq 2 ]]; then
			echo "[pulse-wrapper] Dedup: claim error for #${issue_number} in ${repo_slug} — proceeding (fail-open)" >>"$LOGFILE"
		fi
		# Extract claim comment_id for post-dispatch cleanup (GH#15317)
		_claim_comment_id=$(printf '%s' "$claim_output" | sed -n 's/.*comment_id=\([0-9]*\).*/\1/p')
		# claim_exit 0 = won, proceed to dispatch
	fi

	return 1
}

#######################################
# Lock an issue to prevent mid-flight prompt injection (t1894).
# When a worker is dispatched for an external contributor issue,
# lock the conversation so the attacker cannot add new comments
# that could influence the worker mid-execution.
# Non-fatal: locking failure doesn't block dispatch.
#######################################
lock_issue_for_worker() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	# Only lock issues that were ever NMR-labeled (external contributor issues)
	if issue_was_ever_nmr "$issue_num" "$slug" 2>/dev/null; then
		gh issue lock "$issue_num" --repo "$slug" --reason "$reason" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Locked #${issue_num} in ${slug} during worker execution" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Unlock an issue after worker completion or failure (t1894).
# Non-fatal: unlocking failure is logged but doesn't block.
#######################################
unlock_issue_after_worker() {
	local issue_num="$1"
	local slug="$2"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	gh issue unlock "$issue_num" --repo "$slug" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Unlocked #${issue_num} in ${slug} after worker completion" >>"$LOGFILE"
	return 0
}

#######################################
# GH#17574: Check if a task has already been committed directly to main.
#
# Workers that bypass the PR flow (direct commits to main) complete the
# work invisibly — the issue stays open until the pulse's mark-complete
# pass runs, which happens AFTER dispatch decisions for the next cycle.
# This caused 3× token waste in the observed incident (t153–t160).
#
# Strategy: Extract task ID patterns from the issue title (tNNN, GH#NNN)
# and search recent commits on origin/main since the issue was created.
# A match means the work is already done — skip dispatch.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - issue_title (e.g., "t153: add dark mode toggle")
#   $4 - repo_path (local path to the repo)
#
# Exit codes:
#   0 - task IS committed to main (do NOT dispatch)
#   1 - task is NOT committed to main (safe to dispatch)
#######################################
_is_task_committed_to_main() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local repo_path="$4"

	[[ -n "$issue_number" && -n "$repo_slug" && -n "$repo_path" ]] || return 1

	# Extract task ID patterns from the issue title.
	# Matches: "t153:", "t153 ", "GH#17574:", "GH#17574 "
	# Also matches the issue number itself: "#17574" in commit messages.
	local -a search_patterns=()

	# Pattern 1: tNNN task ID from title (e.g., "t153: add dark mode")
	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+' | head -1) || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		search_patterns+=("$task_id_match")
	fi

	# Pattern 2: GH#NNN from title (e.g., "GH#17574: fix pulse dispatch")
	local gh_id_match
	gh_id_match=$(printf '%s' "$issue_title" | grep -oE '^GH#[0-9]+' | head -1) || gh_id_match=""
	if [[ -n "$gh_id_match" ]]; then
		search_patterns+=("$gh_id_match")
	fi

	# Pattern 3: GitHub squash-merge suffix "(#NNN)" — only matches commit
	# titles, not body references. The bare "#NNN" pattern previously caused
	# false positives: any commit that MENTIONED an issue (e.g., "Relabeled
	# #17659 and #17660") would match, closing issues whose work hadn't been
	# done. Restrict to the "(#NNN)" suffix that GitHub adds to squash merges.
	search_patterns+=("(#${issue_number})")

	# Pattern 4: "Closes #NNN" / "Fixes #NNN" in commit messages — these
	# are the conventional patterns for commits that resolve an issue.
	search_patterns+=("[Cc]loses #${issue_number}")
	search_patterns+=("[Ff]ixes #${issue_number}")

	# No patterns to search — cannot determine if committed
	if [[ ${#search_patterns[@]} -eq 0 ]]; then
		return 1
	fi

	# Get the issue creation date for --since filtering
	local created_at
	created_at=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json createdAt -q '.createdAt' 2>/dev/null) || created_at=""
	if [[ -z "$created_at" ]]; then
		return 1
	fi

	# Ensure we have the latest remote refs (the dispatch loop already
	# does git pull, but fetch is cheaper and sufficient for log queries)
	if [[ -d "$repo_path/.git" ]] || git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" fetch origin main --quiet 2>/dev/null || true
	else
		return 1
	fi

	# Search recent commits on origin/main for any matching pattern.
	# Use -E for extended regex (Closes/Fixes patterns).
	local pattern
	for pattern in "${search_patterns[@]}"; do
		local match_count
		match_count=$(git -C "$repo_path" log origin/main --since="$created_at" \
			--oneline -E --grep="$pattern" 2>/dev/null | wc -l) || match_count=0
		match_count=$(printf '%s' "$match_count" | tr -d '[:space:]')
		if [[ "$match_count" -gt 0 ]]; then
			echo "[pulse-wrapper] _is_task_committed_to_main: found ${match_count} commit(s) matching '${pattern}' on origin/main since ${created_at} for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
			return 0
		fi
	done

	return 1
}

#######################################
# Atomic dispatch: dedup guard + assign + launch in a single call (GH#12436)
#
# Root cause of GH#12141 and GH#12155: the pulse.md instructed the LLM to
# run check_dispatch_dedup, then gh issue edit, then headless-runtime-helper.sh
# as three separate steps. The LLM skipped check_dispatch_dedup entirely in
# both incidents — zero DISPATCH_CLAIM comments were posted. This function
# makes the dedup guard non-skippable by wrapping all three steps into a
# single deterministic call. The LLM calls one function; the function
# enforces all 7 dedup layers before assigning and launching.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (e.g., "Issue #42: Fix auth")
#   $4 - issue_title (e.g., "t042: Fix auth" — for merged-PR fallback)
#   $5 - self_login (runner's GitHub login)
#   $6 - repo_path (local path to the repo for the worker)
#   $7 - prompt (full prompt string for the worker, e.g., "/full-loop ...")
#   $8 - session_key (optional; defaults to "issue-${issue_number}")
#
# Exit codes:
#   0 - dispatched successfully
#   1 - dedup guard blocked dispatch (duplicate detected)
#   2 - dispatch failed after passing dedup (assign or launch error)
#######################################
dispatch_with_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"
	local repo_path="$6"
	local prompt="$7"
	local session_key="${8:-issue-${issue_number}}"
	local model_override="${9:-}"
	# GH#15317 fix: _claim_comment_id is set by check_dispatch_dedup() via
	# bash dynamic scoping, but must be declared in the calling function's
	# scope first. Without this, set -u crashes the wrapper on every dispatch,
	# SIGTERM-ing all active workers.
	local _claim_comment_id=""

	# GH#17503: Claim comments are NEVER deleted — they form the audit trail.
	# The _cleanup_claim_comment function is retained as a no-op for backward
	# compatibility (callers may still reference it on early-return paths).
	_cleanup_claim_comment() {
		# No-op: claim comments are persistent audit trail (GH#17503).
		# Previously deleted DISPATCH_CLAIM comments, which destroyed both
		# the lock and the audit trail — causing duplicate dispatches.
		return 0
	}

	# Hard stop for supervisor/telemetry issues (t1702 pulse guard).
	# The pulse prompt should already avoid these, but this deterministic
	# gate prevents dispatch when prompt fallback logic is too permissive.
	local issue_meta_json
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels 2>/dev/null) || issue_meta_json=""
	if [[ -z "$issue_meta_json" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unable to load issue metadata" >>"$LOGFILE"
		return 1
	fi

	local target_state target_title
	target_state=$(echo "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null)
	target_title=$(echo "$issue_meta_json" | jq -r '.title // ""' 2>/dev/null)

	if [[ "$target_state" != "OPEN" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: issue state is ${target_state:-unknown}" >>"$LOGFILE"
		return 1
	fi

	if echo "$issue_meta_json" | jq -e '.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review"))' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: non-dispatchable management label present" >>"$LOGFILE"
		return 1
	fi

	local known_ever_nmr="unknown"
	if echo "$issue_meta_json" | jq -e '.labels | map(.name) | index("needs-maintainer-review")' >/dev/null 2>&1; then
		known_ever_nmr="true"
	fi

	# t1894: Cryptographic approval gate — block dispatch for issues that were
	# ever labeled needs-maintainer-review without a signed approval.
	if ! issue_has_required_approval "$issue_number" "$repo_slug" "$known_ever_nmr"; then
		echo "[pulse-wrapper] dispatch_with_dedup: BLOCKED #${issue_number} in ${repo_slug} — requires cryptographic approval (ever-NMR)" >>"$LOGFILE"
		return 1
	fi

	if [[ "$target_title" == \[Supervisor:* ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: supervisor telemetry title" >>"$LOGFILE"
		return 1
	fi

	# GH#17574: Skip dispatch if the task has already been committed directly
	# to main. Workers that bypass the PR flow (direct commits) complete the
	# work invisibly — the issue stays open until the pulse's mark-complete
	# pass runs, which happens AFTER dispatch decisions. Without this check,
	# the pulse dispatches redundant workers for already-completed work.
	if _is_task_committed_to_main "$issue_number" "$repo_slug" "$target_title" "$repo_path"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: task already committed to main (GH#17574)" >>"$LOGFILE"
		# GH#17642: Do NOT auto-close the issue. The main-commit check has a
		# high false-positive rate (casual mentions, multi-runner deployment
		# gaps, stale patterns). A false skip is harmless (next cycle retries),
		# a false close is destructive (needs manual reopen, re-dispatch, and
		# loses worker context). Let the verified merge-pass or human close it.
		return 1
	fi

	# All 7 dedup layers — cannot be skipped
	if check_dispatch_dedup "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" "$self_login"; then
		echo "[dispatch_with_dedup] Dedup guard blocked #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		return 1
	fi

	# Assign issue and label as queued + origin:worker (dispatched by pulse)
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-assignee "$self_login" --add-label "status:queued" --add-label "origin:worker" 2>/dev/null || true

	# Detach worker stdio from the dispatcher (GH#14483).
	# Without this, background workers inherit the candidate-loop stdin created by
	# process substitutions and can consume the remaining candidate stream,
	# causing the deterministic fill floor to stop after one dispatch. Redirect
	# worker stdout/stderr into per-issue temp logs so launch validation reads the
	# intended output file and dispatcher shells stay clean.
	local safe_slug worker_log worker_log_fallback
	safe_slug=$(echo "$repo_slug" | tr '/:' '--')
	worker_log="/tmp/pulse-${safe_slug}-${issue_number}.log"
	worker_log_fallback="/tmp/pulse-${issue_number}.log"
	rm -f "$worker_log" "$worker_log_fallback"
	: >"$worker_log"
	ln -s "$worker_log" "$worker_log_fallback" 2>/dev/null || true

	# ROUND-ROBIN MODEL SELECTION (owned by this function, NOT the caller).
	#
	# When model_override (param 9) is EMPTY, this function calls
	# headless-runtime-helper.sh select --role worker, which runs the
	# round-robin across AIDEVOPS_HEADLESS_MODELS (respects backoff DB,
	# auth availability, and provider rotation). The resolved model name
	# is shown in the dispatch comment so the audit trail records exactly
	# which provider/model the worker used.
	#
	# IMPORTANT: Callers (including the pulse AI) MUST NOT pass a model
	# override for default dispatches. Only pass model_override when a
	# specific tier is required (e.g., tier:reasoning → opus escalation,
	# tier:simple → haiku). Passing an arbitrary model here bypasses the
	# round-robin and causes provider imbalance — e.g., all workers end
	# up on a single provider instead of alternating between anthropic
	# and openai as configured.
	#
	# History: GH#17503 moved model resolution here (from the worker) so
	# the dispatch comment shows the actual model. Prior to that fix, the
	# comment showed "auto-select (round-robin)" which was unhelpful.
	local selected_model=""
	if [[ -n "$model_override" ]]; then
		selected_model="$model_override"
	else
		selected_model=$("$HEADLESS_RUNTIME_HELPER" select --role worker 2>/dev/null) || selected_model=""
	fi

	# t1894: Lock external contributor issues during worker execution
	lock_issue_for_worker "$issue_number" "$repo_slug"

	# GH#17584: Ensure the repo is on the latest remote commit before
	# launching the worker. Without this, workers on stale checkouts
	# close issues as "Invalid — file does not exist" when the target
	# file was added in a recent commit they haven't pulled.
	if git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$repo_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1 || {
			echo "[dispatch_with_dedup] Warning: git pull failed for ${repo_path} — proceeding with current checkout" >>"$LOGFILE"
		}
	fi

	# Launch worker — headless-runtime-helper.sh handles model selection
	# via round-robin when no --model is specified. Its choose_model() reads
	# AIDEVOPS_HEADLESS_MODELS, checks backoff/auth, and rotates providers.
	local -a worker_cmd=("$HEADLESS_RUNTIME_HELPER" run
		--role worker
		--session-key "$session_key"
		--dir "$repo_path"
		--title "$dispatch_title"
		--prompt "$prompt")
	if [[ -n "$selected_model" ]]; then
		worker_cmd+=(--model "$selected_model")
	fi
	# GH#17549: Detach worker from the pulse-wrapper's SIGHUP.
	# launchd runs pulse-wrapper with StartInterval=120s. When the wrapper
	# exits after its dispatch cycle, bash sends SIGHUP to background jobs.
	# nohup makes the worker immune to SIGHUP so it survives the parent's
	# exit. The EXIT trap only releases the instance lock (no child killing).
	nohup "${worker_cmd[@]}" </dev/null >>"$worker_log" 2>&1 &
	local worker_pid="$!"

	# GH#17549: Stagger delay between worker launches to reduce SQLite
	# write contention on opencode.db (busy_timeout=0). Without this,
	# batches of 8+ workers all hit the DB simultaneously, causing
	# SQLITE_BUSY → silent mid-turn death. The stagger gives each worker
	# time to complete its initial DB writes before the next one starts.
	local stagger_delay="${PULSE_DISPATCH_STAGGER_SECONDS:-8}"
	sleep "$stagger_delay"

	# Determine dispatch tier from issue labels for telemetry
	local dispatch_tier="standard"
	local issue_labels_csv
	issue_labels_csv=$(echo "$issue_meta_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels_csv=""
	case ",$issue_labels_csv," in
	*,tier:reasoning,* | *,tier:thinking,*) dispatch_tier="reasoning" ;;
	*,tier:standard,*) dispatch_tier="standard" ;;
	*,tier:simple,*) dispatch_tier="simple" ;;
	esac

	# Record in dispatch ledger (with tier telemetry)
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		"$ledger_helper" register --session-key "$session_key" \
			--issue "$issue_number" --repo "$repo_slug" \
			--pid "$worker_pid" --tier "$dispatch_tier" \
			--model "$selected_model" 2>/dev/null || true
	fi

	# GH#15317: Post deterministic "Dispatching worker" comment from the dispatcher,
	# not from the worker LLM session. Previously, the worker was responsible for
	# posting this comment — but workers could crash before posting, leaving no
	# persistent signal. Without this signal, Layer 5 (has_dispatch_comment) had
	# nothing to find, and the issue would be re-dispatched every pulse cycle.
	# Evidence: awardsapp #2051 accumulated 29 DISPATCH_CLAIM comments over 6 hours
	# because workers kept dying before posting.
	local dispatch_comment_body
	local display_model="${selected_model:-auto-select (round-robin)}"
	dispatch_comment_body="Dispatching worker (deterministic).
- **Worker PID**: ${worker_pid}
- **Model**: ${display_model}
- **Tier**: ${dispatch_tier}
- **Runner**: ${self_login}
- **Issue**: #${issue_number}"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST --field body="$dispatch_comment_body" \
		>/dev/null 2>>"$LOGFILE" || {
		echo "[dispatch_with_dedup] Warning: failed to post deterministic dispatch comment for #${issue_number}" >>"$LOGFILE"
	}

	# GH#17503: Claim comments are NEVER deleted — they form the persistent
	# audit trail and are respected as the primary dedup lock for 30 minutes.
	# The deferred deletion that previously ran here (GH#17497) was the root
	# cause of duplicate dispatches: deleting the claim removed the lock,
	# allowing subsequent pulse cycles and other runners to re-dispatch.
	# Evidence: GH#17503 — 6 dispatches from marcusquinn + 1 from alex-solovyev,
	# producing 2 duplicate PRs (#17512, #17513).
	if [[ -n "$_claim_comment_id" ]]; then
		echo "[dispatch_with_dedup] Claim comment ${_claim_comment_id} retained for audit trail on #${issue_number} (GH#17503)" >>"$LOGFILE"
		_claim_comment_id=""
	fi

	echo "[dispatch_with_dedup] Dispatched worker PID ${worker_pid} for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}

#######################################
# Check issue comments for terminal blocker patterns (GH#5141)
#
# Scans the last N comments on an issue for known patterns that indicate
# a user-action-required blocker. Workers cannot resolve these — they
# require the repo owner to take a manual action (e.g., refresh a token,
# grant a scope, configure a secret). Dispatching workers against these
# issues wastes compute on guaranteed failures.
#
# Known terminal blocker patterns:
#   - workflow scope missing (token lacks `workflow` scope)
#   - token lacks scope / missing scope
#   - ACTION REQUIRED (supervisor-posted user-action comments)
#   - refusing to allow an OAuth App to create or update workflow
#   - authentication required / permission denied (persistent auth failures)
#
# When a blocker is detected, the function:
#   1. Adds `status:blocked` label to the issue
#   2. Posts a comment directing the user to the required action
#      (idempotent — checks for existing blocker comment first)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - (optional) max comments to scan (default: 5)
#
# Exit codes:
#   0 - terminal blocker detected (skip dispatch)
#   1 - no blocker found (safe to dispatch)
#   2 - API error (fail open — allow dispatch to proceed)
#######################################
#######################################
# Match terminal blocker patterns in comment bodies (GH#5627)
#
# Checks concatenated comment bodies against known blocker patterns.
# Returns blocker_reason and user_action via stdout (2 lines).
#
# Arguments:
#   $1 - all_bodies (concatenated comment text)
# Output: 2 lines to stdout (blocker_reason, user_action) — empty if no match
# Exit codes:
#   0 - blocker pattern matched
#   1 - no match
#######################################
_match_terminal_blocker_pattern() {
	local all_bodies="$1"
	local blocker_reason=""
	local user_action=""

	# Pattern 1: workflow scope missing
	if echo "$all_bodies" | grep -qiE 'workflow scope|refusing to allow an OAuth App to create or update workflow|token lacks.*workflow'; then
		blocker_reason="GitHub token lacks \`workflow\` scope — workers cannot push workflow file changes"
		user_action="Run \`gh auth refresh -s workflow\` to add the workflow scope to your token, then remove the \`status:blocked\` label."
	# Pattern 2: generic token/auth scope issues
	elif echo "$all_bodies" | grep -qiE 'token lacks.*scope|missing.*scope.*token|token.*missing.*scope'; then
		blocker_reason="GitHub token is missing a required scope — workers cannot complete this task"
		user_action="Check the error details in the comments above, run \`gh auth refresh -s <missing-scope>\` to add the required scope, then remove the \`status:blocked\` label."
	# Pattern 3: ACTION REQUIRED (supervisor-posted)
	elif echo "$all_bodies" | grep -qF 'ACTION REQUIRED'; then
		blocker_reason="A previous supervisor comment flagged this issue as requiring user action"
		user_action="Read the ACTION REQUIRED comment above, complete the requested action, then remove the \`status:blocked\` label."
	# Pattern 4: persistent authentication/permission failures
	elif echo "$all_bodies" | grep -qiE 'authentication required.*workflow|permission denied.*workflow|push declined.*workflow'; then
		blocker_reason="Persistent authentication or permission failure for workflow files"
		user_action="Check your GitHub token scopes with \`gh auth status\`, refresh if needed with \`gh auth refresh -s workflow\`, then remove the \`status:blocked\` label."
	fi

	if [[ -z "$blocker_reason" ]]; then
		return 1
	fi

	echo "$blocker_reason"
	echo "$user_action"
	return 0
}

#######################################
# Apply terminal blocker labels and comment to an issue (GH#5627)
#
# Idempotent — checks for existing label and comment before acting.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - blocker_reason
#   $4 - user_action
#   $5 - all_bodies (for existing comment check)
#######################################
_apply_terminal_blocker() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocker_reason="$3"
	local user_action="$4"
	local all_bodies="$5"

	# Check if already labelled
	local existing_labels
	existing_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || existing_labels=""

	local already_blocked=false
	if [[ ",${existing_labels}," == *",status:blocked,"* ]]; then
		already_blocked=true
	fi

	# Check for existing terminal-blocker comment (idempotent)
	local has_blocker_comment=false
	if echo "$all_bodies" | grep -qF 'Terminal blocker detected'; then
		has_blocker_comment=true
	fi

	# Add label if not already present
	if [[ "$already_blocked" == "false" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "status:blocked" \
			--remove-label "status:available" --remove-label "status:queued" 2>/dev/null ||
			gh issue edit "$issue_number" --repo "$repo_slug" \
				--add-label "status:blocked" 2>/dev/null || true
	fi

	# Post comment if not already posted
	if [[ "$has_blocker_comment" == "false" ]]; then
		gh issue comment "$issue_number" --repo "$repo_slug" \
			--body "**Terminal blocker detected** (GH#5141) — skipping dispatch.

**Reason:** ${blocker_reason}

**Action required:** ${user_action}

---
*This issue will not be dispatched to workers until the blocker is resolved. Once you have completed the required action, remove the \`status:blocked\` label to re-enable dispatch.*" || true
	fi

	return 0
}

check_terminal_blockers() {
	local issue_number="$1"
	local repo_slug="$2"
	local max_comments="${3:-5}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_terminal_blockers: missing arguments" >>"$LOGFILE"
		return 2
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 2
	fi

	# Fetch the last N comments
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq "[ .[-${max_comments}:][] | {body: .body, created_at: .created_at} ]" 2>/dev/null)
	local api_exit=$?

	if [[ $api_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_terminal_blockers: API error (exit=$api_exit) for #${issue_number} in ${repo_slug} — failing open" >>"$LOGFILE"
		return 2
	fi

	if [[ -z "$comments_json" || "$comments_json" == "[]" || "$comments_json" == "null" ]]; then
		return 1
	fi

	# Concatenate comment bodies for pattern matching
	local all_bodies
	all_bodies=$(echo "$comments_json" | jq -r '.[].body // ""' 2>/dev/null)

	if [[ -z "$all_bodies" ]]; then
		return 1
	fi

	# Match against known terminal blocker patterns
	local pattern_output
	pattern_output=$(_match_terminal_blocker_pattern "$all_bodies") || return 1

	local blocker_reason user_action
	blocker_reason=$(echo "$pattern_output" | sed -n '1p')
	user_action=$(echo "$pattern_output" | sed -n '2p')

	# Apply labels and comment
	_apply_terminal_blocker "$issue_number" "$repo_slug" "$blocker_reason" "$user_action" "$all_bodies"

	echo "[pulse-wrapper] check_terminal_blockers: blocker detected for #${issue_number} in ${repo_slug} — ${blocker_reason}" >>"$LOGFILE"
	return 0
}

#######################################
# Append adaptive queue-governor guidance to pre-fetched state
#
# Uses observed queue totals and trend vs previous cycle to derive an
# adaptive PR-vs-issue dispatch focus. This avoids static per-repo
# thresholds and shifts effort toward PR burn-down when PR backlog grows.
#######################################
#######################################
# Fetch queue metrics from all pulse-enabled repos (GH#5627)
#
# Outputs 4 lines: total_prs, total_issues, ready_prs, failing_prs
#######################################
_fetch_queue_metrics() {
	local total_prs=0
	local total_issues=0
	local ready_prs=0
	local failing_prs=0

	while IFS='|' read -r slug _path; do
		[[ -n "$slug" ]] || continue

		local pr_json pr_qm_err
		pr_qm_err=$(mktemp)
		pr_json=$(gh pr list --repo "$slug" --state open --json reviewDecision,statusCheckRollup --limit "$PULSE_RUNNABLE_PR_LIMIT" 2>"$pr_qm_err") || pr_json="[]"
		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
			local _pr_qm_err_msg
			_pr_qm_err_msg=$(cat "$pr_qm_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] _fetch_queue_metrics: gh pr list FAILED for ${slug}: ${_pr_qm_err_msg}" >>"$LOGFILE"
			pr_json="[]"
		fi
		rm -f "$pr_qm_err"
		local repo_pr_total repo_ready repo_failing
		repo_pr_total=$(echo "$pr_json" | jq 'length' 2>/dev/null) || repo_pr_total=0
		repo_ready=$(echo "$pr_json" | jq '[.[] | select(.reviewDecision == "APPROVED" and ((.statusCheckRollup // []) | length > 0) and ((.statusCheckRollup // []) | all((.conclusion // .state) == "SUCCESS")))] | length' 2>/dev/null) || repo_ready=0
		repo_failing=$(echo "$pr_json" | jq '[.[] | select(.reviewDecision == "CHANGES_REQUESTED" or ((.statusCheckRollup // []) | any((.conclusion // .state) == "FAILURE")))] | length' 2>/dev/null) || repo_failing=0

		local issue_json repo_issue_total issue_qm_err
		issue_qm_err=$(mktemp)
		issue_json=$(gh issue list --repo "$slug" --state open --json number --limit "$PULSE_RUNNABLE_ISSUE_LIMIT" 2>"$issue_qm_err") || issue_json="[]"
		if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
			local _issue_qm_err_msg
			_issue_qm_err_msg=$(cat "$issue_qm_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] _fetch_queue_metrics: gh issue list FAILED for ${slug}: ${_issue_qm_err_msg}" >>"$LOGFILE"
			issue_json="[]"
		fi
		rm -f "$issue_qm_err"
		repo_issue_total=$(echo "$issue_json" | jq 'length' 2>/dev/null) || repo_issue_total=0

		[[ "$repo_pr_total" =~ ^[0-9]+$ ]] || repo_pr_total=0
		[[ "$repo_ready" =~ ^[0-9]+$ ]] || repo_ready=0
		[[ "$repo_failing" =~ ^[0-9]+$ ]] || repo_failing=0
		[[ "$repo_issue_total" =~ ^[0-9]+$ ]] || repo_issue_total=0

		total_prs=$((total_prs + repo_pr_total))
		total_issues=$((total_issues + repo_issue_total))
		ready_prs=$((ready_prs + repo_ready))
		failing_prs=$((failing_prs + repo_failing))
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$REPOS_JSON" 2>/dev/null)

	echo "$total_prs"
	echo "$total_issues"
	echo "$ready_prs"
	echo "$failing_prs"
	return 0
}

#######################################
# Load previous queue metrics from the metrics file (GH#14960)
#
# Reads QUEUE_METRICS_FILE and populates caller-scope variables via
# stdout in key=value format. Caller evals the output.
#
# Output: key=value lines for prev_total_prs, prev_total_issues,
#         prev_ready_prs, prev_failing_prs, prev_recorded_at
#######################################
_load_queue_metrics_history() {
	local prev_total_prs=0 prev_total_issues=0 prev_ready_prs=0 prev_failing_prs=0 prev_recorded_at=0
	if [[ -f "$QUEUE_METRICS_FILE" ]]; then
		while IFS='=' read -r key value; do
			case "$key" in
			prev_total_prs) prev_total_prs="$value" ;;
			prev_total_issues) prev_total_issues="$value" ;;
			prev_ready_prs) prev_ready_prs="$value" ;;
			prev_failing_prs) prev_failing_prs="$value" ;;
			prev_recorded_at) prev_recorded_at="$value" ;;
			esac
		done <"$QUEUE_METRICS_FILE"
	fi
	[[ "$prev_total_prs" =~ ^-?[0-9]+$ ]] || prev_total_prs=0
	[[ "$prev_total_issues" =~ ^-?[0-9]+$ ]] || prev_total_issues=0
	[[ "$prev_ready_prs" =~ ^-?[0-9]+$ ]] || prev_ready_prs=0
	[[ "$prev_failing_prs" =~ ^-?[0-9]+$ ]] || prev_failing_prs=0
	[[ "$prev_recorded_at" =~ ^[0-9]+$ ]] || prev_recorded_at=0
	printf 'prev_total_prs=%s\nprev_total_issues=%s\nprev_ready_prs=%s\nprev_failing_prs=%s\nprev_recorded_at=%s\n' \
		"$prev_total_prs" "$prev_total_issues" "$prev_ready_prs" "$prev_failing_prs" "$prev_recorded_at"
	return 0
}

#######################################
# Compute queue deltas and drain/growth metrics (GH#14960)
#
# Arguments:
#   $1 - total_prs (current)
#   $2 - total_issues (current)
#   $3 - ready_prs (current)
#   $4 - failing_prs (current)
#   $5 - prev_total_prs
#   $6 - prev_total_issues
#   $7 - prev_ready_prs
#   $8 - prev_failing_prs
#   $9 - prev_recorded_at (epoch)
#
# Output: key=value lines for pr_delta, issue_delta, ready_delta,
#         failing_delta, backlog_drain_per_cycle, backlog_growth_pressure,
#         drain_rate_per_hour, elapsed_seconds, now_epoch
#######################################
_compute_queue_deltas() {
	local total_prs="$1"
	local total_issues="$2"
	local ready_prs="$3"
	local failing_prs="$4"
	local prev_total_prs="$5"
	local prev_total_issues="$6"
	local prev_ready_prs="$7"
	local prev_failing_prs="$8"
	local prev_recorded_at="$9"

	local now_epoch elapsed_seconds
	now_epoch=$(date +%s)
	elapsed_seconds=$((now_epoch - prev_recorded_at))
	if [[ "$elapsed_seconds" -lt 0 ]]; then
		elapsed_seconds=0
	fi

	local pr_delta issue_delta ready_delta failing_delta
	pr_delta=$((total_prs - prev_total_prs))
	issue_delta=$((total_issues - prev_total_issues))
	ready_delta=$((ready_prs - prev_ready_prs))
	failing_delta=$((failing_prs - prev_failing_prs))

	local backlog_drain_per_cycle backlog_growth_pressure drain_rate_per_hour
	backlog_drain_per_cycle=$((prev_total_prs - total_prs))
	if [[ "$backlog_drain_per_cycle" -lt 0 ]]; then
		backlog_drain_per_cycle=0
	fi
	backlog_growth_pressure=$pr_delta
	if [[ "$backlog_growth_pressure" -lt 0 ]]; then
		backlog_growth_pressure=0
	fi
	drain_rate_per_hour="n/a"
	if [[ "$elapsed_seconds" -gt 0 && "$backlog_drain_per_cycle" -gt 0 ]]; then
		drain_rate_per_hour=$(((backlog_drain_per_cycle * 3600) / elapsed_seconds))
	fi

	printf 'pr_delta=%s\nissue_delta=%s\nready_delta=%s\nfailing_delta=%s\nbacklog_drain_per_cycle=%s\nbacklog_growth_pressure=%s\ndrain_rate_per_hour=%s\nelapsed_seconds=%s\nnow_epoch=%s\n' \
		"$pr_delta" "$issue_delta" "$ready_delta" "$failing_delta" \
		"$backlog_drain_per_cycle" "$backlog_growth_pressure" "$drain_rate_per_hour" \
		"$elapsed_seconds" "$now_epoch"
	return 0
}

#######################################
# Determine queue mode and PR focus percentages (GH#14960)
#
# Arguments:
#   $1 - total_prs
#   $2 - total_issues
#   $3 - ready_prs
#   $4 - failing_prs
#   $5 - pr_delta
#
# Output: key=value lines for queue_mode, backlog_band,
#         pr_focus_pct, new_issue_pct
#######################################
_compute_queue_mode() {
	local total_prs="$1"
	local total_issues="$2"
	local ready_prs="$3"
	local failing_prs="$4"
	local pr_delta="$5"

	local denominator pr_share_pct growth_bias pr_focus_pct new_issue_pct
	denominator=$((total_prs + total_issues))
	if [[ "$denominator" -lt 1 ]]; then
		denominator=1
	fi
	pr_share_pct=$(((total_prs * 100) / denominator))
	growth_bias=0
	if [[ "$pr_delta" -gt 0 ]]; then
		growth_bias=10
	elif [[ "$pr_delta" -lt 0 ]]; then
		growth_bias=-5
	fi
	pr_focus_pct=$((35 + (pr_share_pct / 2) + growth_bias))
	if [[ "$pr_focus_pct" -lt 35 ]]; then
		pr_focus_pct=35
	elif [[ "$pr_focus_pct" -gt 85 ]]; then
		pr_focus_pct=85
	fi

	local queue_mode backlog_band
	queue_mode="balanced"
	backlog_band="normal"
	if [[ "$total_prs" -ge "$PULSE_PR_BACKLOG_CRITICAL_THRESHOLD" ]]; then
		backlog_band="critical"
	elif [[ "$total_prs" -ge "$PULSE_PR_BACKLOG_HEAVY_THRESHOLD" ]]; then
		backlog_band="heavy"
	fi

	if [[ "$backlog_band" == "critical" || ("$ready_prs" -ge "$PULSE_READY_PR_MERGE_HEAVY_THRESHOLD" && "$pr_delta" -ge 0) ]]; then
		queue_mode="merge-heavy"
		if [[ "$pr_focus_pct" -lt 90 ]]; then
			pr_focus_pct=90
		fi
	elif [[ "$backlog_band" == "heavy" || "$failing_prs" -ge "$PULSE_FAILING_PR_HEAVY_THRESHOLD" || "$pr_focus_pct" -ge 60 ]]; then
		queue_mode="pr-heavy"
		if [[ "$pr_focus_pct" -lt 75 ]]; then
			pr_focus_pct=75
		fi
	fi
	new_issue_pct=$((100 - pr_focus_pct))

	printf 'queue_mode=%s\nbacklog_band=%s\npr_focus_pct=%s\nnew_issue_pct=%s\n' \
		"$queue_mode" "$backlog_band" "$pr_focus_pct" "$new_issue_pct"
	return 0
}

#######################################
# Write metrics file and emit governor state to STATE_FILE (GH#14960)
#
# Arguments:
#   $1  - total_prs
#   $2  - total_issues
#   $3  - ready_prs
#   $4  - failing_prs
#   $5  - now_epoch
#   $6  - pr_delta
#   $7  - issue_delta
#   $8  - ready_delta
#   $9  - failing_delta
#   $10 - backlog_drain_per_cycle
#   $11 - backlog_growth_pressure
#   $12 - drain_rate_per_hour
#   $13 - backlog_band
#   $14 - queue_mode
#   $15 - pr_focus_pct
#   $16 - new_issue_pct
#   $17 - active_workers
#   $18 - max_workers
#   $19 - utilization_pct
#######################################
_emit_queue_governor_state() {
	local total_prs="$1"
	local total_issues="$2"
	local ready_prs="$3"
	local failing_prs="$4"
	local now_epoch="$5"
	local pr_delta="$6"
	local issue_delta="$7"
	local ready_delta="$8"
	local failing_delta="$9"
	local backlog_drain_per_cycle="${10}"
	local backlog_growth_pressure="${11}"
	local drain_rate_per_hour="${12}"
	local backlog_band="${13}"
	local queue_mode="${14}"
	local pr_focus_pct="${15}"
	local new_issue_pct="${16}"
	local active_workers="${17}"
	local max_workers="${18}"
	local utilization_pct="${19}"

	cat >"$QUEUE_METRICS_FILE" <<EOF
prev_total_prs=${total_prs}
prev_total_issues=${total_issues}
prev_ready_prs=${ready_prs}
prev_failing_prs=${failing_prs}
prev_recorded_at=${now_epoch}
EOF

	{
		echo ""
		echo "## Adaptive Queue Governor"
		echo "- Queue totals: PRs=${total_prs} (delta ${pr_delta}), issues=${total_issues} (delta ${issue_delta})"
		echo "- Backlog thresholds: heavy>=${PULSE_PR_BACKLOG_HEAVY_THRESHOLD}, critical>=${PULSE_PR_BACKLOG_CRITICAL_THRESHOLD}; current_band=${backlog_band}"
		echo "- PR execution pressure: ready=${ready_prs} (delta ${ready_delta}), failing_or_changes_requested=${failing_prs} (delta ${failing_delta})"
		echo "- Merge-drain telemetry: open_pr_drain_per_cycle=${backlog_drain_per_cycle}, open_pr_growth_pressure=${backlog_growth_pressure}, estimated_merge_drain_per_hour=${drain_rate_per_hour}"
		echo "- Worker utilization snapshot: active=${active_workers}/${max_workers} (${utilization_pct}%)"
		echo "- Adaptive mode this cycle: ${queue_mode}"
		echo "- Recommended dispatch focus: PR remediation ${pr_focus_pct}% / new issue dispatch ${new_issue_pct}%"
		echo ""
		echo "PULSE_QUEUE_MODE=${queue_mode}"
		echo "PULSE_PR_BACKLOG_BAND=${backlog_band}"
		echo "PR_REMEDIATION_FOCUS_PCT=${pr_focus_pct}"
		echo "NEW_ISSUE_DISPATCH_PCT=${new_issue_pct}"
		echo "OPEN_PR_BACKLOG=${total_prs}"
		echo "OPEN_PR_DRAIN_PER_CYCLE=${backlog_drain_per_cycle}"
		echo "OPEN_PR_GROWTH_PRESSURE=${backlog_growth_pressure}"
		echo "ESTIMATED_MERGE_DRAIN_PER_HOUR=${drain_rate_per_hour}"
		echo "PULSE_ACTIVE_WORKERS=${active_workers}"
		echo "PULSE_MAX_WORKERS=${max_workers}"
		echo "PULSE_WORKER_UTILIZATION_PCT=${utilization_pct}"
		echo ""
		echo "When PR backlog is rising, prioritize merge-ready and failing-check PR advancement before new issue starts."
	} >>"$STATE_FILE"

	return 0
}

#######################################
# Compute queue governor guidance from metrics (GH#5627)
#
# Orchestrates focused helpers to load history, compute deltas,
# determine queue mode, and emit state. Each helper is under 50 lines.
# Refactored from a 145-line monolith (GH#14960).
#
# Arguments:
#   $1 - total_prs
#   $2 - total_issues
#   $3 - ready_prs
#   $4 - failing_prs
# Output: governor guidance appended to STATE_FILE
#######################################
_compute_queue_governor_guidance() {
	local total_prs="$1"
	local total_issues="$2"
	local ready_prs="$3"
	local failing_prs="$4"

	[[ "$total_prs" =~ ^[0-9]+$ ]] || total_prs=0
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$ready_prs" =~ ^[0-9]+$ ]] || ready_prs=0
	[[ "$failing_prs" =~ ^[0-9]+$ ]] || failing_prs=0

	# Load previous cycle metrics
	local prev_total_prs prev_total_issues prev_ready_prs prev_failing_prs prev_recorded_at
	eval "$(_load_queue_metrics_history)"

	# Compute deltas and drain metrics
	local pr_delta issue_delta ready_delta failing_delta
	local backlog_drain_per_cycle backlog_growth_pressure drain_rate_per_hour
	local elapsed_seconds now_epoch
	eval "$(_compute_queue_deltas \
		"$total_prs" "$total_issues" "$ready_prs" "$failing_prs" \
		"$prev_total_prs" "$prev_total_issues" "$prev_ready_prs" "$prev_failing_prs" \
		"$prev_recorded_at")"

	# Determine queue mode and focus percentages
	local queue_mode backlog_band pr_focus_pct new_issue_pct
	eval "$(_compute_queue_mode \
		"$total_prs" "$total_issues" "$ready_prs" "$failing_prs" "$pr_delta")"

	# Get worker utilization
	local active_workers max_workers utilization_pct
	active_workers=$(count_active_workers)
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	max_workers=$(get_max_workers_target)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	fi
	utilization_pct=$(((active_workers * 100) / max_workers))

	# Write metrics file and emit state output
	_emit_queue_governor_state \
		"$total_prs" "$total_issues" "$ready_prs" "$failing_prs" \
		"$now_epoch" \
		"$pr_delta" "$issue_delta" "$ready_delta" "$failing_delta" \
		"$backlog_drain_per_cycle" "$backlog_growth_pressure" "$drain_rate_per_hour" \
		"$backlog_band" "$queue_mode" "$pr_focus_pct" "$new_issue_pct" \
		"$active_workers" "$max_workers" "$utilization_pct"

	echo "[pulse-wrapper] Adaptive queue governor: mode=${queue_mode} prs=${total_prs} issues=${total_issues} pr_focus=${pr_focus_pct}%" >>"$LOGFILE"
	return 0
}

append_adaptive_queue_governor() {
	if [[ ! -f "$STATE_FILE" ]]; then
		return 0
	fi

	# Fetch current queue metrics from all pulse-enabled repos
	local metrics_output
	metrics_output=$(_fetch_queue_metrics)

	local total_prs total_issues ready_prs failing_prs
	total_prs=$(echo "$metrics_output" | sed -n '1p')
	total_issues=$(echo "$metrics_output" | sed -n '2p')
	ready_prs=$(echo "$metrics_output" | sed -n '3p')
	failing_prs=$(echo "$metrics_output" | sed -n '4p')

	# Compute guidance and append to state file
	_compute_queue_governor_guidance "$total_prs" "$total_issues" "$ready_prs" "$failing_prs"
	return 0
}

#######################################
# Get current max workers from pulse-max-workers file
# Returns: numeric value via stdout (defaults to 1)
#######################################
get_max_workers_target() {
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	local max_workers
	max_workers=$(cat "$max_workers_file" 2>/dev/null || echo "1")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	fi
	echo "$max_workers"
	return 0
}

#######################################
# Count runnable backlog candidates across pulse scope
# Heuristic for t1453 utilization loop:
# - open issues passing default-open candidate filter
#   (non-needs-* and non-management labels)
# - open PRs with failing checks or changes requested
# Returns: count via stdout
#######################################
count_runnable_candidates() {
	local repos_json="${REPOS_JSON}"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "0"
		return 0
	fi

	local total=0
	while IFS='|' read -r slug _path; do
		[[ -n "$slug" ]] || continue

		local issue_count
		issue_count=$(list_dispatchable_issue_candidates "$slug" "$PULSE_RUNNABLE_ISSUE_LIMIT" | wc -l | tr -d ' ') || issue_count=0
		[[ "$issue_count" =~ ^[0-9]+$ ]] || issue_count=0

		local pr_json pr_rc_err
		pr_rc_err=$(mktemp)
		pr_json=$(gh pr list --repo "$slug" --state open --json reviewDecision,statusCheckRollup --limit "$PULSE_RUNNABLE_PR_LIMIT" 2>"$pr_rc_err") || pr_json="[]"
		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
			local _pr_rc_err_msg
			_pr_rc_err_msg=$(cat "$pr_rc_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] count_runnable_candidates: gh pr list FAILED for ${slug}: ${_pr_rc_err_msg}" >>"$LOGFILE"
			pr_json="[]"
		fi
		rm -f "$pr_rc_err"
		local pr_count
		pr_count=$(echo "$pr_json" | jq '[.[] | select(.reviewDecision == "CHANGES_REQUESTED" or ((.statusCheckRollup // []) | any((.conclusion // .state) == "FAILURE")))] | length' 2>/dev/null) || pr_count=0
		[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
		pulse_count_debug_log "count_runnable_candidates repo=${slug} issues=${issue_count} prs=${pr_count} total=$((issue_count + pr_count))"

		total=$((total + issue_count + pr_count))
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	echo "$total"
	return 0
}

#######################################
# Count queued issues that do not have an active worker process
# This is a launch-validation signal: queued labels imply dispatch,
# but no matching worker indicates startup failure or immediate exit.
# Returns: count via stdout
#######################################
count_queued_without_worker() {
	local repos_json="${REPOS_JSON}"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "0"
		return 0
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")

	local total=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local queued_json queued_err
		queued_err=$(mktemp)
		queued_json=$(gh issue list --repo "$slug" --state open --label "status:queued" --json number,assignees --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>"$queued_err") || queued_json="[]"
		if [[ -z "$queued_json" || "$queued_json" == "null" ]]; then
			local _queued_err_msg
			_queued_err_msg=$(cat "$queued_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] count_queued_without_worker: gh issue list FAILED for ${slug}: ${_queued_err_msg}" >>"$LOGFILE"
			queued_json="[]"
		fi
		rm -f "$queued_err"

		local queued_count
		queued_count=$(echo "$queued_json" | jq 'length' 2>/dev/null) || queued_count=0
		[[ "$queued_count" =~ ^[0-9]+$ ]] || queued_count=0
		pulse_count_debug_log "count_queued_without_worker repo=${slug} queued=${queued_count}"
		if [[ "$queued_count" -eq 0 ]]; then
			continue
		fi

		while IFS='|' read -r issue_num assigned_to_other; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Cross-runner safety: queued issues assigned to another login are not
			# counted as "without worker" because the worker may be running on that
			# runner's machine and invisible to local process inspection.
			if [[ "$assigned_to_other" == "true" ]]; then
				continue
			fi

			if ! has_worker_for_repo_issue "$issue_num" "$slug"; then
				total=$((total + 1))
				pulse_count_debug_log "count_queued_without_worker repo=${slug} issue=${issue_num} missing_worker=true"
			fi
		done < <(echo "$queued_json" | jq -r --arg self "$self_login" '.[] | .number as $n | ((.assignees | length) > 0 and (([.assignees[].login] | index($self)) == null)) as $assigned_other | "\($n)|\($assigned_other)"' 2>/dev/null)
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	echo "$total"
	return 0
}

#######################################
# Emit debug logs for pulse count helpers without polluting stdout.
#
# Debug logs are opt-in via PULSE_DEBUG and always go to stderr so helpers that
# are consumed numerically keep a strict stdout contract.
#
# Arguments:
#   $1 - message to log
# Returns: 0 always
#######################################
pulse_count_debug_log() {
	local message="$1"
	case "${PULSE_DEBUG:-}" in
	1 | true | TRUE | yes | YES | on | ON)
		printf '[pulse-wrapper] DEBUG: %s\n' "$message" >&2
		;;
	esac
	return 0
}

#######################################
# Normalize noisy helper stdout to a numeric count.
#
# Some count helpers may emit diagnostic lines before their final numeric
# result. Accept the last line that is purely an integer; otherwise fail closed
# to 0.
#
# Arguments:
#   $1 - raw helper stdout
# Returns: normalized integer via stdout
#######################################
normalize_count_output() {
	local raw_output="$1"
	local normalized
	normalized=$(printf '%s\n' "$raw_output" | awk '
		/^[[:space:]]*[0-9]+[[:space:]]*$/ {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
			last = $0
		}
		END {
			if (last != "") {
				print last
			}
		}
	')

	if [[ "$normalized" =~ ^[0-9]+$ ]]; then
		echo "$normalized"
		return 0
	fi

	echo "0"
	return 0
}

#######################################
# Recover issue state after launch validation failure (t1702)
#
# When launch validation fails, the issue may remain assigned + queued even
# though no worker process exists. This traps capacity by blocking redispatch.
#
# Safety gates:
#   - Only act on OPEN issues
#   - Only act when current GitHub login is assigned on the issue
#   - Only act when issue still has status:queued label
#   - Re-check for a late-started worker before mutating issue state
#
# Actions (best-effort):
#   1. Mark any in-flight ledger entry for this issue as failed
#   2. Remove self assignee and status:queued
#   3. Re-label status:available unless issue is blocked
#
# Args:
#   $1 - issue number
#   $2 - repo slug
#   $3 - failure reason string (for logs)
#######################################
recover_failed_launch_state() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_reason="${3:-launch_validation_failed}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# Mark in-flight ledger entry as failed even if GitHub claim edits never stuck.
	local ledger_helper
	ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		local ledger_entry session_key
		ledger_entry=$("$ledger_helper" check-issue --issue "$issue_number" --repo "$repo_slug" 2>/dev/null || true)
		session_key=$(printf '%s' "$ledger_entry" | jq -r '.session_key // ""' 2>/dev/null)
		if [[ -n "$session_key" ]]; then
			"$ledger_helper" fail --session-key "$session_key" >/dev/null 2>&1 || true
		fi
	fi

	# For no-worker failures, skip cleanup if a late-started worker appears.
	# For cli_usage_output failures, always continue to clear stale claim state.
	if [[ "$failure_reason" != "cli_usage_output" ]]; then
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): worker appeared after validation failure" >>"$LOGFILE"
			return 0
		fi
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$self_login" ]]; then
		echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): unable to resolve current login" >>"$LOGFILE"
		return 0
	fi

	local issue_meta_json
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" --json state,labels,assignees 2>/dev/null) || issue_meta_json=""
	if [[ -z "$issue_meta_json" ]]; then
		return 0
	fi

	local issue_state assigned_to_self has_queued is_blocked
	issue_state=$(echo "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null)
	assigned_to_self=$(echo "$issue_meta_json" | jq -r --arg self "$self_login" '([.assignees[].login] | index($self)) != null' 2>/dev/null)
	has_queued=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:queued")) != null' 2>/dev/null)
	is_blocked=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:blocked")) != null' 2>/dev/null)

	[[ "$assigned_to_self" == "true" || "$assigned_to_self" == "false" ]] || assigned_to_self="false"
	[[ "$has_queued" == "true" || "$has_queued" == "false" ]] || has_queued="false"
	[[ "$is_blocked" == "true" || "$is_blocked" == "false" ]] || is_blocked="false"

	if [[ "$issue_state" != "OPEN" ]] || [[ "$assigned_to_self" != "true" ]] || [[ "$has_queued" != "true" ]]; then
		return 0
	fi

	if [[ "$is_blocked" == "true" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-assignee "$self_login" --remove-label "status:queued" >/dev/null 2>&1 || true
	else
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-assignee "$self_login" --remove-label "status:queued" --add-label "status:available" >/dev/null 2>&1 ||
			gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-assignee "$self_login" --remove-label "status:queued" >/dev/null 2>&1 || true
	fi

	# Record the launch failure in the fast-fail counter (t1888)
	fast_fail_record "$issue_number" "$repo_slug" "$failure_reason" || true

	echo "[pulse-wrapper] Launch recovery reset #${issue_number} (${repo_slug}) after ${failure_reason}: removed self assignee + status:queued" >>"$LOGFILE"
	return 0
}

#######################################
# Per-issue retry state (t1888, GH#2076, GH#17384)
#
# Cause-aware retry backoff. See config block at line ~205 for the full
# decision tree. Key invariant: rate-limit failures with available accounts
# do NOT increment the counter or delay retry — they rotate immediately.
# Only exhaustion of all accounts or non-rate-limit failures trigger backoff.
#
# State file: FAST_FAIL_STATE_FILE (JSON, ~200 bytes per entry)
# Format: { "slug/number": { "count": N, "ts": epoch, "reason": "...",
#            "retry_after": epoch, "backoff_secs": N } }
#
# Integration points:
#   - pulse-wrapper.sh: fast_fail_record() on launch failure (recover_failed_launch_state)
#   - worker-watchdog.sh: _watchdog_record_failure_and_escalate() on worker kill
#   - pulse-wrapper.sh: fast_fail_reset() on PR merge / issue close
#   - pulse-wrapper.sh: fast_fail_is_skipped() in deterministic dispatch loop
#
# All functions are best-effort — failures are logged but never fatal.
#######################################

#######################################
# Return the fast-fail state key for an issue.
# Arguments: $1 issue_number, $2 repo_slug
#######################################
_ff_key() {
	local issue_number="$1"
	local repo_slug="$2"
	printf '%s/%s' "$repo_slug" "$issue_number"
	return 0
}

#######################################
# Load the fast-fail state file as JSON.
# Outputs "{}" on missing or corrupt file.
#######################################
_ff_load() {
	if [[ ! -f "$FAST_FAIL_STATE_FILE" ]]; then
		printf '{}'
		return 0
	fi
	local content
	content=$(cat "$FAST_FAIL_STATE_FILE" 2>/dev/null) || content="{}"
	# Validate JSON; reset if corrupt
	if ! printf '%s' "$content" | jq empty 2>/dev/null; then
		printf '{}'
		return 0
	fi
	printf '%s' "$content"
	return 0
}

#######################################
# Query the OAuth account pool to determine retry strategy for rate limits.
#
# Checks whether any non-rate-limited accounts are available for the given
# provider. If yes, returns 0 (immediate retry with rotation). If all
# accounts are exhausted, returns the number of seconds until the earliest
# account recovers via stdout.
#
# Uses the same logic as parse_retry_after_seconds() in headless-runtime-helper.sh
# but is self-contained so the pulse can query without launching a subprocess.
#
# Arguments:
#   $1 - provider (anthropic, openai, cursor, google)
# Stdout: seconds until earliest recovery (0 = accounts available now,
#         -1 = no pool configured / query failed)
# Returns: 0 always (best-effort)
#######################################
_ff_query_pool_retry_seconds() {
	local provider="${1:-anthropic}"
	local pool_file="${HOME}/.aidevops/oauth-pool.json"

	# No pool file = no pool management = signal "no pool configured" so caller
	# falls through to exponential backoff instead of treating it as "available now".
	if [[ ! -f "$pool_file" ]]; then
		echo "-1"
		return 0
	fi

	local result
	result=$(POOL_FILE="$pool_file" PROVIDER="$provider" python3 -c "
import json, os, time, sys
try:
    pool = json.load(open(os.environ['POOL_FILE']))
    now_ms = int(time.time() * 1000)
    accounts = pool.get(os.environ['PROVIDER'], [])
    if not accounts:
        # No accounts configured for this provider — can't determine availability
        print(-1); sys.exit(0)
    min_remaining = None
    for a in accounts:
        cd = a.get('cooldownUntil')
        if cd and int(cd) > now_ms and a.get('status') == 'rate-limited':
            remaining_s = max(1, (int(cd) - now_ms) // 1000)
            min_remaining = min(min_remaining, remaining_s) if min_remaining else remaining_s
        else:
            # At least one account is available — immediate retry
            print(0); sys.exit(0)
    # All accounts rate-limited — return shortest wait
    print(min_remaining or 0)
except Exception:
    print(-1)
" 2>/dev/null) || result="-1"

	[[ "$result" =~ ^-?[0-9]+$ ]] || result="-1"
	echo "$result"
	return 0
}

#######################################
# Acquire an exclusive lock for fast-fail state read-modify-write.
# Uses mkdir atomicity (same pattern as circuit-breaker-helper.sh).
# Both pulse-wrapper.sh and worker-watchdog.sh write to the same
# state file — this prevents lost increments from concurrent updates.
# (GH#2076, CodeRabbit review)
#
# Arguments: command and arguments to run under lock
# Returns: exit code of the wrapped command
#######################################
_ff_with_lock() {
	local lock_dir="${FAST_FAIL_STATE_FILE}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			echo "[pulse-wrapper] _ff_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		sleep 0.1
	done
	local rc=0
	"$@" || rc=$?
	rmdir "$lock_dir" 2>/dev/null || true
	return "$rc"
}

#######################################
# Write updated state atomically (tmp + mv).
# Arguments: $1 JSON string
#######################################
_ff_save() {
	local json="$1"
	local state_dir
	state_dir=$(dirname "$FAST_FAIL_STATE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	local tmp_file
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || return 0
	if printf '%s\n' "$json" >"$tmp_file"; then
		mv "$tmp_file" "$FAST_FAIL_STATE_FILE" || {
			rm -f "$tmp_file"
			echo "[pulse-wrapper] _ff_save: failed to move fast-fail state" >>"$LOGFILE"
		}
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _ff_save: failed to write fast-fail state" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Record a worker failure for an issue with cause-aware retry strategy.
#
# Rate-limit failures query the account pool before deciding on backoff.
# Non-rate-limit failures use exponential backoff (10m → 20m → ... → 7d).
#
# Acquires a file lock to prevent lost updates from concurrent
# pulse-wrapper and worker-watchdog writes. (GH#2076, GH#17384)
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - reason (rate_limit, backoff, stall, idle, thrash, runtime,
#                no_worker_process, cli_usage_output, local_error, etc.)
#   $4 - provider (optional, for rate-limit pool queries; default: anthropic)
#######################################
fast_fail_record() {
	_ff_with_lock _fast_fail_record_locked "$@" || return 0
	return 0
}

_fast_fail_record_locked() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="${3:-launch_failure}"
	local provider="${4:-anthropic}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local key now state
	key=$(_ff_key "$issue_number" "$repo_slug")
	now=$(date +%s)
	state=$(_ff_load)

	# Read existing entry (reset all fields if expired)
	local existing_ts existing_count existing_backoff
	existing_ts=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].ts // 0' 2>/dev/null) || existing_ts=0
	existing_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].count // 0' 2>/dev/null) || existing_count=0
	existing_backoff=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].backoff_secs // 0' 2>/dev/null) || existing_backoff=0
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_backoff" =~ ^[0-9]+$ ]] || existing_backoff=0

	local age=$((now - existing_ts))
	if [[ "$age" -ge "$FAST_FAIL_EXPIRY_SECS" ]]; then
		existing_count=0
		existing_backoff=0
	fi

	# ── Decide retry strategy based on failure cause ──
	local new_count="$existing_count"
	local new_backoff="$existing_backoff"
	local retry_after=0
	local log_action=""

	case "$reason" in
	rate_limit* | backoff)
		# Rate-limit: check if other accounts are available
		local pool_wait
		pool_wait=$(_ff_query_pool_retry_seconds "$provider")

		if [[ "$pool_wait" == "0" ]]; then
			# Other accounts available — immediate retry, no counter increment.
			# The next dispatch will rotate to a different account automatically.
			retry_after=0
			log_action="rate_limit_rotate (accounts available, immediate retry)"
		elif [[ "$pool_wait" == "-1" ]]; then
			# No pool configured or query failed — use exponential backoff
			new_count=$((existing_count + 1))
			new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
			[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
			retry_after=$((now + new_backoff))
			log_action="rate_limit_no_pool (no pool data, backoff=${new_backoff}s)"
		else
			# All accounts exhausted — wait for earliest recovery.
			# Use pool_wait for retry_after but keep backoff_secs on the
			# exponential ladder so a subsequent failure doesn't reset to
			# a short pool cooldown value.
			new_count=$((existing_count + 1))
			retry_after=$((now + pool_wait))
			new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
			[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
			log_action="rate_limit_exhausted (all accounts rate-limited, wait=${pool_wait}s, backoff_stage=${new_backoff}s)"
		fi
		;;

	*)
		# Non-rate-limit failure: exponential backoff
		new_count=$((existing_count + 1))
		new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
		[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
		retry_after=$((now + new_backoff))
		log_action="failure_backoff (count=${new_count}, backoff=${new_backoff}s)"
		;;
	esac

	# Write updated state
	local updated_state
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		--argjson count "$new_count" \
		--argjson ts "$now" \
		--arg reason "$reason" \
		--argjson retry_after "$retry_after" \
		--argjson backoff_secs "$new_backoff" \
		'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs}' 2>/dev/null) || return 0

	_ff_save "$updated_state"
	echo "[pulse-wrapper] fast_fail_record: #${issue_number} (${repo_slug}) ${log_action} reason=${reason}" >>"$LOGFILE"

	# Trigger tier escalation on non-rate-limit failures only (GH#2076).
	# Rate-limit paths (rate_limit*, backoff) don't escalate — the model isn't
	# the problem, it's provider capacity. Escalating would waste a higher tier.
	local is_rate_limit=false
	case "$reason" in
	rate_limit* | backoff) is_rate_limit=true ;;
	esac
	if [[ "$is_rate_limit" == "false" && "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason" || true
	fi

	return 0
}

#######################################
# Reset the fast-fail counter for an issue.
#
# Called when an issue is confirmed resolved (PR merged, issue closed) —
# NOT on launch success. Previously this was called on launch, which
# defeated the counter entirely since every launch reset it before the
# worker could fail. (GH#2076, GH#17378)
#
# Arguments: $1 issue_number, $2 repo_slug
#######################################
fast_fail_reset() {
	_ff_with_lock _fast_fail_reset_locked "$@" || return 0
	return 0
}

_fast_fail_reset_locked() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local key state updated_state
	key=$(_ff_key "$issue_number" "$repo_slug")
	state=$(_ff_load)

	# Only write if the key exists (avoid unnecessary writes)
	local existing
	existing=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k] // null' 2>/dev/null)
	if [[ "$existing" == "null" || -z "$existing" ]]; then
		return 0
	fi

	updated_state=$(printf '%s' "$state" | jq --arg k "$key" 'del(.[$k])' 2>/dev/null) || return 0
	_ff_save "$updated_state"
	echo "[pulse-wrapper] fast_fail_reset: #${issue_number} (${repo_slug}) counter cleared" >>"$LOGFILE"
	return 0
}

#######################################
# Check if an issue should be skipped due to retry backoff.
#
# An issue is skipped when EITHER condition is true:
#   1. retry_after is in the future (backoff timer hasn't expired)
#   2. count >= FAST_FAIL_SKIP_THRESHOLD (hard stop — too many failures)
#
# The distinction matters for diagnostics:
#   - Condition 1: "waiting for backoff/rate-limit to clear"
#   - Condition 2: "this issue is fundamentally broken, needs human"
#
# Exit codes:
#   0 - issue is skipped (do NOT dispatch)
#   1 - issue is not skipped (safe to dispatch)
# Arguments: $1 issue_number, $2 repo_slug
#######################################
fast_fail_is_skipped() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	local key now state existing_ts existing_count existing_retry_after
	key=$(_ff_key "$issue_number" "$repo_slug")
	now=$(date +%s)
	state=$(_ff_load)

	existing_ts=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].ts // 0' 2>/dev/null) || existing_ts=0
	existing_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].count // 0' 2>/dev/null) || existing_count=0
	existing_retry_after=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].retry_after // 0' 2>/dev/null) || existing_retry_after=0
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_retry_after" =~ ^[0-9]+$ ]] || existing_retry_after=0

	# Check overall expiry (entire entry is stale).
	# Mirror fast_fail_prune_expired(): only expire when BOTH the ts is old
	# AND the retry_after window has passed. This prevents discarding entries
	# that still have an active backoff timer (e.g., rate-limit waits).
	local age=$((now - existing_ts))
	if [[ "$age" -ge "$FAST_FAIL_EXPIRY_SECS" && "$existing_retry_after" -le "$now" ]]; then
		return 1 # Expired — not skipped
	fi

	# Hard stop: too many non-rate-limit failures
	if [[ "$existing_count" -ge "$FAST_FAIL_SKIP_THRESHOLD" ]]; then
		echo "[pulse-wrapper] fast_fail_is_skipped: #${issue_number} (${repo_slug}) HARD STOP count=${existing_count}>=${FAST_FAIL_SKIP_THRESHOLD}" >>"$LOGFILE"
		return 0 # Skipped
	fi

	# Backoff timer: retry_after is in the future
	if [[ "$existing_retry_after" -gt "$now" ]]; then
		local wait_remaining=$((existing_retry_after - now))
		echo "[pulse-wrapper] fast_fail_is_skipped: #${issue_number} (${repo_slug}) BACKOFF wait=${wait_remaining}s retry_after=$(date -r "$existing_retry_after" '+%H:%M:%S' 2>/dev/null || echo "$existing_retry_after")" >>"$LOGFILE"
		return 0 # Skipped — backoff timer active
	fi

	return 1 # Safe to dispatch
}

#######################################
# Prune expired entries from the fast-fail state file.
# An entry is expired when its ts is older than FAST_FAIL_EXPIRY_SECS
# AND its retry_after has passed (we don't prune entries that still
# have an active backoff timer, even if they're old).
# Called periodically to keep the file small.
#######################################
fast_fail_prune_expired() {
	_ff_with_lock _fast_fail_prune_expired_locked || return 0
	return 0
}

_fast_fail_prune_expired_locked() {
	local now state pruned
	now=$(date +%s)
	state=$(_ff_load)

	pruned=$(printf '%s' "$state" | jq \
		--argjson now "$now" \
		--argjson expiry "$FAST_FAIL_EXPIRY_SECS" \
		'with_entries(select(
			(($now - (.value.ts // 0)) < $expiry) or
			((.value.retry_after // 0) > $now)
		))' 2>/dev/null) || return 0

	local before_count after_count
	before_count=$(printf '%s' "$state" | jq 'length' 2>/dev/null) || before_count=0
	after_count=$(printf '%s' "$pruned" | jq 'length' 2>/dev/null) || after_count=0

	if [[ "$before_count" -ne "$after_count" ]]; then
		_ff_save "$pruned"
		echo "[pulse-wrapper] fast_fail_prune_expired: pruned $((before_count - after_count)) expired entries" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Launch validation gate for pulse dispatches (t1453)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional grace timeout in seconds
#
# Exit codes:
#   0 - worker launch appears valid (process observed, no CLI usage output marker)
#   1 - launch invalid (no process within grace window or usage output detected)
#######################################
check_worker_launch() {
	local issue_number="$1"
	local repo_slug="$2"
	local grace_seconds="${3:-$PULSE_LAUNCH_GRACE_SECONDS}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_worker_launch: invalid arguments issue='$issue_number' repo='$repo_slug'" >>"$LOGFILE"
		return 1
	fi
	[[ "$grace_seconds" =~ ^[0-9]+$ ]] || grace_seconds="$PULSE_LAUNCH_GRACE_SECONDS"
	if [[ "$grace_seconds" -lt 1 ]]; then
		grace_seconds=1
	fi

	local safe_slug
	safe_slug=$(echo "$repo_slug" | tr '/:' '--')
	local -a log_candidates=(
		"/tmp/pulse-${safe_slug}-${issue_number}.log"
		"/tmp/pulse-${issue_number}.log"
	)

	local elapsed=0
	local poll_seconds=2
	while [[ "$elapsed" -lt "$grace_seconds" ]]; do
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			local candidate
			for candidate in "${log_candidates[@]}"; do
				if [[ -f "$candidate" ]] && rg -q '^opencode run \[message\.\.\]|^run opencode with a message|^Options:' "$candidate"; then
					recover_failed_launch_state "$issue_number" "$repo_slug" "cli_usage_output"
					echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — CLI usage output detected in ${candidate}" >>"$LOGFILE"
					return 1
				fi
			done
			# Launch confirmed — do NOT reset fast-fail counter here.
			# A successful launch does not mean successful completion.
			# The counter is reset only when the issue is closed or a PR
			# is confirmed. Resetting on launch defeated the counter
			# entirely — workers that launched but died during execution
			# were invisible. (GH#2076, GH#17378)
			return 0
		fi
		sleep "$poll_seconds"
		elapsed=$((elapsed + poll_seconds))
	done

	recover_failed_launch_state "$issue_number" "$repo_slug" "no_worker_process"
	echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — no active worker process within ${grace_seconds}s" >>"$LOGFILE"
	return 1
}

#######################################
# Build ranked deterministic dispatch candidates across all pulse repos.
# Arguments:
#   $1 - max issues to fetch per repo (optional)
# Returns: JSON array sorted by score desc, updatedAt asc
#######################################
build_ranked_dispatch_candidates_json() {
	local per_repo_limit="${1:-$PULSE_RUNNABLE_ISSUE_LIMIT}"
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit="$PULSE_RUNNABLE_ISSUE_LIMIT"

	if [[ ! -f "$REPOS_JSON" ]]; then
		printf '[]\n'
		return 0
	fi

	local tmp_candidates
	tmp_candidates=$(mktemp 2>/dev/null || echo "/tmp/aidevops-pulse-candidates.$$")
	: >"$tmp_candidates"

	while IFS='|' read -r repo_slug repo_path repo_priority ph_start ph_end expires; do
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue
		if ! check_repo_pulse_schedule "$repo_slug" "$ph_start" "$ph_end" "$expires" "$REPOS_JSON"; then
			continue
		fi
		local repo_candidates_json
		repo_candidates_json=$(list_dispatchable_issue_candidates_json "$repo_slug" "$per_repo_limit") || repo_candidates_json='[]'
		if [[ -z "$repo_candidates_json" || "$repo_candidates_json" == "[]" ]]; then
			continue
		fi

		printf '%s' "$repo_candidates_json" | jq -c --arg slug "$repo_slug" --arg path "$repo_path" --arg priority "$repo_priority" '
			.[] |
			. + {
				repo_slug: $slug,
				repo_path: $path,
				repo_priority: $priority,
				score: (
					(if $priority == "product" then 2000 elif $priority == "tooling" then 1000 else 0 end) +
					(if (.labels | index("priority:critical")) != null then 10000
					 elif (.labels | index("priority:high")) != null then 8000
					 elif (.labels | index("bug")) != null then 7000
					 elif (.labels | index("enhancement")) != null then 6000
					 elif (.labels | index("quality-debt")) != null then 5000
					 elif (.labels | index("simplification-debt")) != null then 4000
					 else 3000 end)
				)
			}
		' >>"$tmp_candidates" 2>/dev/null || true
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | [(.slug), (.path), (.priority // "tooling"), (if .pulse_hours then (.pulse_hours.start | tostring) else "" end), (if .pulse_hours then (.pulse_hours.end | tostring) else "" end), (.pulse_expires // "")] | join("|")' "$REPOS_JSON" 2>/dev/null)

	if [[ ! -s "$tmp_candidates" ]]; then
		rm -f "$tmp_candidates"
		printf '[]\n'
		return 0
	fi

	jq -cs 'sort_by([-.score, (.updatedAt // "")])' "$tmp_candidates" 2>/dev/null || printf '[]\n'
	rm -f "$tmp_candidates"
	return 0
}

#######################################
# Deterministic fill floor for obvious backlog.
#
# This is intentionally narrow: it only materializes already-eligible issues
# and fills empty local slots. Ranking remains simple and auditable; judgment
# stays with the pulse LLM for merges, blockers, and unusual edge cases.
#
# Returns: dispatched worker count via stdout
#######################################
dispatch_deterministic_fill_floor() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: stop flag present" >>"$LOGFILE"
		echo 0
		return 0
	fi

	local max_workers active_workers available_slots runnable_count queued_without_worker
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

	available_slots=$((max_workers - active_workers))
	if [[ "$available_slots" -le 0 ]]; then
		echo 0
		return 0
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$self_login" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: unable to resolve GitHub login" >>"$LOGFILE"
		echo 0
		return 0
	fi

	local candidates_json candidate_count
	candidates_json=$(build_ranked_dispatch_candidates_json "$PULSE_RUNNABLE_ISSUE_LIMIT") || candidates_json='[]'
	candidate_count=$(printf '%s' "$candidates_json" | jq 'length' 2>/dev/null) || candidate_count=0
	[[ "$candidate_count" =~ ^[0-9]+$ ]] || candidate_count=0
	if [[ "$candidate_count" -eq 0 ]]; then
		echo 0
		return 0
	fi

	echo "[pulse-wrapper] Deterministic fill floor: available=${available_slots}, runnable=${runnable_count}, queued_without_worker=${queued_without_worker}, candidates=${candidate_count}" >>"$LOGFILE"

	# Triage reviews first — community responsiveness before implementation backlog.
	# dispatch_triage_reviews returns the remaining available count via stdout.
	local triage_remaining
	triage_remaining=$(dispatch_triage_reviews "$available_slots" 2>>"$LOGFILE") || triage_remaining="$available_slots"
	[[ "$triage_remaining" =~ ^[0-9]+$ ]] || triage_remaining="$available_slots"
	local triage_dispatched=$((available_slots - triage_remaining))
	if [[ "$triage_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: dispatched ${triage_dispatched} triage review(s), ${triage_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$triage_remaining"

	local dispatched_count=0
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		if [[ "$dispatched_count" -ge "$available_slots" ]]; then
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor stopping early: stop flag appeared" >>"$LOGFILE"
			break
		fi

		local issue_number repo_slug repo_path issue_url issue_title dispatch_title prompt labels_csv model_override
		issue_number=$(printf '%s' "$candidate_json" | jq -r '.number // empty' 2>/dev/null)
		repo_slug=$(printf '%s' "$candidate_json" | jq -r '.repo_slug // empty' 2>/dev/null)
		repo_path=$(printf '%s' "$candidate_json" | jq -r '.repo_path // empty' 2>/dev/null)
		issue_url=$(printf '%s' "$candidate_json" | jq -r '.url // empty' 2>/dev/null)
		issue_title=$(printf '%s' "$candidate_json" | jq -r '.title // empty' 2>/dev/null | tr '\n' ' ')
		labels_csv=$(printf '%s' "$candidate_json" | jq -r '(.labels // []) | join(",")' 2>/dev/null)
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue

		if check_terminal_blockers "$issue_number" "$repo_slug" >/dev/null 2>&1; then
			continue
		fi

		# Skip issues with repeated launch deaths (t1888)
		if fast_fail_is_skipped "$issue_number" "$repo_slug"; then
			echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — fast-fail threshold reached" >>"$LOGFILE"
			continue
		fi

		# t1899: Skip issues with placeholder/empty bodies — dispatching a
		# worker to an undescribed issue wastes a session. The body check is
		# a single API call cached for the candidate loop iteration.
		local issue_body
		issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body -q '.body' 2>/dev/null || echo "")
		if [[ -z "$issue_body" || "$issue_body" == "Task created via claim-task-id.sh" || "$issue_body" == "null" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — placeholder/empty issue body, needs enrichment before dispatch" >>"$LOGFILE"
			continue
		fi

		dispatch_title="Issue #${issue_number}"
		prompt="/full-loop Implement issue #${issue_number}"
		if [[ -n "$issue_url" ]]; then
			prompt="${prompt} (${issue_url})"
		fi
		model_override=$(resolve_dispatch_model_for_labels "$labels_csv")

		local dispatch_rc=0
		dispatch_with_dedup "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
			"$self_login" "$repo_path" "$prompt" "issue-${issue_number}" "$model_override" || dispatch_rc=$?
		if [[ "$dispatch_rc" -ne 0 ]]; then
			continue
		fi

		if ! check_worker_launch "$issue_number" "$repo_slug" >/dev/null 2>&1; then
			continue
		fi

		dispatched_count=$((dispatched_count + 1))
	done < <(printf '%s' "$candidates_json" | jq -c '.[]' 2>/dev/null)

	local total_dispatched=$((dispatched_count + triage_dispatched))
	echo "[pulse-wrapper] Deterministic fill floor complete: dispatched=${total_dispatched} (${triage_dispatched} triage + ${dispatched_count} implementation), target_available=${available_slots}" >>"$LOGFILE"
	echo "$total_dispatched"
	return 0
}

#######################################
# Apply deterministic fill floor after a pulse pass.
#######################################
# Deterministic merge pass: approve and merge all ready PRs.
#
# Runs every pulse cycle as a wrapper-level stage (not LLM-dependent).
# This prevents PR backlogs from accumulating when the LLM fails to
# execute merge steps or the prefetch was broken.
#
# A PR is merge-ready when ALL of:
#   1. mergeable == MERGEABLE (not conflicting)
#   2. Author is a collaborator (admin/maintain/write permission)
#   3. Not modifying .github/workflows/ without workflow token scope
#   4. No linked issue with needs-maintainer-review label
#   5. Not from an external contributor
#
# REVIEW_REQUIRED is not a blocker — the pulse user auto-approves
# collaborator PRs via approve_collaborator_pr().
#
# Conflicting PRs are closed with a comment (they will be superseded
# by workers re-dispatching the issue).
#
# Returns: 0 always (non-fatal — merge failures don't block the pulse)
#######################################
PULSE_MERGE_BATCH_LIMIT="${PULSE_MERGE_BATCH_LIMIT:-50}"
PULSE_MERGE_CLOSE_CONFLICTING="${PULSE_MERGE_CLOSE_CONFLICTING:-true}"

merge_ready_prs_all_repos() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: stop flag present" >>"$LOGFILE"
		return 0
	fi

	if [[ ! -f "$REPOS_JSON" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: repos.json not found" >>"$LOGFILE"
		return 0
	fi

	local total_merged=0
	local total_closed=0
	local total_failed=0

	while IFS='|' read -r repo_slug repo_path; do
		[[ -n "$repo_slug" ]] || continue

		local repo_merged=0
		local repo_closed=0
		local repo_failed=0

		_merge_ready_prs_for_repo "$repo_slug" repo_merged repo_closed repo_failed

		total_merged=$((total_merged + repo_merged))
		total_closed=$((total_closed + repo_closed))
		total_failed=$((total_failed + repo_failed))

		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Deterministic merge pass: stop flag appeared mid-run" >>"$LOGFILE"
			break
		fi
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$REPOS_JSON" 2>/dev/null)

	if [[ $((total_merged + total_closed)) -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic merge pass complete: merged=${total_merged}, closed_conflicting=${total_closed}, failed=${total_failed}" >>"$LOGFILE"
	fi
	# Accumulate into per-cycle health counters (GH#15107)
	_PULSE_HEALTH_PRS_MERGED=$((_PULSE_HEALTH_PRS_MERGED + total_merged))
	_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=$((_PULSE_HEALTH_PRS_CLOSED_CONFLICTING + total_closed))
	return 0
}

#######################################
# Merge ready PRs for a single repo.
#
# Uses nameref variables to return counts to the caller.
# Args:
#   $1 - repo slug
#   $2 - nameref for merged count
#   $3 - nameref for closed count
#   $4 - nameref for failed count
#######################################
_merge_ready_prs_for_repo() {
	local repo_slug="$1"
	# Bash 3.2 compat: no nameref. Use eval to set caller variables.
	local _merged_var="$2"
	local _closed_var="$3"
	local _failed_var="$4"

	local merged=0
	local closed=0
	local failed=0

	# Fetch open PRs — lightweight call without statusCheckRollup (GH#15060 lesson)
	local pr_json pr_merge_err
	pr_merge_err=$(mktemp)
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--json number,mergeable,reviewDecision,author,title \
		--limit "$PULSE_MERGE_BATCH_LIMIT" 2>"$pr_merge_err") || pr_json="[]"
	if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
		local _pr_merge_err_msg
		_pr_merge_err_msg=$(cat "$pr_merge_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] _process_merge_batch: gh pr list FAILED for ${repo_slug}: ${_pr_merge_err_msg}" >>"$LOGFILE"
		pr_json="[]"
	fi
	rm -f "$pr_merge_err"

	local pr_count
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	if [[ "$pr_count" -eq 0 ]]; then
		eval "${_merged_var}=0; ${_closed_var}=0; ${_failed_var}=0"
		return 0
	fi

	# Process each PR
	local i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		if [[ -f "$STOP_FLAG" ]]; then
			break
		fi

		local pr_number pr_mergeable pr_review pr_author pr_title
		pr_number=$(printf '%s' "$pr_json" | jq -r ".[$i].number" 2>/dev/null)
		pr_mergeable=$(printf '%s' "$pr_json" | jq -r ".[$i].mergeable" 2>/dev/null)
		pr_review=$(printf '%s' "$pr_json" | jq -r ".[$i].reviewDecision // \"NONE\"" 2>/dev/null)
		pr_author=$(printf '%s' "$pr_json" | jq -r ".[$i].author.login // \"unknown\"" 2>/dev/null)
		pr_title=$(printf '%s' "$pr_json" | jq -r ".[$i].title // \"\"" 2>/dev/null)
		i=$((i + 1))

		[[ "$pr_number" =~ ^[0-9]+$ ]] || continue

		# Close conflicting PRs — they can never be merged and block the queue
		if [[ "$pr_mergeable" == "CONFLICTING" && "$PULSE_MERGE_CLOSE_CONFLICTING" == "true" ]]; then
			_close_conflicting_pr "$pr_number" "$repo_slug" "$pr_title"
			closed=$((closed + 1))
			continue
		fi

		# Skip non-mergeable
		if [[ "$pr_mergeable" != "MERGEABLE" ]]; then
			continue
		fi

		# Skip CHANGES_REQUESTED — needs a fix worker, not a merge
		if [[ "$pr_review" == "CHANGES_REQUESTED" ]]; then
			continue
		fi

		# Skip external contributor PRs (non-collaborator)
		if ! _is_collaborator_author "$pr_author" "$repo_slug"; then
			continue
		fi

		# Skip PRs modifying workflow files when we lack the scope
		if check_pr_modifies_workflows "$pr_number" "$repo_slug" 2>/dev/null; then
			if ! check_gh_workflow_scope 2>/dev/null; then
				continue
			fi
		fi

		# Check maintainer-gate: skip if linked issue has needs-maintainer-review
		local linked_issue
		linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
		if [[ -n "$linked_issue" ]]; then
			local issue_labels
			issue_labels=$(gh api "repos/${repo_slug}/issues/${linked_issue}" \
				--jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
			if [[ "$issue_labels" == *"needs-maintainer-review"* ]]; then
				continue
			fi
		fi

		# ── Review bot gate (GH#17490) ──
		# The deterministic merge pass uses --admin which bypasses branch
		# protection (including the review-bot-gate required status check).
		# Enforce the gate in code so PRs cannot be merged without bot review.
		local rbg_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/review-bot-gate-helper.sh"
		if [[ -f "$rbg_helper" ]]; then
			local rbg_result=""
			rbg_result=$(bash "$rbg_helper" check "$pr_number" "$repo_slug" 2>/dev/null) || rbg_result=""
			local rbg_status=""
			rbg_status=$(printf '%s' "$rbg_result" | grep -oE '^(PASS|SKIP|WAITING|PASS_RATE_LIMITED)' | head -1)
			case "$rbg_status" in
			PASS | SKIP | PASS_RATE_LIMITED)
				echo "[pulse-wrapper] Review bot gate: ${rbg_status} for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
				;;
			*)
				echo "[pulse-wrapper] Review bot gate: ${rbg_status:-UNKNOWN} for PR #${pr_number} in ${repo_slug} — skipping merge" >>"$LOGFILE"
				continue
				;;
			esac
		fi

		# Approve (satisfies REVIEW_REQUIRED for collaborator PRs)
		approve_collaborator_pr "$pr_number" "$repo_slug" "$pr_author" 2>/dev/null || true

		# Extract merge summary for closing comments. Tries (in order):
		# 1. Worker's <!-- MERGE_SUMMARY --> tagged comment (richest, ~35% hit rate)
		# 2. PR body text (always present, created atomically with gh pr create)
		# Fallback to generic only if both are empty (should be near-zero).
		local merge_summary
		merge_summary=$(_extract_merge_summary "$pr_number" "$repo_slug")

		# Merge
		local merge_output
		merge_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --squash --admin 2>&1)
		if [[ $? -eq 0 ]]; then
			merged=$((merged + 1))
			echo "[pulse-wrapper] Deterministic merge: merged PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"

			# Build closing comment — use worker summary if available, fall back to generic
			local closing_comment
			if [[ -n "$merge_summary" ]]; then
				closing_comment="${merge_summary}

---
Merged via PR #${pr_number} to main.
_Merged by deterministic merge pass (pulse-wrapper.sh)._"
			else
				closing_comment="Completed via PR #${pr_number}, merged to main.

_Merged by deterministic merge pass (pulse-wrapper.sh). Neither MERGE_SUMMARY comment nor PR body text was available._"
			fi

			# Append signature footer to closing comment (GH#15486).
			# The merge pass is not an LLM session, so use --no-session.
			# Pass --issue for total-time and cumulative token tracking.
			local _merge_sig_footer="" _merge_elapsed=""
			_merge_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
			local _merge_issue_ref=""
			if [[ -n "$linked_issue" ]]; then
				_merge_issue_ref="${repo_slug}#${linked_issue}"
			fi
			_merge_sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
				--body "$closing_comment" --no-session --tokens 0 \
				--time "$_merge_elapsed" --session-type routine \
				${_merge_issue_ref:+--issue "$_merge_issue_ref"} --solved 2>/dev/null || true)
			closing_comment="${closing_comment}${_merge_sig_footer}"

			# Post closing comment on PR
			gh pr comment "$pr_number" --repo "$repo_slug" \
				--body "$closing_comment" 2>/dev/null || true

			# Close linked issue with the same context
			if [[ -n "$linked_issue" ]]; then
				gh issue comment "$linked_issue" --repo "$repo_slug" \
					--body "$closing_comment" 2>/dev/null || true
				gh issue close "$linked_issue" --repo "$repo_slug" 2>/dev/null || true
				# Reset fast-fail counter now that the issue is resolved (GH#2076)
				fast_fail_reset "$linked_issue" "$repo_slug" || true
			fi
		else
			failed=$((failed + 1))
			echo "[pulse-wrapper] Deterministic merge: FAILED PR #${pr_number} in ${repo_slug}: ${merge_output}" >>"$LOGFILE"
		fi

		# Rate-limit: 1 second between merges to avoid GitHub API abuse
		sleep 1
	done

	eval "${_merged_var}=${merged}; ${_closed_var}=${closed}; ${_failed_var}=${failed}"
	return 0
}

#######################################
# Check if a PR author is a collaborator (admin/maintain/write).
# Args: $1=author login, $2=repo slug
# Returns: 0=collaborator, 1=not collaborator or error
#######################################
_is_collaborator_author() {
	local author="$1"
	local repo_slug="$2"
	local perm_response
	perm_response=$(gh api -i "repos/${repo_slug}/collaborators/${author}/permission" 2>/dev/null | head -1)
	if [[ "$perm_response" == *"200"* ]]; then
		local perm
		perm=$(gh api "repos/${repo_slug}/collaborators/${author}/permission" --jq '.permission' 2>/dev/null)
		case "$perm" in
		admin | maintain | write) return 0 ;;
		esac
	fi
	return 1
}

#######################################
# Extract linked issue number from PR title or body.
# Looks for: "Closes #NNN", "Fixes #NNN", "GH#NNN:" prefix in title.
# Args: $1=PR number, $2=repo slug
# Returns: issue number on stdout, or empty if none found
#######################################
_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_data
	pr_data=$(gh pr view "$pr_number" --repo "$repo_slug" --json title,body --jq '.title + " " + .body' 2>/dev/null) || pr_data=""

	# Match: Closes #NNN, Fixes #NNN, Resolves #NNN
	local issue_num
	issue_num=$(printf '%s' "$pr_data" | grep -oE '(Closes|Fixes|Resolves)\s+#[0-9]+' | head -1 | grep -oE '[0-9]+')
	if [[ -n "$issue_num" ]]; then
		printf '%s' "$issue_num"
		return 0
	fi

	# Match: GH#NNN: in title
	issue_num=$(printf '%s' "$pr_data" | grep -oE 'GH#[0-9]+' | head -1 | grep -oE '[0-9]+')
	if [[ -n "$issue_num" ]]; then
		printf '%s' "$issue_num"
		return 0
	fi

	return 0
}

#######################################
# Extract the worker's merge summary from PR comments.
#
# Workers post a structured comment tagged with <!-- MERGE_SUMMARY -->
# on the PR at creation time (full-loop.md step 4.2.1). This function
# finds the most recent such comment and returns its body (without the
# HTML tag) for use in closing comments.
#
# Args: $1=PR number, $2=repo slug
# Output: merge summary text on stdout (empty if none found)
#######################################
_extract_merge_summary() {
	local pr_number="$1"
	local repo_slug="$2"

	# Strategy 1: Look for explicit MERGE_SUMMARY tagged comment (richest content)
	local summary
	summary=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | last | .body // empty' \
		2>/dev/null) || summary=""

	if [[ -n "$summary" ]]; then
		# Strip the HTML marker tag
		summary=$(printf '%s' "$summary" | sed 's/<!-- MERGE_SUMMARY -->//')
		# Strip the worker's "written at PR creation time" note if present
		summary=$(printf '%s' "$summary" | sed '/written by the worker at PR creation time/d')
		printf '%s' "$summary"
		return 0
	fi

	# Strategy 2: Extract from PR body (always present, created atomically with PR).
	# Workers skip the MERGE_SUMMARY comment ~65% of the time, but the PR body
	# always contains a useful description of what was done (GH#17503).
	local pr_body
	pr_body=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json body --jq '.body // empty' 2>/dev/null) || pr_body=""

	if [[ -z "$pr_body" ]]; then
		return 0
	fi

	# Strip auto-generated bot content (CodeRabbit, SonarCloud, Codacy, etc.)
	# These start with <!-- This is an auto-generated comment or similar markers
	pr_body=$(printf '%s\n' "$pr_body" | sed '/<!-- This is an auto-generated comment/,$d')

	# Strip Closes/Fixes/Resolves #NNN (the closing comment adds its own PR reference)
	pr_body=$(printf '%s\n' "$pr_body" | sed -E 's/(Closes|Fixes|Resolves) #[0-9]+[[:space:]]*//')

	# Trim leading/trailing blank lines (BSD sed compatible)
	pr_body=$(printf '%s\n' "$pr_body" | sed '/./,$!d' | sed -E '/^[[:space:]]*$/{ N; }' | sed -E '/^[[:space:]]*$/d')

	# Only use if there's meaningful content left (more than just whitespace)
	if [[ -n "$pr_body" ]] && [[ "$(printf '%s' "$pr_body" | tr -d '[:space:]')" != "" ]]; then
		printf '%s' "$pr_body"
	fi

	return 0
}

#######################################
# Close a conflicting PR with audit comment.
#
# GH#17574: Before saying "remains open for re-attempt", check if the
# work has already landed on main (via the linked issue's task ID in
# recent commits). If yes, close the linked issue too and say so —
# the misleading "remains open for re-attempt" comment was itself a
# dispatch trigger that caused a third redundant worker in the
# observed incident.
#
# Args: $1=PR number, $2=repo slug, $3=PR title
#######################################
_close_conflicting_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title="$3"

	# GH#17574: Check if the work is already on the default branch.
	# Extract task ID from PR title (e.g., "t153: add dark mode" → "t153")
	# and search recent commits on the default branch.
	local work_on_main="false"
	local task_id_from_pr
	task_id_from_pr=$(printf '%s' "$pr_title" | grep -oE '^(t[0-9]+|GH#[0-9]+)' | head -1) || task_id_from_pr=""

	if [[ -n "$task_id_from_pr" ]]; then
		# Search commits on the default branch via GitHub API
		local commit_match
		commit_match=$(gh api "repos/${repo_slug}/commits" \
			--method GET -f sha=main -f per_page=50 \
			--jq "[.[] | select(.commit.message | test(\"(?i)${task_id_from_pr}\"))] | length" \
			2>/dev/null) || commit_match="0"
		if [[ "$commit_match" =~ ^[0-9]+$ ]] && [[ "$commit_match" -gt 0 ]]; then
			work_on_main="true"
		fi
	fi

	if [[ "$work_on_main" == "true" ]]; then
		# Work is already on main — close PR with accurate message
		gh pr close "$pr_number" --repo "$repo_slug" \
			--comment "Closing — this PR has merge conflicts with the base branch. The work for this task (\`${task_id_from_pr}\`) has already been committed directly to main, so no re-attempt is needed.

_Closed by deterministic merge pass (pulse-wrapper.sh, GH#17574)._" 2>/dev/null || true

		# GH#17642: Do NOT auto-close the linked issue. Closing a conflicting
		# PR is safe (PRs are cheap), but closing the ISSUE based on a commit
		# search has too many false positives. The issue stays open for
		# re-dispatch with a fresh branch. Only the verified merge-pass
		# (which checks for an actually-merged PR) should close issues.
		echo "[pulse-wrapper] Deterministic merge: conflicting PR #${pr_number} closed, linked issue left open for re-dispatch (GH#17642)" >>"$LOGFILE"

		echo "[pulse-wrapper] Deterministic merge: closed conflicting PR #${pr_number} in ${repo_slug}: ${pr_title} (work already on main)" >>"$LOGFILE"
	else
		# Work NOT on main — use standard message but without the misleading
		# "remains open for re-attempt" phrasing (GH#17574)
		gh pr close "$pr_number" --repo "$repo_slug" \
			--comment "Closing — this PR has merge conflicts with the base branch. If the linked issue is still open, a worker will be dispatched to re-attempt with a fresh branch.

_Closed by deterministic merge pass (pulse-wrapper.sh)._" 2>/dev/null || true

		echo "[pulse-wrapper] Deterministic merge: closed conflicting PR #${pr_number} in ${repo_slug}: ${pr_title}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Decide whether to invoke the LLM supervisor this cycle.
#
# Returns 0 (true = run LLM) when:
#   - Last LLM run was >24h ago (daily sweep)
#   - Backlog is stalled: issue+PR count unchanged for 30+ min
#   - No backlog snapshot exists yet (first run)
#
# Returns 1 (false = skip LLM) when:
#   - Backlog is progressing (counts are decreasing)
#   - Daily sweep not yet due
#
# Side effect: writes the trigger mode to ${PULSE_DIR}/llm_trigger_mode
#   Values: "daily_sweep" | "stall" | "first_run"
#   Callers read this file to select the correct agent prompt
#   (pulse-sweep.md for daily_sweep, pulse.md for stall/first_run).
#
# State files:
#   ${PULSE_DIR}/last_llm_run_epoch     — epoch of last LLM invocation
#   ${PULSE_DIR}/backlog_snapshot.txt    — "epoch issues_count prs_count"
#   ${PULSE_DIR}/llm_trigger_mode        — last trigger reason (daily_sweep|stall|first_run)
#######################################
PULSE_LLM_STALL_THRESHOLD="${PULSE_LLM_STALL_THRESHOLD:-$(config_get "orchestration.llm_stall_threshold" "3600")}" # 1h (was 30 min; deterministic fill floor handles routine dispatch)
PULSE_LLM_DAILY_INTERVAL="${PULSE_LLM_DAILY_INTERVAL:-86400}"                                                      # 24h

_should_run_llm_supervisor() {
	local now_epoch
	now_epoch=$(date +%s)

	# 1. Daily sweep: always run if last LLM was >24h ago
	local last_llm_epoch=0
	if [[ -f "${PULSE_DIR}/last_llm_run_epoch" ]]; then
		last_llm_epoch=$(cat "${PULSE_DIR}/last_llm_run_epoch" 2>/dev/null) || last_llm_epoch=0
	fi
	[[ "$last_llm_epoch" =~ ^[0-9]+$ ]] || last_llm_epoch=0

	local llm_age=$((now_epoch - last_llm_epoch))
	if [[ "$llm_age" -ge "$PULSE_LLM_DAILY_INTERVAL" ]]; then
		echo "[pulse-wrapper] LLM supervisor: daily sweep due (last run ${llm_age}s ago)" >>"$LOGFILE"
		printf 'daily_sweep\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	# 2. Backlog stall: check if issue+PR count has changed
	local snapshot_file="${PULSE_DIR}/backlog_snapshot.txt"
	if [[ ! -f "$snapshot_file" ]]; then
		# First run — take snapshot and run LLM
		_update_backlog_snapshot "$now_epoch"
		echo "[pulse-wrapper] LLM supervisor: first run (no snapshot)" >>"$LOGFILE"
		printf 'first_run\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	local snap_epoch snap_issues snap_prs
	read -r snap_epoch snap_issues snap_prs <"$snapshot_file" 2>/dev/null || snap_epoch=0
	[[ "$snap_epoch" =~ ^[0-9]+$ ]] || snap_epoch=0
	[[ "$snap_issues" =~ ^[0-9]+$ ]] || snap_issues=0
	[[ "$snap_prs" =~ ^[0-9]+$ ]] || snap_prs=0

	# Get current counts (fast — single API call per repo, cached in prefetch)
	# t1890: exclude persistent/supervisor/contributor issues from stall detection.
	# These management issues never close, so including them inflates the count
	# and makes the backlog appear stalled even when all actionable work is done.
	local current_issues=0 current_prs=0
	while IFS='|' read -r slug _; do
		[[ -n "$slug" ]] || continue
		local ic pc
		ic=$(gh issue list --repo "$slug" --state open --json number,labels --limit 500 \
			--jq '[.[] | select(.labels | map(.name) | (index("persistent")) | not)] | length' 2>/dev/null) || ic=0
		pc=$(gh pr list --repo "$slug" --state open --json number --jq 'length' --limit 200 2>/dev/null) || pc=0
		[[ "$ic" =~ ^[0-9]+$ ]] || ic=0
		[[ "$pc" =~ ^[0-9]+$ ]] || pc=0
		current_issues=$((current_issues + ic))
		current_prs=$((current_prs + pc))
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$REPOS_JSON" 2>/dev/null)

	local snap_age=$((now_epoch - snap_epoch))
	local total_before=$((snap_issues + snap_prs))
	local total_now=$((current_issues + current_prs))

	# Backlog is progressing — update snapshot, skip LLM
	if [[ "$total_now" -lt "$total_before" ]]; then
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		return 1
	fi

	# Backlog unchanged — check if stalled long enough
	if [[ "$snap_age" -ge "$PULSE_LLM_STALL_THRESHOLD" ]]; then
		echo "[pulse-wrapper] LLM supervisor: backlog stalled for ${snap_age}s (issues=${current_issues} prs=${current_prs}, unchanged from ${snap_issues}+${snap_prs})" >>"$LOGFILE"
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		printf 'stall\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	# Stalled but not long enough yet
	return 1
}

_update_backlog_snapshot() {
	local epoch="${1:-$(date +%s)}"
	local issues="${2:-0}"
	local prs="${3:-0}"
	printf '%s %s %s\n' "$epoch" "$issues" "$prs" >"${PULSE_DIR}/backlog_snapshot.txt"
	return 0
}

#######################################
# Compute and apply an adaptive launch-settle wait (t1887).
#
# Scales the wait from 0s (0 dispatches) to PULSE_LAUNCH_GRACE_SECONDS
# (PULSE_LAUNCH_SETTLE_BATCH_MAX or more dispatches) using linear
# interpolation. This avoids the static 35s wait when no workers were
# launched, saving ~35s per idle cycle.
#
# Formula: wait = ceil(dispatched / batch_max * grace_max)
# Examples (grace_max=35, batch_max=5):
#   0 dispatches → 0s
#   1 dispatch   → 7s
#   2 dispatches → 14s
#   3 dispatches → 21s
#   4 dispatches → 28s
#   5+ dispatches → 35s
#
# Arguments:
#   $1 - dispatched_count (integer, number of workers just launched)
#   $2 - context label for log (e.g. "fill floor", "recycle loop")
#######################################
_adaptive_launch_settle_wait() {
	local dispatched_count="${1:-0}"
	local context_label="${2:-dispatch}"

	[[ "$dispatched_count" =~ ^[0-9]+$ ]] || dispatched_count=0
	if [[ "$dispatched_count" -eq 0 ]]; then
		echo "[pulse-wrapper] Adaptive settle wait (${context_label}): 0 dispatches — skipping wait" >>"$LOGFILE"
		return 0
	fi

	local grace_max="$PULSE_LAUNCH_GRACE_SECONDS"
	local batch_max="$PULSE_LAUNCH_SETTLE_BATCH_MAX"
	[[ "$grace_max" =~ ^[0-9]+$ ]] || grace_max=35
	[[ "$batch_max" =~ ^[0-9]+$ ]] || batch_max=5
	[[ "$batch_max" -lt 1 ]] && batch_max=1

	# Clamp dispatched_count to batch_max ceiling
	local clamped="$dispatched_count"
	if [[ "$clamped" -gt "$batch_max" ]]; then
		clamped="$batch_max"
	fi

	# Linear interpolation: ceil(clamped / batch_max * grace_max)
	# Integer arithmetic: (clamped * grace_max + batch_max - 1) / batch_max
	local wait_seconds=$(((clamped * grace_max + batch_max - 1) / batch_max))
	[[ "$wait_seconds" -gt "$grace_max" ]] && wait_seconds="$grace_max"

	echo "[pulse-wrapper] Adaptive settle wait (${context_label}): ${dispatched_count} dispatch(es) → waiting ${wait_seconds}s (max ${grace_max}s at ${batch_max}+ dispatches)" >>"$LOGFILE"
	sleep "$wait_seconds"
	return 0
}

#
# Dispatches deterministic fill floor, then waits adaptively based on
# how many workers were launched so they can appear in process lists
# before the next worker count.
#######################################
apply_deterministic_fill_floor() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: stop flag present" >>"$LOGFILE"
		return 0
	fi

	local fill_dispatched
	fill_dispatched=$(dispatch_deterministic_fill_floor) || fill_dispatched=0
	[[ "$fill_dispatched" =~ ^[0-9]+$ ]] || fill_dispatched=0

	_adaptive_launch_settle_wait "$fill_dispatched" "fill floor"
	return 0
}

#######################################
# Enforce utilization invariants post-pulse (DEPRECATED — t1453)
#
# The LLM pulse session now runs a monitoring loop (sleep 60s, check
# slots, backfill) for up to 60 minutes, making this wrapper-level
# backfill loop redundant. The function is kept as a no-op stub for
# backward compatibility (pulse.md sources this file).
#
# Previously: re-launched run_pulse() in a loop until active workers
# >= MAX_WORKERS or no runnable work remained. Each iteration paid
# the full LLM cold-start penalty (~125s). The monitoring loop inside
# the LLM session eliminates this overhead — each backfill iteration
# costs ~3K tokens instead of a full session restart.
#######################################
enforce_utilization_invariants() {
	echo "[pulse-wrapper] enforce_utilization_invariants is deprecated — LLM session handles continuous slot filling" >>"$LOGFILE"
	return 0
}

#######################################
# Recycle stale workers aggressively when underfill is severe
#
# During deep underfill, long-running workers can occupy slots while making
# no mergeable progress. Run worker-watchdog with stricter thresholds so
# stale workers are recycled before the next pulse dispatch attempt.
#
# Throttle (t1885): when runnable+queued candidates are scarce
# (<= UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD) and underfill is not severe
# (< UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT), skip the watchdog run if it was
# called within UNDERFILL_RECYCLE_THROTTLE_SECS (default 5 min). This avoids
# repeated no-op watchdog scans when there is little work to dispatch.
# Severe underfill (>= 75% deficit) always bypasses the throttle.
#
# Arguments:
#   $1 - max workers
#   $2 - active workers
#   $3 - runnable candidate count
#   $4 - queued_without_worker count
#######################################
run_underfill_worker_recycler() {
	local max_workers="$1"
	local active_workers="$2"
	local runnable_count="$3"
	local queued_without_worker="$4"

	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$runnable_count" =~ ^[0-9]+$ ]] || runnable_count=0
	[[ "$queued_without_worker" =~ ^[0-9]+$ ]] || queued_without_worker=0

	if [[ "$active_workers" -ge "$max_workers" ]]; then
		return 0
	fi

	if [[ "$runnable_count" -eq 0 && "$queued_without_worker" -eq 0 ]]; then
		return 0
	fi

	if [[ ! -x "$WORKER_WATCHDOG_HELPER" ]]; then
		echo "[pulse-wrapper] Underfill recycler skipped: worker-watchdog helper missing or not executable (${WORKER_WATCHDOG_HELPER})" >>"$LOGFILE"
		return 0
	fi

	local deficit_pct
	deficit_pct=$(((max_workers - active_workers) * 100 / max_workers))
	if [[ "$deficit_pct" -lt "$UNDERFILL_RECYCLE_DEFICIT_MIN_PCT" ]]; then
		return 0
	fi

	# Time-based throttle (t1885): when runnable candidates are scarce and underfill
	# is not severe, avoid hammering worker-watchdog on every pulse cycle. Running
	# watchdog with few candidates produces no kills but still pays the process-scan
	# cost and generates noisy log entries. Bypass throttle for severe underfill
	# (>= UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT) so critical slot recovery is never delayed.
	local recycle_throttle_file="${HOME}/.aidevops/logs/underfill-recycle-last-run"
	local total_candidates=$((runnable_count + queued_without_worker))
	if [[ "$total_candidates" -le "$UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD" &&
		"$deficit_pct" -lt "$UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT" ]]; then
		local now_epoch
		now_epoch=$(date +%s)
		local last_run_epoch=0
		if [[ -f "$recycle_throttle_file" ]]; then
			last_run_epoch=$(cat "$recycle_throttle_file" 2>/dev/null || echo "0")
			[[ "$last_run_epoch" =~ ^[0-9]+$ ]] || last_run_epoch=0
		fi
		local secs_since_last=$((now_epoch - last_run_epoch))
		if [[ "$secs_since_last" -lt "$UNDERFILL_RECYCLE_THROTTLE_SECS" ]]; then
			echo "[pulse-wrapper] Underfill recycler throttled: candidates=${total_candidates} (threshold=${UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD}), deficit=${deficit_pct}% (<${UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT}% severe), last_run=${secs_since_last}s ago (throttle=${UNDERFILL_RECYCLE_THROTTLE_SECS}s)" >>"$LOGFILE"
			return 0
		fi
	fi

	local thrash_elapsed_threshold
	local thrash_message_threshold
	local progress_timeout
	local max_runtime
	if [[ "$deficit_pct" -ge 50 ]]; then
		thrash_elapsed_threshold=1800
		thrash_message_threshold=90
		progress_timeout=420
		max_runtime=7200
	else
		thrash_elapsed_threshold=3600
		thrash_message_threshold=120
		progress_timeout=480
		max_runtime=9000
	fi

	echo "[pulse-wrapper] Underfill recycler: running worker-watchdog (active ${active_workers}/${max_workers}, deficit ${deficit_pct}%, runnable=${runnable_count}, queued_without_worker=${queued_without_worker})" >>"$LOGFILE"

	if WORKER_WATCHDOG_NOTIFY=false \
		WORKER_THRASH_ELAPSED_THRESHOLD="$thrash_elapsed_threshold" \
		WORKER_THRASH_MESSAGE_THRESHOLD="$thrash_message_threshold" \
		WORKER_PROGRESS_TIMEOUT="$progress_timeout" \
		WORKER_MAX_RUNTIME="$max_runtime" \
		"$WORKER_WATCHDOG_HELPER" --check >>"$LOGFILE" 2>&1; then
		echo "[pulse-wrapper] Underfill recycler complete: worker-watchdog check finished" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Underfill recycler warning: worker-watchdog returned non-zero" >>"$LOGFILE"
	fi

	# Update throttle timestamp after each run (t1885)
	date +%s >"$recycle_throttle_file" 2>/dev/null || true

	return 0
}

#######################################
# Refill an underfilled worker pool while the pulse session is still alive.
#
# The pulse prompt asks the LLM to monitor every 60s, but the live session can
# still sleep or focus on a narrow thread while local slots sit idle. When the
# wrapper sees sustained idle/stall signals plus runnable work, it performs a
# bounded deterministic refill instead of waiting for the session to exit.
#
# Arguments:
#   $1 - last refill epoch (0 if never)
#   $2 - progress stall seconds
#   $3 - idle seconds
#   $4 - has_seen_progress (true/false)
#
# Returns: updated last refill epoch via stdout
#######################################
maybe_refill_underfilled_pool_during_active_pulse() {
	local last_refill_epoch="${1:-0}"
	local progress_stall_seconds="${2:-0}"
	local idle_seconds="${3:-0}"
	local has_seen_progress="${4:-false}"

	[[ "$last_refill_epoch" =~ ^[0-9]+$ ]] || last_refill_epoch=0
	[[ "$progress_stall_seconds" =~ ^[0-9]+$ ]] || progress_stall_seconds=0
	[[ "$idle_seconds" =~ ^[0-9]+$ ]] || idle_seconds=0
	[[ "$PULSE_ACTIVE_REFILL_INTERVAL" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_INTERVAL=120
	[[ "$PULSE_ACTIVE_REFILL_IDLE_MIN" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_IDLE_MIN=60
	[[ "$PULSE_ACTIVE_REFILL_STALL_MIN" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_STALL_MIN=120

	if [[ -f "$STOP_FLAG" || "$has_seen_progress" != "true" ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	if [[ "$idle_seconds" -lt "$PULSE_ACTIVE_REFILL_IDLE_MIN" && "$progress_stall_seconds" -lt "$PULSE_ACTIVE_REFILL_STALL_MIN" ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)
	if [[ "$last_refill_epoch" -gt 0 ]]; then
		local since_last_refill=$((now_epoch - last_refill_epoch))
		if [[ "$since_last_refill" -lt "$PULSE_ACTIVE_REFILL_INTERVAL" ]]; then
			echo "$last_refill_epoch"
			return 0
		fi
	fi

	local max_workers active_workers runnable_count queued_without_worker
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

	if [[ "$active_workers" -ge "$max_workers" || ("$runnable_count" -eq 0 && "$queued_without_worker" -eq 0) ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	echo "[pulse-wrapper] Active pulse refill: underfilled ${active_workers}/${max_workers} with runnable=${runnable_count}, queued_without_worker=${queued_without_worker}, idle=${idle_seconds}s, stall=${progress_stall_seconds}s" >>"$LOGFILE"
	run_underfill_worker_recycler "$max_workers" "$active_workers" "$runnable_count" "$queued_without_worker"
	dispatch_deterministic_fill_floor >/dev/null || true

	echo "$now_epoch"
	return 0
}

#######################################
# Main
#
# Execution order (t1429, GH#4513, GH#5628):
#   0. Instance lock (mkdir-based atomic — prevents concurrent pulses on macOS+Linux)
#   1. Gate checks (consent, dedup)
#   2. Cleanup (orphans, worktrees, stashes)
#   2.5. Daily complexity scan — .sh functions + .md agent docs (creates simplification-debt issues)
#   3. Prefetch state (parallel gh API calls)
#   4. Run pulse (LLM session — dispatch workers, merge PRs)
#
# Statistics (quality sweep, health issues, person-stats) run in a
# SEPARATE process — stats-wrapper.sh — on its own cron schedule.
# They must never share a process with the pulse because they depend
# on GitHub Search API (30 req/min limit). When budget is exhausted,
# contributor-activity-helper.sh bails out with partial results, but
# even the API calls themselves add latency that delays dispatch.
#######################################
#######################################
# Run pre-flight stages: cleanup, calculations, normalization (GH#5627)
#
# Returns: 0 if prefetch succeeded, 1 if prefetch failed (abort cycle)
#######################################
_run_preflight_stages() {
	# t1425, t1482: Write SETUP sentinel during pre-flight stages.
	echo "SETUP:$$" >"$PIDFILE"

	run_stage_with_timeout "cleanup_orphans" "$PRE_RUN_STAGE_TIMEOUT" cleanup_orphans || true
	run_stage_with_timeout "cleanup_stale_opencode" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stale_opencode || true
	run_stage_with_timeout "cleanup_stalled_workers" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stalled_workers || true
	run_stage_with_timeout "cleanup_worktrees" "$PRE_RUN_STAGE_TIMEOUT" cleanup_worktrees || true
	run_stage_with_timeout "cleanup_stashes" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stashes || true

	# GH#17549: Archive old OpenCode sessions to keep the active DB small.
	# Concurrent workers hit SQLITE_BUSY on a bloated DB (busy_timeout=0).
	# Runs daily with a 30s budget — catches up over multiple pulse cycles.
	local _archive_helper="${SCRIPT_DIR}/opencode-db-archive.sh"
	if [[ -x "$_archive_helper" ]]; then
		"$_archive_helper" archive --max-duration-seconds 30 >>"$LOGFILE" 2>&1 || true
	fi

	# t1751: Reap zombie workers whose PRs have been merged by the deterministic merge pass.
	# Runs before worker counting so count_active_workers sees accurate slot availability.
	run_stage_with_timeout "reap_zombie_workers" "$PRE_RUN_STAGE_TIMEOUT" reap_zombie_workers || true

	# GH#6696: Expire stale in-flight ledger entries and prune old completed/failed ones.
	# This runs before worker counting so count_active_workers sees accurate ledger state.
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local expired_count
		expired_count=$("$_ledger_helper" expire 2>/dev/null) || expired_count=0
		"$_ledger_helper" prune >/dev/null 2>&1 || true
		if [[ "${expired_count:-0}" -gt 0 ]]; then
			echo "[pulse-wrapper] Dispatch ledger: expired ${expired_count} stale in-flight entries (GH#6696)" >>"$LOGFILE"
		fi
	fi

	calculate_max_workers
	calculate_priority_allocations
	local _session_ct
	_session_ct=$(check_session_count)
	if [[ "${_session_ct:-0}" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "[pulse-wrapper] Session warning: $_session_ct interactive sessions open (threshold: $SESSION_COUNT_WARN). Each consumes 100-440MB + language servers. Consider closing unused tabs." >>"$LOGFILE"
	fi

	# Daily complexity scan (GH#5628): creates simplification-debt issues
	# for .sh files with complex functions and .md agent docs exceeding size
	# threshold. Longest files first. Runs at most once per day.
	# Non-fatal — pulse proceeds even if the scan fails.
	run_stage_with_timeout "complexity_scan" "$PRE_RUN_STAGE_TIMEOUT" run_weekly_complexity_scan || true

	# Daily full codebase review via CodeRabbit (GH#17640): posts a review
	# trigger on issue #2632 once per 24h. Uses simple timestamp gate.
	# Non-fatal — pulse proceeds even if the review request fails.
	run_stage_with_timeout "coderabbit_review" "$PRE_RUN_STAGE_TIMEOUT" run_daily_codebase_review || true

	# Daily dedup cleanup: close duplicate simplification-debt issues.
	# Runs after complexity scan so any new duplicates from this cycle are caught.
	# Non-fatal — pulse proceeds even if cleanup fails.
	run_stage_with_timeout "dedup_cleanup" "$PRE_RUN_STAGE_TIMEOUT" run_simplification_dedup_cleanup || true

	# Prune expired fast-fail counter entries (t1888).
	# Lightweight — just reads and rewrites a small JSON file.
	fast_fail_prune_expired || true

	# Contribution watch: lightweight scan of external issues/PRs (t1419).
	prefetch_contribution_watch

	# Ensure active labels reflect ownership to prevent multi-worker overlap.
	run_stage_with_timeout "normalize_active_issue_assignments" "$PRE_RUN_STAGE_TIMEOUT" normalize_active_issue_assignments || true

	# Close issues whose linked PRs already merged (GH#16851).
	# The dedup guard blocks re-dispatch for these but they stay open forever.
	run_stage_with_timeout "close_issues_with_merged_prs" "$PRE_RUN_STAGE_TIMEOUT" close_issues_with_merged_prs || true

	# Reconcile status:done issues: close if merged PR exists, reset to
	# status:available if not (needs re-evaluation by a worker).
	run_stage_with_timeout "reconcile_stale_done_issues" "$PRE_RUN_STAGE_TIMEOUT" reconcile_stale_done_issues || true

	# Auto-approve maintainer issues: remove needs-maintainer-review when
	# the maintainer created or commented on the issue (GH#16842).
	run_stage_with_timeout "auto_approve_maintainer_issues" "$PRE_RUN_STAGE_TIMEOUT" auto_approve_maintainer_issues || true

	if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
		echo "[pulse-wrapper] prefetch_state did not complete successfully — aborting this cycle to avoid stale dispatch decisions" >>"$LOGFILE"
		_PULSE_HEALTH_PREFETCH_ERRORS=$((_PULSE_HEALTH_PREFETCH_ERRORS + 1))
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 1
	fi

	if [[ -f "$SCOPE_FILE" ]]; then
		local persisted_scope
		persisted_scope=$(cat "$SCOPE_FILE" 2>/dev/null || echo "")
		if [[ -n "$persisted_scope" ]]; then
			export PULSE_SCOPE_REPOS="$persisted_scope"
			echo "[pulse-wrapper] Restored PULSE_SCOPE_REPOS from ${SCOPE_FILE}" >>"$LOGFILE"
		fi
	fi

	return 0
}

#######################################
# Compute initial underfill state and run recycler (GH#5627)
#
# Outputs 2 lines: underfilled_mode, underfill_pct
#######################################
_compute_initial_underfill() {
	local max_workers active_workers underfilled_mode underfill_pct

	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	underfilled_mode=0
	underfill_pct=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		underfilled_mode=1
		underfill_pct=$(((max_workers - active_workers) * 100 / max_workers))
	fi

	local runnable_count queued_without_worker
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	run_underfill_worker_recycler "$max_workers" "$active_workers" "$runnable_count" "$queued_without_worker"

	# Re-check after recycler
	active_workers=$(count_active_workers)
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		underfilled_mode=1
		underfill_pct=$(((max_workers - active_workers) * 100 / max_workers))
	else
		underfilled_mode=0
		underfill_pct=0
	fi

	echo "$underfilled_mode"
	echo "$underfill_pct"
	return 0
}

#######################################
# Early-exit recycle loop (GH#5627, extracted from main)
#
# If the LLM exited quickly (<5 min) and the pool is still underfilled
# with runnable work, restart the pulse. Capped at PULSE_BACKFILL_MAX_ATTEMPTS.
#
# GH#6453: A grace-period wait is inserted before re-counting workers.
# Workers dispatched by the LLM pulse take several seconds to appear in
# list_active_worker_processes (sandbox-exec + opencode startup latency).
# Without this wait, count_active_workers() returns the pre-dispatch count,
# making the pool appear underfilled and triggering a second LLM pass that
# re-dispatches the same issues — doubling compute cost and causing branch
# conflicts. The wait duration is PULSE_LAUNCH_GRACE_SECONDS (default 20s).
#
# Arguments:
#   $1 - initial pulse_duration in seconds
#######################################
_run_early_exit_recycle_loop() {
	local pulse_duration="$1"
	local recycle_attempt=0

	while [[ "$recycle_attempt" -lt "$PULSE_BACKFILL_MAX_ATTEMPTS" ]]; do
		# Only recycle if the pulse ran for less than 5 minutes
		if [[ "$pulse_duration" -ge 300 ]]; then
			break
		fi

		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Stop flag set — skipping early-exit recycle" >>"$LOGFILE"
			break
		fi

		# GH#6453: Wait for newly-dispatched workers to appear in the process list
		# before re-counting. Workers dispatched by the LLM pulse take up to
		# PULSE_LAUNCH_GRACE_SECONDS to start (sandbox-exec + opencode startup).
		# Counting immediately after the LLM exits produces a false-negative
		# (workers running but not yet visible) that triggers duplicate dispatch.
		# t1887: LLM dispatch count is unknown here — use full grace to preserve
		# the GH#6453 safety guarantee.
		local grace_wait="$PULSE_LAUNCH_GRACE_SECONDS"
		[[ "$grace_wait" =~ ^[0-9]+$ ]] || grace_wait=35
		if [[ "$grace_wait" -gt 0 ]]; then
			echo "[pulse-wrapper] Early-exit recycle: waiting ${grace_wait}s for dispatched workers to appear (GH#6453)" >>"$LOGFILE"
			sleep "$grace_wait"
		fi

		# Re-check worker state
		local post_max post_active post_runnable post_queued
		post_max=$(get_max_workers_target)
		post_active=$(count_active_workers)
		post_runnable=$(normalize_count_output "$(count_runnable_candidates)")
		post_queued=$(normalize_count_output "$(count_queued_without_worker)")
		[[ "$post_max" =~ ^[0-9]+$ ]] || post_max=1
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0

		if [[ "$post_active" -ge "$post_max" ]]; then
			break
		fi
		if [[ "$post_runnable" -eq 0 && "$post_queued" -eq 0 ]]; then
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Early-exit recycle: stop flag appeared before deterministic fill" >>"$LOGFILE"
			break
		fi

		dispatch_deterministic_fill_floor >/dev/null || true
		post_active=$(count_active_workers)
		post_runnable=$(normalize_count_output "$(count_runnable_candidates)")
		post_queued=$(normalize_count_output "$(count_queued_without_worker)")
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		if [[ "$post_active" -ge "$post_max" ]]; then
			break
		fi
		if [[ "$post_runnable" -eq 0 && "$post_queued" -eq 0 ]]; then
			break
		fi

		local post_deficit_pct=$(((post_max - post_active) * 100 / post_max))
		recycle_attempt=$((recycle_attempt + 1))
		echo "[pulse-wrapper] Early-exit recycle attempt ${recycle_attempt}/${PULSE_BACKFILL_MAX_ATTEMPTS}: pulse ran ${pulse_duration}s (<300s), pool underfilled (active ${post_active}/${post_max}, deficit ${post_deficit_pct}%, runnable=${post_runnable}, queued=${post_queued})" >>"$LOGFILE"

		run_underfill_worker_recycler "$post_max" "$post_active" "$post_runnable" "$post_queued"

		if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
			echo "[pulse-wrapper] Early-exit recycle: prefetch_state failed — aborting recycle" >>"$LOGFILE"
			break
		fi

		# Recalculate underfill for the new pulse
		post_active=$(count_active_workers)
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		local recycle_underfilled_mode=0
		local recycle_underfill_pct=0
		if [[ "$post_active" -lt "$post_max" ]]; then
			recycle_underfilled_mode=1
			recycle_underfill_pct=$(((post_max - post_active) * 100 / post_max))
		fi

		local recycle_start_epoch
		recycle_start_epoch=$(date +%s)
		run_pulse "$recycle_underfilled_mode" "$recycle_underfill_pct"

		local recycle_end_epoch
		recycle_end_epoch=$(date +%s)
		pulse_duration=$((recycle_end_epoch - recycle_start_epoch))
	done

	if [[ "$recycle_attempt" -gt 0 ]]; then
		echo "[pulse-wrapper] Early-exit recycle completed after ${recycle_attempt} attempt(s)" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# rotate_pulse_log — hot/cold log sharding (t1886)
#
# Called once per cycle, before any log writes. If pulse.log exceeds
# PULSE_LOG_HOT_MAX_BYTES, it is gzip-compressed and moved to the cold
# archive directory. The cold archive is then pruned to stay within
# PULSE_LOG_COLD_MAX_BYTES by removing the oldest archives first.
#
# Design constraints:
#   - Atomic: uses a tmp file + mv to avoid partial archives.
#   - Non-fatal: any failure is logged to WRAPPER_LOGFILE and silently
#     ignored so the pulse cycle is never blocked by log housekeeping.
#   - macOS compatible: uses stat -f %z (BSD stat) with fallback to wc -c.
#   - No external deps beyond gzip (standard on macOS and Linux).
#######################################
rotate_pulse_log() {
	# Ensure archive directory exists
	mkdir -p "$PULSE_LOG_ARCHIVE_DIR" 2>/dev/null || {
		echo "[pulse-wrapper] rotate_pulse_log: cannot create archive dir ${PULSE_LOG_ARCHIVE_DIR}" >>"$WRAPPER_LOGFILE"
		return 0
	}

	# Check hot log size — skip if under cap or log doesn't exist
	local hot_size=0
	if [[ -f "$LOGFILE" ]]; then
		hot_size=$(stat -f %z "$LOGFILE" 2>/dev/null || wc -c <"$LOGFILE" 2>/dev/null || echo "0")
		hot_size="${hot_size//[[:space:]]/}"
		[[ "$hot_size" =~ ^[0-9]+$ ]] || hot_size=0
	fi

	if [[ "$hot_size" -lt "$PULSE_LOG_HOT_MAX_BYTES" ]]; then
		return 0
	fi

	# Rotate: compress hot log to archive
	local ts
	ts=$(date -u +%Y%m%d-%H%M%S)
	local archive_name="pulse-${ts}.log.gz"
	local archive_path="${PULSE_LOG_ARCHIVE_DIR}/${archive_name}"
	local tmp_archive
	tmp_archive=$(mktemp "${PULSE_LOG_ARCHIVE_DIR}/.pulse-archive-XXXXXX.gz") || {
		echo "[pulse-wrapper] rotate_pulse_log: mktemp failed for archive" >>"$WRAPPER_LOGFILE"
		return 0
	}

	if gzip -c "$LOGFILE" >"$tmp_archive" 2>/dev/null; then
		mv "$tmp_archive" "$archive_path" 2>/dev/null || {
			rm -f "$tmp_archive"
			echo "[pulse-wrapper] rotate_pulse_log: mv failed for ${archive_name}" >>"$WRAPPER_LOGFILE"
			return 0
		}
		# Truncate hot log (not delete — preserves file descriptor for any
		# concurrent writers that still have it open)
		: >"$LOGFILE" 2>/dev/null || true
		echo "[pulse-wrapper] rotate_pulse_log: rotated ${hot_size}B → ${archive_name}" >>"$WRAPPER_LOGFILE"
	else
		rm -f "$tmp_archive"
		echo "[pulse-wrapper] rotate_pulse_log: gzip failed for ${LOGFILE}" >>"$WRAPPER_LOGFILE"
		return 0
	fi

	# Prune cold archive to stay within PULSE_LOG_COLD_MAX_BYTES
	# Sum archive sizes; remove oldest (lexicographic = chronological) until under cap.
	local total_cold=0
	local archive_file archive_size
	# Build sorted list (oldest first via lexicographic sort on timestamp-named files)
	local -a archive_files=()
	while IFS= read -r archive_file; do
		archive_files+=("$archive_file")
	done < <(ls -1 "${PULSE_LOG_ARCHIVE_DIR}"/pulse-*.log.gz 2>/dev/null | sort)

	for archive_file in "${archive_files[@]}"; do
		archive_size=$(stat -f %z "$archive_file" 2>/dev/null || wc -c <"$archive_file" 2>/dev/null || echo "0")
		archive_size="${archive_size//[[:space:]]/}"
		[[ "$archive_size" =~ ^[0-9]+$ ]] || archive_size=0
		total_cold=$((total_cold + archive_size))
	done

	if [[ "$total_cold" -gt "$PULSE_LOG_COLD_MAX_BYTES" ]]; then
		for archive_file in "${archive_files[@]}"; do
			[[ "$total_cold" -le "$PULSE_LOG_COLD_MAX_BYTES" ]] && break
			archive_size=$(stat -f %z "$archive_file" 2>/dev/null || wc -c <"$archive_file" 2>/dev/null || echo "0")
			archive_size="${archive_size//[[:space:]]/}"
			[[ "$archive_size" =~ ^[0-9]+$ ]] || archive_size=0
			rm -f "$archive_file" && {
				total_cold=$((total_cold - archive_size))
				echo "[pulse-wrapper] rotate_pulse_log: pruned cold archive $(basename "$archive_file") (${archive_size}B)" >>"$WRAPPER_LOGFILE"
			}
		done
	fi

	return 0
}

#######################################
# append_cycle_index — write one JSONL record to the cycle index (t1886)
#
# Called once per cycle after write_pulse_health_file(). Captures the
# per-cycle counters already computed by the health file writer plus
# timing and utilisation data. The index is append-only and capped at
# PULSE_CYCLE_INDEX_MAX_LINES lines; oldest lines are pruned in-place
# using a tmp-file swap when the cap is exceeded.
#
# Fields written per cycle:
#   ts          — ISO-8601 UTC timestamp
#   duration_s  — cycle wall-clock duration in seconds (0 if unknown)
#   workers     — "active/max" string
#   dispatched  — issues dispatched this cycle
#   merged      — PRs merged this cycle
#   closed      — conflicting PRs closed this cycle
#   killed      — stalled workers killed this cycle
#   prefetch_errors — prefetch failures this cycle
#######################################
append_cycle_index() {
	local duration_s="${1:-0}"

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local workers_active workers_max
	workers_active=$(count_active_workers 2>/dev/null || echo "0")
	[[ "$workers_active" =~ ^[0-9]+$ ]] || workers_active=0
	workers_max=$(get_max_workers_target 2>/dev/null || echo "1")
	[[ "$workers_max" =~ ^[0-9]+$ ]] || workers_max=1

	local issues_dispatched=0
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local _ledger_count
		_ledger_count=$("$_ledger_helper" count 2>/dev/null || echo "0")
		[[ "$_ledger_count" =~ ^[0-9]+$ ]] && issues_dispatched="$_ledger_count"
	fi

	# Append record — use printf for portability (no echo -e needed)
	printf '{"ts":"%s","duration_s":%s,"workers":"%s/%s","dispatched":%s,"merged":%s,"closed":%s,"killed":%s,"prefetch_errors":%s}\n' \
		"$ts" \
		"$duration_s" \
		"$workers_active" \
		"$workers_max" \
		"$issues_dispatched" \
		"$_PULSE_HEALTH_PRS_MERGED" \
		"$_PULSE_HEALTH_PRS_CLOSED_CONFLICTING" \
		"$_PULSE_HEALTH_STALLED_KILLED" \
		"$_PULSE_HEALTH_PREFETCH_ERRORS" \
		>>"$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || {
		echo "[pulse-wrapper] append_cycle_index: write failed to ${PULSE_CYCLE_INDEX_FILE}" >>"$WRAPPER_LOGFILE"
		return 0
	}

	# Prune index to PULSE_CYCLE_INDEX_MAX_LINES lines when exceeded
	local line_count
	line_count=$(wc -l <"$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || echo "0")
	line_count="${line_count//[[:space:]]/}"
	[[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0

	if [[ "$line_count" -gt "$PULSE_CYCLE_INDEX_MAX_LINES" ]]; then
		local excess=$((line_count - PULSE_CYCLE_INDEX_MAX_LINES))
		local tmp_index
		tmp_index=$(mktemp "${HOME}/.aidevops/logs/.pulse-cycle-index-XXXXXX.jsonl") || {
			echo "[pulse-wrapper] append_cycle_index: mktemp failed for index prune" >>"$WRAPPER_LOGFILE"
			return 0
		}
		# Keep only the last PULSE_CYCLE_INDEX_MAX_LINES lines
		tail -n "$PULSE_CYCLE_INDEX_MAX_LINES" "$PULSE_CYCLE_INDEX_FILE" >"$tmp_index" 2>/dev/null &&
			mv "$tmp_index" "$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || {
			rm -f "$tmp_index"
			echo "[pulse-wrapper] append_cycle_index: prune failed (excess=${excess})" >>"$WRAPPER_LOGFILE"
		}
	fi

	return 0
}

main() {
	# GH#4513: Acquire exclusive instance lock FIRST — before any other
	# check. Uses mkdir atomicity as the primary primitive (POSIX-guaranteed,
	# works on macOS APFS/HFS+ without util-linux). flock is used as a
	# supplementary layer on Linux when available.
	#
	# Register EXIT trap BEFORE acquiring the lock so the lock is always
	# released on exit — including set -e aborts, SIGTERM, and return paths.
	# SIGKILL cannot be trapped; stale-lock detection handles that case.
	trap 'release_instance_lock' EXIT

	# Open FD 9 for flock supplementary layer (no-op if flock unavailable)
	exec 9>"$LOCKFILE"
	if ! acquire_instance_lock; then
		return 0
	fi

	if ! check_session_gate; then
		return 0
	fi

	if ! check_dedup; then
		return 0
	fi

	# Rotate hot log to cold archive if over cap (t1886)
	# Run before any log writes so the new cycle starts with a fresh hot log.
	rotate_pulse_log || true

	# Record cycle start for append_cycle_index duration tracking (t1886)
	local _cycle_start_epoch
	_cycle_start_epoch=$(date +%s)

	# Run pre-flight stages (cleanup, prefetch, normalization)
	if ! _run_preflight_stages; then
		return 0
	fi

	# Re-check stop flag immediately before run_pulse() — a stop may have
	# been issued during the prefetch/cleanup phase above (t2943)
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared during setup — aborting before run_pulse()" >>"$LOGFILE"
		return 0
	fi

	# Deterministic merge pass: approve and merge all ready PRs across pulse
	# repos. This runs BEFORE the LLM session because merging is free (no
	# worker slot) and deterministic (no judgment needed). Previously merging
	# was LLM-only, which meant backlogs of 100+ PRs accumulated when the
	# LLM failed to execute merge steps or the prefetch showed 0 PRs.
	run_stage_with_timeout "deterministic_merge_pass" "$PRE_RUN_STAGE_TIMEOUT" \
		merge_ready_prs_all_repos || true

	# Deterministic fill floor runs EVERY cycle — before the LLM session,
	# not after. This ensures workers are dispatched every 2-min cycle
	# regardless of whether the LLM supervisor is running.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping deterministic fill floor" >>"$LOGFILE"
	else
		apply_deterministic_fill_floor
	fi

	# Write structured health snapshot for instant diagnosis (GH#15107)
	write_pulse_health_file || true

	# Append one JSONL record to the cycle index (t1886)
	local _cycle_end_epoch
	_cycle_end_epoch=$(date +%s)
	local _cycle_duration=$((_cycle_end_epoch - _cycle_start_epoch))
	append_cycle_index "$_cycle_duration" || true

	# Release the instance lock BEFORE the LLM session so the next 2-min
	# cycle can run deterministic ops (merge pass + fill floor) concurrently.
	# The LLM session is protected by its own stall/daily-sweep gating,
	# and workers are protected by 7-layer dedup guards (assignee labels,
	# DISPATCH_CLAIM comments, ledger checks). No risk of duplication.
	release_instance_lock

	# Conditional LLM supervisor: the deterministic layer (merge pass, fill
	# floor, stalled worker cleanup) handles the common case every cycle.
	# The LLM supervisor adds value only for edge cases (CHANGES_REQUESTED
	# PRs, external contributor triage, semantic dedup, stale coaching).
	#
	# Skip the LLM session unless:
	#   1. Backlog is stalled (issue+PR count unchanged for PULSE_LLM_STALL_THRESHOLD)
	#   2. Daily sweep is due (last LLM run was >24h ago)
	#   3. PULSE_FORCE_LLM=1 is set (manual override)
	#
	# Trigger mode routing (GH#15287):
	#   daily_sweep → /pulse-sweep (full edge-case triage, quality review, mission awareness)
	#   stall / first_run → /pulse (lightweight dispatch+merge, unblocks the stall faster)
	local skip_llm=false
	local llm_trigger_mode="stall"
	if [[ "${PULSE_FORCE_LLM:-0}" != "1" ]] && ! _should_run_llm_supervisor; then
		skip_llm=true
		echo "[pulse-wrapper] Skipping LLM supervisor (backlog progressing, daily sweep not due)" >>"$LOGFILE"
	else
		if [[ -f "${PULSE_DIR}/llm_trigger_mode" ]]; then
			llm_trigger_mode=$(cat "${PULSE_DIR}/llm_trigger_mode" 2>/dev/null) || llm_trigger_mode="stall"
		fi
		if [[ "${PULSE_FORCE_LLM:-0}" == "1" && "$llm_trigger_mode" == "stall" ]]; then
			llm_trigger_mode="daily_sweep"
		fi
	fi

	if [[ "$skip_llm" == "false" ]]; then
		# Use a separate LLM lock so only one LLM session runs at a time,
		# without blocking the deterministic 2-min cycle.
		local llm_lockdir="${LOCKDIR}.llm"
		if mkdir "$llm_lockdir" 2>/dev/null; then
			echo "$$" >"${llm_lockdir}/pid" 2>/dev/null || true
			# shellcheck disable=SC2064
			trap "rm -rf '$llm_lockdir' 2>/dev/null" EXIT

			local underfill_output
			underfill_output=$(_compute_initial_underfill)
			local initial_underfilled_mode initial_underfill_pct
			initial_underfilled_mode=$(echo "$underfill_output" | sed -n '1p')
			initial_underfill_pct=$(echo "$underfill_output" | sed -n '2p')

			local pulse_start_epoch
			pulse_start_epoch=$(date +%s)
			run_pulse "$initial_underfilled_mode" "$initial_underfill_pct" "$llm_trigger_mode"
			local pulse_end_epoch
			pulse_end_epoch=$(date +%s)
			local pulse_duration=$((pulse_end_epoch - pulse_start_epoch))

			date +%s >"${PULSE_DIR}/last_llm_run_epoch"
			_run_early_exit_recycle_loop "$pulse_duration"
			rm -rf "$llm_lockdir" 2>/dev/null || true
		else
			echo "[pulse-wrapper] LLM session already running (lock held) — skipping" >>"$LOGFILE"
		fi
	fi

	return 0
}

#######################################
# Kill orphaned opencode processes
#
# Criteria (ALL must be true):
#   - No TTY (headless — not a user's terminal tab)
#   - Not a current worker (/full-loop or /review-issue-pr not in command)
#   - Not the supervisor pulse (Supervisor Pulse not in command)
#   - Not a strategic review (Strategic Review not in command)
#   - Older than ORPHAN_MAX_AGE seconds
#
# These are completed headless sessions where opencode entered idle
# state with a file watcher and never exited.
#######################################

#######################################
# Write pulse-health.json — structured status snapshot for instant diagnosis.
#
# Fields (GH#15107):
#   workers_active          — current live worker count
#   workers_max             — configured max worker slots
#   prs_merged_this_cycle   — PRs squash-merged by deterministic merge pass
#   prs_closed_conflicting  — conflicting PRs closed this cycle
#   issues_dispatched       — workers launched this cycle (from dispatch ledger)
#   prefetch_errors         — prefetch_state failures this cycle
#   stalled_workers_killed  — stalled workers killed by cleanup_stalled_workers
#   models_backed_off       — active backoff entries in provider_backoff DB
#
# Atomic write: write to tmp file then mv to avoid partial reads.
# Non-fatal: any failure is logged and silently ignored.
#######################################
write_pulse_health_file() {
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local workers_active workers_max
	workers_active=$(count_active_workers 2>/dev/null || echo "0")
	[[ "$workers_active" =~ ^[0-9]+$ ]] || workers_active=0
	workers_max=$(get_max_workers_target 2>/dev/null || echo "1")
	[[ "$workers_max" =~ ^[0-9]+$ ]] || workers_max=1

	# issues_dispatched: in-flight worker count from dispatch ledger
	local issues_dispatched=0
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local _ledger_count
		_ledger_count=$("$_ledger_helper" count 2>/dev/null || echo "0")
		[[ "$_ledger_count" =~ ^[0-9]+$ ]] && issues_dispatched="$_ledger_count"
	fi

	# models_backed_off: count active backoff entries in provider_backoff DB
	local models_backed_off=0
	if [[ -x "$HEADLESS_RUNTIME_HELPER" ]]; then
		local _backoff_rows
		_backoff_rows=$("$HEADLESS_RUNTIME_HELPER" backoff status 2>/dev/null | grep -c '|' || echo "0")
		[[ "$_backoff_rows" =~ ^[0-9]+$ ]] && models_backed_off="$_backoff_rows"
	fi

	local tmp_health
	tmp_health=$(mktemp "${HOME}/.aidevops/logs/.pulse-health-XXXXXX.json") || {
		echo "[pulse-wrapper] write_pulse_health_file: mktemp failed — skipping health write" >>"$LOGFILE"
		return 0
	}

	cat >"$tmp_health" <<EOF
{
  "timestamp": "${ts}",
  "workers_active": ${workers_active},
  "workers_max": ${workers_max},
  "prs_merged_this_cycle": ${_PULSE_HEALTH_PRS_MERGED},
  "prs_closed_conflicting": ${_PULSE_HEALTH_PRS_CLOSED_CONFLICTING},
  "issues_dispatched": ${issues_dispatched},
  "prefetch_errors": ${_PULSE_HEALTH_PREFETCH_ERRORS},
  "stalled_workers_killed": ${_PULSE_HEALTH_STALLED_KILLED},
  "models_backed_off": ${models_backed_off}
}
EOF

	mv "$tmp_health" "$PULSE_HEALTH_FILE" || {
		rm -f "$tmp_health"
		echo "[pulse-wrapper] write_pulse_health_file: mv failed — skipping health write" >>"$LOGFILE"
		return 0
	}

	echo "[pulse-wrapper] pulse-health.json written: workers=${workers_active}/${workers_max} merged=${_PULSE_HEALTH_PRS_MERGED} closed_conflicting=${_PULSE_HEALTH_PRS_CLOSED_CONFLICTING} dispatched=${issues_dispatched} stalled_killed=${_PULSE_HEALTH_STALLED_KILLED} backed_off=${models_backed_off}" >>"$LOGFILE"
	return 0
}

#######################################
# Kill workers stalled on rate-limited providers.
#
# When a provider hits its rate limit, already-running workers don't exit —
# they hang indefinitely waiting for the API to respond. The retry/rotation
# logic in headless-runtime-helper.sh only runs AFTER the process exits,
# creating a deadlock: worker waits for API → API is rate-limited → worker
# never exits → rotation never fires → slot wasted permanently.
#
# Observed in production: 20 of 24 worker slots consumed by stalled openai
# workers with 306 bytes of output (just the sandbox startup line, zero LLM
# activity) for 20-30 minutes. 0% CPU, 0 commits, 0 PRs.
#
# Detection: a worker running >STALLED_WORKER_MIN_AGE seconds with a log
# file ≤STALLED_WORKER_MAX_LOG_BYTES is stalled. The log file only contains
# the sandbox startup line when the LLM never responded.
#
# Action: kill the stalled worker, record provider backoff so the next
# dispatch rotates to a working provider, and log the kill for audit.
#######################################
STALLED_WORKER_MIN_AGE="${STALLED_WORKER_MIN_AGE:-300}"             # 5 minutes
STALLED_WORKER_MAX_LOG_BYTES="${STALLED_WORKER_MAX_LOG_BYTES:-500}" # just the startup line

cleanup_stalled_workers() {
	local killed=0
	local freed_mb=0

	while IFS= read -r line; do
		local pid etime cpu rss cmd
		read -r pid etime cpu rss cmd <<<"$line"

		# Only check headless workers (no TTY, full-loop in command)
		case "$cmd" in
		*"/full-loop"*) ;;
		*) continue ;;
		esac

		# Check process age
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$STALLED_WORKER_MIN_AGE" ]]; then
			continue
		fi

		# Extract issue number and find log file
		local issue_num
		issue_num=$(echo "$cmd" | grep -oE 'issue #[0-9]+' | grep -oE '[0-9]+' | head -1)
		[[ -n "$issue_num" ]] || continue

		local safe_slug log_file log_size
		# Check all pulse-enabled repos for matching log
		local found_log=""
		for safe_slug in $(jq -r '.initialized_repos[] | select(.pulse == true) | .slug' "$REPOS_JSON" 2>/dev/null | tr '/:' '--'); do
			log_file="/tmp/pulse-${safe_slug}-${issue_num}.log"
			if [[ -f "$log_file" ]]; then
				found_log="$log_file"
				break
			fi
		done
		# Fallback log path
		if [[ -z "$found_log" ]]; then
			log_file="/tmp/pulse-${issue_num}.log"
			[[ -f "$log_file" ]] && found_log="$log_file"
		fi

		if [[ -z "$found_log" ]]; then
			continue
		fi

		# Check log size — stalled workers have ≤500 bytes (just sandbox startup)
		log_size=$(wc -c <"$found_log" 2>/dev/null || echo "0")
		log_size=$(echo "$log_size" | tr -d ' ')
		[[ "$log_size" =~ ^[0-9]+$ ]] || log_size=0

		if [[ "$log_size" -gt "$STALLED_WORKER_MAX_LOG_BYTES" ]]; then
			# Worker has produced real output — it's working, not stalled
			continue
		fi

		# Extract model from the command line for backoff recording
		local worker_model
		worker_model=$(echo "$cmd" | grep -oE '\-m [^ ]+' | head -1 | sed 's/-m //')

		# Kill the stalled worker
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		freed_mb=$((freed_mb + mb))

		# Record provider backoff so next dispatch rotates away
		if [[ -n "$worker_model" ]]; then
			local provider
			provider=$(echo "$worker_model" | cut -d/ -f1)
			local tmp_backoff
			tmp_backoff=$(mktemp)
			printf 'Worker stalled: PID %s, issue #%s, model %s, age %ss, log %s bytes\n' \
				"$pid" "$issue_num" "$worker_model" "$age_seconds" "$log_size" >"$tmp_backoff"

			# Use the headless runtime helper to record backoff properly
			if [[ -x "${SCRIPT_DIR}/headless-runtime-helper.sh" ]]; then
				"${SCRIPT_DIR}/headless-runtime-helper.sh" backoff set "$worker_model" "rate_limit" 900 2>/dev/null || true
			fi
			rm -f "$tmp_backoff"
		fi

		echo "[pulse-wrapper] Killed stalled worker PID $pid (issue #${issue_num}, model=${worker_model:-unknown}, age=${age_seconds}s, log=${log_size}B) — provider likely rate-limited" >>"$LOGFILE"

	done < <(ps axo pid,etime,%cpu,rss,command | grep '[.]opencode run' | grep -v grep)

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] cleanup_stalled_workers: killed ${killed} stalled workers (freed ~${freed_mb}MB)" >>"$LOGFILE"
	fi
	# Accumulate into per-cycle health counter (GH#15107)
	_PULSE_HEALTH_STALLED_KILLED=$((_PULSE_HEALTH_STALLED_KILLED + killed))
	return 0
}

cleanup_orphans() {

	local killed=0
	local total_mb=0

	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		# Skip interactive sessions (has a real TTY).
		# Exclude both '?' (Linux headless) and '??' (macOS headless) — only
		# those are headless; anything else (pts/N, ttys00N) is interactive.
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		# Skip active workers, pulse, strategic reviews, and language servers.
		# Use case instead of [[ =~ ]] with | alternation — zsh parses the |
		# as a pipe operator inside [[ ]], causing a parse error. See GH#4904.
		case "$cmd" in
		*"/full-loop"* | *"/review-issue-pr"* | *"Supervisor Pulse"* | *"Strategic Review"* | *"language-server"* | *"eslintServer"*)
			continue
			;;
		esac

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]]; then
			continue
		fi

		# This is an orphan — kill it
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep '[.]opencode' | grep -v 'bash-language-server')

	# Also kill orphaned node launchers (parent of .opencode processes)
	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		[[ "$tty" != "?" && "$tty" != "??" ]] && continue
		# Use case instead of [[ =~ ]] with | alternation — zsh parse error. See GH#4904.
		case "$cmd" in
		*"/full-loop"* | *"/review-issue-pr"* | *"Supervisor Pulse"* | *"Strategic Review"* | *"language-server"* | *"eslintServer"*)
			continue
			;;
		esac

		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		[[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]] && continue

		kill "$pid" 2>/dev/null || true
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep 'node.*opencode' | grep -v '[.]opencode')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed orphaned opencode processes (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Kill stale opencode processes (TTY-attached)
#
# cleanup_orphans only handles headless (no-TTY) processes. Workers
# dispatched via terminal tabs retain a TTY, so they survive the orphan
# reaper. When OpenCode completes a task it enters an idle file-watcher
# state (0% CPU) and never exits — consuming memory and TTY slots.
#
# Criteria (ALL must be true):
#   - Is a .opencode binary process
#   - Launched as a headless worker (command contains --format json)
#   - Older than STALE_OPENCODE_MAX_AGE seconds (default: 4 hours)
#   - CPU usage below PULSE_IDLE_CPU_THRESHOLD (default: 5%)
#   - Not the current interactive session (skip our own PID tree)
#
# Interactive sessions (no --format json) are NEVER killed — they may be
# idle because the user stepped away, not because the task completed.
#
# Also kills the parent node launcher and grandparent zsh for each
# stale .opencode process to fully reclaim the terminal tab.
#######################################
STALE_OPENCODE_MAX_AGE="${STALE_OPENCODE_MAX_AGE:-14400}" # 4 hours

cleanup_stale_opencode() {
	local killed=0
	local total_mb=0

	# Get our own PID tree to avoid killing the current session
	local my_pid="$$"
	local my_ppid
	my_ppid=$(ps -p "$my_pid" -o ppid= 2>/dev/null | tr -d ' ') || my_ppid=""

	while IFS= read -r line; do
		local pid cpu rss
		read -r pid cpu rss <<<"$line"

		# Skip our own process tree
		if [[ "$pid" == "$my_pid" || "$pid" == "$my_ppid" ]]; then
			continue
		fi

		# Skip interactive sessions — only kill headless workers.
		# Headless workers are launched via headless-runtime-helper.sh with
		# --format json in the command line. Interactive sessions (user typing
		# in a terminal) never have this flag. Without this guard, any idle
		# interactive session (user stepped away) gets killed along with its
		# parent shell, closing the terminal tab entirely.
		local proc_cmd
		proc_cmd=$(ps -p "$pid" -o command= 2>/dev/null) || proc_cmd=""
		if [[ "$proc_cmd" != *"--format json"* ]]; then
			continue
		fi

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$STALE_OPENCODE_MAX_AGE" ]]; then
			continue
		fi

		# Skip processes with significant CPU usage (actively working)
		# cpu is a float like "0.0" or "40.3" — compare integer part
		local cpu_int
		cpu_int="${cpu%%.*}"
		[[ "$cpu_int" =~ ^[0-9]+$ ]] || cpu_int=0
		if [[ "$cpu_int" -ge "$PULSE_IDLE_CPU_THRESHOLD" ]]; then
			continue
		fi

		# This is a stale headless worker — kill it and its parent chain
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))

		# Kill parent (node launcher) and grandparent (zsh tab) first
		local ppid
		ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || ppid=""
		if [[ -n "$ppid" && "$ppid" != "1" ]]; then
			local gppid
			gppid=$(ps -p "$ppid" -o ppid= 2>/dev/null | tr -d ' ') || gppid=""
			# Kill grandparent zsh (the terminal tab shell)
			if [[ -n "$gppid" && "$gppid" != "1" ]]; then
				local gp_cmd
				gp_cmd=$(ps -p "$gppid" -o command= 2>/dev/null) || gp_cmd=""
				# Only kill if it's a shell that launched opencode
				case "$gp_cmd" in
				*zsh* | *bash* | *sh*)
					kill "$gppid" 2>/dev/null || true
					;;
				esac
			fi
			# Kill parent node launcher
			kill "$ppid" 2>/dev/null || true
		fi

		# Kill the .opencode process — SIGTERM first, SIGKILL fallback.
		# OpenCode's file watcher may ignore SIGTERM.
		kill "$pid" 2>/dev/null || true
		sleep 1
		if kill -0 "$pid" 2>/dev/null; then
			kill -9 "$pid" 2>/dev/null || true
		fi
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,%cpu,rss,command | awk '$0 ~ /[.]opencode/ && $0 !~ /bash-language-server/ { print $1, $2, $3 }')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed stale headless opencode workers (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Apply peak-hours worker cap (t1677)
#
# When supervisor.peak_hours_enabled is true and the current local time
# falls within the configured window, caps MAX_WORKERS at
# ceil(off_peak_max * peak_hours_worker_fraction), minimum 1.
#
# The cap is applied AFTER the RAM-based calculation so it can only
# reduce, never increase, the worker count.
#
# Settings read via settings-helper.sh (respects env var overrides):
#   supervisor.peak_hours_enabled        (default: false)
#   supervisor.peak_hours_start          (default: 5,  0-23 local hour)
#   supervisor.peak_hours_end            (default: 11, 0-23 local hour)
#   supervisor.peak_hours_tz             (default: America/Los_Angeles)
#   supervisor.peak_hours_worker_fraction (default: 0.2)
#
# Arguments:
#   $1 - current off-peak max_workers value (integer >= 1)
#
# Output: (possibly reduced) max_workers value to stdout
# Returns: 0 always
#######################################
apply_peak_hours_cap() {
	local off_peak_max="$1"

	# Validate input
	[[ "$off_peak_max" =~ ^[0-9]+$ ]] || off_peak_max=1
	[[ "$off_peak_max" -lt 1 ]] && off_peak_max=1

	# Read settings via helper (respects env var overrides)
	local settings_helper="${SCRIPT_DIR}/settings-helper.sh"
	if [[ ! -x "$settings_helper" ]]; then
		echo "$off_peak_max"
		return 0
	fi

	local peak_enabled
	peak_enabled=$("$settings_helper" get supervisor.peak_hours_enabled 2>/dev/null || echo "false")
	if [[ "$peak_enabled" != "true" ]]; then
		echo "$off_peak_max"
		return 0
	fi

	local ph_start ph_end ph_fraction
	ph_start=$("$settings_helper" get supervisor.peak_hours_start 2>/dev/null || echo "5")
	ph_end=$("$settings_helper" get supervisor.peak_hours_end 2>/dev/null || echo "11")
	ph_fraction=$("$settings_helper" get supervisor.peak_hours_worker_fraction 2>/dev/null || echo "0.2")

	# Validate hour values
	[[ "$ph_start" =~ ^[0-9]+$ ]] || ph_start=5
	[[ "$ph_end" =~ ^[0-9]+$ ]] || ph_end=11
	[[ "$ph_start" -gt 23 ]] && ph_start=5
	[[ "$ph_end" -gt 23 ]] && ph_end=11

	# Get current local hour (strip leading zero to avoid octal interpretation)
	local current_hour
	current_hour=$(date +%H)
	local cur ph_s ph_e
	cur=$((10#${current_hour}))
	ph_s=$((10#${ph_start}))
	ph_e=$((10#${ph_end}))

	# Determine if we are inside the peak window
	# Supports overnight windows (start > end, e.g., 22→6)
	local in_peak=false
	if [[ "$ph_s" -le "$ph_e" ]]; then
		# Normal window: in peak when cur >= start AND cur < end
		if [[ "$cur" -ge "$ph_s" && "$cur" -lt "$ph_e" ]]; then
			in_peak=true
		fi
	else
		# Overnight window: in peak when cur >= start OR cur < end
		if [[ "$cur" -ge "$ph_s" || "$cur" -lt "$ph_e" ]]; then
			in_peak=true
		fi
	fi

	if [[ "$in_peak" != "true" ]]; then
		echo "$off_peak_max"
		return 0
	fi

	# Compute capped value: ceil(off_peak_max * fraction), minimum 1
	# Use awk for floating-point arithmetic (bash has no native float support)
	local peak_max
	peak_max=$(awk -v max="$off_peak_max" -v frac="$ph_fraction" \
		'BEGIN { v = max * frac; c = int(v); if (c < v) c++; if (c < 1) c = 1; print c }' \
		2>/dev/null || echo "1")
	[[ "$peak_max" =~ ^[0-9]+$ ]] || peak_max=1
	[[ "$peak_max" -lt 1 ]] && peak_max=1

	echo "[pulse-wrapper] Peak hours active (window ${ph_s}→${ph_e}, current hour ${cur}): capping MAX_WORKERS ${off_peak_max}→${peak_max} (fraction=${ph_fraction})" >>"$LOGFILE"
	echo "$peak_max"
	return 0
}

#######################################
# Calculate max workers from available RAM
#
# Formula: (free_ram - RAM_RESERVE_MB) / RAM_PER_WORKER_MB
# Clamped to [1, MAX_WORKERS_CAP]
#
# Writes MAX_WORKERS to a file that pulse.md reads via bash.
#######################################
calculate_max_workers() {
	local free_mb
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: use vm_stat for free + inactive (reclaimable) pages
		local page_size free_pages inactive_pages
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
		free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		inactive_pages=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		# Validate integers before arithmetic expansion
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$free_pages" =~ ^[0-9]+$ ]] || free_pages=0
		[[ "$inactive_pages" =~ ^[0-9]+$ ]] || inactive_pages=0
		free_mb=$(((free_pages + inactive_pages) * page_size / 1024 / 1024))
	else
		# Linux: use MemAvailable from /proc/meminfo
		free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)
	fi
	[[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=8192

	local available_mb=$((free_mb - RAM_RESERVE_MB))
	local max_workers=$((available_mb / RAM_PER_WORKER_MB))

	# Clamp to [1, MAX_WORKERS_CAP]
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	elif [[ "$max_workers" -gt "$MAX_WORKERS_CAP" ]]; then
		max_workers="$MAX_WORKERS_CAP"
	fi

	# Apply peak-hours cap (t1677) — may further reduce max_workers
	max_workers=$(apply_peak_hours_cap "$max_workers")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$max_workers" -lt 1 ]] && max_workers=1

	# Write to a file that pulse.md can read
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	echo "$max_workers" >"$max_workers_file"

	echo "[pulse-wrapper] Available RAM: ${free_mb}MB, reserve: ${RAM_RESERVE_MB}MB, max workers: ${max_workers}" >>"$LOGFILE"
	return 0
}

#######################################
# Calculate priority-class worker allocations (t1423)
#
# Reads repos.json to count product vs tooling repos, then computes
# per-class slot reservations based on PRODUCT_RESERVATION_PCT.
#
# Product repos get a guaranteed minimum share of worker slots.
# Tooling repos get the remainder. When one class has no pending work,
# the other class can use the freed slots (soft reservation).
#
# Output: writes allocation data to pulse-priority-allocations file
# and appends a summary section to STATE_FILE for the pulse agent.
#
# Depends on: calculate_max_workers() having run first (reads pulse-max-workers)
#######################################
calculate_priority_allocations() {
	local repos_json="${REPOS_JSON}"
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	local alloc_file="${HOME}/.aidevops/logs/pulse-priority-allocations"

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "[pulse-wrapper] repos.json or jq not available — skipping priority allocations" >>"$LOGFILE"
		return 0
	fi

	local max_workers
	max_workers=$(cat "$max_workers_file" 2>/dev/null || echo 4)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=4

	# Count pulse-enabled repos by priority class (single jq pass)
	local product_repos tooling_repos
	read -r product_repos tooling_repos < <(jq -r '
		.initialized_repos |
		map(select(.pulse == true and (.local_only // false) == false and .slug != "")) |
		[
			(map(select(.priority == "product")) | length),
			(map(select(.priority == "tooling")) | length)
		] | @tsv
	' "$repos_json" 2>/dev/null) || true
	product_repos=${product_repos:-0}
	tooling_repos=${tooling_repos:-0}
	[[ "$product_repos" =~ ^[0-9]+$ ]] || product_repos=0
	[[ "$tooling_repos" =~ ^[0-9]+$ ]] || tooling_repos=0

	# Count product repos that can actually dispatch now (not blocked by daily PR cap)
	local dispatchable_product_repos today_utc
	dispatchable_product_repos=0
	today_utc=$(date -u +%Y-%m-%d)
	if [[ "$product_repos" -gt 0 && "$DAILY_PR_CAP" -gt 0 ]]; then
		while IFS= read -r slug; do
			[[ -n "$slug" ]] || continue
			local pr_json daily_pr_count pr_alloc_err
			# GH#4412: use --state all to count merged/closed PRs too
			pr_alloc_err=$(mktemp)
			pr_json=$(gh pr list --repo "$slug" --state all --json createdAt --limit 200 2>"$pr_alloc_err") || pr_json="[]"
			if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
				local _pr_alloc_err_msg
				_pr_alloc_err_msg=$(cat "$pr_alloc_err" 2>/dev/null || echo "unknown error")
				echo "[pulse-wrapper] calculate_priority_allocations: gh pr list FAILED for ${slug}: ${_pr_alloc_err_msg}" >>"$LOGFILE"
				pr_json="[]"
			fi
			rm -f "$pr_alloc_err"
			daily_pr_count=$(echo "$pr_json" | jq --arg today "$today_utc" '[.[] | select(.createdAt | startswith($today))] | length' 2>/dev/null) || daily_pr_count=0
			[[ "$daily_pr_count" =~ ^[0-9]+$ ]] || daily_pr_count=0
			if [[ "$daily_pr_count" -lt "$DAILY_PR_CAP" ]]; then
				dispatchable_product_repos=$((dispatchable_product_repos + 1))
			fi
		done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .priority == "product") | .slug' "$repos_json" 2>/dev/null)
	else
		dispatchable_product_repos="$product_repos"
	fi
	[[ "$dispatchable_product_repos" =~ ^[0-9]+$ ]] || dispatchable_product_repos="$product_repos"
	if [[ "$dispatchable_product_repos" -lt "$product_repos" ]]; then
		echo "[pulse-wrapper] Product dispatchability reduced by daily PR caps: ${dispatchable_product_repos}/${product_repos} repos can accept new workers" >>"$LOGFILE"
	fi

	# Calculate reservations
	# product_min = ceil(max_workers * PRODUCT_RESERVATION_PCT / 100)
	# Using integer arithmetic: ceil(a/b) = (a + b - 1) / b
	local product_min tooling_max
	if [[ "$dispatchable_product_repos" -eq 0 ]]; then
		# No product repos — all slots available for tooling
		product_min=0
		tooling_max="$max_workers"
	elif [[ "$tooling_repos" -eq 0 ]]; then
		# No tooling repos — all slots available for product
		product_min="$max_workers"
		tooling_max=0
	else
		product_min=$(((max_workers * PRODUCT_RESERVATION_PCT + 99) / 100))
		# Ensure product_min doesn't exceed max_workers
		if [[ "$product_min" -gt "$max_workers" ]]; then
			product_min="$max_workers"
		fi
		# Ensure at least 1 slot for tooling when tooling repos exist
		# but only when there are multiple slots to distribute (with 1 slot,
		# product keeps it — the reservation is a minimum guarantee)
		if [[ "$max_workers" -gt 1 && "$product_min" -ge "$max_workers" && "$tooling_repos" -gt 0 ]]; then
			product_min=$((max_workers - 1))
		fi
		tooling_max=$((max_workers - product_min))
	fi

	# Write allocation file (key=value, readable by pulse.md)
	{
		echo "MAX_WORKERS=${max_workers}"
		echo "PRODUCT_REPOS=${product_repos}"
		echo "TOOLING_REPOS=${tooling_repos}"
		echo "DISPATCHABLE_PRODUCT_REPOS=${dispatchable_product_repos}"
		echo "PRODUCT_MIN=${product_min}"
		echo "TOOLING_MAX=${tooling_max}"
		echo "PRODUCT_RESERVATION_PCT=${PRODUCT_RESERVATION_PCT}"
		echo "QUALITY_DEBT_CAP_PCT=${QUALITY_DEBT_CAP_PCT}"
	} >"$alloc_file"

	echo "[pulse-wrapper] Priority allocations: product_min=${product_min}, tooling_max=${tooling_max} (${product_repos} product, ${tooling_repos} tooling repos, ${max_workers} total slots)" >>"$LOGFILE"
	return 0
}

#######################################
# Count active debt workers for a repo (quality-debt + simplification-debt)
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - debt type: "quality-debt", "simplification-debt", or "all" (default: all)
#
# Outputs two lines: active_count queued_count
# Exit code: always 0
#######################################
count_debt_workers() {
	local repo_slug="$1"
	local debt_type="${2:-all}"
	local active=0
	local queued=0

	case "$debt_type" in
	quality-debt)
		active=$(gh issue list --repo "$repo_slug" --label "quality-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		queued=$(gh issue list --repo "$repo_slug" --label "quality-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		;;
	simplification-debt)
		active=$(gh issue list --repo "$repo_slug" --label "simplification-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		queued=$(gh issue list --repo "$repo_slug" --label "simplification-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		;;
	all)
		local qa_active qa_queued sd_active sd_queued
		qa_active=$(gh issue list --repo "$repo_slug" --label "quality-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		qa_queued=$(gh issue list --repo "$repo_slug" --label "quality-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		sd_active=$(gh issue list --repo "$repo_slug" --label "simplification-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		sd_queued=$(gh issue list --repo "$repo_slug" --label "simplification-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		active=$((qa_active + sd_active))
		queued=$((qa_queued + sd_queued))
		;;
	esac

	[[ "$active" =~ ^[0-9]+$ ]] || active=0
	[[ "$queued" =~ ^[0-9]+$ ]] || queued=0
	echo "$active"
	echo "$queued"
	return 0
}

#######################################
# Check per-repo worker cap before dispatch
#
# Arguments:
#   $1 - repo path (canonical path on disk)
#   $2 - max workers per repo (default: MAX_WORKERS_PER_REPO or 5)
#
# Exit codes:
#   0 - at or above cap (skip dispatch for this repo)
#   1 - below cap (safe to dispatch)
#######################################
check_repo_worker_cap() {
	local repo_path="$1"
	local cap="${2:-${MAX_WORKERS_PER_REPO:-5}}"
	local active_for_repo

	active_for_repo=$(list_active_worker_processes | awk -v path="$repo_path" '
		BEGIN { esc=path; gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc) }
		$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") { count++ }
		END { print count + 0 }
	')
	[[ "$active_for_repo" =~ ^[0-9]+$ ]] || active_for_repo=0

	if [[ "$active_for_repo" -ge "$cap" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Create a pre-isolated worktree for a quality-debt worker
#
# Generates a branch name from the issue number + title slug, creates the
# worktree under the same parent directory as the canonical repo, and prints
# the worktree path to stdout. Idempotent — reuses an existing worktree if
# the branch already exists.
#
# Arguments:
#   $1 - canonical repo path
#   $2 - issue number
#   $3 - issue title (used for branch slug)
#
# Outputs: worktree path (stdout)
# Exit codes:
#   0 - worktree path printed to stdout
#   1 - failed to create worktree
#######################################
create_quality_debt_worktree() {
	local repo_path="$1"
	local issue_number="$2"
	local issue_title="$3"

	local qd_branch_slug qd_branch qd_wt_path
	qd_branch_slug=$(printf '%s' "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-30)
	qd_branch="bugfix/qd-${issue_number}-${qd_branch_slug}"

	# Check if worktree already exists for this branch
	qd_wt_path=$(git -C "$repo_path" worktree list --porcelain |
		grep -B2 "branch refs/heads/${qd_branch}$" |
		grep "^worktree " | cut -d' ' -f2- 2>/dev/null || true)

	if [[ -z "$qd_wt_path" ]]; then
		local repo_name parent_dir qd_wt_slug
		repo_name=$(basename "$repo_path")
		parent_dir=$(dirname "$repo_path")
		qd_wt_slug=$(printf '%s' "$qd_branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
		qd_wt_path="${parent_dir}/${repo_name}-${qd_wt_slug}"
		git -C "$repo_path" worktree add -b "$qd_branch" "$qd_wt_path" 2>/dev/null || {
			echo "[create_quality_debt_worktree] Failed to create worktree for #${issue_number}" >>"${LOGFILE:-/dev/null}"
			return 1
		}
	fi

	if [[ -z "$qd_wt_path" || ! -d "$qd_wt_path" ]]; then
		return 1
	fi

	printf '%s\n' "$qd_wt_path"
	return 0
}

#######################################
# Close stale quality-debt PRs that have been CONFLICTING for 24+ hours
#
# Arguments:
#   $1 - repo slug (owner/repo)
#
# Exit code: always 0
#######################################
close_stale_quality_debt_prs() {
	local repo_slug="$1"
	local cutoff_epoch
	cutoff_epoch=$(date -v-24H +%s 2>/dev/null || date -d '24 hours ago' +%s 2>/dev/null || echo 0)

	local pr_json
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--json number,title,labels,mergeable,updatedAt \
		--jq '[.[] | select(.mergeable == "CONFLICTING") | select(.labels[]?.name == "quality-debt" or (.title | test("quality.debt|fix:.*batch|fix:.*harden"; "i")))]' \
		2>/dev/null) || pr_json="[]"

	local pr_count
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null || echo 0)
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	[[ "$pr_count" -gt 0 ]] || return 0

	local i
	for i in $(seq 0 $((pr_count - 1))); do
		local pr_num pr_updated_at pr_epoch
		pr_num=$(printf '%s' "$pr_json" | jq -r ".[$i].number" 2>/dev/null) || continue
		pr_updated_at=$(printf '%s' "$pr_json" | jq -r ".[$i].updatedAt" 2>/dev/null) || continue
		# GH#17699: TZ=UTC required — macOS date interprets input as local time
		pr_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_updated_at" +%s 2>/dev/null ||
			date -d "$pr_updated_at" +%s 2>/dev/null || echo 0)

		if [[ "$pr_epoch" -lt "$cutoff_epoch" ]]; then
			gh pr close "$pr_num" --repo "$repo_slug" \
				-c "Closing — this PR has merge conflicts and touches too many files (blast radius issue, see t1422). The underlying fixes will be re-created as smaller PRs (max 5 files each) to prevent conflict cascades." \
				2>/dev/null || true
			# Relabel linked issue status:available
			local issue_num
			issue_num=$(gh pr view "$pr_num" --repo "$repo_slug" --json body \
				--jq '.body | match("(?i)(closes|fixes|resolves)[[:space:]]+#([0-9]+)").captures[1].string' \
				2>/dev/null || true)
			if [[ -n "$issue_num" ]]; then
				gh issue edit "$issue_num" --repo "$repo_slug" \
					--remove-label "status:in-review" --add-label "status:available" 2>/dev/null || true
			fi
		fi
	done
	return 0
}

#######################################
# Dispatch triage review workers for needs-maintainer-review issues
#
# Reads the pre-fetched triage status from STATE_FILE and dispatches
# opus-tier review workers for issues marked needs-review. Respects
# the 2-per-cycle cap and available worker slots.
#
# Arguments:
#   $1 - available worker slots (AVAILABLE)
#   $2 - repos JSON path (default: REPOS_JSON)
#
# Outputs: updated available count to stdout (one integer)
# Exit code: always 0
#######################################
dispatch_triage_reviews() {
	local available="$1"
	local repos_json="${2:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local triage_count=0
	local triage_max=2

	[[ "$available" =~ ^[0-9]+$ ]] || available=0
	[[ "$available" -gt 0 ]] || {
		printf '%d\n' "$available"
		return 0
	}

	# Parse needs-review items from the dedicated triage state file (t1894).
	# NMR data is written to a separate file, not the LLM's STATE_FILE.
	local triage_file="${TRIAGE_STATE_FILE:-${STATE_FILE%.txt}-triage.txt}"
	[[ -f "$triage_file" ]] || {
		echo "[pulse-wrapper] dispatch_triage_reviews: no triage state file" >>"$LOGFILE"
		printf '%d\n' "$available"
		return 0
	}
	local state_file="$triage_file"

	# Resolve model: prefer opus, fall back to sonnet, then omit --model
	# (lets headless-runtime-helper pick its default, same as implementation workers)
	local resolved_model=""
	resolved_model=$(~/.aidevops/agents/scripts/model-availability-helper.sh resolve opus 2>/dev/null || echo "")
	if [[ -z "$resolved_model" ]]; then
		resolved_model=$(~/.aidevops/agents/scripts/model-availability-helper.sh resolve sonnet 2>/dev/null || echo "")
	fi
	if [[ -z "$resolved_model" ]]; then
		echo "[pulse-wrapper] dispatch_triage_reviews: model resolution failed (opus and sonnet unavailable)" >>"$LOGFILE"
	fi

	# Parse markdown-format state entries:
	#   ## owner/repo            ← repo slug header
	#   - Issue #NNN: ... [status: **needs-review**] ...
	# Build pipe-separated list: issue_num|repo_slug|repo_path
	local current_slug="" current_path="" candidates=""
	while IFS= read -r line; do
		# Match repo slug headers: "## owner/repo"
		if [[ "$line" =~ ^##[[:space:]]+([^[:space:]]+/[^[:space:]]+) ]]; then
			current_slug="${BASH_REMATCH[1]}"
			current_path=$(jq -r --arg s "$current_slug" '.initialized_repos[]? | select(.slug == $s) | .path' "$repos_json" 2>/dev/null || echo "")
			# Expand ~ in path
			current_path="${current_path/#\~/$HOME}"
			continue
		fi
		# Match needs-review issue lines
		if [[ "$line" == *"**needs-review**"* && "$line" =~ Issue\ #([0-9]+) ]]; then
			local issue_num="${BASH_REMATCH[1]}"
			if [[ -n "$current_slug" && -n "$current_path" ]]; then
				candidates="${candidates}${issue_num}|${current_slug}|${current_path}"$'\n'
			fi
		fi
	done <"$state_file"

	local candidate_count=0
	if [[ -n "$candidates" ]]; then
		candidate_count=$(printf '%s' "$candidates" | grep -c '|' 2>/dev/null || echo 0)
	fi
	echo "[pulse-wrapper] dispatch_triage_reviews: parsed ${candidate_count} candidates from state file" >>"$LOGFILE"

	[[ -n "$candidates" ]] || {
		echo "[pulse-wrapper] dispatch_triage_reviews: 0 candidates found in state file" >>"$LOGFILE"
		printf '%d\n' "$available"
		return 0
	}

	while IFS='|' read -r issue_num repo_slug repo_path; do
		[[ -n "$issue_num" && -n "$repo_slug" ]] || continue
		[[ "$available" -gt 0 && "$triage_count" -lt "$triage_max" ]] || break

		# ── t1916: Triage is exempt from the cryptographic approval gate ──
		# Triage is read + comment — it helps the maintainer decide whether to
		# approve the issue for implementation dispatch. The approval gate is
		# enforced on implementation dispatch (dispatch_with_dedup), not here.
		# Previously blocked by GH#17490 (t1894), restored in GH#17705 (t1916).

		# ── t1894: Sandboxed triage — pre-fetch all GitHub data deterministically ──
		local prefetch_file=""
		prefetch_file=$(mktemp)

		local issue_json=""
		issue_json=$(gh issue view "$issue_num" --repo "$repo_slug" \
			--json number,title,body,author,labels,createdAt,updatedAt 2>/dev/null) || issue_json="{}"

		local issue_comments=""
		issue_comments=$(gh api "repos/${repo_slug}/issues/${issue_num}/comments" \
			--jq '[.[] | {author: .user.login, body: .body, created: .created_at}]' 2>/dev/null) || issue_comments="[]"

		# Check if this is a PR
		local pr_diff="" pr_files="" is_pr=""
		is_pr=$(gh pr view "$issue_num" --repo "$repo_slug" --json number --jq '.number' 2>/dev/null) || is_pr=""
		if [[ -n "$is_pr" ]]; then
			pr_diff=$(gh pr diff "$issue_num" --repo "$repo_slug" 2>/dev/null | head -500) || pr_diff=""
			pr_files=$(gh pr view "$issue_num" --repo "$repo_slug" --json files --jq '[.files[].path]' 2>/dev/null) || pr_files="[]"
		fi

		# Recent closed issues for duplicate detection
		local recent_closed=""
		recent_closed=$(gh issue list --repo "$repo_slug" --state closed \
			--json number,title --limit 30 --jq '.[].title' 2>/dev/null) || recent_closed=""

		# Git log for affected files (if PR)
		local git_log_context=""
		if [[ -n "$is_pr" && -n "$repo_path" && -d "$repo_path" ]]; then
			git_log_context=$(git -C "$repo_path" log --oneline -10 2>/dev/null) || git_log_context=""
		fi

		# Build the prompt with all pre-fetched data
		local issue_body=""
		issue_body=$(echo "$issue_json" | jq -r '.body // "No body"' 2>/dev/null) || issue_body="No body"

		cat >"$prefetch_file" <<PREFETCH_EOF
You are reviewing issue/PR #${issue_num} in ${repo_slug}.

## ISSUE_METADATA
${issue_json}

## ISSUE_BODY
${issue_body}

## ISSUE_COMMENTS
${issue_comments}

## PR_DIFF
${pr_diff:-Not a PR or no diff available}

## PR_FILES
${pr_files:-[]}

## RECENT_CLOSED
${recent_closed:-No recent closed issues}

## GIT_LOG
${git_log_context:-No git log available}

---

Now read the triage-review.md agent instructions and produce your review.
PREFETCH_EOF

		# ── Launch sandboxed agent (no Bash, no gh, no network) ──
		# NOTE: headless-runtime-helper.sh does not yet support --allowed-tools.
		# Tool restriction is enforced by the triage-review.md agent file frontmatter
		# in runtimes that respect YAML tool declarations (Claude Code, OpenCode).
		local review_output_file=""
		review_output_file=$(mktemp)

		local model_flag=""
		if [[ -n "$resolved_model" ]]; then
			model_flag="--model $resolved_model"
		fi

		# t1894: Lock external contributor issues during triage
		lock_issue_for_worker "$issue_num" "$repo_slug"

		# Run agent with triage-review prompt — agent file restricts to Read/Glob/Grep
		# shellcheck disable=SC2086
		"$HEADLESS_RUNTIME_HELPER" run \
			--role worker \
			--session-key "triage-review-${issue_num}" \
			--dir "$repo_path" \
			$model_flag \
			--title "Sandboxed triage review: Issue #${issue_num}" \
			--prompt-file "$prefetch_file" </dev/null >"$review_output_file" 2>&1

		rm -f "$prefetch_file"

		# ── Post-process: post the review comment (deterministic) ──
		local review_text=""
		review_text=$(cat "$review_output_file")
		rm -f "$review_output_file"

		if [[ -n "$review_text" && ${#review_text} -gt 50 ]]; then
			# ── Safety filter: NEVER post raw sandbox/infrastructure output ──
			# If the LLM failed (quota, timeout, garbled), the output contains
			# sandbox startup logs, execution metadata, or internal paths.
			# These MUST be discarded — posting them leaks sensitive infra data.
			local has_infra_markers="false"
			if echo "$review_text" | grep -qE '\[SANDBOX\]|\[INFO\] Executing|timeout=[0-9]+s|network_blocked=|sandbox-exec-helper|/opt/homebrew/|opencode run '; then
				has_infra_markers="true"
			fi

			# Extract just the review portion (starts with ## Review:)
			local clean_review=""
			clean_review=$(echo "$review_text" | sed -n '/^## Review:/,$ p')

			if [[ -n "$clean_review" ]]; then
				# Re-check extracted review for infra leaks (belt-and-suspenders)
				if echo "$clean_review" | grep -qE '\[SANDBOX\]|\[INFO\] Executing|timeout=[0-9]+s|network_blocked=|sandbox-exec-helper'; then
					echo "[pulse-wrapper] SECURITY: triage review for #${issue_num} contained infrastructure markers after extraction — suppressed" >>"$LOGFILE"
				else
					gh issue comment "$issue_num" --repo "$repo_slug" \
						--body "$clean_review" >/dev/null 2>&1 || true
					echo "[pulse-wrapper] Posted sandboxed triage review for #${issue_num} in ${repo_slug}" >>"$LOGFILE"
				fi
			elif [[ "$has_infra_markers" == "true" ]]; then
				# No ## Review: header AND infra markers present — raw sandbox output, discard entirely
				echo "[pulse-wrapper] SECURITY: triage review for #${issue_num} was raw sandbox output — suppressed (${#review_text} chars)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Triage review for #${issue_num} had no ## Review: header and no infra markers — suppressed to be safe (${#review_text} chars)" >>"$LOGFILE"
			fi
		else
			echo "[pulse-wrapper] Triage review for #${issue_num} produced no usable output (${#review_text} chars)" >>"$LOGFILE"
		fi

		# Unlock issue after triage
		unlock_issue_after_worker "$issue_num" "$repo_slug"

		sleep 2
		triage_count=$((triage_count + 1))
		available=$((available - 1))
	done <<<"$candidates"

	local slots_remaining="$available"
	echo "[pulse-wrapper] dispatch_triage_reviews: dispatched ${triage_count} triage workers (${slots_remaining} slots remaining)" >>"$LOGFILE"

	printf '%d\n' "$available"
	return 0
}

#######################################
# Relabel status:needs-info issues where contributor has replied
#
# Reads the pre-fetched needs-info reply status from STATE_FILE and
# transitions replied issues to needs-maintainer-review.
#
# Arguments:
#   $1 - repos JSON path (default: REPOS_JSON)
#
# Exit code: always 0
#######################################
relabel_needs_info_replies() {
	local repos_json="${1:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local state_file="${STATE_FILE:-}"
	[[ -f "$state_file" ]] || return 0

	# Parse replied items from pre-fetched state (format: number|slug)
	while IFS='|' read -r issue_num repo_slug; do
		[[ -n "$issue_num" && -n "$repo_slug" ]] || continue

		gh issue edit "$issue_num" --repo "$repo_slug" \
			--remove-label "status:needs-info" \
			--add-label "needs-maintainer-review" 2>/dev/null || true
		gh issue comment "$issue_num" --repo "$repo_slug" \
			--body "Contributor replied to the information request. Relabeled to \`needs-maintainer-review\` for re-evaluation." \
			2>/dev/null || true
	done < <(grep -oP '(?<=replied\|)\d+\|[^\n]+' "$state_file" 2>/dev/null || true)

	return 0
}

#######################################
# Dispatch FOSS contribution workers when idle capacity exists (t1702)
#
# Reads the pre-fetched FOSS scan from STATE_FILE and dispatches workers
# for eligible repos. Respects the FOSS_MAX_DISPATCH_PER_CYCLE cap and
# available worker slots.
#
# Arguments:
#   $1 - available worker slots (AVAILABLE)
#   $2 - repos JSON path (default: REPOS_JSON)
#
# Outputs: updated available count to stdout (one integer)
# Exit code: always 0
#######################################
dispatch_foss_workers() {
	local available="$1"
	local repos_json="${2:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local foss_count=0
	local foss_max="${FOSS_MAX_DISPATCH_PER_CYCLE:-2}"

	[[ "$available" =~ ^[0-9]+$ ]] || available=0

	while IFS='|' read -r foss_slug foss_path; do
		[[ -n "$foss_slug" && -n "$foss_path" ]] || continue
		[[ "$available" -gt 0 && "$foss_count" -lt "$foss_max" ]] || break

		# Pre-dispatch eligibility check (budget + rate limit)
		~/.aidevops/agents/scripts/foss-contribution-helper.sh check "$foss_slug" >/dev/null 2>&1 || continue

		# Scan for a suitable issue
		local labels_filter foss_issue foss_issue_num foss_issue_title
		labels_filter=$(jq -r --arg slug "$foss_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .foss_config.labels_filter // ["help wanted","good first issue","bug"] | join(",")' \
			"$repos_json" 2>/dev/null || echo "help wanted")
		foss_issue=$(gh issue list --repo "$foss_slug" --state open \
			--label "${labels_filter%%,*}" --limit 1 \
			--json number,title --jq '.[0] | "\(.number)|\(.title)"' 2>/dev/null) || foss_issue=""
		[[ -n "$foss_issue" ]] || continue

		foss_issue_num="${foss_issue%%|*}"
		foss_issue_title="${foss_issue#*|}"

		local disclosure_flag=""
		local disclosure
		disclosure=$(jq -r --arg slug "$foss_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .foss_config.disclosure // true' \
			"$repos_json" 2>/dev/null || echo "true")
		[[ "$disclosure" == "true" ]] && disclosure_flag=" Include AI disclosure note in the PR."

		~/.aidevops/agents/scripts/headless-runtime-helper.sh run \
			--role worker \
			--session-key "foss-${foss_slug}-${foss_issue_num}" \
			--dir "$foss_path" \
			--title "FOSS: ${foss_slug} #${foss_issue_num}: ${foss_issue_title}" \
			--prompt "/full-loop Implement issue #${foss_issue_num} (https://github.com/${foss_slug}/issues/${foss_issue_num}) -- ${foss_issue_title}. This is a FOSS contribution.${disclosure_flag} After completion, run: foss-contribution-helper.sh record ${foss_slug} <tokens_used>" \
			</dev/null >>"/tmp/pulse-foss-${foss_issue_num}.log" 2>&1 &
		sleep 2

		foss_count=$((foss_count + 1))
		available=$((available - 1))
	done < <(jq -r '.initialized_repos[] | select(.foss == true and (.foss_config.blocklist // false) == false) | "\(.slug)|\(.path)"' \
		"$repos_json" 2>/dev/null || true)

	printf '%d\n' "$available"
	return 0
}

#######################################
# Sync GitHub issue refs to TODO.md and close completed issues for a repo
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path (canonical path on disk)
#
# Exit code: always 0
#######################################
sync_todo_refs_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

	/bin/bash "${script_dir}/issue-sync-helper.sh" pull --repo "$repo_slug" 2>&1 || true
	/bin/bash "${script_dir}/issue-sync-helper.sh" close --repo "$repo_slug" 2>&1 || true
	/bin/bash "${script_dir}/issue-sync-helper.sh" reopen --repo "$repo_slug" 2>&1 || true
	git -C "$repo_path" diff --quiet TODO.md 2>/dev/null || {
		git -C "$repo_path" add TODO.md &&
			git -C "$repo_path" commit -m "chore: sync GitHub issue refs to TODO.md [skip ci]" &&
			git -C "$repo_path" push
	} 2>/dev/null || true
	return 0
}

# Only run main when executed directly, not when sourced.
# The pulse agent sources this file to access helper functions
# (check_external_contributor_pr, check_permission_failure_pr)
# without triggering the full pulse lifecycle.
#
# Shell-portable source detection (GH#3931):
#   bash: BASH_SOURCE[0] differs from $0 when sourced
#   zsh:  BASH_SOURCE is undefined; use ZSH_EVAL_CONTEXT instead
#         (contains "file" when sourced, "toplevel" when executed)
_pulse_is_sourced() {
	if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" != "${0}" ]]
	elif [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
		[[ ":${ZSH_EVAL_CONTEXT}:" == *":file:"* ]]
	else
		return 1
	fi
}
if ! _pulse_is_sourced; then
	main "$@"
fi
