#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# complexity-scan-runner.sh — Standalone runner for the weekly complexity scan (t2903)
#
# Decouples the simplification/complexity scan from the pulse dispatch cycle.
# Previously invoked from `_run_preflight_stages` in pulse-dispatch-engine.sh,
# where it could consume 200-470s of the preflight budget per cycle (26%+ of
# the 1800s pulse stale ceiling) and starve downstream scanners.
#
# This wrapper sources the minimal set of pulse libraries needed to call
# `run_weekly_complexity_scan` (defined in pulse-simplification.sh) and runs
# under its own launchd schedule (sh.aidevops.complexity-scan, hourly).
#
# Architecture: identical to the contribution-watch-helper.sh + worker-watchdog.sh
# pattern — independent file-based lock so the scan never blocks dispatch and
# never overlaps itself, with a runner-level log for invocation visibility.
#
# Usage:
#   complexity-scan-runner.sh [run]    Run the scan (default; called by launchd)
#   complexity-scan-runner.sh help     Show usage
#
# Lock:    ~/.aidevops/.agent-workspace/locks/complexity-scan.lock
# Runner log: ~/.aidevops/logs/complexity-scan-runner.log
# Scan log: ~/.aidevops/logs/pulse.log (the underlying function writes here)
# Last-run: ~/.aidevops/logs/complexity-scan-last-run (touched by the scan itself)
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# PATH normalisation for launchd/cron environments where PATH is minimal.
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"

# SCRIPT_DIR resolution — uses BASH_SOURCE[0]:-$0 for zsh portability (GH#3931).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# =============================================================================
# Source pulse libraries
# =============================================================================
# Order matters:
#   1. shared-constants.sh  — bash 4+ re-exec guard fires here at depth 1; also
#                             auto-sources shared-gh-wrappers.sh for gh_issue_list.
#   2. config-helper.sh     — provides config_get used by pulse-wrapper-config.sh
#                             (sourced with || true to match pulse-wrapper.sh).
#   3. worker-lifecycle-common.sh — provides _validate_int used by pulse-wrapper-config.sh.
#   4. credentials.sh       — picks up gh tokens / API keys before the scan calls gh.
#   5. pulse-wrapper-config.sh — defines LOGFILE, REPOS_JSON, COMPLEXITY_*, etc.
#   6. pulse-repo-meta.sh   — get_repo_role_by_slug, get_repo_path_by_slug.
#   7. pulse-simplification.sh — run_weekly_complexity_scan + helpers.
#   8. pulse-simplification-state.sh — _simplification_state_* helpers (called
#                                       transitively from the scan flow).
# Sourcing the lock acquisition AFTER these means the bash-4+ re-exec guard
# (which exec's the calling script) cannot orphan the lock.

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
	# shellcheck source=/dev/null
	. "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null || true
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-wrapper-config.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-repo-meta.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-simplification.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-simplification-state.sh"

# =============================================================================
# Runner-level state files
# =============================================================================

RUNNER_LOG_FILE="${HOME}/.aidevops/logs/complexity-scan-runner.log"
LOCK_DIR="${HOME}/.aidevops/.agent-workspace/locks/complexity-scan.lock"

mkdir -p "$(dirname "$RUNNER_LOG_FILE")" "$(dirname "$LOCK_DIR")"

# =============================================================================
# Logging
# =============================================================================

_runner_log() {
	local level="$1"
	shift
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '[%s] [%s] %s\n' "$timestamp" "$level" "$*" >>"$RUNNER_LOG_FILE"
	return 0
}

# =============================================================================
# File-based lock (mkdir-based for bash 3.2 + macOS portability)
# =============================================================================
# mkdir is atomic on POSIX filesystems and works without flock (Linux-only) or
# any FD-inheritance gotchas. PID-based stale detection lets the next runner
# reclaim the lock if the previous instance crashed.

_release_lock() {
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	return 0
}

_acquire_lock() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"${LOCK_DIR}/pid"
		trap '_release_lock' EXIT INT TERM
		return 0
	fi

	# Lock dir exists — check if owner is alive.
	local owner_pid=""
	if [[ -f "${LOCK_DIR}/pid" ]]; then
		owner_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
	fi
	if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
		_runner_log INFO "Skipping: previous instance still running (pid=${owner_pid})"
		return 1
	fi

	# Stale lock — reclaim. mkdir again after rm to confirm we won the race.
	# Best-effort rm: if removal fails (permissions/IO), the mkdir below will
	# still fail and we'll skip cleanly. Never let a failed cleanup brick the
	# scheduled job under `set -e`.
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"${LOCK_DIR}/pid"
		trap '_release_lock' EXIT INT TERM
		_runner_log WARN "Reclaimed stale lock (was pid=${owner_pid:-unknown})"
		return 0
	fi
	_runner_log WARN "Could not acquire lock after stale-reclaim attempt"
	return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_run() {
	_runner_log INFO "Starting complexity scan (pid=$$)"
	if ! _acquire_lock; then
		exit 0
	fi

	local scan_exit=0
	run_weekly_complexity_scan || scan_exit=$?
	_runner_log INFO "Complexity scan completed (exit=${scan_exit})"
	return "$scan_exit"
}

cmd_help() {
	cat <<EOF
complexity-scan-runner.sh — Standalone runner for the weekly complexity scan (t2903)

Usage:
  complexity-scan-runner.sh [run]    Run the scan (default; called by launchd)
  complexity-scan-runner.sh help     Show this help

Scheduled via launchd: sh.aidevops.complexity-scan (hourly, RunAtLoad=true).
Install via setup.sh / setup_complexity_scan in setup-modules/schedulers.sh.

Paths:
  Lock dir:    ${LOCK_DIR}
  Runner log:  ${RUNNER_LOG_FILE}
  Scan log:    ${LOGFILE:-~/.aidevops/logs/pulse.log}
  Last-run:    ${COMPLEXITY_SCAN_LAST_RUN:-~/.aidevops/logs/complexity-scan-last-run}

The underlying scan (run_weekly_complexity_scan in pulse-simplification.sh)
performs its own internal interval check (COMPLEXITY_SCAN_INTERVAL, 15 min)
so hourly runner invocations are always safe.
EOF
	return 0
}

# =============================================================================
# Entry point
# =============================================================================

_subcommand="${1:-run}"
case "$_subcommand" in
run | --run | "")
	cmd_run
	;;
help | -h | --help)
	cmd_help
	;;
*)
	echo "Unknown command: $_subcommand" >&2
	echo "Run '$0 help' for usage." >&2
	exit 2
	;;
esac
