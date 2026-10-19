#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by the recovery lifecycle helper: migration is not retirement.

_worktree_recovery_migrate_cli() {
	local count="$#"
	local bucket_option="${1:-}"
	local bucket="${2:-}"
	local repo_option="${3:-}"
	local repo="${4:-}"
	local base_option="${5:-}"
	local base="${6:-}"
	[[ "$count" -eq 6 && "$bucket_option" == "--bucket" &&
		"$repo_option" == "--repo" && "$base_option" == "--base-branch" ]] || {
		_worktree_recovery_lifecycle_usage >&2
		return 1
	}
	worktree_recovery_migrate "$bucket" --repo "$repo" --base-branch "$base"
	return $?
}

_worktree_recovery_migrate_failure() {
	local reason="$1"
	jq -cn --arg reason "$reason" '{state:"incomplete",reason:$reason,source_retired:false}'
	return 1
}

_worktree_recovery_migrate_under_lock() {
	local bucket="$1"
	local root="$2"
	shift 2
	local archive="" identity="" format="" completion=""
	local metadata="${bucket}/.aidevops-worktree-recovery"
	local -x GIT_OPTIONAL_LOCKS=0
	local -x GIT_NO_LAZY_FETCH=1

	[[ -d "$metadata" && ! -L "$metadata" ]] || return 1
	format=$(_worktree_recovery_plan_read_line "$metadata/format") || return 1
	completion=$(_worktree_recovery_plan_read_line "$metadata/archive-complete") || {
		_worktree_recovery_migrate_failure "completion-marker-unavailable"
		return 1
	}
	[[ "$completion" == "$format" ]] || {
		_worktree_recovery_migrate_failure "completion-marker-mismatch"
		return 1
	}
	_worktree_recovery_storage_contract_is_valid "$bucket" "$root" || {
		_worktree_recovery_migrate_failure "storage-contract-invalid"
		return 1
	}
	archive=$(_worktree_recovery_plan_archive_path "$bucket") || return 1
	_worktree_recovery_archive_is_valid "$archive" || {
		_worktree_recovery_migrate_failure "git-recovery-unavailable"
		return 1
	}
	identity=$(_worktree_recovery_plan_identity_json "$bucket") || return 1
	printf '%s\n' "$identity" | python3 \
		"$WORKTREE_RECOVERY_LIFECYCLE_DIR/worktree_recovery_migrate.py" "$@"
	return $?
}

worktree_recovery_migrate() {
	local bucket="$1"
	shift
	local root="" root_real="" bucket_real="" status=0

	root=$(_worktree_recovery_store_root) || return 1
	[[ -d "$root" && ! -L "$root" && -d "$bucket" && ! -L "$bucket" ]] || return 1
	root_real=$(cd "$root" && pwd -P) || return 1
	bucket_real=$(cd "$bucket" && pwd -P) || return 1
	[[ "$bucket" == "$bucket_real" && "${bucket_real%/*}" == "$root_real" &&
		"${bucket_real##*/}" == aidevops-worktree-cleanup-* ]] || return 1
	_worktree_recovery_acquire_producer_lock "$root_real" || return 1
	_worktree_recovery_migrate_under_lock "$bucket_real" "$root_real" "$@" || status=$?
	_worktree_recovery_release_producer_lock || status=1
	if [[ "$status" -ne 0 ]]; then
		printf '%s\n' 'Migration incomplete: source retained; inspect bucket completeness, ownership and Git evidence.' >&2
		return 1
	fi
	return 0
}
