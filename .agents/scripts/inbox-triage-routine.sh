#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# inbox-triage-routine.sh — Pulse-callable wrapper for inbox triage (t2868)
# =============================================================================
# Wraps inbox-helper.sh triage with rate-limiting, backoff, and safe exit
# codes for pulse-wrapper.sh task scheduling.
#
# Called by pulse-wrapper.sh on a configurable interval (default: 60 min).
# Register in TODO.md as a routine, e.g.:
#   - [x] r010 Inbox triage routine @system #routine
#       repeat:daily(@*:00) run:scripts/inbox-triage-routine.sh
#
# Exit codes:
#   0  All pending items processed (routed or needs-review) cleanly
#   1  Classifier error or inbox-helper failure
#   2  Inbox not provisioned (non-fatal: pulse should not retry immediately)
#
# Environment:
#   INBOX_TRIAGE_RATE_LIMIT   Max items per run (default: 50)
#   INBOX_WORKSPACE_DIR       Workspace inbox root
#   INBOX_TRIAGE_DRY_RUN      Set to 1 to dry-run without moving files
#   INBOX_TRIAGE_TIMEOUT_SECS Max seconds per run before abort (default: 240)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

INBOX_TRIAGE_RATE_LIMIT="${INBOX_TRIAGE_RATE_LIMIT:-50}"
INBOX_TRIAGE_DRY_RUN="${INBOX_TRIAGE_DRY_RUN:-0}"
INBOX_TRIAGE_TIMEOUT_SECS="${INBOX_TRIAGE_TIMEOUT_SECS:-240}"
INBOX_HELPER="${SCRIPT_DIR}/inbox-helper.sh"

# =============================================================================
# Internal helpers
# =============================================================================

_log_ts() {
	date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

_require_inbox_helper() {
	if [[ ! -f "$INBOX_HELPER" ]]; then
		print_error "inbox-helper.sh not found at: ${INBOX_HELPER}"
		return 1
	fi
	if [[ ! -x "$INBOX_HELPER" ]]; then
		chmod +x "$INBOX_HELPER"
	fi
	return 0
}

_inbox_provisioned() {
	local workspace_inbox="${INBOX_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace/inbox}"
	[[ -d "$workspace_inbox" ]]
	return $?
}

# _run_triage_with_timeout: invoke inbox-helper.sh triage, aborting on timeout
# Uses a background job + watchdog pattern to stay watchdog-safe (no sleep >240s)
_run_triage_with_timeout() {
	local timeout_secs="$INBOX_TRIAGE_TIMEOUT_SECS"
	local limit="$INBOX_TRIAGE_RATE_LIMIT"
	local dry_run_flag=""
	[[ "$INBOX_TRIAGE_DRY_RUN" -eq 1 ]] && dry_run_flag="--dry-run"

	local helper_args=(triage --limit "$limit")
	[[ -n "$dry_run_flag" ]] && helper_args+=("$dry_run_flag")

	# Run in background, kill after timeout
	"$INBOX_HELPER" "${helper_args[@]}" &
	local bg_pid=$!

	local elapsed=0
	local poll_interval=10
	while kill -0 "$bg_pid" 2>/dev/null; do
		sleep "$poll_interval"
		elapsed=$((elapsed + poll_interval))
		if [[ "$elapsed" -ge "$timeout_secs" ]]; then
			print_warning "Triage timeout (${timeout_secs}s) — sending SIGTERM to PID ${bg_pid}"
			kill "$bg_pid" 2>/dev/null || true
			wait "$bg_pid" 2>/dev/null || true
			print_warning "Triage aborted after ${elapsed}s"
			return 1
		fi
	done

	wait "$bg_pid"
	return $?
}

# =============================================================================
# Main
# =============================================================================

main() {
	local start_ts
	start_ts=$(_log_ts)
	print_info "[inbox-triage-routine] Starting at ${start_ts}"
	print_info "  rate_limit=${INBOX_TRIAGE_RATE_LIMIT} dry_run=${INBOX_TRIAGE_DRY_RUN} timeout=${INBOX_TRIAGE_TIMEOUT_SECS}s"

	# Guard: inbox-helper.sh must exist
	if ! _require_inbox_helper; then
		return 1
	fi

	# Guard: inbox must be provisioned (soft failure — schedule can retry later)
	if ! _inbox_provisioned; then
		print_warning "Inbox not provisioned. Run: inbox-helper.sh provision-workspace"
		print_info "Re-run after provisioning to start triage."
		return 2
	fi

	# Run triage with timeout protection
	local rc=0
	_run_triage_with_timeout || rc=$?

	local end_ts
	end_ts=$(_log_ts)
	if [[ "$rc" -eq 0 ]]; then
		print_success "[inbox-triage-routine] Completed at ${end_ts}"
	else
		print_warning "[inbox-triage-routine] Completed with errors (rc=${rc}) at ${end_ts}"
	fi

	return "$rc"
}

main "$@"
