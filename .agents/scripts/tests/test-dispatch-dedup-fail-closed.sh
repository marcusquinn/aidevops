#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-dedup-fail-closed.sh — t2046 fail-closed guard regression.
#
# Asserts that is_assigned() blocks dispatch (exit 0 + GUARD_UNCERTAIN signal)
# when the gh API call fails internally, rather than silently allowing dispatch
# (the previous fail-open default that allowed three workers to be dispatched
# to a parent-task issue during the t2010 / GH#18458 incident).
#
# Test cases (Plan §2.4 of todo/plans/parent-task-incident-hardening.md):
#   Case 1: gh exits non-zero (command failure)       → GUARD_UNCERTAIN, exit 0 (block)
#   Case 2: gh exits 0 but returns empty string       → GUARD_UNCERTAIN, exit 0 (block)
#   Case 3: well-formed parent-task labels            → PARENT_TASK_BLOCKED, exit 0 (block)
#   Case 4: clean dispatchable issue                  → exit 1 (allow dispatch)
#
# Companion to test-parent-task-guard.sh (t1986, GH#18537).
# Model: same fixture + stub pattern as test-parent-task-guard.sh Parts 3+.

# NOTE: not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits. Each assertion explicitly captures exit codes.
# NOTE: SCRIPT_DIR is NOT readonly — collision avoidance (see test-parent-task-guard.sh).
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Stub infrastructure — same pattern as test-parent-task-guard.sh
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

# write_stub_gh_success: stub gh that exits 0 and returns a given JSON payload.
write_stub_gh_success() {
	local payload="$1"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub for test-dispatch-dedup-fail-closed.sh — exits 0, returns payload
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	printf '%s\n' '${payload}'
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
}

# write_stub_gh_fail: stub gh that exits with a given non-zero code.
write_stub_gh_fail() {
	local exit_code="${1:-1}"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub for test-dispatch-dedup-fail-closed.sh — exits ${exit_code} (failure)
exit ${exit_code}
STUB
	chmod +x "${STUB_DIR}/gh"
}

# write_stub_gh_empty: stub gh that exits 0 but returns empty output.
write_stub_gh_empty() {
	cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Stub for test-dispatch-dedup-fail-closed.sh — exits 0, returns empty string
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	printf ''
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# run_is_assigned: invokes dispatch-dedup-helper.sh is-assigned, captures
# both stdout (output) and exit code (rc).
run_is_assigned() {
	local issue="$1" repo="$2" self="${3:-}"
	output=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned "$issue" "$repo" "$self" 2>/dev/null)
	rc=$?
	return 0
}

# =============================================================================
# Case 1 — gh exits non-zero → GUARD_UNCERTAIN, exit 0 (block)
# =============================================================================
# Simulates: network error, auth failure, rate limit, issue not found
write_stub_gh_fail 1
run_is_assigned 99990 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"GUARD_UNCERTAIN"* && "$output" == *"gh-api-failure"* ]]; then
	print_result "fail-closed: gh exit non-zero → GUARD_UNCERTAIN, exit 0 (block)" 0
else
	print_result "fail-closed: gh exit non-zero → GUARD_UNCERTAIN, exit 0 (block)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Case 2 — gh exits 0 but returns empty string → GUARD_UNCERTAIN, exit 0 (block)
# =============================================================================
# Simulates: gh bug returning empty body on success — previously allowed dispatch
write_stub_gh_empty
run_is_assigned 99991 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"GUARD_UNCERTAIN"* ]]; then
	print_result "fail-closed: gh empty response → GUARD_UNCERTAIN, exit 0 (block)" 0
else
	print_result "fail-closed: gh empty response → GUARD_UNCERTAIN, exit 0 (block)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Case 3 — well-formed parent-task issue → PARENT_TASK_BLOCKED, exit 0
# =============================================================================
# Verifies that the existing parent-task guard still fires when gh succeeds.
write_stub_gh_success '{"state":"OPEN","assignees":[],"labels":[{"name":"parent-task"},{"name":"pulse"}]}'
run_is_assigned 99992 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"PARENT_TASK_BLOCKED"* && "$output" == *"parent-task"* ]]; then
	print_result "fail-closed: parent-task label → PARENT_TASK_BLOCKED preserved" 0
else
	print_result "fail-closed: parent-task label → PARENT_TASK_BLOCKED preserved" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Case 4 — clean dispatchable issue → exit 1 (allow dispatch)
# =============================================================================
# Verifies that normal issues (no parent-task, no blocking assignees) are
# not affected by the fail-closed change — the happy path must still work.
write_stub_gh_success '{"state":"OPEN","assignees":[],"labels":[{"name":"pulse"},{"name":"tier:standard"}]}'
run_is_assigned 99993 "owner/repo"
if [[ "$rc" -eq 1 && "$output" != *"GUARD_UNCERTAIN"* && "$output" != *"PARENT_TASK_BLOCKED"* ]]; then
	print_result "fail-closed: clean issue → exit 1 (allow dispatch, happy path unaffected)" 0
else
	print_result "fail-closed: clean issue → exit 1 (allow dispatch, happy path unaffected)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# t2061 Part 1 — internal jq failure cases
# =============================================================================
# These cases inject JSON that passes top-level parsing but fails on downstream
# jq filter calls inside is_assigned(). They assert that the fail-closed
# GUARD_UNCERTAIN signal is emitted instead of silently allowing dispatch.

# write_stub_gh_success_api: stub that returns a given issue JSON on `gh issue view`
# and passes through `gh api` calls (returns empty array for comments).
write_stub_gh_success_api() {
	local payload="$1"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub for t2061 — gh issue view returns payload, gh api returns empty array
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	printf '%s\n' '${payload}'
	exit 0
fi
if [[ "\$1" == "api" ]]; then
	printf '[]'
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
}

# =============================================================================
# Case 5 — assignees field is wrong type → jq downstream failure → GUARD_UNCERTAIN
# =============================================================================
# Injects JSON where "assignees" is a string instead of an array. The top-level
# JSON is valid (passes the gh API check and non-empty check). The downstream
# jq filter `[.assignees[].login] | join(",")` fails on a string operand.
# Expected: GUARD_UNCERTAIN (reason=jq-failure call=assignees-join), exit 0 (block)
write_stub_gh_success_api '{"state":"OPEN","assignees":"invalid-not-an-array","labels":[{"name":"pulse"},{"name":"tier:standard"}]}'
run_is_assigned 99994 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"GUARD_UNCERTAIN"* && "$output" == *"jq-failure"* ]]; then
	print_result "t2061: assignees field wrong type → GUARD_UNCERTAIN (assignees-join jq failure)" 0
else
	print_result "t2061: assignees field wrong type → GUARD_UNCERTAIN (assignees-join jq failure)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Case 6 — labels field is wrong type → parent-task check jq failure → GUARD_UNCERTAIN
# =============================================================================
# Injects JSON where "labels" is an object instead of an array. The top-level
# JSON is valid (passes the gh API check). The jq filter inside
# _is_assigned_check_parent_task() attempts `(.labels // [])[].name | select(...)`
# on an object, which fails. Expected: GUARD_UNCERTAIN (reason=jq-failure
# call=parent-task-check), exit 0 (block).
write_stub_gh_success_api '{"state":"OPEN","assignees":[],"labels":{"invalid":"object-not-array"}}'
run_is_assigned 99995 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"GUARD_UNCERTAIN"* && "$output" == *"jq-failure"* ]]; then
	print_result "t2061: labels field wrong type → GUARD_UNCERTAIN (parent-task-check jq failure)" 0
else
	print_result "t2061: labels field wrong type → GUARD_UNCERTAIN (parent-task-check jq failure)" 1 \
		"(rc=$rc output='$output')"
fi

export PATH="$OLD_PATH"

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
