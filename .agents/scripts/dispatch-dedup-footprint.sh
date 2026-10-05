#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-footprint.sh — File-footprint overlap throttle for dispatch (t2117/GH#19109)
#
# Prevents parallel dispatch of workers whose target file sets overlap.
# When two issues both modify the same file, whichever PR merges first
# invalidates the other (merge conflict or semantic conflict). The
# update-branch salvage path (t2116) rescues trivial cases, but genuine
# line-conflicting edits still cascade through CONFLICTING-close.
#
# This module is sourced by pulse-dispatch-core.sh. Depends on
# shared-constants.sh being sourced first by the orchestrator.
#
# Functions:
#   - _footprint_extract_paths    — parse file paths from issue body text
#   - _footprint_get_inflight     — collect file footprints for all in-flight issues
#   - _footprint_check_overlap    — check if a candidate's files overlap with in-flight
#
# Integration point: _dispatch_dedup_check_layers() in pulse-dispatch-core.sh
# calls _footprint_check_overlap() after the large-file gate and before the
# 7-layer dedup chain.
#
# Decay: natural — the check queries issues with active status labels
# (status:queued, status:in-progress, status:in-review, status:claimed). Once
# the blocking issue's PR merges and labels clear, the overlap disappears.
#
# Same-cycle reservations (GH#32977): each candidate runs in its own dispatch
# subshell and a launched worker only becomes visible once its status:queued
# edit lands, so two overlapping candidates in one refill batch could both
# pass the live check. The overlap check therefore also consults, and on
# success atomically writes, a per-repo reservation of the candidate's
# declared footprint under a short lock. Reservations are released when the
# launch fails, retired a short grace period after the issue shows durable
# lifecycle labels, and otherwise expire after a bounded TTL.

[[ -n "${_DISPATCH_DEDUP_FOOTPRINT_LOADED:-}" ]] && return 0
_DISPATCH_DEDUP_FOOTPRINT_LOADED=1

# Cache for in-flight footprints — built once per pulse cycle, not per candidate.
# Keyed by repo_slug. Format: associative array of file→issue_number mappings.
# Populated lazily on first call to _footprint_check_overlap for each repo.
_FOOTPRINT_CACHE_REPO=""
_FOOTPRINT_CACHE_DATA=""
_FOOTPRINT_CACHE_EPOCH=0

# Cross-cycle defer state. The live overlap check remains authoritative; this
# state only suppresses unchanged reconsideration until a bounded wake event.
_FOOTPRINT_DEFER_STATE_DIR="${AIDEVOPS_FOOTPRINT_DEFER_STATE_DIR:-${HOME}/.aidevops/cache/footprint-defers}"
_FOOTPRINT_DEFER_TTL_SECONDS="${AIDEVOPS_FOOTPRINT_DEFER_TTL_SECONDS:-1800}"
[[ "$_FOOTPRINT_DEFER_TTL_SECONDS" =~ ^[1-9][0-9]*$ ]] || _FOOTPRINT_DEFER_TTL_SECONDS=1800
_FOOTPRINT_DEFER_SCHEMA="aidevops-footprint-defer/v1"

# Same-cycle reservation store (GH#32977). The TTL only needs to cover the
# launch -> status:queued/in-progress window; durable labels replace it.
_FOOTPRINT_RESERVATION_DIR="${AIDEVOPS_FOOTPRINT_RESERVATION_DIR:-${HOME}/.aidevops/cache/footprint-reservations}"
_FOOTPRINT_RESERVATION_TTL_SECONDS="${AIDEVOPS_FOOTPRINT_RESERVATION_TTL_SECONDS:-900}"
[[ "$_FOOTPRINT_RESERVATION_TTL_SECONDS" =~ ^[1-9][0-9]*$ ]] || _FOOTPRINT_RESERVATION_TTL_SECONDS=900
_FOOTPRINT_RESERVATION_SCHEMA="aidevops-footprint-reservation/v1"
_FOOTPRINT_RESERVATION_LOCK_STALE_SECONDS=30
_FOOTPRINT_RESERVATION_LOCK_ATTEMPTS=50
# Must exceed the longest live-read -> lock window (gh fetch + lock wait).
_FOOTPRINT_RESERVATION_SUPERSEDE_GRACE_SECONDS=120

# Release/version files are low-information overlap: sharing only these does
# not block dispatch, but any shared implementation file still does.
# Basenames match case-insensitively. `changelog.txt`/`readme.txt` are the
# WordPress.org plugin conventions (GH#33522). Repos with append-only
# README tables can opt in to more basenames via repos.json
# `footprint_low_info_paths` (array of basenames).
_FOOTPRINT_LOW_INFO_BASENAMES="${AIDEVOPS_FOOTPRINT_LOW_INFO_BASENAMES:-VERSION VERSION.txt version.txt .version CHANGELOG CHANGELOG.md CHANGES.md HISTORY.md changelog.txt readme.txt}"

# Maximum age of the footprint cache in seconds. After this, rebuild.
# 30s: long enough to catch concurrent same-file dispatch races (the
# original use-case), short enough to limit blast radius when issues
# close mid-window. See invalidate_footprint_cache_for_issue() for
# immediate eviction on known-close events (t2927/GH#21103).
_FOOTPRINT_CACHE_TTL=30

#######################################
# Compute a portable SHA-256 digest for text.
# Args: $1 = text
# Output: lowercase hex digest
# Exit: 0 on success, 1 when no digest implementation is available
#######################################
_footprint_hash_text() {
	local value="$1"
	local digest=""
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | sha256sum | awk '{print $1}') || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}') || return 1
	elif command -v openssl >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}') || return 1
	else
		return 1
	fi
	[[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
	printf '%s\n' "$digest" | tr '[:upper:]' '[:lower:]'
	return 0
}

#######################################
# Prepare the private defer-state directory.
# Exit: 0 when safe, 1 otherwise
#######################################
_footprint_defer_prepare_dir() {
	local state_dir="$_FOOTPRINT_DEFER_STATE_DIR"
	if [[ ! -e "$state_dir" && ! -L "$state_dir" ]]; then
		(umask 077 && mkdir -p "$state_dir") || return 1
	fi
	[[ -d "$state_dir" && ! -L "$state_dir" && -O "$state_dir" ]] || return 1
	chmod 0700 "$state_dir" 2>/dev/null || return 1
	return 0
}

#######################################
# Resolve the state path for a repository candidate without exposing the slug
# in the filename.
# Args: $1 = repo slug, $2 = candidate issue
# Output: absolute state path
#######################################
_footprint_defer_state_path() {
	local repo_slug="$1"
	local issue_number="$2"
	local repo_hash=""
	local normalized_repo=""
	normalized_repo=$(printf '%s' "$repo_slug" | tr '[:upper:]' '[:lower:]')
	repo_hash=$(_footprint_hash_text "$normalized_repo") || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	printf '%s/%s-%s.json\n' "$_FOOTPRINT_DEFER_STATE_DIR" "$repo_hash" "$issue_number"
	return 0
}

#######################################
# Atomically write one validated defer-state object.
# Args: $1 = destination path, $2 = JSON object
#######################################
_footprint_defer_write_json() {
	local state_path="$1"
	local state_json="$2"
	local temp_path=""
	command -v jq >/dev/null 2>&1 || return 1
	printf '%s' "$state_json" | jq -e --arg schema "$_FOOTPRINT_DEFER_SCHEMA" '.schema == $schema' >/dev/null 2>&1 || return 1
	_footprint_defer_prepare_dir || return 1
	temp_path=$(mktemp "${_FOOTPRINT_DEFER_STATE_DIR}/.defer.XXXXXX" 2>/dev/null) || return 1
	if ! printf '%s\n' "$state_json" >"$temp_path"; then
		rm -f "$temp_path" 2>/dev/null || true
		return 1
	fi
	chmod 0600 "$temp_path" 2>/dev/null || {
		rm -f "$temp_path" 2>/dev/null || true
		return 1
	}
	if ! mv -f "$temp_path" "$state_path"; then
		rm -f "$temp_path" 2>/dev/null || true
		return 1
	fi
	return 0
}

#######################################
# Read one structurally valid defer record.
# Args: $1 = state path
# Output: compact JSON
#######################################
_footprint_defer_read_json() {
	local state_path="$1"
	[[ -f "$state_path" && ! -L "$state_path" && -O "$state_path" ]] || return 1
	jq -ce --arg schema "$_FOOTPRINT_DEFER_SCHEMA" '
		select(.schema == $schema)
		| select([.candidate_issue, .blocking_issue, .expires_at] | all(type == "number"))
		| select((.candidate_hash | type) == "string")
		| select((.blocker_hash | type) == "string")
	' "$state_path" 2>/dev/null
	return $?
}

#######################################
# Persist a wake/tombstone so diagnostics can explain why suppression ended.
# Args: $1 = state path, $2 = current JSON, $3 = wake reason
#######################################
_footprint_defer_wake() {
	local state_path="$1"
	local state_json="$2"
	local wake_reason="$3"
	local now_epoch=""
	local updated_json=""
	now_epoch=$(date +%s)
	updated_json=$(printf '%s' "$state_json" | jq -c \
		--arg reason "$wake_reason" --argjson now "$now_epoch" \
		'.active = false | .wake_reason = $reason | .wake_at = $now') || return 1
	_footprint_defer_write_json "$state_path" "$updated_json" || return 1
	if [[ -n "${LOGFILE:-}" ]]; then
		local candidate_issue=""
		local repo_slug=""
		local blocking_issue=""
		candidate_issue=$(printf '%s' "$updated_json" | jq -r '.candidate_issue')
		repo_slug=$(printf '%s' "$updated_json" | jq -r '.repo_slug')
		blocking_issue=$(printf '%s' "$updated_json" | jq -r '.blocking_issue')
		printf '[footprint-defer] event=wake issue=#%s repo=%s blocker=#%s wake_reason=%s ts=%s\n' \
			"$candidate_issue" "$repo_slug" "$blocking_issue" "$wake_reason" "$now_epoch" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Record a newly confirmed live overlap. This runs inside the overlap command
# substitution, so only filesystem/log side effects are used.
# Args: candidate issue, repo slug, candidate files, inflight data,
#       blocking issue, overlapping files
#######################################
_footprint_defer_record_overlap() {
	local issue_number="$1"
	local repo_slug="$2"
	local candidate_files="$3"
	local inflight_data="$4"
	local blocking_issue="$5"
	local overlapping_files="$6"
	local blocker_files=""
	local candidate_hash="" blocker_hash="" state_path="" existing_json=""
	local now_epoch="" expires_at=""
	local state_json=""
	command -v jq >/dev/null 2>&1 || return 0
	blocker_files=$(printf '%s\n' "$inflight_data" | awk -F '|' -v issue="$blocking_issue" '$2 == issue {print $1}' | sort -u)
	[[ -n "$blocker_files" ]] || return 0
	candidate_hash=$(_footprint_hash_text "$candidate_files") || return 0
	blocker_hash=$(_footprint_hash_text "$blocker_files") || return 0
	state_path=$(_footprint_defer_state_path "$repo_slug" "$issue_number") || return 0
	if existing_json=$(_footprint_defer_read_json "$state_path"); then
		if printf '%s' "$existing_json" | jq -e \
			--arg candidate "$candidate_hash" --arg blocker "$blocker_hash" --argjson blocking "$blocking_issue" \
			'.active == true and .candidate_hash == $candidate and .blocker_hash == $blocker and .blocking_issue == $blocking' >/dev/null 2>&1; then
			return 0
		fi
	fi
	now_epoch=$(date +%s)
	expires_at=$((now_epoch + _FOOTPRINT_DEFER_TTL_SECONDS))
	state_json=$(jq -cn \
		--arg schema "$_FOOTPRINT_DEFER_SCHEMA" \
		--arg repo "$repo_slug" \
		--arg candidate_hash "$candidate_hash" \
		--arg blocker_hash "$blocker_hash" \
		--arg overlapping_files "$overlapping_files" \
		--argjson candidate_issue "$issue_number" \
		--argjson blocking_issue "$blocking_issue" \
		--argjson created_at "$now_epoch" \
		--argjson expires_at "$expires_at" \
		'{schema:$schema,repo_slug:$repo,candidate_issue:$candidate_issue,blocking_issue:$blocking_issue,candidate_hash:$candidate_hash,blocker_hash:$blocker_hash,overlapping_files:$overlapping_files,created_at:$created_at,expires_at:$expires_at,suppressed_count:0,active:true,wake_reason:"none",wake_at:0}') || return 0
	_footprint_defer_write_json "$state_path" "$state_json" || return 0
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[footprint-defer] event=deferred issue=#%s repo=%s blocker=#%s expires_at=%s suppressed=0 wake_reason=none\n' \
			"$issue_number" "$repo_slug" "$blocking_issue" "$expires_at" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Return success when an unchanged durable overlap should suppress this cycle.
# Missing/corrupt/stale state falls through to the authoritative live check.
# Args: $1 = candidate issue, $2 = repo slug, $3 = candidate JSON
# Exit: 0 suppress, 1 reconsider normally
#######################################
_footprint_defer_should_suppress() {
	local issue_number="$1"
	local repo_slug="$2"
	local candidate_json="$3"
	local state_path=""
	local state_json=""
	local candidate_body="" candidate_files="" candidate_hash=""
	local now_epoch="" expires_at=""
	local blocking_issue="" blocker_json="" blocker_state=""
	local blocker_files="" blocker_hash="" updated_json="" suppressed_count=""
	state_path=$(_footprint_defer_state_path "$repo_slug" "$issue_number") || return 1
	if ! state_json=$(_footprint_defer_read_json "$state_path"); then
		[[ -e "$state_path" || -L "$state_path" ]] && rm -f "$state_path" 2>/dev/null || true
		return 1
	fi
	printf '%s' "$state_json" | jq -e '.active == true' >/dev/null 2>&1 || return 1
	if printf '%s' "$candidate_json" | jq -e '[(.labels // [])[]? | if type == "object" then .name else . end] | index("force-dispatch") != null' >/dev/null 2>&1; then
		_footprint_defer_wake "$state_path" "$state_json" "operator_reconsideration" || true
		return 1
	fi
	candidate_body=$(printf '%s' "$candidate_json" | jq -r '.body // ""' 2>/dev/null) || candidate_body=""
	candidate_files=$(_footprint_extract_paths "$candidate_body")
	[[ -n "$candidate_files" ]] || {
		_footprint_defer_wake "$state_path" "$state_json" "candidate_footprint_changed" || true
		return 1
	}
	candidate_hash=$(_footprint_hash_text "$candidate_files") || return 1
	if ! printf '%s' "$state_json" | jq -e --arg hash "$candidate_hash" '.candidate_hash == $hash' >/dev/null 2>&1; then
		_footprint_defer_wake "$state_path" "$state_json" "candidate_footprint_changed" || true
		return 1
	fi
	now_epoch=$(date +%s)
	expires_at=$(printf '%s' "$state_json" | jq -r '.expires_at')
	if [[ ! "$expires_at" =~ ^[0-9]+$ || "$now_epoch" -ge "$expires_at" ]]; then
		_footprint_defer_wake "$state_path" "$state_json" "cooldown_expired" || true
		return 1
	fi
	blocking_issue=$(printf '%s' "$state_json" | jq -r '.blocking_issue')
	if declare -F gh_issue_view >/dev/null 2>&1; then
		blocker_json=$(gh_issue_view "$blocking_issue" --repo "$repo_slug" --json number,state,labels,body 2>/dev/null) || blocker_json=""
	else
		blocker_json=$(gh issue view "$blocking_issue" --repo "$repo_slug" --json number,state,labels,body 2>/dev/null) || blocker_json=""
	fi
	if [[ -n "$blocker_json" ]]; then
		blocker_state=$(printf '%s' "$blocker_json" | jq -r '.state // ""' | tr '[:lower:]' '[:upper:]')
		if [[ "$blocker_state" != "OPEN" ]] || ! printf '%s' "$blocker_json" | jq -e \
			'[(.labels // [])[]? | if type == "object" then .name else . end] | any(. == "status:queued" or . == "status:in-progress" or . == "status:in-review" or . == "status:claimed")' >/dev/null 2>&1; then
			_footprint_defer_wake "$state_path" "$state_json" "blocker_lifecycle_changed" || true
			return 1
		fi
		blocker_files=$(_footprint_extract_paths "$(printf '%s' "$blocker_json" | jq -r '.body // ""')")
		blocker_hash=$(_footprint_hash_text "$blocker_files") || blocker_hash=""
		if [[ -z "$blocker_hash" ]] || ! printf '%s' "$state_json" | jq -e --arg hash "$blocker_hash" '.blocker_hash == $hash' >/dev/null 2>&1; then
			_footprint_defer_wake "$state_path" "$state_json" "blocker_footprint_changed" || true
			return 1
		fi
	fi
	suppressed_count=$(printf '%s' "$state_json" | jq -r '.suppressed_count // 0')
	[[ "$suppressed_count" =~ ^[0-9]+$ ]] || suppressed_count=0
	suppressed_count=$((suppressed_count + 1))
	updated_json=$(printf '%s' "$state_json" | jq -c --argjson count "$suppressed_count" --argjson checked "$now_epoch" \
		'.suppressed_count = $count | .last_checked_at = $checked') || updated_json=""
	[[ -n "$updated_json" ]] && _footprint_defer_write_json "$state_path" "$updated_json" || true
	return 0
}

#######################################
# Return the current/tombstoned defer record for diagnostics.
# Args: $1 = issue number, $2 = repo slug
# Output: compact JSON (or an inactive empty object)
#######################################
_footprint_defer_empty_status_json() {
	local wake_reason="$1"
	jq -cn --arg reason "$wake_reason" '{active:false,wake_reason:$reason}' 2>/dev/null || printf '{}\n'
	return 0
}

_footprint_defer_status_json() {
	local issue_number="$1"
	local repo_slug="$2"
	local state_path=""
	local state_json=""
	local now_epoch=""
	state_path=$(_footprint_defer_state_path "$repo_slug" "$issue_number") || {
		_footprint_defer_empty_status_json "unavailable"
		return 0
	}
	if ! state_json=$(_footprint_defer_read_json "$state_path"); then
		_footprint_defer_empty_status_json "none"
		return 0
	fi
	now_epoch=$(date +%s)
	printf '%s' "$state_json" | jq -c --argjson now "$now_epoch" '
		. + {
			age_seconds: ([$now - (.created_at // $now), 0] | max),
			cooldown_remaining_seconds: ([.expires_at - $now, 0] | max)
		}' 2>/dev/null || _footprint_defer_empty_status_json "parse_error"
	return 0
}

#######################################
# Same-cycle reservation store (GH#32977).
#######################################
_footprint_reservation_log() {
	local message="$1"
	[[ -n "${LOGFILE:-}" ]] || return 0
	printf '[footprint-reservation] %s ts=%s\n' "$message" "$(date +%s)" >>"$LOGFILE" 2>/dev/null || true
	return 0
}

_footprint_reservation_prepare_dir() {
	local state_dir="$_FOOTPRINT_RESERVATION_DIR"
	if [[ ! -e "$state_dir" && ! -L "$state_dir" ]]; then
		(umask 077 && mkdir -p "$state_dir") || return 1
	fi
	[[ -d "$state_dir" && ! -L "$state_dir" && -O "$state_dir" ]] || return 1
	chmod 0700 "$state_dir" 2>/dev/null || return 1
	return 0
}

# Hash the repo slug so reservation filenames never expose private repo names.
_footprint_reservation_repo_key() {
	local repo_slug="$1"
	local normalized_repo=""
	[[ -n "$repo_slug" ]] || return 1
	normalized_repo=$(printf '%s' "$repo_slug" | tr '[:upper:]' '[:lower:]')
	_footprint_hash_text "$normalized_repo"
	return $?
}

#######################################
# Acquire the per-repo reservation lock (mkdir is atomic on local filesystems).
# A lock whose stamp is older than the stale bound, or that never received a
# stamp, is broken so a crashed dispatch subshell cannot wedge dispatch.
# Args: $1 = repo key
# Output: lock directory path
# Exit: 0 acquired, 1 busy
#######################################
_footprint_reservation_lock() {
	local repo_key="$1"
	local lock_dir="${_FOOTPRINT_RESERVATION_DIR}/${repo_key}.lock"
	local attempt=0 stamp="" now_epoch=""
	while [[ "$attempt" -lt "$_FOOTPRINT_RESERVATION_LOCK_ATTEMPTS" ]]; do
		if mkdir "$lock_dir" 2>/dev/null; then
			date +%s >"${lock_dir}/stamp" 2>/dev/null || true
			printf '%s\n' "$lock_dir"
			return 0
		fi
		attempt=$((attempt + 1))
		stamp=$(cat "${lock_dir}/stamp" 2>/dev/null) || stamp=""
		now_epoch=$(date +%s)
		if [[ "$stamp" =~ ^[0-9]+$ ]]; then
			if [[ $((now_epoch - stamp)) -gt "$_FOOTPRINT_RESERVATION_LOCK_STALE_SECONDS" ]]; then
				rm -rf "$lock_dir" 2>/dev/null || true
				continue
			fi
		elif [[ "$attempt" -ge $((_FOOTPRINT_RESERVATION_LOCK_ATTEMPTS / 2)) ]]; then
			rm -rf "$lock_dir" 2>/dev/null || true
			continue
		fi
		sleep 0.1
	done
	return 1
}

#######################################
# Print active reservations for a repo as "path|issue" lines. Expired or
# malformed records are pruned; records for issues that already carry durable
# lifecycle labels (supplied as superseded issues) are replaced by that live
# evidence and removed. Call with the repo lock held.
# Args: $1 = repo key, $2 = issue to exclude, $3 = newline-separated live issues
#######################################
_footprint_reservation_entries() {
	local repo_key="$1"
	local exclude_issue="$2"
	local superseded_issues="$3"
	local record_path="" record_json="" record_issue="" now_epoch=""
	now_epoch=$(date +%s)
	for record_path in "${_FOOTPRINT_RESERVATION_DIR}/${repo_key}-"*.json; do
		[[ -f "$record_path" && ! -L "$record_path" && -O "$record_path" ]] || continue
		if ! record_json=$(jq -ce --arg schema "$_FOOTPRINT_RESERVATION_SCHEMA" --argjson now "$now_epoch" '
			select(.schema == $schema and (.issue | type) == "number"
				and (.expires_at | type) == "number" and (.paths | type) == "array")
			| select(.expires_at > $now)' "$record_path" 2>/dev/null); then
			rm -f "$record_path" 2>/dev/null || true
			continue
		fi
		record_issue=$(printf '%s' "$record_json" | jq -r '.issue')
		[[ "$record_issue" == "$exclude_issue" ]] && continue
		if printf '%s\n' "$superseded_issues" | grep -qx "$record_issue"; then
			# This caller's live evidence already covers the issue.
			_footprint_reservation_supersede "$record_path" "$record_json" "$record_issue" "$now_epoch"
			continue
		fi
		printf '%s' "$record_json" | jq -r --arg issue "$record_issue" \
			'.paths[] | select(type == "string" and length > 0) | . + "|" + $issue'
	done
	return 0
}

#######################################
# Retire a reservation whose issue now shows durable lifecycle labels. The
# first sighting only stamps superseded_at: a concurrent caller whose live read
# predates those labels may still be about to take the lock and must see the
# reservation. Removal waits for a grace period longer than any read-to-lock
# window. Call with the repo lock held.
# Args: $1 = record path, $2 = record json, $3 = issue, $4 = now epoch
#######################################
_footprint_reservation_supersede() {
	local record_path="$1"
	local record_json="$2"
	local record_issue="$3"
	local now_epoch="$4"
	local superseded_at="" temp_path=""
	superseded_at=$(printf '%s' "$record_json" | jq -r '.superseded_at // 0' 2>/dev/null) || superseded_at=0
	[[ "$superseded_at" =~ ^[0-9]+$ ]] || superseded_at=0
	if [[ "$superseded_at" -eq 0 ]]; then
		temp_path=$(mktemp "${_FOOTPRINT_RESERVATION_DIR}/.reservation.XXXXXX" 2>/dev/null) || return 0
		if printf '%s' "$record_json" | jq -c --argjson now "$now_epoch" '.superseded_at = $now' >"$temp_path" 2>/dev/null &&
			chmod 0600 "$temp_path" && mv -f "$temp_path" "$record_path"; then
			_footprint_reservation_log "event=superseded issue=#${record_issue} reason=lifecycle_labels_visible"
		else
			rm -f "$temp_path" 2>/dev/null || true
		fi
		return 0
	fi
	if [[ $((now_epoch - superseded_at)) -gt "$_FOOTPRINT_RESERVATION_SUPERSEDE_GRACE_SECONDS" ]]; then
		rm -f "$record_path" 2>/dev/null || true
		_footprint_reservation_log "event=retired issue=#${record_issue} reason=superseded_grace_elapsed"
	fi
	return 0
}

# Atomically write this candidate's reservation. Call with the repo lock held.
_footprint_reservation_write() {
	local repo_slug="$1"
	local repo_key="$2"
	local issue_number="$3"
	local candidate_files="$4"
	local now_epoch="" expires_at="" record_json="" record_path="" temp_path=""
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	now_epoch=$(date +%s)
	expires_at=$((now_epoch + _FOOTPRINT_RESERVATION_TTL_SECONDS))
	record_json=$(printf '%s\n' "$candidate_files" | jq -Rsc \
		--arg schema "$_FOOTPRINT_RESERVATION_SCHEMA" --arg repo "$repo_slug" \
		--argjson issue "$issue_number" --argjson created_at "$now_epoch" --argjson expires_at "$expires_at" \
		'{schema:$schema,repo_slug:$repo,issue:$issue,paths:(split("\n") | map(select(length > 0))),created_at:$created_at,expires_at:$expires_at}') || return 1
	record_path="${_FOOTPRINT_RESERVATION_DIR}/${repo_key}-${issue_number}.json"
	temp_path=$(mktemp "${_FOOTPRINT_RESERVATION_DIR}/.reservation.XXXXXX" 2>/dev/null) || return 1
	if ! printf '%s\n' "$record_json" >"$temp_path" || ! chmod 0600 "$temp_path" || ! mv -f "$temp_path" "$record_path"; then
		rm -f "$temp_path" 2>/dev/null || true
		return 1
	fi
	_footprint_reservation_log "event=reserved issue=#${issue_number} repo=${repo_slug} expires_at=${expires_at}"
	return 0
}

#######################################
# Release a candidate's reservation after a failed or aborted launch. With a
# since-epoch, only a reservation created by this attempt (at or after it) is
# removed, so an earlier live launch keeps its reservation.
# Args: $1 = repo slug, $2 = issue number, $3 = since epoch (optional)
# Exit: always 0
#######################################
footprint_release_reservation() {
	local repo_slug="$1"
	local issue_number="$2"
	local since_epoch="${3:-0}"
	local repo_key="" record_path="" created_at=""
	[[ -n "$repo_slug" && "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ "$since_epoch" =~ ^[0-9]+$ ]] || since_epoch=0
	repo_key=$(_footprint_reservation_repo_key "$repo_slug") || return 0
	record_path="${_FOOTPRINT_RESERVATION_DIR}/${repo_key}-${issue_number}.json"
	[[ -f "$record_path" && ! -L "$record_path" ]] || return 0
	created_at=$(jq -r '.created_at // 0' "$record_path" 2>/dev/null) || created_at=0
	[[ "$created_at" =~ ^[0-9]+$ ]] || created_at=0
	[[ "$created_at" -ge "$since_epoch" ]] || return 0
	rm -f "$record_path" 2>/dev/null || true
	_footprint_reservation_log "event=released issue=#${issue_number} repo=${repo_slug}"
	return 0
}

#######################################
# Read a repo's opt-in low-information basenames from repos.json.
# Args: $1 = repo slug (owner/repo)
# Output: space-separated basenames (empty when unset/unavailable)
#######################################
_footprint_repo_low_info_basenames() {
	local repo_slug="$1"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	[[ -n "$repo_slug" && -f "$repos_json" ]] || return 0
	jq -r --arg slug "$repo_slug" '
		first(.initialized_repos[]? | select(.slug == $slug))
		| (.footprint_low_info_paths // [])
		| if type == "array" then .[] else empty end
		| select(type == "string" and length > 0 and (test("[[:space:]]") | not))
	' "$repos_json" 2>/dev/null | tr '\n' ' ' || true
	return 0
}

#######################################
# Release/version/changelog files alone are low-information overlap.
# Matching is by basename and case-insensitive (Bash 3.2 safe).
# Args: $1 = path, $2 = optional extra space-separated basenames
# Exit: 0 low-information, 1 implementation file
#######################################
_footprint_is_low_information_path() {
	local path="$1"
	local extra_names="${2:-}"
	local base="" name=""
	base=$(printf '%s' "${path##*/}" | tr '[:upper:]' '[:lower:]')
	local all_names=""
	all_names=$(printf '%s %s' "$_FOOTPRINT_LOW_INFO_BASENAMES" "$extra_names" | tr '[:upper:]' '[:lower:]')
	for name in $all_names; do
		[[ "$base" == "$name" ]] && return 0
	done
	return 1
}

#######################################
# Find the blocking overlap between a candidate footprint and in-flight or
# reserved footprints. Shared low-information (release/version) files are
# ignored; any shared implementation file blocks.
# Args: $1 = candidate files (newline list), $2 = "path|issue" lines,
#       $3 = optional extra low-information basenames (per-repo opt-in)
# Output: "<blocking_issue><TAB><overlapping files>"
# Exit: 0 overlap found, 1 none
#######################################
_footprint_find_overlap() {
	local candidate_files="$1"
	local inflight_data="$2"
	local extra_low_info="${3:-}"
	local candidate_file="" norm_candidate="" inflight_entry="" inflight_file="" inflight_issue="" norm_inflight=""
	local overlapping_files="" blocking_issue=""
	[[ -n "$candidate_files" && -n "$inflight_data" ]] || return 1
	while IFS= read -r candidate_file; do
		[[ -n "$candidate_file" ]] || continue
		_footprint_is_low_information_path "$candidate_file" "$extra_low_info" && continue
		# Normalise: strip leading ./ or .agents/ for comparison
		norm_candidate=$(printf '%s' "$candidate_file" | sed 's|^\./||' | sed 's|^\.agents/||')
		while IFS= read -r inflight_entry; do
			[[ -n "$inflight_entry" ]] || continue
			inflight_file="${inflight_entry%|*}"
			inflight_issue="${inflight_entry##*|}"
			norm_inflight=$(printf '%s' "$inflight_file" | sed 's|^\./||' | sed 's|^\.agents/||')
			if [[ "$norm_candidate" == "$norm_inflight" ]]; then
				overlapping_files="${overlapping_files}${candidate_file}, "
				blocking_issue="$inflight_issue"
				break
			fi
		done <<<"$inflight_data"
	done <<<"$candidate_files"
	[[ -n "$overlapping_files" && -n "$blocking_issue" ]] || return 1
	printf '%s\t%s\n' "$blocking_issue" "${overlapping_files%, }"
	return 0
}

#######################################
# Extract file paths from an issue body.
#
# Parses explicit edit declarations from the brief template's "Files to Modify" section:
#   - `EDIT: path/to/file.sh:45-60` — existing file edit
#   - `NEW: path/to/file.sh` — new file creation
#   - Plain paths after "File:" prefix
# Context-only list items and "Relevant files" references are intentionally
# ignored because they do not declare implementation ownership.
#
# Strips line-number qualifiers (`:NNN` or `:START-END`) since we only care
# about file-level overlap, not line-level.
#
# Args:
#   $1 = issue body text
# Output: one file path per line (sorted, unique, no line qualifiers)
# Exit: always 0
#######################################
_footprint_extract_paths() {
	local issue_body="$1"
	[[ -n "$issue_body" ]] || return 0

	# EDIT:/NEW:/File: prefixed paths (brief template format). Keep this
	# intent-aware: backticked paths on ordinary list items are often reference
	# context and must not create false dispatch-overlap deferrals (GH#27787).
	# File requires its explicit colon so prose such as "File refs verified"
	# cannot become a synthetic path claim (GH#28861).
	local prefixed
	# shellcheck disable=SC2016 # Backticks are literal regex characters, not shell expansion.
	prefixed=$(printf '%s' "$issue_body" | grep -oE '((EDIT|NEW):?|File:)[[:space:]]+[`"]?[^`"[:space:],]+' 2>/dev/null |
		sed -E 's/^((EDIT|NEW):?|File:)[[:space:]]*//' | sed 's/^[`"]//' | sed 's/[`"]*$//' | sort -u) || prefixed=""

	# GH#32977: a canonical `## Files Scope` / `### Files Scope` section is an
	# explicit ownership declaration (see pre-dispatch-validator-lib-brief-scope.sh),
	# so its bare list items count too. Paths elsewhere stay context-only.
	local scoped=""
	scoped=$(_footprint_extract_files_scope_paths "$issue_body")

	# Strip line-number qualifiers — we only care about file-level overlap
	# Handles: file.sh:45, file.sh:45-60, file.sh:1477
	printf '%s\n%s' "$prefixed" "$scoped" | sed 's/:[0-9]*\(-[0-9]*\)*$//' | sort -u | grep -v '^$' || true
	return 0
}

#######################################
# Print the first path token of each list item inside a canonical Files Scope
# section. Tokens must look like repo-relative file paths (contain "/" or ".").
# Args: $1 = issue body
# Output: one path per line (may include line qualifiers)
#######################################
_footprint_extract_files_scope_paths() {
	local issue_body="$1"
	# shellcheck disable=SC2016 # Backticks are literal awk regex characters.
	printf '%s\n' "$issue_body" | tr -d '\r' | awk '
		/^## Files Scope[[:space:]]*$/ { found = 1; level = 2; next }
		/^### Files Scope[[:space:]]*$/ { found = 1; level = 3; next }
		found && level == 2 && (/^# / || /^## /) { found = 0 }
		found && level == 3 && (/^# / || /^## / || /^### /) { found = 0 }
		found && /^[[:space:]]*[-*][[:space:]]+/ {
			line = $0
			sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)
			sub(/^`?(EDIT|NEW):?[[:space:]]*/, "", line)
			quoted = (line ~ /^`/)
			gsub(/`/, "", line)
			split(line, parts, /[[:space:]]+/)
			token = parts[1]
			if (token ~ /^[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)*(:[0-9]+(-[0-9]+)?)?$/ && (quoted || token ~ /[.\/]/)) print token
		}
	'
	return 0
}

#######################################
# Fetch open issues carrying any active dispatch status label, merged and
# deduplicated by number. t3043: the per-label gh calls run concurrently via
# temp files and background jobs (max(5-15s) instead of their serial sum).
#
# Args: $1 = repo_slug (owner/repo)
# Output: JSON array of {number, body, labels}; "[]" on failure
# Exit: always 0
#######################################
_footprint_fetch_active_issues() {
	local repo_slug="$1"
	local labels=("status:queued" "status:in-progress" "status:in-review" "status:claimed")
	local tmpdir="" label="" idx=0 pids=() merged=""
	tmpdir=$(mktemp -d 2>/dev/null) || tmpdir="/tmp/fp-$$"
	mkdir -p "$tmpdir" 2>/dev/null || true

	for label in "${labels[@]}"; do
		(gh issue list --repo "$repo_slug" --label "$label" --state open \
			--json number,body,labels --limit 50 2>/dev/null || echo "[]") >"${tmpdir}/${idx}.json" &
		pids+=("$!")
		idx=$((idx + 1))
	done
	local pid=""
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	idx=0
	for label in "${labels[@]}"; do
		merged="${merged}$(cat "${tmpdir}/${idx}.json" 2>/dev/null || echo "[]")"$'\n'
		idx=$((idx + 1))
	done
	rm -rf "$tmpdir" 2>/dev/null || true

	printf '%s' "$merged" | jq -s 'map(select(type == "array")) | add // [] | unique_by(.number)' 2>/dev/null || printf '[]\n'
	return 0
}

#######################################
# Log a footprint-coordinator decision to LOGFILE, when set (best-effort).
# Args: $1 = message
#######################################
_footprint_coordinator_log() {
	local message="$1"
	[[ -n "${LOGFILE:-}" ]] || return 0
	printf '[footprint-coordinator] %s ts=%s\n' "$message" "$(date +%s)" >>"$LOGFILE" 2>/dev/null || true
	return 0
}

#######################################
# GH#33293: determine whether a claimed `no-auto-dispatch` coordination
# issue has evidence of active implementation. Without evidence, such an
# issue is a coordination container — like `parent-task` — and must not
# reserve its declared Files Scope indefinitely just because a maintainer
# left it claimed.
#
# Evidence (any one is sufficient to keep the footprint reserved):
#   1. A dispatch-ledger entry for this issue (session_key "issue-<N>")
#      that is still in-flight/launched — a worker or interactive session
#      is actually registered against it.
#   2. An open PR that either closes this issue (standard closing
#      keywords) or whose branch name encodes the issue number, matching
#      the aidevops worktree-branch convention (".../auto-...-gh<N>").
#
# Args: $1 = repo_slug, $2 = issue_number
# Exit: 0 = evidence found (keep reserving); 1 = no evidence (skip, like
#       parent-task) or invalid args (fail safe to "no evidence").
#######################################
_footprint_claimed_coordinator_has_evidence() {
	local repo_slug="$1"
	local issue_number="$2"
	[[ -n "$repo_slug" && "$issue_number" =~ ^[0-9]+$ ]] || return 1

	# Evidence 1 — dispatch ledger entry still in-flight for this issue.
	local ledger_file="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-ledger.jsonl"
	if [[ -f "$ledger_file" && ! -L "$ledger_file" ]]; then
		local ledger_hit=""
		ledger_hit=$(jq -r --arg key "issue-${issue_number}" \
			'select(.session_key == $key and (.status == "in-flight" or .status == "launched")) | .session_key' \
			"$ledger_file" 2>/dev/null | head -1) || ledger_hit=""
		[[ -n "$ledger_hit" ]] && return 0
	fi

	# Evidence 2 — an open PR linked to the issue (closing keyword in its
	# body) or a branch whose name encodes the issue number.
	local prs="" pr_hit="0"
	prs=$(gh pr list --repo "$repo_slug" --state open \
		--json number,headRefName,body --limit 100 2>/dev/null) || prs=""
	[[ -n "$prs" ]] || prs="[]"
	pr_hit=$(printf '%s' "$prs" | jq -r --arg n "$issue_number" '
		[.[] | select(
			((.headRefName // "") | test("gh" + $n + "([^0-9]|$)")) or
			((.body // "") | test("(close[sd]?|fix(e[sd])?|resolve[sd]?)[ \t]*#" + $n + "([^0-9]|$)"; "i"))
		)] | length' 2>/dev/null) || pr_hit="0"
	[[ "$pr_hit" =~ ^[1-9][0-9]*$ ]] && return 0

	return 1
}

#######################################
# Get file footprints for all currently in-flight issues in a repo.
#
# "In-flight" = issue has an active status label (status:queued,
# status:in-progress, status:in-review, status:claimed). status:queued is set
# by the dispatcher when it assigns a worker that is about to launch
# (GH#32977), so it is owned work even before the worker registers.
# Parent-task issues are coordination containers, not worker
# implementation claims, so their broad planning footprints do not block
# worker-ready child dispatch. GH#33293: a claimed `no-auto-dispatch`
# coordination issue is skipped the same way unless it carries evidence of
# active implementation (see _footprint_claimed_coordinator_has_evidence).
#
# Returns a newline-separated list of "file|issue_number" pairs.
# Uses a TTL-based cache to avoid repeated API calls within a pulse cycle.
#
# Args:
#   $1 = repo_slug (owner/repo)
#   $2 = (optional) issue to exclude from results (the candidate itself)
# Output: "file_path|issue_number" pairs, one per line
# Exit: always 0
#######################################
_footprint_refresh_inflight_cache() {
	local repo_slug="$1"

	local now_epoch
	now_epoch=$(date +%s)

	# Check cache validity
	if [[ "$_FOOTPRINT_CACHE_REPO" == "$repo_slug" ]] &&
		[[ "$_FOOTPRINT_CACHE_EPOCH" -gt 0 ]] &&
		[[ $((now_epoch - _FOOTPRINT_CACHE_EPOCH)) -lt $_FOOTPRINT_CACHE_TTL ]]; then
		return 0
	fi

	# Cache miss — rebuild.
	local all_inflight
	all_inflight=$(_footprint_fetch_active_issues "$repo_slug")

	local issue_count
	issue_count=$(printf '%s' "$all_inflight" | jq 'length' 2>/dev/null) || issue_count=0
	[[ "$issue_count" =~ ^[0-9]+$ ]] || issue_count=0

	local cache_data=""
	local i=0
	while [[ "$i" -lt "$issue_count" ]]; do
		local num body is_parent_task is_no_auto_dispatch is_claimed paths
		num=$(printf '%s' "$all_inflight" | jq -r ".[$i].number // empty" 2>/dev/null)
		body=$(printf '%s' "$all_inflight" | jq -r ".[$i].body // empty" 2>/dev/null)
		is_parent_task=$(printf '%s' "$all_inflight" | jq -r ".[$i] | any((.labels // [])[]?; .name == \"parent-task\")" 2>/dev/null) || is_parent_task="false"
		if [[ "$is_parent_task" == "true" ]]; then
			i=$((i + 1))
			continue
		fi

		# GH#33293: a claimed no-auto-dispatch coordination issue only
		# holds its footprint when there is evidence of active
		# implementation; otherwise it is skipped like parent-task.
		is_no_auto_dispatch=$(printf '%s' "$all_inflight" | jq -r ".[$i] | any((.labels // [])[]?; .name == \"no-auto-dispatch\")" 2>/dev/null) || is_no_auto_dispatch="false"
		is_claimed=$(printf '%s' "$all_inflight" | jq -r ".[$i] | any((.labels // [])[]?; .name == \"status:claimed\")" 2>/dev/null) || is_claimed="false"
		if [[ "$is_no_auto_dispatch" == "true" && "$is_claimed" == "true" ]] &&
			[[ -n "$num" ]] && ! _footprint_claimed_coordinator_has_evidence "$repo_slug" "$num"; then
			_footprint_coordinator_log "event=footprint_stale_coordinator issue=#${num} repo=${repo_slug}"
			i=$((i + 1))
			continue
		fi

		if [[ -n "$num" && -n "$body" ]]; then
			paths=$(_footprint_extract_paths "$body")
			if [[ -n "$paths" ]]; then
				while IFS= read -r p; do
					[[ -n "$p" ]] || continue
					cache_data="${cache_data}${p}|${num}\n"
				done <<<"$paths"
			fi
		fi
		i=$((i + 1))
	done

	# Store in cache
	_FOOTPRINT_CACHE_REPO="$repo_slug"
	_FOOTPRINT_CACHE_DATA="$cache_data"
	_FOOTPRINT_CACHE_EPOCH="$now_epoch"
	return 0
}

# Optional output variable lets dispatch retain the repo cache in its shell.
# Legacy stdout callers remain supported, but command substitution cannot
# preserve cache writes, even when nested inside another helper.
_footprint_get_inflight() {
	local repo_slug="$1" exclude_issue="${2:-}" result_var="${3:-}"
	_footprint_refresh_inflight_cache "$repo_slug"
	local filtered_data=""
	if [[ -n "$exclude_issue" ]]; then
		filtered_data=$(printf '%b' "$_FOOTPRINT_CACHE_DATA" | grep -v "|${exclude_issue}$" | grep -v '^$' || true)
	else
		filtered_data=$(printf '%b' "$_FOOTPRINT_CACHE_DATA" | grep -v '^$' || true)
	fi
	if [[ -n "$result_var" ]]; then
		printf -v "$result_var" '%s' "$filtered_data"
	else
		printf '%s\n' "$filtered_data"
	fi
	return 0
}

# Keep the stdout interface for existing callers and offer an in-process result.
_footprint_emit_overlap() {
	local signal="$1" result_var="${2:-}"
	if [[ -n "$result_var" ]]; then
		printf -v "$result_var" '%s' "$signal"
	else
		printf '%s\n' "$signal"
	fi
	return 0
}

#######################################
# Check if a candidate issue's file footprint overlaps with any in-flight issue.
#
# This is the main entry point called from _dispatch_dedup_check_layers.
#
# Args:
#   $1 = issue_number (candidate being considered for dispatch)
#   $2 = repo_slug (owner/repo)
#   $3 = issue_body (body text of the candidate issue)
# Output: on overlap, prints "FOOTPRINT_OVERLAP (issue=#<blocking> files=<list>)"
# Side effect: when no overlap is found, reserves the candidate's footprint
# for the rest of this refill window (GH#32977); callers release it with
# footprint_release_reservation when the launch does not happen.
# Exit:
#   0 = overlap found (do NOT dispatch — defer one cycle)
#   1 = no overlap (safe to dispatch)
#######################################
_footprint_check_overlap() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body="$3"
	local overlap_result_var="${4:-}"
	[[ -z "$overlap_result_var" ]] || printf -v "$overlap_result_var" '%s' ''

	[[ -n "$issue_body" ]] || return 1

	# Extract candidate's file footprint
	local candidate_files
	candidate_files=$(_footprint_extract_paths "$issue_body")
	[[ -n "$candidate_files" ]] || return 1

	# Get in-flight footprints (excluding self). Network reads stay outside the
	# reservation lock; reservations are written before the launch labels, so
	# anything this read misses is visible as a reservation under the lock.
	local inflight_data="" repo_key="" lock_dir="" live_issues="" reserved_data=""
	_footprint_get_inflight "$repo_slug" "$issue_number" inflight_data
	if repo_key=$(_footprint_reservation_repo_key "$repo_slug") && _footprint_reservation_prepare_dir; then
		if ! lock_dir=$(_footprint_reservation_lock "$repo_key"); then
			_footprint_reservation_log "event=lock_busy issue=#${issue_number} repo=${repo_slug}"
			_footprint_emit_overlap 'FOOTPRINT_OVERLAP (reservation_lock_busy; retry next cycle)' "$overlap_result_var"
			return 0
		fi
		live_issues=$(printf '%s\n' "$inflight_data" | awk -F '|' 'NF > 1 { print $NF }' | sort -u)
		reserved_data=$(_footprint_reservation_entries "$repo_key" "$issue_number" "$live_issues")
		if [[ -n "$reserved_data" ]]; then
			inflight_data=$(printf '%s\n%s\n' "$inflight_data" "$reserved_data" | grep -v '^$' || true)
		fi
	else
		_footprint_reservation_log "event=store_unavailable issue=#${issue_number} repo=${repo_slug} fallback=live_only"
	fi

	local overlap="" blocking_issue="" overlapping_files="" repo_low_info=""
	repo_low_info=$(_footprint_repo_low_info_basenames "$repo_slug")
	if overlap=$(_footprint_find_overlap "$candidate_files" "$inflight_data" "$repo_low_info"); then
		[[ -z "$lock_dir" ]] || rm -rf "$lock_dir" 2>/dev/null || true
		blocking_issue="${overlap%%$'\t'*}"
		overlapping_files="${overlap#*$'\t'}"
		_footprint_defer_record_overlap "$issue_number" "$repo_slug" "$candidate_files" \
			"$inflight_data" "$blocking_issue" "$overlapping_files"
		_footprint_emit_overlap "FOOTPRINT_OVERLAP (issue=#${blocking_issue} files=${overlapping_files})" "$overlap_result_var"
		return 0
	fi

	if [[ -n "$lock_dir" ]]; then
		_footprint_reservation_write "$repo_slug" "$repo_key" "$issue_number" "$candidate_files" ||
			_footprint_reservation_log "event=reserve_failed issue=#${issue_number} repo=${repo_slug}"
		rm -rf "$lock_dir" 2>/dev/null || true
	fi
	return 1
}

#######################################
# Evict all cache entries for a specific issue number.
#
# Called after an issue closes (PR merge, worktree cleanup, stale reset,
# claim release) so the next _footprint_check_overlap call does not
# produce a stale FOOTPRINT_OVERLAP defer against the already-closed
# issue. This provides immediate eviction on known-close events;
# _FOOTPRINT_CACHE_TTL bounds the maximum stale window for untracked
# closes. (t2927/GH#21103)
#
# Safe to call when the cache is empty or the issue is not in the cache —
# both are no-ops. Safe to call when dispatch-dedup-footprint.sh is not
# sourced — callers guard with `declare -F ... && ...`.
#
# Args:
#   $1 = issue_num (number of the issue to evict)
# Exit: always 0
#######################################
invalidate_footprint_cache_for_issue() {
	local issue_num="$1"
	[[ -n "$issue_num" ]] || return 0

	# Rebuild cache without entries for this issue.
	# Cache stores "file_path|issue_num\n" (literal \n separators).
	# printf '%b' expands \n to actual newlines for line-by-line filtering.
	local _new_cache_data=""
	local _cache_entry _cache_issue
	if [[ -n "$_FOOTPRINT_CACHE_DATA" ]]; then
		while IFS= read -r _cache_entry; do
			[[ -n "$_cache_entry" ]] || continue
			_cache_issue="${_cache_entry##*|}"
			[[ "$_cache_issue" == "$issue_num" ]] && continue
			_new_cache_data="${_new_cache_data}${_cache_entry}\n"
		done <<<"$(printf '%b' "$_FOOTPRINT_CACHE_DATA")"
		_FOOTPRINT_CACHE_DATA="$_new_cache_data"
	fi

	# Wake any durable record where this issue is either candidate or blocker.
	# The caller does not always know the repository, so conservatively scan the
	# private bounded state directory; issue-number collisions only cause a safe
	# extra live overlap check.
	local state_path=""
	local state_json=""
	local candidate_issue=""
	local blocking_issue=""
	if [[ -d "$_FOOTPRINT_DEFER_STATE_DIR" && ! -L "$_FOOTPRINT_DEFER_STATE_DIR" ]]; then
		for state_path in "$_FOOTPRINT_DEFER_STATE_DIR"/*.json; do
			[[ -f "$state_path" && ! -L "$state_path" ]] || continue
			state_json=$(_footprint_defer_read_json "$state_path") || continue
			printf '%s' "$state_json" | jq -e '.active == true' >/dev/null 2>&1 || continue
			candidate_issue=$(printf '%s' "$state_json" | jq -r '.candidate_issue')
			blocking_issue=$(printf '%s' "$state_json" | jq -r '.blocking_issue')
			if [[ "$candidate_issue" == "$issue_num" || "$blocking_issue" == "$issue_num" ]]; then
				_footprint_defer_wake "$state_path" "$state_json" "lifecycle_invalidation" || true
			fi
		done
	fi
	return 0
}
