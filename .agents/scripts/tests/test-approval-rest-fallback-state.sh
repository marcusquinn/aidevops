#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for approval-helper.sh REST fallback + state verification.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $name"
		printf '    expected: %s\n    actual:   %s\n' "$expected" "$actual"
		FAIL=$((FAIL + 1))
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
	assert_eq "$name rc" "$expected_rc" "$rc"
	printf '%s' "$output"
	return 0
}

echo "Test: approval-helper REST fallback and verified lifecycle state"
echo "================================================================="
echo ""

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
title_output=$(run_case "title fallback" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_rest_should_fallback() { return 0; }
	_rest_issue_view() { printf "Fallback title"; return 0; }
	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then return 1; fi
		return 1
	}
	_fetch_target_title issue 123 marcusquinn/aidevops
' 0)
assert_eq "title uses REST fallback value" "Fallback title" "${title_output##*$'\n'}"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
success_output=$(run_case "verified success" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_rest_should_fallback() { return 0; }
	gh_issue_edit_safe() { printf "%s\n" "$*" >"${TMPDIR:-/tmp}/approval-edit-args.$$"; return 0; }
	gh_issue_view() { printf "bug,auto-dispatch"; return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "issue" && "${2:-}" == "lock" ]]; then return 1; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "-X" && "${3:-}" == "PUT" ]]; then return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"auto-dispatch\"}],\"assignees\":[{\"login\":\"marcusquinn\"}],\"locked\":true}"
			return 0
		fi
		return 1
	}
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops
' 0)
if printf '%s' "$success_output" | grep -q "Labels updated"; then
	echo "  PASS: success path reports label update after verified edit"
	PASS=$((PASS + 1))
else
	echo "  FAIL: success path reports label update after verified edit"
	FAIL=$((FAIL + 1))
fi

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
failure_output=$(run_case "edit failure blocks success" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	gh_issue_edit_safe() { printf "simulated edit failure" >&2; return 1; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		return 1
	}
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops
' 1)
if printf '%s' "$failure_output" | grep -q "Failed to update approval labels/assignee"; then
	echo "  PASS: edit failure surfaces accurate blocked reason"
	PASS=$((PASS + 1))
else
	echo "  FAIL: edit failure surfaces accurate blocked reason"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
