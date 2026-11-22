#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../pulse-merge-stuck.sh
source "${SCRIPT_DIR}/pulse-merge-stuck.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
LOGFILE="${TEST_DIR}/pulse.log"
GH_LOG="${TEST_DIR}/gh.log"
export LOGFILE GH_LOG
MODE=normal
gh() {
	printf '%s\n' "$*" >>"$GH_LOG"
	case "$*" in
	*'/commits/'*'/status'*) printf '%s\n' '{"statuses":[{"context":"maintainer-gate","state":"pending","description":"Refreshing via Job 1 rerun...","updated_at":"2020-01-01T00:00:00Z"}]}' ;;
	*'/actions/workflows/'*)
		if [[ "$MODE" == no_completed ]]; then
			printf '%s\n' '{"workflow_runs":[{"id":2,"head_sha":"abc","status":"queued","created_at":"2020-01-02T00:00:00Z"}]}'
		else
			printf '%s\n' '{"workflow_runs":[{"id":2,"head_sha":"abc","status":"queued","created_at":"2020-01-02T00:00:00Z"},{"id":1,"head_sha":"abc","status":"completed","created_at":"2020-01-01T00:00:00Z"}]}'
		fi ;;
	*'/jobs?'*) printf '%s\n' '{"total_count":0,"jobs":[]}' ;;
	*'-X POST'*'/rerun'*) return 0 ;;
	*) return 1 ;;
	esac
	return 0
}
_pms_queued_gate_refresh owner/repo abc
_pms_repair_queued_gate_refresh owner/repo abc
[[ $(grep -c 'POST.*runs/1/rerun' "$GH_LOG") -eq 1 ]]
if grep -q 'POST.*statuses' "$GH_LOG"; then
	exit 1
fi
MODE=no_completed
_pms_queued_gate_refresh owner/repo abc
if _pms_repair_queued_gate_refresh owner/repo abc; then
	printf '%s\n' 'Unexpected repair without completed run' >&2
	exit 1
fi
_escalate_individual_stuck_pr() {
	printf '%s\n' "$3" >"${TEST_DIR}/escalated"
	return 0
}
_pms_handle_classified_pr 42 owner/repo 0 '{"headRefOid":"abc"}' STUCK_QUEUED_GATE_REFRESH >/dev/null
[[ $(<"${TEST_DIR}/escalated") == STUCK_QUEUED_GATE_REFRESH ]]
[[ $(grep -c 'POST.*runs/1/rerun' "$GH_LOG") -eq 1 ]]
printf '%s\n' 'PASS: queued refresh detection and rerun'
