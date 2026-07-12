#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/task-coordinator.mjs"

main() {
	local mode="${1:-reconcile}"
	local limit="${AIDEVOPS_RECONCILE_MAX_ISSUES:-100}"
	local targets="" row="" number="" subject_id="" task_id="" updated_at="" state="" action="" operation_id=""
	[[ "$mode" == "reconcile" || "$mode" == "audit" ]] || return 1
	[[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 1 && "$limit" -le 500 ]] || return 1
	targets=$(node "$COORDINATOR" reconciliation-targets --repository-id "${REPOSITORY_ID:?}" --limit "$limit") || return 1
	while IFS= read -r row; do
		number=$(jq -r '.displayNumber' <<<"$row")
		subject_id=$(jq -r '.subjectId' <<<"$row")
		task_id=$(jq -r '.taskId' <<<"$row")
		row=$(gh api "repos/${REPOSITORY_SLUG}/issues/${number}") || return 1
		updated_at=$(jq -r '.updated_at' <<<"$row")
		state=$(jq -r '.state' <<<"$row")
		[[ "$state" == "closed" ]] && action="closed" || action="edited"
		[[ "$mode" == "audit" ]] && continue
		operation_id="reconcile-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${number}"
		node "$COORDINATOR" forge-event --operation-id "$operation_id" --delivery-id "$operation_id" \
			--cursor-tiebreaker "$operation_id" --repository-id "$REPOSITORY_ID" --repository-slug "$REPOSITORY_SLUG" \
			--repository-path "${REPOSITORY_PATH:-}" --task-id "$task_id" --event-kind issue --action "$action" \
			--subject-id "$subject_id" --cursor "$updated_at" >/dev/null || return 1
	done < <(jq -c '.targets[]' <<<"$targets")
	return 0
}

main "$@"
