#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Relationships — Edge and Subtask Hierarchy Sync
# =============================================================================
# Per-task blocked-by/blocks edge syncing, sub-issue hierarchy linking, and
# the bulk-command workset preparation/finalization helpers used by
# cmd_relationships in issue-sync-relationships.sh.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-relationships-sync.sh"
#
# Dependencies (all available when sourced from issue-sync-relationships.sh):
#   - shared-constants.sh (print_warning, log_verbose)
#   - issue-sync-lib.sh (resolve_task_gh_number, parse_task_line,
#     detect_parent_task_id, strip_code_fences)
#   - issue-sync-relationships-state.sh (deadline/outcome/scope helpers)
#   - issue-sync-relationships-gh.sh (_cached_node_id, _gh_add_sub_issue,
#     _dependency_cycle_should_skip_edge, _hold_dependency_sync_retry,
#     _ensure_dependency_status_blocked, _relationship_edge_should_attempt,
#     _relationship_task_line)
#   - issue-sync-relationship-batch.sh (_relationship_run_timed,
#     _relationship_apply_planned_batches)
#
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_ISSUE_SYNC_RELATIONSHIPS_SYNC_LIB_LOADED:-}" ]] && return 0
_ISSUE_SYNC_RELATIONSHIPS_SYNC_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_sync_declared_blocked_by_edges() {
	local task_id="$1" todo_file="$2" repo="$3" this_gh_num="$4" this_node_id="$5" blocked_by="$6"
	local dep_task_id="" dep_gh_num="" dep_node_id="" rels_set=0 retryable_errors=0
	local batch_result="" batch_rels=0 batch_errors=0
	local pending_pairs=()
	local saved_ifs="$IFS"
	IFS=','
	for dep_task_id in $blocked_by; do
			if _relationship_deadline_expired; then
				_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
				retryable_errors=$((retryable_errors + 1))
				break
			fi
			dep_task_id="${dep_task_id// /}"
			[[ -z "$dep_task_id" ]] && continue
			if [[ "$dep_task_id" == "$task_id" ]]; then
				log_verbose "$task_id: ignoring self-referential blocked-by edge"
				continue
			fi
			local dep_gh_num
			dep_gh_num=$(_relationship_run_timed mapping resolve_task_gh_number \
				"$dep_task_id" "$todo_file" "$repo" || true)
			[[ -z "$dep_gh_num" ]] && {
				log_verbose "$task_id: blocked-by $dep_task_id has no ref:GH#"
				_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
				_relationship_record_diagnostic "$task_id" "${task_id}->${dep_task_id}" "dependency-mapping-unresolved"
				retryable_errors=$((retryable_errors + 1))
				continue
			}
			if [[ "$dep_gh_num" == "$this_gh_num" ]]; then
				log_verbose "$task_id: ignoring blocked-by edge that resolves back to #$this_gh_num"
				continue
			fi
			if ! _relationship_edge_should_attempt "$this_gh_num" "$dep_gh_num"; then
				log_verbose "$task_id: skipping duplicate native edge #$this_gh_num blocked-by #$dep_gh_num"
				if [[ "$DRY_RUN" != "true" ]] && ! _ensure_dependency_status_blocked \
					"$this_gh_num" "$repo" "native_relationship_already_attempted" "$dep_gh_num"; then
					retryable_errors=$((retryable_errors + 1))
				fi
				continue
			fi
			local dep_node_id
			dep_node_id=$(_relationship_run_timed mapping _cached_node_id "$dep_gh_num" "$repo")
			if [[ -z "$dep_node_id" ]]; then
				_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
				_relationship_record_diagnostic "$task_id" "${task_id}->${dep_task_id}" "dependency-node-unresolved"
				retryable_errors=$((retryable_errors + 1))
				_hold_dependency_sync_retry "$this_gh_num" "$repo" "blocking_node_unresolved"
				continue
			fi

			if _dependency_cycle_should_skip_edge "$task_id" "$dep_task_id" "$this_gh_num" "$dep_gh_num" "$todo_file"; then
				if [[ "$DRY_RUN" == "true" ]]; then
					print_info "[DRY-RUN] Would remove circular #$this_gh_num blocked-by #$dep_gh_num ($task_id <- $dep_task_id)"
				elif ! _gh_remove_blocked_by "$this_node_id" "$dep_node_id"; then
					_relationship_record_outcome "$_REL_OUTCOME_FAILED_UNKNOWN"
					retryable_errors=$((retryable_errors + 1))
				else
					log_verbose "$task_id (#$this_gh_num): normalized circular native edge to $dep_task_id (#$dep_gh_num)"
				fi
				continue
			elif [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would set #$this_gh_num blocked-by #$dep_gh_num ($task_id <- $dep_task_id)"
				rels_set=$((rels_set + 1))
			else
				pending_pairs+=("${this_node_id}|${dep_node_id}|${this_gh_num}")
			fi
	done
	IFS="$saved_ifs"
	if [[ ${#pending_pairs[@]} -gt 0 ]]; then
		batch_result=$(_relationship_apply_planned_batches "$repo" "${pending_pairs[@]}")
		IFS=':' read -r batch_rels batch_errors <<<"$batch_result"
		rels_set=$((rels_set + batch_rels))
		retryable_errors=$((retryable_errors + batch_errors))
	fi
	printf '%s:%s\n' "$rels_set" "$retryable_errors"
	return 0
}

_sync_declared_blocks_edges() {
	local task_id="$1" todo_file="$2" repo="$3" this_gh_num="$4" this_node_id="$5" blocks="$6"
	local dep_task_id="" dep_gh_num="" dep_node_id="" rels_set=0 retryable_errors=0
	local batch_result="" batch_rels=0 batch_errors=0
	local pending_pairs=()
	local saved_ifs="$IFS"
	IFS=','
	for dep_task_id in $blocks; do
			if _relationship_deadline_expired; then
				_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
				retryable_errors=$((retryable_errors + 1))
				break
			fi
			dep_task_id="${dep_task_id// /}"
			[[ -z "$dep_task_id" ]] && continue
			if [[ "$dep_task_id" == "$task_id" ]]; then
				log_verbose "$task_id: ignoring self-referential blocks edge"
				continue
			fi
			local dep_gh_num
			dep_gh_num=$(_relationship_run_timed mapping resolve_task_gh_number \
				"$dep_task_id" "$todo_file" "$repo" || true)
			[[ -z "$dep_gh_num" ]] && {
				log_verbose "$task_id: blocks $dep_task_id has no ref:GH#"
				_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
				_relationship_record_diagnostic "$task_id" "${dep_task_id}->${task_id}" "dependency-mapping-unresolved"
				retryable_errors=$((retryable_errors + 1))
				continue
			}
			[[ "$dep_gh_num" == "$this_gh_num" ]] && continue
			if ! _relationship_edge_should_attempt "$dep_gh_num" "$this_gh_num"; then
				log_verbose "$task_id: skipping duplicate native edge #$dep_gh_num blocked-by #$this_gh_num"
				if [[ "$DRY_RUN" != "true" ]] && ! _ensure_dependency_status_blocked \
					"$dep_gh_num" "$repo" "native_relationship_already_attempted" "$this_gh_num"; then
					retryable_errors=$((retryable_errors + 1))
				fi
				continue
			fi
			local dep_node_id
			dep_node_id=$(_relationship_run_timed mapping _cached_node_id "$dep_gh_num" "$repo")
			if [[ -z "$dep_node_id" ]]; then
				_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
				_relationship_record_diagnostic "$task_id" "${dep_task_id}->${task_id}" "dependency-node-unresolved"
				retryable_errors=$((retryable_errors + 1))
				_hold_dependency_sync_retry "$dep_gh_num" "$repo" "blocking_node_unresolved"
				continue
			fi

			if _dependency_cycle_should_skip_edge "$dep_task_id" "$task_id" "$dep_gh_num" "$this_gh_num" "$todo_file"; then
				if [[ "$DRY_RUN" == "true" ]]; then
					print_info "[DRY-RUN] Would remove circular #$dep_gh_num blocked-by #$this_gh_num ($dep_task_id <- $task_id)"
				elif ! _gh_remove_blocked_by "$dep_node_id" "$this_node_id"; then
					_relationship_record_outcome "$_REL_OUTCOME_FAILED_UNKNOWN"
					retryable_errors=$((retryable_errors + 1))
					_hold_dependency_sync_retry "$dep_gh_num" "$repo" "circular_native_edge_remove_failed"
				else
					log_verbose "$dep_task_id (#$dep_gh_num): normalized circular native edge to $task_id (#$this_gh_num)"
				fi
				continue
			elif [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would set #$dep_gh_num blocked-by #$this_gh_num ($dep_task_id <- $task_id)"
				rels_set=$((rels_set + 1))
			else
				pending_pairs+=("${dep_node_id}|${this_node_id}|${dep_gh_num}")
			fi
	done
	IFS="$saved_ifs"
	if [[ ${#pending_pairs[@]} -gt 0 ]]; then
		batch_result=$(_relationship_apply_planned_batches "$repo" "${pending_pairs[@]}")
		IFS=':' read -r batch_rels batch_errors <<<"$batch_result"
		rels_set=$((rels_set + batch_rels))
		retryable_errors=$((retryable_errors + batch_errors))
	fi
	printf '%s:%s\n' "$rels_set" "$retryable_errors"
	return 0
}

# Sync blocked-by and blocks relationships for a single task.
_sync_blocked_by_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	local task_line="" parsed="" key="" value="" blocked_by="" blocks=""
	local this_gh_num="" this_node_id="" result="" edge_rels=0 edge_errors=0
	local rels_set=0 retryable_errors=0 current_retry_errors=0
	task_line=$(_relationship_task_line "$task_id" "$todo_file")
	[[ -z "$task_line" ]] && return 0
	parsed=$(parse_task_line "$task_line")
	while IFS='=' read -r key value; do
		case "$key" in
		blocked_by) blocked_by="$value" ;;
		blocks) blocks="$value" ;;
		esac
	done <<<"$parsed"
	if [[ -z "$blocked_by" && -z "$blocks" ]]; then
		echo "$_RELATIONSHIP_SUCCESS_RESULT"
		return 0
	fi
	this_gh_num=$(_relationship_run_timed mapping resolve_task_gh_number \
		"$task_id" "$todo_file" "$repo" || true)
	if [[ -z "$this_gh_num" ]]; then
		log_verbose "$task_id: declared relationship mapping unresolved; retaining for retry"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		_relationship_record_diagnostic "$task_id" "${task_id}->unmapped" "task-mapping-unresolved"
		echo "$_RELATIONSHIP_RETRY_RESULT"
		return 0
	fi
	this_node_id=$(_relationship_run_timed mapping _cached_node_id "$this_gh_num" "$repo")
	if [[ -z "$this_node_id" ]]; then
		log_verbose "$task_id: could not resolve node ID for #$this_gh_num"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		_relationship_record_diagnostic "$task_id" "${task_id}->node" "task-node-unresolved"
		_hold_dependency_sync_retry "$this_gh_num" "$repo" "blocked_issue_node_unresolved"
		echo "RELS:0 RETRYABLE:1"
		return 0
	fi
	if [[ -n "$blocked_by" ]]; then
		result=$(_sync_declared_blocked_by_edges "$task_id" "$todo_file" "$repo" "$this_gh_num" "$this_node_id" "$blocked_by")
		IFS=':' read -r edge_rels edge_errors <<<"$result"
		rels_set=$((rels_set + edge_rels)); retryable_errors=$((retryable_errors + edge_errors))
		current_retry_errors="$edge_errors"
	fi
	if [[ -n "$blocks" ]]; then
		result=$(_sync_declared_blocks_edges "$task_id" "$todo_file" "$repo" "$this_gh_num" "$this_node_id" "$blocks")
		IFS=':' read -r edge_rels edge_errors <<<"$result"
		rels_set=$((rels_set + edge_rels)); retryable_errors=$((retryable_errors + edge_errors))
	fi

	if [[ "$current_retry_errors" -gt 0 ]]; then
		_hold_dependency_sync_retry "$this_gh_num" "$repo" "declared_dependency_repair_failed"
	fi
	echo "RELS:$rels_set RETRYABLE:$retryable_errors"
	return 0
}

# Link a single child issue as a sub-issue of a parent issue.
# Resolves task IDs to GitHub node IDs and calls the addSubIssue mutation.
# Arguments:
#   $1 - child_task_id
#   $2 - parent_task_id
#   $3 - todo_file path
#   $4 - repo slug
# Returns: 0 if linked (or would-link in dry-run), 1 if skipped
_link_sub_issue_pair() {
	local child_id="$1" parent_id="$2" todo_file="$3" repo="$4"

	local child_gh_num
	child_gh_num=$(resolve_task_gh_number "$child_id" "$todo_file" "$repo" || true)
	[[ -z "$child_gh_num" ]] && {
		log_verbose "$child_id: no ref:GH# — skipping sub-issue"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		_relationship_record_diagnostic "$child_id" "${child_id}->${parent_id}" "task-mapping-unresolved"
		return 1
	}
	local parent_gh_num
	parent_gh_num=$(resolve_task_gh_number "$parent_id" "$todo_file" "$repo" || true)
	[[ -z "$parent_gh_num" ]] && {
		log_verbose "$child_id: parent $parent_id has no ref:GH# — skipping sub-issue"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		_relationship_record_diagnostic "$child_id" "${child_id}->${parent_id}" "parent-mapping-unresolved"
		return 1
	}

	local child_node_id
	child_node_id=$(_cached_node_id "$child_gh_num" "$repo")
	[[ -z "$child_node_id" ]] && { _relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"; return 1; }
	local parent_node_id
	parent_node_id=$(_cached_node_id "$parent_gh_num" "$repo")
	[[ -z "$parent_node_id" ]] && { _relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"; return 1; }

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would set #$child_gh_num as sub-issue of #$parent_gh_num ($child_id -> $parent_id)"
		return 0
	fi

	if _gh_add_sub_issue "$parent_node_id" "$child_node_id"; then
		log_verbose "$child_id (#$child_gh_num) sub-issue of $parent_id (#$parent_gh_num) ✓"
		return 0
	fi
	return 1
}

# Check if a task ID has the #parent / #parent-task / #meta tag in TODO.md.
# Arguments:
#   $1 - task_id to check
#   $2 - todo_file path
# Returns: 0 if parent-tagged, 1 otherwise
_is_parent_tagged_task() {
	local task_id="$1" todo_file="$2"
	local task_line
	task_line=$(_relationship_task_line "$task_id" "$todo_file")
	[[ -z "$task_line" ]] && return 1

	# Check for #parent, #parent-task, or #meta tags
	if echo "$task_line" | grep -qE '#parent\b|#parent-task\b|#meta\b'; then
		return 0
	fi
	return 1
}

# Sync parent-child (sub-issue) relationships for a task.
# Detects hierarchy through explicit parent metadata, dot notation, or a legacy
# blocked-by edge to a parent-tagged task. Distinct candidates fail closed.
# Arguments:
#   $1 - task_id
#   $2 - todo_file path
#   $3 - repo slug
# Returns: "RELS:N" with count of relationships set
_sync_subtask_hierarchy_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	local rels_set=0 retryable_errors=0
	local key="" value="" dep_task_id="" explicit_parent="" blocked_by=""
	local parent_candidates="" parent_id="" candidate_count=0
	local dot_parent
	dot_parent=$(detect_parent_task_id "$task_id")
	local task_line
	task_line=$(_relationship_task_line "$task_id" "$todo_file")
	if [[ -n "$task_line" ]]; then
		local parsed
		if ! parsed=$(parse_task_line "$task_line"); then
			print_warning "$task_id: invalid parent or dependency metadata"
			_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
			echo "$_RELATIONSHIP_RETRY_RESULT"
			return 0
		fi
		while IFS='=' read -r key value; do
			case "$key" in
			blocked_by) blocked_by="$value" ;;
			parent) explicit_parent="$value" ;;
			esac
		done <<<"$parsed"
	fi

	for parent_id in "$explicit_parent" "$dot_parent"; do
		[[ -n "$parent_id" ]] || continue
		if ! printf '%s' "$parent_candidates" | grep -Fxq -- "$parent_id"; then
			parent_candidates="${parent_candidates}${parent_id}"$'\n'
		fi
	done

	if [[ -n "$blocked_by" ]]; then
		local saved_ifs="$IFS"
		IFS=','
		for dep_task_id in $blocked_by; do
			dep_task_id="${dep_task_id// /}"
			[[ -n "$dep_task_id" ]] || continue
			if _is_parent_tagged_task "$dep_task_id" "$todo_file" &&
				! printf '%s' "$parent_candidates" | grep -Fxq -- "$dep_task_id"; then
				parent_candidates="${parent_candidates}${dep_task_id}"$'\n'
			fi
		done
		IFS="$saved_ifs"
	fi

	candidate_count=$(printf '%s' "$parent_candidates" | grep -cE '.+' || true)
	if [[ "$candidate_count" -gt 1 ]]; then
		print_warning "$task_id: conflicting parent declarations"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		echo "$_RELATIONSHIP_RETRY_RESULT"
		return 0
	fi
	parent_id=$(printf '%s' "$parent_candidates" | grep -E '.+' | head -1 || true)
	[[ -n "$parent_id" ]] || {
		echo "RELS:0 RETRYABLE:0"
		return 0
	}
	if [[ "$parent_id" == "$task_id" ]]; then
		print_warning "$task_id: parent declaration is self-referential"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		echo "$_RELATIONSHIP_RETRY_RESULT"
		return 0
	fi
	if _relationship_deadline_expired; then
		_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
		retryable_errors=$((retryable_errors + 1))
	elif _link_sub_issue_pair "$task_id" "$parent_id" "$todo_file" "$repo"; then
		rels_set=$((rels_set + 1))
	else
		retryable_errors=$((retryable_errors + 1))
	fi

	echo "RELS:$rels_set RETRYABLE:$retryable_errors"
	return 0
}

# Sync all relationships for a single task (blocked-by + subtask hierarchy).
# Convenience wrapper called after push/enrich operations.
# Arguments:
#   $1 - task_id
#   $2 - todo_file path
#   $3 - repo slug
sync_relationships_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	local owns_scope=0
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
	local result="" retryable_total=0 count=""
	result=$(_sync_blocked_by_for_task "$task_id" "$todo_file" "$repo" 2>/dev/null || echo "$_RELATIONSHIP_RETRY_RESULT")
	count=$(echo "$result" | grep -oE 'RETRYABLE:[0-9]+' | head -1 | sed 's/RETRYABLE://' || echo "0")
	retryable_total=$((retryable_total + count))
	if ! _relationship_deadline_expired; then
		result=$(_sync_subtask_hierarchy_for_task "$task_id" "$todo_file" "$repo" 2>/dev/null || echo "$_RELATIONSHIP_RETRY_RESULT")
		count=$(echo "$result" | grep -oE 'RETRYABLE:[0-9]+' | head -1 | sed 's/RETRYABLE://' || echo "0")
		retryable_total=$((retryable_total + count))
	else
		_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
		retryable_total=$((retryable_total + 1))
	fi
	if [[ "$retryable_total" -gt 0 ]] || _relationship_deadline_expired; then
		print_warning "$task_id: relationship sync pending; retry with: .agents/scripts/issue-sync-helper.sh relationships $task_id"
		[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
		return 1
	fi
	[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
	return 0
}

_relationship_prepare_workset() {
	local target_task="$1"
	local todo_file="$2"
	local repo="$3"
	local revision_input="" seen_list=$'\n' line="" tid="" dominated=false task=""
	# Broad reconciliation only needs active work. Explicit single-task sync still
	# repairs completed tasks after publication, but unchanged historical rows do
	# not consume every hosted default-branch pass.
	local todo_line_re='^[[:space:]]*-[[:space:]]+\[[[:space:]>]\][[:space:]]+(t[0-9]+(\.[0-9]+)*)[[:space:]]'
	local tasks=() unique_tasks=()
	_RELATIONSHIP_WORK_TASKS=()
	_RELATIONSHIP_CANDIDATE_TOTAL=0
	_RELATIONSHIP_INPUT_REVISION=""
	_RELATIONSHIP_STATE_FILE=""
	_RELATIONSHIP_RESUME_STATUS="$_RELATIONSHIP_RESUME_FRESH"
	if [[ -n "$target_task" ]]; then
		tasks=("$target_task")
	else
		while IFS= read -r line; do
			[[ "$line" =~ $todo_line_re ]] || continue
			tid="${BASH_REMATCH[1]}"
			dominated=false
			[[ "$line" =~ blocked-by:|blocks:|parent: ]] && dominated=true
			[[ "$tid" == *"."* ]] && dominated=true
			if [[ "$dominated" == "true" ]]; then
				tasks+=("$tid")
				revision_input="${revision_input}${line}"$'\n'
			fi
		done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[.\] t[0-9]+.*ref:GH#[0-9]+' || true)
	fi
	if [[ ${#tasks[@]} -eq 0 ]]; then
		if [[ -z "$target_task" ]]; then
			_RELATIONSHIP_STATE_FILE=$(_relationship_resume_state_file "$repo") || _RELATIONSHIP_STATE_FILE=""
			[[ -z "$_RELATIONSHIP_STATE_FILE" ]] || rm -f "$_RELATIONSHIP_STATE_FILE"
		fi
		return 2
	fi
	for task in "${tasks[@]}"; do
		if [[ "$seen_list" != *$'\n'"$task"$'\n'* ]]; then
			unique_tasks+=("$task")
			seen_list="${seen_list}${task}"$'\n'
		fi
	done
	_RELATIONSHIP_CANDIDATE_TOTAL="${#unique_tasks[@]}"
	_RELATIONSHIP_WORK_TASKS=("${unique_tasks[@]}")
	[[ -n "$target_task" ]] && return 0
	_RELATIONSHIP_INPUT_REVISION=$(printf '%s' "$revision_input" | _relationship_hash_stdin) || return 1
	_RELATIONSHIP_STATE_FILE=$(_relationship_resume_state_file "$repo") || return 1
	_relationship_load_resume_state "$_RELATIONSHIP_STATE_FILE" "$_RELATIONSHIP_INPUT_REVISION"
	if [[ ${#_RELATIONSHIP_RESUME_TASKS[@]} -gt 0 ]]; then
		_RELATIONSHIP_WORK_TASKS=("${_RELATIONSHIP_RESUME_TASKS[@]}")
	fi
	if [[ ${#_RELATIONSHIP_RESUME_SUPPRESSED_TASKS[@]} -gt 0 ]]; then
		local retained_tasks=() suppressed_task="" task_is_suppressed=false
		for task in "${_RELATIONSHIP_WORK_TASKS[@]}"; do
			task_is_suppressed=false
			for suppressed_task in "${_RELATIONSHIP_RESUME_SUPPRESSED_TASKS[@]}"; do
				[[ "$task" == "$suppressed_task" ]] && task_is_suppressed=true && break
			done
			[[ "$task_is_suppressed" == "true" ]] || retained_tasks+=("$task")
		done
		_RELATIONSHIP_WORK_TASKS=("${retained_tasks[@]}")
		_RELATIONSHIP_RESUME_STATUS="suppressed"
	fi
	return 0
}
