#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Verify Pulse approves only exact-head action-required runs for trusted Issue Sync PRs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
TEST_ROOT="$(mktemp -d)"
LOGFILE="${TEST_ROOT}/pulse.log"
APPROVE_LOG="${TEST_ROOT}/approve.log"
AUDIT_LOG="${TEST_ROOT}/audit.log"
HEAD_READ_LOG="${TEST_ROOT}/head-read.log"
TRUST_LOG="${TEST_ROOT}/trust.log"
_PULSE_MERGE_PROCESS_DIR="${TEST_ROOT}"
TRUSTED=1
RUNS_JSON='{"total_count":0,"workflow_runs":[]}'
LIVE_HEAD="head-current"
LIVE_REPO="owner/repo"
INVALIDATE_FAIL=0
FAIL_APPROVE_RUN=""
FAILED_RUN_CONCLUSION="action_required"
TESTS_RUN=0
TESTS_FAILED=0
export LOGFILE
trap 'rm -rf "$TEST_ROOT"' EXIT

cat >"${TEST_ROOT}/audit-log-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AUDIT_LOG}"
STUB
chmod +x "${TEST_ROOT}/audit-log-helper.sh"
export AUDIT_LOG

function_src=$(awk '
	/^_pmp_issue_sync_run_api\(\) \{/,/^}$/ { print }
	/^_pmp_audit_issue_sync_run_approval\(\) \{/,/^}$/ { print }
	/^_pmp_approve_issue_sync_action_required_runs\(\) \{/,/^}$/ { print }
' "$PROCESS_SCRIPT")
[[ -n "$function_src" ]] || {
	printf 'FAIL could not extract Issue Sync run approval helpers\n' >&2
	exit 1
}

_gh_with_timeout() {
	shift
	"$@"
}

_pulse_is_trusted_issue_sync_pr() {
	printf '%s %s %s\n' "$1" "$2" "$3" >>"$TRUST_LOG"
	if [[ "$TRUSTED" -eq 1 && "$3" == "head-current" ]]; then
		return 0
	fi
	return 1
}

gh_pr_check_status_cache_invalidate() {
	printf '%s %s\n' "$1" "$2" >>"${TEST_ROOT}/invalidate.log"
	if [[ "$INVALIDATE_FAIL" -eq 0 ]]; then
		return 0
	fi
	return 1
}

gh() {
	local args="$*"
	local run_id=""
	if [[ "$args" == *"actions/runs?event=pull_request"* ]]; then
		printf '%s\n' "$RUNS_JSON"
		return 0
	fi
	if [[ "$args" == *"pulls/950"* ]]; then
		printf 'read\n' >>"$HEAD_READ_LOG"
		printf '%s\t%s\n' "$LIVE_HEAD" "$LIVE_REPO"
		return 0
	fi
	if [[ "$args" == *"/approve"* ]]; then
		run_id="${args%/approve}"
		run_id="${run_id##*/}"
		printf '%s\n' "$run_id" >>"$APPROVE_LOG"
		[[ "$run_id" != "$FAIL_APPROVE_RUN" ]]
		return $?
	fi
	if [[ "$args" == *"actions/runs/"* ]]; then
		printf '%s\n' "$FAILED_RUN_CONCLUSION"
		return 0
	fi
	return 1
}

# shellcheck disable=SC1090
eval "$function_src"

reset_fixture() {
	: >"$LOGFILE"
	: >"$APPROVE_LOG"
	: >"$AUDIT_LOG"
	: >"$HEAD_READ_LOG"
	: >"$TRUST_LOG"
	: >"${TEST_ROOT}/invalidate.log"
	TRUSTED=1
	RUNS_JSON='{"total_count":0,"workflow_runs":[]}'
	LIVE_HEAD="head-current"
	LIVE_REPO="owner/repo"
	FAIL_APPROVE_RUN=""
	FAILED_RUN_CONCLUSION="action_required"
	INVALIDATE_FAIL=0
	_PULSE_ISSUE_SYNC_RUNS_APPROVED=0
}

run_helper() {
	RUN_RC=0
	_pmp_approve_issue_sync_action_required_runs 950 owner/repo head-current || RUN_RC=$?
}

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s' "$name"
	[[ -n "$detail" ]] && printf ': %s' "$detail"
	printf '\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

run_json() {
	local id="$1"
	local conclusion="${2:-action_required}"
	local head="${3:-head-current}"
	local repo="${4:-owner/repo}"
	local pr="${5:-950}"
	printf '{"total_count":1,"workflow_runs":[{"id":%s,"event":"pull_request","conclusion":"%s","head_sha":"%s","head_repository":{"full_name":"%s"},"pull_requests":[{"number":%s}]}]}' \
		"$id" "$conclusion" "$head" "$repo" "$pr"
}

reset_fixture
RUNS_JSON=$(run_json 101)
run_helper
result="$RUN_RC"
if [[ "$result" -eq 0 && "$(<"$APPROVE_LOG")" == "101" \
	&& "$_PULSE_ISSUE_SYNC_RUNS_APPROVED" -eq 1 && -s "$AUDIT_LOG" ]]; then
	print_result "trusted exact-head action-required run is approved and audited" 0
else
	print_result "trusted exact-head action-required run is approved and audited" 1 "rc=${result} approvals=$(<"$APPROVE_LOG")"
fi

reset_fixture
RUNS_JSON=$(run_json 102 action_required stale-head)
run_helper
result="$RUN_RC"
if [[ "$result" -eq 1 && ! -s "$APPROVE_LOG" ]]; then
	print_result "stale run head is refused" 0
else
	print_result "stale run head is refused" 1 "rc=${result}"
fi

reset_fixture
RUNS_JSON=$(run_json 103 action_required head-current owner/repo 951)
run_helper
result="$RUN_RC"
if [[ "$result" -eq 1 && ! -s "$APPROVE_LOG" ]]; then
	print_result "wrong PR association is refused" 0
else
	print_result "wrong PR association is refused" 1 "rc=${result}"
fi

reset_fixture
RUNS_JSON=$(run_json 104 action_required head-current fork/repo)
run_helper
result="$RUN_RC"
if [[ "$result" -eq 1 && ! -s "$APPROVE_LOG" ]]; then
	print_result "fork run is refused" 0
else
	print_result "fork run is refused" 1 "rc=${result}"
fi

reset_fixture
RUNS_JSON=$(run_json 105 success)
run_helper
result="$RUN_RC"
if [[ "$result" -eq 0 && ! -s "$APPROVE_LOG" && "$_PULSE_ISSUE_SYNC_RUNS_APPROVED" -eq 0 ]]; then
	print_result "non-action-required run is a no-op" 0
else
	print_result "non-action-required run is a no-op" 1 "rc=${result}"
fi

reset_fixture
RUNS_JSON='{"total_count":2,"workflow_runs":[{"id":106,"event":"pull_request","conclusion":"action_required","head_sha":"head-current","head_repository":{"full_name":"owner/repo"},"pull_requests":[{"number":950}]},{"id":107,"event":"pull_request","conclusion":"action_required","head_sha":"head-current","head_repository":{"full_name":"owner/repo"},"pull_requests":[{"number":950}]}]}'
FAIL_APPROVE_RUN=107
run_helper
result="$RUN_RC"
if [[ "$result" -eq 1 && "$(tr '\n' ' ' <"$APPROVE_LOG")" == "106 107 " ]]; then
	print_result "partial approval API failure stops the batch" 0
else
	print_result "partial approval API failure stops the batch" 1 "rc=${result} approvals=$(tr '\n' ' ' <"$APPROVE_LOG")"
fi

reset_fixture
RUNS_JSON=$(run_json 108)
FAIL_APPROVE_RUN=108
FAILED_RUN_CONCLUSION="queued"
run_helper
first_result="$RUN_RC"
run_helper
second_result="$RUN_RC"
if [[ "$first_result" -eq 0 && "$second_result" -eq 0 \
	&& "$(wc -l <"$APPROVE_LOG" | tr -d ' ')" -eq 2 ]]; then
	print_result "repeated pass treats an already-cleared run idempotently" 0
else
	print_result "repeated pass treats an already-cleared run idempotently" 1 "first=${first_result} second=${second_result}"
fi

reset_fixture
RUNS_JSON=$(run_json 109)
LIVE_HEAD="head-mutated"
run_helper
result="$RUN_RC"
if [[ "$result" -eq 1 && ! -s "$APPROVE_LOG" && -s "$HEAD_READ_LOG" ]]; then
	print_result "head mutation between listing and approval is refused" 0
else
	print_result "head mutation between listing and approval is refused" 1 "rc=${result}"
fi

approval_line=$(awk '/^[[:space:]]*if ! _pmp_approve_issue_sync_action_required_runs / { print NR; exit }' "$MERGE_SCRIPT")
native_auto_line=$(awk '/^[[:space:]]*_set_native_auto_merge_or_skip / { print NR; exit }' "$MERGE_SCRIPT")
if [[ "$approval_line" =~ ^[0-9]+$ && "$native_auto_line" =~ ^[0-9]+$ \
	&& "$approval_line" -lt "$native_auto_line" ]]; then
	print_result "run recovery precedes native auto-merge classification" 0
else
	print_result "run recovery precedes native auto-merge classification" 1 "approval=${approval_line:-missing} native=${native_auto_line:-missing}"
fi

printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
