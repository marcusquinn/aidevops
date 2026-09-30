#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Intentionally using /bin/bash (not /usr/bin/env bash) for headless compatibility.
# Some MCP/headless runners provide a stripped PATH where env cannot resolve bash.
# Keep this exception aligned with issue #2610 and t135.14 standardization context.
# shellcheck disable=SC2016,SC2155
# =============================================================================
# aidevops Issue Sync — Relationships & Backfill (GH#19502)
# =============================================================================
# Extracted from issue-sync-helper.sh to reduce the main file below the 2000-line
# gate. This is now a thin orchestrator (GH#33209) that holds shared global
# state and cmd_relationships (kept here so its function-complexity identity
# key does not regress) while sourcing four cohesive sub-libraries:
#
#   1. issue-sync-relationships-state.sh — sync scope, outcomes, resume state
#   2. issue-sync-relationships-gh.sh — node ID cache + GraphQL mutations
#   3. issue-sync-relationships-sync.sh — per-task edge/hierarchy sync
#   4. issue-sync-relationships-backfill.sh — GitHub-state-only backfill (t2114, t2877)
#
# Usage: source "${SCRIPT_DIR}/issue-sync-relationships.sh"
#
# Dependencies (all available when sourced from issue-sync-helper.sh):
#   - shared-constants.sh (print_error, print_info)
#   - issue-sync-lib.sh (parse_task_line, resolve_task_gh_number,
#     detect_parent_task_id, resolve_gh_node_id, strip_code_fences, _escape_ere)
#   - issue-sync-helper.sh globals: log_verbose, _init_cmd, DRY_RUN, VERBOSE
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced — would affect caller)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — prevents double-loading when sourced from multiple paths.
[[ -n "${_ISSUE_SYNC_RELATIONSHIPS_LOADED:-}" ]] && return 0
_ISSUE_SYNC_RELATIONSHIPS_LOADED=1

_relationships_library_dir="${BASH_SOURCE[0]%/*}"
[[ "$_relationships_library_dir" == "${BASH_SOURCE[0]}" ]] && _relationships_library_dir="."
_relationships_library_dir="$(cd "$_relationships_library_dir" && pwd)"
[[ -n "${SCRIPT_DIR:-}" ]] || SCRIPT_DIR="$_relationships_library_dir"
# shellcheck source=./issue-sync-relationship-batch.sh
# shellcheck disable=SC1091  # sub-library resolved relative to this source file
source "${_relationships_library_dir}/issue-sync-relationship-batch.sh"
# shellcheck source=./issue-sync-relationships-state.sh
# shellcheck disable=SC1091  # sub-library resolved relative to this source file
source "${_relationships_library_dir}/issue-sync-relationships-state.sh"
# shellcheck source=./issue-sync-relationships-gh.sh
# shellcheck disable=SC1091  # sub-library resolved relative to this source file
source "${_relationships_library_dir}/issue-sync-relationships-gh.sh"
# shellcheck source=./issue-sync-relationships-sync.sh
# shellcheck disable=SC1091  # sub-library resolved relative to this source file
source "${_relationships_library_dir}/issue-sync-relationships-sync.sh"
# shellcheck source=./issue-sync-relationships-backfill.sh
# shellcheck disable=SC1091  # sub-library resolved relative to this source file
source "${_relationships_library_dir}/issue-sync-relationships-backfill.sh"
unset _relationships_library_dir

# =============================================================================
# Relationships — GitHub Issue Dependencies & Hierarchy (t1889)
# =============================================================================
# Syncs TODO.md blocked-by:/blocks: and subtask hierarchy to GitHub's native
# issue relationships via GraphQL mutations.

# Node ID cache: avoids repeated API calls for the same issue number.
# Uses a temp file (bash 3.2 compatible — no associative arrays).
# Format: one "number=node_id" per line. Populated by _cached_node_id().
_NODE_ID_CACHE_FILE=""

# Rate-limited flag file: written by _cached_node_id when GraphQL is exhausted
# AND the REST fallback also fails. Uses a file (not a bash variable) so that
# the signal survives bash subshell boundaries — callers invoke _cached_node_id
# via $() which spawns a subshell, so bash variable writes inside would be lost.
# Callers check via _node_id_was_rate_limited. Reset to empty at each call.
_NODE_ID_RATE_LIMITED_FILE=""

# Invocation-scoped native-edge set. A file is required because relationship
# helpers are commonly called through command substitutions; file writes
# survive those subshell boundaries while Bash variables do not.
_RELATIONSHIP_EDGE_SEEN_FILE=""
_RELATIONSHIP_RESULT_FILE=""
_RELATIONSHIP_DIAGNOSTIC_FILE=""
_RELATIONSHIP_BACKEND_CALL_FILE=""
_RELATIONSHIP_SUCCESS_RESULT="RELS:0 RETRYABLE:0"
_RELATIONSHIP_RETRY_RESULT="RELS:0 RETRYABLE:1"
_RELATIONSHIP_SYNC_SCOPE_ACTIVE=0
_RELATIONSHIP_SYNC_DEADLINE_EPOCH=
_RELATIONSHIP_RESUME_TASKS=()
_RELATIONSHIP_RESUME_FRESH="fresh"
_RELATIONSHIP_RESUME_STATUS="$_RELATIONSHIP_RESUME_FRESH"
_RELATIONSHIP_RESUME_SUPPRESSED_TASKS=()
_RELATIONSHIP_WORK_TASKS=()
_RELATIONSHIP_CANDIDATE_TOTAL=0
_RELATIONSHIP_INPUT_REVISION=""
_RELATIONSHIP_STATE_FILE=""
_REL_OUTCOME_CREATED="created"
_REL_OUTCOME_ALREADY_PRESENT="already-present"
_REL_OUTCOME_FAILED_RESOLUTION="failed:resolution"
_REL_OUTCOME_FAILED_UNKNOWN="failed:unknown"
_REL_OUTCOME_DEFERRED_DEADLINE="deferred:deadline"

# Bulk relationship sync command.
# Scans TODO.md for tasks with relationship metadata or subtask patterns,
# resolves to GitHub node IDs, and sets relationships via GraphQL.
# Arguments:
#   $1 - optional target task_id (if empty, processes all)
cmd_relationships() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"
	local owns_scope=0 parse_started=0 parse_finished=0 mutation_started=0 mutation_finished=0
	local current_task="" result="" n="" prepare_rc=0
	local total=0 candidate_total=0 pending_before=0 index=0 remaining_index=0
	local blocked_set=0 sub_set=0 attempted=0 complete=0 retryable_total=0 task_retryable=0
	local deadline_exhausted=false backend_calls=0
	local pending_tasks=() suppressed_tasks=()
	if [[ "$_RELATIONSHIP_SYNC_SCOPE_ACTIVE" -ne 1 ]]; then
		_save_cleanup_scope
		trap '_run_cleanups' RETURN
		_begin_relationship_sync_scope || return 1
		_register_relationship_sync_cleanup
		owns_scope=1
	fi
	_ensure_relationship_sync_deadline || {
		[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
		return 1
	}
	local AIDEVOPS_GH_DEADLINE_EPOCH="$_RELATIONSHIP_SYNC_DEADLINE_EPOCH"
	parse_started=$(date +%s 2>/dev/null || printf '0')
	_relationship_prepare_workset "$target_task" "$todo_file" "$repo" || prepare_rc=$?
	if [[ "$prepare_rc" -eq 2 ]]; then
		print_info "No tasks with relationships to sync"
		[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
		return 0
	fi
	if [[ "$prepare_rc" -ne 0 ]]; then
		[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
		return 1
	fi
	_relationship_restore_suppressed_tasks
	candidate_total="$_RELATIONSHIP_CANDIDATE_TOTAL"; total="${#_RELATIONSHIP_WORK_TASKS[@]}"
	pending_before="$total"
	_relationship_prepare_edge_snapshot "$todo_file" "$owns_scope" || return 1
	parse_finished=$(date +%s 2>/dev/null || printf '%s' "$parse_started")
	print_info "Syncing relationships for $candidate_total task(s) in $repo (pending: $total, resume: $_RELATIONSHIP_RESUME_STATUS)"
	mutation_started="$parse_finished"
	for ((index = 0; index < total; index++)); do
		current_task="${_RELATIONSHIP_WORK_TASKS[index]}"
		if _relationship_deadline_expired; then
			deadline_exhausted=true
			_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
			retryable_total=$((retryable_total + 1))
			for ((remaining_index = index; remaining_index < total; remaining_index++)); do
				pending_tasks+=("${_RELATIONSHIP_WORK_TASKS[remaining_index]}")
			done
			break
		fi
		attempted=$((attempted + 1))
		task_retryable=0
		_relationship_print_progress "$attempted" "$total"
		# Recheck the absolute deadline after progress; mapping and hierarchy
		# helpers must not run after transport has consumed the remaining budget.
		if _relationship_deadline_expired; then
			deadline_exhausted=true
			_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
			retryable_total=$((retryable_total + 1))
			pending_tasks+=("$current_task")
			for ((remaining_index = index + 1; remaining_index < total; remaining_index++)); do
				pending_tasks+=("${_RELATIONSHIP_WORK_TASKS[remaining_index]}")
			done
			break
		fi

		# Blocked-by / blocks
		result=$(_sync_blocked_by_for_task "$current_task" "$todo_file" "$repo" 2>/dev/null || echo "$_RELATIONSHIP_RETRY_RESULT")
		n=$(echo "$result" | grep -oE 'RELS:[0-9]+' | head -1 | sed 's/RELS://' || echo "0")
		blocked_set=$((blocked_set + n))
		n=$(echo "$result" | grep -oE 'RETRYABLE:[0-9]+' | head -1 | sed 's/RETRYABLE://' || echo "0")
		retryable_total=$((retryable_total + n))
		task_retryable=$((task_retryable + n))

		# Sub-issue hierarchy
		if _relationship_deadline_expired; then
			deadline_exhausted=true
			_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
			retryable_total=$((retryable_total + 1))
			task_retryable=$((task_retryable + 1))
		else
			result=$(_sync_subtask_hierarchy_for_task "$current_task" "$todo_file" "$repo" 2>/dev/null || echo "$_RELATIONSHIP_RETRY_RESULT")
			n=$(echo "$result" | grep -oE 'RELS:[0-9]+' | head -1 | sed 's/RELS://' || echo "0")
			sub_set=$((sub_set + n))
			n=$(echo "$result" | grep -oE 'RETRYABLE:[0-9]+' | head -1 | sed 's/RETRYABLE://' || echo "0")
			retryable_total=$((retryable_total + n))
			task_retryable=$((task_retryable + n))
		fi
		if [[ "$task_retryable" -eq 0 ]]; then
			complete=$((complete + 1))
		else
			pending_tasks+=("$current_task")
			_relationship_suppress_failed_task "$current_task"
		fi
	done
	_relationship_finalize_command
	[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
	[[ "$retryable_total" -eq 0 ]] || return 1
	return 0
}
