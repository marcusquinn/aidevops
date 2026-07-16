#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-temp-worktree-cleanup.sh — Fast cleanup for abandoned detached fixture worktrees.

[[ -n "${_PULSE_TEMP_WORKTREE_CLEANUP_LOADED:-}" ]] && return 0
_PULSE_TEMP_WORKTREE_CLEANUP_LOADED=1

_PTWC_REASON="stale-temp-fixture"
_PTWC_LOCK_DIR=""
_PTWC_LOCK_OWNER_PID=""

_ptwc_is_temp_fixture_path() {
	local wt_path="$1"
	case "$wt_path" in
	/tmp/tmp.* | /private/tmp/tmp.* | /var/folders/*/T/tmp.* | /private/var/folders/*/T/tmp.*)
		return 0
		;;
	esac
	return 1
}

_ptwc_file_mtime_epoch() {
	local file_path="$1"
	local mtime=""
	mtime=$(stat -f %m "$file_path" 2>/dev/null) || mtime=""
	if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
		mtime=$(stat -c %Y "$file_path" 2>/dev/null) || mtime=""
	fi
	[[ "$mtime" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$mtime"
	return 0
}

_ptwc_head_reachable_from_remote() {
	local repo_path="$1"
	local head_sha="$2"
	local remote_ref=""
	remote_ref=$(git -C "$repo_path" for-each-ref --count=1 --contains "$head_sha" \
		--format='%(refname)' refs/remotes 2>/dev/null) || remote_ref=""
	[[ -n "$remote_ref" ]] || return 1
	return 0
}

_ptwc_worktree_is_clean() {
	local wt_path="$1"
	local status_output=""
	# Ignored files are still user data. A detached fixture is disposable only
	# when tracked, untracked, and ignored content are all absent.
	status_output=$(git -C "$wt_path" status --porcelain=v1 --untracked-files=all \
		--ignored=matching --ignore-submodules=none 2>/dev/null) || return 1
	[[ -z "$status_output" ]] || return 1
	return 0
}

_ptwc_lock_acquire() {
	local log_dir="${AIDEVOPS_LOG_DIR:-${HOME:-}/.aidevops/logs}"
	local lock_dir="${log_dir}/cleanup_temp_worktrees.lock"
	local pid_file="${lock_dir}/pid"
	local lock_pid=""
	local owner_pid=""
	local lock_mtime=0
	local lock_age=0
	local stale_secs="${TEMP_WORKTREE_LOCK_STALE_SECS:-300}"
	local reclaim_dir=""
	local reclaim_guard="${lock_dir}.reclaim.lock"

	[[ -n "$log_dir" ]] || return 1
	[[ "$stale_secs" =~ ^[1-9][0-9]*$ ]] || stale_secs=300
	owner_pid=$(/bin/sh -c 'printf "%s\n" "$PPID"' 2>/dev/null) || owner_pid="$$"
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || owner_pid="$$"
	mkdir -p "$log_dir" 2>/dev/null || return 1
	if mkdir "$lock_dir" 2>/dev/null; then
		if ! printf '%s\n' "$owner_pid" >"$pid_file" 2>/dev/null; then
			rm -rf "$lock_dir" 2>/dev/null || true
			return 1
		fi
		_PTWC_LOCK_DIR="$lock_dir"
		_PTWC_LOCK_OWNER_PID="$owner_pid"
		return 0
	fi
	# Only one contender may inspect and reclaim an existing lock. Without this
	# atomic guard, two contenders can both classify the old owner as dead; the
	# loser may then remove the winner's newly created lock before its PID is
	# published. A stranded reclaim guard fails closed rather than risking that.
	mkdir "$reclaim_guard" 2>/dev/null || return 1
	lock_pid=""
	if [[ -f "$pid_file" ]]; then
		IFS= read -r lock_pid <"$pid_file" || lock_pid=""
	fi
	if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
		rmdir "$reclaim_guard" 2>/dev/null || true
		return 1
	fi
	if [[ -z "$lock_pid" || ! "$lock_pid" =~ ^[0-9]+$ ]]; then
		lock_mtime=$(_ptwc_file_mtime_epoch "$lock_dir") || lock_mtime=0
		if [[ "$lock_mtime" -le 0 ]]; then
			rmdir "$reclaim_guard" 2>/dev/null || true
			return 1
		fi
		lock_age=$(($(date +%s) - lock_mtime))
		if [[ "$lock_age" -lt "$stale_secs" ]]; then
			rmdir "$reclaim_guard" 2>/dev/null || true
			return 1
		fi
	fi
	# Rename-before-delete makes stale-lock reclamation atomic. A second caller
	# racing here cannot delete a newly acquired lock owned by the winner.
	reclaim_dir="${lock_dir}.reclaim.${owner_pid}"
	if ! mv "$lock_dir" "$reclaim_dir" 2>/dev/null; then
		rmdir "$reclaim_guard" 2>/dev/null || true
		return 1
	fi
	if ! rm -rf "$reclaim_dir" 2>/dev/null; then
		rmdir "$reclaim_guard" 2>/dev/null || true
		return 1
	fi
	if ! mkdir "$lock_dir" 2>/dev/null; then
		rmdir "$reclaim_guard" 2>/dev/null || true
		return 1
	fi
	if ! printf '%s\n' "$owner_pid" >"$pid_file" 2>/dev/null; then
		rm -rf "$lock_dir" 2>/dev/null || true
		rmdir "$reclaim_guard" 2>/dev/null || true
		return 1
	fi
	_PTWC_LOCK_DIR="$lock_dir"
	_PTWC_LOCK_OWNER_PID="$owner_pid"
	rmdir "$reclaim_guard" 2>/dev/null || true
	return 0
}

_ptwc_lock_release() {
	local lock_dir="$1"
	local pid_file="${lock_dir}/pid"
	local lock_pid=""
	[[ -n "$lock_dir" ]] || return 0
	if [[ -f "$pid_file" ]]; then
		IFS= read -r lock_pid <"$pid_file" || lock_pid=""
	fi
	if [[ -z "$_PTWC_LOCK_OWNER_PID" || "$lock_pid" != "$_PTWC_LOCK_OWNER_PID" ]]; then
		_PTWC_LOCK_DIR=""
		_PTWC_LOCK_OWNER_PID=""
		return 0
	fi
	rm -rf "$lock_dir" 2>/dev/null || true
	_PTWC_LOCK_DIR=""
	_PTWC_LOCK_OWNER_PID=""
	return 0
}

_ptwc_remove_candidate() {
	local repo_path="$1"
	local wt_path="$2"
	local head_sha="$3"
	local detached="$4"
	local now_epoch="$5"
	local grace_secs="$6"
	local created_epoch=0
	local age_secs=0
	local audit_context=""
	local current_head=""
	local cwd_snapshot=""

	[[ "$detached" == "1" ]] || return 1
	_ptwc_is_temp_fixture_path "$wt_path" || return 1
	[[ -f "$wt_path/.git" ]] || return 1
	created_epoch=$(_ptwc_file_mtime_epoch "$wt_path/.git") || return 1
	age_secs=$((now_epoch - created_epoch))
	[[ "$age_secs" -ge "$grace_secs" ]] || return 1
	declare -F worktree_removal_guard >/dev/null 2>&1 || return 1
	declare -F capture_worktree_process_cwds >/dev/null 2>&1 || return 1
	declare -F _worktree_owner_alive >/dev/null 2>&1 || return 1

	# Recheck candidate-local mutable predicates immediately before the
	# destructive primitive. Each destructive candidate gets a fresh process-CWD
	# snapshot; the outer pass bounds removals so this remains fast enough without
	# widening the check/delete race across candidates.
	git -C "$wt_path" symbolic-ref --quiet HEAD >/dev/null 2>&1 && return 1
	current_head=$(git -C "$wt_path" rev-parse --verify HEAD 2>/dev/null) || return 1
	[[ "$current_head" == "$head_sha" ]] || return 1
	_worktree_owner_alive "$wt_path" "" && return 1
	_ptwc_worktree_is_clean "$wt_path" || return 1
	_ptwc_head_reachable_from_remote "$repo_path" "$current_head" || return 1
	cwd_snapshot=$(capture_worktree_process_cwds) || return 1
	worktree_removal_guard "$wt_path" "pulse-temp-worktree-cleanup.sh" "$_PTWC_REASON" \
		"$cwd_snapshot" || return 1
	# Keep the post-snapshot window minimal while still proving HEAD did not move.
	git -C "$wt_path" symbolic-ref --quiet HEAD >/dev/null 2>&1 && return 1
	[[ "$(git -C "$wt_path" rev-parse --verify HEAD 2>/dev/null)" == "$current_head" ]] || return 1
	if declare -F _pc_worktree_audit_context >/dev/null 2>&1; then
		audit_context=$(_pc_worktree_audit_context "" "" "0" "0" "$age_secs" \
			"remote-ref" "clear" "clear" "clear" "remote-ref")
	fi
	# Use the linked candidate as Git context. The canonical Git guard permits
	# linked-worktree mutation but correctly rejects `worktree remove` when -C
	# points at the canonical checkout.
	git -C "$wt_path" worktree remove "$wt_path" >/dev/null 2>&1 || return 1
	if declare -F log_worktree_removal_event >/dev/null 2>&1; then
		log_worktree_removal_event "${_WTAR_REMOVED:-worktree-removed}" "pulse-temp-worktree-cleanup.sh" \
			"$wt_path" "$_PTWC_REASON" "permanent" "$audit_context"
	fi
	if declare -F unregister_worktree >/dev/null 2>&1; then
		unregister_worktree "$wt_path" 2>/dev/null || true
	fi
	printf '%s\n' "[pulse-wrapper] Temp worktree cleanup: removed detached fixture ${wt_path} — clean, age ${age_secs}s, HEAD reachable from remote" >>"${LOGFILE:-/dev/null}"
	return 0
}

_ptwc_cleanup_repo() {
	local repo_path="$1"
	local now_epoch="$2"
	local grace_secs="$3"
	local max_removals="${4:-10}"
	local porcelain=""
	local line=""
	local wt_path=""
	local head_sha=""
	local detached=0
	local removed=0
	[[ "$max_removals" =~ ^[1-9][0-9]*$ ]] || max_removals=10

	porcelain=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null) || {
		printf '0\n'
		return 0
	}
	while IFS= read -r line; do
		case "$line" in
		worktree\ *) wt_path="${line#worktree }" ;;
		HEAD\ *) head_sha="${line#HEAD }" ;;
		detached) detached=1 ;;
		"")
			if [[ "$removed" -ge "$max_removals" ]]; then
				break
			fi
			if [[ -n "$wt_path" && -n "$head_sha" ]] && \
				_ptwc_remove_candidate "$repo_path" "$wt_path" "$head_sha" "$detached" "$now_epoch" "$grace_secs"; then
				removed=$((removed + 1))
			fi
			wt_path=""
			head_sha=""
			detached=0
			;;
		esac
	done <<<"${porcelain}"$'\n'
	printf '%s\n' "$removed"
	return 0
}

cleanup_stale_temp_worktrees() {
	local lock_dir=""
	local repos_json="${AIDEVOPS_REPOS_JSON:-${HOME:-}/.config/aidevops/repos.json}"
	local grace_secs="${TEMP_WORKTREE_GRACE_SECS:-3600}"
	local max_removals="${TEMP_WORKTREE_MAX_REMOVALS_PER_RUN:-10}"
	local now_epoch=0
	local repo_paths=""
	local repo_path=""
	local repo_removed=0
	local total_removed=0
	local remaining_removals=0

	[[ "$grace_secs" =~ ^[0-9]+$ ]] || grace_secs=3600
	[[ "$max_removals" =~ ^[1-9][0-9]*$ ]] || max_removals=10
	if ! _ptwc_lock_acquire; then
		printf '0\n'
		return 0
	fi
	lock_dir="$_PTWC_LOCK_DIR"
	if [[ ! -f "$repos_json" ]] || ! command -v jq >/dev/null 2>&1; then
		_ptwc_lock_release "$lock_dir"
		printf '0\n'
		return 0
	fi
	now_epoch=$(date +%s)
	repo_paths=$(jq -r '.initialized_repos[]? | select((.local_only // false) != true) | .path // empty' \
		"$repos_json" 2>/dev/null) || repo_paths=""
	while IFS= read -r repo_path; do
		[[ -n "$repo_path" ]] || continue
		[[ "$total_removed" -lt "$max_removals" ]] || break
		git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || continue
		remaining_removals=$((max_removals - total_removed))
		repo_removed=$(_ptwc_cleanup_repo "$repo_path" "$now_epoch" "$grace_secs" "$remaining_removals")
		[[ "$repo_removed" =~ ^[0-9]+$ ]] || repo_removed=0
		total_removed=$((total_removed + repo_removed))
	done <<<"$repo_paths"
	_ptwc_lock_release "$lock_dir"
	if [[ "$total_removed" -gt 0 ]]; then
		printf '%s\n' "[pulse-wrapper] Temp worktree cleanup total: ${total_removed} stale detached fixture(s) removed" >>"${LOGFILE:-/dev/null}"
	fi
	printf '%s\n' "$total_removed"
	return 0
}

_pc_default_branch_compare_ref() {
	local repo_path="$1"
	local main_branch="$2"
	if git -C "$repo_path" rev-parse --verify --quiet "refs/remotes/origin/${main_branch}^{commit}" >/dev/null 2>&1; then
		printf 'origin/%s\n' "$main_branch"
		return 0
	fi
	printf '%s\n' "$main_branch"
	return 0
}

_pc_commits_ahead_from_default() {
	local repo_path="$1"
	local wt_path="$2"
	local main_branch="$3"
	local compare_ref=""
	compare_ref=$(_pc_default_branch_compare_ref "$repo_path" "$main_branch") || return 1
	git -C "$wt_path" rev-list --count HEAD "^${compare_ref}" 2>/dev/null
	return $?
}
