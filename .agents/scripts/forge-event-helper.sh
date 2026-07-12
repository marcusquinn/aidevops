#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/task-coordinator.mjs"

main() {
	local event_kind="${EVENT_NAME:-}"
	local action="${EVENT_ACTION:-}"
	local subject_id="${EVENT_SUBJECT_ID:-}"
	local cursor="${EVENT_CURSOR:-}"
	local operation_id="${EVENT_OPERATION_ID:-}"

	case "$event_kind" in
	issues) event_kind="issue" ;;
	pull_request | pull_request_target) event_kind="pull_request" ;;
	push)
		event_kind="push"
		action="pushed"
		;;
	workflow_dispatch)
		event_kind="manual"
		action="requested"
		;;
	*)
		printf 'Unsupported forge event: %s\n' "$event_kind" >&2
		return 1
		;;
	esac
	if [[ "$event_kind" == "pull_request" && "$action" == "closed" && "${EVENT_MERGED:-false}" == "true" ]]; then
		action="merged"
	fi
	[[ -n "$subject_id" && -n "$cursor" && -n "$operation_id" ]] || {
		printf 'Forge event is missing immutable identity or cursor\n' >&2
		return 1
	}

	node "$COORDINATOR" forge-event --operation-id "$operation_id" \
		--repository-id "${REPOSITORY_ID:-}" --repository-slug "${REPOSITORY_SLUG:-}" \
		--event-kind "$event_kind" --action "$action" --subject-id "$subject_id" --cursor "$cursor"
	return 0
}

main "$@"
