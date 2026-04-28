#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
# Get the age in seconds of a directory's mtime.
# Args: $1 = directory path
# Returns: age in seconds via stdout (0 if directory absent or stat fails)
# Portable across BSD (macOS) and GNU (Linux) stat invocations.
#######################################
_lock_dir_age() {
	local dir="$1"
	local mtime=""
	local now=""
	if [[ ! -d "$dir" ]]; then
		echo "0"
		return 0
	fi
	# BSD stat (macOS) first, then GNU stat (Linux)
	mtime=$(stat -f '%m' "$dir" 2>/dev/null || stat -c '%Y' "$dir" 2>/dev/null || echo "")
	if [[ -z "$mtime" ]] || [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
		echo "0"
		return 0
	fi
	now=$(_now_epoch)
	echo "$((now - mtime))"
	return 0
}

#######################################
# Detect a stale ledger lock and clear it if so.
#
# Three-tier detection mirroring pulse-instance-lock.sh::_handle_existing_lock
# (GH#20025), but with ledger-appropriate semantics:
#   1. No valid PID in the lockdir → corrupt or pre-PID-file lock from
#      an older client. Use mtime as the staleness signal.
#   2. Owner PID dead → stale from SIGKILL/OOM/crash. Clear immediately.
#   3. Owner alive but lock age > AIDEVOPS_LEDGER_LOCK_MAX_AGE_S
#      (default 60s) → hung holder. Clear so we can re-acquire. Unlike
#      pulse-instance-lock we do NOT kill the owner — ledger ops should
#      complete in <100ms; a 60s+ hold means the holder is stuck and
#      the safe move is to steal the lock. Worst-case race outcome is a
#      single corrupted JSONL line, which the helper already tolerates
#      (registration failures are logged non-fatal upstream).
#
# Args:
#   $1 = lock directory path
#   $2 = pid file path (lock_dir/pid)
#   $3 = max age in seconds (threshold for force-reclaim)
# Returns: 0 if the lock was stale and was cleared, 1 if still live
#######################################
_ledger_lock_is_stale() {
	local lock_dir="$1"
	local pid_file="$2"
	local max_age="$3"
	local lock_pid=""
	local lock_age=""

	# Must still exist — race: another waiter may have just cleared it.
	if [[ ! -d "$lock_dir" ]]; then
		return 1
	fi

	if [[ -f "$pid_file" ]]; then
		lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
	fi

	# Tier 1: no valid PID file (corrupt, or pre-PID lock from old client)
	# Use mtime as the staleness signal.
	if [[ -z "$lock_pid" ]] || [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
		lock_age=$(_lock_dir_age "$lock_dir")
		if [[ "$lock_age" -gt "$max_age" ]]; then
			rm -rf "$lock_dir" 2>/dev/null || true
			# Only return 0 if the directory was actually removed — if rm -rf
			# failed silently the caller would loop indefinitely via `continue`.
			[[ ! -d "$lock_dir" ]] && return 0
		fi
		return 1
	fi

	# Tier 2: owner PID is dead → stale (SIGKILL, OOM, crash)
	# Use kill -0 for consistency with cmd_check/cmd_check_issue/cmd_expire.
	if ! kill -0 "$lock_pid" 2>/dev/null; then
		rm -rf "$lock_dir" 2>/dev/null || true
		[[ ! -d "$lock_dir" ]] && return 0
		return 1
	fi

	# Tier 3: owner alive but lock too old → hung holder, steal lock
	lock_age=$(_lock_dir_age "$lock_dir")
	if [[ "$lock_age" -gt "$max_age" ]]; then
		rm -rf "$lock_dir" 2>/dev/null || true
		[[ ! -d "$lock_dir" ]] && return 0
		return 1
	fi

	return 1
}

#######################################
# Acquire file lock (fail-closed — aborts if lock cannot be obtained)
# Uses flock when available, falls back to mkdir-based lock.
#
# Stale-lock recovery (t2999): when the mkdir fallback path is used,
# each failed mkdir attempt checks whether the existing lock is stale
# (dead PID, corrupt PID file with old mtime, or hung-holder age
# ceiling) via _ledger_lock_is_stale. If stale, the lockdir is cleared
# and mkdir is retried. Without this, a worker killed mid-registration
# leaves a permanent lockdir that blocks all subsequent ledger writes.
# Canonical incident: marcusquinn/aidevops#21427 — a 24-day-old stale
# lockdir suppressed registration for the entire dispatch fleet.
#
# Returns: 0 on success, 1 on failure (caller must abort write)
#######################################
_acquire_lock() {
	if command -v flock &>/dev/null; then
		exec 8>"$LEDGER_LOCK"
		if ! flock -w 5 8 2>/dev/null; then
			echo "Error: could not acquire ledger lock: $LEDGER_LOCK" >&2
			return 1
		fi
		return 0
	fi

	# Portable fallback: mkdir is atomic on all POSIX systems
	local lock_dir="${LEDGER_LOCK}.d"
	local pid_file="${lock_dir}/pid"
	local max_age="${AIDEVOPS_LEDGER_LOCK_MAX_AGE_S:-60}"
	local attempts=0
	local max_attempts=50 # 50 × 0.1s = 5s timeout

	while ! mkdir "$lock_dir" 2>/dev/null; do
		# Stale-lock recovery (t2999): if the existing lock is stale,
		# clear it and retry mkdir immediately without burning an attempt.
		if _ledger_lock_is_stale "$lock_dir" "$pid_file" "$max_age"; then
			continue
		fi
		attempts=$((attempts + 1))
		if [[ "$attempts" -ge "$max_attempts" ]]; then
			echo "Error: could not acquire ledger lock (mkdir): $lock_dir" >&2
			return 1
		fi
		sleep 0.1
	done

	# Record holder PID inside the lockdir so future waiters can
	# detect a stale lock if we die before _release_lock runs.
	echo "$$" >"$pid_file" 2>/dev/null || true
	return 0
}

#######################################
# Release file lock
# Note: mkdir-based lock now contains a PID file (t2999), so we use
# `rm -rf` instead of `rmdir`. Backward-compatible — rm -rf also
# removes empty lockdirs left by older clients.
#######################################
_release_lock() {
	if command -v flock &>/dev/null; then
		flock -u 8 2>/dev/null || true
	else
		# Remove mkdir-based lock (and any PID file inside it)
		local lock_dir="${LEDGER_LOCK}.d"
		rm -rf "$lock_dir" 2>/dev/null || true
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
	local dispatch_tier=""
	local dispatch_model=""

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
		--tier)
			dispatch_tier="${2:-}"
			shift 2
			;;
		--model)
			dispatch_model="${2:-}"
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
		--arg tier "$dispatch_tier" \
		--arg model "$dispatch_model" \
		'{session_key: $sk, issue_number: $inum, repo_slug: $slug, pid: $pid, dispatched_at: $ts, status: "in-flight", updated_at: $ts, tier: $tier, model: $model}' \
		>>"$LEDGER_FILE"

	# Append to tier telemetry log (append-only, never pruned)
	local telemetry_file="${LEDGER_DIR}/tier-telemetry.jsonl"
	jq -cn \
		--arg inum "$issue_number" \
		--arg slug "$repo_slug" \
		--arg tier "$dispatch_tier" \
		--arg model "$dispatch_model" \
		--arg ts "$now" \
		'{issue: $inum, repo: $slug, tier: $tier, model: $model, dispatched_at: $ts, outcome: "pending"}' \
		>>"$telemetry_file" 2>/dev/null || true

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
# Record dispatch outcome in the tier telemetry log
#
# Appends outcome to the append-only tier-telemetry.jsonl.
# Called by workers on completion or by the escalation function on failure.
#
# Args:
#   --issue NUM          issue number
#   --repo SLUG          repo slug
#   --outcome OUTCOME    "success" | "escalated" | "failed" | "timeout"
#   --reason REASON      escalation reason code (optional)
#   --tokens NUM         tokens used (optional)
#   --tier TIER          tier at dispatch time (optional, for context)
#
# Exit codes: 0 always (best-effort, never fatal)
#######################################
cmd_record_outcome() {
	local issue_number=""
	local repo_slug=""
	local outcome=""
	local reason=""
	local tokens="0"
	local tier=""

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
		--outcome)
			outcome="${2:-}"
			shift 2
			;;
		--reason)
			reason="${2:-}"
			shift 2
			;;
		--tokens)
			tokens="${2:-0}"
			shift 2
			;;
		--tier)
			tier="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	[[ -n "$outcome" ]] || return 0

	local telemetry_file="${LEDGER_DIR}/tier-telemetry.jsonl"
	local now
	now=$(_now_utc)

	jq -cn \
		--arg inum "$issue_number" \
		--arg slug "$repo_slug" \
		--arg tier "$tier" \
		--arg outcome "$outcome" \
		--arg reason "$reason" \
		--argjson tokens "${tokens:-0}" \
		--arg ts "$now" \
		'{issue: $inum, repo: $slug, tier: $tier, outcome: $outcome, reason: $reason, tokens: $tokens, completed_at: $ts}' \
		>>"$telemetry_file" 2>/dev/null || true

	return 0
}

#######################################
# Report tier telemetry summary
#
# Reads tier-telemetry.jsonl and outputs aggregate stats.
# Used by the pulse sweep and /optimize-tiers command.
#
# Exit codes: 0 always
#######################################
cmd_tier_report() {
	local telemetry_file="${LEDGER_DIR}/tier-telemetry.jsonl"

	if [[ ! -s "$telemetry_file" ]]; then
		echo "No tier telemetry data yet."
		return 0
	fi

	local total success escalated failed
	total=$(wc -l <"$telemetry_file" | tr -d ' ')
	success=$(grep -c '"outcome":"success"' "$telemetry_file" 2>/dev/null) || success=0
	escalated=$(grep -c '"outcome":"escalated"' "$telemetry_file" 2>/dev/null) || escalated=0
	failed=$(grep -c '"outcome":"failed"' "$telemetry_file" 2>/dev/null) || failed=0

	echo "=== Tier Dispatch Telemetry ==="
	echo "Total dispatches: $total"
	echo "Success: $success"
	echo "Escalated: $escalated"
	echo "Failed: $failed"
	echo ""
	echo "By tier:"
	jq -r '.tier' "$telemetry_file" 2>/dev/null | sort | uniq -c | sort -rn
	echo ""
	echo "Escalation reasons:"
	jq -r 'select(.reason != "" and .reason != null) | .reason' "$telemetry_file" 2>/dev/null | sort | uniq -c | sort -rn
	echo ""
	echo "Pass rate by tier:"
	for t in simple standard reasoning; do
		local t_total t_success
		t_total=$(grep -c "\"tier\":\"$t\"" "$telemetry_file" 2>/dev/null) || t_total=0
		t_success=$(jq -r "select(.tier == \"$t\" and .outcome == \"success\") | .tier" "$telemetry_file" 2>/dev/null | wc -l | tr -d ' ') || t_success=0
		if [[ "$t_total" -gt 0 ]]; then
			local pct
			pct=$(awk "BEGIN {printf \"%.1f\", ${t_success}/${t_total}*100}")
			echo "  tier:$t — $t_success/$t_total ($pct%)"
		fi
	done

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

	# GH#21105: single-pass jq extraction. The previous loop forked jq up to
	# 3x per line (status, dispatched_at, pid) — for 600+ ledger entries this
	# was ~10s per cycle. One jq invocation produces all needed metadata as TSV;
	# bash then performs the kill -0 liveness checks (which jq cannot do) and
	# decides which entries to expire. Final rewrite uses a single jq pass too.
	local tsv_data
	tsv_data=$(jq -nr '
		[inputs] | to_entries[]
		| .key as $idx | .value as $v
		| "\($idx)\t\($v.status // "")\t\($v.dispatched_at // "")\t\($v.pid // 0)"
	' "$LEDGER_FILE" 2>/dev/null) || tsv_data=""

	# Walk the TSV and collect ledger line indices that need to be expired.
	# should_expire is an integer (0/1) rather than a "true"/"false" string
	# to avoid tripping the repeated-string-literal ratchet on the value.
	local -a expire_indices=()
	local idx status dispatched_at entry_pid dispatch_epoch age
	local -i should_expire
	while IFS=$'\t' read -r idx status dispatched_at entry_pid; do
		[[ -z "$idx" ]] && continue
		[[ "$status" != "in-flight" ]] && continue

		should_expire=0
		if [[ -n "$dispatched_at" ]]; then
			dispatch_epoch=$(_iso_to_epoch "$dispatched_at")
			if [[ "$dispatch_epoch" =~ ^[0-9]+$ ]] && [[ "$dispatch_epoch" -gt 0 ]]; then
				age=$((now_epoch - dispatch_epoch))
				if [[ "$age" -gt "$ttl" ]]; then
					should_expire=1
				fi
			fi
		fi
		if ((!should_expire)) && [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
			if ! kill -0 "$entry_pid" 2>/dev/null; then
				should_expire=1
			fi
		fi

		if ((should_expire)); then
			expire_indices+=("$idx")
		fi
	done <<<"$tsv_data"

	expired_count=${#expire_indices[@]}

	if [[ "$expired_count" -gt 0 ]]; then
		# Single jq pass rewrites the file: entries at the listed indices have
		# their status flipped to "failed" with a fresh updated_at timestamp.
		local indices_csv
		indices_csv=$(IFS=,; printf '%s' "${expire_indices[*]}")
		# Two subtleties learned the hard way during GH#21105:
		#   1. -n is REQUIRED: without it, jq consumes the first JSON line as
		#      its initial input, then `[inputs]` collects only entries 2..N.
		#      Indices in $exp (assigned by the matching -n TSV pass above)
		#      become off-by-one, and the first ledger entry is silently
		#      dropped from the rewritten file.
		#   2. .key MUST be bound to $k BEFORE the pipe into $exp. Writing
		#      `$exp | index(.key)` evaluates `.key` against $exp (an array)
		#      and jq raises "Cannot index array with string 'key'", which
		#      `2>/dev/null` would swallow into the cp fallback path.
		if ! jq -nc --arg ts "$now_ts" --argjson exp "[${indices_csv}]" '
			[inputs] | to_entries[]
			| .key as $k
			| if (($exp | index($k)) != null)
			  then .value | .status = "failed" | .updated_at = $ts
			  else .value
			  end
		' "$LEDGER_FILE" >"$tmp_file" 2>/dev/null; then
			# jq failure: preserve original file rather than risk corruption.
			cp "$LEDGER_FILE" "$tmp_file"
			expired_count=0
		fi
		mv "$tmp_file" "$LEDGER_FILE"
	else
		rm -f "$tmp_file"
	fi

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

	local now_epoch prune_threshold pruned_count orig_count new_count
	now_epoch=$(_now_epoch)
	prune_threshold=86400 # 24 hours
	pruned_count=0
	local tmp_file
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX")

	# GH#21105: single-pass jq filter. Previously this loop forked jq up to 2x
	# per line (status, updated_at) — for 600+ ledger entries this was ~7s per
	# cycle. The new filter processes all entries in one jq invocation:
	# in-flight entries are always kept; completed/failed entries are kept only
	# when updated_at is within the prune threshold (default 24h). Empty/
	# unparseable updated_at values are kept (fail-open) to avoid silent loss.
	#
	# fromdateiso8601 in jq parses RFC 3339 / ISO 8601 with the 'Z' suffix
	# directly; the try/catch falls back to "$now" so unparseable timestamps
	# keep the entry rather than dropping it.
	if ! jq -c --argjson now "$now_epoch" --argjson threshold "$prune_threshold" '
		select(
			(.status == "in-flight")
			or
			(((.updated_at // "") | length) == 0)
			or
			(($now - ((.updated_at) | try fromdateiso8601 catch $now)) <= $threshold)
		)
	' "$LEDGER_FILE" >"$tmp_file" 2>/dev/null; then
		# jq failure: preserve original ledger rather than risk corruption.
		cp "$LEDGER_FILE" "$tmp_file"
	fi

	# Pruned count = original line count - kept line count.
	orig_count=$(wc -l <"$LEDGER_FILE" | tr -d ' ')
	new_count=$(wc -l <"$tmp_file" | tr -d ' ')
	[[ "$orig_count" =~ ^[0-9]+$ ]] || orig_count=0
	[[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0
	pruned_count=$((orig_count - new_count))
	[[ "$pruned_count" -lt 0 ]] && pruned_count=0

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
	record-outcome)
		cmd_record_outcome "$@"
		;;
	tier-report)
		cmd_tier_report
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
