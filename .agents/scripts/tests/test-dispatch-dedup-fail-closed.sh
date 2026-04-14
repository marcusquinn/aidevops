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

# write_stub_gh_issue_ok_comments_fail: stub gh that:
#   - exits 0 for "gh issue view" with a payload containing blocking assignees
#   - exits 1 for "gh api repos/.../comments" (comments endpoint failure)
# This simulates the partial API degradation that GH#18816 addresses:
# issue metadata is fetchable but the comments endpoint is down.
write_stub_gh_issue_ok_comments_fail() {
	local payload="$1"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub: issue view succeeds, comments api fails (GH#18816 test)
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	printf '%s\n' '${payload}'
	exit 0
fi
if [[ "\$1" == "api" ]]; then
	# Simulate comments endpoint failure (network error, rate limit, etc.)
	exit 1
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
# Case 5 — internal jq failure in parent-task check → GUARD_UNCERTAIN (t2061)
# =============================================================================
# Simulates: labels field is a string instead of an array. The jq filter
# '(.labels // [])[].name | select(...)' fails with a type error when it
# tries to iterate '[].name' over a string. Previously fell through to
# "no parent-task label" via '|| true'; now emits GUARD_UNCERTAIN.
write_stub_gh_success '{"state":"OPEN","assignees":[],"labels":"not-an-array"}'
run_is_assigned 99994 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"GUARD_UNCERTAIN"* && "$output" == *"jq-failure"* ]]; then
	print_result "t2061: internal jq failure (parent-task check) → GUARD_UNCERTAIN, exit 0 (block)" 0
else
	print_result "t2061: internal jq failure (parent-task check) → GUARD_UNCERTAIN, exit 0 (block)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Case 6 — internal jq failure in assignees extraction → GUARD_UNCERTAIN (t2061)
# =============================================================================
# Simulates: assignees field is a string instead of an array. The jq filter
# '[.assignees[].login] | join(",")' fails with a type error when it tries
# to iterate '[].login' over a string. Previously set assignees="" → "No
# assignees — safe to dispatch"; now emits GUARD_UNCERTAIN.
# Labels are a valid empty array to pass the parent-task check cleanly.
write_stub_gh_success '{"state":"OPEN","assignees":"not-an-array","labels":[{"name":"pulse"}]}'
run_is_assigned 99995 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"GUARD_UNCERTAIN"* && "$output" == *"jq-failure"* ]]; then
	print_result "t2061: internal jq failure (assignees extract) → GUARD_UNCERTAIN, exit 0 (block)" 0
else
	print_result "t2061: internal jq failure (assignees extract) → GUARD_UNCERTAIN, exit 0 (block)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Case 7 — _is_stale_assignment: comments API failure + blocking assignee
#           → NOT stale (return 1, block dispatch) (GH#18816)
# =============================================================================
# Simulates: issue metadata fetch succeeds (blocking assignee present), but
# the comments endpoint fails (network error, rate limit, partial degradation).
# Prior to GH#18816: comments_json="[]" → treated as "no dispatch comment" →
# stale recovery fired → is_assigned() returned 1 (allow dispatch) — a
# spurious dispatch even if the original worker was actively running.
# After GH#18816: fail-CLOSED → is_assigned() returns 0 (ASSIGNED, block).
# The issue payload includes a non-self, non-owner assignee ("other-runner")
# without an active claim label so _is_assigned_compute_blocking returns it
# as blocking, reaching _is_stale_assignment.
write_stub_gh_issue_ok_comments_fail '{"state":"OPEN","assignees":[{"login":"other-runner"}],"labels":[{"name":"pulse"},{"name":"tier:standard"}]}'
run_is_assigned 99996 "owner/repo" "self-login"
if [[ "$rc" -eq 0 && "$output" == *"ASSIGNED"* ]]; then
	print_result "GH#18816: comments API fail + blocking assignee → ASSIGNED, exit 0 (block)" 0
else
	print_result "GH#18816: comments API fail + blocking assignee → ASSIGNED, exit 0 (block)" 1 \
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
