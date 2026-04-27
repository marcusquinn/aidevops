#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _pulse_merge_admin_safety_check() (t2934).
#
# This is the defense-in-depth gate evaluated immediately before the
# `gh pr merge --admin` invocation in _process_single_ready_pr. It restates
# the external-contributor gate at the call site so the safety property
# becomes local to the bypass operation. The 2026-04-07 incident (#17671,
# #17685, #3846) merged external-contributor PRs because the
# maintainer-gate.yml workflow's Check 0 only inspected the linked-issue
# label. PR #17868 hardened the workflow; this gate exists so that any
# future regression in upstream gate ordering, label-application timing,
# or new code paths cannot re-open the same threat.
#
# Cases covered:
#   A — collaborator PR (no external-contributor label, not a fork)        → return 0
#   B — external-contributor label, no closing keyword in PR body          → return 1
#   C — external-contributor label, linked issue, no crypto approval       → return 1
#   D — external-contributor label, linked issue, crypto approval present  → return 0
#   E — unlabeled fork PR (isCrossRepository=true), no crypto approval     → return 1
#   F — unlabeled fork PR (isCrossRepository=true), crypto approval        → return 0

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

# Set fixture state for one case: labels, isCrossRepository, body, approval.
set_fixture() {
	local labels_json="$1"
	local is_cross_repo="$2"
	local body="$3"
	local approval_result="$4"

	cat >"${TEST_ROOT}/labels.json" <<EOF
{"labels": ${labels_json}, "isCrossRepository": ${is_cross_repo}}
EOF

	# PR title / body fixtures used by _extract_linked_issue.
	printf 'test-pr-title' >"${TEST_ROOT}/title.txt"
	printf '%s' "$body" >"${TEST_ROOT}/body.txt"

	# approval-helper.sh stub output.
	printf '%s' "$approval_result" >"${TEST_ROOT}/approval-result.txt"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	mkdir -p "${TEST_ROOT}/agents/scripts"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG

	# Mock gh: only handles the two `gh pr view` shapes used by this gate
	# and its delegates. Any other call exits 0 silently.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# gh pr view N --repo R --json labels,isCrossRepository
if [[ "$*" == *"--json labels,isCrossRepository"* ]]; then
	cat "${TEST_ROOT}/labels.json"
	exit 0
fi

# gh pr view N --repo R --json title --jq ...
if [[ "$*" == *"--json title"* ]]; then
	cat "${TEST_ROOT}/title.txt"
	exit 0
fi

# gh pr view N --repo R --json body --jq ...
if [[ "$*" == *"--json body"* ]]; then
	cat "${TEST_ROOT}/body.txt"
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Mock approval-helper.sh — emits VERIFIED or NOT_VERIFIED based on fixture.
	export AGENTS_DIR="${TEST_ROOT}/agents"
	cat >"${TEST_ROOT}/agents/scripts/approval-helper.sh" <<'AHEOF'
#!/usr/bin/env bash
cat "${TEST_ROOT}/approval-result.txt"
AHEOF
	chmod +x "${TEST_ROOT}/agents/scripts/approval-helper.sh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract the function under test plus its delegates from pulse-merge.sh.
# The function calls _external_pr_has_linked_issue and
# _external_pr_linked_issue_crypto_approved, which themselves call
# _extract_linked_issue. All four are pure functions — no module-level state.
define_helpers_under_test() {
	local src
	src=$(awk '
		/^_extract_linked_issue\(\) \{/,/^}$/ { print }
		/^_external_pr_has_linked_issue\(\) \{/,/^}$/ { print }
		/^_external_pr_linked_issue_crypto_approved\(\) \{/,/^}$/ { print }
		/^_pulse_merge_admin_safety_check\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src"
	return 0
}

# =============================================================================
# Case A: collaborator PR — no external-contributor label, not a fork.
# Expected: returns 0 (safe to merge).
# =============================================================================

test_case_a_collaborator_pr_returns_0() {
	set_fixture '[{"name":"bug"},{"name":"tier:standard"}]' 'false' \
		'## Summary\n\nResolves #100' 'VERIFIED'

	local result
	_pulse_merge_admin_safety_check "100" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case A: collaborator PR returns 0" 1 \
			"Expected 0, got ${result}"
		return 0
	fi
	# No log message expected (function exits silently on collaborator path).
	if grep -q "DEFENSE-IN-DEPTH" "$LOGFILE"; then
		print_result "Case A: collaborator PR no log message" 1 \
			"Unexpected DEFENSE-IN-DEPTH log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case A: collaborator PR — returns 0, no log" 0
	return 0
}

# =============================================================================
# Case B: external-contributor labeled, no closing keyword in body.
# Expected: returns 1 (refused — no linked issue).
# =============================================================================

test_case_b_external_no_linked_issue_returns_1() {
	: >"$LOGFILE"
	set_fixture '[{"name":"external-contributor"}]' 'false' \
		'## Summary\n\nFor #200 (parent reference, not closing)' 'VERIFIED'

	local result
	_pulse_merge_admin_safety_check "200" "owner/repo" || result=$?
	result=${result:-0}

	if [[ "$result" -ne 1 ]]; then
		print_result "Case B: external no linked issue returns 1" 1 \
			"Expected 1, got ${result}"
		return 0
	fi
	if ! grep -qF "REFUSING --admin merge" "$LOGFILE"; then
		print_result "Case B: refusal logged" 1 \
			"Expected REFUSING log entry. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if ! grep -qF "no linked issue" "$LOGFILE"; then
		print_result "Case B: no-linked-issue reason logged" 1 \
			"Expected 'no linked issue' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case B: external no linked issue — returns 1, refusal logged" 0
	return 0
}

# =============================================================================
# Case C: external-contributor labeled, linked issue, no crypto approval.
# Expected: returns 1 (refused — issue lacks approval).
# =============================================================================

test_case_c_external_no_approval_returns_1() {
	: >"$LOGFILE"
	set_fixture '[{"name":"external-contributor"}]' 'false' \
		'## Summary\n\nResolves #300' 'NOT_VERIFIED'

	local result
	_pulse_merge_admin_safety_check "300" "owner/repo" || result=$?
	result=${result:-0}

	if [[ "$result" -ne 1 ]]; then
		print_result "Case C: external no approval returns 1" 1 \
			"Expected 1, got ${result}"
		return 0
	fi
	if ! grep -qF "lacks crypto approval" "$LOGFILE"; then
		print_result "Case C: lacks-crypto-approval reason logged" 1 \
			"Expected 'lacks crypto approval' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case C: external no approval — returns 1, refusal logged" 0
	return 0
}

# =============================================================================
# Case D: external-contributor labeled, linked issue, crypto approval present.
# Expected: returns 0 (allowed — gate satisfied).
# =============================================================================

test_case_d_external_with_approval_returns_0() {
	: >"$LOGFILE"
	set_fixture '[{"name":"external-contributor"}]' 'false' \
		'## Summary\n\nResolves #400' 'VERIFIED'

	local result
	_pulse_merge_admin_safety_check "400" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case D: external with approval returns 0" 1 \
			"Expected 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if grep -q "REFUSING" "$LOGFILE"; then
		print_result "Case D: no refusal logged" 1 \
			"Unexpected REFUSING log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case D: external with approval — returns 0, no refusal" 0
	return 0
}

# =============================================================================
# Case E: unlabeled fork PR (isCrossRepository=true, no external label),
# no crypto approval. Tests the label-system-failure detection path.
# Expected: returns 1 (refused — fork detected, no approval).
# =============================================================================

test_case_e_unlabeled_fork_no_approval_returns_1() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'true' \
		'## Summary\n\nResolves #500' 'NOT_VERIFIED'

	local result
	_pulse_merge_admin_safety_check "500" "owner/repo" || result=$?
	result=${result:-0}

	if [[ "$result" -ne 1 ]]; then
		print_result "Case E: unlabeled fork no approval returns 1" 1 \
			"Expected 1, got ${result}"
		return 0
	fi
	# Verify the label-system-failure log was emitted.
	if ! grep -qF "fork PR missing external-contributor label" "$LOGFILE"; then
		print_result "Case E: label-system-failure logged" 1 \
			"Expected 'fork PR missing external-contributor label' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if ! grep -qF "REFUSING --admin merge" "$LOGFILE"; then
		print_result "Case E: refusal logged" 1 \
			"Expected REFUSING log entry. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case E: unlabeled fork no approval — returns 1, label-failure detected" 0
	return 0
}

# =============================================================================
# Case F: unlabeled fork PR with crypto approval — verifies the fork-detection
# path doesn't over-block legitimate approved external work.
# Expected: returns 0 (allowed — fork detected, but approved).
# =============================================================================

test_case_f_unlabeled_fork_with_approval_returns_0() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'true' \
		'## Summary\n\nResolves #600' 'VERIFIED'

	local result
	_pulse_merge_admin_safety_check "600" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case F: unlabeled fork with approval returns 0" 1 \
			"Expected 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	# Label-failure log expected (fork detected without label) but no refusal.
	if ! grep -qF "fork PR missing external-contributor label" "$LOGFILE"; then
		print_result "Case F: label-failure detected" 1 \
			"Expected fork-detection log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if grep -q "REFUSING" "$LOGFILE"; then
		print_result "Case F: no refusal logged" 1 \
			"Unexpected REFUSING log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case F: unlabeled fork with approval — returns 0, fork detected but allowed" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_case_a_collaborator_pr_returns_0
	test_case_b_external_no_linked_issue_returns_1
	test_case_c_external_no_approval_returns_1
	test_case_d_external_with_approval_returns_0
	test_case_e_unlabeled_fork_no_approval_returns_1
	test_case_f_unlabeled_fork_with_approval_returns_0

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
