#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Helper — Push Command
# =============================================================================
# Issue creation from TODO.md: build task list, auto-assign, create issue,
# collision detection, and the cmd_push entry point.
#
# Note: _push_process_task is kept in the orchestrator (issue-sync-helper.sh)
# to preserve its (file, fname) identity key for the function-complexity gate.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-helper-push.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, print_success,
#     session_origin_label)
#   - issue-sync-lib.sh (strip_code_fences, add_gh_ref_to_todo, parse_task_line,
#     map_tags_to_labels, compose_issue_body, _extract_tier_from_brief,
#     _validate_tier_checklist, sync_relationships_for_task,
#     _parent_body_has_phase_markers, _post_parent_task_no_markers_warning)
#   - issue-sync-helper-labels.sh (ensure_labels_exist, gh_create_label,
#     gh_find_issue_by_title, gh_find_merged_pr, _apply_tier_label_replace)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_HELPER_PUSH_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_PUSH_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Push Helpers
# =============================================================================

# _push_build_task_list: populate tasks array from target or full TODO.md scan.
# Outputs one task ID per line to stdout; caller reads into array.
_push_build_task_list() {
	local target_task="$1" todo_file="$2"
	if [[ -n "$target_task" ]]; then
		echo "$target_task"
		return 0
	fi
	while IFS= read -r line; do
		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -n "$tid" ]] && ! echo "$line" | grep -qE 'ref:GH#[0-9]+' && echo "$tid"
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[ \] t[0-9]+' || true)
	return 0
}

# _push_auto_assign_interactive: self-assign issue to the current user when
# origin is interactive and the task is NOT flagged for worker dispatch.
# t2157: skips assignment when auto-dispatch is in all_labels — the user said
# "let a worker handle it"; assigning the pusher creates the blocking combo
# (origin:interactive + assigned + active status) per GH#18352/t1996.
# t1970: eliminates the race where Maintainer Gate fires before self-assign.
# t1984: uses AIDEVOPS_SESSION_USER when set (workflow env -> github.actor).
_push_auto_assign_interactive() {
	local num="$1" repo="$2" all_labels="$3"
	# t2157: skip when auto-dispatch tag present — issue is worker-owned
	if [[ ",${all_labels}," == *",auto-dispatch,"* ]]; then
		print_info "Skipping auto-assign for #${num} — auto-dispatch entry is worker-owned (t2157)"
		return 0
	fi
	local current_user="${AIDEVOPS_SESSION_USER:-}"
	if [[ -z "$current_user" ]]; then
		# GH#18591: cache gh api user to avoid repeated API calls in loops.
		if [[ -z "${_CACHED_GH_USER:-}" ]]; then
			_CACHED_GH_USER=$(gh api user --jq '.login // ""' 2>/dev/null || echo "")
		fi
		current_user="$_CACHED_GH_USER"
	fi
	if [[ -n "$current_user" ]]; then
		if gh issue edit "$num" --repo "$repo" --add-assignee "$current_user" >/dev/null 2>&1; then
			print_info "Auto-assigned #${num} to @${current_user} (origin:interactive)"
		else
			print_warning "Could not self-assign #${num} — assign manually to unblock Maintainer Gate"
		fi
	fi
	return 0
}

# _push_create_issue: create a GitHub issue for task_id with race-condition guard.
# Sets _PUSH_CREATED_NUM on success (empty on failure/skip).
# Returns 0=created, 1=skipped (race), 2=error.
_push_create_issue() {
	local task_id="$1" repo="$2" todo_file="$3" title="$4" body="$5" labels="$6" assignee="$7"
	_PUSH_CREATED_NUM=""

	[[ -n "$labels" ]] && ensure_labels_exist "$labels" "$repo"
	local status_label="status:available"
	[[ -n "$assignee" ]] && {
		status_label="status:claimed"
		gh_create_label "$repo" "status:claimed" "D93F0B" "Task is claimed"
	}
	# Add session origin label (origin:worker or origin:interactive)
	local origin_label
	origin_label=$(session_origin_label)
	gh_create_label "$repo" "$origin_label" "C5DEF5" "Created from ${origin_label#origin:} session"
	local all_labels="${labels:+${labels},}${status_label},${origin_label}"

	# cool — belt-and-suspenders race guard right before creation
	local recheck
	recheck=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
	if [[ -n "$recheck" && "$recheck" != "null" ]]; then
		add_gh_ref_to_todo "$task_id" "$recheck" "$todo_file"
		return 1
	fi

	local -a args=("issue" "create" "--repo" "$repo" "--title" "$title" "--body" "$body" "--label" "$all_labels")
	[[ -n "$assignee" ]] && args+=("--assignee" "$assignee")

	# GH#15234 Fix 1: gh issue create may return empty stdout (e.g. when label
	# application fails after issue creation) while still creating the issue
	# server-side. Treat empty URL or non-zero exit as a soft failure and attempt
	# a recovery lookup before declaring an error. Stderr is merged into the
	# combined output for diagnostics without requiring a temp file.
	local url gh_exit combined
	{
		combined=$(gh "${args[@]}" 2>&1)
		gh_exit=$?
	} || true
	# Extract URL from combined output (stdout URL appears first on success)
	url=$(echo "$combined" | grep -oE 'https://github\.com/[^ ]+/issues/[0-9]+' | head -1 || echo "")

	if [[ $gh_exit -ne 0 || -z "$url" ]]; then
		# Issue may have been created despite the error — check before failing.
		# Brief pause for API consistency before the recovery lookup.
		sleep 1
		local recovery
		recovery=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
		if [[ -n "$recovery" && "$recovery" != "null" ]]; then
			print_warning "gh create exited $gh_exit but issue found via recovery: #$recovery"
			log_verbose "gh output: ${combined:0:200}"
			_PUSH_CREATED_NUM="$recovery"
			return 0
		fi
		print_error "Failed to create issue for $task_id (exit $gh_exit): ${combined:0:200}"
		return 2
	fi

	local num
	num=$(echo "$url" | grep -oE '[0-9]+$' || echo "")
	[[ -n "$num" ]] && _PUSH_CREATED_NUM="$num"

	# t1970/t1984/t2157: auto-assign interactive origin issues (not auto-dispatch).
	# Worker issues follow status:claimed + pulse-managed assignment instead.
	[[ -n "$num" && -z "$assignee" && "$origin_label" == "origin:interactive" ]] &&
		_push_auto_assign_interactive "$num" "$repo" "$all_labels"

	# Lock maintainer/worker-created issues at creation to prevent
	# comment prompt-injection across the entire issue lifecycle.
	if [[ -n "$num" ]]; then
		local _lock_owner="${repo%%/*}"
		local _lock_user="${AIDEVOPS_SESSION_USER:-}"
		[[ -z "$_lock_user" ]] && _lock_user=$(gh api user --jq '.login // ""' 2>/dev/null || echo "")
		if [[ -n "$_lock_user" && "$_lock_user" == "$_lock_owner" ]] ||
			[[ "$origin_label" == "origin:worker" ]]; then
			gh issue lock "$num" --repo "$repo" --reason "resolved" >/dev/null 2>&1 || true
		fi
	fi
	return 0
}

# GH#18041 (t1957): Collision detection — warn if a merged PR already uses
# this task ID. This catches task ID reuse (counter reset, fabricated IDs)
# before the issue is created, preventing permanent dispatch blocks.
# Extracted from _push_process_task to keep that function under the 100-line
# complexity gate (t2377 refactor).
_push_warn_if_task_id_collides() {
	local repo="$1" task_id="$2"
	local collision_pr
	collision_pr=$(gh_find_merged_pr "$repo" "$task_id")
	if [[ -n "$collision_pr" ]]; then
		local collision_num="${collision_pr%%|*}"
		local collision_url="${collision_pr#*|}"
		print_warning "TASK ID COLLISION: ${task_id} already used by merged PR #${collision_num} (${collision_url}). This issue will be blocked by the dedup guard. Re-ID the task with claim-task-id.sh."
	fi
	return 0
}

# =============================================================================
# cmd_push
# =============================================================================

cmd_push() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO" project_root="$_CMD_ROOT"

	# Guard: issue creation from TODO.md should only happen in ONE place to
	# prevent duplicates. CI (GitHub Actions issue-sync.yml) is the single
	# authority for bulk push. Local sessions use claim-task-id.sh (which
	# creates issues at claim time) or target a single task explicitly.
	#
	# The race condition: when TODO.md merges to main, both CI and local
	# pulse/supervisor run "push" simultaneously. Both see "no existing issue"
	# and both create one — producing duplicates (observed: t1365, t1366,
	# t1367, t1370.x, t1375.x all had duplicate issues).
	#
	# Fix: bulk push (no target_task) is CI-only unless --force-push is passed.
	# Single-task push (claim-task-id.sh path) is always allowed.
	if [[ -z "$target_task" && "${GITHUB_ACTIONS:-}" != "true" && "$FORCE_PUSH" != "true" ]]; then
		print_info "Bulk push skipped — CI is the single authority for issue creation from TODO.md"
		print_info "Use 'issue-sync-helper.sh push <task_id>' for single tasks, or --force-push to override"
		return 0
	fi
	if [[ "$FORCE_PUSH" == "true" && -z "$target_task" ]]; then
		print_info "FORCE_PUSH active — bypassing CI-only gate for bulk push (GH#20146 audit)"
	fi

	local tasks=()
	while IFS= read -r tid; do
		[[ -n "$tid" ]] && tasks+=("$tid")
	done < <(_push_build_task_list "$target_task" "$todo_file")

	[[ ${#tasks[@]} -eq 0 ]] && {
		print_info "No tasks to push"
		return 0
	}

	print_info "Processing ${#tasks[@]} task(s) for push to $repo"
	gh_create_label "$repo" "status:available" "0E8A16" "Task is available for claiming"

	local created=0 skipped=0
	for task_id in "${tasks[@]}"; do
		local result
		result=$(_push_process_task "$task_id" "$repo" "$todo_file" "$project_root")
		[[ "$result" == *"CREATED"* ]] && created=$((created + 1))
		[[ "$result" == *"SKIPPED"* ]] && skipped=$((skipped + 1))
	done
	print_info "Push complete: $created created, $skipped skipped"
	return 0
}
