#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

resolve_pr_task_ids() {
	local todo_file="$1"
	local issue_numbers="$2"
	local title_task_id="$3"
	local vetoed_issue_numbers="$4"
	local issue_number=""
	local matches=""
	local match_count="0"
	local task_id=""
	local task_ids=""
	local effective_issues=""
	local task_backed="false"
	local issue_task_pairs=""

	if [[ ! -f "$todo_file" ]]; then
		printf 'ERROR: TODO file not found: %s\n' "$todo_file" >&2
		return 1
	fi
	for issue_number in $issue_numbers; do
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
			printf 'ERROR: invalid closing issue number: %s\n' "$issue_number" >&2
			return 1
		fi
		if [[ " $vetoed_issue_numbers " == *" $issue_number "* ]]; then
			continue
		fi
		effective_issues="${effective_issues}${effective_issues:+ }${issue_number}"
		matches=$(grep -E "^[[:space:]]*- \[[ x]\] t[0-9]+(\.[0-9]+)* .*ref:GH#${issue_number}([[:space:]]|$)" "$todo_file" || true)
		match_count=$(printf '%s\n' "$matches" | grep -c . || true)
		if [[ "$match_count" -gt 0 ]]; then
			task_backed="true"
		fi
	done

	if [[ -n "$title_task_id" ]]; then
		task_backed="true"
	fi

	if [[ "$task_backed" == "true" ]]; then
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
			task_id=$(printf '%s\n' "$matches" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			issue_task_pairs="${issue_task_pairs}${issue_task_pairs:+ }${issue_number}:${task_id}"
			if [[ " $task_ids " != *" $task_id "* ]]; then
				task_ids="${task_ids}${task_ids:+ }${task_id}"
			fi
		done
	fi

	if [[ -n "$title_task_id" && " $task_ids " != *" $title_task_id "* ]]; then
		printf 'ERROR: PR title task %s conflicts with closing-issue TODO mapping(s): %s\n' "$title_task_id" "$task_ids" >&2
		return 1
	fi

	printf '%s|%s|%s|%s\n' "$task_ids" "$effective_issues" "$task_backed" "$issue_task_pairs"
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
