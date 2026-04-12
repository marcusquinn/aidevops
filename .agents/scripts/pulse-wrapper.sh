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
# Phase 0 (t1963): diagnostic flags must return instantly. Skip jitter
# when the first arg is --self-check or --dry-run (or PULSE_DRY_RUN=1)
# so CI, post-install verification, and interactive debugging aren't
# delayed by up to 30 s of random sleep.
_pulse_skip_jitter=0
if [[ "${1:-}" == "--self-check" || "${1:-}" == "--dry-run" || "${PULSE_DRY_RUN:-0}" == "1" ]]; then
	_pulse_skip_jitter=1
fi
if [[ "$_pulse_skip_jitter" -eq 0 && "$PULSE_JITTER_MAX" =~ ^[0-9]+$ && "$PULSE_JITTER_MAX" -gt 0 ]]; then
	# $RANDOM is 0-32767; modulo gives 0 to PULSE_JITTER_MAX
	jitter_seconds=$((RANDOM % (PULSE_JITTER_MAX + 1)))
	if [[ "$jitter_seconds" -gt 0 ]]; then
		sleep "$jitter_seconds"
	fi
fi
unset _pulse_skip_jitter

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

# Phase 1 (t1966, GH#18364): sourced leaf modules extracted from this file.
# Each module has an _PULSE_<CLUSTER>_LOADED include guard so re-sourcing is a no-op.
# Order does not matter for correctness (bash defers function resolution until
# call time). Listed in plan §3 cluster order for readability.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-model-routing.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-instance-lock.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-meta-parse.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-repo-meta.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-routines.sh"
# Phase 2 (t1967, GH#18367): 4 leaves-with-fan-in extracted from this file.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-queue-governor.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-nmr-approval.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dep-graph.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-fast-fail.sh"
# Phase 3 (t1971, GH#18372): 4 operational plumbing clusters extracted from this file.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-capacity.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-watchdog.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-capacity-alloc.sh"
# Phase 4 (t1972, GH#18378): pr-gates + merge cycle co-extracted into one module.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge.sh"
# Phase 5 (t1973, GH#18380): cleanup + issue-reconcile extracted into two modules.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-cleanup.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-issue-reconcile.sh"

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
# Source credentials.sh for API keys (GH#17546)
# Launchd plists bake env vars at setup time — they go stale when
# credentials.sh is later updated. Sourcing at runtime ensures the
# pulse always uses the current provider API keys, regardless of what
# the plist embedded. Model config is now derived from the pool +
# routing table (GH#17769), not env vars.
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
# GH#17769: PULSE_MODEL and AIDEVOPS_HEADLESS_MODELS are deprecated.
# Model routing is now derived from the routing table at runtime and resolved
# through model-availability-helper.sh so pulse follows the same provider
# fallback logic as workers.
# Backward compat: if legacy env vars are still set, log deprecation warnings.
MODEL_AVAILABILITY_HELPER="${MODEL_AVAILABILITY_HELPER:-${SCRIPT_DIR}/model-availability-helper.sh}"
if [[ -n "${PULSE_MODEL:-}" ]]; then
	echo "[pulse-wrapper] WARN: PULSE_MODEL env var is deprecated (v3.7+). Model routing is now automatic via routing table + availability checks. Remove this export from credentials.sh." >&2
fi
if [[ -n "${AIDEVOPS_HEADLESS_MODELS:-}" ]]; then
	echo "[pulse-wrapper] WARN: AIDEVOPS_HEADLESS_MODELS env var is deprecated (v3.7+). Model routing is now automatic via routing table + availability checks. Remove this export from credentials.sh." >&2
fi
if [[ -z "${PULSE_MODEL:-}" ]] && [[ -x "$MODEL_AVAILABILITY_HELPER" ]]; then
	PULSE_MODEL=$("$MODEL_AVAILABILITY_HELPER" resolve sonnet --quiet 2>/dev/null || true)
fi
# Absolute fallback if routing resolution fails entirely.
PULSE_MODEL="${PULSE_MODEL:-anthropic/claude-sonnet-4-6}"
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
# GH#18264: tracks whether this process successfully acquired the instance lock.
# release_instance_lock() checks this flag so it only closes FD 9 and removes
# LOCKDIR when this process actually owns the lock.
_LOCK_OWNED=false
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
# PULSE_MODEL is derived from routing table above (GH#17769) — no longer user-configurable
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
DEP_GRAPH_CACHE_FILE="${DEP_GRAPH_CACHE_FILE:-${HOME}/.aidevops/.agent-workspace/supervisor/dep-graph-cache.json}" # Dependency graph cache (t1935)
DEP_GRAPH_CACHE_TTL_SECS="${DEP_GRAPH_CACHE_TTL_SECS:-300}"                                                        # Rebuild graph if older than 5 min (t1935)

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

# Flock deadlock health state (GH#18141) — set by acquire_instance_lock() when
# a non-pulse process holds the flock. Persisted to pulse-health.json so the
# session greeting can warn the user. Cleared on next clean cycle.
_PULSE_HEALTH_DEADLOCK_DETECTED=false
_PULSE_HEALTH_DEADLOCK_HOLDER_PID=""
_PULSE_HEALTH_DEADLOCK_HOLDER_CMD=""
_PULSE_HEALTH_DEADLOCK_BOUNCES=0
_PULSE_HEALTH_DEADLOCK_RECOVERED=false

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

#######################################
# Ensure log and workspace directories exist
#######################################
mkdir -p "$(dirname "$PIDFILE")"
mkdir -p "$PULSE_DIR"

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

	# Remove issues with non-dispatchable labels (supervisor, tracking, review gates)
	local filtered_json
	filtered_json=$(echo "$issue_json" | jq '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("needs-maintainer-review") or index("routine-tracking") or index("on hold") or index("blocked")) | not)]')

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
		) 9>&- &
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

# _compute_struggle_ratio provided by worker-lifecycle-common.sh

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

# check_session_count: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate the duplicate. The shared version
# returns the count; callers handle warning logs independently.

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
	local -a pulse_cmd=("$HEADLESS_RUNTIME_HELPER" run --role pulse --session-key supervisor-pulse --dir "$PULSE_DIR" --title "Supervisor Pulse" --agent Automate --prompt "$prompt" --tier sonnet)
	if [[ -n "$PULSE_MODEL" ]]; then
		pulse_cmd+=(--model "$PULSE_MODEL")
	fi
	"${pulse_cmd[@]}" >>"$LOGFILE" 2>&1 9>&- &

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
	# t1955: Don't self-assign on issue creation — let dispatch_with_dedup handle
	# assignment. Self-assigning creates a phantom claim that triggers stale recovery
	# on other runners, producing audit trail gaps.
	if gh_create_issue --repo "$aidevops_slug" \
		--title "perf: simplification debt stalled — LLM sweep needed ($(date -u +%Y-%m-%d))" \
		--label "simplification-debt" $sweep_review_label --label "tier:reasoning" \
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

# Create a follow-up simplification-debt issue when Qlty smells persist after
# a simplification PR merges (t1912). Each re-queue creates a NEW issue (not a
# reopen) for a clean audit trail of each pass.
#
# Arguments:
#   $1 - aidevops_slug (owner/repo)
#   $2 - file_path (repo-relative)
#   $3 - remaining_smells (integer count)
#   $4 - pass_count (current pass number, already incremented)
#   $5 - prev_issue_num (the issue that just closed)
# Returns: 0 on success, 1 on failure. Outputs created issue number to stdout.
_create_requeue_issue() {
	local aidevops_slug="$1"
	local file_path="$2"
	local remaining_smells="$3"
	local pass_count="$4"
	local prev_issue_num="$5"
	local max_passes="${SIMPLIFICATION_MAX_PASSES:-3}"

	# Determine tier based on pass count — escalate to reasoning after max passes
	local tier_label="tier:standard"
	local escalation_note=""
	if [[ "$pass_count" -ge "$max_passes" ]]; then
		tier_label="tier:reasoning"
		escalation_note="

### Escalation note

This file has been through ${pass_count} simplification passes but ${remaining_smells} Qlty smells remain. Previous passes achieved partial reduction but the remaining complexity likely requires **architectural decomposition** (extracting modules, splitting concerns) rather than incremental tightening. Consider a different approach than the previous passes took."
	fi

	local issue_title="simplification: re-queue ${file_path} (pass ${pass_count}, ${remaining_smells} smells remaining)"

	# NOTE: Uses IFS read instead of $(cat <<HEREDOC) to avoid Bash 3.2 bug
	# where literal ) inside a heredoc nested in $() is misinterpreted as
	# closing the command substitution. macOS ships Bash 3.2 by default.
	local issue_body
	IFS= read -r -d '' issue_body <<REQUEUE_BODY_EOF || true
## Post-merge smell verification (automated — t1912)

**File:** \`${file_path}\`
**Qlty smells remaining:** ${remaining_smells}
**Pass:** ${pass_count} of ${max_passes} max
**Previous issue:** #${prev_issue_num}

The previous simplification pass (issue #${prev_issue_num}) merged successfully but Qlty still reports ${remaining_smells} smell(s) on this file. This follow-up issue was created automatically by the post-merge verification step.

### Context from previous pass

Review issue #${prev_issue_num} for what the previous attempt accomplished and what trade-offs were made. Build on that work rather than starting from scratch.

### Proposed action

1. Run \`~/.qlty/bin/qlty smells --all "${file_path}"\` to identify the specific remaining smells
2. Address the flagged complexity — reduce function length, extract helpers, simplify control flow
3. Verify: \`~/.qlty/bin/qlty smells --all 2>&1 | grep '${file_path}' | grep -c . | grep -q '^0$'\` (report \`SKIP\` if Qlty unavailable)${escalation_note}

### Verification

- Qlty smells resolved or reduced for the target file
- Content preservation: all task IDs, URLs, code blocks present before and after
- ShellCheck clean (for .sh files)
REQUEUE_BODY_EOF

	# Append signature footer
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "Claude Code" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	issue_body="${issue_body}${sig_footer}"

	local created_number=""
	# shellcheck disable=SC2086
	created_number=$(gh_create_issue --repo "$aidevops_slug" \
		--title "$issue_title" \
		--label "simplification-debt" --label "$tier_label" --label "auto-dispatch" \
		--body "$issue_body" 2>/dev/null | grep -oE '[0-9]+$') || {
		echo "[pulse-wrapper] _create_requeue_issue: failed to create re-queue issue for ${file_path}" >>"$LOGFILE"
		return 1
	}

	echo "[pulse-wrapper] _create_requeue_issue: created #${created_number} for ${file_path} (pass ${pass_count}, ${remaining_smells} smells, ${tier_label})" >>"$LOGFILE"
	echo "$created_number"
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

		# Post-merge smell verification (t1912): check if Qlty still flags this file.
		# If smells persist after the simplification PR merged, create a follow-up
		# issue so the file gets another pass. Qlty CLI is optional — if not
		# installed, this step is skipped silently and the function behaves as before.
		local full_path="${repo_path}/${file_path}"
		local qlty_cmd=""
		if command -v qlty >/dev/null 2>&1; then
			qlty_cmd="qlty"
		elif [[ -x "${HOME}/.qlty/bin/qlty" ]]; then
			qlty_cmd="${HOME}/.qlty/bin/qlty"
		fi

		if [[ -n "$qlty_cmd" ]]; then
			local remaining_smells
			remaining_smells=$("$qlty_cmd" smells --all "$full_path" 2>/dev/null | grep -c '^[^ ]' || echo "0")

			if [[ "$remaining_smells" -gt 0 ]]; then
				# Check for existing open re-queue issue before creating a new one
				if ! _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
					local requeue_result=""
					requeue_result=$(_create_requeue_issue "$aidevops_slug" "$file_path" "$remaining_smells" "$new_passes" "$issue_num") || true
					if [[ -n "$requeue_result" ]]; then
						echo "[pulse-wrapper] backfill: re-queued ${file_path} → #${requeue_result} (${remaining_smells} smells remain after #${issue_num})" >>"$LOGFILE"
					fi
				else
					echo "[pulse-wrapper] backfill: ${file_path} has ${remaining_smells} smells after #${issue_num} but open issue already exists — skipping re-queue" >>"$LOGFILE"
				fi
			else
				echo "[pulse-wrapper] backfill: ${file_path} — Qlty clean after #${issue_num} (pass ${new_passes})" >>"$LOGFILE"
			fi
		fi
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
- Qlty smells resolved for the target file: \`~/.qlty/bin/qlty smells --all 2>&1 | grep '${file_path}' | grep -c . | grep -q '^0$'\` (report \`SKIP\` if Qlty is unavailable, not \`FAIL\`)
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
	# t1955: Don't self-assign on issue creation — let dispatch_with_dedup handle
	# assignment. Self-assigning creates a phantom claim that triggers stale recovery.
	if [[ "$needs_recheck" == true ]]; then
		# shellcheck disable=SC2086
		gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "simplification-debt" $review_label --label "tier:standard" --label "recheck-simplicity" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	else
		# shellcheck disable=SC2086
		gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "simplification-debt" $review_label --label "tier:standard" \
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
		# t1955: Don't self-assign — let dispatch_with_dedup handle assignment.
		# shellcheck disable=SC2086
		if gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "simplification-debt" $review_label_sh \
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

#######################################
# Check if nesting depth violation count is approaching the CI threshold.
# Creates a warning issue when within the buffer to prevent CI regressions
# before they happen (GH#17808 — regression guard for Complexity Analysis CI).
#
# The CI check uses a global awk counter (not per-function) that counts all
# if/for/while/until/case across the entire file without resetting at function
# boundaries. This function replicates that logic to detect proximity.
#
# Arguments:
#   $1 - aidevops_path (repo root)
#   $2 - aidevops_slug (owner/repo)
#   $3 - maintainer (GitHub login)
# Returns: 0 always (best-effort)
#######################################
_check_ci_nesting_threshold_proximity() {
	local aidevops_path="$1"
	local aidevops_slug="$2"
	local maintainer="$3"
	local buffer=5

	# Read threshold from config file (same logic as CI check)
	local threshold=260
	local conf_file="${aidevops_path}/.agents/configs/complexity-thresholds.conf"
	if [[ -f "$conf_file" ]]; then
		local val
		val=$(grep '^NESTING_DEPTH_THRESHOLD=' "$conf_file" | cut -d= -f2 || true)
		if [[ -n "$val" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
			threshold="$val"
		fi
	fi

	# Count violations using same awk logic as CI (global counter, no function resets)
	local violations=0
	local lint_files
	lint_files=$(git -C "$aidevops_path" ls-files '*.sh' 2>/dev/null |
		grep -v 'node_modules\|vendor\|\.git' |
		sed "s|^|${aidevops_path}/|" || true)
	if [[ -z "$lint_files" ]]; then
		return 0
	fi

	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		[[ -f "$file" ]] || continue
		local max_depth
		max_depth=$(awk '
			BEGIN { depth=0; max_depth=0 }
			/^[[:space:]]*#/ { next }
			/[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if(depth>max_depth) max_depth=depth }
			/[[:space:]]*(fi|done|esac)[[:space:]]*$/ || /^[[:space:]]*(fi|done|esac)$/ { if(depth>0) depth-- }
			END { print max_depth }
		' "$file" 2>/dev/null) || max_depth=0
		if [[ "$max_depth" -gt 8 ]]; then
			violations=$((violations + 1))
		fi
	done <<<"$lint_files"

	local warn_at=$((threshold - buffer))
	if [[ "$violations" -le "$warn_at" ]]; then
		echo "[pulse-wrapper] CI nesting threshold proximity: ${violations}/${threshold} violations (buffer: ${buffer}) — OK" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] CI nesting threshold proximity: ${violations}/${threshold} violations — within ${buffer} of threshold, creating warning issue" >>"$LOGFILE"

	# Check for existing open warning issue to avoid duplicates
	local existing
	existing=$(gh issue list --repo "$aidevops_slug" \
		--state open \
		--search "in:title \"CI nesting threshold proximity\"" \
		--json number --jq 'length' 2>/dev/null) || existing="0"
	if [[ "${existing:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] CI nesting threshold proximity: warning issue already exists — skipping" >>"$LOGFILE"
		return 0
	fi

	local headroom=$((threshold - violations))
	local issue_body
	issue_body="## CI Nesting Threshold Proximity Warning

The shell nesting depth violation count is within **${buffer}** of the CI threshold.

- **Current violations**: ${violations}
- **CI threshold**: ${threshold} (from \`.agents/configs/complexity-thresholds.conf\`)
- **Headroom remaining**: ${headroom}

### Why this matters

The \`Complexity Analysis\` CI check fails when nesting depth violations exceed the threshold. When PRs add new scripts with deep nesting, they push the count over the threshold and block all open PRs. This happened 6 times in a short window (GH#17808).

### Recommended actions

1. Reduce nesting depth in the highest-depth scripts (run \`complexity-scan-helper.sh scan\` to identify them)
2. Or bump the threshold in \`.agents/configs/complexity-thresholds.conf\` with a documented rationale

### Files to check

Run locally to see current violators:
\`\`\`bash
git ls-files '*.sh' | while read -r f; do
  d=\$(awk 'BEGIN{d=0;m=0} /^[[:space:]]*#/{next} /[[:space:]]*(if|for|while|until|case)[[:space:]]/{d++;if(d>m)m=d} /[[:space:]]*(fi|done|esac)[[:space:]]*\$||/^[[:space:]]*(fi|done|esac)\$/{if(d>0)d--} END{print m}' \"\$f\")
  [ \"\$d\" -gt 8 ] && echo \"\$d \$f\"
done | sort -rn | head -20
\`\`\`"

	# Append signature footer
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	issue_body="${issue_body}${sig_footer}"

	# t1955: Don't self-assign — let dispatch_with_dedup handle assignment.
	gh_create_issue --repo "$aidevops_slug" \
		--title "CI nesting threshold proximity: ${violations}/${threshold} violations (${headroom} headroom)" \
		--label "bug" --label "auto-dispatch" --label "tier:standard" \
		--body "$issue_body" >/dev/null 2>&1 || true

	echo "[pulse-wrapper] CI nesting threshold proximity: warning issue created (${violations}/${threshold})" >>"$LOGFILE"
	return 0
}

run_weekly_complexity_scan() {
	local repos_json="$REPOS_JSON"
	local aidevops_slug="marcusquinn/aidevops"

	local now_epoch
	now_epoch=$(date +%s)

	_complexity_scan_check_interval "$now_epoch" || return 0

	# Permission gate: only admin users may create simplification issues.
	# write/maintain collaborators are excluded — they could otherwise use
	# bot-created simplification-debt issues to bypass the maintainer assignee
	# gate (GH#16786, GH#18197). On personal repos, admin = repo owner only.
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null) || current_user=""
	if [[ -n "$current_user" ]]; then
		local perm_level
		perm_level=$(gh api "repos/${aidevops_slug}/collaborators/${current_user}/permission" \
			--jq '.permission' 2>/dev/null) || perm_level=""
		case "$perm_level" in
		admin) ;; # allowed — repo owner/admin only
		*)
			echo "[pulse-wrapper] Complexity scan: skipped — user '$current_user' has '$perm_level' permission on $aidevops_slug (need admin)" >>"$LOGFILE"
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

	# GH#17848: Pull latest state before scanning to avoid false-positive
	# proximity warnings from stale local checkouts. The proximity guard and
	# tree-change check both read working-tree files, so a stale checkout
	# (e.g., local repo hasn't pulled a threshold-bump PR yet) produces
	# incorrect violation counts and may create spurious warning issues.
	# Fail-closed: if pull fails, skip this scan cycle rather than proceeding
	# with stale data (which would reintroduce the exact problem we're fixing).
	# Do NOT update COMPLEXITY_SCAN_LAST_RUN on skip — the next cycle retries.
	# GIT_TERMINAL_PROMPT=0 prevents credential prompts from hanging the pulse.
	# timeout 30 prevents network hangs from blocking the pulse cycle.
	if git -C "$aidevops_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		if ! GIT_TERMINAL_PROMPT=0 timeout 30 \
			git -C "$aidevops_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1 9>&-; then
			echo "[pulse-wrapper] Complexity scan: git pull failed for ${aidevops_path} — skipping this cycle to avoid stale-state warnings" >>"$LOGFILE"
			return 0
		fi
	fi

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

	# CI threshold proximity guard (GH#17808): warn before nesting depth
	# violations reach the CI threshold. Runs independently of tree change
	# so it catches regressions even when no files changed in this cycle.
	_check_ci_nesting_threshold_proximity "$aidevops_path" "$aidevops_slug" "$maintainer" || true

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

		# Phase 5: Ratchet-check — lower thresholds when simplification wins accumulate (t1913)
		# Runs after backfill so closed issues are reflected in violation counts.
		# Creates a chore/ratchet-down PR when gap >= 5 (default).
		local ratchet_output
		ratchet_output=$("$scan_helper" ratchet-check "$aidevops_path" 2>>"$LOGFILE") || true
		if [[ -n "$ratchet_output" ]]; then
			echo "[pulse-wrapper] ratchet-check: proposals available" >>"$LOGFILE"
			echo "$ratchet_output" >>"$LOGFILE"
			# Check if a ratchet-down PR already exists to avoid duplicates
			local ratchet_pr_exists
			ratchet_pr_exists=$(gh pr list --repo "$aidevops_slug" \
				--state open \
				--search "in:title \"chore: ratchet-down complexity thresholds\"" \
				--json number --jq 'length' 2>/dev/null) || ratchet_pr_exists="0"
			if [[ "${ratchet_pr_exists:-0}" -eq 0 ]]; then
				echo "[pulse-wrapper] ratchet-check: creating ratchet-down issue (t1913)" >>"$LOGFILE"
				gh_create_issue --repo "$aidevops_slug" \
					--title "chore: ratchet-down complexity thresholds" \
					--label "code-quality" --label "auto-dispatch" --label "tier:standard" \
					--body "## Automated ratchet-down (t1913)

Simplification wins have accumulated. The following thresholds can be lowered:

\`\`\`
${ratchet_output}
\`\`\`

### Worker Guidance

**Files to Modify:**
- \`EDIT: .agents/configs/complexity-thresholds.conf\` — lower the thresholds listed above

**Implementation Steps:**
1. For each proposed threshold, update the value in \`complexity-thresholds.conf\`
2. Add a ratchet-down comment above the updated value documenting the change (e.g., \`# Ratcheted down to NNN (GH#NNNN): actual violations NNN + 2 buffer\`)
3. Do NOT remove existing bump history comments — they are the audit trail

**Verification:**
\`\`\`bash
# Confirm thresholds updated
grep -E 'FUNCTION_COMPLEXITY_THRESHOLD|NESTING_DEPTH_THRESHOLD|FILE_SIZE_THRESHOLD|BASH32_COMPAT_THRESHOLD' .agents/configs/complexity-thresholds.conf
# Confirm CI would pass with new values
.agents/scripts/complexity-scan-helper.sh ratchet-check . 5
\`\`\`" >/dev/null 2>&1 || true
			else
				echo "[pulse-wrapper] ratchet-check: ratchet-down PR already open, skipping issue creation" >>"$LOGFILE"
			fi
		else
			echo "[pulse-wrapper] ratchet-check: no ratchet-down available (thresholds already tight)" >>"$LOGFILE"
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

# count_active_workers: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate divergence with stats-functions.sh.

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

	# Layer 4: open or merged PR evidence for this issue/task — if a worker
	# already produced a PR (open or merged), don't dispatch another worker.
	# Previously only checked --state merged, missing open PRs entirely.
	local dedup_helper_output=""
	if [[ -x "$dedup_helper" ]]; then
		if dedup_helper_output=$("$dedup_helper" has-open-pr "$issue_number" "$repo_slug" "$issue_title" 2>>"$LOGFILE"); then
			if [[ -n "$dedup_helper_output" ]]; then
				echo "[pulse-wrapper] Dedup: ${dedup_helper_output}" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Dedup: PR evidence already exists for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
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
		# t1927: Stale recovery must record fast-fail. When _is_stale_assignment()
		# recovers a stale assignment (silent worker timeout), the dedup helper
		# outputs STALE_RECOVERED on stdout. Without recording this as a failure,
		# the fast-fail counter stays at 0 and the issue loops through unlimited
		# dispatch→timeout→stale-recovery cycles. Observed: 8+ dispatches in 6h
		# with 0 PRs and 0 fast-fail entries (GH#17700, GH#17701, GH#17702).
		if [[ "$assigned_output" == *STALE_RECOVERED* ]]; then
			echo "[pulse-wrapper] Dedup: stale recovery detected for #${issue_number} in ${repo_slug} — recording fast-fail (t1927)" >>"$LOGFILE"
			fast_fail_record "$issue_number" "$repo_slug" "stale_timeout" || true
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
# Lock an issue (and any linked PRs) to prevent mid-flight prompt
# injection (t1894, t1934). Once a worker is dispatched, the issue
# state is frozen — any comment arriving after dispatch is either
# noise or adversarial. Lock the conversation to prevent influence.
# Also locks open PRs linked to the issue (worker may read PR comments).
# Non-fatal: locking failure doesn't block dispatch.
#######################################
lock_issue_for_worker() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	# Lock the issue itself
	gh issue lock "$issue_num" --repo "$slug" --reason "$reason" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Locked #${issue_num} in ${slug} during worker execution (t1934)" >>"$LOGFILE"

	# Lock any open PRs linked to this issue (t1934: PRs have same injection surface)
	_lock_linked_prs "$issue_num" "$slug" "$reason"

	return 0
}

#######################################
# Lock open PRs that reference a given issue number (t1934).
# Finds PRs whose title contains the issue number pattern
# (e.g., "GH#123" or "#123") and locks their conversations.
# Non-fatal: best-effort, failures are logged but ignored.
#######################################
_lock_linked_prs() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"

	local pr_numbers
	pr_numbers=$(gh pr list --repo "$slug" --state open \
		--json number,title --jq \
		"[.[] | select(.title | test(\"(GH)?#${issue_num}([^0-9]|$)\"))] | .[].number" \
		--limit 5 2>/dev/null) || pr_numbers=""

	local pr_num
	while IFS= read -r pr_num; do
		[[ -n "$pr_num" && "$pr_num" =~ ^[0-9]+$ ]] || continue
		gh issue lock "$pr_num" --repo "$slug" --reason "$reason" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Locked PR #${pr_num} in ${slug} (linked to issue #${issue_num}) (t1934)" >>"$LOGFILE"
	done <<<"$pr_numbers"

	return 0
}

#######################################
# Unlock an issue (and any linked PRs) after worker completion or
# failure (t1894, t1934). Symmetric with lock_issue_for_worker.
# Non-fatal: unlocking failure is logged but doesn't block.
#######################################
unlock_issue_after_worker() {
	local issue_num="$1"
	local slug="$2"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	# Unlock the issue itself
	gh issue unlock "$issue_num" --repo "$slug" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Unlocked #${issue_num} in ${slug} after worker completion (t1934)" >>"$LOGFILE"

	# Unlock any open PRs linked to this issue (symmetric with lock)
	_unlock_linked_prs "$issue_num" "$slug"

	return 0
}

#######################################
# Unlock open PRs that reference a given issue number (t1934).
# Symmetric with _lock_linked_prs. Non-fatal.
#######################################
_unlock_linked_prs() {
	local issue_num="$1"
	local slug="$2"

	local pr_numbers
	pr_numbers=$(gh pr list --repo "$slug" --state open \
		--json number,title --jq \
		"[.[] | select(.title | test(\"(GH)?#${issue_num}([^0-9]|$)\"))] | .[].number" \
		--limit 5 2>/dev/null) || pr_numbers=""

	local pr_num
	while IFS= read -r pr_num; do
		[[ -n "$pr_num" && "$pr_num" =~ ^[0-9]+$ ]] || continue
		gh issue unlock "$pr_num" --repo "$slug" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Unlocked PR #${pr_num} in ${slug} (linked to issue #${issue_num}) (t1934)" >>"$LOGFILE"
	done <<<"$pr_numbers"

	return 0
}

#######################################
# Triage content-hash dedup (GH#17746).
#
# Without dedup, NMR issues are re-triaged every pulse cycle:
# lock → agent → no output → unlock → repeat. This wastes tokens,
# API calls, and pollutes the issue timeline with lock/unlock events.
#
# Strategy: hash the issue body + human comments (excluding bot and
# review comments). Cache the hash. Skip triage when content is
# unchanged. Re-triage when the author edits the body or adds a
# new comment.
#######################################
TRIAGE_CACHE_DIR="${TRIAGE_CACHE_DIR:-${HOME}/.aidevops/.agent-workspace/tmp/triage-cache}"

# Compute a content hash from issue body + human comments.
# Excludes github-actions[bot] comments and our own triage reviews
# (## Review: prefix) so that only author/contributor changes trigger
# a re-triage.
#
# Args: $1=issue_num, $2=repo_slug, $3=body (pre-fetched), $4=comments_json (pre-fetched)
# Outputs: sha256 hash to stdout
_triage_content_hash() {
	local issue_num="$1"
	local repo_slug="$2"
	local body="$3"
	local comments_json="$4"

	# Filter to human comments: exclude github-actions[bot] and triage reviews.
	# GH#17873: Match broader review header pattern (## *Review*) to exclude
	# reviews posted with variant headers, consistent with the extraction regex.
	local human_comments=""
	human_comments=$(printf '%s' "$comments_json" | jq -r \
		'[.[] | select(.author != "github-actions[bot]" and .author != "github-actions") | select(.body | test("^## .*[Rr]eview") | not) | .body] | join("\n---\n")' \
		2>/dev/null) || human_comments=""

	printf '%s\n%s' "$body" "$human_comments" | shasum -a 256 | cut -d' ' -f1
	return 0
}

# Check if triage content hash matches the cached value.
# Returns 0 if content is unchanged (skip triage), 1 if changed or uncached.
#
# Args: $1=issue_num, $2=repo_slug, $3=current_hash
_triage_is_cached() {
	local issue_num="$1"
	local repo_slug="$2"
	local current_hash="$3"
	local slug_safe="${repo_slug//\//_}"
	local cache_file="${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.hash"

	[[ -f "$cache_file" ]] || return 1

	local cached_hash=""
	cached_hash=$(cat "$cache_file" 2>/dev/null) || return 1
	[[ "$cached_hash" == "$current_hash" ]] && return 0
	return 1
}

# Update the triage content hash cache after a triage attempt.
#
# Args: $1=issue_num, $2=repo_slug, $3=content_hash
_triage_update_cache() {
	local issue_num="$1"
	local repo_slug="$2"
	local content_hash="$3"
	local slug_safe="${repo_slug//\//_}"

	mkdir -p "$TRIAGE_CACHE_DIR" 2>/dev/null || true
	printf '%s' "$content_hash" >"${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.hash" 2>/dev/null || true
	# Reset failure counter on successful cache write
	rm -f "${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.failures" 2>/dev/null || true
	return 0
}

#######################################
# GH#17827: Triage failure retry cap.
#
# When triage fails (no review posted), the GH#17873 fix intentionally
# skips caching the content hash so the next cycle retries. But if the
# failure is persistent (e.g., model quota, formatting issues), this
# creates an infinite lock→agent→fail→unlock loop that pollutes the
# issue timeline with dozens of lock/unlock events.
#
# Solution: track failure count per issue+hash. After TRIAGE_MAX_RETRIES
# failures on the same content hash, cache it anyway to break the loop.
# The triage-failed label remains so maintainers can identify these.
# A new human comment changes the hash, resetting the counter.
#######################################
TRIAGE_MAX_RETRIES="${TRIAGE_MAX_RETRIES:-3}"

# Increment failure counter and return whether retry cap is reached.
# Returns 0 if cap reached (should cache anyway), 1 if retries remain.
#
# Args: $1=issue_num, $2=repo_slug, $3=content_hash
_triage_increment_failure() {
	local issue_num="$1"
	local repo_slug="$2"
	local content_hash="$3"
	local slug_safe="${repo_slug//\//_}"
	local fail_file="${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.failures"

	mkdir -p "$TRIAGE_CACHE_DIR" 2>/dev/null || true

	local current_count=0
	local stored_hash=""
	if [[ -f "$fail_file" ]]; then
		# Format: "hash:count"
		stored_hash=$(cut -d: -f1 "$fail_file" 2>/dev/null) || stored_hash=""
		current_count=$(cut -d: -f2 "$fail_file" 2>/dev/null) || current_count=0
		# Reset counter if hash changed (new content since last failure)
		if [[ "$stored_hash" != "$content_hash" ]]; then
			current_count=0
		fi
	fi

	current_count=$((current_count + 1))
	printf '%s:%d' "$content_hash" "$current_count" >"$fail_file" 2>/dev/null || true

	if [[ "$current_count" -ge "$TRIAGE_MAX_RETRIES" ]]; then
		return 0
	fi
	return 1
}

#######################################
# GH#17827: Check if an NMR issue is awaiting a contributor reply.
#
# When the last human comment on an NMR issue is from a repo collaborator
# (maintainer asking for clarification), the ball is in the contributor's
# court. Triage adds no value — the issue needs the contributor to respond,
# not another automated review. Skipping triage here avoids the lock/unlock
# noise entirely.
#
# Args: $1=issue_comments (JSON array from gh api)
#       $2=repo_slug
# Returns: 0 if awaiting contributor reply (skip triage), 1 otherwise
#######################################
_triage_awaiting_contributor_reply() {
	local issue_comments="$1"
	local repo_slug="$2"

	# Get the last human comment (exclude bots and triage reviews)
	local last_human_author=""
	last_human_author=$(printf '%s' "$issue_comments" | jq -r \
		'[.[] | select(.author != "github-actions[bot]" and .author != "github-actions") | select(.body | test("^## .*[Rr]eview") | not)] | last | .author // ""' \
		2>/dev/null) || last_human_author=""

	[[ -n "$last_human_author" ]] || return 1

	# Check if the last commenter is a repo collaborator (maintainer/member)
	local perm_level=""
	perm_level=$(gh api "repos/${repo_slug}/collaborators/${last_human_author}/permission" \
		--jq '.permission // ""' 2>/dev/null) || perm_level=""

	case "$perm_level" in
	admin | maintain | write)
		# Last comment is from a collaborator — awaiting contributor reply
		return 0
		;;
	esac

	return 1
}

#######################################
# GH#17779: Helper for _is_task_committed_to_main.
# Reads commit hashes from stdin, applies the two-stage planning filter
# (subject-line prefix + path-based), and prints the count of real
# implementation commits to stdout.
#
# Args:
#   $1 - repo_path (local path to the repo)
# Stdin: one commit hash per line
#######################################
_count_impl_commits() {
	local repo_path_inner="$1"
	local match_count_inner=0
	local commit_hash_inner
	while IFS= read -r commit_hash_inner; do
		[[ -z "$commit_hash_inner" ]] && continue
		local is_planning_only_inner=true
		local touched_path_inner
		while IFS= read -r touched_path_inner; do
			[[ -z "$touched_path_inner" ]] && continue
			case "$touched_path_inner" in
			TODO.md | todo/* | AGENTS.md | .agents/AGENTS.md | */docs/* | docs/*) ;;
			*)
				is_planning_only_inner=false
				break
				;;
			esac
		done < <(git -C "$repo_path_inner" diff-tree --no-commit-id --name-only -r "$commit_hash_inner" 2>/dev/null)
		if [[ "$is_planning_only_inner" == "false" ]]; then
			match_count_inner=$((match_count_inner + 1))
		fi
	done
	echo "$match_count_inner"
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
	#
	# GH#17779: Split patterns into two arrays by match scope:
	#   subject_patterns — Patterns 1 & 2: task IDs that belong in the commit
	#     subject line only. git --grep searches subject+body, so body
	#     cross-references (e.g. "feeds scope-aware extraction (t101)") cause
	#     false positives. Use --format '%H %s' + grep -w for subject-only match.
	#   message_patterns — Patterns 3-5: closing keywords / squash-merge suffixes
	#     that legitimately appear in commit bodies. Keep using --grep.
	local -a subject_patterns=() # Patterns 1, 2: subject-only matching
	local -a message_patterns=() # Patterns 3, 4, 5: full-message matching

	# Pattern 1: tNNN task ID from title (e.g., "t153: add dark mode")
	# Subject-only: body cross-references like "(t101)" must not match.
	# grep -w enforces word boundaries — prevents t101 matching t1010.
	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+' | head -1) || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		subject_patterns+=("$task_id_match")
	fi

	# Pattern 2: GH#NNN from title (e.g., "GH#17574: fix pulse dispatch")
	# Subject-only: body mentions of other GH# IDs must not match.
	local gh_id_match
	gh_id_match=$(printf '%s' "$issue_title" | grep -oE '^GH#[0-9]+' | head -1) || gh_id_match=""
	if [[ -n "$gh_id_match" ]]; then
		subject_patterns+=("$gh_id_match")
	fi

	# Pattern 3: GitHub squash-merge suffix "(#NNN)" — only matches commit
	# titles, not body references. The bare "#NNN" pattern previously caused
	# false positives: any commit that MENTIONED an issue (e.g., "Relabeled
	# #17659 and #17660") would match, closing issues whose work hadn't been
	# done. Restrict to the "(#NNN)" suffix that GitHub adds to squash merges.
	# t1927: Escape parens for -E regex — unescaped parens are capture groups
	# that match bare "#NNN" in commit bodies (evidence tables, PR descriptions).
	# With \( \) the pattern only matches the literal "(#NNN)" suffix.
	message_patterns+=("\\(#${issue_number}\\)")

	# Pattern 4: "Closes #NNN" / "Fixes #NNN" in commit messages — these
	# are the conventional patterns for commits that resolve an issue.
	# \b word boundary prevents #17779 from matching #177790 (longer IDs).
	message_patterns+=("[Cc]loses #${issue_number}\\b")
	message_patterns+=("[Ff]ixes #${issue_number}\\b")

	# No patterns to search — cannot determine if committed
	if [[ ${#subject_patterns[@]} -eq 0 && ${#message_patterns[@]} -eq 0 ]]; then
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
		git -C "$repo_path" fetch origin main --quiet 2>/dev/null 9>&- || true
	else
		return 1
	fi

	# Search recent commits on origin/main for any matching pattern.
	# GH#17707: Filter out planning-only commits that mention task IDs but
	# don't contain implementation work. Two-stage filter:
	#   1. Subject-line filter: drop obvious planning prefixes (chore: claim, plan:)
	#   2. Path-based filter: for remaining commits, check if ALL touched paths
	#      are planning-only files (TODO.md, todo/*, AGENTS.md). If so, exclude.
	# This preserves real docs: commits while filtering true planning-only commits.
	#
	# GH#17779: subject_patterns use subject-only matching (--format + grep -w)
	# to avoid false positives from body cross-references. message_patterns keep
	# using --grep (full message) because closing keywords belong in commit bodies.

	# Search subject_patterns (Patterns 1 & 2): subject-only via --format + grep -w
	# This prevents body cross-references from triggering false positives.
	# Bash 3.2 + set -u: "${arr[@]}" on an empty array triggers "unbound variable".
	# Guard with length check first.
	local pattern
	if [[ ${#subject_patterns[@]} -gt 0 ]]; then
		for pattern in "${subject_patterns[@]}"; do
			local match_count=0
			# Fetch all commits as "HASH SUBJECT", filter planning subjects, then
			# grep -w for word-boundary match on the subject portion only.
			match_count=$(_count_impl_commits "$repo_path" < <(
				git -C "$repo_path" log origin/main --since="$created_at" \
					--format='%H %s' |
					grep -vE '^[0-9a-f]+ (chore: claim|plan:|p[0-9]+:)' |
					grep -wE "$pattern" |
					cut -d' ' -f1 || true
			))
			if [[ "$match_count" -gt 0 ]]; then
				echo "[pulse-wrapper] _is_task_committed_to_main: found ${match_count} commit(s) matching subject pattern '${pattern}' on origin/main since ${created_at} for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
				return 0
			fi
		done
	fi # subject_patterns guard

	# Search message_patterns (Patterns 3-5): full-message via --grep
	# Closing keywords and squash-merge suffixes legitimately appear in bodies.
	# Bash 3.2 + set -u: guard empty array iteration (same as subject_patterns above).
	if [[ ${#message_patterns[@]} -gt 0 ]]; then
		for pattern in "${message_patterns[@]}"; do
			local match_count=0
			match_count=$(_count_impl_commits "$repo_path" < <(
				git -C "$repo_path" log origin/main --since="$created_at" \
					-E --grep="$pattern" --format='%H %s' |
					grep -vE '^[0-9a-f]+ (chore: claim|plan:|p[0-9]+:)' |
					cut -d' ' -f1 || true
			))
			if [[ "$match_count" -gt 0 ]]; then
				echo "[pulse-wrapper] _is_task_committed_to_main: found ${match_count} commit(s) matching message pattern '${pattern}' on origin/main since ${created_at} for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
				return 0
			fi
		done
	fi # message_patterns guard

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

#######################################
# Idempotent comment posting: race-safe primitive for gate comments.
#
# Multiple pulse instances (different maintainers/machines) can race
# when posting gate comments (consolidation, simplification, blocker).
# Label-only guards have a TOCTOU window: both pulses read "no label",
# both post, producing duplicate comments (observed: GH#17898).
#
# This function checks existing comments for a marker string before
# posting. Fails closed on API errors (never posts if it can't confirm
# the comment is absent).
#
# Arguments:
#   $1 - entity_number (issue or PR number)
#   $2 - repo_slug (owner/repo)
#   $3 - marker (unique string to grep for in existing comments)
#   $4 - comment_body (full comment text to post)
#   $5 - entity_type ("issue" or "pr", default "issue")
#
# Returns:
#   0 - comment posted successfully OR already existed (idempotent)
#   1 - API error fetching comments (fail-closed, caller should retry)
#   2 - missing arguments
#
# Usage:
#   _gh_idempotent_comment "$issue_number" "$repo_slug" \
#       "## Issue Consolidation Needed" "$comment_body"
#######################################
_gh_idempotent_comment() {
	local entity_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local comment_body="$4"
	local entity_type="${5:-issue}"

	if [[ -z "$entity_number" || -z "$repo_slug" || -z "$marker" || -z "$comment_body" ]]; then
		echo "[pulse-wrapper] _gh_idempotent_comment: missing arguments (entity=$entity_number repo=$repo_slug marker_len=${#marker})" >>"$LOGFILE"
		return 2
	fi

	# Fetch existing comments and check for marker.
	# Use the REST API for issues; gh pr view for PRs.
	local existing_comments=""
	if [[ "$entity_type" == "pr" ]]; then
		existing_comments=$(gh pr view "$entity_number" --repo "$repo_slug" \
			--json comments --jq '.comments[].body' 2>/dev/null)
	else
		existing_comments=$(gh api "repos/${repo_slug}/issues/${entity_number}/comments" \
			--jq '.[].body' 2>/dev/null)
	fi
	local api_exit=$?

	if [[ $api_exit -ne 0 ]]; then
		# API error — fail closed. Never post when we can't confirm absence.
		echo "[pulse-wrapper] _gh_idempotent_comment: API error (exit=$api_exit) fetching comments for #${entity_number} in ${repo_slug} — skipping (fail closed)" >>"$LOGFILE"
		return 1
	fi

	# Check if marker already exists in any comment
	if printf '%s' "$existing_comments" | grep -qF "$marker"; then
		echo "[pulse-wrapper] _gh_idempotent_comment: marker already present on #${entity_number} in ${repo_slug} — skipping duplicate" >>"$LOGFILE"
		return 0
	fi

	# Marker not found — safe to post
	if [[ "$entity_type" == "pr" ]]; then
		gh pr comment "$entity_number" --repo "$repo_slug" \
			--body "$comment_body" 2>/dev/null || true
	else
		gh issue comment "$entity_number" --repo "$repo_slug" \
			--body "$comment_body" 2>/dev/null || true
	fi

	echo "[pulse-wrapper] _gh_idempotent_comment: posted gate comment on #${entity_number} in ${repo_slug} (marker: ${marker:0:40}...)" >>"$LOGFILE"
	return 0
}

#######################################
# Issue consolidation: detect multi-comment issues where substantive
# comments (not dispatch/approval machinery) have materially changed
# the issue's scope since the body was written.
#
# Threshold: ISSUE_CONSOLIDATION_COMMENT_THRESHOLD (default 2) substantive
# comments with >500 chars each (excludes dispatch claims, approval sigs,
# bot comments, and recovery comments).
#
# When triggered, adds a "needs-consolidation" label and posts a comment
# explaining the action. The issue is skipped for dispatch until a
# consolidation worker merges the comment thread into a clean issue.
#
# Arguments: $1 issue_number, $2 repo_slug
# Returns: 0 if consolidation is needed, 1 if not
#######################################
ISSUE_CONSOLIDATION_COMMENT_THRESHOLD="${ISSUE_CONSOLIDATION_COMMENT_THRESHOLD:-2}"
ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS="${ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS:-500}"

_issue_needs_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"

	local issue_labels
	issue_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
	# Skip if consolidation was already done (label removed = consolidated)
	if [[ ",$issue_labels," == *",consolidated,"* ]]; then
		return 1
	fi
	# If already labeled, re-evaluate with the current (tighter) filter.
	# If the issue no longer triggers, auto-clear the label so it becomes
	# dispatchable without manual intervention. This handles the case where
	# a filter improvement makes previously-flagged issues pass.
	local was_already_labeled=false
	if [[ ",$issue_labels," == *",needs-consolidation,"* ]]; then
		was_already_labeled=true
	fi

	# Count substantive comments (>MIN_CHARS, not from bots or dispatch machinery).
	# Only human-authored scope-changing comments should count. Operational
	# comments (dispatch claims, kill notices, crash reports, stale recovery,
	# triage reviews, provenance metadata) are noise — workers generate dozens
	# of these on issues that fail repeatedly, falsely triggering consolidation.
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --jq '.' 2>/dev/null) || comments_json="[]"

	local substantive_count=0
	local min_chars="$ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS"
	substantive_count=$(printf '%s' "$comments_json" | jq --argjson min "$min_chars" '
		[.[] | select(
			(.body | length) >= $min
			and (.user.type != "Bot")
			and (.body | test("DISPATCH_CLAIM nonce=") | not)
			and (.body | test("^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker") | not)
			and (.body | test("^<!-- (nmr-hold|aidevops-signed|ops:start|provenance:start)") | not)
			and (.body | test("CLAIM_RELEASED reason=") | not)
			and (.body | test("^(Worker failed:|## Worker Watchdog Kill)") | not)
			and (.body | test("^(\\*\\*)?Stale assignment recovered") | not)
			and (.body | test("^## (Triage Review|Completion Summary|Large File Simplification Gate|Issue Consolidation Needed|Additional Review Feedback|Cascade Tier Escalation)") | not)
			and (.body | test("^This quality-debt issue was auto-generated by") | not)
			and (.body | test("<!-- MERGE_SUMMARY -->") | not)
			and (.body | test("^Closing:") | not)
			and (.body | test("^Worker failed: orphan worktree") | not)
			and (.body | test("sudo aidevops approve") | not)
			and (.body | test("^_Automated by") | not)
		)] | length
	' 2>/dev/null) || substantive_count=0

	if [[ "$substantive_count" -ge "$ISSUE_CONSOLIDATION_COMMENT_THRESHOLD" ]]; then
		return 0
	fi

	# Auto-clear: if the issue was previously labeled but no longer triggers
	# (e.g., filter improvement excluded operational comments that were false
	# positives), remove the label so it becomes dispatchable immediately.
	if [[ "$was_already_labeled" == "true" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-label "needs-consolidation" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Consolidation gate cleared for #${issue_number} (${repo_slug}) — substantive_count=${substantive_count} below threshold=${ISSUE_CONSOLIDATION_COMMENT_THRESHOLD}" >>"$LOGFILE"
	fi
	return 1
}

#######################################
# Re-evaluate all needs-consolidation labeled issues across pulse repos.
# Issues filtered out by list_dispatchable_issue_candidates_json (needs-*
# exclusion) never reach dispatch_with_dedup, so the auto-clear logic in
# _issue_needs_consolidation can't fire. This pass runs them through the
# current filter and removes the label if they no longer trigger.
# Lightweight: one gh issue list per repo + one _issue_needs_consolidation
# call per labeled issue. Runs every cycle before the early fill floor.
#######################################
_reevaluate_consolidation_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_cleared=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "needs-consolidation" \
			--json number --limit 50 2>/dev/null) || issues_json="[]"
		local count
		count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || count=0
		[[ "$count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$count" ]]; do
			local num
			num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
			i=$((i + 1))
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			# _issue_needs_consolidation returns 1 (no consolidation needed)
			# AND auto-clears the label when was_already_labeled=true
			if ! _issue_needs_consolidation "$num" "$slug"; then
				total_cleared=$((total_cleared + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation re-evaluation: cleared ${total_cleared} stale needs-consolidation label(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Re-evaluate needs-simplification labeled issues across pulse repos.
# Same pattern as _reevaluate_consolidation_labels: issues filtered out
# by the needs-* exclusion never reach dispatch_with_dedup, so the
# auto-clear at the end of _issue_targets_large_files can't fire.
# This pass re-evaluates them and clears the label when the file is
# now excluded (lockfile, JSON config) or below threshold.
#######################################
_reevaluate_simplification_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_cleared=0
	while IFS='|' read -r slug rpath; do
		[[ -n "$slug" && -n "$rpath" ]] || continue
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "needs-simplification" \
			--json number --limit 50 2>/dev/null) || issues_json="[]"
		local count
		count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || count=0
		[[ "$count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$count" ]]; do
			local num
			num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
			i=$((i + 1))
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			local body
			body=$(gh issue view "$num" --repo "$slug" \
				--json body --jq '.body // ""' 2>/dev/null) || body=""
			# _issue_targets_large_files returns 1 (no large files) AND
			# auto-clears the label when was_already_labeled
			if ! _issue_targets_large_files "$num" "$slug" "$body" "$rpath"; then
				total_cleared=$((total_cleared + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Simplification re-evaluation: cleared ${total_cleared} stale needs-simplification label(s)" >>"$LOGFILE"
	fi
	return 0
}

_dispatch_issue_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"

	# Add label so we don't re-trigger on next cycle
	gh label create "needs-consolidation" \
		--repo "$repo_slug" \
		--description "Issue needs comment consolidation before dispatch" \
		--color "FBCA04" \
		--force 2>/dev/null || true
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "needs-consolidation" 2>/dev/null || true

	# Post comment explaining the hold (idempotent — safe against concurrent pulses)
	local comment_body="## Issue Consolidation Needed

This issue has accumulated multiple substantive comments that modify the original scope. To give the implementing worker clean context, a consolidation pass will merge the issue body and comment addenda into a single coherent specification.

**What happens next:**
1. A consolidation worker reads the body + all substantive comments
2. Creates a new issue with the merged spec (body-only, no comment archaeology)
3. Links the new issue back here: \"Supersedes #${issue_number}\"
4. This issue is closed as superseded

The implementing worker gets a single clean body with all context inline.

_Automated by \`_dispatch_issue_consolidation()\` in pulse-wrapper.sh_"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"## Issue Consolidation Needed" "$comment_body"

	echo "[pulse-wrapper] Issue consolidation: flagged #${issue_number} in ${repo_slug} for comment consolidation" >>"$LOGFILE"
	return 0
}

#######################################
# Large-file simplification gate: check if an issue body references
# files that exceed a line count threshold, indicating the worker will
# spend most of its context budget just reading the target file.
#
# When a large file is detected, the function:
#   1. Checks if a simplification task already exists for that file
#   2. If not, logs the finding for the simplification routine to pick up
#   3. Adds a label so the issue is held until simplification runs
#
# Arguments: $1 issue_number, $2 repo_slug, $3 issue_body, $4 repo_path
# Returns: 0 if gate triggered (hold dispatch), 1 if clear
#######################################
LARGE_FILE_LINE_THRESHOLD="${LARGE_FILE_LINE_THRESHOLD:-2000}"

_issue_targets_large_files() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body="$3"
	local repo_path="$4"

	[[ -n "$issue_body" ]] || return 1
	[[ -d "$repo_path" ]] || return 1

	local issue_labels
	issue_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""

	# GH#18042: Never gate simplification tasks behind the large-file gate.
	# Issues tagged "simplification" or "simplification-debt" exist to reduce
	# the file — blocking them creates a deadlock where the file can never be
	# simplified because the simplification issue is held by the gate.
	# If the label was already applied (e.g., before this fix), auto-clear it.
	if [[ ",$issue_labels," == *",simplification,"* ]] ||
		[[ ",$issue_labels," == *",simplification-debt,"* ]]; then
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			if gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-label "needs-simplification" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Simplification gate auto-cleared for #${issue_number} (${repo_slug}) — issue is itself a simplification task (GH#18042)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] WARN: failed to remove needs-simplification label from #${issue_number} (${repo_slug}); will retry next cycle (GH#18042)" >>"$LOGFILE"
			fi
		fi
		# Always return 1 (don't gate) — the issue IS simplification work
		# regardless of whether the label removal succeeded.
		return 1
	fi

	# Skip if already labeled (avoid re-checking every cycle)
	if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
		return 0
	fi
	# Skip if simplification was already done
	if [[ ",$issue_labels," == *",simplified,"* ]]; then
		return 1
	fi

	# GH#17958: Skip if issue is already dispatched (worker actively running).
	# A second pulse cycle can re-evaluate the same issue and post a spurious
	# simplification comment even though the worker is mid-implementation.
	# The gate should only fire for issues that haven't been claimed yet.
	if [[ ",$issue_labels," == *",status:queued,"* ]] ||
		[[ ",$issue_labels," == *",status:in-progress,"* ]]; then
		return 1
	fi
	# Also skip if assigned with origin:worker — worker was dispatched even if
	# status label hasn't been applied yet (race window between assign and label).
	if [[ ",$issue_labels," == *",origin:worker,"* ]]; then
		local assignee_count
		assignee_count=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json assignees --jq '.assignees | length' 2>/dev/null) || assignee_count="0"
		if [[ "$assignee_count" -gt 0 ]]; then
			return 1
		fi
	fi

	# Extract file paths from "EDIT:" and "Files to Modify" patterns in body.
	# Patterns: "EDIT: path/to/file.sh:123-456", "- EDIT: path/to/file"
	local file_paths
	file_paths=$(printf '%s' "$issue_body" | grep -oE '(EDIT|NEW|File):?\s+[`"]?\.?agents/scripts/[^`"[:space:],:]+' 2>/dev/null |
		sed 's/^[A-Z]*:*[[:space:]]*//' | sed 's/^[`"]//' | sed 's/:.*//' | sort -u) || file_paths=""

	# Also check for backtick-quoted filenames that look like script paths.
	# GH#17897: Only match backtick paths on lines that look like implementation
	# targets (list items, "File:" markers), not paths mentioned as evidence in
	# review feedback prose. Previously, files cited in Gemini review comments
	# (e.g., "aidevops.sh hashes were updated") triggered the large-file gate
	# even though they weren't implementation targets.
	local backtick_paths
	backtick_paths=$(printf '%s' "$issue_body" | grep -E '^\s*[-*]\s|^(EDIT|NEW|File):' 2>/dev/null |
		grep -oE '`[^`]*\.(sh|py|js|ts)[^`]*`' 2>/dev/null |
		tr -d '`' | grep -v '^#' | sed 's/:.*//' | sort -u) || backtick_paths=""

	# Combine and deduplicate
	local all_paths
	all_paths=$(printf '%s\n%s' "$file_paths" "$backtick_paths" | sort -u | grep -v '^$') || all_paths=""

	[[ -n "$all_paths" ]] || return 1

	# Files that are large by nature and can't/shouldn't be "simplified":
	# lockfiles, generated data, JSON/YAML configs, binary-adjacent formats.
	# These should never block dispatch — workers don't modify them directly.
	# GH#17897: Also skip all .json/.yaml/.yml/.toml/.xml/.csv data files —
	# these are config/data, not code. The simplification routine doesn't
	# target them, so gating dispatch on their size is incorrect.
	local _skip_pattern='(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Cargo\.lock|Gemfile\.lock|poetry\.lock|simplification-state\.json|\.min\.(js|css)$|\.json$|\.yaml$|\.yml$|\.toml$|\.xml$|\.csv$)'

	local found_large=false
	local large_files=""
	local large_file_paths=""
	while IFS= read -r fpath; do
		[[ -z "$fpath" ]] && continue

		# Skip non-simplifiable files (lockfiles, generated data, configs)
		local basename_fpath
		basename_fpath=$(basename "$fpath")
		if printf '%s' "$basename_fpath" | grep -qE "$_skip_pattern" 2>/dev/null; then
			continue
		fi

		# Resolve path relative to repo
		local full_path=""
		if [[ -f "${repo_path}/${fpath}" ]]; then
			full_path="${repo_path}/${fpath}"
		elif [[ -f "${repo_path}/.agents/${fpath}" ]]; then
			full_path="${repo_path}/.agents/${fpath}"
		elif [[ -f "${repo_path}/.${fpath}" ]]; then
			full_path="${repo_path}/.${fpath}"
		else
			continue
		fi

		local line_count=0
		line_count=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ') || line_count=0
		if [[ "$line_count" -ge "$LARGE_FILE_LINE_THRESHOLD" ]]; then
			found_large=true
			large_files="${large_files}${fpath} (${line_count} lines), "
			large_file_paths="${large_file_paths}${fpath}\n"
		fi
	done <<<"$all_paths"

	if [[ "$found_large" == "true" ]]; then
		# Add label to hold dispatch
		gh label create "needs-simplification" \
			--repo "$repo_slug" \
			--description "Issue targets large file(s) needing simplification first" \
			--color "D93F0B" \
			--force 2>/dev/null || true
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-simplification" 2>/dev/null || true

		large_files="${large_files%, }"

		# Create simplification-debt issues for each large file immediately
		# (don't wait for the daily complexity scan). Dedup: skip if an open
		# simplification-debt issue already mentions this file.
		local _created_issues=""
		while IFS= read -r _lf_path; do
			[[ -z "$_lf_path" ]] && continue
			local _lf_basename
			_lf_basename=$(basename "$_lf_path")
			# Check if a simplification-debt issue already exists for this file
			local _existing
			_existing=$(gh issue list --repo "$repo_slug" --state open \
				--label "simplification-debt" --search "$_lf_basename" \
				--json number --jq '.[0].number // empty' --limit 5 2>/dev/null) || _existing=""
			if [[ -n "$_existing" ]]; then
				_created_issues="${_created_issues}#${_existing} (existing), "
				continue
			fi
			# Create the simplification-debt issue now
			local _new_num
			_new_num=$(gh issue create --repo "$repo_slug" \
				--title "simplification-debt: ${_lf_path} exceeds ${LARGE_FILE_LINE_THRESHOLD} lines" \
				--label "simplification-debt,auto-dispatch,origin:worker" \
				--body "## What
Simplify \`${_lf_path}\` — currently over ${LARGE_FILE_LINE_THRESHOLD} lines. Break into smaller, focused modules.

## Why
Issue #${issue_number} is blocked by the large-file gate. Workers dispatched against this file spend most of their context budget reading it, leaving insufficient capacity for implementation.

## How
- EDIT: \`${_lf_path}\`
- Extract cohesive function groups into separate files
- Keep a thin orchestrator in the original file that sources/imports the extracted modules
- Verify: \`wc -l ${_lf_path}\` should be below ${LARGE_FILE_LINE_THRESHOLD}

_Created by large-file simplification gate (pulse-wrapper.sh)_" \
				--json number --jq '.number' 2>/dev/null) || _new_num=""
			if [[ -n "$_new_num" ]]; then
				_created_issues="${_created_issues}#${_new_num} (new), "
				echo "[pulse-wrapper] Created simplification-debt issue #${_new_num} for ${_lf_path} (blocking #${issue_number})" >>"$LOGFILE"
			fi
		done < <(printf '%b' "$large_file_paths")

		_created_issues="${_created_issues%, }"
		local simplification_body="## Large File Simplification Gate

This issue references file(s) exceeding ${LARGE_FILE_LINE_THRESHOLD} lines: ${large_files}.

Workers dispatched against large files spend most of their context budget reading the file, leaving insufficient capacity for implementation.

**Simplification issues:** ${_created_issues:-none created}

**Status:** Held from dispatch until simplification completes. The \`needs-simplification\` label will be removed automatically when the target file(s) are below threshold.

_Automated by \`_issue_targets_large_files()\` in pulse-wrapper.sh_"

		_gh_idempotent_comment "$issue_number" "$repo_slug" \
			"## Large File Simplification Gate" "$simplification_body"

		echo "[pulse-wrapper] Large-file gate: #${issue_number} in ${repo_slug} targets ${large_files}" >>"$LOGFILE"
		return 0
	fi

	# If was_already_labeled but no large files found (e.g., all files now
	# excluded by skip pattern or simplified below threshold), auto-clear.
	if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-label "needs-simplification" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Simplification gate cleared for #${issue_number} (${repo_slug}) — no large files after exclusion filter" >>"$LOGFILE"
	fi

	return 1
}

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
		--json number,title,state,labels,assignees 2>/dev/null) || issue_meta_json=""
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

	if echo "$issue_meta_json" | jq -e '.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("on hold") or index("blocked"))' >/dev/null 2>&1; then
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

	# t1927: Blocked-by enforcement — skip dispatch if a dependency is unresolved.
	# Fetches issue body and parses for "blocked-by:tNNN" or "Blocked by #NNN".
	local _dispatch_issue_body
	_dispatch_issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || _dispatch_issue_body=""
	if [[ -n "$_dispatch_issue_body" ]] && is_blocked_by_unresolved "$_dispatch_issue_body" "$repo_slug" "$issue_number"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unresolved blocked-by dependency (t1927)" >>"$LOGFILE"
		return 1
	fi

	# Pre-dispatch: issue consolidation check. If an issue has accumulated
	# multiple substantive comments that change scope (not dispatch/approval
	# machinery), dispatch a consolidation worker first to merge everything
	# into a clean issue body. This prevents implementing workers from spending
	# tokens reconstructing scope from comment archaeology.
	if _issue_needs_consolidation "$issue_number" "$repo_slug"; then
		_dispatch_issue_consolidation "$issue_number" "$repo_slug" "$repo_path"
		echo "[dispatch_with_dedup] Dispatch deferred for #${issue_number} in ${repo_slug}: issue needs comment consolidation" >>"$LOGFILE"
		return 1
	fi

	# Pre-dispatch: large-file simplification gate. If the issue body
	# references files that exceed LARGE_FILE_LINE_THRESHOLD, create a
	# blocked-by simplification task instead of dispatching. Workers
	# shouldn't pay the complexity tax of navigating a 12,000-line file.
	if _issue_targets_large_files "$issue_number" "$repo_slug" "$_dispatch_issue_body" "$repo_path"; then
		echo "[dispatch_with_dedup] Dispatch deferred for #${issue_number} in ${repo_slug}: targets large file(s), simplification gate" >>"$LOGFILE"
		return 1
	fi

	# All 7 dedup layers — cannot be skipped
	if check_dispatch_dedup "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" "$self_login"; then
		echo "[dispatch_with_dedup] Dedup guard blocked #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		return 1
	fi

	# Replace existing assignees with dispatching runner (GH#17777).
	# Previous behavior only added self (--add-assignee), leaving the original
	# assignee (typically the issue creator) co-assigned. This created ambiguity
	# about ownership and confused dedup layer 6 (is_assigned) when status:queued
	# made passive owner assignments appear active.
	local -a _edit_flags=(--add-assignee "$self_login" --add-label "status:queued" --add-label "origin:worker")
	local _prev_login
	while IFS= read -r _prev_login; do
		[[ -n "$_prev_login" && "$_prev_login" != "$self_login" ]] && _edit_flags+=(--remove-assignee "$_prev_login")
	done < <(printf '%s' "$issue_meta_json" | jq -r '.assignees[].login' 2>/dev/null)

	gh issue edit "$issue_number" --repo "$repo_slug" \
		"${_edit_flags[@]}" 2>/dev/null || true

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
	# headless-runtime-helper.sh select --role worker, which resolves the
	# worker model from the routing table / local override (respecting
	# backoff DB, auth availability, provider allowlists, and rotation).
	# The resolved model name
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
	local dispatch_tier="standard"
	local dispatch_model_tier="sonnet"
	local issue_labels_csv
	issue_labels_csv=$(echo "$issue_meta_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels_csv=""
	case ",$issue_labels_csv," in
	*,tier:reasoning,* | *,tier:thinking,*)
		dispatch_tier="reasoning"
		dispatch_model_tier="opus"
		;;
	*,tier:standard,*)
		dispatch_tier="standard"
		dispatch_model_tier="sonnet"
		;;
	*,tier:simple,*)
		dispatch_tier="simple"
		dispatch_model_tier="haiku"
		;;
	esac

	local selected_model=""
	if [[ -n "$model_override" ]]; then
		selected_model="$model_override"
	else
		selected_model=$("$HEADLESS_RUNTIME_HELPER" select --role worker --tier "$dispatch_model_tier" 2>/dev/null) || selected_model=""
	fi

	# t1894/t1934: Lock issue and linked PRs during worker execution
	lock_issue_for_worker "$issue_number" "$repo_slug"

	# GH#17584: Ensure the repo is on the latest remote commit before
	# launching the worker. Without this, workers on stale checkouts
	# close issues as "Invalid — file does not exist" when the target
	# file was added in a recent commit they haven't pulled.
	if git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$repo_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1 9>&- || {
			echo "[dispatch_with_dedup] Warning: git pull failed for ${repo_path} — proceeding with current checkout" >>"$LOGFILE"
		}
	fi

	# Pre-create worktree for the worker so it can start coding immediately
	# instead of spending 5-8 tool calls on worktree setup. The worktree is
	# idempotent — if a previous worker already created it, add returns the
	# existing path. On failure, fall back to letting the worker create it.
	local worker_worktree_path="" worker_worktree_branch=""
	local _wt_helper="${SCRIPT_DIR}/worktree-helper.sh"
	if [[ -x "$_wt_helper" && -d "$repo_path" ]]; then
		# Derive branch name from issue number (deterministic, collision-free)
		worker_worktree_branch="feature/auto-$(date +%Y%m%d-%H%M%S)"
		local _wt_output=""
		# Run from repo_path — worktree-helper.sh uses git commands that need
		# to be inside the repo. The pulse-wrapper's cwd is typically / (launchd).
		_wt_output=$(cd "$repo_path" && "$_wt_helper" add "$worker_worktree_branch" 2>&1) || true
		worker_worktree_path=$(printf '%s' "$_wt_output" | grep -oE '/[^ ]*Git/[^ ]*' | head -1) || worker_worktree_path=""
		if [[ -n "$worker_worktree_path" && -d "$worker_worktree_path" ]]; then
			echo "[dispatch_with_dedup] Pre-created worktree for #${issue_number}: ${worker_worktree_path} (branch: ${worker_worktree_branch})" >>"$LOGFILE"
		else
			echo "[dispatch_with_dedup] Warning: worktree pre-creation failed for #${issue_number} — worker will create its own" >>"$LOGFILE"
			worker_worktree_path=""
			worker_worktree_branch=""
		fi
	fi

	# Use issue title as session title for searchable history (not generic "Issue #NNN").
	# Workers no longer need to call session-rename — the title is set at dispatch.
	local worker_title="${issue_title:-${dispatch_title}}"

	# Launch worker — headless-runtime-helper.sh handles model selection
	# when no --model is specified. Its choose_model() uses the routing
	# table/local override, then checks backoff/auth and rotates providers.
	local -a worker_cmd=(
		env
		HEADLESS=1
		FULL_LOOP_HEADLESS=true
		WORKER_ISSUE_NUMBER="$issue_number"
	)
	# Pass worktree env vars only if pre-creation succeeded
	if [[ -n "$worker_worktree_path" ]]; then
		worker_cmd+=(
			WORKER_WORKTREE_PATH="$worker_worktree_path"
			WORKER_WORKTREE_BRANCH="$worker_worktree_branch"
		)
	fi
	worker_cmd+=(
		"$HEADLESS_RUNTIME_HELPER" run
		--role worker
		--session-key "$session_key"
		--dir "${worker_worktree_path:-$repo_path}"
		--tier "$dispatch_model_tier"
		--title "$worker_title"
		--prompt "$prompt"
	)
	if [[ -n "$selected_model" ]]; then
		worker_cmd+=(--model "$selected_model")
	fi
	# GH#17549: Detach worker from the pulse-wrapper's SIGHUP.
	# launchd runs pulse-wrapper with StartInterval=120s. When the wrapper
	# exits after its dispatch cycle, bash sends SIGHUP to background jobs.
	# nohup makes the worker immune to SIGHUP so it survives the parent's
	# exit. The EXIT trap only releases the instance lock (no child killing).
	nohup "${worker_cmd[@]}" </dev/null >>"$worker_log" 2>&1 9>&- &
	local worker_pid="$!"

	# GH#17549: Stagger delay between worker launches to reduce SQLite
	# write contention on opencode.db (busy_timeout=0). Without this,
	# batches of 8+ workers all hit the DB simultaneously, causing
	# SQLITE_BUSY → silent mid-turn death. The stagger gives each worker
	# time to complete its initial DB writes before the next one starts.
	local stagger_delay="${PULSE_DISPATCH_STAGGER_SECONDS:-8}"
	sleep "$stagger_delay"

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
	dispatch_comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Dispatching worker (deterministic).
- **Worker PID**: ${worker_pid}
- **Model**: ${display_model}
- **Tier**: ${dispatch_tier}
- **Runner**: ${self_login}
- **Issue**: #${issue_number}
<!-- ops:end -->"
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

	# Add label if not already present
	if [[ "$already_blocked" == "false" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "status:blocked" \
			--remove-label "status:available" --remove-label "status:queued" 2>/dev/null ||
			gh issue edit "$issue_number" --repo "$repo_slug" \
				--add-label "status:blocked" 2>/dev/null || true
	fi

	# Post comment if not already posted (idempotent — safe against concurrent pulses)
	local blocker_body="**Terminal blocker detected** (GH#5141) — skipping dispatch.

**Reason:** ${blocker_reason}

**Action required:** ${user_action}

---
*This issue will not be dispatched to workers until the blocker is resolved. Once you have completed the required action, remove the \`status:blocked\` label to re-enable dispatch.*"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"Terminal blocker detected" "$blocker_body"

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

# dispatch_count_exceeded removed (t1927). An arbitrary hard cap on dispatch
# attempts gives up instead of solving. The correct approach is:
#   1. fast_fail with exponential backoff (already implemented) — gives the
#      system breathing room between attempts
#   2. escalate_issue_tier (already implemented) — moves to higher-capability
#      models after consecutive failures
#   3. stale recovery records fast-fail (already implemented) — silent timeouts
#      count as failures and feed into backoff + escalation
#   4. blocked-by enforcement (already implemented) — skips genuinely blocked work
#
# Together, these ensure the system keeps trying with progressively more
# capable models and longer backoff intervals, rather than giving up at an
# arbitrary number. The measure of success is issues getting solved, not
# issues getting labeled "stuck".

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

	# Enrichment pass: analyze failed issues with reasoning before re-dispatch.
	# Runs after triage (responsiveness) but before implementation dispatch
	# (so enriched issues get better context on the next dispatch attempt).
	local enrichment_remaining
	enrichment_remaining=$(dispatch_enrichment_workers "$available_slots" 2>>"$LOGFILE") || enrichment_remaining="$available_slots"
	[[ "$enrichment_remaining" =~ ^[0-9]+$ ]] || enrichment_remaining="$available_slots"
	local enrichment_dispatched=$((available_slots - enrichment_remaining))
	if [[ "$enrichment_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: dispatched ${enrichment_dispatched} enrichment worker(s), ${enrichment_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$enrichment_remaining"

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

		# t1899/t1937: Skip issues with placeholder/empty bodies — dispatching a
		# worker to an undescribed issue wastes a session. The body check is
		# a single API call cached for the candidate loop iteration.
		# Detects both the legacy GitLab stub and the current claim-task-id.sh
		# stub marker ("no description provided — enrich before dispatch").
		local issue_body
		issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body -q '.body' 2>/dev/null || echo "")
		if [[ -z "$issue_body" || "$issue_body" == "Task created via claim-task-id.sh" || "$issue_body" == "null" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — placeholder/empty issue body, needs enrichment before dispatch" >>"$LOGFILE"
			continue
		fi
		# t1937: Detect the current claim-task-id.sh stub marker embedded in
		# structured bodies (## Task\n\n<title>\n\n---\n*Created by claim-task-id.sh ...*)
		if [[ "$issue_body" == *"no description provided — enrich before dispatch"* ]]; then
			echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — claim-task-id.sh stub body, needs enrichment before dispatch" >>"$LOGFILE"
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

	# Re-evaluate needs-consolidation labels before dispatch. Issues labeled
	# by an earlier (less precise) filter may no longer trigger under the
	# current filter. Auto-clearing here makes them dispatchable immediately
	# instead of stuck forever behind a label that list_dispatchable_issue_candidates_json
	# filters out (needs-* exclusion at line 6703).
	_reevaluate_consolidation_labels
	_reevaluate_simplification_labels

	# Early dispatch pass: fill available worker slots BEFORE heavy housekeeping.
	# Workers take 25-30s to cold-start (sandbox-exec + opencode), so dispatching
	# here lets them boot in parallel with the remaining housekeeping stages
	# (close_issues_with_merged_prs ~260s, prefetch_state ~130s, etc.).
	# The main fill floor at the end of the cycle catches any slots freed by
	# housekeeping. Without this, workers sit idle for ~7 minutes of cleanup.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag present — skipping early fill floor" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Early fill floor: dispatching workers before housekeeping" >>"$LOGFILE"
		apply_deterministic_fill_floor
	fi

	# Routine comment responses: scan routine-tracking issues for unanswered
	# user comments and dispatch lightweight Haiku workers to respond.
	# Runs before heavy housekeeping so responses are fast.
	dispatch_routine_comment_responses || true

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
# Routine evaluation (t1925)
#
# Evaluates repeat: fields in TODO.md routines sections across pulse-enabled
# repos. Dispatches due routines:
#   - run: → execute script directly (zero LLM tokens)
#   - agent: → dispatch via headless-runtime-helper.sh
#
# State file: ~/.aidevops/.agent-workspace/routine-state.json
# Schedule parser: routine-schedule-helper.sh
#######################################
ROUTINE_STATE_FILE="${HOME}/.aidevops/.agent-workspace/routine-state.json"
ROUTINE_SCHEDULE_HELPER="${SCRIPT_DIR}/routine-schedule-helper.sh"
ROUTINE_LOG_HELPER="${SCRIPT_DIR}/routine-log-helper.sh"

main() {
	# Phase 0 (t1963, GH#18357): --self-check short-circuit for CI, pre-edit
	# verification, and post-install smoke testing. Runs before any lock,
	# state mutation, or side effect. Sources are already in place (the
	# wrapper sources its helpers before main() is called), so by the time
	# control reaches here every function the wrapper claims to define has
	# been parsed.
	#
	# The canonical function set below covers every cluster identified in
	# todo/plans/pulse-wrapper-decomposition.md §3. During extraction the
	# cluster representatives stay stable but each phase appends a new
	# _PULSE_<CLUSTER>_LOADED guard variable check so we catch modules that
	# fail to source for any reason (missing file, syntax error, failed
	# include-guard logic). Phase 0 has zero guards; they come online as
	# Phases 1–10 land.
	#
	# Exit 0: self-check passed.
	# Exit 1: at least one expected function or module guard is missing.
	if [[ "${1:-}" == "--self-check" ]]; then
		local _sc_missing=()
		local _sc_fn
		local _sc_expected_fns=(
			resolve_dispatch_model_for_labels
			acquire_instance_lock
			check_dedup
			prefetch_state
			_extract_frontmatter_field
			check_external_contributor_pr
			run_cmd_with_timeout
			run_pulse
			cleanup_worktrees
			normalize_active_issue_assignments
			issue_has_required_approval
			run_weekly_complexity_scan
			get_repo_path_by_slug
			dispatch_with_dedup
			_triage_content_hash
			normalize_count_output
			_ff_key
			build_dependency_graph_cache
			dispatch_deterministic_fill_floor
			merge_ready_prs_all_repos
			rotate_pulse_log
			evaluate_routines
			main
			write_pulse_health_file
			calculate_max_workers
			dispatch_enrichment_workers
			dispatch_triage_reviews
			sync_todo_refs_for_repo
		)
		for _sc_fn in "${_sc_expected_fns[@]}"; do
			if ! declare -F "$_sc_fn" >/dev/null 2>&1; then
				_sc_missing+=("$_sc_fn")
			fi
		done
		# Module include guards. Appended as each phase lands.
		# Phase 1 (t1966, GH#18364): 5 leaf modules
		# Phase 2 (t1967, GH#18367): 4 leaves with fan-in
		# Phase 3 (t1971, GH#18372): 4 operational plumbing clusters
		# Phase 4 (t1972, GH#18378): pr-gates + merge cycle co-extracted
		# Phase 5 (t1973, GH#18380): cleanup + issue-reconcile extracted
		# Phase 6+: ...
		local _sc_expected_guards=(
			_PULSE_MODEL_ROUTING_LOADED
			_PULSE_INSTANCE_LOCK_LOADED
			_PULSE_META_PARSE_LOADED
			_PULSE_REPO_META_LOADED
			_PULSE_ROUTINES_LOADED
			_PULSE_QUEUE_GOVERNOR_LOADED
			_PULSE_NMR_APPROVAL_LOADED
			_PULSE_DEP_GRAPH_LOADED
			_PULSE_FAST_FAIL_LOADED
			_PULSE_CAPACITY_LOADED
			_PULSE_LOGGING_LOADED
			_PULSE_WATCHDOG_LOADED
			_PULSE_CAPACITY_ALLOC_LOADED
			_PULSE_MERGE_LOADED
			_PULSE_CLEANUP_LOADED
			_PULSE_ISSUE_RECONCILE_LOADED
		)
		local _sc_guard _sc_val
		# The `${array[@]+"${array[@]}"}` pattern is safe under `set -u`
		# when the array is empty — required in Phase 0 where no module
		# guards exist yet.
		for _sc_guard in ${_sc_expected_guards[@]+"${_sc_expected_guards[@]}"}; do
			_sc_val="${!_sc_guard:-}"
			if [[ -z "$_sc_val" ]]; then
				_sc_missing+=("${_sc_guard} (module not loaded)")
			fi
		done
		if [[ ${#_sc_missing[@]} -eq 0 ]]; then
			printf 'self-check: ok (%d canonical functions defined, %d module guards verified)\n' \
				"${#_sc_expected_fns[@]}" "${#_sc_expected_guards[@]}"
			return 0
		fi
		printf 'self-check: FAIL: %d missing:\n' "${#_sc_missing[@]}" >&2
		local _sc_item
		for _sc_item in "${_sc_missing[@]}"; do
			printf '  - %s\n' "$_sc_item" >&2
		done
		return 1
	fi

	# Phase 0 (t1963, GH#18357): --dry-run flag sets PULSE_DRY_RUN=1 so the
	# cycle can short-circuit before touching destructive operations. This
	# smoke-tests bootstrap, sourcing, config validation, lock acquisition,
	# and the main() prelude — the code paths most at risk during the
	# phased decomposition — without dispatching workers, merging PRs,
	# writing GitHub state, or removing worktrees.
	#
	# Phase 0 scope is narrow by design: --dry-run runs up to (but not
	# through) _run_preflight_stages, which is where preflight cleanup and
	# prefetch functions begin their real side effects. Later phases may
	# widen --dry-run by shimming individual destructive call sites with a
	# _dry_run_log() helper, allowing the preflight, merge pass, dispatch
	# fill floor, and LLM session to exercise their full code paths
	# without writing.
	#
	# USAGE NOTE: --dry-run still runs acquire_instance_lock, session_gate,
	# and dedup — which means an active pulse or a live user session will
	# cause --dry-run to short-circuit silently. For CI, post-install
	# verification, and smoke tests, run --dry-run in a sandboxed $HOME:
	#
	#   SANDBOX=$(mktemp -d)
	#   HOME="$SANDBOX/home" PULSE_JITTER_MAX=0 \
	#     pulse-wrapper.sh --dry-run
	#
	# The sandbox ensures no collision with the live pulse's PID file,
	# lock dir, or session flag.
	if [[ "${1:-}" == "--dry-run" ]]; then
		export PULSE_DRY_RUN=1
	fi

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
	# GH#18264: FD 9 inheritance is prevented by appending 9>&- to every child-
	# spawning command below (backgrounded workers, git calls, subshells). This
	# tells bash to close FD 9 in the child before exec — the parent's FD 9 and
	# flock are unaffected. The previous python3 fcntl(F_SETFD) approach (GH#18094)
	# was ineffective: fcntl() operates on the calling process's FD table, so
	# running it in a child python3 process only set CLOEXEC on python's copy of
	# FD 9, which was discarded when python exited. The parent bash FD 9 was never
	# modified. Bash has no built-in for fcntl().
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

	# Phase 0 (t1963): --dry-run short-circuits here. Bootstrap, sourcing,
	# config validation, lock acquisition, session gate, dedup guard, and
	# log rotation have all run cleanly by this point — that is the Phase 0
	# scope of the dry-run smoke test. Pre-flight stages below are skipped
	# because they start touching worktrees, GitHub state, and process
	# spawning. Later phases may shim those sites individually.
	if [[ "${PULSE_DRY_RUN:-0}" == "1" ]]; then
		printf 'dry-run: ok (bootstrap + sourcing + lock + session-gate + dedup + log-rotate exercised; pre-flight stages and beyond skipped)\n'
		return 0
	fi

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

	# Dependency graph cache (t1935): build once per cycle so that
	# is_blocked_by_unresolved() can resolve blocker state without API calls.
	# Runs before the fill floor so the cache is warm when dispatch checks run.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping dependency graph cache build" >>"$LOGFILE"
	else
		run_stage_with_timeout "build_dependency_graph_cache" "$PRE_RUN_STAGE_TIMEOUT" \
			build_dependency_graph_cache || true
	fi

	# Blocked-status refresh (t1935): relabel status:blocked → status:available
	# for issues whose blockers are now closed. Uses the freshly built cache —
	# zero API calls for the resolution check, one API call per unblocked issue.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping blocked-status refresh" >>"$LOGFILE"
	else
		run_stage_with_timeout "refresh_blocked_status_from_graph" "$PRE_RUN_STAGE_TIMEOUT" \
			refresh_blocked_status_from_graph || true
	fi

	# Deterministic fill floor runs EVERY cycle — before the LLM session,
	# not after. This ensures workers are dispatched every 2-min cycle
	# regardless of whether the LLM supervisor is running.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping deterministic fill floor" >>"$LOGFILE"
	else
		apply_deterministic_fill_floor
	fi

	# Routine evaluation (t1925): check repeat: fields in TODO.md routines
	# and dispatch due routines. Script-only (run:) routines execute directly
	# with zero LLM tokens. Agent routines dispatch via headless runtime.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping routine evaluation" >>"$LOGFILE"
	else
		run_stage_with_timeout "evaluate_routines" "$PRE_RUN_STAGE_TIMEOUT" \
			evaluate_routines || true
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
# Enrich failed issues with reasoning-tier analysis before re-dispatch.
#
# When a worker fails (premature_exit, idle kill), the issue body often
# lacks the implementation context needed for success. This function
# spawns an inline reasoning worker to analyze the codebase and append
# a "## Worker Guidance" section with concrete file paths, patterns,
# and verification commands.
#
# Triggered by: fast_fail_record sets enrichment_needed=true on the
# first non-rate-limit failure. Runs at most once per issue.
#
# Arguments:
#   $1 - available worker slots
# Outputs: updated available count to stdout
# Exit code: always 0
#######################################
ENRICHMENT_MAX_PER_CYCLE="${ENRICHMENT_MAX_PER_CYCLE:-2}"

dispatch_enrichment_workers() {
	local available="$1"
	local enrichment_count=0

	[[ "$available" =~ ^[0-9]+$ ]] || available=0
	[[ "$available" -gt 0 ]] || {
		printf '%d\n' "$available"
		return 0
	}

	# Read fast-fail state for issues needing enrichment
	local state
	state=$(_ff_load)
	[[ -n "$state" && "$state" != "{}" && "$state" != "null" ]] || {
		printf '%d\n' "$available"
		return 0
	}

	# Resolve reasoning model
	local resolved_model=""
	resolved_model=$(~/.aidevops/agents/scripts/model-availability-helper.sh resolve opus 2>/dev/null || echo "")
	if [[ -z "$resolved_model" ]]; then
		resolved_model=$(~/.aidevops/agents/scripts/model-availability-helper.sh resolve sonnet 2>/dev/null || echo "")
	fi
	if [[ -z "$resolved_model" ]]; then
		echo "[pulse-wrapper] dispatch_enrichment_workers: no reasoning model available — skipping" >>"$LOGFILE"
		printf '%d\n' "$available"
		return 0
	fi

	# Extract keys with enrichment_needed=true
	local enrichment_keys
	enrichment_keys=$(printf '%s' "$state" | jq -r 'to_entries[] | select(.value.enrichment_needed == true) | .key' 2>/dev/null) || enrichment_keys=""

	[[ -n "$enrichment_keys" ]] || {
		printf '%d\n' "$available"
		return 0
	}

	local repos_json="${REPOS_JSON:-$HOME/.config/aidevops/repos.json}"
	local enriched_total=0

	while IFS= read -r ff_key; do
		[[ -n "$ff_key" ]] || continue
		[[ "$enrichment_count" -lt "$ENRICHMENT_MAX_PER_CYCLE" ]] || break
		[[ "$available" -gt 0 ]] || break
		[[ -f "$STOP_FLAG" ]] && break

		# Parse key format: "issue_number:repo_slug"
		local issue_number repo_slug
		issue_number="${ff_key%%:*}"
		repo_slug="${ff_key#*:}"
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
		[[ -n "$repo_slug" ]] || continue

		# Resolve repo path
		local repo_path
		repo_path=$(jq -r --arg s "$repo_slug" \
			'.initialized_repos[]? | select(.slug == $s) | .path' \
			"$repos_json" 2>/dev/null || echo "")
		repo_path="${repo_path/#\~/$HOME}"
		[[ -n "$repo_path" && -d "$repo_path" ]] || continue

		echo "[pulse-wrapper] Enrichment: analyzing #${issue_number} in ${repo_slug} after worker failure" >>"$LOGFILE"

		# Pre-fetch issue data (deterministic, no LLM)
		local issue_body issue_title issue_comments
		issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json body --jq '.body // ""' 2>/dev/null) || issue_body=""
		issue_title=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json title --jq '.title // ""' 2>/dev/null) || issue_title=""

		# Get kill/dispatch comments for failure context
		issue_comments=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
			--jq '[.[] | select(.body | test("CLAIM|kill|premature|BLOCKED|worker_failed|Dispatching")) | {author: .user.login, body: .body, created: .created_at}] | last(3) // []' 2>/dev/null) || issue_comments="[]"

		# Build enrichment prompt
		local prompt_file
		prompt_file=$(mktemp)
		cat >"$prompt_file" <<ENRICHMENT_PROMPT_EOF
You are a reasoning-tier analyst. A worker attempted to implement issue #${issue_number} but failed.
Your job: analyze the issue and codebase, then edit the issue body to add concrete implementation guidance.

## Issue Title
${issue_title}

## Current Issue Body
${issue_body}

## Recent Comments (failure context)
${issue_comments}

## Instructions

1. Read the issue body to understand the task
2. Search the codebase (use Bash with rg/git ls-files, Read, Grep) to identify:
   - Exact file paths that need modification
   - Reference patterns in similar existing code
   - The verification command to confirm completion
3. Edit the issue body on GitHub using: gh issue edit ${issue_number} --repo ${repo_slug} --body "\$NEW_BODY"
   - Preserve the existing body content
   - Append a new section:

## Worker Guidance

**Files to modify:**
- EDIT: path/to/file.ext:LINE_RANGE — description
- NEW: path/to/new-file.ext — model on path/to/reference.ext

**Reference pattern:** Follow the pattern at path/to/similar.ext:LINES

**What the previous worker likely struggled with:** (your analysis)

**Verification:** command to verify completion

4. Keep analysis focused — spend at most 5 minutes. If the task is genuinely ambiguous, say so in the guidance rather than guessing.
5. Do NOT implement the solution. Only analyze and document guidance.
ENRICHMENT_PROMPT_EOF

		# Run inline reasoning worker
		local enrichment_output
		enrichment_output=$(mktemp)

		# shellcheck disable=SC2086
		"$HEADLESS_RUNTIME_HELPER" run \
			--role worker \
			--session-key "enrichment-${issue_number}" \
			--dir "$repo_path" \
			--model "$resolved_model" \
			--title "Enrichment analysis: Issue #${issue_number}" \
			--prompt-file "$prompt_file" </dev/null >"$enrichment_output" 2>&1

		local enrichment_exit=$?
		rm -f "$prompt_file"

		# Check if enrichment succeeded (issue body was edited)
		local post_body
		post_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json body --jq '.body // ""' 2>/dev/null) || post_body=""

		if [[ "$post_body" == *"Worker Guidance"* ]]; then
			echo "[pulse-wrapper] Enrichment: successfully added Worker Guidance to #${issue_number} in ${repo_slug}" >>"$LOGFILE"
			enriched_total=$((enriched_total + 1))
		else
			echo "[pulse-wrapper] Enrichment: worker ran (exit=${enrichment_exit}) but no Worker Guidance found in #${issue_number} body (${#post_body} chars)" >>"$LOGFILE"
		fi

		rm -f "$enrichment_output"

		# Mark enrichment complete in fast-fail state (regardless of success —
		# don't retry enrichment, let normal escalation handle persistent failures)
		_ff_with_lock _ff_mark_enrichment_done "$issue_number" "$repo_slug" || true

		enrichment_count=$((enrichment_count + 1))
		available=$((available - 1))
	done <<<"$enrichment_keys"

	if [[ "$enrichment_count" -gt 0 ]]; then
		echo "[pulse-wrapper] dispatch_enrichment_workers: processed ${enrichment_count} issues (${enriched_total} enriched), ${available} slots remaining" >>"$LOGFILE"
	fi

	printf '%d\n' "$available"
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

		# ── GH#17746: Content-hash dedup — fetch body+comments first ──
		# Fetch issue metadata and comments early: needed for both the dedup
		# check AND the prefetch prompt. If content is unchanged since the
		# last triage attempt, skip entirely (saves agent launch, lock/unlock,
		# and remaining API calls).
		local issue_json=""
		issue_json=$(gh issue view "$issue_num" --repo "$repo_slug" \
			--json number,title,body,author,labels,createdAt,updatedAt 2>/dev/null) || issue_json="{}"

		local issue_comments=""
		issue_comments=$(gh api "repos/${repo_slug}/issues/${issue_num}/comments" \
			--jq '[.[] | {author: .user.login, body: .body, created: .created_at}]' 2>/dev/null) || issue_comments="[]"

		local issue_body=""
		issue_body=$(echo "$issue_json" | jq -r '.body // "No body"' 2>/dev/null) || issue_body="No body"

		# Compute content hash and check cache
		local content_hash=""
		content_hash=$(_triage_content_hash "$issue_num" "$repo_slug" "$issue_body" "$issue_comments")

		if _triage_is_cached "$issue_num" "$repo_slug" "$content_hash"; then
			echo "[pulse-wrapper] triage dedup: skipping #${issue_num} in ${repo_slug} — content unchanged since last triage" >>"$LOGFILE"
			continue
		fi

		# ── GH#17827: Skip triage if awaiting contributor reply ──
		# When the last human comment is from a collaborator (maintainer asking
		# for info), the contributor needs to respond — not another triage cycle.
		# This eliminates the lock/unlock noise on NMR issues waiting for replies.
		if _triage_awaiting_contributor_reply "$issue_comments" "$repo_slug"; then
			echo "[pulse-wrapper] triage skip: #${issue_num} in ${repo_slug} — awaiting contributor reply (last comment from collaborator) (GH#17827)" >>"$LOGFILE"
			# Cache the hash so we don't re-check every cycle. A new contributor
			# comment will change the hash and trigger re-evaluation.
			_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
			continue
		fi

		# ── Content is new or changed — proceed with full prefetch ──

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
		local prefetch_file=""
		prefetch_file=$(mktemp)

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

		# t1894/t1934: Lock issue and linked PRs during triage
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

		local triage_posted="false"

		if [[ -n "$review_text" && ${#review_text} -gt 50 ]]; then
			# ── Safety filter: NEVER post raw sandbox/infrastructure output ──
			# If the LLM failed (quota, timeout, garbled), the output contains
			# sandbox startup logs, execution metadata, or internal paths.
			# These MUST be discarded — posting them leaks sensitive infra data.
			local has_infra_markers="false"
			if echo "$review_text" | grep -qE '\[SANDBOX\]|\[INFO\] Executing|timeout=[0-9]+s|network_blocked=|sandbox-exec-helper|/opt/homebrew/|opencode run '; then
				has_infra_markers="true"
			fi

			# Extract just the review portion (starts with ## Review variants).
			# GH#17873: Workers sometimes produce slightly different headers
			# (e.g., "## Review", "## Triage Review:", "## Review Summary:").
			# Match any "## " line containing "Review" (case-insensitive).
			local clean_review=""
			clean_review=$(echo "$review_text" | sed -n '/^## .*[Rr]eview/,$ p')

			if [[ -n "$clean_review" ]]; then
				# Re-check extracted review for infra leaks (belt-and-suspenders)
				if echo "$clean_review" | grep -qE '\[SANDBOX\]|\[INFO\] Executing|timeout=[0-9]+s|network_blocked=|sandbox-exec-helper'; then
					echo "[pulse-wrapper] SECURITY: triage review for #${issue_num} contained infrastructure markers after extraction — suppressed" >>"$LOGFILE"
				else
					gh issue comment "$issue_num" --repo "$repo_slug" \
						--body "$clean_review" >/dev/null 2>&1 || true
					echo "[pulse-wrapper] Posted sandboxed triage review for #${issue_num} in ${repo_slug}" >>"$LOGFILE"
					triage_posted="true"
				fi
			elif [[ "$has_infra_markers" == "true" ]]; then
				# No review header AND infra markers present — raw sandbox output, discard entirely
				echo "[pulse-wrapper] SECURITY: triage review for #${issue_num} was raw sandbox output — suppressed (${#review_text} chars)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Triage review for #${issue_num} had no review header (## *Review*) and no infra markers — suppressed to be safe (${#review_text} chars)" >>"$LOGFILE"
			fi
		else
			echo "[pulse-wrapper] Triage review for #${issue_num} produced no usable output (${#review_text} chars)" >>"$LOGFILE"
		fi

		# GH#17829: Surface triage failures visibly. When the triage worker
		# fails to produce a review, the only evidence is log entries — the
		# issue timeline shows lock/unlock churn with no visible outcome.
		# Add a label so maintainers can identify issues needing manual triage.
		# The label is removed when a successful triage review is posted.
		if [[ "$triage_posted" == "true" ]]; then
			gh issue edit "$issue_num" --repo "$repo_slug" \
				--remove-label "triage-failed" >/dev/null 2>&1 || true
		else
			gh issue edit "$issue_num" --repo "$repo_slug" \
				--add-label "triage-failed" >/dev/null 2>&1 || true
			echo "[pulse-wrapper] Added triage-failed label to #${issue_num} in ${repo_slug}" >>"$LOGFILE"
		fi

		# Unlock issue after triage
		unlock_issue_after_worker "$issue_num" "$repo_slug"

		# GH#17873: Only cache content hash on successful post.
		# Previously (GH#17746) the cache was written unconditionally,
		# which created a dead-letter state: if the safety filter suppressed
		# the review (e.g., missing ## Review: header), the content hash was
		# still cached, and subsequent pulse cycles would skip the issue
		# forever ("content unchanged since last triage") even though no
		# review was ever posted. Now we only cache on success — failed
		# attempts are retried on the next pulse cycle, allowing transient
		# worker formatting issues to self-heal.
		#
		# GH#17827: BUT if failures are persistent (>= TRIAGE_MAX_RETRIES on
		# the same content hash), cache anyway to break the infinite
		# lock→agent→fail→unlock loop. The triage-failed label remains so
		# maintainers can identify these issues for manual triage.
		if [[ "$triage_posted" == "true" ]]; then
			_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
		elif _triage_increment_failure "$issue_num" "$repo_slug" "$content_hash"; then
			echo "[pulse-wrapper] Triage retry cap reached for #${issue_num} in ${repo_slug} — caching hash to stop lock/unlock loop (GH#17827)" >>"$LOGFILE"
			_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
		else
			echo "[pulse-wrapper] Skipping triage cache for #${issue_num} — review not posted, will retry on next cycle" >>"$LOGFILE"
		fi

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

#######################################
# dispatch_routine_comment_responses
#
# Scans routine-tracking issues across pulse-enabled repos for unanswered
# user comments. Dispatches lightweight Haiku workers to respond.
# Max 2 dispatches per cycle to avoid flooding.
#
# Exit code: always 0 (non-fatal)
#######################################
dispatch_routine_comment_responses() {
	local responder="${SCRIPT_DIR}/routine-comment-responder.sh"
	if [[ ! -x "$responder" ]]; then
		return 0
	fi

	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local max_dispatches="${ROUTINE_COMMENT_MAX_PER_CYCLE:-2}"
	local dispatched=0

	# Iterate pulse-enabled repos
	local slug repo_path
	while IFS='|' read -r slug repo_path; do
		[[ -n "$slug" && -n "$repo_path" ]] || continue
		[[ "$dispatched" -lt "$max_dispatches" ]] || break

		# Scan for unanswered comments
		local scan_output
		scan_output=$(bash "$responder" scan "$slug" "$repo_path" 2>/dev/null) || continue
		[[ -n "$scan_output" ]] || continue

		while IFS='|' read -r issue_number comment_id author body_preview; do
			[[ -n "$issue_number" && -n "$comment_id" ]] || continue
			[[ "$dispatched" -lt "$max_dispatches" ]] || break

			echo "[pulse-wrapper] Routine comment response: dispatching for #${issue_number} comment ${comment_id} by @${author} in ${slug}" >>"$LOGFILE"
			bash "$responder" dispatch "$slug" "$repo_path" "$issue_number" "$comment_id" 2>>"$LOGFILE" || true
			dispatched=$((dispatched + 1))
		done <<<"$scan_output"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true) | select(.local_only != true) | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Routine comment responses: dispatched ${dispatched} workers" >>"$LOGFILE"
	fi

	return 0
}

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
			</dev/null >>"/tmp/pulse-foss-${foss_issue_num}.log" 2>&1 9>&- &
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
