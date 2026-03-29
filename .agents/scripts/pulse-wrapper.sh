#!/usr/bin/env bash
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
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-3600}"                                      # 60 min hard ceiling (raised from 30 min — GH#2958)
PULSE_IDLE_TIMEOUT="${PULSE_IDLE_TIMEOUT:-600}"                                             # 10 min idle before kill (reduces false positives during active triage)
PULSE_IDLE_CPU_THRESHOLD="${PULSE_IDLE_CPU_THRESHOLD:-5}"                                   # CPU% below this = idle (0-100 scale)
PULSE_PROGRESS_TIMEOUT="${PULSE_PROGRESS_TIMEOUT:-600}"                                     # 10 min no log output = stuck (GH#2958)
PULSE_COLD_START_TIMEOUT="${PULSE_COLD_START_TIMEOUT:-1200}"                                # 20 min grace before first output (prevents false early watchdog kills)
PULSE_COLD_START_TIMEOUT_UNDERFILLED="${PULSE_COLD_START_TIMEOUT_UNDERFILLED:-600}"         # 10 min grace when below worker target to recover capacity faster
PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT="${PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT:-900}" # 15 min stale-process cutoff when worker pool is underfilled
ORPHAN_MAX_AGE="${ORPHAN_MAX_AGE:-7200}"                                                    # 2 hours — kill orphans older than this
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
PULSE_BACKFILL_MAX_ATTEMPTS="${PULSE_BACKFILL_MAX_ATTEMPTS:-3}"                                         # Additional pulse passes when below utilization target (t1453)
PULSE_LAUNCH_GRACE_SECONDS="${PULSE_LAUNCH_GRACE_SECONDS:-20}"                                          # Grace window for worker process to appear after dispatch (t1453)
PRE_RUN_STAGE_TIMEOUT="${PRE_RUN_STAGE_TIMEOUT:-600}"                                                   # 10 min cap per pre-run stage (cleanup/prefetch)
PULSE_PREFETCH_PR_LIMIT="${PULSE_PREFETCH_PR_LIMIT:-200}"                                               # Open PR list window per repo for pre-fetched state
PULSE_PREFETCH_ISSUE_LIMIT="${PULSE_PREFETCH_ISSUE_LIMIT:-200}"                                         # Open issue list window for pulse prompt payload (keep compact)
PULSE_RUNNABLE_PR_LIMIT="${PULSE_RUNNABLE_PR_LIMIT:-200}"                                               # Open PR sample size for runnable-candidate counting
PULSE_RUNNABLE_ISSUE_LIMIT="${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}"                                        # Open issue sample size for runnable-candidate counting
PULSE_QUEUED_SCAN_LIMIT="${PULSE_QUEUED_SCAN_LIMIT:-1000}"                                              # Queued/in-progress scan window per repo
UNDERFILL_RECYCLE_DEFICIT_MIN_PCT="${UNDERFILL_RECYCLE_DEFICIT_MIN_PCT:-25}"                            # Run worker recycler when underfill reaches this threshold
GH_FAILURE_PREFETCH_HOURS="${GH_FAILURE_PREFETCH_HOURS:-24}"                                            # Window for failed-notification mining summary
GH_FAILURE_PREFETCH_LIMIT="${GH_FAILURE_PREFETCH_LIMIT:-100}"                                           # Notification page size for failed-notification mining
GH_FAILURE_SYSTEMIC_THRESHOLD="${GH_FAILURE_SYSTEMIC_THRESHOLD:-3}"                                     # Cluster threshold for systemic-failure flag
GH_FAILURE_MAX_RUN_LOGS="${GH_FAILURE_MAX_RUN_LOGS:-6}"                                                 # Max failed workflow runs to sample for signatures per pulse

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
PULSE_LAUNCH_GRACE_SECONDS=$(_validate_int PULSE_LAUNCH_GRACE_SECONDS "$PULSE_LAUNCH_GRACE_SECONDS" 20 5)
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
GH_FAILURE_PREFETCH_HOURS=$(_validate_int GH_FAILURE_PREFETCH_HOURS "$GH_FAILURE_PREFETCH_HOURS" 24 1)
GH_FAILURE_PREFETCH_LIMIT=$(_validate_int GH_FAILURE_PREFETCH_LIMIT "$GH_FAILURE_PREFETCH_LIMIT" 100 1)
GH_FAILURE_SYSTEMIC_THRESHOLD=$(_validate_int GH_FAILURE_SYSTEMIC_THRESHOLD "$GH_FAILURE_SYSTEMIC_THRESHOLD" 3 1)
GH_FAILURE_MAX_RUN_LOGS=$(_validate_int GH_FAILURE_MAX_RUN_LOGS "$GH_FAILURE_MAX_RUN_LOGS" 6 0)
CHILD_RSS_LIMIT_KB=$(_validate_int CHILD_RSS_LIMIT_KB "$CHILD_RSS_LIMIT_KB" 2097152 1)
CHILD_RUNTIME_LIMIT=$(_validate_int CHILD_RUNTIME_LIMIT "$CHILD_RUNTIME_LIMIT" 1800 1)
SHELLCHECK_RSS_LIMIT_KB=$(_validate_int SHELLCHECK_RSS_LIMIT_KB "$SHELLCHECK_RSS_LIMIT_KB" 1048576 1)
SHELLCHECK_RUNTIME_LIMIT=$(_validate_int SHELLCHECK_RUNTIME_LIMIT "$SHELLCHECK_RUNTIME_LIMIT" 300 1)
SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 1)

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
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
SCOPE_FILE="${HOME}/.aidevops/logs/pulse-scope-repos"
COMPLEXITY_SCAN_LAST_RUN="${HOME}/.aidevops/logs/complexity-scan-last-run"
COMPLEXITY_SCAN_INTERVAL="${COMPLEXITY_SCAN_INTERVAL:-900}" # 15 min — runs each pulse cycle, per-run cap governs throughput
DEDUP_CLEANUP_LAST_RUN="${HOME}/.aidevops/logs/dedup-cleanup-last-run"
DEDUP_CLEANUP_INTERVAL="${DEDUP_CLEANUP_INTERVAL:-86400}"                       # 1 day in seconds
DEDUP_CLEANUP_BATCH_SIZE="${DEDUP_CLEANUP_BATCH_SIZE:-50}"                      # Max issues to close per run
COMPLEXITY_FUNC_LINE_THRESHOLD="${COMPLEXITY_FUNC_LINE_THRESHOLD:-100}"         # Functions longer than this are violations
COMPLEXITY_FILE_VIOLATION_THRESHOLD="${COMPLEXITY_FILE_VIOLATION_THRESHOLD:-1}" # Files with >= this many violations get an issue (was 5)
COMPLEXITY_MD_MIN_LINES="${COMPLEXITY_MD_MIN_LINES:-50}"                        # Agent docs shorter than this are not actionable for simplification
WORKER_WATCHDOG_HELPER="${SCRIPT_DIR}/worker-watchdog.sh"

# Validate complexity scan configuration (defined above, validated here)
COMPLEXITY_SCAN_INTERVAL=$(_validate_int COMPLEXITY_SCAN_INTERVAL "$COMPLEXITY_SCAN_INTERVAL" 900 300)
COMPLEXITY_FUNC_LINE_THRESHOLD=$(_validate_int COMPLEXITY_FUNC_LINE_THRESHOLD "$COMPLEXITY_FUNC_LINE_THRESHOLD" 100 50)
COMPLEXITY_FILE_VIOLATION_THRESHOLD=$(_validate_int COMPLEXITY_FILE_VIOLATION_THRESHOLD "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" 1 1)
COMPLEXITY_MD_MIN_LINES=$(_validate_int COMPLEXITY_MD_MIN_LINES "$COMPLEXITY_MD_MIN_LINES" 50 10)

if [[ ! -x "$HEADLESS_RUNTIME_HELPER" ]]; then
	printf '[pulse-wrapper] ERROR: headless runtime helper is missing or not executable: %s (SCRIPT_DIR=%s)\n' "$HEADLESS_RUNTIME_HELPER" "$SCRIPT_DIR" >&2
	exit 1
fi

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
}

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
# Print the Open PRs section for a repo (GH#5627)
#
# Fetches open PRs and emits a markdown section to stdout.
# Called from _prefetch_single_repo inside a subshell redirect.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#######################################
_prefetch_repo_prs() {
	local slug="$1"

	# PRs (createdAt included for daily PR cap — GH#3821)
	local pr_json
	pr_json=$(gh pr list --repo "$slug" --state open \
		--json number,title,reviewDecision,statusCheckRollup,updatedAt,headRefName,createdAt \
		--limit "$PULSE_PREFETCH_PR_LIMIT" 2>/dev/null) || pr_json="[]"

	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length')

	if [[ "$pr_count" -gt 0 ]]; then
		echo "### Open PRs ($pr_count)"
		echo "$pr_json" | jq -r '.[] | "- PR #\(.number): \(.title) [checks: \(if .statusCheckRollup == null or (.statusCheckRollup | length) == 0 then "none" elif (.statusCheckRollup | all((.conclusion // .state) == "SUCCESS")) then "PASS" elif (.statusCheckRollup | any((.conclusion // .state) == "FAILURE")) then "FAIL" else "PENDING" end)] [review: \(if .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end)] [branch: \(.headRefName)] [updated: \(.updatedAt)]"'
	else
		echo "### Open PRs (0)"
		echo "- None"
	fi

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
	local daily_cap_json
	daily_cap_json=$(gh pr list --repo "$slug" --state all \
		--json createdAt --limit 200 2>/dev/null) || daily_cap_json="[]"
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
# Print the Open Issues sections for a repo (GH#5627)
#
# Fetches open issues, filters managed labels, splits into dispatchable
# vs quality-sweep-tracked, and emits markdown sections to stdout.
# Called from _prefetch_single_repo inside a subshell redirect.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#######################################
_prefetch_repo_issues() {
	local slug="$1"

	# Issues (include assignees for dispatch dedup)
	# Filter out supervisor/contributor/persistent/quality-review issues —
	# these are managed by pulse-wrapper.sh and must not be touched by the
	# pulse agent. Exposing them in pre-fetched state causes the LLM to
	# close them as "stale", creating churn (wrapper recreates on next cycle).
	local issue_json
	issue_json=$(gh issue list --repo "$slug" --state open \
		--json number,title,labels,updatedAt,assignees \
		--limit "$PULSE_PREFETCH_ISSUE_LIMIT" 2>/dev/null) || issue_json="[]"

	# Remove issues with supervisor, contributor, persistent, or quality-review labels
	local filtered_json
	filtered_json=$(echo "$issue_json" | jq '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review")) | not)]')

	# GH#10308: Split issues into dispatchable vs quality-sweep-tracked.
	# The sweep (stats-functions.sh) creates quality-debt and simplification-debt
	# issues with source:quality-sweep labels. Showing these separately prevents
	# the pulse LLM from independently creating duplicate issues for the same
	# findings it reads from the quality dashboard comments.
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
# Fetch PR, issue, and daily-cap data for a single repo (GH#5627)
#
# Runs inside a subshell (called from prefetch_state parallel loop).
# Writes a compact markdown summary to the specified output file.
# Delegates to focused helpers for each data section.
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

	{
		echo "## ${slug} (${path})"
		echo ""
		_prefetch_repo_prs "$slug"
		_prefetch_repo_daily_cap "$slug"
		_prefetch_repo_issues "$slug"
	} >"$outfile"
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
_append_prefetch_sub_helpers() {
	local repo_entries="$1"

	# Append mission state (reads local files — fast)
	prefetch_missions "$repo_entries" >>"$STATE_FILE"

	# Append active worker snapshot for orphaned PR detection (t216, local ps — fast)
	prefetch_active_workers >>"$STATE_FILE"

	# Append repo hygiene data for LLM triage (t1417)
	# This includes pr-salvage-helper.sh which iterates all repos sequentially
	# and can hang on gh API calls. 30s timeout — if it can't finish fast,
	# the pulse proceeds without hygiene data (degraded but functional).
	# Total prefetch budget: 60s (parallel) + 30s + 30s + 30s = 150s max,
	# well within the 600s stage timeout.
	local hygiene_tmp
	hygiene_tmp=$(mktemp)
	run_cmd_with_timeout 30 prefetch_hygiene >"$hygiene_tmp" 2>/dev/null || {
		echo "[pulse-wrapper] prefetch_hygiene timed out after 30s (non-fatal)" >>"$LOGFILE"
	}
	cat "$hygiene_tmp" >>"$STATE_FILE"
	rm -f "$hygiene_tmp"

	# Append CI failure patterns from notification mining (GH#4480)
	local ci_tmp
	ci_tmp=$(mktemp)
	run_cmd_with_timeout 30 prefetch_ci_failures >"$ci_tmp" 2>/dev/null || {
		echo "[pulse-wrapper] prefetch_ci_failures timed out after 30s (non-fatal)" >>"$LOGFILE"
	}
	cat "$ci_tmp" >>"$STATE_FILE"
	rm -f "$ci_tmp"

	# Append priority-class worker allocations (t1423, reads local file — fast)
	_append_priority_allocations >>"$STATE_FILE"

	# Append adaptive queue-governor guidance (t1455, local computation — fast)
	append_adaptive_queue_governor

	# Append external contribution watch summary (t1419, local state — fast)
	prefetch_contribution_watch >>"$STATE_FILE"

	# Append failed-notification systemic summary (t3960)
	local ghfail_tmp
	ghfail_tmp=$(mktemp)
	run_cmd_with_timeout 30 prefetch_gh_failure_notifications >"$ghfail_tmp" 2>/dev/null || {
		echo "[pulse-wrapper] prefetch_gh_failure_notifications timed out after 30s (non-fatal)" >>"$LOGFILE"
	}
	cat "$ghfail_tmp" >>"$STATE_FILE"
	rm -f "$ghfail_tmp"

	# Append needs-maintainer-review triage status for automated review dispatch
	local triage_tmp
	triage_tmp=$(mktemp)
	run_cmd_with_timeout 30 prefetch_triage_review_status "$repo_entries" >"$triage_tmp" 2>/dev/null || {
		echo "[pulse-wrapper] prefetch_triage_review_status timed out after 30s (non-fatal)" >>"$LOGFILE"
	}
	cat "$triage_tmp" >>"$STATE_FILE"
	rm -f "$triage_tmp"

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
				' "$repos_json" >"$tmp_json" 2>/dev/null; then
					mv "$tmp_json" "$repos_json"
					echo "[pulse-wrapper] Set pulse:false for ${slug} in repos.json (expiry auto-disable)" >>"$LOGFILE"
				else
					rm -f "$tmp_json"
					echo "[pulse-wrapper] WARNING: jq failed to update repos.json for ${slug} expiry — skipping this cycle only" >>"$LOGFILE"
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
	# Normal completion: <30s. Timeout at 60s catches hung gh connections.
	_wait_parallel_pids 60 "${pids[@]}"

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
list_active_worker_processes() {
	# t5072: Count logical workers (one per session/issue), not OS process tree nodes.
	# A single opencode worker spawns a 3-process chain:
	#   bash sandbox-exec-helper.sh run ... -- opencode run ...  (top-level launcher)
	#   node /opt/homebrew/bin/opencode run ...                  (node child)
	#   /path/to/.opencode run ...                               (binary grandchild)
	# All three contain /full-loop (or /review-issue-pr) and opencode in their command line.
	#
	# GH#12361: Workers dispatched via headless-runtime-helper.sh without
	# sandbox-exec-helper.sh run as /bin/.opencode processes directly.
	# The old approach blanket-excluded /bin/.opencode and node child
	# processes, which missed standalone workers. New approach:
	#   1. Match all processes with /full-loop or /review-issue-pr + opencode (any binary path)
	#   2. Deduplicate by issue+dir key: when multiple processes share the
	#      same issue AND --dir path (sandbox chain), prefer the sandbox
	#      launcher; if no launcher exists, keep the first match (the
	#      standalone worker). Different --dir paths = different logical
	#      workers even with the same issue number.
	#
	# GH#6413: Process state filtering — exclude zombie (Z) and stopped (T)
	# processes. These are dead/stuck processes that hold no useful work but
	# appear as "active" in worker counts, inflating struggle ratios and
	# preventing the pulse from dispatching replacements. The stat column is
	# used for filtering only; output format remains pid,etime,command for
	# backward compatibility with all consumers.
	ps axo pid,stat,etime,command | awk '
		($0 ~ /\/full-loop/ || $0 ~ /\/review-issue-pr/) &&
		$0 !~ /(^|[[:space:]])\/pulse([[:space:]]|$)/ &&
		$0 !~ /Supervisor Pulse/ &&
		$0 ~ /(^|[[:space:]\/])\.?opencode([[:space:]]|$)/ {
			# $2 is the stat column (e.g., S, SN, Ss, Z, Zs, T, TN)
			stat = $2
			# Exclude zombies (Z*) and stopped processes (T*)
			if (stat ~ /^[ZT]/) next
			# Build output line: pid, etime, command (skip stat)
			line = $1 " " $3
			for (i = 4; i <= NF; i++) line = line " " $i
			# Extract issue number for dedup (matches "Issue #NNN" or "issue-NNN")
			issue = ""
			if (match($0, /[Ii]ssue[[:space:]]*#([0-9]+)/) || match($0, /issue-([0-9]+)/)) {
				rest = substr($0, RSTART, RLENGTH)
				gsub(/[^0-9]/, "", rest)
				issue = rest
			}
			# Extract --dir path for dedup key (same issue in different repos
			# = different logical workers)
			dir = ""
			if (match($0, /--dir[[:space:]]+[^[:space:]]+/)) {
				dir = substr($0, RSTART, RLENGTH)
				sub(/--dir[[:space:]]+/, "", dir)
			}
			dedup_key = issue "|" dir
			# Prefer sandbox launcher over node/binary children for same issue+dir
			is_launcher = ($0 ~ /sandbox-exec-helper\.sh/)
			if (issue != "" && dedup_key in seen) {
				# Already have a line for this issue+dir
				if (is_launcher && !seen_launcher[dedup_key]) {
					# Replace child with launcher
					seen_lines[dedup_key] = line
					seen_launcher[dedup_key] = 1
				}
				# Otherwise skip (child of existing launcher, or duplicate)
			} else if (issue != "") {
				seen[dedup_key] = 1
				seen_lines[dedup_key] = line
				seen_launcher[dedup_key] = is_launcher ? 1 : 0
				key_order[++key_count] = dedup_key
			} else {
				# No issue number found — print directly (edge case)
				no_issue_lines[++no_issue_count] = line
			}
		}
		END {
			for (i = 1; i <= key_count; i++) {
				print seen_lines[key_order[i]]
			}
			for (i = 1; i <= no_issue_count; i++) {
				print no_issue_lines[i]
			}
		}
	'
	return 0
}

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

#######################################
# Check concurrent session count and warn (t1398)
#
# Counts running opencode/claude interactive sessions (those with a TTY).
# If count exceeds SESSION_COUNT_WARN, logs a warning. This is informational
# — the pulse doesn't kill user sessions, but the health issue will show it.
#
# Returns: session count via stdout
#######################################
check_session_count() {
	local interactive_count=0

	# Count opencode processes with a real TTY (interactive sessions).
	# Filter both '?' (Linux) and '??' (macOS) headless TTY entries.
	interactive_count=$(ps axo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || interactive_count=0

	if [[ "$interactive_count" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "[pulse-wrapper] Session warning: $interactive_count interactive sessions open (threshold: $SESSION_COUNT_WARN). Each consumes 100-440MB + language servers. Consider closing unused tabs." >>"$LOGFILE"
	fi

	echo "$interactive_count"
	return 0
}

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

	local kill_reason=""

	# Check 0: Stop flag — user ran `aidevops pulse stop` during this cycle (t2943)
	if [[ -f "$STOP_FLAG" ]]; then
		kill_reason="Stop flag detected during active pulse — user requested stop"
	# Check 1: Wall-clock stale threshold (hard ceiling)
	elif [[ "$elapsed" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		kill_reason="Pulse exceeded stale threshold (${elapsed}s > ${PULSE_STALE_THRESHOLD}s)"
	# Skip checks 2 and 3 during the first 3 minutes to allow startup/init.
	elif [[ "$elapsed" -ge 180 ]]; then
		# Check 2: Progress detection — is the log file growing? (GH#2958)
		if [[ -z "$kill_reason" ]]; then
			local current_log_size=0
			if [[ -f "$LOGFILE" ]]; then
				current_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || echo "0")
				current_log_size="${current_log_size// /}"
			fi
			[[ "$current_log_size" =~ ^[0-9]+$ ]] || current_log_size=0

			if [[ "$current_log_size" -gt "$last_log_size" ]]; then
				# Log grew — process is making progress
				has_seen_progress=true
				if [[ "$progress_stall_seconds" -gt 0 ]]; then
					echo "[pulse-wrapper] Progress resumed after ${progress_stall_seconds}s stall (log grew by $((current_log_size - last_log_size)) bytes)" >>"$LOGFILE"
				fi
				last_log_size="$current_log_size"
				progress_stall_seconds=0
			else
				# Log hasn't grown — increment stall counter
				progress_stall_seconds=$((progress_stall_seconds + 60))
				local progress_timeout="$PULSE_PROGRESS_TIMEOUT"
				if [[ "$has_seen_progress" == false ]]; then
					progress_timeout="$effective_cold_start_timeout"
				fi
				if [[ "$progress_stall_seconds" -ge "$progress_timeout" ]]; then
					if [[ "$has_seen_progress" == false ]]; then
						kill_reason="Pulse cold-start stalled for ${progress_stall_seconds}s — no first output (log size: ${current_log_size} bytes, threshold: ${effective_cold_start_timeout}s)"
					else
						kill_reason="Pulse stalled for ${progress_stall_seconds}s — no log output (log size: ${current_log_size} bytes, threshold: ${PULSE_PROGRESS_TIMEOUT}s) (GH#2958)"
					fi
				fi
			fi
		fi

		# Check 3: Idle detection — CPU usage of the process tree (t1398.3)
		if [[ -z "$kill_reason" ]]; then
			if [[ "$has_seen_progress" == true ]]; then
				local tree_cpu
				tree_cpu=$(_get_process_tree_cpu "$opencode_pid")
				if [[ "$tree_cpu" -lt "$PULSE_IDLE_CPU_THRESHOLD" ]]; then
					idle_seconds=$((idle_seconds + 60))
					if [[ "$idle_seconds" -ge "$PULSE_IDLE_TIMEOUT" ]]; then
						kill_reason="Pulse idle for ${idle_seconds}s (CPU ${tree_cpu}% < ${PULSE_IDLE_CPU_THRESHOLD}%, threshold ${PULSE_IDLE_TIMEOUT}s) (t1398.3)"
					fi
				else
					# Process is active — reset idle counter
					if [[ "$idle_seconds" -gt 0 ]]; then
						echo "[pulse-wrapper] Pulse active again (CPU ${tree_cpu}%) after ${idle_seconds}s idle — resetting idle counter" >>"$LOGFILE"
					fi
					idle_seconds=0
				fi
			else
				idle_seconds=0
			fi
		fi
	fi

	# Output updated state (one value per line for caller to read)
	echo "$kill_reason"
	echo "$last_log_size"
	echo "$progress_stall_seconds"
	echo "$has_seen_progress"
	echo "$idle_seconds"
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
	echo "[pulse-wrapper] Starting pulse at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$WRAPPER_LOGFILE"
	echo "[pulse-wrapper] Watchdog cold-start timeout: ${effective_cold_start_timeout}s (underfilled_mode=${underfilled_mode}, underfill_pct=${underfill_pct})" >>"$LOGFILE"

	# Build the prompt: /pulse + reference to pre-fetched state file.
	# The state is NOT inlined into the prompt — on Linux, execve() enforces
	# MAX_ARG_STRLEN (128KB per argument) and the state routinely exceeds this,
	# causing "Argument list too long" on every pulse invocation. The agent
	# reads the file via its Read tool instead. See: #4257
	local prompt="/pulse"
	if [[ -f "$STATE_FILE" ]]; then
		prompt="/pulse

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
		local nmr_json
		nmr_json=$(gh issue list --repo "$slug" --label "needs-maintainer-review" \
			--state open --json number,title,createdAt,updatedAt \
			--limit 50 2>/dev/null) || nmr_json="[]"

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

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local issue_rows
		issue_rows=$(gh issue list --repo "$slug" --state open --json number,assignees,labels --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null | jq -r '.[] | select(((.labels | map(.name) | index("status:queued")) or (.labels | map(.name) | index("status:in-progress"))) and ((.assignees | length) == 0)) | .number' 2>/dev/null) || issue_rows=""
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

	return 0
}

#######################################
# Daily complexity scan helpers (GH#5628)
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
	shell_files=$(git -C "$aidevops_path" ls-files '*.sh' | grep -Ev '_archive/|archived/|supervisor-archived/' || true)
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
# Protected files (build.txt, AGENTS.md, pulse.md) are excluded — these are
# core infrastructure that must be simplified manually with a maintainer present.
# Results are sorted longest-first so biggest wins come early.
# Arguments: $1 - aidevops_path
# Outputs: scan_results (pipe-delimited lines: file_path|line_count) via stdout
_complexity_scan_collect_md_violations() {
	local aidevops_path="$1"

	# Protected files and directories — excluded from automated simplification.
	# - build.txt, AGENTS.md, pulse.md: core infrastructure (code-simplifier.md)
	# - templates/: template files meant to be copied, not compressed
	# - README.md: navigation/index docs, not instruction docs
	# - todo/: planning files, not code
	local protected_pattern='prompts/build\.txt|^\.agents/AGENTS\.md|^AGENTS\.md|scripts/commands/pulse\.md'
	local excluded_dirs='_archive/|archived/|/templates/|/todo/'
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
# - When hash differs → file changed since simplification → create regression issue
# - State is committed to main and pushed, so all users share it
#######################################

# Check if a file has already been simplified and is unchanged.
# Arguments: $1 - repo_path, $2 - file_path (repo-relative), $3 - state_file path
# Returns: 0 = already simplified (unchanged), 1 = not simplified or changed
# Outputs to stdout: "unchanged" | "regressed" | "new"
_simplification_state_check() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"

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

	echo "regressed"
	return 1
}

# Record a file as simplified in the state file.
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

	# Update the entry using jq
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg fp "$file_path" --arg hash "$current_hash" --arg at "$now_iso" --argjson pr "$pr_number" \
		'.files[$fp] = {"hash": $hash, "at": $at, "pr": $pr}' \
		"$state_file" >"$tmp_file" 2>/dev/null && mv "$tmp_file" "$state_file" || {
		rm -f "$tmp_file"
		return 1
	}
	return 0
}

# Prune stale entries from simplification state (files that no longer exist).
# This handles file moves/renames/deletions — entries for non-existent files
# are removed so they don't cause false "regressed" status or accumulate.
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
		jq "${jq_filter} | {\"_comment\": ._comment, \"files\": .}" "$state_file" >"$tmp_file" 2>/dev/null || {
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
	local cap="${2:-100}"
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
# Checks simplification state, dedup, regression, builds title/body, creates issue.
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
		# "regressed" files fall through — they get a new issue with regression label
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

	# Determine if this is a regression (file changed after simplification)
	local is_regression=false
	if [[ "$file_status" == "regressed" ]]; then
		is_regression=true
	fi

	local issue_title="simplification: tighten agent doc ${file_path} (${line_count} lines)"
	if [[ -n "$topic_label" ]]; then
		issue_title="simplification: tighten agent doc ${topic_label} (${file_path}, ${line_count} lines)"
	fi
	if [[ "$is_regression" == true ]]; then
		issue_title="regression: ${issue_title}"
	fi

	local issue_body
	issue_body=$(_complexity_scan_build_md_issue_body "$file_path" "$line_count" "$topic_label")
	if [[ "$is_regression" == true ]]; then
		local prev_pr
		prev_pr=$(jq -r --arg fp "$file_path" '.files[$fp].pr // 0' "$state_file" 2>/dev/null) || prev_pr="0"
		issue_body="${issue_body}

### Regression note

This file was previously simplified (PR #${prev_pr}) but has since been modified. The content hash no longer matches the post-simplification state. Please re-evaluate."
	fi

	# Append signature footer
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer 2>/dev/null || true)
	issue_body="${issue_body}${sig_footer}"

	local create_ok=false
	if [[ "$is_regression" == true ]]; then
		gh issue create --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "simplification-debt" --label "needs-maintainer-review" --label "tier:thinking" --label "regression" \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	else
		gh issue create --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "simplification-debt" --label "needs-maintainer-review" --label "tier:thinking" \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	fi

	if [[ "$create_ok" == true ]]; then
		local log_suffix=""
		if [[ "$is_regression" == true ]]; then log_suffix=" [REGRESSION]"; fi
		echo "[pulse-wrapper] Complexity scan (.md): created issue for ${file_path} (${line_count} lines)${log_suffix}" >>"$LOGFILE"
		echo "created"
	else
		echo "[pulse-wrapper] Complexity scan (.md): failed to create issue for ${file_path}" >>"$LOGFILE"
		echo "failed"
	fi
	return 0
}

# Create GitHub issues for agent docs flagged for simplification review.
# Uses tier:thinking label (opus) because doc simplification requires deep
# reasoning to distinguish noise from institutional knowledge.
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
		# Append signature footer
		local sig_footer2=""
		sig_footer2=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer 2>/dev/null || true)
		issue_body="${issue_body}${sig_footer2}"

		local issue_key="$file_path"
		if gh issue create --repo "$aidevops_slug" \
			--title "simplification: reduce function complexity in ${issue_key} (${violation_count} functions >${COMPLEXITY_FUNC_LINE_THRESHOLD} lines)" \
			--label "simplification-debt" --label "needs-maintainer-review" \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1; then
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
# Complexity scan (GH#5628)
#
# Scans both shell scripts (.sh) and agent docs (.md) for complexity:
# - .sh files: functions exceeding COMPLEXITY_FUNC_LINE_THRESHOLD lines
# - .md files: all agent docs (no size gate — classification determines action, t1679)
#
# Protected files (build.txt, AGENTS.md, pulse.md) are excluded from
# .md scanning — these are core infrastructure requiring manual review.
#
# Results are processed longest-first so the biggest wins come early
# and the process is refined by the time shorter files are reached.
#
# .md issues get tier:thinking (opus) because doc simplification requires
# deep reasoning to distinguish noise from institutional knowledge.
#
# Runs at most once per COMPLEXITY_SCAN_INTERVAL (default 15 min — each
# pulse cycle). Creates up to 5 issues per run; the open cap (100) is
# the safety valve against backlog flooding.
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

	echo "[pulse-wrapper] Running daily complexity scan (GH#5628)..." >>"$LOGFILE"

	# Ensure regression label exists (used when a simplified file changes)
	gh label create "regression" --repo "$aidevops_slug" --color "D93F0B" \
		--description "File was simplified but has since been modified" --force 2>/dev/null || true

	local aidevops_path
	aidevops_path=$(_complexity_scan_find_repo "$repos_json" "$aidevops_slug" "$now_epoch") || return 0

	# Phase 1: Shell script function complexity (longest-first)
	local sh_results
	sh_results=$(_complexity_scan_collect_violations "$aidevops_path" "$now_epoch") || true
	if [[ -n "$sh_results" ]]; then
		# Sort longest-first by violation count (field 2)
		sh_results=$(printf '%s' "$sh_results" | sort -t'|' -k2 -rn)
		_complexity_scan_create_issues "$sh_results" "$repos_json" "$aidevops_slug"
	fi

	# Phase 2: Agent doc size (.md files, longest-first)
	local md_results
	md_results=$(_complexity_scan_collect_md_violations "$aidevops_path") || true
	if [[ -n "$md_results" ]]; then
		_complexity_scan_create_md_issues "$md_results" "$repos_json" "$aidevops_slug"
	fi

	# Phase 3: Backfill simplification state from recently-closed issues.
	# Finds simplification-debt issues closed in the last 7 days that have a
	# linked merged PR, extracts the changed files, and records their current
	# git blob hashes in the state file. This catches simplifications done by
	# workers without requiring them to update the state file explicitly.
	local state_file="${aidevops_path}/.agents/configs/simplification-state.json"
	local state_updated=false

	# Prune stale entries (files moved/renamed/deleted since last scan)
	local pruned_count
	pruned_count=$(_simplification_state_prune "$aidevops_path" "$state_file")
	if [[ "$pruned_count" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: pruned $pruned_count stale entries (files no longer exist)" >>"$LOGFILE"
		state_updated=true
	fi
	local closed_issues
	closed_issues=$(gh issue list --repo "$aidevops_slug" \
		--label "simplification-debt" --state closed \
		--limit 50 --json number,title,closedAt \
		--jq '[.[] | select(.closedAt > (now - 604800 | strftime("%Y-%m-%dT%H:%M:%SZ")))] | .[].number' 2>/dev/null) || closed_issues=""

	if [[ -n "$closed_issues" ]]; then
		while IFS= read -r issue_num; do
			[[ -z "$issue_num" ]] && continue
			# Find linked merged PR
			local pr_num
			pr_num=$(gh api "repos/${aidevops_slug}/issues/${issue_num}/timeline" \
				--jq '[.[] | select(.event == "cross-referenced" and .source.issue.pull_request != null and .source.issue.pull_request.merged_at != null)] | .[0].source.issue.number // empty' 2>/dev/null) || pr_num=""
			[[ -z "$pr_num" ]] && continue

			# Get changed files from the PR
			local changed_files
			changed_files=$(gh pr view "$pr_num" --repo "$aidevops_slug" --json files --jq '.files[].path' 2>/dev/null) || changed_files=""
			[[ -z "$changed_files" ]] && continue

			# Record each changed file that still exists
			while IFS= read -r changed_file; do
				[[ -z "$changed_file" ]] && continue
				# Only record files that match the simplification target patterns
				case "$changed_file" in
				*.md | *.sh) ;;
				*) continue ;;
				esac
				# Check if already in state with current hash
				local check_result
				check_result=$(_simplification_state_check "$aidevops_path" "$changed_file" "$state_file")
				if [[ "$check_result" != "unchanged" ]]; then
					_simplification_state_record "$aidevops_path" "$changed_file" "$state_file" "$pr_num" && state_updated=true
				fi
			done <<<"$changed_files"
		done <<<"$closed_issues"
	fi

	# Push state file if updated (planning data — direct to main)
	if [[ "$state_updated" == true ]]; then
		_simplification_state_push "$aidevops_path"
	fi

	echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
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
# Count active worker processes
# Returns: count via stdout
#######################################
count_active_workers() {
	local count
	count=$(list_active_worker_processes | wc -l | tr -d ' ') || count=0
	echo "$count"
	return 0
}

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
# Six-layer dedup:
#   1. dispatch-ledger-helper.sh check-issue — in-flight ledger (GH#6696)
#   2. has_worker_for_repo_issue() — exact repo+issue process match
#   3. dispatch-dedup-helper.sh is-duplicate — normalized title key match
#   4. dispatch-dedup-helper.sh has-open-pr — merged PR evidence for issue/task
#   5. dispatch-dedup-helper.sh is-assigned — cross-machine assignee guard (GH#6891)
#   6. dispatch-dedup-helper.sh claim — cross-machine optimistic lock (GH#11086)
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
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		local claim_exit=0
		"$dedup_helper" claim "$issue_number" "$repo_slug" "$self_login" >>"$LOGFILE" 2>&1 || claim_exit=$?
		if [[ "$claim_exit" -eq 1 ]]; then
			echo "[pulse-wrapper] Dedup: claim lost for #${issue_number} in ${repo_slug} — another runner claimed first (GH#11086)" >>"$LOGFILE"
			return 0
		fi
		if [[ "$claim_exit" -eq 2 ]]; then
			echo "[pulse-wrapper] Dedup: claim error for #${issue_number} in ${repo_slug} — proceeding (fail-open)" >>"$LOGFILE"
		fi
		# claim_exit 0 = won, proceed to dispatch
	fi

	return 1
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

		local pr_json
		pr_json=$(gh pr list --repo "$slug" --state open --json reviewDecision,statusCheckRollup --limit "$PULSE_RUNNABLE_PR_LIMIT" 2>/dev/null) || pr_json="[]"
		local repo_pr_total repo_ready repo_failing
		repo_pr_total=$(echo "$pr_json" | jq 'length' 2>/dev/null) || repo_pr_total=0
		repo_ready=$(echo "$pr_json" | jq '[.[] | select(.reviewDecision == "APPROVED" and ((.statusCheckRollup // []) | length > 0) and ((.statusCheckRollup // []) | all((.conclusion // .state) == "SUCCESS")))] | length' 2>/dev/null) || repo_ready=0
		repo_failing=$(echo "$pr_json" | jq '[.[] | select(.reviewDecision == "CHANGES_REQUESTED" or ((.statusCheckRollup // []) | any((.conclusion // .state) == "FAILURE")))] | length' 2>/dev/null) || repo_failing=0

		local issue_json repo_issue_total
		issue_json=$(gh issue list --repo "$slug" --state open --json number --limit "$PULSE_RUNNABLE_ISSUE_LIMIT" 2>/dev/null) || issue_json="[]"
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
# Compute queue governor guidance from metrics (GH#5627)
#
# Pure computation — no I/O except reading/writing the metrics file.
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

	local prev_total_prs=0 prev_total_issues=0 prev_ready_prs=0 prev_failing_prs=0
	if [[ -f "$QUEUE_METRICS_FILE" ]]; then
		while IFS='=' read -r key value; do
			case "$key" in
			prev_total_prs) prev_total_prs="$value" ;;
			prev_total_issues) prev_total_issues="$value" ;;
			prev_ready_prs) prev_ready_prs="$value" ;;
			prev_failing_prs) prev_failing_prs="$value" ;;
			esac
		done <"$QUEUE_METRICS_FILE"
	fi

	[[ "$prev_total_prs" =~ ^-?[0-9]+$ ]] || prev_total_prs=0
	[[ "$prev_total_issues" =~ ^-?[0-9]+$ ]] || prev_total_issues=0
	[[ "$prev_ready_prs" =~ ^-?[0-9]+$ ]] || prev_ready_prs=0
	[[ "$prev_failing_prs" =~ ^-?[0-9]+$ ]] || prev_failing_prs=0

	local pr_delta issue_delta ready_delta failing_delta
	pr_delta=$((total_prs - prev_total_prs))
	issue_delta=$((total_issues - prev_total_issues))
	ready_delta=$((ready_prs - prev_ready_prs))
	failing_delta=$((failing_prs - prev_failing_prs))

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
	new_issue_pct=$((100 - pr_focus_pct))

	local queue_mode
	queue_mode="balanced"
	if [[ "$ready_prs" -gt 0 && "$pr_delta" -ge 0 ]]; then
		queue_mode="merge-heavy"
	elif [[ "$pr_focus_pct" -ge 60 ]]; then
		queue_mode="pr-heavy"
	fi

	cat >"$QUEUE_METRICS_FILE" <<EOF
prev_total_prs=${total_prs}
prev_total_issues=${total_issues}
prev_ready_prs=${ready_prs}
prev_failing_prs=${failing_prs}
EOF

	{
		echo ""
		echo "## Adaptive Queue Governor"
		echo "- Queue totals: PRs=${total_prs} (delta ${pr_delta}), issues=${total_issues} (delta ${issue_delta})"
		echo "- PR execution pressure: ready=${ready_prs} (delta ${ready_delta}), failing_or_changes_requested=${failing_prs} (delta ${failing_delta})"
		echo "- Adaptive mode this cycle: ${queue_mode}"
		echo "- Recommended dispatch focus: PR remediation ${pr_focus_pct}% / new issue dispatch ${new_issue_pct}%"
		echo ""
		echo "PULSE_QUEUE_MODE=${queue_mode}"
		echo "PR_REMEDIATION_FOCUS_PCT=${pr_focus_pct}"
		echo "NEW_ISSUE_DISPATCH_PCT=${new_issue_pct}"
		echo ""
		echo "When PR backlog is rising, prioritize merge-ready and failing-check PR advancement before new issue starts."
	} >>"$STATE_FILE"

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
# - open unassigned, non-blocked issues
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

		local issue_json
		issue_json=$(gh issue list --repo "$slug" --state open --json assignees,labels --limit "$PULSE_RUNNABLE_ISSUE_LIMIT" 2>/dev/null) || issue_json="[]"
		local issue_count
		issue_count=$(echo "$issue_json" | jq '[.[] | select((.assignees | length) == 0 and (.labels | map(.name) | index("status:blocked") | not))] | length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" =~ ^[0-9]+$ ]] || issue_count=0

		local pr_json
		pr_json=$(gh pr list --repo "$slug" --state open --json reviewDecision,statusCheckRollup --limit "$PULSE_RUNNABLE_PR_LIMIT" 2>/dev/null) || pr_json="[]"
		local pr_count
		pr_count=$(echo "$pr_json" | jq '[.[] | select(.reviewDecision == "CHANGES_REQUESTED" or ((.statusCheckRollup // []) | any((.conclusion // .state) == "FAILURE")))] | length' 2>/dev/null) || pr_count=0
		[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

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

	local total=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local queued_numbers
		queued_numbers=$(gh issue list --repo "$slug" --state open --label "status:queued" --json number --jq '.[].number' --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || queued_numbers=""
		if [[ -z "$queued_numbers" ]]; then
			continue
		fi

		while IFS= read -r issue_num; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
			if ! has_worker_for_repo_issue "$issue_num" "$slug"; then
				total=$((total + 1))
			fi
		done <<<"$queued_numbers"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	echo "$total"
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
					echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — CLI usage output detected in ${candidate}" >>"$LOGFILE"
					return 1
				fi
			done
			return 0
		fi
		sleep "$poll_seconds"
		elapsed=$((elapsed + poll_seconds))
	done

	echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — no active worker process within ${grace_seconds}s" >>"$LOGFILE"
	return 1
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
	run_stage_with_timeout "cleanup_worktrees" "$PRE_RUN_STAGE_TIMEOUT" cleanup_worktrees || true
	run_stage_with_timeout "cleanup_stashes" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stashes || true

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
	check_session_count >/dev/null

	# Daily complexity scan (GH#5628): creates simplification-debt issues
	# for .sh files with complex functions and .md agent docs exceeding size
	# threshold. Longest files first. Runs at most once per day.
	# Non-fatal — pulse proceeds even if the scan fails.
	run_stage_with_timeout "complexity_scan" "$PRE_RUN_STAGE_TIMEOUT" run_weekly_complexity_scan || true

	# Daily dedup cleanup: close duplicate simplification-debt issues.
	# Runs after complexity scan so any new duplicates from this cycle are caught.
	# Non-fatal — pulse proceeds even if cleanup fails.
	run_stage_with_timeout "dedup_cleanup" "$PRE_RUN_STAGE_TIMEOUT" run_simplification_dedup_cleanup || true

	# Contribution watch: lightweight scan of external issues/PRs (t1419).
	prefetch_contribution_watch

	# Ensure active labels reflect ownership to prevent multi-worker overlap.
	run_stage_with_timeout "normalize_active_issue_assignments" "$PRE_RUN_STAGE_TIMEOUT" normalize_active_issue_assignments || true

	if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
		echo "[pulse-wrapper] prefetch_state did not complete successfully — aborting this cycle to avoid stale dispatch decisions" >>"$LOGFILE"
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
	runnable_count=$(count_runnable_candidates)
	queued_without_worker=$(count_queued_without_worker)
	[[ "$runnable_count" =~ ^[0-9]+$ ]] || runnable_count=0
	[[ "$queued_without_worker" =~ ^[0-9]+$ ]] || queued_without_worker=0
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
		# before re-counting. Workers dispatched by the LLM pulse take
		# PULSE_LAUNCH_GRACE_SECONDS to start (sandbox-exec + opencode startup).
		# Counting immediately after the LLM exits produces a false-negative
		# (workers running but not yet visible) that triggers duplicate dispatch.
		local grace_wait="$PULSE_LAUNCH_GRACE_SECONDS"
		[[ "$grace_wait" =~ ^[0-9]+$ ]] || grace_wait=20
		if [[ "$grace_wait" -gt 0 ]]; then
			echo "[pulse-wrapper] Early-exit recycle: waiting ${grace_wait}s for dispatched workers to appear (GH#6453)" >>"$LOGFILE"
			sleep "$grace_wait"
		fi

		# Re-check worker state
		local post_max post_active post_runnable post_queued
		post_max=$(get_max_workers_target)
		post_active=$(count_active_workers)
		post_runnable=$(count_runnable_candidates)
		post_queued=$(count_queued_without_worker)
		[[ "$post_max" =~ ^[0-9]+$ ]] || post_max=1
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		[[ "$post_runnable" =~ ^[0-9]+$ ]] || post_runnable=0
		[[ "$post_queued" =~ ^[0-9]+$ ]] || post_queued=0

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

	# Compute initial underfill state and run recycler
	local underfill_output
	underfill_output=$(_compute_initial_underfill)
	local initial_underfilled_mode initial_underfill_pct
	initial_underfilled_mode=$(echo "$underfill_output" | sed -n '1p')
	initial_underfill_pct=$(echo "$underfill_output" | sed -n '2p')

	local pulse_start_epoch
	pulse_start_epoch=$(date +%s)
	run_pulse "$initial_underfilled_mode" "$initial_underfill_pct"

	# Early-exit recycle loop
	local pulse_end_epoch
	pulse_end_epoch=$(date +%s)
	local pulse_duration=$((pulse_end_epoch - pulse_start_epoch))
	_run_early_exit_recycle_loop "$pulse_duration"

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
			local pr_json daily_pr_count
			# GH#4412: use --state all to count merged/closed PRs too
			pr_json=$(gh pr list --repo "$slug" --state all --json createdAt --limit 200 2>/dev/null) || pr_json="[]"
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
