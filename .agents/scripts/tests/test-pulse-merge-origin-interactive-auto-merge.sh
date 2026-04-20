#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for origin:interactive auto-merge gates (t2411).
#
# Verifies the six criteria that govern whether an origin:interactive PR is
# eligible for auto-merge in pulse-merge.sh:
#   Case 1: OWNER (admin perm) passes _is_owner_or_member_author
#   Case 2: COLLABORATOR (write perm) fails _is_owner_or_member_author
#   Case 3: CI failure is a pre-gate boundary (not blocked by interactive gates)
#   Case 4: hold-for-review label blocks _check_interactive_pr_gates
#   Case 5: draft PR blocks _check_interactive_pr_gates
#   Case 6: CHANGES_REQUESTED is blocked by existing gate (boundary verified)
#
# No real repository is touched. The gh binary is replaced with a mock stub
# that serves canned responses from TEST_ROOT fixture files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

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
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG

	# Default permission fixture: admin (OWNER)
	printf '{"permission": "admin"}' >"${TEST_ROOT}/perm.json"

	# Mock gh: logs every call and returns canned data from TEST_ROOT fixtures.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_all_args=("$@")

# HEAD call for permission check (-i flag)
if [[ "$*" == *"-i"* && "$*" == *"permission"* ]]; then
	printf 'HTTP/2 200\n'
	exit 0
fi

# Permission API
if [[ "$*" == *"collaborators"* && "$*" == *"permission"* ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter" <"${TEST_ROOT}/perm.json"
	else
		cat "${TEST_ROOT}/perm.json"
	fi
	exit 0
fi

# labels+isDraft fetch for interactive gate
if [[ "$*" == *"--json"*"labels,isDraft"* || "$*" == *"labels,isDraft"* ]]; then
	cat "${TEST_ROOT:-/tmp}/pr-info.json" 2>/dev/null \
		|| printf '{"labels":[],"isDraft":false}'
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Default PR info: not draft, no special labels
	printf '{"labels":[],"isDraft":false}' >"${TEST_ROOT}/pr-info.json"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_helpers_under_test() {
	local src_owner src_interactive
	src_owner=$(awk '
		/^_is_owner_or_member_author\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	src_interactive=$(awk '
		/^_check_interactive_pr_gates\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src_owner" || -z "$src_interactive" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_owner"
	# shellcheck disable=SC1090
	eval "$src_interactive"
	return 0
}

# =============================================================================
# Case 1: OWNER (admin permission) — _is_owner_or_member_author returns 0
# =============================================================================
test_case1_owner_admin_perm_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"permission": "admin"}' >"${TEST_ROOT}/perm.json"
	: >"$GH_LOG"

	local result=0
	_is_owner_or_member_author "owner-user" "owner/repo" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 1: OWNER (admin) passes _is_owner_or_member_author" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case 1: OWNER (admin) passes _is_owner_or_member_author" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 2: COLLABORATOR (write permission) — _is_owner_or_member_author returns 1
# =============================================================================
test_case2_collaborator_write_perm_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"permission": "write"}' >"${TEST_ROOT}/perm.json"
	: >"$GH_LOG"

	local result=0
	_is_owner_or_member_author "collab-user" "owner/repo" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 2: COLLABORATOR (write) blocked by _is_owner_or_member_author" 1 \
			"Expected non-zero exit, got 0 (COLLABORATOR should not pass OWNER/MEMBER check)"
	else
		print_result "Case 2: COLLABORATOR (write) blocked by _is_owner_or_member_author" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 3: CI failure is a pre-gate concern — _check_interactive_pr_gates
# does NOT handle CI failure. Boundary: passes when PR is not draft and
# does not have hold-for-review (CI check is the caller's responsibility).
# =============================================================================
test_case3_ci_failure_is_pre_gate_boundary() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	# Simulate: interactive labels, not draft, no hold-for-review.
	# CI failure is checked BEFORE _check_interactive_pr_gates is called.
	local labels="origin:interactive"
	local result=0
	_check_interactive_pr_gates "101" "owner/repo" "$labels" "false" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 3: CI failure pre-gate boundary — _check_interactive_pr_gates passes" 1 \
			"Expected exit 0 (CI is pre-gate), got ${result}"
	else
		print_result "Case 3: CI failure pre-gate boundary — _check_interactive_pr_gates passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 4: hold-for-review label → _check_interactive_pr_gates returns 1
# =============================================================================
test_case4_hold_for_review_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	local labels="origin:interactive,hold-for-review"
	local result=0
	_check_interactive_pr_gates "102" "owner/repo" "$labels" "false" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 4: hold-for-review label blocks _check_interactive_pr_gates" 1 \
			"Expected non-zero exit, got 0 (hold-for-review should block)"
	else
		# Verify the log message was written
		if ! grep -q "hold-for-review opt-out" "$LOGFILE" 2>/dev/null; then
			print_result "Case 4: hold-for-review label blocks _check_interactive_pr_gates" 1 \
				"Exit was non-zero but hold-for-review log message missing from ${LOGFILE}"
		else
			print_result "Case 4: hold-for-review label blocks _check_interactive_pr_gates" 0
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 5: draft PR → _check_interactive_pr_gates returns 1
# =============================================================================
test_case5_draft_pr_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	local labels="origin:interactive"
	local result=0
	_check_interactive_pr_gates "103" "owner/repo" "$labels" "true" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 5: draft PR blocks _check_interactive_pr_gates" 1 \
			"Expected non-zero exit, got 0 (draft should block)"
	else
		if ! grep -q "draft PR not eligible" "$LOGFILE" 2>/dev/null; then
			print_result "Case 5: draft PR blocks _check_interactive_pr_gates" 1 \
				"Exit was non-zero but draft log message missing from ${LOGFILE}"
		else
			print_result "Case 5: draft PR blocks _check_interactive_pr_gates" 0
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 6: CHANGES_REQUESTED is an existing gate — _check_interactive_pr_gates
# runs AFTER the existing CHANGES_REQUESTED check. Boundary: verifying the
# helper itself is agnostic to review state (review state is handled upstream).
# =============================================================================
test_case6_changes_requested_is_upstream_gate() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	# _check_interactive_pr_gates does not receive or check review state.
	# It only blocks on draft and hold-for-review.
	# A non-draft, non-h-f-r interactive PR passes this helper regardless.
	local labels="origin:interactive"
	local result=0
	_check_interactive_pr_gates "104" "owner/repo" "$labels" "false" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 6: CHANGES_REQUESTED is upstream — _check_interactive_pr_gates passes" 1 \
			"Expected exit 0 (CHANGES_REQUESTED is upstream gate), got ${result}"
	else
		print_result "Case 6: CHANGES_REQUESTED is upstream — _check_interactive_pr_gates passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Run all cases
# =============================================================================
main() {
	if [[ ! -f "$MERGE_SCRIPT" ]]; then
		printf 'ERROR: merge script not found: %s\n' "$MERGE_SCRIPT" >&2
		exit 1
	fi

	test_case1_owner_admin_perm_passes
	test_case2_collaborator_write_perm_blocked
	test_case3_ci_failure_is_pre_gate_boundary
	test_case4_hold_for_review_blocked
	test_case5_draft_pr_blocked
	test_case6_changes_requested_is_upstream_gate

	echo ""
	printf 'Results: %d/%d passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
	return 0
}

main "$@"
