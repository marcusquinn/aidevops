#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091
set -euo pipefail

# email-poll-helper.sh
# Pulse-driven IMAP polling for the aidevops knowledge plane.
#
# Polls configured mailboxes, fetches new .eml files to _knowledge/inbox/,
# and maintains per-mailbox high-watermark state at _knowledge/.imap-state.json.
#
# Usage:
#   email-poll-helper.sh tick              Poll all configured mailboxes
#   email-poll-helper.sh backfill <id>     Backfill mailbox --since <date>
#     --since YYYY-MM-DD                   Fetch history from this date
#     --rate-limit N                       Max messages/min (default 100)
#   email-poll-helper.sh test <id>         Dry-run: connect + fetch, no writes
#   email-poll-helper.sh list              List mailboxes + last-polled status
#   email-poll-helper.sh help              Show this help
#
# Config locations (in priority order):
#   _config/mailboxes.json                 Per-repo config (git-trackable)
#   ~/.config/aidevops/mailboxes.json      Personal / global config
#
# State:  _knowledge/.imap-state.json      Per-folder high-watermark UIDs
# Inbox:  _knowledge/inbox/               Output .eml files
#
# Part of aidevops email system (t2855).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/shared-constants.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly POLL_PY="${SCRIPT_DIR}/email_poll.py"
readonly _ERR_NO_CONFIG="No mailboxes.json config found"

# Config resolution order (first-found wins)
_REPO_CONFIG="_config/mailboxes.json"
_GLOBAL_CONFIG="${HOME}/.config/aidevops/mailboxes.json"

# State and inbox paths (relative to CWD = repo root)
_STATE_FILE="_knowledge/.imap-state.json"
_INBOX_DIR="_knowledge/inbox"

# Lock file: one poll per pulse cycle
_LOCK_DIR="${HOME}/.aidevops/.agent-workspace/locks"
_LOCK_FILE="${_LOCK_DIR}/email-poll.lock"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_find_config() {
	if [[ -f "$_REPO_CONFIG" ]]; then
		echo "$_REPO_CONFIG"
		return 0
	fi
	if [[ -f "$_GLOBAL_CONFIG" ]]; then
		echo "$_GLOBAL_CONFIG"
		return 0
	fi
	return 1
}

_require_python3() {
	if ! command -v python3 &>/dev/null; then
		log_error "python3 is required for email polling"
		return 1
	fi
	return 0
}

_require_poll_py() {
	if [[ ! -f "$POLL_PY" ]]; then
		log_error "email_poll.py not found: $POLL_PY"
		log_error "Run: aidevops update"
		return 1
	fi
	return 0
}

_acquire_lock() {
	mkdir -p "$_LOCK_DIR"
	if ! mkdir "${_LOCK_FILE}" 2>/dev/null; then
		local lock_pid=""
		lock_pid=$(cat "${_LOCK_FILE}/pid" 2>/dev/null || true)
		if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
			log_warn "Email poll already running (PID $lock_pid). Skipping tick."
			return 1
		fi
		# Stale lock — clear it
		log_warn "Clearing stale email-poll lock (PID ${lock_pid:-unknown} not running)"
		rm -rf "${_LOCK_FILE}"
		mkdir "${_LOCK_FILE}"
	fi
	echo "$$" >"${_LOCK_FILE}/pid"
	return 0
}

_release_lock() {
	rm -rf "${_LOCK_FILE}" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_tick() {
	local config_path
	if ! config_path=$(_find_config 2>&1); then
		log_error "$_ERR_NO_CONFIG"
		log_error "Create $_REPO_CONFIG or $_GLOBAL_CONFIG"
		log_error "Template: aidevops email mailbox add"
		return 1
	fi

	_require_python3 || return 1
	_require_poll_py || return 1

	if ! _acquire_lock; then
		return 0
	fi
	trap '_release_lock' EXIT

	mkdir -p "$_INBOX_DIR"

	log_info "Polling mailboxes (config: $config_path)"
	# Capture stdout (JSON) and stderr separately.
	# 2>&1 would merge stderr into $result, corrupting JSON when partial errors occur.
	# Non-zero exit is expected when overall_status is "partial_error" (fail-open).
	local py_stderr result py_exit
	py_stderr=$(mktemp)
	result=$(python3 "$POLL_PY" tick \
		--config "$config_path" \
		--state "$_STATE_FILE" \
		--inbox "$_INBOX_DIR" 2>"$py_stderr") && py_exit=0 || py_exit=$?
	local py_err_out
	py_err_out=$(cat "$py_stderr" 2>/dev/null || true)
	rm -f "$py_stderr"
	[[ -n "$py_err_out" ]] && log_warn "email_poll.py: $py_err_out"
	if [[ -z "$result" ]] && [[ $py_exit -ne 0 ]]; then
		log_error "email_poll.py tick failed (exit $py_exit)"
		return 1
	fi

	# Parse summary from JSON result
	local overall_status fetched_count
	overall_status=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('overall_status', 'unknown'))
" 2>/dev/null || echo "unknown")
	fetched_count=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
total = sum(r.get('fetched_count', 0) for r in d.get('results', []))
print(total)
" 2>/dev/null || echo "0")

	if [[ "$overall_status" == "ok" ]]; then
		log_info "Tick complete: $fetched_count new message(s)"
	else
		log_warn "Tick complete with errors: $fetched_count message(s) fetched"
		# Log full result for debugging but don't crash pulse
		echo "$result" >&2
	fi

	_release_lock
	trap - EXIT
	return 0
}

cmd_backfill() {
	local mailbox_id="${1:-}"
	shift || true

	if [[ -z "$mailbox_id" ]]; then
		log_error "Usage: email-poll-helper.sh backfill <mailbox-id> --since YYYY-MM-DD"
		return 1
	fi

	local since="" rate_limit=100
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		local val="${2:-}"
		case "$flag" in
		--since) since="$val"; shift 2 ;;
		--rate-limit) rate_limit="$val"; shift 2 ;;
		*) shift ;;
		esac
	done

	if [[ -z "$since" ]]; then
		log_error "--since YYYY-MM-DD is required for backfill"
		return 1
	fi

	local config_path
	if ! config_path=$(_find_config 2>&1); then
		log_error "$_ERR_NO_CONFIG"
		return 1
	fi

	_require_python3 || return 1
	_require_poll_py || return 1

	mkdir -p "$_INBOX_DIR"

	log_info "Backfilling mailbox '$mailbox_id' from $since (rate: ${rate_limit}/min)"
	python3 "$POLL_PY" backfill \
		--config "$config_path" \
		--state "$_STATE_FILE" \
		--inbox "$_INBOX_DIR" \
		--mailbox-id "$mailbox_id" \
		--since "$since" \
		--rate-limit "$rate_limit"

	return 0
}

cmd_test() {
	local mailbox_id="${1:-}"

	if [[ -z "$mailbox_id" ]]; then
		log_error "Usage: email-poll-helper.sh test <mailbox-id>"
		return 1
	fi

	local config_path
	if ! config_path=$(_find_config 2>&1); then
		log_error "$_ERR_NO_CONFIG"
		return 1
	fi

	_require_python3 || return 1
	_require_poll_py || return 1

	log_info "Dry-run test for mailbox '$mailbox_id'"
	python3 "$POLL_PY" test \
		--config "$config_path" \
		--mailbox-id "$mailbox_id"

	return 0
}

cmd_list() {
	local config_path
	if ! config_path=$(_find_config 2>&1); then
		log_error "$_ERR_NO_CONFIG"
		return 1
	fi

	_require_python3 || return 1
	_require_poll_py || return 1

	local state_arg=""
	if [[ -f "$_STATE_FILE" ]]; then
		state_arg="--state $_STATE_FILE"
	fi

	# shellcheck disable=SC2086
	python3 "$POLL_PY" list \
		--config "$config_path" \
		$state_arg | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('mailboxes', [])
if not rows:
    print('No mailboxes configured.')
    sys.exit(0)
print(f\"{'ID':<25} {'HOST':<30} {'USER':<35} {'POLLED':<22} {'ERROR'}\")
print('-' * 120)
for r in rows:
    polled = r.get('last_polled_at') or '-'
    err = (r.get('last_error') or '')[:40]
    print(f\"{r['id']:<25} {r['host']:<30} {r['user']:<35} {polled:<22} {err}\")
"
	return 0
}

cmd_help() {
	cat <<'EOF'
email-poll-helper.sh — IMAP polling for the aidevops knowledge plane (t2855)

Usage:
  email-poll-helper.sh tick                    Poll all configured mailboxes
  email-poll-helper.sh backfill <id>           Backfill a mailbox from a date
    --since YYYY-MM-DD                           Start date for backfill (required)
    --rate-limit N                               Max messages/min (default 100)
  email-poll-helper.sh test <id>               Dry-run: connect + fetch, no disk writes
  email-poll-helper.sh list                    Show mailboxes and last-polled status
  email-poll-helper.sh help                    Show this help

Config locations (first-found wins):
  _config/mailboxes.json                       Per-repo (git-trackable)
  ~/.config/aidevops/mailboxes.json            Personal / global

State:  _knowledge/.imap-state.json
Inbox:  _knowledge/inbox/

Credentials:
  Store passwords in gopass: aidevops secret set email/<mailbox-id>/password
  Reference in config as:    "password_ref": "gopass:aidevops/email/<id>/password"

Setup:
  aidevops email mailbox add                   Interactive guided setup
  aidevops email mailbox list                  Show all mailboxes
  aidevops email mailbox test <id>             Test connection
  aidevops email mailbox remove <id>           Remove a mailbox
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	tick)        cmd_tick "$@" ;;
	backfill)    cmd_backfill "$@" ;;
	test)        cmd_test "$@" ;;
	list)        cmd_list "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		log_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
