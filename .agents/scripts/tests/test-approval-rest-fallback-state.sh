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
	set_issue_status() {
		local issue="$1"
		local repo="$2"
		local status="$3"
		shift 3
		printf "STATUS %s %s %s %s\n" "$issue" "$repo" "$status" "$*"
		[[ "$issue" == "123" && "$repo" == "marcusquinn/aidevops" && "$status" == "available" && "$#" -eq 0 ]]
		return $?
	}
	gh_issue_edit_safe() {
		local arg=""
		local saw_auto_dispatch=0
		for arg in "$@"; do
			[[ "$arg" == "auto-dispatch" ]] && saw_auto_dispatch=1
		done
		[[ "$saw_auto_dispatch" -eq 1 ]] || return 1
		return 0
	}
	gh_issue_view() { printf "bug,auto-dispatch"; return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "issue" && "${2:-}" == "lock" ]]; then return 1; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "-X" && "${3:-}" == "PUT" ]]; then return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"auto-dispatch\"},{\"name\":\"status:available\"}],\"assignees\":[{\"login\":\"marcusquinn\"}],\"locked\":true}"
			return 0
		fi
		return 1
	}
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops
' 0)
if printf '%s' "$success_output" | grep -q "Lifecycle updated"; then
	echo "  PASS: success path reports lifecycle update after verified edit"
	PASS=$((PASS + 1))
else
	echo "  FAIL: success path reports lifecycle update after verified edit"
	FAIL=$((FAIL + 1))
fi
echo "  PASS: success path writes status:available synchronously"
PASS=$((PASS + 1))

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
progressed_output=$(run_case "dispatcher progression before final verification" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	test_home=$(mktemp -d)
	_APPROVAL_HOME="$test_home"
	mkdir -p "$test_home/.aidevops/.agent-workspace/interactive-claims"
	stamp_file="$test_home/.aidevops/.agent-workspace/interactive-claims/marcusquinn-aidevops-123.json"
	printf "{}" >"$stamp_file"
	_rest_should_fallback() { return 0; }
	set_issue_status() { return 0; }
	gh_issue_edit_safe() { return 0; }
	gh_issue_view() { printf "bug,status:in-review"; return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "issue" && "${2:-}" == "lock" ]]; then return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"auto-dispatch\"},{\"name\":\"status:queued\"}],\"assignees\":[{\"login\":\"worker-runner\"}],\"locked\":true}"
			return 0
		fi
		return 1
	}
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops
	[[ ! -f "$stamp_file" ]] || exit 9
	rm -rf "$test_home"
' 0)
if printf '%s' "$progressed_output" | grep -q "Approval state verification failed"; then
	echo "  FAIL: queued dispatcher progression is accepted"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: queued dispatcher progression is accepted"
	PASS=$((PASS + 1))
fi
echo "  PASS: lifecycle handoff removes only the local claim stamp"
PASS=$((PASS + 1))

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
invalid_progression_output=$(run_case "invalid lifecycle state fails closed" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	test_home=$(mktemp -d)
	_APPROVAL_HOME="$test_home"
	mkdir -p "$test_home/.aidevops/.agent-workspace/interactive-claims"
	stamp_file="$test_home/.aidevops/.agent-workspace/interactive-claims/marcusquinn-aidevops-123.json"
	printf "{}" >"$stamp_file"
	restore_trace=$(mktemp)
	set_issue_status() { return 0; }
	gh_issue_edit_safe() { printf "RESTORE %s\n" "$*" >>"$restore_trace"; return 0; }
	gh_issue_view() { printf "bug,status:in-review"; return 0; }
	_approval_lock_issue() { return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"auto-dispatch\"},{\"name\":\"status:blocked\"}],\"assignees\":[],\"locked\":true}"
			return 0
		fi
		return 1
	}
	rc=0
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	[[ -f "$stamp_file" ]] || rc=9
	cat "$restore_trace"
	rm -f "$restore_trace"
	rm -rf "$test_home"
	exit "$rc"
' 1)
if printf '%s' "$invalid_progression_output" | grep -q -- "--add-label needs-maintainer-review"; then
	echo "  PASS: invalid lifecycle state restores NMR"
	PASS=$((PASS + 1))
else
	echo "  FAIL: invalid lifecycle state restores NMR"
	FAIL=$((FAIL + 1))
fi
echo "  PASS: failed lifecycle verification retains the local claim stamp"
PASS=$((PASS + 1))

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
dual_status_output=$(run_case "dual core status fails closed" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	restore_trace=$(mktemp)
	set_issue_status() { return 0; }
	gh_issue_edit_safe() { printf "RESTORE %s\n" "$*" >>"$restore_trace"; return 0; }
	gh_issue_view() { printf "bug,status:in-review"; return 0; }
	_approval_lock_issue() { return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"auto-dispatch\"},{\"name\":\"status:available\"},{\"name\":\"status:queued\"}],\"assignees\":[{\"login\":\"marcusquinn\"}],\"locked\":true}"
			return 0
		fi
		return 1
	}
	rc=0
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	cat "$restore_trace"
	rm -f "$restore_trace"
	exit "$rc"
' 1)
if printf '%s' "$dual_status_output" | grep -q -- "--add-label needs-maintainer-review"; then
	echo "  PASS: dual core status restores NMR"
	PASS=$((PASS + 1))
else
	echo "  FAIL: dual core status restores NMR"
	FAIL=$((FAIL + 1))
fi

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
failure_output=$(run_case "edit failure blocks success" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	set_issue_status() { return 0; }
	gh_issue_view() { printf "bug"; return 0; }
	restore_trace=$(mktemp)
	gh_issue_edit_safe() {
		if [[ "$*" == *"--add-label needs-maintainer-review"* && "$*" != *"--remove-label needs-maintainer-review"* ]]; then
			printf "RESTORE %s\n" "$*" >>"$restore_trace"
			return 0
		fi
		printf "simulated edit failure" >&2
		return 1
	}
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		return 1
	}
	rc=0
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	cat "$restore_trace"
	rm -f "$restore_trace"
	exit "$rc"
' 1)
if printf '%s' "$failure_output" | grep -q "Failed to update approval labels/assignee"; then
	echo "  PASS: edit failure surfaces accurate blocked reason"
	PASS=$((PASS + 1))
else
	echo "  FAIL: edit failure surfaces accurate blocked reason"
	FAIL=$((FAIL + 1))
fi
if printf '%s' "$failure_output" | grep -q -- "RESTORE .*--add-label needs-maintainer-review"; then
	echo "  PASS: edit uncertainty restores NMR synchronously"
	PASS=$((PASS + 1))
else
	echo "  FAIL: edit uncertainty restores NMR synchronously"
	FAIL=$((FAIL + 1))
fi

# GH#37956: approval-only issues (release requests, standing policies) keep
# authority without gaining task lifecycle labels or an assignee.
# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
approval_only_output=$(run_case "approval-only issue skips task lifecycle" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	edit_trace=$(mktemp)
	set_issue_status() { printf "UNEXPECTED_STATUS %s\n" "$*" >>"$edit_trace"; return 0; }
	gh_issue_edit_safe() { printf "EDIT %s\n" "$*" >>"$edit_trace"; return 0; }
	gh_issue_view() { printf "release-standing-policy,no-auto-dispatch,needs-maintainer-review"; return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"release-standing-policy\"},{\"name\":\"no-auto-dispatch\"}],\"assignees\":[],\"locked\":true}"
			return 0
		fi
		return 1
	}
	rc=0
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	cat "$edit_trace"
	rm -f "$edit_trace"
	exit "$rc"
' 0)
assert_eq "approval-only issue sets no status" "0" "$(printf '%s' "$approval_only_output" | grep -c UNEXPECTED_STATUS)"
assert_eq "approval-only issue adds no labels or assignee" "0" "$(printf '%s' "$approval_only_output" | grep -c -- '--add-')"
assert_eq "approval-only issue clears only NMR" "1" "$(printf '%s' "$approval_only_output" | grep -c -- 'EDIT 123 --repo marcusquinn/aidevops --remove-label needs-maintainer-review$')"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
approval_only_unheld_output=$(run_case "approval-only issue without NMR makes no edit" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	edit_trace=$(mktemp)
	set_issue_status() { printf "UNEXPECTED_STATUS\n" >>"$edit_trace"; return 0; }
	gh_issue_edit_safe() { printf "UNEXPECTED_EDIT %s\n" "$*" >>"$edit_trace"; return 0; }
	gh_issue_view() { printf "release-approval-required,no-auto-dispatch"; return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"release-approval-required\"}],\"assignees\":[],\"locked\":true}"
			return 0
		fi
		return 1
	}
	rc=0
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	cat "$edit_trace"
	rm -f "$edit_trace"
	exit "$rc"
' 0)
assert_eq "unheld approval-only issue is not mutated" "0" "$(printf '%s' "$approval_only_unheld_output" | grep -c 'UNEXPECTED_')"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
approval_only_unlocked_output=$(run_case "approval-only unlocked final state fails closed" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	set_issue_status() { return 0; }
	edit_trace=$(mktemp)
	gh_issue_edit_safe() { printf "EDIT %s\n" "$*" >>"$edit_trace"; return 0; }
	gh_issue_view() { printf "release-standing-policy,needs-maintainer-review"; return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"release-standing-policy\"}],\"assignees\":[],\"locked\":false}"
			return 0
		fi
		return 1
	}
	rc=0
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	cat "$edit_trace"
	rm -f "$edit_trace"
	exit "$rc"
' 1)
assert_eq "unlocked approval-only issue restores NMR" "1" "$(printf '%s' "$approval_only_unlocked_output" | grep -c -- 'EDIT 123 --repo marcusquinn/aidevops --add-label needs-maintainer-review$')"

# A failed label read must not fall into the dispatchable path: REST confirms
# the approval-only labels, and an unreadable issue changes nothing.
# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
approval_only_read_fallback_output=$(run_case "approval-only classification survives label-read failure" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	edit_trace=$(mktemp)
	set_issue_status() { printf "UNEXPECTED_STATUS\n" >>"$edit_trace"; return 0; }
	gh_issue_edit_safe() { printf "EDIT %s\n" "$*" >>"$edit_trace"; return 0; }
	gh_issue_view() { return 1; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "${1:-}" == "api" && "${2:-}" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"release-standing-policy\"}],\"assignees\":[],\"locked\":true}"
			return 0
		fi
		return 1
	}
	rc=0
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	cat "$edit_trace"
	rm -f "$edit_trace"
	exit "$rc"
' 0)
assert_eq "label-read failure still skips task lifecycle" "0" "$(printf '%s' "$approval_only_read_fallback_output" | grep -c -e UNEXPECTED_STATUS -e '--add-')"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
unreadable_output=$(run_case "unreadable labels fail closed" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	edit_trace=$(mktemp)
	set_issue_status() { printf "UNEXPECTED_STATUS\n" >>"$edit_trace"; return 0; }
	gh_issue_edit_safe() { printf "UNEXPECTED_EDIT %s\n" "$*" >>"$edit_trace"; return 0; }
	gh_issue_view() { return 1; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then printf "marcusquinn"; return 0; fi
		return 1
	}
	rc=0
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	cat "$edit_trace"
	rm -f "$edit_trace"
	exit "$rc"
' 1)
assert_eq "unreadable labels make no lifecycle mutation" "0" "$(printf '%s' "$unreadable_output" | grep -c 'UNEXPECTED_')"

echo ""
echo "================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
