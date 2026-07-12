#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/coordinator.db"
TODO_FILE="${TEST_ROOT}/TODO.md"
printf '%s\n' '- [ ] t101 first repository task ref:GH#42' '- [ ] t102 second repository task ref:GH#42' >"$TODO_FILE"

_escape_ere() { printf '%s' "$1"; return 0; }
strip_code_fences() { command cat; return 0; }
log_verbose() { return 0; }

gh() {
	local group="$1"
	shift
	if [[ "$group" == "api" ]]; then
		local endpoint="$1"
		case "$endpoint" in
			repos/owner/one | repos/owner/renamed-one) printf '%s\n' R_one ;;
			repos/owner/two) printf '%s\n' R_two ;;
			*) return 1 ;;
		esac
		return 0
	fi
	if [[ "$group" == "issue" && "$1" == "view" ]]; then
		local repo=""
		while [[ $# -gt 0 ]]; do
			if [[ "$1" == "--repo" ]]; then repo="$2"; shift 2; else shift; fi
		done
		case "$repo" in
			owner/one | owner/renamed-one) printf '%s\n' '{"id":"I_one_42","number":42,"state":"OPEN","updatedAt":"2026-07-12T10:00:00Z"}' ;;
			owner/two) printf '%s\n' '{"id":"I_two_42","number":42,"state":"CLOSED","updatedAt":"2026-07-12T11:00:00Z"}' ;;
			*) return 1 ;;
		esac
		return 0
	fi
	return 1
}

# shellcheck source=../issue-sync-lib-ref.sh
source "${SCRIPT_DIR}/issue-sync-lib-ref.sh"

[[ "$(resolve_task_gh_number t101 "$TODO_FILE" owner/one)" == "42" ]]
[[ "$(resolve_task_gh_number t102 "$TODO_FILE" owner/two)" == "42" ]]
[[ "$(node "${SCRIPT_DIR}/task-coordinator.mjs" resolve-issue --task-id t101 --repository-id R_one | jq -r '.issueId')" == "I_one_42" ]]
[[ "$(node "${SCRIPT_DIR}/task-coordinator.mjs" resolve-issue --task-id t102 --repository-id R_two | jq -r '.issueId')" == "I_two_42" ]]

# A renamed remote resolves through immutable repository identity and refreshes
# only the mutable slug. A local-only/unvalidated target cannot resolve.
[[ "$(resolve_task_gh_number t101 "$TODO_FILE" owner/renamed-one)" == "42" ]]
[[ "$(node "${SCRIPT_DIR}/task-coordinator.mjs" resolve-issue --task-id t101 --repository-id R_one | jq -r '.repositorySlug')" == "owner/renamed-one" ]]
if resolve_task_gh_number t101 "$TODO_FILE" local/only >/dev/null 2>&1; then
	printf 'FAIL local-only repository resolved an issue write target\n' >&2
	exit 1
fi

# A conflicting projection for the same immutable task/repository fails closed.
printf '%s\n' '- [ ] t101 conflicting task projection ref:GH#43' >"$TODO_FILE"
if AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/conflict.db" resolve_task_gh_number t101 "$TODO_FILE" owner/one >/dev/null 2>&1; then
	printf 'FAIL unresolved issue projection was accepted\n' >&2
	exit 1
fi

printf 'PASS repository-scoped issue mapping isolation and fail-closed backfill\n'
