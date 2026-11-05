#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-nmr-approval-cache.sh — Cached immutable ever-NMR provenance.
# Sourced by pulse-nmr-approval.sh; inherits the caller's cache configuration,
# LOGFILE, gh transport, and jq dependency. No top-level external actions.

[[ -n "${_PULSE_NMR_APPROVAL_CACHE_LOADED:-}" ]] && return 0
_PULSE_NMR_APPROVAL_CACHE_LOADED=1

NMR_CACHE_TRUE="true"
NMR_CACHE_FALSE="false"
NMR_CACHE_UNKNOWN="unknown"

#######################################
# Cached ever-NMR provenance helpers (GH#17458)
#
# Positive results are immutable and can be cached indefinitely.
# Negative results are cached for a short TTL to avoid a timeline API call
# on every dispatch candidate while still noticing new NMR labels promptly.
#######################################
_ever_nmr_cache_key() {
	local issue_num="$1"
	local slug="$2"
	printf '%s\n' "${slug}#${issue_num}"
	return 0
}

_ever_nmr_cache_load() {
	if [[ ! -f "$EVER_NMR_CACHE_FILE" ]]; then
		printf '{}\n'
		return 0
	fi

	local content
	content=$(cat "$EVER_NMR_CACHE_FILE" 2>/dev/null) || content="{}"
	if ! printf '%s' "$content" | jq empty >/dev/null 2>&1; then
		content="{}"
	fi

	printf '%s\n' "$content"
	return 0
}

_ever_nmr_cache_with_lock() {
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		# Stale lock detection: read the owner PID stored in the lock directory.
		# If that process is no longer running, the lock is orphaned — clear it.
		local _nmr_owner_pid
		_nmr_owner_pid=$(cat "${lock_dir}/owner.pid" 2>/dev/null || true)
		if [[ -n "$_nmr_owner_pid" ]] && ! kill -0 "$_nmr_owner_pid" 2>/dev/null; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: clearing stale lock (owner PID ${_nmr_owner_pid} gone)" >>"$LOGFILE"
			rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
			rmdir "$lock_dir" 2>/dev/null || true
			continue
		fi
		sleep 0.1
	done

	# Record owner PID inside lock directory so retrying callers can detect staleness.
	printf '%s\n' "$$" >"${lock_dir}/owner.pid" 2>/dev/null || true
	local rc=0
	"$@" || rc=$?
	rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return "$rc"
}

_ever_nmr_cache_get() {
	local issue_num="$1"
	local slug="$2"
	local key now_epoch cache_json cache_value checked_at age

	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	cache_json=$(_ever_nmr_cache_load)
	cache_value=$(printf '%s' "$cache_json" | jq -r --arg key "$key" --arg unknown "$NMR_CACHE_UNKNOWN" 'if .[$key] == null then $unknown elif .[$key].ever_nmr == true then "true" elif .[$key].ever_nmr == false then "false" else $unknown end' 2>/dev/null) || cache_value="$NMR_CACHE_UNKNOWN"
	checked_at=$(printf '%s' "$cache_json" | jq -r --arg key "$key" '.[$key].checked_at // 0' 2>/dev/null) || checked_at=0
	[[ "$checked_at" =~ ^[0-9]+$ ]] || checked_at=0

	if [[ "$cache_value" == "$NMR_CACHE_TRUE" ]]; then
		printf 'true\n'
		return 0
	fi

	if [[ "$cache_value" == "$NMR_CACHE_FALSE" ]]; then
		age=$((now_epoch - checked_at))
		if [[ "$age" -lt "$EVER_NMR_NEGATIVE_CACHE_TTL_SECS" ]]; then
			printf 'false\n'
			return 0
		fi
	fi

	printf 'unknown\n'
	return 0
}

_ever_nmr_cache_set_locked() {
	local issue_num="$1"
	local slug="$2"
	local cache_value="$3"
	local state_dir cache_json key now_epoch tmp_file

	[[ "$cache_value" == "$NMR_CACHE_TRUE" || "$cache_value" == "$NMR_CACHE_FALSE" ]] || return 1

	state_dir=$(dirname "$EVER_NMR_CACHE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	cache_json=$(_ever_nmr_cache_load)
	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	tmp_file=$(mktemp "${state_dir}/.ever-nmr-cache.XXXXXX" 2>/dev/null) || return 0

	if printf '%s' "$cache_json" | jq --arg key "$key" --argjson checked_at "$now_epoch" --argjson ever_nmr "$cache_value" '.[$key] = {ever_nmr: $ever_nmr, checked_at: $checked_at}' >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$EVER_NMR_CACHE_FILE" || {
			rm -f "$tmp_file"
			echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to move cache file" >>"$LOGFILE"
		}
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to write cache entry" >>"$LOGFILE"
	fi

	return 0
}

_ever_nmr_cache_set() {
	_ever_nmr_cache_with_lock _ever_nmr_cache_set_locked "$@" || return 0
	return 0
}

#######################################
# Check if an issue was ever labeled needs-maintainer-review (t1894).
# Uses the immutable GitHub timeline API — label removal does not erase
# the history. This provenance remains relevant for external-author issues;
# write-authorized authors are independently trusted and must not self-approve.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional precomputed status: true|false|unknown
# Returns: 0 if the issue was ever NMR-labeled, 1 otherwise
#######################################
issue_was_ever_nmr() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 1

	case "$known_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local cache_status
	cache_status=$(_ever_nmr_cache_get "$issue_num" "$slug")
	case "$cache_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local ever_count
	ever_count=$(gh api "repos/${slug}/issues/${issue_num}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "needs-maintainer-review")] | length' \
		2>/dev/null) || ever_count=0
	[[ "$ever_count" =~ ^[0-9]+$ ]] || ever_count=0

	if [[ "$ever_count" -gt 0 ]]; then
		_ever_nmr_cache_set "$issue_num" "$slug" "$NMR_CACHE_TRUE"
		return 0
	fi

	_ever_nmr_cache_set "$issue_num" "$slug" "$NMR_CACHE_FALSE"
	return 1
}
