#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Resolve a merged PR's task identity from its canonical title or, when the
# title has no tNNN prefix, from one explicit closing issue's unique TODO.md
# ref:GH#NNN mapping. Conflicting and ambiguous identities fail closed.
set -euo pipefail

extract_linked_issues() {
	local pr_body="$1"
	printf '%s' "$pr_body" |
		grep -ioE '\b(close[ds]?|fix(es|ed)?|resolve[ds]?)\b[[:space:]]+#[0-9]+' |
		grep -oE '[0-9]+' |
		sort -u |
		tr '\n' ' ' || true
	return 0
}

task_ids_for_issue() {
	local issue_number="$1"
	local todo_file="$2"
	grep -E "^[[:space:]]*- \[[ x]\] t[0-9]+(\.[0-9]+)* .*ref:GH#${issue_number}([^0-9]|\$)" "$todo_file" 2>/dev/null |
		sed -E 's/^[[:space:]]*- \[[ x]\] (t[0-9]+(\.[0-9]+)*).*/\1/' |
		sort -u || true
	return 0
}

resolve_pr_identity() {
	local pr_title="$1"
	local pr_body="$2"
	local todo_file="$3"
	local title_task_id=""
	local linked_issues=""
	local task_id=""
	local issue_number=""
	local mapped_ids=""
	local mapped_count=0

	title_task_id=$(printf '%s\n' "$pr_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || true)
	linked_issues=$(extract_linked_issues "$pr_body")
	task_id="$title_task_id"

	if [[ -f "$todo_file" ]]; then
		for issue_number in $linked_issues; do
			mapped_ids=$(task_ids_for_issue "$issue_number" "$todo_file")
			mapped_count=$(printf '%s\n' "$mapped_ids" | grep -cE '^t[0-9]+(\.[0-9]+)*$' || true)
			if [[ "$mapped_count" -gt 1 ]]; then
				printf 'ERROR: ref:GH#%s maps to multiple TODO tasks: %s\n' "$issue_number" "$(printf '%s' "$mapped_ids" | tr '\n' ' ')" >&2
				return 1
			fi
			if [[ "$mapped_count" -eq 1 && -n "$title_task_id" && "$mapped_ids" != "$title_task_id" ]]; then
				printf 'ERROR: PR title task %s conflicts with ref:GH#%s mapping to %s\n' "$title_task_id" "$issue_number" "$mapped_ids" >&2
				return 1
			fi
		done
	fi

	if [[ -z "$task_id" && -n "$linked_issues" ]]; then
		local linked_count=0
		linked_count=$(printf '%s\n' "$linked_issues" | grep -oE '[0-9]+' | wc -l | tr -d ' ')
		if [[ "$linked_count" -ne 1 ]]; then
			printf 'ERROR: PR without a canonical task title has %s closing issues; refusing ambiguous TODO identity\n' "$linked_count" >&2
			return 1
		fi
		issue_number=${linked_issues%% *}
		mapped_ids=$(task_ids_for_issue "$issue_number" "$todo_file")
		mapped_count=$(printf '%s\n' "$mapped_ids" | grep -cE '^t[0-9]+(\.[0-9]+)*$' || true)
		if [[ "$mapped_count" -eq 1 ]]; then
			task_id="$mapped_ids"
			printf 'Resolved %s from unique ref:GH#%s TODO mapping\n' "$task_id" "$issue_number" >&2
		fi
	fi

	printf 'task_id=%s\n' "$task_id"
	printf 'linked_issues=%s\n' "$linked_issues"
	return 0
}

main() {
	local command="${1:-}"
	local pr_title="${2:-}"
	local pr_body="${3:-}"
	local todo_file="${4:-TODO.md}"

	if [[ "$command" != "resolve" ]]; then
		printf 'Usage: %s resolve <pr-title> <pr-body> [todo-file]\n' "${0##*/}" >&2
		return 1
	fi
	resolve_pr_identity "$pr_title" "$pr_body" "$todo_file"
	return $?
}

main "$@"
