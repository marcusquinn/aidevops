#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

collect_effective_issues() {
	local todo_file="$1"
	local issue_numbers="$2"
	local vetoed_issue_numbers="$3"
	local issue_number=""
	local matches=""

	for issue_number in $issue_numbers; do
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
			printf 'ERROR: invalid closing issue number: %s\n' "$issue_number" >&2
			return 1
		fi
		if [[ " $vetoed_issue_numbers " == *" $issue_number "* ]]; then
			continue
		fi
		RESOLVED_EFFECTIVE_ISSUES="${RESOLVED_EFFECTIVE_ISSUES}${RESOLVED_EFFECTIVE_ISSUES:+ }${issue_number}"
		matches=$(grep -E "^[[:space:]]*- \[[ x]\] t[0-9]+(\.[0-9]+)* .*ref:GH#${issue_number}([[:space:]]|$)" "$todo_file" || true)
		if [[ -n "$matches" ]]; then
			RESOLVED_TASK_BACKED="true"
		fi
	done
	return 0
}

map_issue_tasks() {
	local todo_file="$1"
	local effective_issues="$2"
	local issue_number=""
	local matches=""
	local match_count="0"
	local task_id=""

	for issue_number in $effective_issues; do
		matches=$(grep -E "^[[:space:]]*- \[[ x]\] t[0-9]+(\.[0-9]+)* .*ref:GH#${issue_number}([[:space:]]|$)" "$todo_file" || true)
		match_count=$(printf '%s\n' "$matches" | grep -c . || true)
		if [[ "$match_count" -eq 0 ]]; then
			printf 'ERROR: closing issue #%s has no exact ref:GH#%s TODO mapping\n' "$issue_number" "$issue_number" >&2
			return 1
		fi
		if [[ "$match_count" -ne 1 ]]; then
			printf 'ERROR: closing issue #%s has %s ref:GH#%s TODO mappings; expected exactly one\n' "$issue_number" "$match_count" "$issue_number" >&2
			return 1
		fi
		if ! [[ "$matches" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]x]\][[:space:]]+(t[0-9]+(\.[0-9]+)*) ]]; then
			printf 'ERROR: closing issue #%s has an invalid TODO mapping\n' "$issue_number" >&2
			return 1
		fi
		task_id="${BASH_REMATCH[1]}"
		RESOLVED_ISSUE_TASK_PAIRS="${RESOLVED_ISSUE_TASK_PAIRS}${RESOLVED_ISSUE_TASK_PAIRS:+ }${issue_number}:${task_id}"
		if [[ " $RESOLVED_TASK_IDS " != *" $task_id "* ]]; then
			RESOLVED_TASK_IDS="${RESOLVED_TASK_IDS}${RESOLVED_TASK_IDS:+ }${task_id}"
		fi
	done
	return 0
}

resolve_pr_task_ids() {
	local todo_file="$1"
	local issue_numbers="$2"
	local title_task_id="$3"
	local vetoed_issue_numbers="$4"
	RESOLVED_TASK_IDS=""
	RESOLVED_EFFECTIVE_ISSUES=""
	RESOLVED_TASK_BACKED="false"
	RESOLVED_ISSUE_TASK_PAIRS=""

	if [[ ! -f "$todo_file" ]]; then
		printf 'ERROR: TODO file not found: %s\n' "$todo_file" >&2
		return 1
	fi
	collect_effective_issues "$todo_file" "$issue_numbers" "$vetoed_issue_numbers" || return 1
	if [[ -n "$title_task_id" ]]; then
		RESOLVED_TASK_BACKED="true"
	fi
	if [[ "$RESOLVED_TASK_BACKED" == "true" ]]; then
		map_issue_tasks "$todo_file" "$RESOLVED_EFFECTIVE_ISSUES" || return 1
	fi

	if [[ -n "$title_task_id" && " $RESOLVED_TASK_IDS " != *" $title_task_id "* ]]; then
		printf 'ERROR: PR title task %s conflicts with closing-issue TODO mapping(s): %s\n' "$title_task_id" "$RESOLVED_TASK_IDS" >&2
		return 1
	fi

	printf '%s|%s|%s|%s\n' "$RESOLVED_TASK_IDS" "$RESOLVED_EFFECTIVE_ISSUES" "$RESOLVED_TASK_BACKED" "$RESOLVED_ISSUE_TASK_PAIRS"
	return 0
}

main() {
	local todo_file="${1:-}"
	local issue_numbers="${2:-}"
	local title_task_id="${3:-}"
	local vetoed_issue_numbers="${4:-}"
	resolve_pr_task_ids "$todo_file" "$issue_numbers" "$title_task_id" "$vetoed_issue_numbers"
	return $?
}

main "$@"
