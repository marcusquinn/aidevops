#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Test-only factory for historical full-copy buckets. Production never sources
# this file; tests of new producers must continue calling the production API.

# shellcheck source=../audit-worktree-removal-helper.sh
source "${BASH_SOURCE[0]%/*}/../audit-worktree-removal-helper.sh"

_create_legacy_recovery_fixture_under_lock() {
	local wt_path="$1"
	local caller="$2"
	local context="$3"
	local root="$4"
	local bucket="" archive="" metadata="" admin=""
	_worktree_capture_git_identity "$wt_path" || return 1
	bucket=$(_worktree_recovery_cache_policy reserve "$_WT_ID_SOURCE_REAL" "$root" "$_WT_ID_REAL_GIT") || return 1
	archive="$bucket/${wt_path##*/}"
	metadata="$bucket/$_WT_RECOVERY_DIR_NAME"
	admin="$metadata/admin"
	if [[ -e "$archive" ]]; then
		_worktree_recovery_archive_is_valid "$archive" || return 1
		_worktree_archive_source_matches "$wt_path" "$archive" || return 1
		_worktree_recovery_cache_policy matching-copy "$_WT_ID_SOURCE_REAL" "$archive" "$_WT_ID_REAL_GIT" || return 1
	else
		_worktree_recovery_cache_policy copy "$_WT_ID_SOURCE_REAL" "$archive" "$_WT_ID_REAL_GIT" || return 1
		mkdir "$metadata" || return 1
		_worktree_copy_directory_once "$_WT_ID_ADMIN_REAL" "$admin" || return 1
		_worktree_write_recovery_identity "$metadata" || return 1
		_worktree_write_recovery_v2_metadata "$metadata" "$caller" "$context" || return 1
		printf '%s\n' "$_WT_RECOVERY_STORAGE_OWNER" >"$metadata/storage-owner" || return 1
		printf '%s\n' recovery >"$metadata/storage-class" || return 1
		printf '%s\n' manual-review >"$metadata/storage-policy" || return 1
		printf '%s\n' "$root" >"$metadata/storage-root" || return 1
		printf '%s\n' "$_WT_ID_HEAD" >"$admin/HEAD" || return 1
		printf '%s\n' "$_WT_ID_COMMON_REAL" >"$admin/commondir" || return 1
		printf '%s\n' "$archive/.git" >"$admin/gitdir" || return 1
		printf 'gitdir: %s\n' "$admin" >"$archive/.git" || return 1
		_worktree_recovery_archive_is_valid "$archive" || return 1
		_worktree_archive_source_matches "$wt_path" "$archive" || return 1
		printf '%s\n' "$_WT_RECOVERY_FORMAT" >"$metadata/$_WT_RECOVERY_COMPLETE_MARKER" || return 1
	fi
	WORKTREE_RECOVERABLE_ARCHIVE_PATH="$archive"
	return 0
}

create_legacy_worktree_recovery_fixture() {
	local wt_path="$1"
	local caller="$2"
	local context="${3:-fixture}"
	local root="" status=0
	WORKTREE_RECOVERABLE_ARCHIVE_PATH=""
	root=$(_worktree_recovery_store_root) || return 1
	_worktree_recovery_store_preflight "$wt_path" "$root" "$caller" || return 1
	mkdir -p "$root" || return 1
	root=$(cd "$root" && pwd -P) || return 1
	_worktree_recovery_acquire_producer_lock "$root" || return 1
	_create_legacy_recovery_fixture_under_lock "$wt_path" "$caller" "$context" "$root" || status=$?
	_worktree_recovery_release_producer_lock || status=1
	return "$status"
}
