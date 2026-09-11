#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../shared-gh-wrappers-checks.sh
source "${SCRIPT_DIR}/../shared-gh-wrappers-checks.sh"

MOCK_CHECK_RUNS_RC=0
MOCK_CHECK_RUNS_BODY='[]'
MOCK_STATUS_RC=0
MOCK_STATUS_BODY='[]'

_gh_checks_api_read() {
	local endpoint="$1"
	if [[ "$endpoint" == */check-runs ]]; then
		[[ "$MOCK_CHECK_RUNS_RC" -eq 0 ]] || return "$MOCK_CHECK_RUNS_RC"
		printf '%s\n' "$MOCK_CHECK_RUNS_BODY"
		return 0
	fi
	[[ "$MOCK_STATUS_RC" -eq 0 ]] || return "$MOCK_STATUS_RC"
	printf '%s\n' "$MOCK_STATUS_BODY"
	return 0
}

assert_outcome() {
	local description="$1"
	local expected_rc="$2"
	local expected_output="$3"
	local output="" rc=0 actual_output="" wanted_output=""
	output=$(gh_pr_check_runs_rest owner/repo abc123) || rc=$?
	actual_output="$output"
	wanted_output="$expected_output"
	if [[ -n "$expected_output" ]]; then
		actual_output=$(printf '%s' "$output" | jq -c . 2>/dev/null) || actual_output="$output"
		wanted_output=$(printf '%s' "$expected_output" | jq -c . 2>/dev/null) || wanted_output="$expected_output"
	fi
	if [[ "$rc" -ne "$expected_rc" || "$actual_output" != "$wanted_output" ]]; then
		printf 'FAIL %s (rc=%s output=%q)\n' "$description" "$rc" "$output"
		return 1
	fi
	printf 'PASS %s\n' "$description"
	return 0
}

assert_outcome "valid empty check set is distinguishable from failure" 0 '[]'

MOCK_CHECK_RUNS_RC=75
assert_outcome "local admission deferral is preserved" 75 ''

MOCK_CHECK_RUNS_RC=124
assert_outcome "transport timeout is preserved" 124 ''

MOCK_CHECK_RUNS_RC=1
assert_outcome "ordinary API failure remains non-zero" 1 ''

MOCK_CHECK_RUNS_RC=0
MOCK_CHECK_RUNS_BODY=''
assert_outcome "successful read with empty stdout fails closed" 1 ''

MOCK_CHECK_RUNS_BODY='[{"name":"required-a","conclusion":"success","status":"completed"}]'
MOCK_STATUS_RC=75
assert_outcome "optional legacy-status deferral does not erase authoritative checks" 0 \
	'[{"name":"required-a","conclusion":"success","status":"completed"}]'
