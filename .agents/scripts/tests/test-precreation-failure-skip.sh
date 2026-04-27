#!/usr/bin/env bash
# shellcheck disable=SC2218  # Functions defined via dynamic source
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-precreation-failure-skip.sh — t2981 / GH#21353 regression guard.
#
# Asserts that worktree pre-creation failures are observable:
#   1. _dlw_precreate_worktree returns 1 when path extraction fails
#   2. _dlw_precreate_worktree returns 0 when worktree creation succeeds
#   3. _dispatch_launch_worker skips dispatch (no setsid) when pre-creation fails
#   4. worktree_precreation_failed_count counter is incremented on failure
#   5. --dir argument no longer contains repo_path fallback
#
# Stub strategy: stub worktree-helper.sh, git, and dependent functions
# to isolate _dlw_precreate_worktree and _dispatch_launch_worker.

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
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2981.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export LOGFILE="${TMP}/test-pulse.log"
export SCRIPT_DIR="$TMP"
export PULSE_STATS_FILE="${TMP}/pulse-stats.json"

# Seed pulse-stats.json with minimal valid structure
printf '{"counters":{}}\n' >"$PULSE_STATS_FILE"

# Create a fake repo_path directory
FAKE_REPO="${TMP}/fake-repo"
mkdir -p "$FAKE_REPO"

# =============================================================================
# Stub: worktree-helper.sh that emits unparseable output
# =============================================================================
STUB_WT_HELPER="${TMP}/worktree-helper.sh"
cat >"$STUB_WT_HELPER" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub worktree-helper.sh — output depends on STUB_WT_MODE
case "${STUB_WT_MODE:-fail}" in
	fail)
		echo "Error: something went wrong, no path here"
		exit 1
		;;
	success)
		# Emit output with a parseable Git path
		echo "Created worktree at ${STUB_WT_SUCCESS_PATH}"
		exit 0
		;;
esac
STUB_EOF
chmod +x "$STUB_WT_HELPER"

# =============================================================================
# Stub: git (for worktree list — returns empty by default)
# =============================================================================
git() {
	# For worktree list, return nothing (no existing worktrees)
	if [[ "${1:-}" == "-C" && "${3:-}" == "worktree" && "${4:-}" == "list" ]]; then
		return 0
	fi
	# For symbolic-ref, return main
	if [[ "${1:-}" == "-C" && "${3:-}" == "symbolic-ref" ]]; then
		echo "refs/remotes/origin/main"
		return 0
	fi
	# Fallback: call real git
	command git "$@"
	return $?
}
export -f git

# =============================================================================
# Stub dependent functions that _dlw_precreate_worktree calls
# =============================================================================
_dlw_restore_worktree_deps() { return 0; }

# =============================================================================
# Source pulse-stats-helper.sh for pulse_stats_increment
# =============================================================================
# shellcheck source=../pulse-stats-helper.sh
source "${SCRIPTS_DIR}/pulse-stats-helper.sh"

# Disable errexit — sourced modules may set -e; we check return codes explicitly
set +e

# =============================================================================
# Source the module under test
# =============================================================================
# Unset the load guard so we can source it.
unset _PULSE_DISPATCH_WORKER_LAUNCH_LOADED

# Stub functions that the module depends on but we don't test here
lock_issue_for_worker() { return 0; }
_dlw_assign_and_label() { return 0; }
_dlw_setup_worker_log() { echo "${TMP}/worker.log"; return 0; }
_dlw_resolve_tier_and_model() {
	_DLW_DISPATCH_TIER="standard"
	_DLW_DISPATCH_MODEL_TIER="sonnet"
	_DLW_SELECTED_MODEL=""
	return 0
}
_dlw_prewarm_opencode_db() { _DLW_PREWARM_DIR=""; return 0; }
_dlw_exec_detached() {
	# Record that setsid would have been called
	echo "SETSID_CALLED" >>"${TMP}/setsid-calls.txt"
	echo "12345"  # fake PID
	return 0
}
_dlw_post_launch_hooks() { return 0; }
HEADLESS_RUNTIME_HELPER="${TMP}/fake-headless-runtime"

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"

# Restore SCRIPT_DIR to point to our stub directory (sourced modules may
# overwrite it). _dlw_precreate_worktree uses SCRIPT_DIR to find
# worktree-helper.sh.
SCRIPT_DIR="$TMP"

printf '\n%s\n' "=== t2981: worktree pre-creation failure observability ==="

# =============================================================================
# Test 1: _dlw_precreate_worktree returns 1 when path extraction fails
# =============================================================================
export STUB_WT_MODE="fail"
: >"$LOGFILE"
_dlw_precreate_worktree "99999" "$FAKE_REPO"
rc=$?
if [[ $rc -eq 1 ]]; then
	pass "precreate returns 1 on path-extraction failure"
else
	fail "precreate returns 1 on path-extraction failure" "got rc=$rc, expected 1"
fi

# Verify the warning message was logged
if grep -q "pre-creation failed for #99999" "$LOGFILE" 2>/dev/null; then
	pass "failure log message includes issue number"
else
	fail "failure log message includes issue number" "LOGFILE: $(cat "$LOGFILE")"
fi

# Verify _DLW_WORKTREE_PATH is empty on failure
if [[ -z "$_DLW_WORKTREE_PATH" ]]; then
	pass "worktree path is empty on failure"
else
	fail "worktree path is empty on failure" "got: $_DLW_WORKTREE_PATH"
fi

# =============================================================================
# Test 2: _dlw_precreate_worktree returns 0 when creation succeeds
# =============================================================================
export STUB_WT_MODE="success"
STUB_WT_SUCCESS_PATH="${TMP}/Git/fake-repo-feature"
export STUB_WT_SUCCESS_PATH
mkdir -p "$STUB_WT_SUCCESS_PATH"
: >"$LOGFILE"
_dlw_precreate_worktree "88888" "$FAKE_REPO"
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "precreate returns 0 on success"
else
	fail "precreate returns 0 on success" "got rc=$rc, expected 0"
fi

if [[ "$_DLW_WORKTREE_PATH" == "$STUB_WT_SUCCESS_PATH" ]]; then
	pass "worktree path is set on success"
else
	fail "worktree path is set on success" "got: '$_DLW_WORKTREE_PATH', expected: '$STUB_WT_SUCCESS_PATH'"
fi

# =============================================================================
# Test 3: _dispatch_launch_worker skips dispatch when pre-creation fails
# =============================================================================
# Override _dlw_precreate_worktree to simulate failure
_dlw_precreate_worktree() {
	_DLW_WORKTREE_PATH=""
	_DLW_WORKTREE_BRANCH=""
	return 1
}

: >"$LOGFILE"
: >"${TMP}/setsid-calls.txt"
# Reset stats file
printf '{"counters":{}}\n' >"$PULSE_STATS_FILE"

_dispatch_launch_worker "77777" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-1" "" "{}"

if [[ ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "dispatch skipped (no setsid) when pre-creation fails"
else
	fail "dispatch skipped (no setsid) when pre-creation fails" "setsid was called"
fi

# =============================================================================
# Test 4: worktree_precreation_failed_count counter is incremented
# =============================================================================
local_count=""
if command -v jq &>/dev/null; then
	local_count=$(jq -r '.counters.worktree_precreation_failed_count | length' "$PULSE_STATS_FILE" 2>/dev/null) || local_count="0"
fi
if [[ "$local_count" == "1" ]]; then
	pass "worktree_precreation_failed_count incremented to 1"
else
	fail "worktree_precreation_failed_count incremented to 1" "got count=$local_count (jq available: $(command -v jq &>/dev/null && echo yes || echo no))"
fi

# Verify skip message in log
if grep -q "Skipping #77777.*pre-creation failed" "$LOGFILE" 2>/dev/null; then
	pass "skip-dispatch log message present"
else
	fail "skip-dispatch log message present" "LOGFILE: $(cat "$LOGFILE")"
fi

# =============================================================================
# Test 5: --dir argument no longer contains repo_path fallback
# =============================================================================
# Grep the source file for the old pattern (single quotes intentional — literal search)
# shellcheck disable=SC2016
if grep -q ':-\$repo_path' "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh" 2>/dev/null; then
	fail "--dir fallback removed" "still found ':-\$repo_path' in source"
else
	pass "--dir fallback removed"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%s\n' "--- Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ---"
if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi
exit 0
