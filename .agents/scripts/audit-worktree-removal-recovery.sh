#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worktree Removal Audit -- Recoverable Archive Library
# =============================================================================
# Recovery cache policy, archive metadata/validation, inventory, producer lock
# and recoverable-archive functions split from audit-worktree-removal-helper.sh
# (GH#36924). Behaviour-preserving move; no function bodies changed.
#
# Usage: sourced by audit-worktree-removal-helper.sh (constants defined there).
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AUDIT_WORKTREE_REMOVAL_RECOVERY_LIB_LOADED:-}" ]] && return 0
_AUDIT_WORKTREE_REMOVAL_RECOVERY_LIB_LOADED=1

_worktree_recovery_cache_policy() {
	local mode="$1"
	local source_path="$2"
	local archive_path="${3:-}"
	local git_bin="${4:-git}"
	local helper_dir=""
	local helper_path=""

	command -v python3 >/dev/null 2>&1 || return 2
	helper_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 2
	helper_path="${helper_dir}/worktree-recovery-cache-policy.py"
	[[ -f "$helper_path" && ! -L "$helper_path" ]] || return 2
	python3 "$helper_path" "$mode" "$source_path" "$archive_path" "$git_bin"
	return $?
}

_worktree_prune_regenerable_archive_caches() {
	local source_path="$1"
	local archive_path="$2"
	local git_bin="$3"

	_worktree_recovery_cache_policy "prune" "$source_path" "$archive_path" "$git_bin"
	return $?
}

_worktree_recovery_status_has_user_data() {
	local status_path="$1"
	local archive_path="$2"

	_worktree_recovery_cache_policy "status" "$status_path" "$archive_path"
	return $?
}

# Copy exactly once into a unique destination. In particular, do not retry into
# a partially populated directory: cp changes semantics when the destination
# already exists, which could make a partial archive look complete.
_worktree_copy_directory_once() {
	local source_path="$1"
	local destination_path="$2"
	local platform=""

	[[ -d "$source_path" && ! -e "$destination_path" && ! -L "$destination_path" ]] || return 1
	platform=$(uname -s 2>/dev/null) || return 1
	case "$platform" in
	Darwin) cp -ac "$source_path" "$destination_path" 2>/dev/null || return 1 ;;
	Linux) cp -a --reflink=auto "$source_path" "$destination_path" 2>/dev/null || return 1 ;;
	*) cp -Rp "$source_path" "$destination_path" 2>/dev/null || return 1 ;;
	esac
	return 0
}

_worktree_capture_git_identity() {
	local wt_path="$1"
	local candidate_root=""
	local branch_status=0

	_WT_ID_REAL_GIT=""
	_WT_ID_SOURCE_REAL=""
	_WT_ID_SOURCE_INODE=""
	_WT_ID_ADMIN_REAL=""
	_WT_ID_ADMIN_INODE=""
	_WT_ID_COMMON_REAL=""
	_WT_ID_HEAD=""
	_WT_ID_BRANCH=""
	[[ -d "$wt_path" && ! -L "$wt_path" ]] || return 1
	_WT_ID_SOURCE_REAL=$(cd "$wt_path" 2>/dev/null && pwd -P) || return 1
	_WT_ID_SOURCE_INODE=$(_worktree_path_identity "$wt_path") || return 1
	_WT_ID_REAL_GIT=$(_worktree_cleanup_real_git) || return 1
	candidate_root=$("$_WT_ID_REAL_GIT" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || return 1
	candidate_root=$(cd "$candidate_root" 2>/dev/null && pwd -P) || return 1
	[[ "$candidate_root" == "$_WT_ID_SOURCE_REAL" ]] || return 1
	_WT_ID_ADMIN_REAL=$("$_WT_ID_REAL_GIT" -C "$wt_path" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	_WT_ID_ADMIN_REAL=$(cd "$_WT_ID_ADMIN_REAL" 2>/dev/null && pwd -P) || return 1
	_WT_ID_ADMIN_INODE=$(_worktree_path_identity "$_WT_ID_ADMIN_REAL") || return 1
	_WT_ID_COMMON_REAL=$(_worktree_git_common_dir "$_WT_ID_REAL_GIT" "$wt_path") || return 1
	_WT_ID_HEAD=$("$_WT_ID_REAL_GIT" -C "$wt_path" rev-parse --verify HEAD 2>/dev/null) || return 1
	_worktree_git_head_payload_is_valid "$_WT_ID_HEAD" || return 1
	if _WT_ID_BRANCH=$("$_WT_ID_REAL_GIT" -C "$wt_path" symbolic-ref -q HEAD 2>/dev/null); then
		_worktree_git_branch_payload_is_valid "$_WT_ID_BRANCH" || return 1
	else
		branch_status=$?
		[[ "$branch_status" -eq 1 ]] || return 1
		_WT_ID_BRANCH="$_WT_RECOVERY_BRANCH_DETACHED"
	fi
	case "$_WT_ID_SOURCE_REAL$_WT_ID_ADMIN_REAL$_WT_ID_COMMON_REAL" in
	*$'\n'*) return 1 ;;
	esac
	return 0
}

_worktree_recovery_dir_for_archive() {
	local archive_path="$1"
	local archive_parent="${archive_path%/*}"

	[[ -n "$archive_path" && "$archive_parent" != "$archive_path" ]] || return 1
	printf '%s/%s\n' "$archive_parent" "$_WT_RECOVERY_DIR_NAME"
	return 0
}

# Dispatch only; the producer command validates the private receipt and artifact.
# A legacy worktree may itself contain an application manifest.json.
_worktree_recovery_is_compact() {
	local archive_path="$1"
	[[ -f "$archive_path/manifest.json" && ! -e "$archive_path/.git" && ! -L "$archive_path/.git" ]] || return 1
	return 0
}

_worktree_recovery_producer_command() {
	local deadline_epoch="$1"
	shift
	_worktree_recovery_run_before_epoch "$deadline_epoch" \
		python3 "${BASH_SOURCE[0]%/*}/worktree_recovery_producer.py" "$@" || return $?
	return 0
}

_worktree_recovery_format_is_supported() {
	local format="$1"
	case "$format" in
	"$_WT_RECOVERY_FORMAT_V1" | "$_WT_RECOVERY_FORMAT_V2") return 0 ;;
	esac
	return 1
}

_worktree_recovery_line_payload_is_valid() {
	local payload="$1"
	[[ -n "$payload" ]] || return 1
	case "$payload" in
	*$'\n'* | *$'\r'*) return 1 ;;
	esac
	return 0
}

_worktree_recovery_v2_contract_is_valid() {
	local recovery_dir="$1"
	local created_at=""
	local producer=""
	local producer_context=""
	local session_id=""
	local archive_outcome=""
	local source_outcome=""
	local metadata_name=""

	for metadata_name in created-at producer producer-context session-id archive-outcome source-removal-outcome; do
		[[ -f "$recovery_dir/$metadata_name" && ! -L "$recovery_dir/$metadata_name" ]] || return 1
	done
	IFS= read -r created_at <"$recovery_dir/created-at" || return 1
	IFS= read -r producer <"$recovery_dir/producer" || return 1
	IFS= read -r producer_context <"$recovery_dir/producer-context" || return 1
	IFS= read -r session_id <"$recovery_dir/session-id" || return 1
	IFS= read -r archive_outcome <"$recovery_dir/archive-outcome" || return 1
	IFS= read -r source_outcome <"$recovery_dir/source-removal-outcome" || return 1
	[[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
	_worktree_recovery_line_payload_is_valid "$producer" || return 1
	_worktree_recovery_line_payload_is_valid "$producer_context" || return 1
	[[ "$session_id" == "$_WT_STATE_UNAVAILABLE" || "$session_id" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
	[[ "$archive_outcome" == "$_WT_STATE_COMPLETE" ]] || return 1
	case "$source_outcome" in
	"$_WT_RECOVERY_OUTCOME_PENDING" | "$_WT_RECOVERY_OUTCOME_REMOVED") return 0 ;;
	esac
	return 1
}

_worktree_write_recovery_v2_metadata() {
	local recovery_dir="$1"
	local caller="$2"
	local context="${3:-unspecified}"
	local created_at=""
	local session_id="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-unavailable}}}"

	[[ -n "$context" ]] || context="unspecified"
	created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
	_worktree_recovery_line_payload_is_valid "$caller" || return 1
	_worktree_recovery_line_payload_is_valid "$context" || return 1
	[[ "$session_id" == "$_WT_STATE_UNAVAILABLE" || "$session_id" =~ ^[A-Za-z0-9._:-]+$ ]] || session_id="$_WT_STATE_UNAVAILABLE"
	printf '%s\n' "$created_at" >"${recovery_dir}/created-at" || return 1
	printf '%s\n' "$caller" >"${recovery_dir}/producer" || return 1
	printf '%s\n' "$context" >"${recovery_dir}/producer-context" || return 1
	printf '%s\n' "$session_id" >"${recovery_dir}/session-id" || return 1
	printf '%s\n' "$_WT_STATE_COMPLETE" >"${recovery_dir}/archive-outcome" || return 1
	printf '%s\n' "$_WT_RECOVERY_OUTCOME_PENDING" >"${recovery_dir}/source-removal-outcome" || return 1
	return 0
}

_worktree_recovery_record_source_outcome() {
	local archive_path="$1"
	local outcome="$2"
	local recovery_dir=""
	local format=""
	local outcome_tmp=""

	case "$outcome" in
	"$_WT_RECOVERY_OUTCOME_PENDING" | "$_WT_RECOVERY_OUTCOME_REMOVED") ;;
	*) return 1 ;;
	esac
	if _worktree_recovery_is_compact "$archive_path"; then
		[[ "$outcome" == "$_WT_RECOVERY_OUTCOME_REMOVED" ]] || return 1
		_worktree_recovery_producer_command 0 removed "$archive_path" || return 1
		return 0
	fi
	recovery_dir=$(_worktree_recovery_dir_for_archive "$archive_path") || return 1
	IFS= read -r format <"$recovery_dir/format" || return 1
	[[ "$format" == "$_WT_RECOVERY_FORMAT_V2" ]] || return 0
	outcome_tmp="${recovery_dir}/.source-removal-outcome.$$-${RANDOM}"
	printf '%s\n' "$outcome" >"$outcome_tmp" || return 1
	mv "$outcome_tmp" "$recovery_dir/source-removal-outcome" || return 1
	_worktree_recovery_v2_contract_is_valid "$recovery_dir" || return 1
	return 0
}

_worktree_write_recovery_identity() {
	local recovery_dir="$1"

	printf '%s\n' "$_WT_RECOVERY_FORMAT" >"${recovery_dir}/format" || return 1
	printf '%s\n' "$_WT_ID_SOURCE_REAL" >"${recovery_dir}/source-real" || return 1
	printf '%s\n' "$_WT_ID_SOURCE_INODE" >"${recovery_dir}/source-inode" || return 1
	printf '%s\n' "$_WT_ID_ADMIN_REAL" >"${recovery_dir}/admin-real" || return 1
	printf '%s\n' "$_WT_ID_ADMIN_INODE" >"${recovery_dir}/admin-inode" || return 1
	printf '%s\n' "$_WT_ID_COMMON_REAL" >"${recovery_dir}/common-real" || return 1
	printf '%s\n' "$_WT_ID_HEAD" >"${recovery_dir}/head" || return 1
	printf '%s\n' "$_WT_ID_BRANCH" >"${recovery_dir}/branch" || return 1
	return 0
}

_worktree_recovery_run_before_epoch() {
	local deadline_epoch="$1"
	shift
	local current_epoch=0
	local remaining_seconds=0

	if [[ "$deadline_epoch" -eq 0 ]]; then
		"$@"
		return $?
	fi
	current_epoch=$(date +%s) || return 1
	remaining_seconds=$((deadline_epoch - current_epoch))
	[[ "$remaining_seconds" -gt 0 ]] || return 124
	declare -F timeout_sec >/dev/null 2>&1 || return 124
	timeout_sec "$remaining_seconds" "$@"
	return $?
}

_worktree_recovery_archive_is_valid() {
	local archive_path="$1"
	local deadline_epoch="${2:-0}"
	local recovery_dir=""
	local recovery_admin=""
	local recovery_admin_real=""
	local format=""
	local expected_head=""
	local expected_branch=""
	local actual_admin=""
	local actual_head=""
	local real_git=""

	if _worktree_recovery_is_compact "$archive_path"; then
		_worktree_recovery_producer_command "$deadline_epoch" verify "$archive_path" || return $?
		return 0
	fi
	recovery_dir=$(_worktree_recovery_dir_for_archive "$archive_path") || return 1
	recovery_admin="${recovery_dir}/admin"
	[[ -d "$archive_path" && -f "$archive_path/.git" && ! -L "$archive_path/.git" ]] || return 1
	[[ -d "$recovery_admin" && -f "$recovery_admin/HEAD" && -f "$recovery_admin/index" ]] || return 1
	IFS= read -r format <"${recovery_dir}/format" || return 1
	IFS= read -r expected_head <"${recovery_dir}/head" || return 1
	IFS= read -r expected_branch <"${recovery_dir}/branch" || return 1
	_worktree_recovery_format_is_supported "$format" || return 1
	if [[ "$format" == "$_WT_RECOVERY_FORMAT_V2" ]]; then
		_worktree_recovery_v2_contract_is_valid "$recovery_dir" || return 1
	fi
	_worktree_git_head_payload_is_valid "$expected_head" || return 1
	if [[ "$expected_branch" != "$_WT_RECOVERY_BRANCH_DETACHED" ]]; then
		_worktree_git_branch_payload_is_valid "$expected_branch" || return 1
	fi
	real_git=$(_worktree_cleanup_real_git) || return 1
	recovery_admin_real=$(cd "$recovery_admin" 2>/dev/null && pwd -P) || return 1
	actual_admin=$(_worktree_recovery_run_before_epoch "$deadline_epoch" \
		"$real_git" -C "$archive_path" rev-parse --absolute-git-dir 2>/dev/null) || return $?
	actual_admin=$(cd "$actual_admin" 2>/dev/null && pwd -P) || return 1
	[[ "$actual_admin" == "$recovery_admin_real" ]] || return 1
	actual_head=$(_worktree_recovery_run_before_epoch "$deadline_epoch" \
		"$real_git" -C "$archive_path" rev-parse --verify HEAD 2>/dev/null) || return $?
	[[ "$actual_head" == "$expected_head" ]] || return 1
	_worktree_recovery_run_before_epoch "$deadline_epoch" \
		"$real_git" -C "$archive_path" status --porcelain=v1 -z --untracked-files=all \
		>/dev/null 2>&1 || return $?
	return 0
}

_worktree_archive_source_matches() {
	local wt_path="$1"
	local archive_path="$2"
	local recovery_dir=""
	local expected_source_real=""
	local expected_source_inode=""
	local expected_admin_real=""
	local expected_admin_inode=""
	local expected_common_real=""
	local expected_head=""
	local expected_branch=""

	if _worktree_recovery_is_compact "$archive_path"; then
		# Also called after the final mutable probes in native removal.
		_worktree_recovery_producer_command 0 source-matches "$archive_path" "$wt_path" || return 1
		return 0
	fi
	recovery_dir=$(_worktree_recovery_dir_for_archive "$archive_path") || return 1
	IFS= read -r expected_source_real <"${recovery_dir}/source-real" || return 1
	IFS= read -r expected_source_inode <"${recovery_dir}/source-inode" || return 1
	IFS= read -r expected_admin_real <"${recovery_dir}/admin-real" || return 1
	IFS= read -r expected_admin_inode <"${recovery_dir}/admin-inode" || return 1
	IFS= read -r expected_common_real <"${recovery_dir}/common-real" || return 1
	IFS= read -r expected_head <"${recovery_dir}/head" || return 1
	IFS= read -r expected_branch <"${recovery_dir}/branch" || return 1
	_worktree_capture_git_identity "$wt_path" || return 1
	[[ "$_WT_ID_SOURCE_REAL" == "$expected_source_real" ]] || return 1
	[[ "$_WT_ID_SOURCE_INODE" == "$expected_source_inode" ]] || return 1
	[[ "$_WT_ID_ADMIN_REAL" == "$expected_admin_real" ]] || return 1
	[[ "$_WT_ID_ADMIN_INODE" == "$expected_admin_inode" ]] || return 1
	[[ "$_WT_ID_COMMON_REAL" == "$expected_common_real" ]] || return 1
	[[ "$_WT_ID_HEAD" == "$expected_head" ]] || return 1
	[[ "$_WT_ID_BRANCH" == "$expected_branch" ]] || return 1
	return 0
}

# Recoverable archives are framework-owned recovery data, not ordinary Trash on
# platforms where $HOME/.Trash has no OS meaning. macOS keeps its established
# OS Trash destination; Linux and other platforms use an explicit aidevops store.
# Explicit operator overrides retain precedence on every platform.
_worktree_recovery_store_root() {
	local platform="${1:-}"
	local configured_root="${AIDEVOPS_WORKTREE_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}"

	if [[ -n "$configured_root" ]]; then
		[[ "$configured_root" == /* ]] || return 1
		printf '%s\n' "$configured_root"
		return 0
	fi
	[[ -n "${HOME:-}" ]] || return 1
	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null) || return 1
	fi
	case "$platform" in
	Darwin) printf '%s/.Trash\n' "$HOME" ;;
	*) printf '%s/.aidevops/recovery/worktrees\n' "$HOME" ;;
	esac
	return 0
}

_worktree_legacy_recovery_root() {
	local platform="${1:-}"

	[[ -n "${HOME:-}" ]] || return 1
	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null) || return 1
	fi
	[[ "$platform" != "$_WT_PLATFORM_DARWIN" ]] || return 1
	printf '%s/.Trash\n' "$HOME"
	return 0
}

_worktree_legacy_recovery_bucket_is_valid() {
	local bucket="$1"
	local deadline_epoch="${2:-0}"
	local recovery_dir="${bucket}/${_WT_RECOVERY_DIR_NAME}"
	local recorded_gitdir=""
	local archive_path=""

	[[ -f "$recovery_dir/admin/gitdir" && ! -L "$recovery_dir/admin/gitdir" ]] || return 1
	IFS= read -r recorded_gitdir <"$recovery_dir/admin/gitdir" || return 1
	case "$recorded_gitdir" in
	"$bucket"/*/.git) archive_path="${recorded_gitdir%/.git}" ;;
	*) return 1 ;;
	esac
	[[ "${archive_path%/*}" == "$bucket" ]] || return 1
	_worktree_recovery_archive_is_valid "$archive_path" "$deadline_epoch" || return $?
	return 0
}

_worktree_recovery_extended_metadata_is_present() {
	local bucket="$1"
	local recovery_dir="${bucket}/${_WT_RECOVERY_DIR_NAME}"
	local metadata_name=""

	for metadata_name in "$_WT_RECOVERY_COMPLETE_MARKER" storage-owner storage-class storage-policy storage-root \
		created-at producer producer-context session-id archive-outcome source-removal-outcome; do
		if [[ -e "$recovery_dir/$metadata_name" || -L "$recovery_dir/$metadata_name" ]]; then
			return 0
		fi
	done
	return 1
}

_worktree_recovery_storage_contract_is_valid() {
	local bucket="$1"
	local expected_root="$2"
	local recovery_dir="${bucket}/${_WT_RECOVERY_DIR_NAME}"
	local storage_owner=""
	local storage_class=""
	local storage_policy=""
	local storage_root=""
	local metadata_name=""

	for metadata_name in storage-owner storage-class storage-policy storage-root; do
		[[ -f "$recovery_dir/$metadata_name" && ! -L "$recovery_dir/$metadata_name" ]] || return 1
	done
	IFS= read -r storage_owner <"$recovery_dir/storage-owner" || return 1
	IFS= read -r storage_class <"$recovery_dir/storage-class" || return 1
	IFS= read -r storage_policy <"$recovery_dir/storage-policy" || return 1
	IFS= read -r storage_root <"$recovery_dir/storage-root" || return 1
	[[ "$storage_owner" == "$_WT_RECOVERY_STORAGE_OWNER" ]] || return 1
	[[ "$storage_class" == "recovery" ]] || return 1
	[[ "$storage_policy" == "manual-review" ]] || return 1
	[[ "$storage_root" == "$expected_root" ]] || return 1
	return 0
}

_worktree_recovery_inventory_bucket_state() {
	local bucket="$1"
	local root_real="$2"
	local deadline_epoch="${3:-0}"
	local completion=""
	local format=""
	local state="unknown"
	local validation_status=1

	if [[ -d "$bucket" && ! -L "$bucket" &&
		-d "$bucket/${_WT_RECOVERY_DIR_NAME}" &&
		! -L "$bucket/${_WT_RECOVERY_DIR_NAME}" &&
		-f "$bucket/${_WT_RECOVERY_DIR_NAME}/format" &&
		! -L "$bucket/${_WT_RECOVERY_DIR_NAME}/format" &&
		-f "$bucket/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" &&
		! -L "$bucket/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" ]]; then
		IFS= read -r format <"$bucket/${_WT_RECOVERY_DIR_NAME}/format" || format=""
		IFS= read -r completion < \
			"$bucket/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" || completion=""
		validation_status=1
		if _worktree_recovery_format_is_supported "$format" &&
			[[ "$completion" == "$format" ]] &&
			_worktree_recovery_storage_contract_is_valid "$bucket" "$root_real"; then
			validation_status=0
			_worktree_legacy_recovery_bucket_is_valid "$bucket" "$deadline_epoch" || validation_status=$?
			[[ "$validation_status" -ne 0 ]] || state="attributed"
		fi
	elif [[ -d "$bucket" && ! -L "$bucket" &&
		-f "$bucket/${_WT_RECOVERY_DIR_NAME}/format" &&
		! -L "$bucket/${_WT_RECOVERY_DIR_NAME}/format" ]]; then
		IFS= read -r format <"$bucket/${_WT_RECOVERY_DIR_NAME}/format" || format=""
		validation_status=1
		if [[ "$format" == "$_WT_RECOVERY_FORMAT_V1" ]] &&
			! _worktree_recovery_extended_metadata_is_present "$bucket"; then
			validation_status=0
			_worktree_legacy_recovery_bucket_is_valid "$bucket" "$deadline_epoch" || validation_status=$?
			[[ "$validation_status" -ne 0 ]] || state="attributed-legacy"
		fi
	fi
	[[ "$validation_status" -ne 124 ]] || return 124
	printf '%s\n' "$state"
	return 0
}

_worktree_recovery_inventory_paths_root() {
	local root_path="$1"
	local store_role="$2"
	local root_owner="$3"
	local root_real="$root_path"
	local bucket=""

	[[ -d "$root_path" && ! -L "$root_path" ]] || return 0
	root_real=$(cd "$root_path" 2>/dev/null && pwd -P) || return 1
	for bucket in "$root_real"/aidevops-worktree-cleanup-*; do
		[[ -e "$bucket" || -L "$bucket" ]] || continue
		printf 'bucket\t%s\t%s\t%s\n' \
			"$store_role" "$root_owner" "$bucket"
	done
	return 0
}

_worktree_recovery_inventory_root() {
	local root_path="$1"
	local store_role="$2"
	local root_owner="$3"
	local root_real="$root_path"
	local root_state="missing"
	local bucket=""
	local state="unknown"

	if [[ -d "$root_path" ]]; then
		root_real=$(cd "$root_path" 2>/dev/null && pwd -P) || root_state="$_WT_RECOVERY_ROOT_UNAVAILABLE"
		[[ "$root_state" == "$_WT_RECOVERY_ROOT_UNAVAILABLE" ]] || root_state="present"
	elif [[ -e "$root_path" || -L "$root_path" ]]; then
		root_state="$_WT_RECOVERY_ROOT_UNAVAILABLE"
	fi
	printf 'store\t%s\t%s\trecovery\tmanual-review\t%s\t%s\n' \
		"$store_role" "$root_owner" "$root_state" "$root_real"
	[[ "$root_state" == "present" ]] || return 0
	for bucket in "$root_real"/aidevops-worktree-cleanup-*; do
		[[ -e "$bucket" || -L "$bucket" ]] || continue
		state=$(_worktree_recovery_inventory_bucket_state "$bucket" "$root_real") || return 1
		printf 'bucket\t%s\t%s\t%s\t%s\n' \
			"$store_role" "$_WT_RECOVERY_STORAGE_OWNER" "$state" "$bucket"
	done
	return 0
}

# Read-only, fail-closed inventory for current and attributable legacy buckets.
# Unknown or interrupted buckets are reported, never treated as reclaimable.
worktree_recovery_inventory() {
	local platform="${1:-}"
	local current_root=""
	local current_root_compare=""
	local current_owner="$_WT_RECOVERY_STORAGE_OWNER"
	local legacy_root=""
	local legacy_root_compare=""

	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null) || return 1
	fi
	if [[ "$platform" == "$_WT_PLATFORM_DARWIN" ||
		-n "${AIDEVOPS_WORKTREE_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}" ]]; then
		current_owner="$_WT_RECOVERY_STORAGE_OWNER_JOINT"
	fi
	current_root=$(_worktree_recovery_store_root "$platform") || return 1
	current_root_compare="$current_root"
	if [[ -d "$current_root" ]]; then
		current_root_compare=$(cd "$current_root" 2>/dev/null && pwd -P) || return 1
	fi
	_worktree_recovery_inventory_root "$current_root" "current" "$current_owner" || return 1
	if legacy_root=$(_worktree_legacy_recovery_root "$platform"); then
		legacy_root_compare="$legacy_root"
		if [[ -d "$legacy_root" ]]; then
			legacy_root_compare=$(cd "$legacy_root" 2>/dev/null && pwd -P) || return 1
		fi
		if [[ "$legacy_root_compare" != "$current_root_compare" ]]; then
			_worktree_recovery_inventory_root "$legacy_root" "legacy" \
				"$_WT_RECOVERY_STORAGE_OWNER_JOINT" || return 1
		fi
	fi
	return 0
}

# Cheap path-only enumeration for bounded consumers. Bucket attribution remains
# fail-closed and must be performed separately inside the consumer's work window.
worktree_recovery_inventory_paths() {
	local platform="${1:-}"
	local current_root=""
	local current_root_compare=""
	local current_owner="$_WT_RECOVERY_STORAGE_OWNER"
	local legacy_root=""
	local legacy_root_compare=""

	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null) || return 1
	fi
	if [[ "$platform" == "$_WT_PLATFORM_DARWIN" ||
		-n "${AIDEVOPS_WORKTREE_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}" ]]; then
		current_owner="$_WT_RECOVERY_STORAGE_OWNER_JOINT"
	fi
	current_root=$(_worktree_recovery_store_root "$platform") || return 1
	current_root_compare="$current_root"
	if [[ -d "$current_root" ]]; then
		current_root_compare=$(cd "$current_root" 2>/dev/null && pwd -P) || return 1
	fi
	_worktree_recovery_inventory_paths_root "$current_root" "current" "$current_owner" || return 1
	if legacy_root=$(_worktree_legacy_recovery_root "$platform"); then
		legacy_root_compare="$legacy_root"
		if [[ -d "$legacy_root" ]]; then
			legacy_root_compare=$(cd "$legacy_root" 2>/dev/null && pwd -P) || return 1
		fi
		if [[ "$legacy_root_compare" != "$current_root_compare" ]]; then
			_worktree_recovery_inventory_paths_root "$legacy_root" "legacy" \
				"$_WT_RECOVERY_STORAGE_OWNER_JOINT" || return 1
		fi
	fi
	return 0
}

_worktree_recovery_process_lstart() {
	local pid="$1"
	local process_lstart=""

	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	process_lstart=$(LC_ALL=C TZ=UTC ps -ww -p "$pid" -o lstart= 2>/dev/null || true)
	process_lstart="${process_lstart#"${process_lstart%%[![:space:]]*}"}"
	[[ -n "$process_lstart" ]] || return 1
	printf '%s\n' "$process_lstart"
	return 0
}

_worktree_recovery_lock_owner_state() {
	local lock_path="$1"
	local owner_pid=""
	local owner_lstart=""
	local current_lstart=""
	local metadata_name=""

	[[ -d "$lock_path" && ! -L "$lock_path" ]] || {
		printf '%s\n' "$_WT_RECOVERY_LOCK_STATE_UNCERTAIN"
		return 0
	}
	for metadata_name in pid lstart token initialized; do
		[[ -f "$lock_path/$metadata_name" && ! -L "$lock_path/$metadata_name" ]] || {
			printf '%s\n' "$_WT_RECOVERY_LOCK_STATE_UNCERTAIN"
			return 0
		}
	done
	IFS= read -r owner_pid <"$lock_path/pid" || owner_pid=""
	IFS= read -r owner_lstart <"$lock_path/lstart" || owner_lstart=""
	[[ "$owner_pid" =~ ^[0-9]+$ && -n "$owner_lstart" ]] || {
		printf '%s\n' "$_WT_RECOVERY_LOCK_STATE_UNCERTAIN"
		return 0
	}
	if ! kill -0 "$owner_pid" 2>/dev/null; then
		printf '%s\n' "$_WT_RECOVERY_LOCK_STATE_STALE"
		return 0
	fi
	current_lstart=$(_worktree_recovery_process_lstart "$owner_pid" 2>/dev/null || true)
	if [[ -z "$current_lstart" ]]; then
		if kill -0 "$owner_pid" 2>/dev/null; then
			printf '%s\n' "$_WT_RECOVERY_LOCK_STATE_UNCERTAIN"
		else
			printf '%s\n' "$_WT_RECOVERY_LOCK_STATE_STALE"
		fi
	elif [[ "$current_lstart" == "$owner_lstart" ]]; then
		printf '%s\n' "$_WT_RECOVERY_LOCK_STATE_LIVE"
	else
		printf '%s\n' "$_WT_RECOVERY_LOCK_STATE_STALE"
	fi
	return 0
}

_worktree_recovery_acquire_producer_lock() {
	local recovery_root="$1"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"
	local reclaim_path=""
	local owner_state=""
	local process_lstart=""
	local owner_token=""
	local observed_pid=""
	local observed_lstart=""
	local observed_token=""
	local reclaimed_pid=""
	local reclaimed_lstart=""
	local reclaimed_token=""
	local reclaim_state=""
	local attempt=0

	WORKTREE_RECOVERY_PRODUCER_LOCK_PATH=""
	WORKTREE_RECOVERY_PRODUCER_LOCK_TOKEN=""
	WORKTREE_RECOVERY_PRODUCER_LOCK_LSTART=""
	[[ -d "$recovery_root" && ! -L "$recovery_root" ]] || return 1
	process_lstart=$(_worktree_recovery_process_lstart "$$") || return 1
	owner_token="$$-${RANDOM}-$(date -u '+%Y%m%dT%H%M%SZ')"
	while [[ "$attempt" -lt 2 ]]; do
		if mkdir "$lock_path" 2>/dev/null; then
			if ! printf '%s\n' "$$" >"$lock_path/pid" ||
				! printf '%s\n' "$process_lstart" >"$lock_path/lstart" ||
				! printf '%s\n' "$owner_token" >"$lock_path/token" ||
				! printf '%s\n' "complete" >"$lock_path/initialized"; then
				rm -f "$lock_path/pid" "$lock_path/lstart" "$lock_path/token" \
					"$lock_path/initialized" 2>/dev/null || true
				rmdir "$lock_path" 2>/dev/null || true
				return 1
			fi
			WORKTREE_RECOVERY_PRODUCER_LOCK_PATH="$lock_path"
			WORKTREE_RECOVERY_PRODUCER_LOCK_TOKEN="$owner_token"
			WORKTREE_RECOVERY_PRODUCER_LOCK_LSTART="$process_lstart"
			return 0
		fi
		[[ -e "$lock_path" || -L "$lock_path" ]] || return 1
		owner_state=$(_worktree_recovery_lock_owner_state "$lock_path") || return 1
		[[ "$owner_state" == "$_WT_RECOVERY_LOCK_STATE_STALE" ]] || return 1
		IFS= read -r observed_pid <"$lock_path/pid" || return 1
		IFS= read -r observed_lstart <"$lock_path/lstart" || return 1
		IFS= read -r observed_token <"$lock_path/token" || return 1
		reclaim_path="${lock_path}.reclaim.$$-${RANDOM}"
		mv "$lock_path" "$reclaim_path" 2>/dev/null || return 1
		reclaim_state=$(_worktree_recovery_lock_owner_state "$reclaim_path") || return 1
		IFS= read -r reclaimed_pid <"$reclaim_path/pid" || return 1
		IFS= read -r reclaimed_lstart <"$reclaim_path/lstart" || return 1
		IFS= read -r reclaimed_token <"$reclaim_path/token" || return 1
		if [[ "$reclaim_state" != "$_WT_RECOVERY_LOCK_STATE_STALE" ||
			"$reclaimed_pid" != "$observed_pid" || "$reclaimed_lstart" != "$observed_lstart" ||
			"$reclaimed_token" != "$observed_token" ]]; then
			if [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
				mv "$reclaim_path" "$lock_path" 2>/dev/null || true
			fi
			return 1
		fi
		rm -rf "$reclaim_path" || return 1
		attempt=$((attempt + 1))
	done
	return 1
}

_worktree_recovery_release_producer_lock() {
	local lock_path="${WORKTREE_RECOVERY_PRODUCER_LOCK_PATH:-}"
	local owner_pid=""
	local owner_lstart=""
	local owner_token=""

	[[ -n "$lock_path" && -d "$lock_path" && ! -L "$lock_path" ]] || return 1
	IFS= read -r owner_pid <"$lock_path/pid" || return 1
	IFS= read -r owner_lstart <"$lock_path/lstart" || return 1
	IFS= read -r owner_token <"$lock_path/token" || return 1
	[[ "$owner_pid" == "$$" && "$owner_lstart" == "$WORKTREE_RECOVERY_PRODUCER_LOCK_LSTART" &&
		"$owner_token" == "$WORKTREE_RECOVERY_PRODUCER_LOCK_TOKEN" ]] || return 1
	rm -f "$lock_path/initialized" "$lock_path/pid" "$lock_path/lstart" \
		"$lock_path/token" || return 1
	rmdir "$lock_path" || return 1
	WORKTREE_RECOVERY_PRODUCER_LOCK_PATH=""
	WORKTREE_RECOVERY_PRODUCER_LOCK_TOKEN=""
	WORKTREE_RECOVERY_PRODUCER_LOCK_LSTART=""
	return 0
}

# Prefer the compact archive override, retaining historical explicit store
# overrides. Defaults now share the archive CLI's store on every platform.
_worktree_recovery_producer_root() {
	local root="${AIDEVOPS_WORKTREE_ARCHIVE_ROOT:-${AIDEVOPS_WORKTREE_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}}"
	if [[ -z "$root" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		root="${HOME}/.aidevops/recovery/archives"
	fi
	_worktree_recovery_line_payload_is_valid "$root" || return 1
	[[ "$root" == /* ]] || return 1
	printf '%s\n' "$root"
	return 0
}

# Resolve and reject overlapping stores before mkdir can modify the source or
# Git administration. The permission probe still precedes all Git inspection.
_worktree_recovery_resolve_producer_root() {
	local wt_path="$1"
	local root="$2"
	local caller="$3"
	local resolved=""
	_worktree_recovery_store_preflight "$wt_path" "$root" "$caller" || return 1
	# Status 2 preserves this refusal category across command substitution.
	_worktree_capture_git_identity "$wt_path" || return 2
	resolved=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$root") || return 1
	case "$resolved" in
	"$_WT_ID_SOURCE_REAL" | "$_WT_ID_SOURCE_REAL"/* | "$_WT_ID_COMMON_REAL" | "$_WT_ID_COMMON_REAL"/*)
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" \
			"recovery-store-overlaps-source" "$_WTAR_MODE_SKIPPED"
		return 1
		;;
	esac
	printf '%s\n' "$resolved"
	return 0
}

# Re-emit producer stderr and, for source-drift, print the recovery steps.
# Args: $1=stderr capture file (may be empty), $2=recovery root
# Deletes the capture file. Always returns 0.
_worktree_report_capture_failure() {
	local err_file="$1"
	local recovery_root="$2"
	local err_text=""

	[[ -n "$err_file" && -f "$err_file" ]] || return 0
	err_text=$(<"$err_file")
	rm -f "$err_file"
	[[ -z "$err_text" ]] || printf '%s\n' "$err_text" >&2
	case "$err_text" in
	*producer:source-drift*)
		printf '%s\n' "Reason: the worktree changed after a previous removal attempt reserved its recovery archive (producer:source-drift)." >&2
		printf '%s\n' "Recovery: restore the recorded state with 'git -C <worktree> apply <archive>/diff.patch' (plus any recorded untracked files) from the retained archive under ${recovery_root}/.producer-archives, then run 'worktree-helper.sh remove <worktree> --force'. Alternatively review and retire the reservation. See .agents/reference/dirty-worktree-preservation.md." >&2
		;;
	esac
	return 0
}

_archive_worktree_path_recoverably_under_lock() {
	local wt_path="$1"
	local caller="$2"
	local context="${3:-}"
	local wt_path_real="$wt_path"
	local recovery_root_real="$4"
	local archive_path=""
	local git_state=""

	WORKTREE_RECOVERABLE_ARCHIVE_PATH=""
	if ! _worktree_capture_git_identity "$wt_path"; then
		_worktree_log_identity_refusal "$wt_path" "$caller" "$context"
		return 1
	fi
	wt_path_real="$_WT_ID_SOURCE_REAL"
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
		git_state="$_WT_GIT_STATE_UNREADABLE"
	if [[ "$git_state" != "$_WT_GIT_STATE_CLEAR" ]]; then
		_worktree_log_git_refusal "$wt_path" "$caller" "$git_state" "$context"
		return 1
	fi
	local capture_err=""
	capture_err=$(mktemp "${TMPDIR:-/tmp}/wt-capture-err.XXXXXX" 2>/dev/null) || capture_err=""
	if ! archive_path=$(_worktree_recovery_producer_command 0 capture \
		"$wt_path_real" "$recovery_root_real" "$caller" "$context" 2>"${capture_err:-/dev/null}"); then
		_worktree_report_capture_failure "$capture_err" "$recovery_root_real"
		WORKTREE_REMOVAL_GUARD_REASON="compact-recovery-capture-failed"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" \
			"compact-recovery-capture-failed" "$_WTAR_MODE_SKIPPED" \
			"source_preserved=true operator_review=required"
		return 1
	fi
	[[ -z "$capture_err" ]] || rm -f "$capture_err"
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") ||
		git_state="$_WT_GIT_STATE_UNREADABLE"
	if [[ "$git_state" != "$_WT_GIT_STATE_CLEAR" ]]; then
		_worktree_log_git_refusal "$wt_path" "$caller" "$git_state" "$context"
		return 1
	fi
	WORKTREE_RECOVERABLE_ARCHIVE_PATH="$archive_path"
	return 0
}

# Refuse privilege mistakes before mkdir can create a root-owned store in a
# user's home. Existing stores must be writable by the actual cleanup user;
# never repair ownership implicitly or bypass recoverable-removal safeguards.
_worktree_recovery_store_preflight() {
	local wt_path="$1"
	local recovery_root="$2"
	local caller="$3"
	local reason=""

	if reason=$(python3 - "$wt_path" "$recovery_root" <<'PY'
import os
import sys

try:
    source, store = sys.argv[1:]
    if os.geteuid() == 0 and os.stat(source).st_uid != 0:
        print("recovery-privilege-mismatch")
        raise SystemExit(1)
    parent = store
    while not os.path.lexists(parent):
        previous = parent
        parent = os.path.dirname(parent)
        if parent == previous or not parent:
            raise OSError("No accessible recovery parent")
    if not os.path.isdir(parent) or not os.access(parent, os.W_OK | os.X_OK):
        print("recovery-store-not-writable")
        raise SystemExit(1)
except OSError:
    print("recovery-store-inaccessible")
    raise SystemExit(1)
PY
	); then
		return 0
	fi
	reason="${reason:-recovery-store-probe-failed}"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" \
		"$reason" "$_WTAR_MODE_SKIPPED" "recovery_root=$recovery_root"
	printf 'Recovery refused: %s (%s). Run cleanup as the worktree owner; inspect recovery-directory ownership and permissions. Repair only with explicit operator approval; source preserved.\n' \
		"$reason" "$recovery_root" >&2
	return 1
}

archive_worktree_path_recoverably() {
	local wt_path="$1"
	local caller="$2"
	local context="${3:-}"
	local recovery_root=""
	local recovery_root_real=""
	local resolver_status=0
	local archive_status=0
	local hold_seconds="${AIDEVOPS_WORKTREE_RECOVERY_TEST_HOLD_LOCK_SECONDS:-0}"

	WORKTREE_RECOVERABLE_ARCHIVE_PATH=""
	recovery_root=$(_worktree_recovery_producer_root) || return 1
	if recovery_root_real=$(_worktree_recovery_resolve_producer_root "$wt_path" "$recovery_root" "$caller"); then
		:
	else
		resolver_status=$?
		if [[ "$resolver_status" -eq 2 ]]; then
			_worktree_log_identity_refusal "$wt_path" "$caller" "$context"
		fi
		return 1
	fi
	# A group-writable caller umask must not shape new archive-store directories;
	# existing directories keep their modes.
	(umask 077 && mkdir -p "$recovery_root_real") 2>/dev/null || return 1
	_worktree_recovery_acquire_producer_lock "$recovery_root_real" || return 1
	case "$hold_seconds" in
	'' | *[!0-9]*) hold_seconds=0 ;;
	esac
	[[ "$hold_seconds" -eq 0 ]] || sleep "$hold_seconds"
	_archive_worktree_path_recoverably_under_lock "$wt_path" "$caller" "$context" "$recovery_root_real" || archive_status=$?
	_worktree_recovery_release_producer_lock || archive_status=1
	return "$archive_status"
}
