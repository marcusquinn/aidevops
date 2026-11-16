#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38624: armed/pending PR whose head has no GitHub Actions check suite is
# recovered by one close/reopen (trusted same-repo only), once per head.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
FAILED=0

# shellcheck source=../pulse-merge-rest-state.sh
source "${SCRIPT_DIR}/../pulse-merge-rest-state.sh"

LOGFILE="${TEST_ROOT}/pulse.log"
AIDEVOPS_PULSE_MISSING_CHECKS_STATE_DIR="${TEST_ROOT}/state"
CALLS="${TEST_ROOT}/calls"
SUITES='{"check_suites":[{"app":{"slug":"coderabbit"}}]}'
PR_META='{"state":"open","head":{"sha":"abc123","repo":{"full_name":"o/r","fork":false}},"base":{"repo":{"full_name":"o/r"}},"author_association":"MEMBER"}'
: >"$LOGFILE"
: >"$CALLS"

# Stub the network boundary: _pmrs_gh_call <op> gh <args...>
_pmrs_gh_call() {
	local op="$1"
	shift
	printf '%s %s\n' "$op" "$*" >>"$CALLS"
	case "$*" in
	*check-suites*) printf '%s' "$SUITES" ;;
	"gh api repos/o/r/pulls/7") printf '%s' "$PR_META" ;;
	*) : ;;
	esac
	return 0
}
gh_commit_by_sha_cached() {
	printf '{"commit":{"committer":{"date":"2020-01-01T00:00:00Z"}}}'
	return 0
}
_pmp_update_branch_rest() {
	printf 'update-branch\n' >>"$CALLS"
	return 0
}
_pmrs_remediate_zero_job_runs() {
	return 1
}

# Assert the number of recorded gh calls matching a pattern.
# Args: $1=name, $2=pattern, $3=expected count
expect_calls() {
	local name="$1"
	local pattern="$2"
	local expected="$3"
	local actual=0
	actual=$(grep -c -- "$pattern" "$CALLS" || true)
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
		FAILED=1
	fi
	return 0
}

run_remediation() {
	_PULSE_REQUIRED_CHECKS_MISSING_COUNT=4
	_PULSE_REQUIRED_CHECKS_NONPASS_COUNT=4
	_PULSE_CHECKS_IN_FLIGHT_COUNT=0
	_pmp_remediate_missing_required_checks 7 o/r abc123 || true
	return 0
}

# Case 1: no Actions suite, trusted same-repo → one close + reopen
run_remediation || true
expect_calls "closes once" "pr close 7" 1
expect_calls "reopens once" "pr reopen 7" 1
expect_calls "no update-branch" "update-branch" 0
if grep -q "closed and reopened once" "$LOGFILE"; then
	printf 'PASS logs action\n'
else
	printf 'FAIL logs action\n'
	FAILED=1
fi

# Case 2: same head again (past cooldown) → no second reopen
sed -i 's/^abc123 [0-9]* reopen$/abc123 1 reopen/' "${AIDEVOPS_PULSE_MISSING_CHECKS_STATE_DIR}/"*
run_remediation || true
expect_calls "no second reopen" "pr reopen 7" 1

# Case 3: fork PR → never closed
rm -rf "$AIDEVOPS_PULSE_MISSING_CHECKS_STATE_DIR"
: >"$CALLS"
PR_META='{"state":"open","head":{"sha":"abc123","repo":{"full_name":"x/r","fork":true}},"base":{"repo":{"full_name":"o/r"}},"author_association":"MEMBER"}'
run_remediation || true
expect_calls "fork PR not closed" "pr close" 0

# Case 4: Actions suite present → no reopen
rm -rf "$AIDEVOPS_PULSE_MISSING_CHECKS_STATE_DIR"
: >"$CALLS"
PR_META='{"state":"open","head":{"sha":"abc123","repo":{"full_name":"o/r","fork":false}},"base":{"repo":{"full_name":"o/r"}},"author_association":"MEMBER"}'
SUITES='{"check_suites":[{"app":{"slug":"github-actions"}}]}'
run_remediation || true
expect_calls "actions suite present: no close" "pr close" 0

exit "$FAILED"
