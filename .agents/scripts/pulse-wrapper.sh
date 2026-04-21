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
#      mkdir is POSIX-guaranteed atomic on all filesystems (APFS, HFS+, ext4)
#      and is the only lock primitive — flock was removed in GH#18668 after
#      recurring FD-inheritance deadlocks. See reference/bash-fd-locking.md.
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
# Instance lock protocol (GH#4513, GH#18668):
#   Uses mkdir atomicity as the ONLY lock primitive. mkdir is guaranteed
#   atomic by POSIX on all local filesystems — the kernel ensures only one
#   process succeeds even under concurrent invocations. The lock directory
#   contains a PID file so stale locks (from SIGKILL/power loss) can be
#   detected and cleared on the next startup. A trap ensures cleanup on
#   normal exit and SIGTERM.
#
#   flock was previously layered on top as a secondary guard, but four
#   recurring deadlock incidents (GH#18094, GH#18141, GH#18264, GH#18668)
#   all traced to FD 9 being inherited by daemonising git hooks and
#   ancillary workers. bash has no built-in fcntl(F_SETFD, FD_CLOEXEC),
#   and annotation-based `9>&-` coverage is a structurally incomplete
#   blocklist. flock was removed entirely in GH#18668 (Path A) — see
#   reference/bash-fd-locking.md for the full rationale and policy.
#
# Called by launchd every 120s via the supervisor-pulse plist.

set -euo pipefail

#######################################
# PATH normalisation
# The MCP shell environment may have a minimal PATH that excludes /bin
# and other standard directories, causing `env bash` to fail. Ensure
# essential directories are always present.
#######################################
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"

#######################################
# FD budget: raise soft limit to avoid exhaustion (GH#19044)
#
# The launchd plist inherits macOS default maxfiles (256 soft, unlimited
# hard). The pulse sources ~20 modules and spawns gh/jq/git subprocesses
# per repo per cycle — 256 FDs is structurally insufficient. Raise the
# soft limit to 4096 (well within the hard limit) BEFORE sourcing any
# modules or spawning any subprocesses.
#
# This is the primary fix for the FD exhaustion observed in GH#18787:
#   pulse-simplification-state.sh: redirection error: cannot duplicate fd: Too many open files
#
# Defence-in-depth: setup-modules/schedulers.sh also sets
# SoftResourceLimits.NumberOfFiles=4096 in the launchd plist, but the
# ulimit raise here is the runtime safety net in case the plist is stale.
#######################################
ulimit -n 4096 2>/dev/null || ulimit -n 1024 2>/dev/null || true

# Regression guard: assert FD budget is adequate. Log loudly if not.
_pulse_fd_limit=$(ulimit -n 2>/dev/null || echo "256")
if [[ "$_pulse_fd_limit" =~ ^[0-9]+$ ]] && [[ "$_pulse_fd_limit" -lt 1024 ]]; then
	printf '[pulse-wrapper] WARNING: FD soft limit is %s (< 1024). Pulse may hit FD exhaustion. Run: ulimit -n 4096 or update the launchd plist SoftResourceLimits.NumberOfFiles (GH#19044)\n' "$_pulse_fd_limit" >&2
fi
unset _pulse_fd_limit

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
# when --self-check or --dry-run appears anywhere in the argument list
# (or PULSE_DRY_RUN=1 is set) so CI, post-install verification, and
# interactive debugging aren't delayed by up to 30 s of random sleep.
# GH#18614: iterate through all args — not just $1 — so diagnostic
# flags are detected regardless of their position in the invocation.
_pulse_skip_jitter=0
if [[ "${PULSE_DRY_RUN:-0}" == "1" ]]; then
	_pulse_skip_jitter=1
else
	for _pulse_arg in "$@"; do
		if [[ "$_pulse_arg" == "--self-check" || "$_pulse_arg" == "--dry-run" ]]; then
			_pulse_skip_jitter=1
			break
		fi
	done
	unset _pulse_arg
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
# Source shared-constants.sh BEFORE config-helper.sh so the bash 4+ re-exec
# guard (t2087/t2176) fires at BASH_SOURCE depth 1, where the outermost caller
# is unambiguously pulse-wrapper.sh. If config-helper.sh is sourced first and it
# sources shared-constants.sh, the guard would see the intermediate helper at
# BASH_SOURCE[1] and re-exec the wrong script. (GH#19632)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true
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
# GH#19836: further split — downstream conflict + feedback clusters into separate
# modules. Source order matters: pulse-merge.sh first (defines the dispatcher
# callers), then the two downstream modules. Bash's lazy function resolution
# handles the runtime cross-module calls (e.g., _check_pr_merge_gates →
# _dispatch_pr_fix_worker in pulse-merge-feedback.sh) without issue.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-conflict.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-feedback.sh"
# Phase 5 (t1973, GH#18380): cleanup + issue-reconcile extracted into two modules.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-cleanup.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-issue-reconcile.sh"
# Phase 6 (t1974, GH#18382): simplification cluster extracted (largest single extraction).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-simplification.sh"
# t2020 (GH#18483): state sub-cluster split out to clear the 2,000-line gate
# that was blocking #18420 (t1993). Must be sourced AFTER pulse-simplification.sh
# because _simplification_state_backfill_closed in the state module calls
# _complexity_scan_has_existing_issue which stays in the parent module. Bash
# resolves function names at call time, so source order is informational
# rather than strict, but this order reads "parent, then state sub-cluster".
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-simplification-state.sh"
# Phase 7 (t1975, GH#18385): prefetch cluster extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-prefetch.sh"
# Phase 8 (t1976, GH#18387): triage cluster extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-triage.sh"
# Phase 9 (t1977, GH#18389): dispatch-core + dispatch-engine extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# Phase 10 (t1978, GH#18391): FINAL — quality-debt + ancillary-dispatch extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-quality-debt.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-ancillary-dispatch.sh"
# GH#19949: canonical-repo fast-forward + stale worktree sweep (30min cadence).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-canonical-maintenance.sh"
# t2350 (GH#19948): DIRTY-PR sweep runs every 30min after the merge pass.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dirty-pr-sweep.sh"

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
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-3600}"                                       # 60 min hard ceiling — workers need 10-20 min to solve issues; 15 min was killing active workers (GH#19166)
PULSE_IDLE_TIMEOUT="${PULSE_IDLE_TIMEOUT:-1800}"                                             # 30 min idle before kill — the per-worker activity watchdog (300s) is the real stall detector
PULSE_IDLE_CPU_THRESHOLD="${PULSE_IDLE_CPU_THRESHOLD:-2}"                                    # CPU% below this = idle (0-100 scale) — lowered from 5 to reduce false positives on I/O-bound work
PULSE_PROGRESS_TIMEOUT="${PULSE_PROGRESS_TIMEOUT:-1800}"                                     # 30 min no log output = stuck — was 10 min, killed workers mid-API-call
PULSE_COLD_START_TIMEOUT="${PULSE_COLD_START_TIMEOUT:-1800}"                                 # 30 min grace before first output (opencode 1.4.x cold start takes longer)
PULSE_COLD_START_TIMEOUT_UNDERFILLED="${PULSE_COLD_START_TIMEOUT_UNDERFILLED:-1200}"         # 20 min grace when below worker target
PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT="${PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT:-3600}" # 60 min stale-process cutoff when worker pool is underfilled — was 15 min, same problem as PULSE_STALE_THRESHOLD
PULSE_ACTIVE_REFILL_INTERVAL="${PULSE_ACTIVE_REFILL_INTERVAL:-120}"                          # Min seconds between wrapper-side refill attempts during an active pulse
PULSE_ACTIVE_REFILL_IDLE_MIN="${PULSE_ACTIVE_REFILL_IDLE_MIN:-60}"                           # Idle seconds before wrapper-side refill may intervene during monitoring sleep
PULSE_ACTIVE_REFILL_STALL_MIN="${PULSE_ACTIVE_REFILL_STALL_MIN:-120}"                        # Progress stall seconds before wrapper-side refill may intervene during an active pulse
ORPHAN_MAX_AGE="${ORPHAN_MAX_AGE:-7200}"                                                     # 2 hours — kill orphans older than this
ORPHAN_WORKTREE_GRACE_SECS="${ORPHAN_WORKTREE_GRACE_SECS:-1800}"                             # 30 min grace for 0-commit worktrees with no open PR (t1884)
RAM_PER_WORKER_MB="${RAM_PER_WORKER_MB:-512}"                                                # 512 MB per worker (opencode headless is lightweight)
RAM_RESERVE_MB="${RAM_RESERVE_MB:-6144}"                                                     # 6 GB reserved for OS + user apps
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
PULSE_STAGE_TIMINGS_LOG="${PULSE_STAGE_TIMINGS_LOG:-${HOME}/.aidevops/logs/pulse-stage-timings.log}"       # Structured TSV stage timing log (GH#20025)
PULSE_LOCK_MAX_AGE_S="${AIDEVOPS_PULSE_LOCK_MAX_AGE_S:-1800}"                                              # Force-reclaim mkdir lock after this age in seconds (GH#20025)
PULSE_PREFETCH_PR_LIMIT="${PULSE_PREFETCH_PR_LIMIT:-200}"                                                  # Open PR list window per repo for pre-fetched state
PULSE_PREFETCH_ISSUE_LIMIT="${PULSE_PREFETCH_ISSUE_LIMIT:-200}"                                            # Open issue list window for pulse prompt payload (keep compact)
PULSE_PREFETCH_CACHE_FILE="${PULSE_PREFETCH_CACHE_FILE:-${HOME}/.aidevops/logs/pulse-prefetch-cache.json}" # Delta prefetch state cache (GH#15286)
PULSE_RATE_LIMIT_FLAG="${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}"   # GH#18979: set by prefetch on detected GraphQL rate-limit exhaustion; checked by _preflight_prefetch_and_scope to abort cycle cleanly
AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD:-0.05}"              # t2690: Fraction of GraphQL budget below which the rate-limit circuit breaker trips (default 5% = 250/5000). Set to 0 to disable.
export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD
PULSE_PREFETCH_FULL_SWEEP_INTERVAL="${PULSE_PREFETCH_FULL_SWEEP_INTERVAL:-14400}"                          # Full sweep interval in seconds (default 4h) (GH#15286, GH#18979: reduced from 24h to prevent stale-cache drift on active repos)
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
PULSE_BATCH_PREFETCH_ENABLED="${PULSE_BATCH_PREFETCH_ENABLED:-1}"                                          # GH#19963: Enable batch prefetch via org-level gh search (L3 cache layer). Set to 0 for safe rollback.
PULSE_BATCH_PREFETCH_CACHE_DIR="${PULSE_BATCH_PREFETCH_CACHE_DIR:-${HOME}/.aidevops/logs/batch-prefetch}"  # GH#19963: Directory for batch prefetch per-slug cache files
PULSE_BATCH_SEARCH_LIMIT="${PULSE_BATCH_SEARCH_LIMIT:-200}"                                                # GH#19963: Max results per gh search call (Search API --limit cap)

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
#        (tier:simple → tier:standard → tier:thinking).
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
FAST_FAIL_AGE_OUT_SECONDS="${FAST_FAIL_AGE_OUT_SECONDS:-86400}"         # Auto-reset HARD STOP after 24h quiet period (t2397)
FAST_FAIL_AGE_OUT_MIN_COUNT="${FAST_FAIL_AGE_OUT_MIN_COUNT:-5}"         # Only age-out issues at/above HARD STOP threshold (t2397)
FAST_FAIL_AGE_OUT_MAX_RESETS="${FAST_FAIL_AGE_OUT_MAX_RESETS:-3}"       # Max auto-resets before NMR escalation (t2397)

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
LOCKDIR="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
# GH#18264: tracks whether this process successfully acquired the instance lock.
# release_instance_lock() checks this flag so it only removes LOCKDIR when
# this process actually owns the lock.
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
COMPLEXITY_DEBT_COUNT_FILE="${HOME}/.aidevops/logs/complexity-debt-count" # tracks open function-complexity-debt count for stall detection
DEDUP_CLEANUP_LAST_RUN="${HOME}/.aidevops/logs/dedup-cleanup-last-run"
DEDUP_CLEANUP_INTERVAL="${DEDUP_CLEANUP_INTERVAL:-86400}"  # 1 day in seconds
DEDUP_CLEANUP_BATCH_SIZE="${DEDUP_CLEANUP_BATCH_SIZE:-50}" # Max issues to close per run
CODERABBIT_REVIEW_LAST_RUN="${HOME}/.aidevops/logs/coderabbit-review-last-run"
CODERABBIT_REVIEW_INTERVAL="${CODERABBIT_REVIEW_INTERVAL:-86400}" # 1 day in seconds
CODERABBIT_REVIEW_ISSUE="2632"                                    # Issue where CodeRabbit full reviews are requested
POST_MERGE_SCANNER_LAST_RUN="${HOME}/.aidevops/logs/post-merge-scanner-last-run"
POST_MERGE_SCANNER_INTERVAL="${POST_MERGE_SCANNER_INTERVAL:-86400}"             # 1 day in seconds
AUTO_DECOMPOSER_INTERVAL="${AUTO_DECOMPOSER_INTERVAL:-604800}"                   # 7 days per-parent re-file interval (t2573; was global 24h gate t2442)
AUTO_DECOMPOSER_PARENT_STATE="${HOME}/.aidevops/logs/auto-decomposer-parent-state.json" # per-parent last-filed epochs (t2573)
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
_PULSE_HEALTH_IDLE_REPO_SKIPS=0 # GH#18984 (t2098): repos skipped due to cache-hit idle detection
_PULSE_HEALTH_BATCH_SEARCH_CALLS=0 # GH#19963: Search API calls made by batch prefetch
_PULSE_HEALTH_BATCH_CACHE_HITS=0   # GH#19963: per-repo batch cache hits (avoided GraphQL calls)

# t2433/GH#20071: Cycle-scoped repo refresh sentinel.
# Keyed by repo_path; set to "1" once the repo has been pulled this cycle.
# Prevents multiple git fetch+pull calls for the same repo within one
# dispatch cycle (dispatch loop + triage re-evaluation can both touch the
# same repo). Bash 4+ associative array — safe because shared-constants.sh
# re-execs this script under modern bash when invoked with bash 3.2.
declare -A _PULSE_REFRESHED_THIS_CYCLE=()

# Validate complexity scan configuration (defined above, validated here)
COMPLEXITY_SCAN_INTERVAL=$(_validate_int COMPLEXITY_SCAN_INTERVAL "$COMPLEXITY_SCAN_INTERVAL" 900 300)
COMPLEXITY_LLM_SWEEP_INTERVAL=$(_validate_int COMPLEXITY_LLM_SWEEP_INTERVAL "$COMPLEXITY_LLM_SWEEP_INTERVAL" 21600 3600)
COMPLEXITY_FUNC_LINE_THRESHOLD=$(_validate_int COMPLEXITY_FUNC_LINE_THRESHOLD "$COMPLEXITY_FUNC_LINE_THRESHOLD" 100 50)
COMPLEXITY_FILE_VIOLATION_THRESHOLD=$(_validate_int COMPLEXITY_FILE_VIOLATION_THRESHOLD "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" 1 1)
COMPLEXITY_MD_MIN_LINES=$(_validate_int COMPLEXITY_MD_MIN_LINES "$COMPLEXITY_MD_MIN_LINES" 50 10)
CODERABBIT_REVIEW_INTERVAL=$(_validate_int CODERABBIT_REVIEW_INTERVAL "$CODERABBIT_REVIEW_INTERVAL" 86400 3600)
POST_MERGE_SCANNER_INTERVAL=$(_validate_int POST_MERGE_SCANNER_INTERVAL "$POST_MERGE_SCANNER_INTERVAL" 86400 3600)
AUTO_DECOMPOSER_INTERVAL=$(_validate_int AUTO_DECOMPOSER_INTERVAL "$AUTO_DECOMPOSER_INTERVAL" 604800 86400)
FAST_FAIL_SKIP_THRESHOLD=$(_validate_int FAST_FAIL_SKIP_THRESHOLD "$FAST_FAIL_SKIP_THRESHOLD" 5 1)
FAST_FAIL_EXPIRY_SECS=$(_validate_int FAST_FAIL_EXPIRY_SECS "$FAST_FAIL_EXPIRY_SECS" 604800 60)
FAST_FAIL_INITIAL_BACKOFF_SECS=$(_validate_int FAST_FAIL_INITIAL_BACKOFF_SECS "$FAST_FAIL_INITIAL_BACKOFF_SECS" 600 60)
FAST_FAIL_MAX_BACKOFF_SECS=$(_validate_int FAST_FAIL_MAX_BACKOFF_SECS "$FAST_FAIL_MAX_BACKOFF_SECS" 604800 600)
FAST_FAIL_AGE_OUT_SECONDS=$(_validate_int FAST_FAIL_AGE_OUT_SECONDS "$FAST_FAIL_AGE_OUT_SECONDS" 86400 3600)
FAST_FAIL_AGE_OUT_MIN_COUNT=$(_validate_int FAST_FAIL_AGE_OUT_MIN_COUNT "$FAST_FAIL_AGE_OUT_MIN_COUNT" 5 1)
FAST_FAIL_AGE_OUT_MAX_RESETS=$(_validate_int FAST_FAIL_AGE_OUT_MAX_RESETS "$FAST_FAIL_AGE_OUT_MAX_RESETS" 3 1)

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

# _compute_struggle_ratio provided by worker-lifecycle-common.sh

# check_session_count: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate the duplicate. The shared version
# returns the count; callers handle warning logs independently.

#######################################
# t2433/GH#20071: Refresh a repo from remote before the large-file gate
# measures it. Without this, stale local checkouts (post-split-PR) cause
# the gate to fire on pre-split line counts, creating spurious file-size-debt
# issues every cycle until a worker dispatch triggers a pull independently.
#
# Idempotent within a process: uses _PULSE_REFRESHED_THIS_CYCLE (associative
# array declared at module scope) as a cycle-scoped sentinel keyed by
# repo_path. The first call for a given path fetches + fast-forwards;
# subsequent calls in the same process are no-ops. The array is inherited
# empty by every subshell (dispatch subshell, run_stage_with_timeout fork)
# so each independent context starts fresh — this is intentional: each
# context needs at most one pull per repo.
#
# Uses --ff-only to avoid catastrophic rebase conflicts in the pulse checkout.
# Uses git fetch before pull so the local is always in sync with origin/HEAD.
#
# GH#17584 context preserved: the original motivation for pulling before
# worker dispatch (workers close issues as "Invalid — file does not exist"
# on stale checkouts) is covered here at the EARLIER point — before any
# gate evaluation — rather than the later worker-launch point.
#
# Arguments:
#   $1 - repo_path: absolute path to the git working tree to refresh
# Returns: always 0 (failures are logged but never fatal — callers proceed
#   with current checkout, same as the previous git pull || { warn; } pattern)
#######################################
_pulse_refresh_repo() {
	local repo_path="$1"
	[[ -n "$repo_path" ]] || return 0

	# Sentinel: already refreshed this repo in this process context.
	if [[ "${_PULSE_REFRESHED_THIS_CYCLE[$repo_path]+_}" ]]; then
		return 0
	fi
	# Mark immediately so concurrent callers in the same process don't double-pull.
	_PULSE_REFRESHED_THIS_CYCLE[$repo_path]=1

	if ! git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "[pulse-wrapper] _pulse_refresh_repo: ${repo_path} is not a git work-tree — skipping" >>"$LOGFILE"
		return 0
	fi

	git -C "$repo_path" fetch --quiet origin >>"$LOGFILE" 2>&1 || {
		echo "[pulse-wrapper] _pulse_refresh_repo: git fetch failed for ${repo_path} — proceeding with current checkout" >>"$LOGFILE"
		return 0
	}
	git -C "$repo_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1 || {
		echo "[pulse-wrapper] _pulse_refresh_repo: git pull --ff-only failed for ${repo_path} (diverged branch?) — proceeding with current checkout" >>"$LOGFILE"
	}
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
	local -a pulse_cmd=("$HEADLESS_RUNTIME_HELPER" run --role pulse --session-key supervisor-pulse --dir "$PULSE_DIR" --title "Supervisor Pulse" --agent Automate --prompt "$prompt" --tier sonnet)
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
# Daily complexity scan helpers (GH#5628, GH#15285)
#######################################

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
# creates a tier:thinking issue for LLM-powered deep review of stalled debt.
#
# Runs at most once per COMPLEXITY_SCAN_INTERVAL (default 15 min).
# Creates up to 5 issues per run; open cap (500) prevents backlog flooding.
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################

# count_active_workers: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate divergence with stats-functions.sh.

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

#######################################
# GH#17827, t2014: Triage failure retry cap (default 1 — single attempt).
#
# When triage fails (no review posted), the GH#17873 fix intentionally
# skips caching the content hash so the next cycle retries. But failing
# triages are overwhelmingly deterministic (format-validation rejections,
# not transient model quota) — three retries per content version burn
# three full opus agent invocations (~100K chars each) and three
# lock/unlock pairs on the issue timeline, all to reach the same outcome.
#
# Solution: cap retries at 1. The FIRST failure increments the counter
# to 1, sees 1 >= TRIAGE_MAX_RETRIES, caches the hash, and marks the
# issue with triage-failed. Subsequent cycles skip via the content-hash
# cache — zero lock/unlock, zero agent invocations. A new human comment
# changes the hash and resets the counter, giving another attempt.
#
# Transient failures (network, gh API, model rate-limit) are caught
# earlier in the dispatch loop (before lock_issue_for_worker) or
# handled by the model rotation pool, so the retry budget here adds no
# value for transients — only cost for deterministic failures.
#
# Maintainers can force a re-triage by removing the triage-failed label
# and the corresponding .failures/.hash files in TRIAGE_CACHE_DIR.
#######################################
TRIAGE_MAX_RETRIES="${TRIAGE_MAX_RETRIES:-1}"

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
#
# Defaults are owned by pulse-triage.sh (module-level := block) which is
# sourced above. Declarations removed from here to eliminate duplicate-default
# drift (t2143). Override via env before sourcing pulse-triage.sh if needed.
#######################################

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

# t2024: Scoped-range exemption for the large-file gate.
#
# The gate's purpose is to prevent a worker from paying the complexity tax
# of navigating a huge file when it only needs to understand a small section.
# If the issue body cites an explicit line range (e.g., "EDIT: file.sh:221-253")
# and the range is at most SCOPED_RANGE_THRESHOLD lines, the worker can
# navigate the cited range directly without reading the whole file — so we
# pass the gate regardless of the enclosing file's total line count.
#
# Single-line citations (e.g., "file.sh:1477") are treated as context references
# for the human reader, not implementation targets, and are excluded from
# gate evaluation entirely. A worker never "edits line 1477" — they edit a
# function or a range; a bare line number is documentation, not a target.
#
# File references without any line qualifier (e.g., "file.sh") fall through
# to the existing file-size check — this preserves the original safety for
# whole-file rewrites where the worker really does need to understand everything.
SCOPED_RANGE_THRESHOLD="${SCOPED_RANGE_THRESHOLD:-300}"

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

# ---------------------------------------------------------------------------
# _pulse_execute_self_check
#
# Phase 0 (t1963, GH#18357): validate that all expected functions and module
# include-guards are present. Extracted from main() (GH#18689) to reduce
# cyclomatic complexity — the self-check body was ~100 lines inside main().
#
# Exit 0: all functions and guards present.
# Exit 1: at least one expected symbol is missing (names printed to stderr).
# ---------------------------------------------------------------------------
_pulse_execute_self_check() {
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
		get_repo_role_by_slug
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
		_pulse_execute_self_check
		_pulse_handle_self_check
		_pulse_setup_dry_run_mode
		_pulse_run_deterministic_pipeline
		_pulse_maybe_run_llm_supervisor
		_carry_forward_pr_diff
		_dispatch_pr_fix_worker
		_close_conflicting_pr
		_interactive_pr_is_stale
		_interactive_pr_trigger_handover
		_dispatch_ci_fix_worker
		_dispatch_conflict_fix_worker
		run_canonical_maintenance
		dirty_pr_sweep_all_repos
		_pulse_refresh_repo
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
	# Phase 6 (t1974, GH#18382): simplification cluster (29 fns, largest)
	# Phase 7 (t1975, GH#18385): prefetch cluster (26 fns)
	# Phase 8 (t1976, GH#18387): triage cluster (10 fns)
	# Phase 9 (t1977, GH#18389): dispatch-core + dispatch-engine (26 fns)
	# Phase 10 (t1978, GH#18391): quality-debt + ancillary-dispatch (FINAL — clears 2K gate)
	# GH#19836: pulse-merge.sh further split into three modules (conflict + feedback extracted).
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
		_PULSE_MERGE_CONFLICT_LOADED
		_PULSE_MERGE_FEEDBACK_LOADED
		_PULSE_CLEANUP_LOADED
		_PULSE_ISSUE_RECONCILE_LOADED
		_PULSE_SIMPLIFICATION_LOADED
		_PULSE_SIMPLIFICATION_STATE_LOADED
		_PULSE_PREFETCH_LOADED
		_PULSE_TRIAGE_LOADED
		_PULSE_DISPATCH_CORE_LOADED
		_PULSE_DISPATCH_ENGINE_LOADED
		_PULSE_QUALITY_DEBT_LOADED
		_PULSE_ANCILLARY_DISPATCH_LOADED
		_PULSE_CANONICAL_MAINTENANCE_LOADED
		_PULSE_DIRTY_PR_SWEEP_LOADED
	)
	local _sc_guard _sc_val
	# The `${array[@]+"${array[@]}"}` pattern is safe under `set -u`
	# when the array is empty — required in Phase 0 where no module
	# guards exist yet.
	# GH#18614: all guard names in _sc_expected_guards are simple scalar
	# variables (e.g. _PULSE_MODEL_ROUTING_LOADED="1"). The indirect
	# expansion ${!_sc_guard:-} is therefore safe — it will never silently
	# read only the first element of an array. Never add array names to
	# _sc_expected_guards; use a dedicated scalar for each module.
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
}

# ---------------------------------------------------------------------------
# _pulse_run_deterministic_pipeline
#
# Deterministic cycle stages: merge pass, dependency graph, blocked-status
# refresh, fill floor, routine evaluation, health snapshot, cycle index, and
# instance lock release. Extracted from main() (GH#18689) to reduce function
# length below the 100-line threshold.
#
# Arguments:
#   $1 — cycle_start_epoch (seconds since epoch, captured in main())
#
# Side effects:
#   - merges ready PRs across all repos
#   - writes health snapshot and cycle index JSONL record
#   - releases the instance lock so the LLM session runs lock-free
#
# Exit code: always 0
# ---------------------------------------------------------------------------
_pulse_run_deterministic_pipeline() {
	local cycle_start_epoch="$1"

	# Deterministic merge pass: approve and merge all ready PRs across pulse
	# repos. This runs BEFORE the LLM session because merging is free (no
	# worker slot) and deterministic (no judgment needed). Previously merging
	# was LLM-only, which meant backlogs of 100+ PRs accumulated when the
	# LLM failed to execute merge steps or the prefetch showed 0 PRs.
	run_stage_with_timeout "deterministic_merge_pass" "$PRE_RUN_STAGE_TIMEOUT" \
		merge_ready_prs_all_repos || true

	# t2350 (GH#19948): DIRTY-PR sweep — auto-rebase young + TODO-only conflicts,
	# auto-close stale abandoned PRs, escalate anything else. Internally gated
	# on DIRTY_PR_SWEEP_INTERVAL (default 30min) so this is cheap to call every
	# cycle. Runs AFTER merge pass so we never sweep a PR that was already
	# about to be merged. Failures are non-fatal — the sweep is advisory.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping dirty-pr-sweep" >>"$LOGFILE"
	else
		run_stage_with_timeout "dirty_pr_sweep" "$PRE_RUN_STAGE_TIMEOUT" \
			dirty_pr_sweep_all_repos || true
	fi
	# Accumulate health counters written by merge_ready_prs_all_repos (GH#18571, GH#15107).
	# The function runs in a subshell via run_stage_with_timeout, so variable
	# updates are lost. Read the temp file it writes and accumulate here.
	local _merge_health_file="${TMPDIR:-/tmp}/pulse-health-merge-$$.tmp"
	if [[ -f "$_merge_health_file" ]]; then
		local _mhf_merged=0 _mhf_closed=0
		read -r _mhf_merged _mhf_closed <"$_merge_health_file" || true
		[[ "$_mhf_merged" =~ ^[0-9]+$ ]] || _mhf_merged=0
		[[ "$_mhf_closed" =~ ^[0-9]+$ ]] || _mhf_closed=0
		_PULSE_HEALTH_PRS_MERGED=$((_PULSE_HEALTH_PRS_MERGED + _mhf_merged))
		_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=$((_PULSE_HEALTH_PRS_CLOSED_CONFLICTING + _mhf_closed))
		rm -f "$_merge_health_file" || true
	fi

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

	# GH#19949: Canonical-repo fast-forward + stale worktree sweep.
	# Cadence-gated (~30 min) — the function's internal cadence check skips
	# if too soon. Runs after routine evaluation and before health snapshot
	# so the snapshot reflects the maintenance outcome.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping canonical maintenance" >>"$LOGFILE"
	else
		run_stage_with_timeout "canonical_maintenance" "$PRE_RUN_STAGE_TIMEOUT" \
			run_canonical_maintenance || true
	fi

	# t2418 (GH#20016): Dashboard freshness watchdog. Detects when the
	# supervisor health dashboard issue has not been refreshed within the
	# threshold (default 48h) and files a `review-followup` + `priority:high`
	# alert. Cadence-gated internally (default 1h) so this is cheap to call
	# every cycle. Non-fatal — failures (gh offline, no dashboards cached)
	# log and return 0.
	#
	# Structure note: two single-arm `if`s (early-return pattern) rather than
	# `if ... elif ...` because the nesting-depth AWK counter in
	# code-quality.yml mis-counts `elif` as opening a new nesting level (the
	# loose regex `(if|for|while|until|case)` matches `if ` inside `elif `).
	local _dfc_script="${SCRIPT_DIR}/dashboard-freshness-check.sh"
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping dashboard freshness check" >>"$LOGFILE"
	fi
	if [[ ! -f "$STOP_FLAG" && -x "$_dfc_script" ]]; then
		run_stage_with_timeout "dashboard_freshness_check" "$PRE_RUN_STAGE_TIMEOUT" \
			bash "$_dfc_script" scan || true
	fi

	# Write structured health snapshot for instant diagnosis (GH#15107)
	write_pulse_health_file || true

	# Append one JSONL record to the cycle index (t1886)
	local _cycle_end_epoch
	_cycle_end_epoch=$(date +%s)
	local _cycle_duration=$((_cycle_end_epoch - cycle_start_epoch))
	append_cycle_index "$_cycle_duration" || true

	# Release the instance lock BEFORE the LLM session so the next 2-min
	# cycle can run deterministic ops (merge pass + fill floor) concurrently.
	# The LLM session is protected by its own stall/daily-sweep gating,
	# and workers are protected by 7-layer dedup guards (assignee labels,
	# DISPATCH_CLAIM comments, ledger checks). No risk of duplication.
	release_instance_lock
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_maybe_run_llm_supervisor
#
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
#
# Extracted from main() (GH#18689) to reduce function length.
# Exit code: always 0
# ---------------------------------------------------------------------------
_pulse_maybe_run_llm_supervisor() {
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

# ---------------------------------------------------------------------------
# _pulse_handle_self_check
#
# Phase 0 (t1963, GH#18357): --self-check short-circuit for CI, pre-edit
# verification, and post-install smoke testing. Runs before any lock,
# state mutation, or side effect. Sources are already in place (the
# wrapper sources its helpers before main() is called), so by the time
# control reaches here every function the wrapper claims to define has
# been parsed.
#
# Scans "$@" for --self-check (GH#18614: position-independent).
# Extracted from main() (GH#18689) to reduce function length.
#
# Returns:
#   0 — --self-check found and all symbols verified (self-check passed)
#   1 — --self-check found but one or more symbols missing (self-check failed)
#   2 — --self-check not present; caller should continue normally
# ---------------------------------------------------------------------------
_pulse_handle_self_check() {
	local _sc_flag=0
	local _arg
	for _arg in "$@"; do
		if [[ "$_arg" == "--self-check" ]]; then
			_sc_flag=1
			break
		fi
	done
	unset _arg
	[[ "$_sc_flag" -eq 0 ]] && return 2
	_pulse_execute_self_check
	return $?
}

# ---------------------------------------------------------------------------
# _pulse_setup_dry_run_mode
#
# Phase 0 (t1963, GH#18357): --dry-run flag sets PULSE_DRY_RUN=1 so the
# cycle can short-circuit before touching destructive operations. This
# smoke-tests bootstrap, sourcing, config validation, lock acquisition,
# and the main() prelude without dispatching workers, merging PRs,
# writing GitHub state, or removing worktrees.
#
# Phase 0 scope is narrow by design: --dry-run runs up to (but not
# through) _run_preflight_stages. Later phases may widen --dry-run by
# shimming individual destructive call sites with a _dry_run_log() helper.
#
# USAGE NOTE: --dry-run still runs acquire_instance_lock, session_gate,
# and dedup. For CI/smoke tests, run in a sandboxed $HOME:
#   SANDBOX=$(mktemp -d)
#   HOME="$SANDBOX/home" PULSE_JITTER_MAX=0 pulse-wrapper.sh --dry-run
#
# Scans "$@" for --dry-run (GH#18614: position-independent).
# Extracted from main() (GH#18689) to reduce function length.
# Exit code: always 0
# ---------------------------------------------------------------------------
_pulse_setup_dry_run_mode() {
	local _dr_arg
	for _dr_arg in "$@"; do
		if [[ "$_dr_arg" == "--dry-run" ]]; then
			export PULSE_DRY_RUN=1
			break
		fi
	done
	unset _dr_arg
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_setup_canary_mode
#
# Phase 0 (GH#18790): --canary flag sets PULSE_CANARY_MODE=1 so main()
# can short-circuit after acquire_instance_lock. This exercises:
#   1. Script sourcing under set -euo pipefail (all top-level declarations)
#   2. _pulse_handle_self_check — the exact function GH#18770 broke
#   3. acquire_instance_lock — the next downstream function
# and exits 0 without entering the pulse loop, dispatching workers, or
# making any GitHub API calls.
#
# Scans "$@" for --canary (position-independent).
# Exit code: always 0
# ---------------------------------------------------------------------------
_pulse_setup_canary_mode() {
	local _can_arg
	for _can_arg in "$@"; do
		if [[ "$_can_arg" == "--canary" ]]; then
			export PULSE_CANARY_MODE=1
			break
		fi
	done
	unset _can_arg
	return 0
}

main() {
	# GH#18670: declare this process as headless BEFORE anything else runs
	# so every child shell stage sees AIDEVOPS_HEADLESS and
	# detect_session_origin() returns "worker". Without this, shell stages
	# default to "interactive", label new issues with origin:interactive,
	# and trigger GH#18352's dedup guard (origin:interactive + maintainer
	# assignee → blocked), draining the queue indefinitely. Scoped to
	# main() so callers sourcing pulse-wrapper.sh for testing do not
	# inherit the env var.
	export AIDEVOPS_HEADLESS=true

	# GH#18689: --self-check and --dry-run arg scanning extracted to helpers.
	# GH#18770: the `_sc_rc=$?` capture MUST be guarded by `|| _sc_rc=$?`
	# on the call itself — otherwise, under `set -euo pipefail` (line 42),
	# any non-zero return from _pulse_handle_self_check (which is the
	# normal path when --self-check is not requested: returns 2 as the
	# "not a self-check invocation" signal) kills the script at the call
	# site BEFORE `_sc_rc=$?` can capture it. The pulse then dies with
	# exit 2 on every launchd restart, never acquiring the instance lock,
	# never dispatching. Regressed in PR #18712 which extracted the
	# handler without reviewing the set -e exit-code propagation. Same
	# bug class as the aidevops.sh getent regression (GH#18784) and the
	# interactive-session-helper set -e kill (GH#18786). See the pre-merge
	# checklist item 4 in `.agents/reference/bash-compat.md`.
	local _sc_rc=0
	_pulse_handle_self_check "$@" || _sc_rc=$?
	[[ "$_sc_rc" -ne 2 ]] && return "$_sc_rc"
	_pulse_setup_dry_run_mode "$@"
	_pulse_setup_canary_mode "$@"

	# GH#4513: Acquire exclusive instance lock FIRST — before any other
	# check. Uses mkdir atomicity as the ONLY primitive (POSIX-guaranteed,
	# works identically on macOS APFS/HFS+ and Linux ext4/btrfs/xfs).
	#
	# flock was removed in GH#18668 after recurring FD 9 inheritance
	# deadlocks. bash has no built-in fcntl(F_SETFD, FD_CLOEXEC), so any
	# persistent FD held by the parent is inherited by every daemonising
	# descendant (git hooks, ancillary workers). See the module header of
	# pulse-instance-lock.sh and reference/bash-fd-locking.md for history.
	#
	# Register EXIT trap BEFORE acquiring the lock so the lock is always
	# released on exit — including set -e aborts, SIGTERM, and return paths.
	# SIGKILL cannot be trapped; stale-lock detection handles that case.
	trap 'release_instance_lock' EXIT

	if ! acquire_instance_lock; then
		return 0
	fi

	# --canary short-circuit (GH#18790): sourcing, _pulse_handle_self_check,
	# and acquire_instance_lock have all passed cleanly. The EXIT trap releases
	# the lock. Return 0 without entering the pulse loop, session gate, dedup,
	# log rotation, or any side-effecting stage.
	if [[ "${PULSE_CANARY_MODE:-0}" == "1" ]]; then
		printf 'canary: ok (sourcing + _pulse_handle_self_check + acquire_instance_lock passed)\n'
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

	# Run deterministic pipeline: merge pass, dep graph, blocked-status
	# refresh, fill floor, routine evaluation, health snapshot, cycle index,
	# and instance lock release. GH#18689: extracted to helper.
	_pulse_run_deterministic_pipeline "$_cycle_start_epoch"

	# Run LLM supervisor if stall/daily-sweep/force conditions are met.
	# GH#18689: extracted to _pulse_maybe_run_llm_supervisor().
	_pulse_maybe_run_llm_supervisor

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
STALE_OPENCODE_MAX_AGE="${STALE_OPENCODE_MAX_AGE:-28800}" # 8 hours — was 4h, increased to avoid killing long-running complex tasks

#######################################
# Enrich failed issues with thinking-tier analysis before re-dispatch.
#
# When a worker fails (premature_exit, idle kill), the issue body often
# lacks the implementation context needed for success. This function
# spawns an inline thinking-tier worker to analyze the codebase and append
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
