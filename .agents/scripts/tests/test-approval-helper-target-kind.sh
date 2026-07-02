#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for approval-helper.sh issue/PR target kind diagnostics.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0
LAST_OUTPUT=""
LAST_RC=0

pass() {
	local name="$1"
	printf '  PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf '  FAIL: %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '    %s\n' "$detail"
	fi
	FAIL=$((FAIL + 1))
	return 0
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$name"
	else
		fail "$name" "expected '${expected}', got '${actual}'"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing '${needle}'"
	fi
	return 0
}

run_case() {
	local name="$1"
	local script="$2"
	local expected_rc="$3"
	local output=""
	local rc=0

	output=$(APPROVAL_HELPER_UNDER_TEST="$PARENT_DIR/approval-helper.sh" bash -c "$script" 2>&1) || rc=$?
	LAST_OUTPUT="$output"
	LAST_RC=$rc
	assert_eq "$name rc" "$expected_rc" "$rc"
	return 0
}

printf 'Test: approval-helper target kind diagnostics\n'
printf '=============================================\n\n'

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "PR command rejects issue target" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_fetch_issue_json() { printf "%s" "{\"number\":26392,\"title\":\"Issue title\"}"; return 0; }
	_validate_approval_target_kind pr 26392 marcusquinn/aidevops
' 1
assert_contains "PR command names wrong target kind" "$LAST_OUTPUT" "#26392 in marcusquinn/aidevops is an issue, not a PR."
assert_contains "PR command advises issue approval command" "$LAST_OUTPUT" "sudo aidevops approve issue 26392 marcusquinn/aidevops"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "issue command rejects PR target" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_fetch_issue_json() { printf "%s" "{\"number\":99,\"pull_request\":{\"url\":\"https://api.github.test/pr\"}}"; return 0; }
	_validate_approval_target_kind issue 99 marcusquinn/aidevops
' 1
assert_contains "issue command names wrong target kind" "$LAST_OUTPUT" "#99 in marcusquinn/aidevops is a PR, not an issue."
assert_contains "issue command advises PR approval command" "$LAST_OUTPUT" "sudo aidevops approve pr 99 marcusquinn/aidevops"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "missing target gives check issue or PR guidance" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_fetch_issue_json() { return 1; }
	_validate_approval_target_kind pr 404 marcusquinn/aidevops
' 1
assert_contains "missing target asks to check target type" "$LAST_OUTPUT" "Check the number, repo, and whether this is an issue or PR."
assert_contains "missing PR target suggests issue command" "$LAST_OUTPUT" "sudo aidevops approve issue 404 marcusquinn/aidevops"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "matching issue target succeeds" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_fetch_issue_json() { printf "%s" "{\"number\":123}"; return 0; }
	_validate_approval_target_kind issue 123 marcusquinn/aidevops
' 0

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "matching PR target succeeds" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_fetch_issue_json() { printf "%s" "{\"number\":456,\"pull_request\":{}}"; return 0; }
	_validate_approval_target_kind pr 456 marcusquinn/aidevops
' 0

printf '\n%d tests passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
