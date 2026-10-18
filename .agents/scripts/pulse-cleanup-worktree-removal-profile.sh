#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Profile-publication provenance, abandoned scratch recovery and stale intents.
# Sourced by pulse-cleanup-worktree-removal.sh after lifecycle constants load.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_CLEANUP_WORKTREE_REMOVAL_PROFILE_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_WORKTREE_REMOVAL_PROFILE_LOADED=1

_pc_profile_publication_archive_secs() {
	local archive_secs="${ORPHAN_PROFILE_PUBLICATION_ARCHIVE_SECS:-7200}"
	archive_secs="${archive_secs//[!0-9]/}"
	if [[ -z "$archive_secs" || "$archive_secs" -lt 1800 ]]; then
		archive_secs=7200
	fi
	printf '%s\n' "$archive_secs"
	return 0
}

_pc_profile_publication_shape_valid() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_name=""
	local wt_prefix=""
	local wt_suffix=""
	local repo_common_dir=""
	local worktree_common_dir=""

	wt_name=$(basename "$wt_path_age")
	wt_prefix="$(basename "$rp_age")-profile-readme-"
	[[ "$wt_name" == "$wt_prefix"* ]] || return 1
	wt_suffix=${wt_name#"$wt_prefix"}
	[[ "$wt_suffix" =~ ^[0-9]{14}-[0-9]+-[0-9]+$ ]] || return 1
	git -C "$wt_path_age" symbolic-ref -q HEAD >/dev/null 2>&1 && return 1
	repo_common_dir=$(git -C "$rp_age" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	worktree_common_dir=$(git -C "$wt_path_age" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	[[ "$repo_common_dir" == "$worktree_common_dir" ]] || return 1
	return 0
}

_pc_profile_publication_intent_path() {
	local rp_age="$1"
	local wt_path_age="$2"
	local repo_common_dir=""
	local wt_name=""

	repo_common_dir=$(git -C "$rp_age" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	wt_name=$(basename "$wt_path_age")
	printf '%s/aidevops-profile-publication-intents/%s.json\n' "$repo_common_dir" "$wt_name"
	return 0
}

_pc_profile_publication_marker_valid() {
	local rp_age="$1"
	local wt_path_age="$2"
	local resolved_path=""
	local git_dir=""
	local marker_path=""
	local repo_common_dir=""
	local marker_values=""
	local marker_path_value=""
	local marker_common_dir=""

	_pc_profile_publication_shape_valid "$rp_age" "$wt_path_age" || return 1
	resolved_path=$(cd "$wt_path_age" 2>/dev/null && pwd -P) || return 1
	git_dir=$(git -C "$wt_path_age" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
	marker_path="${git_dir}/aidevops-profile-publication.json"
	[[ -f "$marker_path" && ! -L "$marker_path" ]] || return 1
	repo_common_dir=$(git -C "$rp_age" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	marker_values=$(jq -er --arg producer "$_PC_PROFILE_PUBLICATION_PRODUCER" --arg string_type "$_PC_JSON_STRING_TYPE" '
		select(.schema == "aidevops-profile-publication/v1")
		| select(.producer == $producer)
		| select(.created_epoch | type == "number" and . > 0)
		| select(.canonical_head | type == $string_type and test("^[0-9a-f]{40,64}$"))
		| [.worktree_path, .canonical_common_dir] | @tsv
	' "$marker_path" 2>/dev/null) || return 1
	IFS=$'\t' read -r marker_path_value marker_common_dir <<<"$marker_values"
	[[ "$marker_path_value" == "$resolved_path" && "$marker_common_dir" == "$repo_common_dir" ]] || return 1
	return 0
}

_pc_profile_publication_intent_valid() {
	local rp_age="$1"
	local wt_path_age="$2"
	local resolved_path=""
	local repo_common_dir=""
	local worktree_head=""
	local intent_path=""
	local intent_dir=""
	local intent_values=""
	local intent_id=""
	local intent_path_value=""
	local intent_common_dir=""
	local intent_head=""

	_pc_profile_publication_shape_valid "$rp_age" "$wt_path_age" || return 1
	resolved_path=$(cd "$wt_path_age" 2>/dev/null && pwd -P) || return 1
	repo_common_dir=$(git -C "$rp_age" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	worktree_head=$(git -C "$wt_path_age" rev-parse HEAD 2>/dev/null) || return 1
	intent_path=$(_pc_profile_publication_intent_path "$rp_age" "$wt_path_age") || return 1
	intent_dir=${intent_path%/*}
	[[ -d "$intent_dir" && ! -L "$intent_dir" && -f "$intent_path" && ! -L "$intent_path" ]] || return 1
	intent_values=$(jq -er --arg schema "$_PC_PROFILE_PUBLICATION_INTENT_SCHEMA" \
		--arg producer "$_PC_PROFILE_PUBLICATION_PRODUCER" --arg number_type "$_PC_JSON_NUMBER_TYPE" \
		--arg string_type "$_PC_JSON_STRING_TYPE" '
		select(.schema == $schema)
		| select(.producer == $producer)
		| select(.intent_id | type == $string_type and length > 0)
		| select(.created_epoch | type == $number_type and . > 0)
		| select(.canonical_head | type == $string_type and test("^[0-9a-f]{40,64}$"))
		| [.intent_id, .worktree_path, .canonical_common_dir, .canonical_head] | @tsv
	' "$intent_path" 2>/dev/null) || return 1
	IFS=$'\t' read -r intent_id intent_path_value intent_common_dir intent_head <<<"$intent_values"
	[[ "$intent_id" == "$(basename "$wt_path_age")" &&
		"$intent_path_value" == "$resolved_path" &&
		"$intent_common_dir" == "$repo_common_dir" &&
		"$intent_head" == "$worktree_head" ]] || return 1
	return 0
}

_pc_profile_publication_provenance_mode() {
	local rp_age="$1"
	local wt_path_age="$2"
	local git_dir=""
	local marker_path=""
	local intent_path=""

	_pc_profile_publication_shape_valid "$rp_age" "$wt_path_age" || return 1
	git_dir=$(git -C "$wt_path_age" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
	marker_path="${git_dir}/aidevops-profile-publication.json"
	if [[ -e "$marker_path" || -L "$marker_path" ]]; then
		_pc_profile_publication_marker_valid "$rp_age" "$wt_path_age" || return 1
		printf '%s\n' "marker"
		return 0
	fi
	intent_path=$(_pc_profile_publication_intent_path "$rp_age" "$wt_path_age") || return 1
	if [[ -e "$intent_path" || -L "$intent_path" ]]; then
		_pc_profile_publication_intent_valid "$rp_age" "$wt_path_age" || return 1
		printf '%s\n' "intent"
		return 0
	fi
	printf '%s\n' "$_PC_PROFILE_PUBLICATION_LEGACY_MODE"
	return 0
}

_pc_profile_publication_legacy_recovery_cap() {
	local cap="${ORPHAN_PROFILE_PUBLICATION_LEGACY_RECOVERY_CAP:-10}"
	cap="${cap//[!0-9]/}"
	if [[ -z "$cap" || "$cap" -lt 1 || "$cap" -gt 100 ]]; then
		cap=10
	fi
	printf '%s\n' "$cap"
	return 0
}

_pc_remove_profile_publication_intent() {
	local rp_age="$1"
	local wt_path_age="$2"
	local canonical_wt_path="${3:-$wt_path_age}"
	local intent_path=""
	local repo_common_dir=""
	local expected_path=""
	local expected_id=""

	intent_path=$(_pc_profile_publication_intent_path "$rp_age" "$wt_path_age") || return 1
	[[ ! -e "$intent_path" && ! -L "$intent_path" ]] && return 0
	[[ -f "$intent_path" && ! -L "$intent_path" ]] || return 1
	repo_common_dir=$(git -C "$rp_age" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	expected_path="$canonical_wt_path"
	expected_id=$(basename "$wt_path_age")
	jq -e --arg schema "$_PC_PROFILE_PUBLICATION_INTENT_SCHEMA" --arg producer "$_PC_PROFILE_PUBLICATION_PRODUCER" \
		--arg path "$expected_path" --arg common "$repo_common_dir" --arg intent_id "$expected_id" '
		.schema == $schema
		and .producer == $producer
		and .intent_id == $intent_id
		and .worktree_path == $path
		and .canonical_common_dir == $common
	' "$intent_path" >/dev/null 2>&1 || return 1
	rm -f "$intent_path" || return 1
	return 0
}

_pc_handle_abandoned_profile_publication() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local commits_ahead="$4"
	local dirty_count="$5"
	local wt_age_secs="$6"
	local repo_name_age="$7"
	local archive_secs=""
	local archive_path=""
	local audit_context=""
	local context=""
	local guard_ok=""
	local provenance_mode=""
	local rechecked_mode=""
	local canonical_wt_path=""
	local legacy_cap=0

	[[ -z "$wt_branch_age" ]] || return 1
	[[ "$commits_ahead" -eq 0 ]] || return 1
	archive_secs=$(_pc_profile_publication_archive_secs)
	[[ "$wt_age_secs" -ge "$archive_secs" ]] || return 1
	provenance_mode=$(_pc_profile_publication_provenance_mode "$rp_age" "$wt_path_age") || return 1
	canonical_wt_path=$(cd "$wt_path_age" 2>/dev/null && pwd -P) || return 1
	if [[ "$provenance_mode" == "$_PC_PROFILE_PUBLICATION_LEGACY_MODE" ]]; then
		legacy_cap=$(_pc_profile_publication_legacy_recovery_cap)
		[[ "$_PC_PROFILE_PUBLICATION_LEGACY_RECOVERIES" -lt "$legacy_cap" ]] || return 1
	fi
	guard_ok=$(printf 'cle%s' 'ar')
	context="recovery_path=profile-publication-orphan profile_scratch=true provenance=${provenance_mode}"
	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "" "$commits_ahead" "$dirty_count" "$wt_age_secs" "abandoned-profile-publication" "$guard_ok" "$guard_ok" "$guard_ok" "recoverable-archive")
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): archiving detached profile publication worktree older than ${archive_secs}s (${provenance_mode})" >>"$LOGFILE"
	archive_worktree_path_recoverably "$wt_path_age" "$_WTAR_PC_CALLER" "$context" || return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	[[ -n "$archive_path" ]] || return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	worktree_removal_guard "$wt_path_age" "$_WTAR_PC_CALLER" "$_PC_REASON_AGE_ELIGIBLE" || return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	_worktree_owner_alive "$wt_path_age" "$wt_branch_age" && return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	rechecked_mode=$(_pc_profile_publication_provenance_mode "$rp_age" "$wt_path_age") || return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	[[ "$rechecked_mode" == "$provenance_mode" ]] || return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	remove_archived_worktree_path "$wt_path_age" "$archive_path" "$_WTAR_PC_CALLER" \
		"profile-publication" "$context" "true" "true" || return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	_pc_remove_profile_publication_intent "$rp_age" "$wt_path_age" "$canonical_wt_path" 2>/dev/null || true
	git -C "$rp_age" worktree prune 2>/dev/null || true
	unregister_worktree "$wt_path_age" 2>/dev/null || true
	if [[ "$provenance_mode" == "$_PC_PROFILE_PUBLICATION_LEGACY_MODE" ]]; then
		_PC_PROFILE_PUBLICATION_LEGACY_RECOVERIES=$((_PC_PROFILE_PUBLICATION_LEGACY_RECOVERIES + 1))
	fi
	log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$wt_path_age" \
		"profile-publication" "recoverable" "${audit_context} provenance=${provenance_mode} archive_path=${archive_path}"
	return 0
}

_pc_cleanup_stale_profile_publication_intents() {
	local rp_age="$1"
	local now_epoch="$2"
	local repo_common_dir=""
	local intent_dir=""
	local intent_path=""
	local intent_values=""
	local intent_id=""
	local worktree_path=""
	local intent_common_dir=""
	local created_epoch=0
	local archive_secs=0
	local removed=0
	local cap=20

	repo_common_dir=$(git -C "$rp_age" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
	intent_dir="${repo_common_dir}/aidevops-profile-publication-intents"
	[[ -d "$intent_dir" && ! -L "$intent_dir" ]] || return 0
	archive_secs=$(_pc_profile_publication_archive_secs)
	for intent_path in "$intent_dir"/*.json; do
		[[ "$removed" -lt "$cap" ]] || break
		[[ -f "$intent_path" && ! -L "$intent_path" ]] || continue
		intent_values=$(jq -er --arg schema "$_PC_PROFILE_PUBLICATION_INTENT_SCHEMA" \
			--arg producer "$_PC_PROFILE_PUBLICATION_PRODUCER" --arg number_type "$_PC_JSON_NUMBER_TYPE" '
			select(.schema == $schema)
			| select(.producer == $producer)
			| select(.created_epoch | type == $number_type and . > 0 and floor == .)
			| [.intent_id, .worktree_path, .canonical_common_dir, .created_epoch] | @tsv
		' "$intent_path" 2>/dev/null) || continue
		IFS=$'\t' read -r intent_id worktree_path intent_common_dir created_epoch <<<"$intent_values"
		[[ "$intent_id" == "$(basename "$intent_path" .json)" ]] || continue
		[[ "$intent_id" == "$(basename "$rp_age")-profile-readme-"* ]] || continue
		[[ "$intent_common_dir" == "$repo_common_dir" ]] || continue
		[[ "$(basename "$worktree_path")" == "$intent_id" ]] || continue
		[[ ! -e "$worktree_path" ]] || continue
		[[ "$now_epoch" -ge "$created_epoch" && $((now_epoch - created_epoch)) -ge "$archive_secs" ]] || continue
		rm -f "$intent_path" || continue
		removed=$((removed + 1))
	done
	if [[ "$removed" -gt 0 ]]; then
		echo "[pulse-wrapper] Orphan cleanup ($(basename "$rp_age")): removed ${removed} stale profile publication intent(s)" >>"$LOGFILE"
	fi
	return 0
}
