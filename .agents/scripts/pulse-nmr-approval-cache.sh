#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-nmr-approval-cache.sh — Cached immutable ever-NMR provenance.
# Sourced by pulse-nmr-approval.sh; inherits the caller's cache configuration,
# LOGFILE, gh transport, and jq dependency. No top-level external actions.

[[ -n "${_PULSE_NMR_APPROVAL_CACHE_LOADED:-}" ]] && return 0
_PULSE_NMR_APPROVAL_CACHE_LOADED=1

# Lock reclamation needs portable mtimes; pulse-wrapper normally loads this.
if ! declare -F _file_mtime_epoch >/dev/null 2>&1; then
	# shellcheck source=./portable-stat.sh
	source "${BASH_SOURCE[0]%/*}/portable-stat.sh"
fi

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

# Read a non-negative integer setting, falling back to its default (GH#37869).
# Arguments: $1 - candidate value, $2 - default
_ever_nmr_lock_setting() {
	local value="$1"
	local default_value="$2"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		# Force base 10: Bash arithmetic treats 08/09 as invalid octal.
		printf '%s\n' "$((10#$value))"
	else
		printf '%s\n' "$default_value"
	fi
	return 0
}

# Print a path's mtime epoch; returns 1 when unavailable (path vanished).
# Arguments: $1 - path
_ever_nmr_lock_mtime() {
	local path="$1"
	local mtime=""
	# _file_mtime_epoch prints 0 when the path vanished; treat that as unavailable.
	mtime=$(_file_mtime_epoch "$path" 2>/dev/null) || mtime=""
	[[ "$mtime" =~ ^[0-9]+$ && "$mtime" -gt 0 ]] || return 1
	printf '%s\n' "$mtime"
	return 0
}

# Print a path's age in seconds; returns 1 when the mtime is unavailable.
# Arguments: $1 - path
_ever_nmr_lock_age() {
	local path="$1"
	local mtime="" now=""
	mtime=$(_ever_nmr_lock_mtime "$path") || return 1
	now=$(date +%s)
	local age=$((now - mtime))
	[[ "$age" -ge 0 ]] || age=0
	printf '%s\n' "$age"
	return 0
}

# Print a token naming one lock instance: its directory inode plus its owner
# record ("none" when absent or invalid). A replacement lock differs in at
# least one part, so a reclaimer can confirm it still holds the instance it
# judged stale. Returns 1 when the directory has vanished.
# Arguments: $1 - lock dir
_ever_nmr_lock_instance() {
	local lock_dir="$1"
	local inode="" owner_pid=""
	read -r inode _ <<<"$(ls -di "$lock_dir" 2>/dev/null)"
	[[ "$inode" =~ ^[0-9]+$ ]] || return 1
	if [[ -f "${lock_dir}/owner.pid" ]]; then
		IFS= read -r owner_pid 2>/dev/null <"${lock_dir}/owner.pid" || owner_pid=""
	fi
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || owner_pid="none"
	printf '%s:%s\n' "$inode" "$owner_pid"
	return 0
}

# Reclaim a stale ever-NMR cache lock (GH#37869). Stale means a dead owner PID,
# or no valid owner.pid for at least the orphan age (holder killed between
# mkdir and the owner write, or between the owner removal and rmdir). A live
# owner is never reclaimed: legacy `$$` records come only from processes still
# running pre-fix code, and their locks become dead-owner locks once they exit.
# A .reclaim directory elects one reclaimer while the lock still blocks
# writers; the winner re-checks the instance so it never removes a lock that
# another caller reclaimed and re-acquired in the meantime.
# Arguments: $1 - lock dir, $2 - ownerless orphan age
# Returns: 0 only when the stale lock was removed
_ever_nmr_cache_reclaim_stale_lock() {
	local lock_dir="$1"
	local orphan_age="$2"
	local instance="" owner_pid="" stale_reason="" lock_age=""

	instance=$(_ever_nmr_lock_instance "$lock_dir") || return 1
	lock_age=$(_ever_nmr_lock_age "$lock_dir") || return 1
	owner_pid="${instance#*:}"

	if [[ "$owner_pid" != "none" ]]; then
		kill -0 "$owner_pid" 2>/dev/null && return 1
		stale_reason="owner PID ${owner_pid} gone"
	elif [[ "$lock_age" -ge "$orphan_age" ]]; then
		stale_reason="ownerless for ${lock_age}s"
	else
		return 1
	fi

	# A reclaimer killed mid-reclaim leaves .reclaim behind; clear it once old.
	local reclaim_dir="${lock_dir}/.reclaim"
	local reclaim_age=""
	if [[ -d "$reclaim_dir" ]]; then
		reclaim_age=$(_ever_nmr_lock_age "$reclaim_dir") || reclaim_age=0
		[[ "$reclaim_age" -ge "$orphan_age" ]] && rmdir "$reclaim_dir" 2>/dev/null
	fi
	mkdir "$reclaim_dir" 2>/dev/null || return 1

	# Re-validate after the election: if the judged instance was replaced, back off.
	local current=""
	current=$(_ever_nmr_lock_instance "$lock_dir") || current=""
	if [[ "$current" != "$instance" ]]; then
		rmdir "$reclaim_dir" 2>/dev/null || true
		return 1
	fi

	echo "[pulse-wrapper] _ever_nmr_cache_with_lock: clearing stale lock (${stale_reason})" >>"$LOGFILE"
	rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
	rmdir "$reclaim_dir" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || return 1
	return 0
}

_ever_nmr_cache_with_lock() {
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	local max_retries="" orphan_age=""
	max_retries=$(_ever_nmr_lock_setting "${EVER_NMR_LOCK_RETRIES:-}" 50)
	orphan_age=$(_ever_nmr_lock_setting "${EVER_NMR_LOCK_ORPHAN_AGE_SECS:-}" 60)
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if _ever_nmr_cache_reclaim_stale_lock "$lock_dir" "$orphan_age"; then
			continue
		fi
		retries=$((retries + 1))
		if [[ "$retries" -ge "$max_retries" ]]; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		sleep 0.1
	done

	# Record owner PID inside lock directory so retrying callers can detect
	# staleness. If the directory vanished (reclaimed while this caller paused
	# past the orphan age), ownership is lost: skip the callback and leave the
	# path alone, since it may now belong to another caller.
	# Resolve the PID in this shell, not a command substitution: in parallel
	# dispatch subshells `$$` is the parent pulse PID. Bash 3.2 has no BASHPID;
	# exec makes sh's PPID this shell.
	local owner_pid="${BASHPID:-}"
	if [[ -z "$owner_pid" ]]; then
		owner_pid="$(exec sh -c 'printf "%s" "$PPID"')" || owner_pid="$$"
	fi
	if ! printf '%s\n' "$owner_pid" 2>/dev/null >"${lock_dir}/owner.pid"; then
		echo "[pulse-wrapper] _ever_nmr_cache_with_lock: lost lock before owner registration" >>"$LOGFILE"
		return 1
	fi
	local rc=0
	"$@" || rc=$?
	# Release only a lock this caller still owns.
	local recorded=""
	if [[ -f "${lock_dir}/owner.pid" ]]; then
		IFS= read -r recorded 2>/dev/null <"${lock_dir}/owner.pid" || recorded=""
	fi
	if [[ "$recorded" == "$owner_pid" ]]; then
		rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
		rmdir "$lock_dir" 2>/dev/null || true
	fi
	return "$rc"
}

_ever_nmr_cache_get() {
	local issue_num="$1"
	local slug="$2"
	local key="" now_epoch="" cache_json="" cache_value="" checked_at="" age=""

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
	local state_dir="" cache_json="" key="" now_epoch="" tmp_file=""

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
