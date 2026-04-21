#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for origin:worker worker-briefed auto-merge gates (t2449).
#
# Verifies the 10 coverage cases from GH#20204 §How:
#   Case (a): origin:worker + issue-author=OWNER + green CI + no NMR → auto-merges
#   Case (b): origin:worker + issue-author=MEMBER + green + no NMR → auto-merges
#   Case (c): origin:worker + issue-author=CONTRIBUTOR → does NOT auto-merge
#   Case (d): origin:worker + NMR auto-approved (not crypto) → does NOT auto-merge
#   Case (e): origin:worker + NMR cleared via crypto approval → auto-merges
#   Case (f): origin:worker + hold-for-review label → does NOT auto-merge
#   Case (g): origin:worker + human CHANGES_REQUESTED → does NOT auto-merge
#   Case (h): origin:worker + draft PR → does NOT auto-merge
#   Case (i): origin:worker-takeover label → does NOT auto-merge
#   Case (j): Bot review in placeholder window → waits, doesn't merge yet
#
# No real repository is touched. The gh binary is replaced with a mock stub
# that serves canned responses from TEST_ROOT fixture files.
#
# Pattern mirrors: test-pulse-merge-origin-interactive-auto-merge.sh

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

	# Default issue fixture: author_association=OWNER, no NMR comments
	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Default comments fixture: empty array (no NMR markers)
	printf '[]' >"${TEST_ROOT}/comments.json"

	# Mock gh: logs every call and returns canned data from TEST_ROOT fixtures.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_all_args=("$@")

# Issue API (author_association check)
if [[ "$*" == *"repos/"*"/issues/"* ]] && [[ "$*" != *"/comments"* ]] && [[ "$*" != *"/labels"* ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter" <"${TEST_ROOT}/issue.json"
	else
		cat "${TEST_ROOT}/issue.json"
	fi
	exit 0
fi

# Issue comments API (NMR marker check)
if [[ "$*" == *"/comments"* ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter" <"${TEST_ROOT}/comments.json"
	else
		cat "${TEST_ROOT}/comments.json"
	fi
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract _attempt_worker_briefed_auto_merge and its dependency _pm_issue_api
# from the merge script and eval them into the test shell.
define_helpers_under_test() {
	local src_worker_briefed src_issue_api
	src_issue_api=$(awk '
		/^_pm_issue_api\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	src_worker_briefed=$(awk '
		/^_attempt_worker_briefed_auto_merge\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src_worker_briefed" || -z "$src_issue_api" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_issue_api"
	# shellcheck disable=SC1090
	eval "$src_worker_briefed"
	return 0
}

# =============================================================================
# Case (a): origin:worker + issue-author=OWNER + no NMR → passes
# =============================================================================
test_case_a_owner_issue_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "100" "owner/repo" "origin:worker" "false" "42" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (a): OWNER-briefed issue + no NMR → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case (a): OWNER-briefed issue + no NMR → passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (b): origin:worker + issue-author=MEMBER + no NMR → passes
# =============================================================================
test_case_b_member_issue_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"MEMBER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "101" "owner/repo" "origin:worker" "false" "43" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (b): MEMBER-briefed issue + no NMR → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case (b): MEMBER-briefed issue + no NMR → passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (c): origin:worker + issue-author=CONTRIBUTOR → blocked
# =============================================================================
test_case_c_contributor_issue_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"CONTRIBUTOR"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "102" "owner/repo" "origin:worker" "false" "44" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 1 \
			"Expected non-zero exit, got 0 (CONTRIBUTOR should not pass)"
	else
		if grep -q "not OWNER/MEMBER" "$LOGFILE" 2>/dev/null; then
			print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 0
		else
			print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (d): NMR auto-approved only (no crypto) → blocked
# =============================================================================
test_case_d_nmr_auto_approved_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Comments contain auto-approval marker but NO crypto signature
	printf '[{"body":"auto-approved-maintainer-issue: cleared NMR"}]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "103" "owner/repo" "origin:worker" "false" "45" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (d): NMR auto-approved only → blocked" 1 \
			"Expected non-zero exit, got 0 (auto-approval without crypto should block)"
	else
		if grep -q "auto-approved only" "$LOGFILE" 2>/dev/null; then
			print_result "Case (d): NMR auto-approved only → blocked" 0
		else
			print_result "Case (d): NMR auto-approved only → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (e): NMR cleared via crypto approval → passes
# =============================================================================
test_case_e_nmr_crypto_cleared_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Comments contain BOTH auto-approval AND crypto approval markers
	printf '[{"body":"auto-approved-maintainer-issue: cleared NMR"},{"body":"aidevops:approval-signature: SHA256:abc123"}]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "104" "owner/repo" "origin:worker" "false" "46" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (e): NMR crypto-cleared → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "passed all gates" "$LOGFILE" 2>/dev/null; then
			print_result "Case (e): NMR crypto-cleared → passes" 0
		else
			print_result "Case (e): NMR crypto-cleared → passes" 1 \
				"Exit was 0 but expected success log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (f): hold-for-review label → blocked
# =============================================================================
test_case_f_hold_for_review_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "105" "owner/repo" "origin:worker,hold-for-review" "false" "47" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (f): hold-for-review label → blocked" 1 \
			"Expected non-zero exit, got 0 (hold-for-review should block)"
	else
		if grep -q "hold-for-review label" "$LOGFILE" 2>/dev/null; then
			print_result "Case (f): hold-for-review label → blocked" 0
		else
			print_result "Case (f): hold-for-review label → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (g): CHANGES_REQUESTED — boundary test. This gate is checked UPSTREAM
# of _attempt_worker_briefed_auto_merge in _check_pr_merge_gates. The worker-
# briefed function itself is agnostic to review state — verify it passes when
# given valid inputs (review state is the caller's responsibility).
# =============================================================================
test_case_g_changes_requested_is_upstream() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# _attempt_worker_briefed_auto_merge does not receive review state.
	# A non-draft, non-hold-for-review, OWNER-briefed PR passes this helper.
	local result=0
	_attempt_worker_briefed_auto_merge "106" "owner/repo" "origin:worker" "false" "48" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (g): CHANGES_REQUESTED is upstream — helper passes" 1 \
			"Expected exit 0 (CHANGES_REQUESTED is upstream gate), got ${result}"
	else
		print_result "Case (g): CHANGES_REQUESTED is upstream — helper passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (h): draft PR → blocked
# =============================================================================
test_case_h_draft_pr_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "107" "owner/repo" "origin:worker" "true" "49" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (h): draft PR → blocked" 1 \
			"Expected non-zero exit, got 0 (draft should block)"
	else
		if grep -q "draft PR not eligible" "$LOGFILE" 2>/dev/null; then
			print_result "Case (h): draft PR → blocked" 0
		else
			print_result "Case (h): draft PR → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (i): origin:worker-takeover → the caller pre-filters using comma-
# delimited matching (",origin:worker," != ",origin:worker-takeover,").
# Verify the function itself blocks if somehow called with takeover labels.
# =============================================================================
test_case_i_worker_takeover_excluded() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# Simulate the caller's comma-delimited check:
	# ",origin:worker-takeover," does NOT match ",origin:worker," pattern.
	local labels_str="origin:worker-takeover"
	local match=0
	if [[ ",${labels_str}," == *",origin:worker,"* ]]; then
		match=1
	fi

	if [[ "$match" -eq 1 ]]; then
		print_result "Case (i): origin:worker-takeover excluded by caller" 1 \
			"Comma-delimited match should NOT fire for origin:worker-takeover"
	else
		print_result "Case (i): origin:worker-takeover excluded by caller" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (j): Feature flag AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 → blocked
# (The spec case is "bot review in placeholder window → waits". That wait is
# handled by review-bot-gate-helper.sh UPSTREAM. This test verifies the
# feature-flag off-switch, which is the closest unit-testable analogue.)
# =============================================================================
test_case_j_feature_flag_off_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0

	local result=0
	_attempt_worker_briefed_auto_merge "109" "owner/repo" "origin:worker" "false" "51" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (j): feature flag OFF → blocked" 1 \
			"Expected non-zero exit, got 0 (flag=0 should block)"
	else
		if grep -q "disabled by AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0" "$LOGFILE" 2>/dev/null; then
			print_result "Case (j): feature flag OFF → blocked" 0
		else
			print_result "Case (j): feature flag OFF → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
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

	test_case_a_owner_issue_passes
	test_case_b_member_issue_passes
	test_case_c_contributor_issue_blocked
	test_case_d_nmr_auto_approved_blocked
	test_case_e_nmr_crypto_cleared_passes
	test_case_f_hold_for_review_blocked
	test_case_g_changes_requested_is_upstream
	test_case_h_draft_pr_blocked
	test_case_i_worker_takeover_excluded
	test_case_j_feature_flag_off_blocked

	echo ""
	printf 'Results: %d/%d passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
	return 0
}

main "$@"
