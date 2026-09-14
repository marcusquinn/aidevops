#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Fail-closed quarantine state for worktrees whose process-CWD visibility is
# degraded. This module is sourced by pulse-cleanup.sh.

[[ -n "${_PULSE_CLEANUP_DEGRADED_ORPHANS_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_DEGRADED_ORPHANS_LOADED=1
_PCDO_STATE_SCHEMA="aidevops-degraded-cwd-quarantine/v1"
_PCDO_REASON_QUARANTINED="degraded-cwd-in-place-quarantine"
_PCDO_MODE_QUARANTINED="in-place-quarantine"
_PCDO_JSON_NUMBER_TYPE="number"
_PCDO_RETRY_AFTER=0
_PCDO_RETRY_ATTEMPT=0

_pcdo_quarantine_state_dir() {
	printf '%s/degraded-worktree-quarantine\n' \
		"${PULSE_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse}"
	return 0
}

_pcdo_path_digest() {
	local wt_path="$1"
	local digest=""
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$wt_path" | sha256sum | awk '{print $1}') || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$wt_path" | shasum -a 256 | awk '{print $1}') || return 1
	else
		return 1
	fi
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

_pcdo_quarantine_state_path() {
	local wt_path="$1"
	local digest=""
	digest=$(_pcdo_path_digest "$wt_path") || return 1
	printf '%s/%s.json\n' "$(_pcdo_quarantine_state_dir)" "$digest"
	return 0
}

_pcdo_retry_initial_seconds() {
	local seconds="${AIDEVOPS_DEGRADED_CWD_RETRY_INITIAL_SECONDS:-900}"
	if [[ ! "$seconds" =~ ^[0-9]+$ || "$seconds" -lt 1 || "$seconds" -gt 86400 ]]; then
		seconds=900
	fi
	printf '%s\n' "$seconds"
	return 0
}

_pcdo_retry_max_seconds() {
	local initial="$1"
	local seconds="${AIDEVOPS_DEGRADED_CWD_RETRY_MAX_SECONDS:-21600}"
	if [[ ! "$seconds" =~ ^[0-9]+$ || "$seconds" -lt "$initial" || "$seconds" -gt 604800 ]]; then
		seconds=21600
	fi
	[[ "$seconds" -ge "$initial" ]] || seconds="$initial"
	printf '%s\n' "$seconds"
	return 0
}

_pcdo_retry_delay_seconds() {
	local attempt="$1"
	local delay="$2"
	local maximum="$3"
	local step=1
	while [[ "$step" -lt "$attempt" && "$delay" -lt "$maximum" ]]; do
		if [[ "$delay" -gt $((maximum / 2)) ]]; then
			delay="$maximum"
		else
			delay=$((delay * 2))
		fi
		step=$((step + 1))
	done
	[[ "$delay" -le "$maximum" ]] || delay="$maximum"
	printf '%s\n' "$delay"
	return 0
}

_pcdo_matching_state_json() {
	local state_path="$1"
	local wt_path="$2"
	local wt_branch="$3"
	[[ -f "$state_path" && ! -L "$state_path" ]] || return 1
	jq -ce --arg schema "$_PCDO_STATE_SCHEMA" --arg path "$wt_path" \
		--arg branch "$wt_branch" --arg number_type "$_PCDO_JSON_NUMBER_TYPE" '
		.schema == $schema and .path == $path and .branch == $branch
		and (.attempt | type) == $number_type and .attempt >= 1
		and (.attempt | floor) == .attempt
		and (.observed_at | type) == $number_type and .observed_at >= 0
		and (.observed_at | floor) == .observed_at
		and (.retry_after | type) == $number_type and .retry_after >= .observed_at
		and (.retry_after | floor) == .retry_after
	' "$state_path" >/dev/null 2>&1 || return 1
	jq -c . "$state_path" 2>/dev/null
	return $?
}

# Return 0 when a fresh process scan is due. Return 1 while a valid quarantine
# backoff is active. Stored state can only delay cleanup; it never authorizes it.
_pcdo_degraded_retry_due() {
	local wt_path="$1"
	local wt_branch="$2"
	local now_epoch="$3"
	local state_path=""
	local state_json=""
	_PCDO_RETRY_AFTER=0
	_PCDO_RETRY_ATTEMPT=0
	state_path=$(_pcdo_quarantine_state_path "$wt_path") || return 0
	[[ ! -L "$state_path" ]] || return 1
	state_json=$(_pcdo_matching_state_json "$state_path" "$wt_path" "$wt_branch") || return 0
	_PCDO_RETRY_AFTER=$(jq -r '.retry_after' <<<"$state_json") || return 0
	_PCDO_RETRY_ATTEMPT=$(jq -r '.attempt' <<<"$state_json") || return 0
	[[ "$now_epoch" -ge "$_PCDO_RETRY_AFTER" ]] && return 0
	return 1
}

_pcdo_write_quarantine_state() {
	local wt_path="$1" wt_branch="$2" now_epoch="$3"
	local state_dir="" state_path="" state_json="" temporary=""
	local attempt=1 initial=0 maximum=0 delay=0
	state_dir=$(_pcdo_quarantine_state_dir)
	[[ ! -L "$state_dir" ]] || return 1
	mkdir -p "$state_dir" || return 1
	chmod 700 "$state_dir" || return 1
	state_path=$(_pcdo_quarantine_state_path "$wt_path") || return 1
	if state_json=$(_pcdo_matching_state_json "$state_path" "$wt_path" "$wt_branch"); then
		attempt=$(jq -r '.attempt + 1 | if . > 32 then 32 else . end' <<<"$state_json") || return 1
	fi
	initial=$(_pcdo_retry_initial_seconds)
	maximum=$(_pcdo_retry_max_seconds "$initial")
	delay=$(_pcdo_retry_delay_seconds "$attempt" "$initial" "$maximum")
	_PCDO_RETRY_AFTER=$((now_epoch + delay))
	_PCDO_RETRY_ATTEMPT="$attempt"
	temporary=$(mktemp "${state_path}.XXXXXX") || return 1
	if ! jq -n --arg schema "$_PCDO_STATE_SCHEMA" --arg path "$wt_path" \
		--arg branch "$wt_branch" --argjson attempt "$attempt" \
		--argjson observed_at "$now_epoch" --argjson retry_after "$_PCDO_RETRY_AFTER" \
		'{schema:$schema,path:$path,branch:$branch,attempt:$attempt,
		observed_at:$observed_at,retry_after:$retry_after,visibility:"degraded"}' >"$temporary" ||
		! chmod 600 "$temporary" || ! mv -f "$temporary" "$state_path"; then
		rm -f "$temporary"
		return 1
	fi
	return 0
}

_pcdo_clear_quarantine_state() {
	local wt_path="$1"
	local state_path=""
	state_path=$(_pcdo_quarantine_state_path "$wt_path") || return 0
	[[ ! -L "$state_path" ]] || return 0
	[[ ! -f "$state_path" ]] || rm -f "$state_path"
	return 0
}

_pcdo_log_active_backoff() {
	local wt_path="$1"
	local context="attempt=${_PCDO_RETRY_ATTEMPT} retry_after=${_PCDO_RETRY_AFTER}"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" \
		"degraded-cwd-retry-backoff" "$_PCDO_MODE_QUARANTINED" "$context"
	return 0
}

_pcdo_retry_backoff_allows_scan() {
	local wt_path="$1"
	local wt_branch="$2"
	local now_epoch="$3"
	if _pcdo_degraded_retry_due "$wt_path" "$wt_branch" "$now_epoch"; then
		return 0
	fi
	_pcdo_log_active_backoff "$wt_path"
	return 1
}

_pcdo_quarantine_degraded_worktree() {
	local wt_path="$1"
	local wt_branch="$2"
	local now_epoch="$3"
	local context=""
	if ! _pcdo_write_quarantine_state "$wt_path" "$wt_branch" "$now_epoch"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" \
			"degraded-cwd-quarantine-state-failed" "$_PCDO_MODE_QUARANTINED"
		return 1
	fi
	context="attempt=${_PCDO_RETRY_ATTEMPT} observed_at=${now_epoch} retry_after=${_PCDO_RETRY_AFTER}"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" \
		"$_PCDO_REASON_QUARANTINED" "$_PCDO_MODE_QUARANTINED" "$context"
	return 0
}
