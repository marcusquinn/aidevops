#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Guarded manual and policy-bound automatic retirement entry points.

_worktree_recovery_retirement_evidence() {
	local identity="$1"
	local git_identity="" candidate="" observed="" state=""
	# The copied .git file deliberately remains unchanged after claiming. Query
	# the original common administration, not that now-relocated pointer.
	git_identity=$(printf '%s\n' "$identity" | jq -ce '.archive_path = .common_path') || return 1
	state=$(_worktree_recovery_plan_claim_state "$git_identity") || return 1
	case "$state" in
	clear | not-applicable) ;;
	*) printf 'claim-%s\n' "$state"; return 1 ;;
	esac
	for candidate in source_path bucket_path archive_path; do
		observed=$(printf '%s\n' "$identity" | jq -ce --arg key "$candidate" '.source_path = .[$key]') || return 1
		state=$(_worktree_recovery_plan_registry_state "$observed") || return 1
		[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || { printf 'registry-%s\n' "$state"; return 1; }
		observed=$(printf '%s\n' "$observed" | jq -ce '.archive_path = .common_path') || return 1
		state=$(_worktree_recovery_plan_worktree_reference_state "$observed") || return 1
		[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || { printf 'worktree-reference-%s\n' "$state"; return 1; }
	done
	state=$(_worktree_recovery_plan_process_state "$identity" "compact-then-retire") || return 1
	[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || { printf 'process-%s\n' "$state"; return 1; }
	return 0
}

_worktree_recovery_retirement_guard() {
	local target="$1"
	local identity="" claimed=""
	local -x GIT_OPTIONAL_LOCKS=0
	local -x GIT_NO_LAZY_FETCH=1
	unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
	identity=$(jq -ce '.') || return 1
	_worktree_recovery_retirement_evidence "$identity" || return 1
	claimed=$(printf '%s\n' "$identity" | jq -ce --arg target "$target" \
		'.bucket_path = $target | .archive_path = ($target + "/" + (.archive_path | split("/") | last))') || return 1
	_worktree_recovery_retirement_evidence "$claimed" || return 1
	return 0
}

_worktree_recovery_retire_cli() {
	local action="$1"
	local option="${2:-}" bucket="${3:-}" root="" root_real="" status=0
	[[ "$option" == "--bucket" && "$bucket" == /* ]] || return 1
	root=$(_worktree_recovery_store_root) || return 1
	[[ -d "$root" && ! -L "$root" && ! -L "$bucket" ]] || return 1
	root_real=$(cd "$root" && pwd -P) || return 1
	[[ "${bucket%/*}" == "$root_real" && "${bucket##*/}" == aidevops-worktree-cleanup-* ]] || return 1
	_worktree_recovery_acquire_producer_lock "$root_real" || return 1
	python3 "$WORKTREE_RECOVERY_LIFECYCLE_DIR/worktree_recovery_retire.py" "$@" || status=$?
	_worktree_recovery_release_producer_lock || status=1
	return "$status"
}
