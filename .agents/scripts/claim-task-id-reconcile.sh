#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Claim Task ID — Counter Status and Reconciliation Sub-Library
# =============================================================================
# Extracted from claim-task-id-counter.sh (GH#20224 headroom split). Pure move.
# Sourced by claim-task-id-counter.sh; do not source directly from callers.
#
# Dependencies: shared-constants.sh and the CAS globals declared in
# claim-task-id.sh (REMOTE_NAME, COUNTER_BRANCH, COUNTER_FILE, CAS_*).
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# shellcheck disable=SC2119  # callers intentionally pass no optional git options
# Include guard
[[ -n "${_CLAIM_TASK_ID_RECONCILE_LIB_LOADED:-}" ]] && return 0
_CLAIM_TASK_ID_RECONCILE_LIB_LOADED=1

# Stable AIDEVOPS_TASK_COUNTER_STATUS values emitted by reconciliation.
_CAS_STATUS_DESYNC="unrecoverable_desync"
_CAS_STATUS_RECOVERED="recovered_contention"

# Emit a stable machine-readable allocation status without contaminating stdout.
# Stdout is reserved for claim-task-id.sh key=value results; status belongs on
# stderr via log_info so wrappers can parse it without breaking callers.
_task_counter_status() {
	local status="$1"
	local detail="${2:-}"
	if [[ -n "$detail" ]]; then
		log_info "AIDEVOPS_TASK_COUNTER_STATUS=${status} detail=${detail}"
	else
		log_info "AIDEVOPS_TASK_COUNTER_STATUS=${status}"
	fi
	return 0
}

# Fetch the counter branch with transport timeouts. In the isolated bare context
# use --depth=1 --no-tags so large repos do not transfer full history; never
# add depth otherwise (a shallow file would truncate the shared object store).
# Any leading arguments are passed through as git global options (e.g. -c k=v).
# shellcheck disable=SC2120  # optional git global options; most callers pass none
_cas_fetch_counter_branch() {
	local -a git_opts=("$@")
	local -a depth_args=()

	_counter_context_is_isolated && read -r -a depth_args <<<"$(_counter_isolated_fetch_args)"
	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		${git_opts[@]+"${git_opts[@]}"} \
		fetch -q ${depth_args[@]+"${depth_args[@]}"} "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null
}

_cas_fetch_counter_branch_for_reconcile() {
	local repo_path="$1"

	cd "$repo_path" || return 1
	_cas_fetch_counter_branch || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: cannot fetch ${REMOTE_NAME}/${COUNTER_BRANCH} for reconciliation"
		_task_counter_status "$_CAS_STATUS_DESYNC" "fetch_failed"
		return 1
	}
	return 0
}

_cas_resolve_counter_ref_for_reconcile() {
	local counter_ref="$1"

	_counter_git rev-parse "$counter_ref" 2>/dev/null || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: cannot resolve ${counter_ref} after fetch"
		_task_counter_status "$_CAS_STATUS_DESYNC" "resolve_failed"
		return 1
	}
	return 0
}

_cas_read_counter_file_from_ref() {
	local ref_sha="$1"
	local repo_path="$2"
	local counter_value=""

	counter_value=$(_counter_show "${ref_sha}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	if [[ -z "$counter_value" ]] || ! [[ "$counter_value" =~ ^[0-9]+$ ]]; then
		counter_value=$(_compute_counter_seed "$repo_path")
	fi
	printf '%s\n' "$counter_value"
	return 0
}

_cas_read_default_counter_for_reconcile() {
	local default_branch="$1"
	local default_counter="0"
	local default_ref=""
	local depth_args=()

	if [[ -n "$default_branch" && "$default_branch" != "$COUNTER_BRANCH" ]]; then
		# Only the tip's counter file is read. Never shallow a shared object store:
		# its shallow boundary would also affect the checkout and other worktrees.
		_counter_context_is_isolated && read -r -a depth_args <<<"$(_counter_isolated_fetch_args)"
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			fetch -q "${depth_args[@]}" "$REMOTE_NAME" "$default_branch" >/dev/null || true
		default_ref="${REMOTE_NAME}/${default_branch}"
		default_counter=$(_counter_show "${default_ref}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
		if [[ -z "$default_counter" ]] || ! [[ "$default_counter" =~ ^[0-9]+$ ]]; then
			default_counter="0"
		fi
	fi
	printf '%s\n' "$default_counter"
	return 0
}

# Seed (highest TODO.md task ID + 1) from a git ref's TODO.md. Echoes 0 when
# the ref or file is unavailable (GH#33157).
_cas_todo_seed_from_ref() {
	local ref="$1"
	local todo_content=""
	local highest="0"

	todo_content=$(_counter_show "${ref}:TODO.md" 2>/dev/null || true)
	if [[ -n "$todo_content" ]]; then
		highest=$(get_highest_task_id "$todo_content")
		if [[ "$highest" =~ ^[0-9]+$ ]] && ((10#$highest > 0)); then
			printf '%s\n' "$((10#$highest + 1))"
			return 0
		fi
	fi
	printf '0\n'
	return 0
}

# Highest TODO.md-derived seed across the remote counter branch and default
# branch tips. Never reads the local working tree (GH#33157).
_cas_todo_seed_from_remote_refs() {
	local default_branch="${1:-}"
	local best="0"
	local candidate=""
	local refs=("${REMOTE_NAME}/${COUNTER_BRANCH}")
	local ref

	[[ -n "$default_branch" ]] && refs+=("${REMOTE_NAME}/${default_branch}")
	for ref in "${refs[@]}"; do
		candidate=$(_cas_todo_seed_from_ref "$ref")
		((10#$candidate > 10#$best)) && best="$candidate"
	done
	printf '%s\n' "$best"
	return 0
}

_cas_reconciled_counter_value() {
	local repo_path="$1"
	local branch_counter="$2"
	local default_counter="$3"
	local default_branch="${4:-}"
	local todo_seed=""
	local reconciled_counter="$branch_counter"

	# GH#33157: seed from remote refs only; the local working tree may be a
	# stale mirror that misses recently published IDs.
	todo_seed=$(_cas_todo_seed_from_remote_refs "$default_branch")
	((10#$default_counter > 10#$reconciled_counter)) && reconciled_counter="$default_counter"
	((10#$todo_seed > 10#$reconciled_counter)) && reconciled_counter="$todo_seed"
	printf '%s\n' "$reconciled_counter"
	return 0
}

_cas_build_reconciled_counter_tree() {
	local pinned_sha="$1"
	local reconciled_counter="$2"
	local blob_sha existing_tree tree_sha

	blob_sha=$(printf '%s\n' "$reconciled_counter" | _counter_git hash-object -w --stdin 2>/dev/null) || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to create reconciled counter blob"
		_task_counter_status "$_CAS_STATUS_DESYNC" "blob_failed"
		return 1
	}
	existing_tree=$(_counter_git ls-tree "$pinned_sha") || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to inspect reconciled counter tree"
		_task_counter_status "$_CAS_STATUS_DESYNC" "tree_read_failed"
		return 1
	}
	if grep -q "${COUNTER_FILE}$" <<<"$existing_tree"; then
		tree_sha=$(printf '%s\n' "$existing_tree" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | _counter_mktree) || {
			log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to replace reconciled counter tree entry"
			_task_counter_status "$_CAS_STATUS_DESYNC" "tree_replace_failed"
			return 1
		}
	else
		tree_sha=$(
			{
				[[ -n "$existing_tree" ]] && printf '%s\n' "$existing_tree"
				printf '100644 blob %s\t%s\n' "$blob_sha" "$COUNTER_FILE"
			} | _counter_mktree
		) || {
			log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to add reconciled counter tree entry"
			_task_counter_status "$_CAS_STATUS_DESYNC" "tree_add_failed"
			return 1
		}
	fi
	printf '%s\n' "$tree_sha"
	return 0
}

_cas_create_reconciliation_commit() {
	local pinned_sha="$1"
	local tree_sha="$2"
	local branch_counter="$3"
	local reconciled_counter="$4"

	_counter_git commit-tree "$tree_sha" -p "$pinned_sha" -m "chore: reconcile task counter (${branch_counter}->${reconciled_counter})" 2>/dev/null || {
		log_error "UNRECOVERABLE_COUNTER_DESYNC: failed to create reconciliation commit"
		_task_counter_status "$_CAS_STATUS_DESYNC" "commit_failed"
		return 1
	}
	return 0
}

_cas_push_reconciliation_commit() {
	local commit_sha="$1"
	local push_rc=0
	local push_stderr=""
	local push_err_file=""

	push_err_file=$(mktemp "${TMPDIR:-/tmp}/claim-task-id-reconcile-push.XXXXXX" 2>/dev/null) || push_err_file=""
	if [[ -n "$push_err_file" ]]; then
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			push -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null 2>"$push_err_file" || push_rc=$?
	else
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			push -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null || push_rc=$?
	fi
	if [[ -n "$push_err_file" ]]; then
		push_stderr=$(<"$push_err_file")
		rm -f "$push_err_file" 2>/dev/null || true
	fi
	if [[ $push_rc -ne 0 ]]; then
		if _cas_push_rejection_is_protected_branch "$push_stderr"; then
			_cas_log_protected_branch_rejection
			_task_counter_status "$_CAS_STATUS_DESYNC" "protected_counter_branch"
			return 1
		fi
		log_warn "Counter reconciliation push raced with another allocator; retrying allocation from refreshed branch"
		_task_counter_status "$_CAS_STATUS_RECOVERED" "reconcile_raced"
		_cas_fetch_counter_branch || true
		return 2
	fi
	return 0
}

# Re-fetch and reconcile a counter branch after CAS contention/desync.
#
# Normal CAS failures are retryable, but a non-main counter branch can become
# desynchronised with the repository's default branch (for example, develop has
# an older .task-counter than main after release/merge activity).  Before any
# fallback or fatal outcome, reconcile by pushing a counter-only commit on the
# configured counter branch with the maximum safe next-ID observed across:
#   - current counter branch
#   - default branch (when different and available)
#   - TODO.md seed (highest tNNN + 1)
#
# Returns:
#   0 — reconciliation pushed or branch already safe
#   1 — hard/unrecoverable desync (diagnostic emitted)
#   2 — race/contention while reconciling; caller may retry allocation
_cas_reconcile_counter_branch() {
	local repo_path="$1"
	local default_branch="${2:-main}"

	cd "$repo_path" || return 1
	_task_counter_status "reconciling" "branch=${REMOTE_NAME}/${COUNTER_BRANCH}"
	_cas_fetch_counter_branch_for_reconcile "$repo_path" || return 1

	local counter_ref="${REMOTE_NAME}/${COUNTER_BRANCH}"
	local pinned_sha=""
	pinned_sha=$(_cas_resolve_counter_ref_for_reconcile "$counter_ref") || return 1

	local branch_counter=""
	branch_counter=$(_cas_read_counter_file_from_ref "$pinned_sha" "$repo_path")

	# Reconciliation must not silently repair an explicitly stale selection.
	_cas_validate_explicit_counter_branch "$pinned_sha" "$branch_counter" || return $?

	local default_counter="0"
	default_counter=$(_cas_read_default_counter_for_reconcile "$default_branch")

	local reconciled_counter=""
	reconciled_counter=$(_cas_reconciled_counter_value "$repo_path" "$branch_counter" "$default_counter" "$default_branch")

	if [[ "$reconciled_counter" == "$branch_counter" ]]; then
		_task_counter_status "$_CAS_STATUS_RECOVERED" "refetched"
		return 0
	fi

	local tree_sha=""
	tree_sha=$(_cas_build_reconciled_counter_tree "$pinned_sha" "$reconciled_counter") || return 1
	local commit_sha=""
	commit_sha=$(_cas_create_reconciliation_commit "$pinned_sha" "$tree_sha" "$branch_counter" "$reconciled_counter") || return 1

	_cas_push_reconciliation_commit "$commit_sha" || return $?

	_task_counter_status "$_CAS_STATUS_RECOVERED" "counter=${reconciled_counter}"
	_cas_fetch_counter_branch || true
	return 0
}
