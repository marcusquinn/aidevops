#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# inbox-triage-routine.sh — Pulse-callable wrapper for inbox triage (t2868)
# =============================================================================
# Processes pending items in _inbox/ for all configured inboxes:
#   sensitivity gate → LLM classification → route to plane or _needs-review/
#
# Designed to be called by the pulse at configurable intervals (default: 60 min)
# or invoked directly via: aidevops inbox triage
#
# Usage:
#   inbox-triage-routine.sh [--dry-run] [--limit N] [--repo-path <path>]
#                           [--workspace]
#
# Options:
#   --dry-run              Show what would be done; no files are moved
#   --limit N              Max items per run (default: TRIAGE_RATE_LIMIT env or 50)
#   --repo-path <path>     Process inbox at specific repo root
#   --workspace            Process workspace-level inbox
#   --confidence N         Confidence threshold 0-100 (default: 85)
#
# Exit codes:
#   0  All items processed cleanly (routed or needs-review)
#   1  Classifier error or critical failure
#
# Environment:
#   TRIAGE_RATE_LIMIT            Max items per cycle (default: 50)
#   TRIAGE_CONFIDENCE_THRESHOLD  Min confidence to route (default: 85)
#   TRIAGE_BACKOFF_THRESHOLD     Consecutive needs-review before halt (default: 10)
#   INBOX_TRIAGE_INTERVAL_MINUTES  Minimum minutes between runs (default: 60)
#
# Pulse registration (TODO.md routine entry):
#   - [ ] r_inbox_triage Inbox triage routine
#     repeat:cron(0 * * * *)
#     run:scripts/inbox-triage-routine.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

readonly INBOX_DIR_NAME="_inbox"
readonly WORKSPACE_INBOX_DIR="${HOME}/.aidevops/.agent-workspace/inbox"
readonly TRIAGE_LOCKFILE="${TMPDIR:-/tmp}/aidevops-inbox-triage.lock"
readonly TRIAGE_STAMP_FILE="${TMPDIR:-/tmp}/aidevops-inbox-triage.last"
readonly INBOX_TRIAGE_INTERVAL_MINUTES="${INBOX_TRIAGE_INTERVAL_MINUTES:-60}"

# =============================================================================
# Helpers
# =============================================================================

# _within_rate_window
# Returns 0 (true) if enough time has elapsed since last run; 1 if too soon.
_within_rate_window() {
	if [[ ! -f "$TRIAGE_STAMP_FILE" ]]; then
		return 0
	fi
	local last_run now elapsed_secs interval_secs
	last_run="$(cat "$TRIAGE_STAMP_FILE" 2>/dev/null || echo 0)"
	now="$(date +%s)"
	elapsed_secs=$(( now - last_run ))
	interval_secs=$(( INBOX_TRIAGE_INTERVAL_MINUTES * 60 ))
	if [[ "$elapsed_secs" -lt "$interval_secs" ]]; then
		local remaining=$(( interval_secs - elapsed_secs ))
		print_info "Inbox triage: next run in ${remaining}s (interval: ${INBOX_TRIAGE_INTERVAL_MINUTES}min)"
		return 1
	fi
	return 0
}

# _stamp_last_run
_stamp_last_run() {
	date +%s > "$TRIAGE_STAMP_FILE" 2>/dev/null || true
	return 0
}

# _acquire_lock
# Uses mkdir for atomic lock (bash 3.2 compatible).
_acquire_lock() {
	if mkdir "$TRIAGE_LOCKFILE" 2>/dev/null; then
		return 0
	fi
	print_warning "Inbox triage already running (lock: ${TRIAGE_LOCKFILE})"
	return 1
}

# _release_lock
_release_lock() {
	rmdir "$TRIAGE_LOCKFILE" 2>/dev/null || true
	return 0
}

# _triage_inbox <inbox-helper-args...>
# Calls inbox-helper.sh triage with the given arguments.
_triage_inbox() {
	local helper="${SCRIPT_DIR}/inbox-helper.sh"
	if [[ ! -x "$helper" ]]; then
		print_error "inbox-helper.sh not found at ${helper}"
		return 1
	fi
	"$helper" triage "$@"
	return $?
}

# =============================================================================
# Main
# =============================================================================

main() {
	local dry_run=0
	local limit="${TRIAGE_RATE_LIMIT:-50}"
	local confidence="${TRIAGE_CONFIDENCE_THRESHOLD:-85}"
	local repo_path=""
	local process_workspace=0

	while [[ $# -gt 0 ]]; do
		local cur_arg="$1"
		case "$cur_arg" in
		--dry-run)         dry_run=1; shift ;;
		--workspace)       process_workspace=1; shift ;;
		--limit)           limit="${2:-$limit}"; shift 2 ;;
		--limit=*)         limit="${cur_arg#--limit=}"; shift ;;
		--repo-path)       repo_path="${2:-}"; shift 2 ;;
		--repo-path=*)     repo_path="${cur_arg#--repo-path=}"; shift ;;
		--confidence)      confidence="${2:-$confidence}"; shift 2 ;;
		--confidence=*)    confidence="${cur_arg#--confidence=}"; shift ;;
		*)
			print_error "Unknown flag: $cur_arg"
			exit 1
			;;
		esac
	done

	# Rate-window guard (skip if interval not elapsed, unless --dry-run)
	if [[ "$dry_run" -eq 0 ]] && ! _within_rate_window; then
		exit 0
	fi

	# Exclusive lock (skip if already running)
	if ! _acquire_lock; then
		exit 0
	fi

	# Ensure lock is released on exit
	trap '_release_lock' EXIT INT TERM

	local exit_code=0

	# Build common triage args
	local triage_args=("--limit" "$limit" "--confidence-threshold" "$confidence")
	[[ "$dry_run" -eq 1 ]] && triage_args+=("--dry-run")

	# --- Process repo-level inbox ---
	if [[ -n "$repo_path" ]]; then
		print_info "Processing inbox at: ${repo_path}"
		local orig_dir
		orig_dir="$(pwd)"
		if cd "$repo_path" 2>/dev/null; then
			_triage_inbox "${triage_args[@]}" || exit_code=$?
			cd "$orig_dir" || true
		else
			print_error "Cannot cd to repo path: ${repo_path}"
			exit_code=1
		fi
	elif [[ "$process_workspace" -eq 1 ]]; then
		# --- Process workspace inbox ---
		if [[ -d "$WORKSPACE_INBOX_DIR" ]]; then
			print_info "Processing workspace inbox at: ${WORKSPACE_INBOX_DIR}"
			local ws_parent
			ws_parent="$(dirname "$WORKSPACE_INBOX_DIR")"
			local orig_dir2
			orig_dir2="$(pwd)"
			if cd "$ws_parent" 2>/dev/null; then
				_triage_inbox "${triage_args[@]}" || exit_code=$?
				cd "$orig_dir2" || true
			fi
		else
			print_info "Workspace inbox not provisioned. Skipping."
		fi
	else
		# Default: process current directory's inbox
		local cur_inbox="${PWD}/${INBOX_DIR_NAME}"
		if [[ -d "$cur_inbox" ]]; then
			print_info "Processing inbox at: ${PWD}"
			_triage_inbox "${triage_args[@]}" || exit_code=$?
		else
			print_info "No _inbox/ found in current directory (${PWD}). Skipping."
		fi
	fi

	# Stamp last run time (only on real runs without error)
	if [[ "$dry_run" -eq 0 && "$exit_code" -eq 0 ]]; then
		_stamp_last_run
	fi

	return "$exit_code"
}

main "$@"
