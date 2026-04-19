#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reassign-self-normalization.sh — Tests for _normalize_reassign_self (t2396)
#
# Verifies that _normalize_reassign_self correctly:
#   1. Self-assigns status:queued / status:in-progress issues (regression)
#   2. Self-assigns status:available + origin:worker + feedback label issues
#   3. Self-assigns status:available + origin:worker + body marker issues
#   4. Skips status:available without origin:worker
#   5. Skips status:available with existing assignees
#   6. Skips fresh scanner issues (no feedback markers/labels)
#
# Requires only: bash, a stub gh binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCRIPTS_DIR="${SCRIPT_DIR}/.."

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ASSIGNED_ISSUES=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	ASSIGNED_ISSUES=""

	mkdir -p "${TEST_ROOT}/bin"

	# repos.json with a single test repo
	cat >"${TEST_ROOT}/repos.json" <<'EOF'
{
  "initialized_repos": [
    {
      "path": "/home/user/Git/testrepo",
      "slug": "testorg/testrepo",
      "pulse": true
    }
  ]
}
EOF

	# LOGFILE for the function
	export LOGFILE="${TEST_ROOT}/pulse.log"
	touch "$LOGFILE"

	# PULSE_QUEUED_SCAN_LIMIT used in the function
	export PULSE_QUEUED_SCAN_LIMIT=100

	# Stub dedup helper that always says "safe to assign" (exit 1)
	cat >"${TEST_ROOT}/bin/dedup-stub.sh" <<'DEDUP_EOF'
#!/usr/bin/env bash
# Stub dispatch-dedup-helper.sh — always returns "not assigned" (exit 1 = safe)
exit 1
DEDUP_EOF
	chmod +x "${TEST_ROOT}/bin/dedup-stub.sh"

	return 0
}

cleanup_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Create a stub gh that returns canned JSON for "issue list" and tracks "issue edit" calls
create_gh_stub() {
	local issue_list_json="$1"
	local issue_view_body="${2:-}"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
	cat <<'JSON_EOF'
${issue_list_json}
JSON_EOF
	exit 0
elif [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	# Return body for marker check
	echo '{"body": "${issue_view_body}"}'
	exit 0
elif [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
	# Track which issues got assigned
	echo "\$3" >> "${TEST_ROOT}/assigned.txt"
	exit 0
fi
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Source the function under test.
# We pre-load the stale module (empty stub) and shared-constants.sh
# constants that the function uses, then source the reconcile module.
source_function_under_test() {
	# Prevent re-sourcing on repeated calls within the same bash process
	unset _PULSE_ISSUE_RECONCILE_LOADED 2>/dev/null || true
	unset _PULSE_ISSUE_RECONCILE_STALE_LOADED 2>/dev/null || true

	# Define the constants that _normalize_reassign_self needs
	FEEDBACK_ROUTED_LABELS=(
		"source:ci-feedback"
		"source:conflict-feedback"
		"source:review-feedback"
	)
	FEEDBACK_ROUTED_MARKERS=(
		"<!-- ci-feedback:PR"
		"<!-- conflict-feedback:PR"
		"<!-- review-followup:PR"
	)

	# Stub the stale module so source won't fail on its functions
	_PULSE_ISSUE_RECONCILE_STALE_LOADED=1
	# Stub functions from the stale module that might be referenced
	_normalize_clear_status_labels() { return 0; }
	_normalize_stale_get_dispatch_info() { return 0; }
	_normalize_stale_should_skip_reset() { return 0; }
	_normalize_unassign_stale() { return 0; }

	# Stub other dependencies from shared-constants.sh / worker-lifecycle-common.sh
	# that the module-level code or other functions may reference
	if ! type print_warning &>/dev/null; then
		print_warning() { echo "[WARN] $*"; return 0; }
	fi
	if ! type print_info &>/dev/null; then
		print_info() { echo "[INFO] $*"; return 0; }
	fi
	# Stub arrays that label-invariant functions need (we don't test those here)
	ISSUE_STATUS_LABEL_PRECEDENCE=("done" "in-review" "in-progress" "queued" "claimed" "available" "blocked")
	ISSUE_TIER_LABEL_RANK=("reasoning" "standard" "simple")

	# Set SCRIPT_DIR for the source chain (used by pulse-issue-reconcile.sh
	# to locate pulse-issue-reconcile-stale.sh)
	export SCRIPT_DIR="$SCRIPTS_DIR"

	local src_file="${SCRIPTS_DIR}/pulse-issue-reconcile.sh"
	if [[ -f "$src_file" ]]; then
		# shellcheck source=/dev/null
		source "$src_file"
		return 0
	fi
	echo "ERROR: cannot find pulse-issue-reconcile.sh at ${src_file}" >&2
	return 1
}

get_assigned_issues() {
	if [[ -f "${TEST_ROOT}/assigned.txt" ]]; then
		cat "${TEST_ROOT}/assigned.txt"
	fi
	return 0
}

reset_assignments() {
	rm -f "${TEST_ROOT}/assigned.txt"
	return 0
}

# ─── Test 1: status:queued with no assignees → self-assigned (regression) ───
test_queued_no_assignee_self_assigns() {
	setup_test_env
	local json='[
		{"number": 100, "assignees": [], "labels": [{"name": "status:queued"}, {"name": "origin:worker"}]}
	]'
	create_gh_stub "$json"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	source_function_under_test

	_normalize_reassign_self "testrunner" "${TEST_ROOT}/repos.json" "${TEST_ROOT}/bin/dedup-stub.sh"

	local assigned
	assigned=$(get_assigned_issues)
	if echo "$assigned" | grep -q "100"; then
		print_result "status:queued + no assignee → self-assigned" 0
	else
		print_result "status:queued + no assignee → self-assigned" 1 \
			"Expected issue 100 to be assigned, got: ${assigned:-<empty>}"
	fi
	cleanup_test_env
	return 0
}

# ─── Test 2: status:in-progress with no assignees → self-assigned (regression) ───
test_in_progress_no_assignee_self_assigns() {
	setup_test_env
	local json='[
		{"number": 101, "assignees": [], "labels": [{"name": "status:in-progress"}, {"name": "origin:worker"}]}
	]'
	create_gh_stub "$json"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	source_function_under_test

	_normalize_reassign_self "testrunner" "${TEST_ROOT}/repos.json" "${TEST_ROOT}/bin/dedup-stub.sh"

	local assigned
	assigned=$(get_assigned_issues)
	if echo "$assigned" | grep -q "101"; then
		print_result "status:in-progress + no assignee → self-assigned" 0
	else
		print_result "status:in-progress + no assignee → self-assigned" 1 \
			"Expected issue 101 to be assigned, got: ${assigned:-<empty>}"
	fi
	cleanup_test_env
	return 0
}

# ─── Test 3: status:available + origin:worker + source:ci-feedback → self-assigned ───
test_available_worker_ci_feedback_label_self_assigns() {
	setup_test_env
	local json='[
		{"number": 200, "assignees": [], "labels": [{"name": "status:available"}, {"name": "origin:worker"}, {"name": "source:ci-feedback"}]}
	]'
	create_gh_stub "$json"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	source_function_under_test

	_normalize_reassign_self "testrunner" "${TEST_ROOT}/repos.json" "${TEST_ROOT}/bin/dedup-stub.sh"

	local assigned
	assigned=$(get_assigned_issues)
	if echo "$assigned" | grep -q "200"; then
		print_result "status:available + origin:worker + source:ci-feedback → self-assigned" 0
	else
		print_result "status:available + origin:worker + source:ci-feedback → self-assigned" 1 \
			"Expected issue 200 to be assigned, got: ${assigned:-<empty>}"
	fi
	cleanup_test_env
	return 0
}

# ─── Test 4: status:available + origin:worker + source:conflict-feedback → self-assigned ───
test_available_worker_conflict_feedback_label_self_assigns() {
	setup_test_env
	local json='[
		{"number": 201, "assignees": [], "labels": [{"name": "status:available"}, {"name": "origin:worker"}, {"name": "source:conflict-feedback"}]}
	]'
	create_gh_stub "$json"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	source_function_under_test

	_normalize_reassign_self "testrunner" "${TEST_ROOT}/repos.json" "${TEST_ROOT}/bin/dedup-stub.sh"

	local assigned
	assigned=$(get_assigned_issues)
	if echo "$assigned" | grep -q "201"; then
		print_result "status:available + origin:worker + source:conflict-feedback → self-assigned" 0
	else
		print_result "status:available + origin:worker + source:conflict-feedback → self-assigned" 1 \
			"Expected issue 201 to be assigned, got: ${assigned:-<empty>}"
	fi
	cleanup_test_env
	return 0
}

# ─── Test 5: status:available + origin:worker + body marker → self-assigned ───
test_available_worker_body_marker_self_assigns() {
	setup_test_env
	local body_marker='<!-- ci-feedback:PR1234 -->'
	local json='[
		{"number": 300, "assignees": [], "labels": [{"name": "status:available"}, {"name": "origin:worker"}]}
	]'
	create_gh_stub "$json" "$body_marker"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	source_function_under_test

	_normalize_reassign_self "testrunner" "${TEST_ROOT}/repos.json" "${TEST_ROOT}/bin/dedup-stub.sh"

	local assigned
	assigned=$(get_assigned_issues)
	if echo "$assigned" | grep -q "300"; then
		print_result "status:available + origin:worker + body marker → self-assigned" 0
	else
		print_result "status:available + origin:worker + body marker → self-assigned" 1 \
			"Expected issue 300 to be assigned, got: ${assigned:-<empty>}"
	fi
	cleanup_test_env
	return 0
}

# ─── Test 6: status:available + NO origin:worker → NOT assigned ───
test_available_no_worker_label_skips() {
	setup_test_env
	local json='[
		{"number": 400, "assignees": [], "labels": [{"name": "status:available"}, {"name": "origin:interactive"}, {"name": "source:ci-feedback"}]}
	]'
	create_gh_stub "$json"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	source_function_under_test

	_normalize_reassign_self "testrunner" "${TEST_ROOT}/repos.json" "${TEST_ROOT}/bin/dedup-stub.sh"

	local assigned
	assigned=$(get_assigned_issues)
	if [[ -z "$assigned" ]]; then
		print_result "status:available + no origin:worker → skipped" 0
	else
		print_result "status:available + no origin:worker → skipped" 1 \
			"Expected no assignment, but got: ${assigned}"
	fi
	cleanup_test_env
	return 0
}

# ─── Test 7: status:available + existing assignees → NOT assigned ───
test_available_with_assignee_skips() {
	setup_test_env
	local json='[
		{"number": 500, "assignees": [{"login": "existing-user"}], "labels": [{"name": "status:available"}, {"name": "origin:worker"}, {"name": "source:ci-feedback"}]}
	]'
	create_gh_stub "$json"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	source_function_under_test

	_normalize_reassign_self "testrunner" "${TEST_ROOT}/repos.json" "${TEST_ROOT}/bin/dedup-stub.sh"

	local assigned
	assigned=$(get_assigned_issues)
	if [[ -z "$assigned" ]]; then
		print_result "status:available + existing assignee → skipped" 0
	else
		print_result "status:available + existing assignee → skipped" 1 \
			"Expected no assignment, but got: ${assigned}"
	fi
	cleanup_test_env
	return 0
}

# ─── Test 8: Fresh scanner issue (status:available, no feedback markers) → NOT assigned ───
test_fresh_scanner_issue_skips() {
	setup_test_env
	local json='[
		{"number": 600, "assignees": [], "labels": [{"name": "status:available"}, {"name": "origin:worker"}, {"name": "source:review-scanner"}]}
	]'
	# No body markers
	create_gh_stub "$json" "This is a fresh scanner issue with no feedback markers"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	source_function_under_test

	_normalize_reassign_self "testrunner" "${TEST_ROOT}/repos.json" "${TEST_ROOT}/bin/dedup-stub.sh"

	local assigned
	assigned=$(get_assigned_issues)
	if [[ -z "$assigned" ]]; then
		print_result "fresh scanner issue (no feedback) → skipped" 0
	else
		print_result "fresh scanner issue (no feedback) → skipped" 1 \
			"Expected no assignment, but got: ${assigned}"
	fi
	cleanup_test_env
	return 0
}

# ─── Run all tests ───
main() {
	echo "=== _normalize_reassign_self tests (t2396) ==="
	echo ""

	test_queued_no_assignee_self_assigns
	test_in_progress_no_assignee_self_assigns
	test_available_worker_ci_feedback_label_self_assigns
	test_available_worker_conflict_feedback_label_self_assigns
	test_available_worker_body_marker_self_assigns
	test_available_no_worker_label_skips
	test_available_with_assignee_skips
	test_fresh_scanner_issue_skips

	echo ""
	echo "=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
