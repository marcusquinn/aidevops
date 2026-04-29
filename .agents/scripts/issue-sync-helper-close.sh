#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Helper — Close & Reopen Commands
# =============================================================================
# Close helpers (_do_close, evidence checks, PR lookup) plus the cmd_close
# and cmd_reopen entry points.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-helper-close.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, print_success)
#   - issue-sync-lib.sh (_escape_ere, extract_task_block, strip_code_fences,
#     add_gh_ref_to_todo, add_pr_ref_to_todo, sed_inplace)
#   - issue-sync-helper-labels.sh (gh_create_label, _gh_edit_labels,
#     _mark_issue_done, gh_find_issue_by_title, gh_find_merged_pr, gh_list_issues)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_HELPER_CLOSE_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_CLOSE_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Close Helpers
# =============================================================================

# _is_cancelled_or_deferred: returns 0 if the task text indicates it was
# cancelled, deferred, or declined — these states require no PR/verified evidence.
_is_cancelled_or_deferred() {
	local text="$1"
	echo "$text" | grep -qiE 'cancelled:[0-9]{4}-[0-9]{2}-[0-9]{2}|deferred:[0-9]{4}-[0-9]{2}-[0-9]{2}|declined:[0-9]{4}-[0-9]{2}-[0-9]{2}|CANCELLED' && return 0
	return 1
}

_has_evidence() {
	local text="$1" task_id="$2" repo="$3"
	# Cancelled/deferred/declined tasks need no PR or verified: evidence
	_is_cancelled_or_deferred "$text" && return 0
	echo "$text" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}|pr:#[0-9]+' && return 0
	echo "$text" | grep -qiE 'PR #[0-9]+ merged|PR.*merged' && return 0
	[[ -n "$repo" ]] && [[ -n "$(gh_find_merged_pr "$repo" "$task_id")" ]] && return 0
	return 1
}

_find_closing_pr() {
	local text="$1" task_id="$2" repo="$3"
	local pr
	pr=$(echo "$text" | grep -oE 'pr:#[0-9]+|PR #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
	[[ -n "$pr" ]] && {
		echo "${pr}|https://github.com/${repo}/pull/${pr}"
		return 0
	}
	if [[ -n "$repo" ]]; then
		local info
		info=$(gh_find_merged_pr "$repo" "$task_id")
		[[ -n "$info" ]] && {
			echo "$info"
			return 0
		}
		local parent
		parent=$(echo "$task_id" | grep -oE '^t[0-9]+' || echo "")
		[[ -n "$parent" && "$parent" != "$task_id" ]] && {
			info=$(gh_find_merged_pr "$repo" "$parent")
			[[ -n "$info" ]] && {
				echo "$info"
				return 0
			}
		}
	fi
	return 1
}

_close_comment() {
	local task_id="$1" text="$2" pr_num="$3" pr_url="$4"
	# Cancelled/deferred/declined: produce a not-planned comment (no PR needed)
	if _is_cancelled_or_deferred "$text"; then
		local reason
		reason=$(echo "$text" | grep -oiE 'cancelled:[0-9-]+|deferred:[0-9-]+|declined:[0-9-]+|CANCELLED' | head -1 | tr '[:upper:]' '[:lower:]')
		[[ -z "$reason" ]] && reason="cancelled"
		echo "Closing as not planned ($reason). Task $task_id resolved in TODO.md."
		return 0
	fi
	if [[ -n "$pr_num" && -n "$pr_url" ]]; then
		echo "Completed via [PR #${pr_num}](${pr_url}). Task $task_id done in TODO.md."
	elif [[ -n "$pr_num" ]]; then
		echo "Completed via PR #${pr_num}. Task $task_id done in TODO.md."
	else
		local d
		d=$(echo "$text" | grep -oE 'verified:[0-9-]+' | head -1 | sed 's/verified://')
		[[ -n "$d" ]] && echo "Completed (verified: $d). Task $task_id done in TODO.md." || echo "Completed. Task $task_id done in TODO.md."
	fi
}

# Mark a TODO entry as done: [ ] -> [x] with completed: date.
# Also handles [-] (cancelled/declined) entries — leaves marker as [-].
_mark_todo_done() {
	local task_id="$1" todo_file="$2"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")
	local today
	today=$(date -u +%Y-%m-%d)

	# Only flip [ ] -> [x]; skip if already [x] or [-]
	# Use [[:space:]] not \s for macOS sed compatibility (bash 3.2)
	if grep -qE "^[[:space:]]*- \[ \] ${task_id_ere} " "$todo_file" 2>/dev/null; then
		# Flip checkbox and append completed: date
		sed -i.bak -E "s/^([[:space:]]*- )\[ \] (${task_id_ere} .*)/\1[x] \2 completed:${today}/" "$todo_file"
		rm -f "${todo_file}.bak"
		log_verbose "Marked $task_id as [x] in TODO.md"
	fi
	return 0
}

_do_close() {
	local task_id="$1" issue_number="$2" todo_file="$3" repo="$4"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")
	local task_with_notes task_line pr_info pr_num="" pr_url=""
	task_with_notes=$(extract_task_block "$task_id" "$todo_file")
	task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
	[[ -z "$task_with_notes" ]] && task_with_notes="$task_line"

	# GH#20828: probe parent-task label before closing. The workflow path's
	# title-fallback close was guarded by t2137 (issue-sync-reusable.yml:480-484);
	# this is the parallel guard for the bash-helper close path that runs from
	# TODO.md `[x]` pushes. A `parent-task`-labelled issue must stay open until
	# its terminal-phase PR merges with `Closes #NNN` (per the t2046 For/Ref
	# convention). Skip the close + skip status:done; the TODO entry is left
	# unchanged so a human can decide whether the `[x]` was premature or
	# whether the parent should be closed via terminal PR.
	local issue_labels
	issue_labels=$(gh api "repos/${repo}/issues/${issue_number}" --jq '[.labels[].name] | join(" ")' 2>/dev/null || echo "")
	if echo "$issue_labels" | grep -qw "parent-task"; then
		print_info "Skipping #$issue_number ($task_id): parent-task label set — parent issues close via terminal-phase PR with explicit Closes #NNN, not TODO [x] (GH#20828)"
		return 0
	fi

	pr_info=$(_find_closing_pr "$task_with_notes" "$task_id" "$repo" 2>/dev/null || echo "")
	if [[ -n "$pr_info" ]]; then
		pr_num="${pr_info%%|*}"
		pr_url="${pr_info#*|}"
		[[ "$DRY_RUN" != "true" && -n "$pr_num" ]] && add_pr_ref_to_todo "$task_id" "$pr_num" "$todo_file"
		task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
		task_with_notes=$(extract_task_block "$task_id" "$todo_file")
		[[ -z "$task_with_notes" ]] && task_with_notes="$task_line"
	fi

	if [[ "$FORCE_CLOSE" == "true" ]]; then
		print_info "FORCE_CLOSE active — bypassing evidence check for #$issue_number ($task_id) (GH#20146 audit)"
	fi
	if [[ "$FORCE_CLOSE" != "true" ]] && ! _has_evidence "$task_with_notes" "$task_id" "$repo"; then
		print_warning "Skipping #$issue_number ($task_id): no merged PR or verified: field"
		return 1
	fi

	local comment
	comment=$(_close_comment "$task_id" "$task_with_notes" "$pr_num" "$pr_url")
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would close #$issue_number ($task_id)"
		return 0
	fi
	# Cancelled/deferred/declined tasks close as "not planned"; completed tasks use default reason
	local close_args=("issue" "close" "$issue_number" "--repo" "$repo" "--comment" "$comment")
	if _is_cancelled_or_deferred "$task_with_notes"; then
		close_args+=("--reason" "not planned")
		gh_create_label "$repo" "not-planned" "E4E669" "Closed as not planned"
	fi
	if gh "${close_args[@]}" 2>/dev/null; then
		if _is_cancelled_or_deferred "$task_with_notes"; then
			_gh_edit_labels "add" "$repo" "$issue_number" "not-planned"
		fi
		_mark_issue_done "$repo" "$issue_number"
		_mark_todo_done "$task_id" "$todo_file"
		print_success "Closed #$issue_number ($task_id)"
	else
		print_error "Failed to close #$issue_number ($task_id)"
		return 1
	fi
}

# =============================================================================
# cmd_close
# =============================================================================

cmd_close() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"

	# Single-task mode
	if [[ -n "$target_task" ]]; then
		local target_ere
		target_ere=$(_escape_ere "$target_task")
		local task_line
		task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${target_ere} " | head -1 || echo "")
		local num
		num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ -z "$num" ]]; then
			num=$(gh_find_issue_by_title "$repo" "${target_task}:" "open" 500)
			[[ -n "$num" && "$DRY_RUN" != "true" ]] && add_gh_ref_to_todo "$target_task" "$num" "$todo_file"
		fi
		[[ -z "$num" ]] && {
			print_info "$target_task: no matching issue"
			return 0
		}
		local st
		st=$(gh issue view "$num" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "")
		[[ "$st" == "CLOSED" || "$st" == "closed" ]] && {
			log_verbose "#$num already closed"
			return 0
		}
		_do_close "$target_task" "$num" "$todo_file" "$repo" || true
		return 0
	fi

	# Bulk mode: fetch all open issues, build task->issue map
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local map=""
	while IFS='|' read -r n t; do
		[[ -z "$n" ]] && continue
		local tid
		tid=$(echo "$t" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ -n "$tid" ]] && map="${map}${tid}|${n}"$'\n'
	done < <(echo "$open_json" | jq -r '.[] | "\(.number)|\(.title)"' 2>/dev/null || true)
	[[ -z "$map" ]] && {
		print_info "No open issues to close"
		return 0
	}

	local closed=0 skipped=0 ref_fixed=0
	while IFS= read -r line; do
		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue
		local task_id_ere
		task_id_ere=$(_escape_ere "$task_id")
		local mapped
		mapped=$(echo "$map" | grep -E "^${task_id_ere}\|" | head -1 || echo "")
		[[ -z "$mapped" ]] && continue
		local issue_num="${mapped#*|}"
		local ref
		ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ "$DRY_RUN" != "true" ]]; then
			if [[ -n "$ref" && "$ref" != "$issue_num" ]]; then
				fix_gh_ref_in_todo "$task_id" "$ref" "$issue_num" "$todo_file"
				ref_fixed=$((ref_fixed + 1))
			elif [[ -z "$ref" ]]; then
				add_gh_ref_to_todo "$task_id" "$issue_num" "$todo_file"
				ref_fixed=$((ref_fixed + 1))
			fi
		fi
		if _do_close "$task_id" "$issue_num" "$todo_file" "$repo"; then closed=$((closed + 1)); else skipped=$((skipped + 1)); fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[(x|-)\] t[0-9]+' || true)
	print_info "Close: $closed closed, $skipped skipped, $ref_fixed refs fixed"
}

# =============================================================================
# cmd_reopen
# =============================================================================

# Reopen closed GitHub issues whose TODO entries are still open [ ].
# TODO.md is the source of truth: if a task is [ ], the work is not done,
# regardless of whether a commit message prematurely closed the issue.
#
# Decision tree per closed issue:
#   NOT_PLANNED         -> skip (deliberately declined)
#   COMPLETED + has PR  -> skip (work done, TODO needs marking [x] separately)
#   COMPLETED + no PR   -> reopen (premature closure from commit keyword)
cmd_reopen() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"

	# Build set of open issue numbers for fast lookup
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local open_numbers
	open_numbers=$(echo "$open_json" | jq -r '.[].number' 2>/dev/null | sort -n)

	local stripped
	stripped=$(strip_code_fences <"$todo_file")
	local reopened=0 skipped=0 not_planned=0 has_pr=0

	while IFS= read -r line; do
		local ref_num
		ref_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		[[ -z "$ref_num" ]] && continue

		# Skip if already open
		echo "$open_numbers" | grep -qx "$ref_num" && continue

		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")

		# Check closure reason — skip NOT_PLANNED (deliberately declined)
		local reason
		reason=$(gh issue view "$ref_num" --repo "$repo" --json stateReason --jq '.stateReason' 2>/dev/null || echo "")
		if [[ "$reason" == "NOT_PLANNED" ]]; then
			log_verbose "#$ref_num ($tid) closed as NOT_PLANNED — skipping"
			not_planned=$((not_planned + 1))
			continue
		fi

		# Check if a merged PR exists for this task — if so, the closure is
		# legitimate (work done). Mark TODO [x] with pr:# instead of reopening.
		local pr_info
		pr_info=$(gh_find_merged_pr "$repo" "$tid" 2>/dev/null || echo "")
		if [[ -n "$pr_info" ]]; then
			local pr_num="${pr_info%%|*}"
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would mark $tid [x] (merged PR #$pr_num)"
			else
				add_pr_ref_to_todo "$tid" "$pr_num" "$todo_file" 2>/dev/null || true
				_mark_todo_done "$tid" "$todo_file"
				log_verbose "#$ref_num ($tid) has merged PR #$pr_num — marked TODO [x]"
			fi
			has_pr=$((has_pr + 1))
			continue
		fi

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would reopen #$ref_num ($tid)"
			reopened=$((reopened + 1))
			continue
		fi

		gh issue reopen "$ref_num" --repo "$repo" \
			--comment "Reopened: TODO.md still has this as \`[ ]\` (open) and no merged PR was found. The issue was prematurely closed by a commit keyword. TODO.md is the source of truth for task state." 2>/dev/null && {
			reopened=$((reopened + 1))
			print_success "Reopened #$ref_num ($tid)"
		} || {
			skipped=$((skipped + 1))
			print_warning "Failed to reopen #$ref_num ($tid)"
		}
	done < <(echo "$stripped" | grep -E '^\s*- \[ \] t[0-9]+.*ref:GH#[0-9]+' || true)

	print_info "Reopen: $reopened reopened, $skipped failed, $not_planned not-planned, $has_pr have-merged-pr"
	return 0
}
