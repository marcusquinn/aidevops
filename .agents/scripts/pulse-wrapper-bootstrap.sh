#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Wrapper Bootstrap -- Invocation source detection and mode flags
# =============================================================================
# Argument-parsing and invocation-source helpers that run early in main()
# before the lock and cycle work begin: --self-check, --dry-run, --canary
# flag handlers; launchd/cron/manual invocation source detection and
# stats counter increment. Extracted from pulse-wrapper.sh
# (GH#21311 / t2936-child) to bring the orchestrator below the 1500-line
# file-size-debt threshold. No behavioural changes.
#
# Usage: source "${SCRIPT_DIR}/pulse-wrapper-bootstrap.sh"
#
# Dependencies:
#   - pulse-wrapper-config.sh (LOGFILE, PULSE_STATS_FILE)
#   - _pulse_execute_self_check (defined in pulse-wrapper.sh — kept there
#     because the function is >100 lines and moving it would create a new
#     function-complexity identity-key violation per
#     reference/large-file-split.md §3)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_WRAPPER_BOOTSTRAP_LIB_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_BOOTSTRAP_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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

# ---------------------------------------------------------------------------
# _detect_invocation_source (GH#20580)
#
# Detects how pulse-wrapper.sh was invoked. Writes the detected source into
# the caller-scoped variable named by the first argument (default:
# _invocation_source). Order: most-specific check first.
#
# Sources:
#   lifecycle-helper  AIDEVOPS_PULSE_SOURCE=lifecycle-helper (set by _start())
#   launchd           PPID=1 or parent command contains "launchd"
#   cron              parent command contains "cron"
#   manual            stdin is a TTY or PULSE_MANUAL=1
#   unknown           none of the above
# ---------------------------------------------------------------------------
_detect_invocation_source() {
	local _parent_cmd
	_parent_cmd=$(ps -p "$PPID" -o comm= 2>/dev/null || printf 'unknown')

	if [[ "${AIDEVOPS_PULSE_SOURCE:-}" == "lifecycle-helper" ]]; then
		_invocation_source="lifecycle-helper"
	elif [[ "$PPID" -eq 1 ]] || [[ "$_parent_cmd" == *"launchd"* ]]; then
		_invocation_source="launchd"
	elif [[ "$_parent_cmd" == *"cron"* ]]; then
		_invocation_source="cron"
	elif [[ "${PULSE_MANUAL:-0}" == "1" ]] || [[ -t 0 ]]; then
		_invocation_source="manual"
	else
		_invocation_source="unknown"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _record_invocation_source (GH#20580)
#
# Logs the invocation source to the pulse log and increments the per-source
# integer counter in pulse-stats.json under the top-level
# "invocation_sources" object, e.g.:
#   {"counters":{...},"invocation_sources":{"launchd":5,"manual":1,...}}
#
# Args:
#   $1 - invocation source string (launchd/cron/manual/lifecycle-helper/unknown)
#
# Non-fatal: any jq or file failure is ignored — never blocks the pulse.
# ---------------------------------------------------------------------------
_record_invocation_source() {
	local source="${1:-unknown}"
	local stats_file="${PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
	local log_dest="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

	# Log entry (ISO-8601 UTC to match pulse-logging.sh conventions)
	local _ts _pcmd
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	_pcmd=$(ps -p "$PPID" -o comm= 2>/dev/null || printf 'unknown')
	printf '[%s] pulse-wrapper invoked: pid=%d ppid=%d source=%s parent_cmd=%s\n' \
		"$_ts" "$$" "$PPID" "$source" "$_pcmd" \
		>>"$log_dest" 2>/dev/null || true

	# Increment invocation_sources.{source} as a plain integer counter.
	# Uses tmp-file + mv for atomicity (same pattern as pulse_stats_increment).
	local _dir _tmp
	_dir="$(dirname "$stats_file")"
	[[ -d "$_dir" ]] || mkdir -p "$_dir" 2>/dev/null || return 0
	[[ -f "$stats_file" ]] || printf '{"counters":{}}\n' >"$stats_file" 2>/dev/null || return 0

	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	_tmp=$(mktemp "${TMPDIR:-/tmp}/pulse-stats-src-XXXXXX") || return 0
	jq --arg src "$source" \
		'.invocation_sources[$src] = ((.invocation_sources[$src] // 0) + 1)' \
		"$stats_file" >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 0; }
	mv "$_tmp" "$stats_file" 2>/dev/null || rm -f "$_tmp"
	return 0
}
