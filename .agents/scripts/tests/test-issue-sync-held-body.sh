#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
mkdir -p "$AIDEVOPS_TEMP_DIR" "${TEST_ROOT}/project/todo/tasks"

print_error() {
	printf 'ERROR: %s\n' "$*" >&2
	return 0
}
print_info() {
	printf 'INFO: %s\n' "$*"
	return 0
}
print_success() {
	printf 'SUCCESS: %s\n' "$*"
	return 0
}

set +e
# shellcheck source=../issue-sync-helper-body.sh
source "${SCRIPTS_DIR}/issue-sync-helper-body.sh"

PASS_COUNT=0
FAIL_COUNT=0
WRITE_COUNT=0
AUDIT_COUNT=0
FETCH_COUNT=0
FETCH_COUNT_FILE="${TEST_ROOT}/fetch-count"
WRITE_FAIL=false
AUDIT_FAIL_STAGE=""
INITIAL_JSON=""
IMMEDIATE_JSON=""
POST_JSON=""
DESIRED_BODY=$'## Summary\n\nAuthoritative implementation context with enough detail to be non-stub and safe for a focused worker.\n\n## Task Brief\n\nFiles, constraints, verification, rollback, and acceptance criteria are fully defined here for deterministic execution.\n\n---\n*Synced from TODO.md by issue-sync-helper.sh*'

pass() {
	local message="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}
fail() {
	local message="$1"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf 'FAIL: %s\n' "$message" >&2
	return 0
}
assert_success() {
	local name="$1"
	shift
	if "$@"; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}
assert_failure() {
	local name="$1"
	shift
	if "$@"; then
		fail "$name"
	else
		pass "$name"
	fi
	return 0
}

make_state() {
	local body="$1"
	local state="${2:-OPEN}"
	local labels="${3:-no-auto-dispatch}"
	local assignees="${4:-}"
	local title="${5:-t999: Held body sync}"
	local labels_json="[]" assignees_json="[]"
	if [[ -n "$labels" ]]; then
		labels_json=$(printf '%s\n' "$labels" | jq -Rc 'split(",") | map({name:.})')
	fi
	if [[ -n "$assignees" ]]; then
		assignees_json=$(printf '%s\n' "$assignees" | jq -Rc 'split(",") | map({login:.})')
	fi
	jq -cn --argjson number 123 --arg title "$title" --arg body "$body" --arg state "$state" \
		--arg updatedAt "2026-07-18T10:00:00Z" --argjson labels "$labels_json" --argjson assignees "$assignees_json" \
		'{number:$number,title:$title,body:$body,state:$state,updatedAt:$updatedAt,labels:$labels,assignees:$assignees}'
	return 0
}

reset_case() {
	local current_body=$'Old framework body\n\n*Synced from TODO.md by issue-sync-helper.sh*'
	WRITE_COUNT=0
	AUDIT_COUNT=0
	FETCH_COUNT=0
	printf '0\n' >"$FETCH_COUNT_FILE"
	WRITE_FAIL=false
	AUDIT_FAIL_STAGE=""
	INITIAL_JSON=$(make_state "$current_body")
	IMMEDIATE_JSON="$INITIAL_JSON"
	POST_JSON=$(make_state "${DESIRED_BODY}"$'\n\n<!-- aidevops:sig -->\n---\n[signed receipt]')
	printf '%120s\n' 'authoritative brief content' >"${TEST_ROOT}/project/todo/tasks/t999-brief.md"
	return 0
}

require_task_issue_mapping() { return 0; }
compose_issue_body() {
	printf '%s' "$DESIRED_BODY"
	return 0
}
_body_sync_scan_file() { return 0; }
_body_sync_fetch_state() {
	local repo="$1"
	local issue_number="$2"
	: "$repo" "$issue_number"
	FETCH_COUNT=$(<"$FETCH_COUNT_FILE")
	FETCH_COUNT=$((FETCH_COUNT + 1))
	printf '%s\n' "$FETCH_COUNT" >"$FETCH_COUNT_FILE"
	case "$FETCH_COUNT" in
	1) printf '%s' "$INITIAL_JSON" ;;
	2) printf '%s' "$IMMEDIATE_JSON" ;;
	*) printf '%s' "$POST_JSON" ;;
	esac
	return 0
}
gh_issue_edit_safe() {
	local issue_number="$1"
	shift
	: "$issue_number"
	WRITE_COUNT=$((WRITE_COUNT + 1))
	[[ "$*" == *"--body-file"* ]] || return 1
	[[ "$*" != *"--title"* && "$*" != *"--add-label"* && "$*" != *"--remove-label"* ]] || return 1
	[[ "$WRITE_FAIL" == "false" ]]
	return $?
}
_body_sync_record_audit() {
	local event_type="$1"
	local outcome="$2"
	shift 2
	: "$event_type" "$@"
	AUDIT_COUNT=$((AUDIT_COUNT + 1))
	[[ "$AUDIT_FAIL_STAGE" != "$outcome" ]]
	return $?
}

run_apply() {
	_body_sync_apply t999 owner/repo "${TEST_ROOT}/project/TODO.md" "${TEST_ROOT}/project" 123 self false
	return $?
}

reset_case
assert_success "unassigned held issue receives body-only verified update" run_apply
[[ "$WRITE_COUNT" -eq 1 && "$AUDIT_COUNT" -eq 2 ]] && pass "success writes once with authorization and verification receipts" || fail "success receipt/write counts"

reset_case
INITIAL_JSON=$(make_state "$(jq -r '.body' <<<"$INITIAL_JSON")" OPEN "no-auto-dispatch,status:in-progress" other)
IMMEDIATE_JSON="$INITIAL_JSON"
assert_failure "genuine non-self active claim blocks held body sync" run_apply
[[ "$WRITE_COUNT" -eq 0 ]] && pass "active claim performs no write" || fail "active claim wrote"

reset_case
INITIAL_JSON='{"number":123,"state":"OPEN","labels":null}'
IMMEDIATE_JSON="$INITIAL_JSON"
assert_failure "malformed uncertain state fails closed" run_apply

reset_case
IMMEDIATE_JSON=$(make_state $'Changed concurrently\n\n*Synced from TODO.md by issue-sync-helper.sh*')
assert_failure "concurrent pre-write state change is rejected" run_apply
[[ "$WRITE_COUNT" -eq 0 ]] && pass "concurrent pre-write change performs no write" || fail "concurrent state wrote"

reset_case
INITIAL_JSON=$(make_state "Collaborator-authored rich body without framework ownership marker")
IMMEDIATE_JSON="$INITIAL_JSON"
assert_failure "rich collaborator-authored body is preserved" run_apply

reset_case
INITIAL_JSON=$(make_state "$(jq -r '.body' <<<"$INITIAL_JSON")" CLOSED)
IMMEDIATE_JSON="$INITIAL_JSON"
POST_JSON=$(make_state "$DESIRED_BODY" CLOSED)
assert_failure "closed issue is rejected by default" run_apply
printf '0\n' >"$FETCH_COUNT_FILE"
assert_success "closed issue requires and accepts explicit mode" _body_sync_apply t999 owner/repo "${TEST_ROOT}/project/TODO.md" "${TEST_ROOT}/project" 123 self true

reset_case
WRITE_FAIL=true
assert_failure "failed body write is reported" run_apply

reset_case
POST_JSON=$(make_state "Unexpected remote body")
assert_failure "failed post-write body hash verification is reported" run_apply

reset_case
POST_JSON=$(make_state "$DESIRED_BODY" OPEN "no-auto-dispatch,status:available")
assert_failure "concurrent metadata change is detected after body-only write" run_apply

reset_case
POST_JSON=$(make_state "$DESIRED_BODY" OPEN "status:available")
assert_failure "missing post-write dispatch hold fails verification" run_apply

reset_case
AUDIT_FAIL_STAGE="authorized"
assert_failure "missing authorization audit receipt prevents write" run_apply
[[ "$WRITE_COUNT" -eq 0 ]] && pass "audit preflight failure performs no write" || fail "audit preflight failure wrote"

reset_case
INITIAL_JSON=$(make_state "$(jq -r '.body' <<<"$INITIAL_JSON")" OPEN "status:available")
IMMEDIATE_JSON="$INITIAL_JSON"
assert_failure "sync-body cannot operate without no-auto-dispatch" run_apply

reset_case
require_task_issue_mapping() { return 1; }
assert_failure "immutable task-to-issue mapping failure prevents synchronization" run_apply
[[ "$WRITE_COUNT" -eq 0 ]] && pass "mapping failure performs no write" || fail "mapping failure wrote"
require_task_issue_mapping() { return 0; }

CMD_APPLY_COUNT=0
_init_cmd() {
	_CMD_REPO="owner/repo"
	_CMD_TODO="${TEST_ROOT}/project/TODO.md"
	_CMD_ROOT="${TEST_ROOT}/project"
	return 0
}
resolve_task_gh_number() {
	printf '123\n'
	return 0
}
_gh_current_user_allows_repo_write() {
	AIDEVOPS_GH_WRITE_PERMISSION_USER="maintainer"
	AIDEVOPS_GH_WRITE_PERMISSION_REASON="allowed"
	return 0
}
_body_sync_apply() {
	CMD_APPLY_COUNT=$((CMD_APPLY_COUNT + 1))
	return 0
}
AIDEVOPS_GH_WRITE_PERMISSION_LEVEL="write"
assert_failure "write-level collaborator cannot invoke maintainer-only sync" cmd_sync_body t999
[[ "$CMD_APPLY_COUNT" -eq 0 ]] && pass "insufficient authority performs no sync" || fail "insufficient authority synced"
AIDEVOPS_GH_WRITE_PERMISSION_LEVEL="maintain"
assert_success "maintain authority may invoke targeted sync" cmd_sync_body t999
[[ "$CMD_APPLY_COUNT" -eq 1 ]] && pass "maintainer command invokes one exact sync" || fail "maintainer invocation count"

printf '\nTests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
