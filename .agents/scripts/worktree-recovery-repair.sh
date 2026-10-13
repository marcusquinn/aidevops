#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Operator-only missing-reservation recovery. Never invoked by pulse/maintenance.
# Requires the audit helper. Reuse its producer lock and archive implementation.

worktree_recovery_repair_missing() {
	local source_path="$1"
	local confirmation="$2"
	local root=""
	local status=0
	local history=""
	local caller="worktree-recovery-repair.sh"

	[[ "$(worktree_process_platform)" == nixos ]] || return 1
	[[ "$source_path" == /* && ! -L "$source_path" && "$confirmation" =~ ^[0-9a-f]{64}$ ]] || return 1
	_worktree_capture_git_identity "$source_path" || return 1
	root=$(_worktree_recovery_store_root) || return 1
	[[ -d "$root" && ! -L "$root" ]] || return 1
	_worktree_recovery_store_preflight "$source_path" "$root" "$caller" || return 1
	root=$(cd "$root" && pwd -P) || return 1
	_worktree_recovery_acquire_producer_lock "$root" || return 1
	if history=$(_worktree_recovery_cache_policy retire-missing "$source_path" "$root" "$confirmation"); then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$source_path" \
			"missing-reservation-reviewed" "$_WTAR_MODE_SKIPPED" \
			"source_preserved=true history=$history historical_archive_recovered=false"
		_archive_worktree_path_recoverably_under_lock "$source_path" \
			"$caller" "operator-reviewed-current-snapshot" || status=$?
	else
		status=1
	fi
	_worktree_recovery_release_producer_lock || status=1
	[[ "$status" -eq 0 ]] || return 1
	printf '%s\n' "$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	return 0
}
