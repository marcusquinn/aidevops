#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/task-coordinator.mjs"

main() {
	local event_kind="${EVENT_NAME:-}"
	local number="${EVENT_DISPLAY_NUMBER:-}"
	local subject_id="${EVENT_SUBJECT_ID:-}"
	local task_id="" issue_json="" issue_id="" issue_number="" issue_state="" issue_cursor=""
	[[ "$event_kind" == "issues" ]] || return 0
	[[ "$number" =~ ^[1-9][0-9]*$ && -n "$subject_id" ]] || return 1
	task_id=$(grep -E "^[[:space:]]*- \[[ x]\] t[1-9][0-9]*(\.[1-9][0-9]*)* .*ref:GH#${number}([[:space:]]|$)" TODO.md 2>/dev/null |
		grep -oE 't[1-9][0-9]*(\.[1-9][0-9]*)*' | head -1 || true)
	[[ -n "$task_id" ]] || return 0
	issue_json=$(gh issue view "$number" --repo "${REPOSITORY_SLUG:?}" --json id,number,state,updatedAt) || return 1
	issue_id=$(jq -r '.id // empty' <<<"$issue_json")
	issue_number=$(jq -r '.number // empty' <<<"$issue_json")
	issue_state=$(jq -r '.state // empty' <<<"$issue_json")
	issue_cursor=$(jq -r '.updatedAt // empty' <<<"$issue_json")
	[[ "$issue_id" == "$subject_id" && "$issue_number" == "$number" ]] || return 1
	node "$COORDINATOR" bind-issue --task-id "$task_id" --forge github --repository-id "${REPOSITORY_ID:?}" \
		--repository-slug "$REPOSITORY_SLUG" --role home --issue-id "$issue_id" --display-number "$issue_number" \
		--state-cursor "$issue_cursor" --sync-metadata "$(jq -cn --arg state "$issue_state" --arg source event-ref-backfill '{state:$state,source:$source}')" >/dev/null || return 1
	return 0
}

main "$@"
