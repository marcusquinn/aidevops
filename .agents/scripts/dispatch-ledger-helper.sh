#!/usr/bin/env bash
# dispatch-ledger-helper.sh — In-flight dispatch tracking ledger (GH#6696)
#
# Tracks workers between dispatch and PR creation to prevent duplicate
# dispatches. The pulse checks GitHub for open PRs to detect "already
# handled" targets, but workers take 10-15 minutes between dispatch and
# PR creation. During this window, the target appears unhandled and gets
# re-dispatched every pulse cycle.
#
# This ledger fills that gap: each dispatch registers an entry, and the
# pulse checks the ledger before dispatching. Entries expire after a
# configurable TTL (default 60 min) or are marked completed/failed by
# the worker on exit.
#
# Storage: JSONL file at ~/.aidevops/.agent-workspace/tmp/dispatch-ledger.jsonl
# Each line is a JSON object with fields:
#   session_key  - unique worker session key (e.g., "issue-42")
#   issue_number - GitHub issue number (string, may be empty)
#   repo_slug    - owner/repo (may be empty for non-repo dispatches)
#   pid          - PID of the dispatching process
#   dispatched_at - ISO 8601 UTC timestamp
#   status       - "in-flight" | "completed" | "failed"
#   updated_at   - ISO 8601 UTC timestamp of last status change
#
# Concurrency: file-level flock for atomic reads/writes. Safe for
# concurrent pulse + worker access. Falls back to mkdir-based lock on
# systems without flock (macOS without util-linux). Lock acquisition
# fails closed — write operations abort if the lock cannot be obtained.
#
# Usage:
#   dispatch-ledger-helper.sh register --session-key KEY [--issue NUM] [--repo SLUG] [--pid PID]
#   dispatch-ledger-helper.sh check --session-key KEY
#   dispatch-ledger-helper.sh check-issue --issue NUM [--repo SLUG]
#   dispatch-ledger-helper.sh complete --session-key KEY
#   dispatch-ledger-helper.sh fail --session-key KEY
#   dispatch-ledger-helper.sh expire [--ttl SECONDS]
#   dispatch-ledger-helper.sh count
#   dispatch-ledger-helper.sh status
#   dispatch-ledger-helper.sh help

set -euo pipefail

LEDGER_DIR="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
LEDGER_FILE="${LEDGER_DIR}/dispatch-ledger.jsonl"
LEDGER_LOCK="${LEDGER_DIR}/dispatch-ledger.lock"
DEFAULT_TTL="${AIDEVOPS_DISPATCH_LEDGER_TTL:-3600}" # 60 minutes

#######################################
# Ensure ledger directory and file exist
#######################################
_ensure_ledger() {
	mkdir -p "$LEDGER_DIR" 2>/dev/null || true
	if [[ ! -f "$LEDGER_FILE" ]]; then
		touch "$LEDGER_FILE"
	fi
	return 0
}

#######################################
# Acquire file lock (fail-closed — aborts if lock cannot be obtained)
# Uses flock when available, falls back to mkdir-based lock.
# Returns: 0 on success, 1 on failure (caller must abort write)
#######################################
_acquire_lock() {
	if command -v flock &>/dev/null; then
		exec 8>"$LEDGER_LOCK"
		if ! flock -w 5 8 2>/dev/null; then
			echo "Error: could not acquire ledger lock: $LEDGER_LOCK" >&2
			return 1
		fi
	else
		# Portable fallback: mkdir is atomic on all POSIX systems
		local lock_dir="${LEDGER_LOCK}.d"
		local attempts=0
		local max_attempts=50 # 50 × 0.1s = 5s timeout
		while ! mkdir "$lock_dir" 2>/dev/null; do
			attempts=$((attempts + 1))
			if [[ "$attempts" -ge "$max_attempts" ]]; then
				echo "Error: could not acquire ledger lock (mkdir): $lock_dir" >&2
				return 1
			fi
			sleep 0.1
		done
	fi
	return 0
}

#######################################
# Release file lock
#######################################
_release_lock() {
	if command -v flock &>/dev/null; then
		flock -u 8 2>/dev/null || true
	else
		# Remove mkdir-based lock
		local lock_dir="${LEDGER_LOCK}.d"
		rmdir "$lock_dir" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Get current UTC timestamp in ISO 8601 format
#######################################
_now_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

#######################################
# Get current epoch seconds
#######################################
_now_epoch() {
	date -u '+%s'
	return 0
}

#######################################
# Parse ISO 8601 timestamp to epoch seconds
# Args: $1 = ISO timestamp
# Returns: epoch seconds via stdout
#######################################
_iso_to_epoch() {
	local ts="$1"
	# Try GNU date first (Linux), then BSD date (macOS)
	date -u -d "$ts" '+%s' 2>/dev/null ||
		TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null ||
		printf '%s' "0"
	return 0
}

#######################################
# Register a new dispatch in the ledger
#
# Args (named):
#   --session-key KEY    (required) Unique session key
#   --issue NUM          (optional) GitHub issue number
#   --repo SLUG          (optional) owner/repo
#   --pid PID            (optional) PID of dispatch process, defaults to $$
#
# Exit codes:
#   0 - registered successfully
#   1 - missing required args
#######################################
cmd_register() {
	local session_key=""
	local issue_number=""
	local repo_slug=""
	local dispatch_pid="$$"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		--issue)
			issue_number="${2:-}"
			shift 2
			;;
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		--pid)
			dispatch_pid="${2:-$$}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for register: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$session_key" ]]; then
		echo "Error: register requires --session-key" >&2
		return 1
	fi

	_ensure_ledger
	if ! _acquire_lock; then
		echo "Error: register aborted — could not acquire lock" >&2
		return 1
	fi

	local now
	now=$(_now_utc)

	# Remove any existing entry for this session_key (idempotent re-register)
	if [[ -s "$LEDGER_FILE" ]]; then
		local tmp_file
		tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX")
		jq -c --arg sk "$session_key" 'select(.session_key != $sk)' "$LEDGER_FILE" >"$tmp_file" 2>/dev/null || true
		mv "$tmp_file" "$LEDGER_FILE"
	fi

	# Append new entry — use jq for safe JSON construction (handles special chars)
	jq -cn \
		--arg sk "$session_key" \
		--arg inum "$issue_number" \
		--arg slug "$repo_slug" \
		--argjson pid "$dispatch_pid" \
		--arg ts "$now" \
		'{session_key: $sk, issue_number: $inum, repo_slug: $slug, pid: $pid, dispatched_at: $ts, status: "in-flight", updated_at: $ts}' \
		>>"$LEDGER_FILE"

	_release_lock
	return 0
}

#######################################
# Check if a session key has an in-flight entry
#
# Args:
#   --session-key KEY    (required)
#
# Exit codes:
#   0 - in-flight entry exists (do NOT dispatch)
#   1 - no in-flight entry (safe to dispatch)
# Output: entry JSON on stdout if found
#######################################
cmd_check() {
	local session_key=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for check: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$session_key" ]]; then
		echo "Error: check requires --session-key" >&2
		return 1
	fi

	_ensure_ledger

	if [[ ! -s "$LEDGER_FILE" ]]; then
		return 1
	fi

	local match
	match=$(jq -c --arg sk "$session_key" 'select(.session_key == $sk and .status == "in-flight")' "$LEDGER_FILE" 2>/dev/null | head -1) || match=""

	if [[ -z "$match" ]]; then
		return 1
	fi

	# Verify PID is still alive (stale entry detection)
	local entry_pid
	entry_pid=$(printf '%s' "$match" | jq -r '.pid // 0') || entry_pid=0
	if [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
		if ! kill -0 "$entry_pid" 2>/dev/null; then
			# PID is dead — mark as failed and return "safe to dispatch"
			cmd_fail --session-key "$session_key" 2>/dev/null || true
			return 1
		fi
	fi

	printf '%s\n' "$match"
	return 0
}

#######################################
# Check if an issue number has an in-flight entry
#
# Args:
#   --issue NUM          (required)
#   --repo SLUG          (optional) restrict to specific repo
#
# Exit codes:
#   0 - in-flight entry exists for this issue (do NOT dispatch)
#   1 - no in-flight entry (safe to dispatch)
# Output: entry JSON on stdout if found
#######################################
cmd_check_issue() {
	local issue_number=""
	local repo_slug=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--issue)
			issue_number="${2:-}"
			shift 2
			;;
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for check-issue: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$issue_number" ]]; then
		echo "Error: check-issue requires --issue" >&2
		return 1
	fi

	_ensure_ledger

	if [[ ! -s "$LEDGER_FILE" ]]; then
		return 1
	fi

	local match
	if [[ -n "$repo_slug" ]]; then
		match=$(jq -c --arg inum "$issue_number" --arg slug "$repo_slug" \
			'select(.issue_number == $inum and .repo_slug == $slug and .status == "in-flight")' \
			"$LEDGER_FILE" 2>/dev/null | head -1) || match=""
	else
		match=$(jq -c --arg inum "$issue_number" \
			'select(.issue_number == $inum and .status == "in-flight")' \
			"$LEDGER_FILE" 2>/dev/null | head -1) || match=""
	fi

	if [[ -z "$match" ]]; then
		return 1
	fi

	# Verify PID is still alive
	local entry_pid
	entry_pid=$(printf '%s' "$match" | jq -r '.pid // 0') || entry_pid=0
	if [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
		if ! kill -0 "$entry_pid" 2>/dev/null; then
			local sk
			sk=$(printf '%s' "$match" | jq -r '.session_key // ""') || sk=""
			if [[ -n "$sk" ]]; then
				cmd_fail --session-key "$sk" 2>/dev/null || true
			fi
			return 1
		fi
	fi

	printf '%s\n' "$match"
	return 0
}

#######################################
# Mark a session key as completed
#
# Args:
#   --session-key KEY    (required)
#
# Exit codes:
#   0 - marked completed (or entry not found — idempotent)
#######################################
cmd_complete() {
	local session_key=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for complete: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$session_key" ]]; then
		echo "Error: complete requires --session-key" >&2
		return 1
	fi

	_update_status "$session_key" "completed"
	return 0
}

#######################################
# Mark a session key as failed
#
# Args:
#   --session-key KEY    (required)
#
# Exit codes:
#   0 - marked failed (or entry not found — idempotent)
#######################################
cmd_fail() {
	local session_key=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for fail: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$session_key" ]]; then
		echo "Error: fail requires --session-key" >&2
		return 1
	fi

	_update_status "$session_key" "failed"
	return 0
}

#######################################
# Update the status of a ledger entry
# Args: $1 = session_key, $2 = new status
#######################################
_update_status() {
	local session_key="$1"
	local new_status="$2"

	_ensure_ledger
	if ! _acquire_lock; then
		echo "Error: _update_status aborted — could not acquire lock for session_key=${session_key}" >&2
		return 1
	fi

	if [[ ! -s "$LEDGER_FILE" ]]; then
		_release_lock
		return 0
	fi

	local now
	now=$(_now_utc)
	local tmp_file
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX")

	# Only transition entries that are still "in-flight" — terminal statuses
	# ("completed", "failed") are immutable. A late fail from dead-PID cleanup
	# must not overwrite a genuinely completed dispatch.
	jq -c --arg sk "$session_key" --arg st "$new_status" --arg ts "$now" \
		'if .session_key == $sk and .status == "in-flight"
			then .status = $st | .updated_at = $ts
			else .
		end' \
		"$LEDGER_FILE" >"$tmp_file" 2>/dev/null || cp "$LEDGER_FILE" "$tmp_file"

	mv "$tmp_file" "$LEDGER_FILE"
	_release_lock
	return 0
}

#######################################
# Expire old in-flight entries
#
# Entries older than TTL seconds are marked "failed" (assumed dead).
# Entries with dead PIDs are also marked "failed" regardless of age.
#
# Args:
#   --ttl SECONDS    (optional, default: $DEFAULT_TTL)
#
# Exit codes:
#   0 - always (best-effort cleanup)
# Output: count of expired entries
#######################################
cmd_expire() {
	local ttl="$DEFAULT_TTL"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--ttl)
			ttl="${2:-$DEFAULT_TTL}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for expire: $1" >&2
			return 1
			;;
		esac
	done

	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl="$DEFAULT_TTL"

	_ensure_ledger
	if ! _acquire_lock; then
		printf '%s\n' "0"
		return 0 # Best-effort cleanup
	fi

	if [[ ! -s "$LEDGER_FILE" ]]; then
		_release_lock
		printf '%s\n' "0"
		return 0
	fi

	local now_epoch
	now_epoch=$(_now_epoch)
	local now_ts
	now_ts=$(_now_utc)
	local expired_count=0
	local tmp_file
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX")

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local status
		status=$(printf '%s' "$line" | jq -r '.status // ""' 2>/dev/null) || status=""

		if [[ "$status" != "in-flight" ]]; then
			printf '%s\n' "$line" >>"$tmp_file"
			continue
		fi

		local should_expire=false

		# Check TTL expiry
		local dispatched_at
		dispatched_at=$(printf '%s' "$line" | jq -r '.dispatched_at // ""' 2>/dev/null) || dispatched_at=""
		if [[ -n "$dispatched_at" ]]; then
			local dispatch_epoch
			dispatch_epoch=$(_iso_to_epoch "$dispatched_at")
			local age=$((now_epoch - dispatch_epoch))
			if [[ "$age" -gt "$ttl" ]]; then
				should_expire=true
			fi
		fi

		# Check PID liveness
		if [[ "$should_expire" != "true" ]]; then
			local entry_pid
			entry_pid=$(printf '%s' "$line" | jq -r '.pid // 0' 2>/dev/null) || entry_pid=0
			if [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
				if ! kill -0 "$entry_pid" 2>/dev/null; then
					should_expire=true
				fi
			fi
		fi

		if [[ "$should_expire" == "true" ]]; then
			printf '%s\n' "$line" | jq -c --arg ts "$now_ts" '.status = "failed" | .updated_at = $ts' >>"$tmp_file" 2>/dev/null || printf '%s\n' "$line" >>"$tmp_file"
			expired_count=$((expired_count + 1))
		else
			printf '%s\n' "$line" >>"$tmp_file"
		fi
	done <"$LEDGER_FILE"

	mv "$tmp_file" "$LEDGER_FILE"
	_release_lock

	printf '%s\n' "$expired_count"
	return 0
}

#######################################
# Count in-flight entries (with PID liveness check)
#
# Exit codes: 0 always
# Output: count of live in-flight entries
#######################################
cmd_count() {
	_ensure_ledger

	if [[ ! -s "$LEDGER_FILE" ]]; then
		printf '%s\n' "0"
		return 0
	fi

	local count=0
	local inflight_lines
	inflight_lines=$(jq -c 'select(.status == "in-flight")' "$LEDGER_FILE" 2>/dev/null) || inflight_lines=""

	if [[ -z "$inflight_lines" ]]; then
		printf '%s\n' "0"
		return 0
	fi

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local entry_pid
		entry_pid=$(printf '%s' "$line" | jq -r '.pid // 0' 2>/dev/null) || entry_pid=0
		if [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
			if kill -0 "$entry_pid" 2>/dev/null; then
				count=$((count + 1))
			fi
		else
			# No valid PID — count it (conservative; expire will clean up)
			count=$((count + 1))
		fi
	done <<<"$inflight_lines"

	printf '%s\n' "$count"
	return 0
}

#######################################
# Show ledger status (all entries, human-readable)
#
# Exit codes: 0 always
# Output: formatted status table
#######################################
cmd_status() {
	_ensure_ledger

	if [[ ! -s "$LEDGER_FILE" ]]; then
		echo "Dispatch ledger is empty"
		return 0
	fi

	local total inflight completed failed
	total=$(wc -l <"$LEDGER_FILE" | tr -d ' ')
	inflight=$(jq -c 'select(.status == "in-flight")' "$LEDGER_FILE" 2>/dev/null | wc -l | tr -d ' ') || inflight=0
	completed=$(jq -c 'select(.status == "completed")' "$LEDGER_FILE" 2>/dev/null | wc -l | tr -d ' ') || completed=0
	failed=$(jq -c 'select(.status == "failed")' "$LEDGER_FILE" 2>/dev/null | wc -l | tr -d ' ') || failed=0

	echo "Dispatch Ledger Status"
	echo "  Total entries: ${total}"
	echo "  In-flight:     ${inflight}"
	echo "  Completed:     ${completed}"
	echo "  Failed:        ${failed}"
	echo ""

	if [[ "$inflight" -gt 0 ]]; then
		echo "In-flight entries:"
		jq -r 'select(.status == "in-flight") | "  \(.session_key) | issue=\(.issue_number) | repo=\(.repo_slug) | pid=\(.pid) | since=\(.dispatched_at)"' "$LEDGER_FILE" 2>/dev/null || true
	fi

	return 0
}

#######################################
# Prune completed/failed entries older than 24h
# Keeps the ledger file from growing indefinitely.
#
# Exit codes: 0 always
# Output: count of pruned entries
#######################################
cmd_prune() {
	_ensure_ledger
	if ! _acquire_lock; then
		printf '%s\n' "0"
		return 0 # Best-effort cleanup — skip if locked
	fi

	if [[ ! -s "$LEDGER_FILE" ]]; then
		_release_lock
		printf '%s\n' "0"
		return 0
	fi

	local now_epoch prune_threshold pruned_count
	now_epoch=$(_now_epoch)
	prune_threshold=86400 # 24 hours
	pruned_count=0
	local tmp_file
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX")

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local status
		status=$(printf '%s' "$line" | jq -r '.status // ""' 2>/dev/null) || status=""

		# Keep in-flight entries always
		if [[ "$status" == "in-flight" ]]; then
			printf '%s\n' "$line" >>"$tmp_file"
			continue
		fi

		# Prune completed/failed entries older than threshold
		local updated_at
		updated_at=$(printf '%s' "$line" | jq -r '.updated_at // ""' 2>/dev/null) || updated_at=""
		if [[ -n "$updated_at" ]]; then
			local update_epoch
			update_epoch=$(_iso_to_epoch "$updated_at")
			local age=$((now_epoch - update_epoch))
			if [[ "$age" -gt "$prune_threshold" ]]; then
				pruned_count=$((pruned_count + 1))
				continue
			fi
		fi

		printf '%s\n' "$line" >>"$tmp_file"
	done <"$LEDGER_FILE"

	mv "$tmp_file" "$LEDGER_FILE"
	_release_lock

	printf '%s\n' "$pruned_count"
	return 0
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'HELP'
dispatch-ledger-helper.sh — In-flight dispatch tracking ledger (GH#6696)

Tracks workers between dispatch and PR creation to prevent duplicate
dispatches during the 10-15 minute window before a worker creates its PR.

Usage:
  dispatch-ledger-helper.sh register --session-key KEY [--issue NUM] [--repo SLUG] [--pid PID]
    Register a new dispatch. Idempotent — re-registering overwrites.

  dispatch-ledger-helper.sh check --session-key KEY
    Check if session key has an in-flight entry. Exit 0=in-flight, 1=safe.

  dispatch-ledger-helper.sh check-issue --issue NUM [--repo SLUG]
    Check if issue has an in-flight entry. Exit 0=in-flight, 1=safe.

  dispatch-ledger-helper.sh complete --session-key KEY
    Mark dispatch as completed (worker finished successfully).

  dispatch-ledger-helper.sh fail --session-key KEY
    Mark dispatch as failed (worker errored or timed out).

  dispatch-ledger-helper.sh expire [--ttl SECONDS]
    Expire stale in-flight entries (default TTL: 3600s / 60 min).
    Also expires entries with dead PIDs regardless of age.

  dispatch-ledger-helper.sh count
    Count live in-flight entries (with PID liveness check).

  dispatch-ledger-helper.sh status
    Show human-readable ledger status.

  dispatch-ledger-helper.sh prune
    Remove completed/failed entries older than 24h.

  dispatch-ledger-helper.sh help
    Show this help.

Environment:
  AIDEVOPS_DISPATCH_LEDGER_DIR   Override ledger directory
  AIDEVOPS_DISPATCH_LEDGER_TTL   Override default TTL in seconds (default: 3600)

Examples:
  # Register before dispatching a worker
  dispatch-ledger-helper.sh register --session-key "issue-42" --issue 42 --repo owner/repo --pid $!

  # Check before dispatching (in pulse dedup)
  if dispatch-ledger-helper.sh check-issue --issue 42 --repo owner/repo; then
    echo "Already in-flight — skip dispatch"
  fi

  # Worker marks completion on exit
  dispatch-ledger-helper.sh complete --session-key "issue-42"

  # Pulse runs expire at start of each cycle
  dispatch-ledger-helper.sh expire --ttl 3600
HELP
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	register)
		cmd_register "$@"
		;;
	check)
		cmd_check "$@"
		;;
	check-issue)
		cmd_check_issue "$@"
		;;
	complete)
		cmd_complete "$@"
		;;
	fail)
		cmd_fail "$@"
		;;
	expire)
		cmd_expire "$@"
		;;
	count)
		cmd_count
		;;
	status)
		cmd_status
		;;
	prune)
		cmd_prune
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help
		return 1
		;;
	esac
}

main "$@"
