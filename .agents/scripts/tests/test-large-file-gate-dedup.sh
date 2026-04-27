#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-large-file-gate-dedup.sh — t2995 regression guard.
#
# Asserts that `_large_file_gate_find_existing_debt_issue` and its caller
# `_large_file_gate_create_debt_issue` distinguish three outcomes from the
# `gh_issue_list` lookup:
#
#   rc=0 (match)     → return existing issue reference, no creation.
#   rc=1 (no match)  → file a new debt issue.
#   rc=2 (lookup err)→ defer; do NOT create a fresh debt issue.
#
# Background:
#   Pre-t2995, the helper swallowed gh_issue_list failures via
#   `|| _open=""` and treated lookup-error as no-match. When the gh wall-
#   clock timeout fired (15s, AIDEVOPS_GH_READ_TIMEOUT), every cycle that
#   timed out filed a duplicate. Worktree-helper.sh accumulated 7 open
#   file-size-debt duplicates over 30 days; aidevops.sh accumulated 2;
#   shared-constants.sh accumulated 2.
#
# Tests (in source order):
#   1. helper:match-open      → rc=0, stdout="open:NNN"
#   2. helper:match-closed    → rc=0, stdout="closed:NNN"
#   3. helper:no-match        → rc=1, stdout=""
#   4. helper:lookup-failed   → rc=2, stdout="", logs WARN
#   5. caller:lookup-failed-defers → does NOT call _large_file_gate_file_new_debt_issue
#   6. caller:no-match-files-new   → DOES call _large_file_gate_file_new_debt_issue
#   7. helper:retry-on-empty  → first call returns empty, retry returns match
#                                (catches search index lag, t2995 step 4)
#   8. wrapper:gh_issue_list-with-search-routes-via-search-issues
#                                → REST fallback uses /search/issues, not
#                                  /repos/.../issues, when --search is non-empty
#                                  (catches t2995 silent-correctness bug)
#
# Stub strategy: define `gh_issue_list`, `gh`, and `_large_file_gate_file_new_debt_issue`
# as shell functions BEFORE sourcing the gate script. Per-test env vars control
# stub behaviour deterministically.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
	return 0
}

# =============================================================================
# Sandbox + stubs
# =============================================================================
TMP=$(mktemp -d -t t2995.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse-wrapper.log"
export LOGFILE
: >"$LOGFILE"

NEW_ISSUE_CALLS="${TMP}/new_issue_calls.log"
GH_ISSUE_LIST_CALLS="${TMP}/gh_issue_list_calls.log"
: >"$NEW_ISSUE_CALLS"
: >"$GH_ISSUE_LIST_CALLS"

# Quiet logging deps that the gate script sources transitively.
print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

# Stub the gh_issue_list wrapper. Per-test env vars:
#   STUB_GH_LIST_RC          — exit code (default 0)
#   STUB_GH_LIST_OPEN_OUT    — stdout for open-state queries (--state open)
#   STUB_GH_LIST_CLOSED_OUT  — stdout for closed-state queries (--state closed)
#   STUB_GH_LIST_RETRY_OUT   — stdout on the SECOND open-state call only
#                              (set to simulate retry-after-empty, t2995 step 4)
#
# Counter is kept in a temp file so increments survive subshells (the helpers
# under test invoke gh_issue_list inside `$(...)` command substitutions).
OPEN_CALL_COUNTER="${TMP}/open_call_counter"
echo 0 >"$OPEN_CALL_COUNTER"
export OPEN_CALL_COUNTER
gh_issue_list() {
	printf '%s\n' "$*" >>"$GH_ISSUE_LIST_CALLS"
	local _state=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--state) _state="$2"; shift 2 ;;
		*) shift ;;
		esac
	done
	if [[ "$_state" == "open" ]]; then
		local _n
		_n=$(cat "$OPEN_CALL_COUNTER" 2>/dev/null || echo 0)
		_n=$((_n + 1))
		echo "$_n" >"$OPEN_CALL_COUNTER"
		# On the SECOND open call, return STUB_GH_LIST_RETRY_OUT if set.
		if [[ "$_n" -ge 2 && -n "${STUB_GH_LIST_RETRY_OUT:-}" ]]; then
			printf '%s' "$STUB_GH_LIST_RETRY_OUT"
			return 0
		fi
		printf '%s' "${STUB_GH_LIST_OPEN_OUT:-}"
	elif [[ "$_state" == "closed" ]]; then
		printf '%s' "${STUB_GH_LIST_CLOSED_OUT:-}"
	fi
	return "${STUB_GH_LIST_RC:-0}"
}
export -f gh_issue_list

# Stub _large_file_gate_file_new_debt_issue so we can detect when the
# caller decides to file a fresh issue. Records the call and emits the
# deterministic "#N (new)" return shape the real helper produces.
_large_file_gate_file_new_debt_issue() {
	printf '%s\n' "lf_path=$1 parent=$2 repo=$3 prior=${4:-}" >>"$NEW_ISSUE_CALLS"
	printf '#9999 (new)'
	return 0
}
export -f _large_file_gate_file_new_debt_issue

# Stub _large_file_gate_verify_prior_reduced_size so the closed-match path
# can be exercised without filesystem inspection.
_large_file_gate_verify_prior_reduced_size() {
	# Default: prior PR DID reduce size → continuation path fires.
	# Tests that need the failed-prior path can override via env.
	return "${STUB_VERIFY_REDUCED_RC:-0}"
}
export -f _large_file_gate_verify_prior_reduced_size

# Stub sleep so the retry-on-empty path doesn't pause 2s in tests. The real
# helper uses `sleep 2` between the first empty result and the retry; we
# short-circuit it for deterministic test runtime.
sleep() { return 0; }
export -f sleep

# Bash 3.2 + LARGE_FILE_LINE_THRESHOLD (referenced by the gate script via
# nested helpers). The dedup helper itself does not depend on this — but
# downstream calls in the create helper do, so set it for completeness.
export LARGE_FILE_LINE_THRESHOLD=1000

# Source the gate script. NOTE: the gate script DOES define
# _large_file_gate_file_new_debt_issue and _large_file_gate_verify_prior_reduced_size
# itself, which would shadow our stubs. We re-define them AFTER sourcing.
# `gh_issue_list` is NOT defined in the gate script (it lives in
# shared-gh-wrappers.sh, which we deliberately don't source here), so our
# stub survives.
unset _PULSE_DISPATCH_LARGE_FILE_GATE_LOADED || true
# shellcheck source=../pulse-dispatch-large-file-gate.sh
source "${SCRIPTS_DIR}/pulse-dispatch-large-file-gate.sh" >/dev/null 2>&1 || {
	printf '%sFATAL%s could not source gate script\n' "$TEST_RED" "$TEST_NC"
	exit 1
}

# Re-define the helper stubs that the gate script overwrote with its real
# implementations.
_large_file_gate_file_new_debt_issue() {
	printf '%s\n' "lf_path=$1 parent=$2 repo=$3 prior=${4:-}" >>"$NEW_ISSUE_CALLS"
	printf '#9999 (new)'
	return 0
}
_large_file_gate_verify_prior_reduced_size() {
	return "${STUB_VERIFY_REDUCED_RC:-0}"
}
export -f _large_file_gate_file_new_debt_issue _large_file_gate_verify_prior_reduced_size

# Re-export the print_* stubs in case any sourced lib overrode them.
export -f print_info print_warning print_error print_success log_verbose

# Helper: reset per-test stub state. The counter file (OPEN_CALL_COUNTER)
# is also reset so retry-tracking starts fresh per test.
_reset_stubs() {
	echo 0 >"$OPEN_CALL_COUNTER"
	export STUB_GH_LIST_RC=0
	export STUB_GH_LIST_OPEN_OUT=""
	export STUB_GH_LIST_CLOSED_OUT=""
	export STUB_GH_LIST_RETRY_OUT=""
	export STUB_VERIFY_REDUCED_RC=0
	: >"$NEW_ISSUE_CALLS"
	: >"$GH_ISSUE_LIST_CALLS"
	: >"$LOGFILE"
}

# =============================================================================
# Helper-level tests
# =============================================================================
printf '\n=== test-large-file-gate-dedup.sh (t2995) ===\n\n'
printf '%s\n\n' '--- Helper: _large_file_gate_find_existing_debt_issue ---'

# Test 1: open match → rc=0, stdout="open:1234"
_reset_stubs
export STUB_GH_LIST_OPEN_OUT="1234"
out=""
rc=0
out=$(_large_file_gate_find_existing_debt_issue "owner/repo" "worktree-helper.sh") || rc=$?
if [[ "$rc" == "0" && "$out" == "open:1234" ]]; then
	pass "helper:match-open returns rc=0 stdout=open:1234"
else
	fail "helper:match-open" "rc=$rc out='$out'"
fi

# Test 2: closed match → rc=0, stdout="closed:5678" (open returns empty,
# closed returns 5678)
_reset_stubs
export STUB_GH_LIST_OPEN_OUT=""
export STUB_GH_LIST_CLOSED_OUT="5678"
# Avoid the retry path by ensuring no STUB_GH_LIST_RETRY_OUT is set
# (the retry returns empty too, then closed search runs).
out=""
rc=0
out=$(_large_file_gate_find_existing_debt_issue "owner/repo" "worktree-helper.sh") || rc=$?
if [[ "$rc" == "0" && "$out" == "closed:5678" ]]; then
	pass "helper:match-closed returns rc=0 stdout=closed:5678"
else
	fail "helper:match-closed" "rc=$rc out='$out'"
fi

# Test 3: no match → rc=1, stdout=""
_reset_stubs
export STUB_GH_LIST_OPEN_OUT=""
export STUB_GH_LIST_CLOSED_OUT=""
out=""
rc=0
out=$(_large_file_gate_find_existing_debt_issue "owner/repo" "worktree-helper.sh") || rc=$?
if [[ "$rc" == "1" && -z "$out" ]]; then
	pass "helper:no-match returns rc=1 stdout=empty"
else
	fail "helper:no-match" "rc=$rc out='$out'"
fi

# Test 4: lookup failure → rc=2, stdout="", logs WARN (THE t2995 fix)
_reset_stubs
export STUB_GH_LIST_RC=124
out=""
rc=0
out=$(_large_file_gate_find_existing_debt_issue "owner/repo" "worktree-helper.sh") || rc=$?
if [[ "$rc" == "2" && -z "$out" ]]; then
	pass "helper:lookup-failed returns rc=2 stdout=empty"
else
	fail "helper:lookup-failed" "rc=$rc out='$out'"
fi
if grep -q "file-size-debt dedup open-search failed for worktree-helper.sh" "$LOGFILE"; then
	pass "helper:lookup-failed logs WARN with basename"
else
	fail "helper:lookup-failed logs WARN" "log contents: $(cat "$LOGFILE")"
fi

# Test 7: retry on empty (search index lag, t2995 step 4). The `sleep`
# call inside the helper is no-op'd by the global stub.
_reset_stubs
export STUB_GH_LIST_OPEN_OUT=""
export STUB_GH_LIST_RETRY_OUT="9001"
out=""
rc=0
out=$(_large_file_gate_find_existing_debt_issue "owner/repo" "worktree-helper.sh") || rc=$?
calls=$(cat "$OPEN_CALL_COUNTER" 2>/dev/null || echo "?")
if [[ "$rc" == "0" && "$out" == "open:9001" ]]; then
	pass "helper:retry-on-empty catches search index lag (calls=$calls)"
else
	fail "helper:retry-on-empty" "rc=$rc out='$out' calls=$calls"
fi

# =============================================================================
# Caller-level tests
# =============================================================================
printf '\n%s\n\n' '--- Caller: _large_file_gate_create_debt_issue ---'

# Test 5: lookup failure → caller defers (does NOT call file-new helper)
_reset_stubs
export STUB_GH_LIST_RC=124
out=""
rc=0
out=$(_large_file_gate_create_debt_issue ".agents/scripts/worktree-helper.sh" "21406" "owner/repo" "/tmp/repo") || rc=$?
new_calls=$(wc -l <"$NEW_ISSUE_CALLS" | tr -d ' ')
if [[ "$rc" == "0" && "$new_calls" == "0" ]]; then
	pass "caller:lookup-failed-defers (does NOT file new issue)"
else
	fail "caller:lookup-failed-defers" "rc=$rc new_calls=$new_calls out='$out'"
fi
if grep -q "file-size-debt dedup lookup failed for worktree-helper.sh" "$LOGFILE"; then
	pass "caller:lookup-failed-defers logs deferral with parent ref"
else
	fail "caller:lookup-failed-defers logs" "log contents: $(cat "$LOGFILE")"
fi

# Test 6: no-match → caller files new issue
_reset_stubs
export STUB_GH_LIST_OPEN_OUT=""
export STUB_GH_LIST_CLOSED_OUT=""
out=""
rc=0
out=$(_large_file_gate_create_debt_issue ".agents/scripts/worktree-helper.sh" "21406" "owner/repo" "/tmp/repo") || rc=$?
new_calls=$(wc -l <"$NEW_ISSUE_CALLS" | tr -d ' ')
if [[ "$rc" == "0" && "$new_calls" == "1" && "$out" == "#9999 (new)" ]]; then
	pass "caller:no-match-files-new (files new issue)"
else
	fail "caller:no-match-files-new" "rc=$rc new_calls=$new_calls out='$out'"
fi

# =============================================================================
# Wrapper-level test: gh_issue_list --search routes via /search/issues
# =============================================================================
printf '\n%s\n\n' '--- Wrapper: gh_issue_list REST fallback parity for --search ---'

# Source shared-gh-wrappers (which also sources rest-fallback) in a fresh
# subshell context. We override `gh` to record the api path it gets called
# with, and force the fallback via _GH_SHOULD_FALLBACK_OVERRIDE=1.
(
	# Shadow the gh_issue_list stub (defined in the parent test) so the real
	# wrapper runs in this subshell.
	unset -f gh_issue_list || true
	unset _SHARED_GH_WRAPPERS_LOADED _SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED || true

	GH_API_PATHS="${TMP}/gh_api_paths.log"
	: >"$GH_API_PATHS"

	# shellcheck source=../shared-gh-wrappers.sh
	source "${SCRIPTS_DIR}/shared-gh-wrappers.sh" >/dev/null 2>&1 || true

	# Override _gh_with_timeout AFTER sourcing. The default implementation
	# uses `timeout 15 "$@"` when the timeout binary is on PATH, which fork-
	# execs the gh binary directly and bypasses our shell-function stub. We
	# replace it with a passthrough so our `gh()` stub captures every call.
	_gh_with_timeout() {
		shift # drop op_class
		"$@"
		return $?
	}

	# Stub gh as a shell function — captures both the primary `gh issue list`
	# call and the fallback `gh api ...` calls. The shell function takes
	# precedence over PATH binaries.
	gh() {
		printf '%s\n' "$*" >>"$GH_API_PATHS"
		case "$1" in
		issue)
			# Primary `gh issue list` — force failure to trigger fallback.
			return 1
			;;
		api)
			if [[ "$2" == "rate_limit" ]]; then
				# _GH_SHOULD_FALLBACK_OVERRIDE short-circuits this anyway.
				printf '0\n'
				return 0
			fi
			if [[ "$2" =~ ^/search/issues ]]; then
				# Real endpoint shape: { "items": [{ "number": 4242 }] }.
				# After --jq ".items | .[0].number // empty" the result is "4242".
				printf '4242\n'
				return 0
			fi
			if [[ "$2" =~ ^/repos/ ]]; then
				# Plain issues endpoint — the OLD silent-drop path. If this
				# fires when --search was supplied, the routing fix regressed.
				printf '[]\n'
				return 0
			fi
			;;
		esac
		return 1
	}

	export _GH_SHOULD_FALLBACK_OVERRIDE=1

	out=$(gh_issue_list --repo owner/repo --state open --label file-size-debt \
		--search worktree-helper.sh --json number --jq '.[0].number // empty' --limit 5 2>/dev/null)

	# Verify /search/issues was called AND /repos/owner/repo/issues was NOT.
	if grep -q "api /search/issues" "$GH_API_PATHS"; then
		printf 'PASS_SEARCH\n' >"${TMP}/wrapper_result"
	else
		printf 'FAIL_SEARCH out=%s paths=%s\n' "$out" "$(cat "$GH_API_PATHS")" >"${TMP}/wrapper_result"
	fi
	if ! grep -qE 'api /repos/[^/]+/[^/]+/issues\?' "$GH_API_PATHS"; then
		printf 'PASS_NO_REPOS\n' >>"${TMP}/wrapper_result"
	else
		printf 'FAIL_NO_REPOS paths=%s\n' "$(cat "$GH_API_PATHS")" >>"${TMP}/wrapper_result"
	fi
)
wrapper_result=$(cat "${TMP}/wrapper_result" 2>/dev/null || true)
if grep -q "PASS_SEARCH" <<<"$wrapper_result"; then
	pass "wrapper:gh_issue_list-with-search routes via /search/issues"
else
	fail "wrapper:gh_issue_list-with-search routes via /search/issues" "$wrapper_result"
fi
if grep -q "PASS_NO_REPOS" <<<"$wrapper_result"; then
	pass "wrapper:gh_issue_list-with-search does NOT hit /repos/.../issues"
else
	fail "wrapper:gh_issue_list-with-search does NOT hit /repos/.../issues" "$wrapper_result"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n=== Results: %d/%d passed ===\n\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%sFAILED%s — %d test(s) failed\n' "$TEST_RED" "$TEST_NC" "$TESTS_FAILED"
	exit 1
fi
printf '%sALL PASSED%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
