#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit Bookkeeping -- closed-issue completion-bookkeeping validators
# =============================================================================
# Focused sub-library for full-loop-helper-commit.sh (GH#31068 split). Holds the
# narrow t2091 completion-bookkeeping exception: request validation, merged
# proof-PR verification, metadata-only diff checks, TODO.md proof checks and the
# non-closing PR body check. Function names and globals are unchanged.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-commit-bookkeeping.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_success, detect_session_origin,
#     _gh_current_user_allows_repo_write)
#   - full-loop-helper-risk.sh (_pending_runtime_comparison_base)
#   - Globals: _FULL_LOOP_TRUE, HEADLESS
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_COMMIT_BOOKKEEPING_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_BOOKKEEPING_LIB_LOADED=1
FULL_LOOP_COMPLETION_BOOKKEEPING_AUDIT=""
FULL_LOOP_COMPLETION_BOOKKEEPING_FILES=""

# Validate the explicit option set before commit-and-pr mutates local history.
# The deeper terminal-state, proof, and diff checks run again immediately before
# push so a late issue-state race cannot bypass the t2091 guard.
_validate_completion_bookkeeping_request() {
	local enabled="$1"
	local proof_pr="$2"
	local task_id="$3"
	local allow_parent_close="$4"
	local repo_slug="$5"
	shift 5
	local -a labels=("$@")

	if [[ "$enabled" -ne 1 ]]; then
		if [[ -n "$proof_pr" || -n "$task_id" ]]; then
			print_error "--proof-pr and --task-id require the explicit --completion-bookkeeping mode"
			return 1
		fi
		return 0
	fi

	if [[ ! "$proof_pr" =~ ^[0-9]+$ || "$proof_pr" -eq 0 ]]; then
		print_error "Completion bookkeeping requires --proof-pr with a positive PR number"
		return 1
	fi
	if [[ ! "$task_id" =~ ^t[0-9]+([.][0-9]+)*$ ]]; then
		print_error "Completion bookkeeping requires --task-id in canonical tNNN form"
		return 1
	fi
	if [[ "$allow_parent_close" -eq 1 ]]; then
		print_error "Completion bookkeeping is non-closing; --allow-parent-close is forbidden"
		return 1
	fi

	# #aidevops:trust-boundary — this exception is never available to workers or
	# CI, even if an origin override tries to classify the session as interactive.
	if [[ "${HEADLESS:-false}" == "$_FULL_LOOP_TRUE" || "${FULL_LOOP_HEADLESS:-}" == "$_FULL_LOOP_TRUE" ||
		"${AIDEVOPS_HEADLESS:-}" == "$_FULL_LOOP_TRUE" || "${OPENCODE_HEADLESS:-}" == "$_FULL_LOOP_TRUE" ||
		"${CLAUDE_HEADLESS:-}" == "$_FULL_LOOP_TRUE" || "${GITHUB_ACTIONS:-}" == "$_FULL_LOOP_TRUE" ||
		-n "${WORKER_ISSUE_NUMBER:-}" || -n "${WORKER_REPO_SLUG:-}" ||
		"$(detect_session_origin)" != "interactive" ]]; then
		print_error "Completion bookkeeping is restricted to interactive maintainer sessions"
		return 1
	fi

	local label=""
	for label in "${labels[@]+"${labels[@]}"}"; do
		if [[ "$label" == origin:* ]]; then
			print_error "Completion bookkeeping rejects caller-supplied origin labels; exactly origin:interactive is injected and verified"
			return 1
		fi
	done

	if ! declare -F _gh_current_user_allows_repo_write >/dev/null 2>&1 ||
		! _gh_current_user_allows_repo_write "$repo_slug"; then
		print_error "Completion bookkeeping requires verified maintainer-equivalent repository permission"
		return 1
	fi
	return 0
}

_completion_bookkeeping_body_has_reference() {
	local body="$1"
	local issue_number="$2"
	grep -Eiq \
		"(^|[[:space:]])(for|ref|close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#${issue_number}([^0-9]|$)" <<<"$body"
	return $?
}

_completion_bookkeeping_body_has_closing_reference() {
	local body="$1"
	local issue_number="$2"
	grep -Eiq \
		"(^|[[:space:]])(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#${issue_number}([^0-9]|$)" <<<"$body"
	return $?
}

_verify_completion_bookkeeping_proof() {
	local issue_number="$1"
	local repo_slug="$2"
	local proof_pr="$3"
	local task_id="$4"
	local proof_json=""
	local proof_title=""
	local proof_body=""

	proof_json=$(gh api "repos/${repo_slug}/pulls/${proof_pr}" \
		--jq '{number, state, merged_at, title, body}' 2>/dev/null) || {
		print_error "Completion bookkeeping could not verify proof PR #${proof_pr}"
		return 1
	}
	if ! printf '%s' "$proof_json" | jq -e --argjson proof "$proof_pr" \
		'.number == $proof and .state == "closed" and ((.merged_at // "") | length) > 0' >/dev/null 2>&1; then
		print_error "Completion bookkeeping proof PR #${proof_pr} is not verified merged"
		return 1
	fi
	proof_title=$(printf '%s' "$proof_json" | jq -r '.title // ""') || return 1
	proof_body=$(printf '%s' "$proof_json" | jq -r '.body // ""') || return 1
	if [[ "$proof_title" != "${task_id}:"* && "$proof_title" != "GH#${issue_number}:"* ]]; then
		print_error "Completion bookkeeping proof PR #${proof_pr} does not match task ${task_id} or issue #${issue_number}"
		return 1
	fi
	if ! _completion_bookkeeping_body_has_reference "$proof_body" "$issue_number"; then
		print_error "Completion bookkeeping proof PR #${proof_pr} does not reference issue #${issue_number}"
		return 1
	fi
	return 0
}

_validate_completion_bookkeeping_paths() {
	local task_id="$1"
	local base_ref="$2"
	local changed_files=""
	local deleted_files=""
	local changed_file=""
	local changed_count=0
	local todo_changed=0
	local comparison_base=""

	comparison_base=$(_pending_runtime_comparison_base "$base_ref") || return 1
	changed_files=$(git diff --name-only "$comparison_base" HEAD) || {
		print_error "Completion bookkeeping could not inspect the final diff"
		return 1
	}
	while IFS= read -r changed_file; do
		[[ -z "$changed_file" ]] && continue
		changed_count=$((changed_count + 1))
		case "$changed_file" in
		TODO.md)
			todo_changed=1
			;;
		"todo/tasks/${task_id}-brief.md") ;;
		*)
			print_error "Completion bookkeeping rejects non-metadata path: ${changed_file}"
			return 1
			;;
		esac
	done <<<"$changed_files"
	if [[ "$changed_count" -eq 0 || "$todo_changed" -ne 1 ]]; then
		print_error "Completion bookkeeping requires a TODO.md completion-proof diff"
		return 1
	fi
	deleted_files=$(git diff --name-only --diff-filter=D "$comparison_base" HEAD) || return 1
	if [[ -n "$deleted_files" ]]; then
		print_error "Completion bookkeeping may not delete completion metadata files: ${deleted_files//$'\n'/, }"
		return 1
	fi
	FULL_LOOP_COMPLETION_BOOKKEEPING_FILES="${changed_files//$'\n'/, }"
	return 0
}

_validate_completion_bookkeeping_todo() {
	local issue_number="$1"
	local proof_pr="$2"
	local task_id="$3"
	local base_ref="$4"
	local repo_root=""
	local todo_file=""
	local task_pattern=""
	local issue_mapping_lines=""
	local issue_mapping_count=0
	local completion_line=""
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
	todo_file="${repo_root}/TODO.md"
	if [[ -z "$repo_root" || ! -f "$todo_file" ]]; then
		print_error "Completion bookkeeping requires TODO.md at the repository root"
		return 1
	fi
	task_pattern="${task_id//./\\.}"
	issue_mapping_lines=$(grep -E \
		"^[[:blank:]]*- \[[ x]\] t[0-9]+([.][0-9]+)* .*ref:GH#${issue_number}([^0-9]|$)" \
		"$todo_file" 2>/dev/null || true)
	issue_mapping_count=$(printf '%s\n' "$issue_mapping_lines" | grep -c . || true)
	if [[ "$issue_mapping_count" -ne 1 ]]; then
		print_error "Completion bookkeeping requires exactly one final TODO.md mapping for issue #${issue_number}; found ${issue_mapping_count}"
		return 1
	fi
	completion_line="$issue_mapping_lines"
	if ! grep -Eq \
		"^[[:blank:]]*- \[x\] ${task_pattern}([[:space:]]|$)" <<<"$completion_line" ||
		! grep -Eq "pr:#${proof_pr}([^0-9]|$)" <<<"$completion_line" ||
		! grep -Eq 'completed:[0-9]{4}-[0-9]{2}-[0-9]{2}([^0-9]|$)' <<<"$completion_line"; then
		print_error "Completion bookkeeping TODO.md proof must complete ${task_id} with merged PR #${proof_pr}"
		return 1
	fi

	local todo_patch=""
	local patch_line=""
	local patch_payload=""
	local comparison_base=""
	comparison_base=$(_pending_runtime_comparison_base "$base_ref") || return 1
	todo_patch=$(git diff --unified=0 "$comparison_base" HEAD -- TODO.md) || return 1
	if [[ -z "$todo_patch" ]]; then
		print_error "Completion bookkeeping found no TODO.md changes against ${base_ref}"
		return 1
	fi
	while IFS= read -r patch_line; do
		case "$patch_line" in
		diff\ --git* | index* | @@* | ---* | +++* | \\*)
			continue
			;;
		+* | -*)
			patch_payload="${patch_line:1}"
			[[ "$patch_payload" =~ ^[[:space:]]*$ ]] && continue
			if ! grep -Eq \
				"^[[:blank:]]*- \[[ x]\] ${task_pattern}([[:space:]]|$)" <<<"$patch_payload"; then
				print_error "Completion bookkeeping TODO.md diff changes content outside task ${task_id}"
				return 1
			fi
			;;
		esac
	done <<<"$todo_patch"
	return 0
}

_validate_completion_bookkeeping_pr_body() {
	local issue_number="$1"
	local pr_body="$2"
	if _completion_bookkeeping_body_has_closing_reference "$pr_body" "$issue_number"; then
		print_error "Completion bookkeeping PR body contains a closing keyword for issue #${issue_number}"
		return 1
	fi
	if ! grep -Eiq \
		"(^|[[:space:]])(for|ref)[[:space:]]*:?[[:space:]]*#${issue_number}([^0-9]|$)" <<<"$pr_body"; then
		print_error "Completion bookkeeping PR body must use For/Ref #${issue_number}"
		return 1
	fi
	return 0
}

# Authorize the narrow t2091 exception against fresh terminal-state, merged-PR,
# task-identity, path, and generated-body evidence. Runs immediately before push.
_validate_closed_issue_completion_bookkeeping() {
	local issue_number="$1"
	local repo_slug="$2"
	local state_reason="$3"
	local proof_pr="$4"
	local task_id="$5"
	local base_ref="$6"
	local pr_body="$7"
	local normalized_reason=""

	normalized_reason=$(printf '%s' "$state_reason" | tr '[:lower:]-' '[:upper:]_') || return 1
	case "$normalized_reason" in
	COMPLETED | NOT_PLANNED) ;;
	*)
		print_error "Completion bookkeeping requires terminal issue reason COMPLETED or NOT_PLANNED; found ${state_reason:-missing}"
		return 1
		;;
	esac

	_verify_completion_bookkeeping_proof "$issue_number" "$repo_slug" "$proof_pr" "$task_id" || return 1
	_validate_completion_bookkeeping_paths "$task_id" "$base_ref" || return 1
	_validate_completion_bookkeeping_todo "$issue_number" "$proof_pr" "$task_id" "$base_ref" || return 1
	_validate_completion_bookkeeping_pr_body "$issue_number" "$pr_body" || return 1

	FULL_LOOP_COMPLETION_BOOKKEEPING_AUDIT="terminal issue #${issue_number} (${normalized_reason}); merged proof PR #${proof_pr}; task ${task_id}; allowed files: ${FULL_LOOP_COMPLETION_BOOKKEEPING_FILES}; non-closing reference: For #${issue_number}"
	print_success "Completion-bookkeeping audit: ${FULL_LOOP_COMPLETION_BOOKKEEPING_AUDIT}"
	return 0
}
