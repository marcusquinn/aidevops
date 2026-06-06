#!/usr/bin/env bash
# shellcheck disable=SC2218  # Functions defined via dynamic source
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-precreation-failure-skip.sh — t2981 / GH#21353 regression guard.
#
# Asserts that worktree pre-creation failures are observable:
#   1. _dlw_precreate_worktree returns 1 when path extraction fails
#   2. _dlw_precreate_worktree marks fresh worktree creation as non-reused
#   3. _dlw_precreate_worktree marks existing issue worktree reuse
#   4. _dlw_check_worker_branch_orphan_loop skips fresh branches
#   5. _dlw_check_worker_branch_orphan_loop still checks reused branches
#   6. _dispatch_launch_worker skips dispatch (no setsid) when pre-creation fails
#   7. worktree_precreation_failed_count counter is incremented on failure
#   8. --dir argument no longer contains repo_path fallback
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
# Stub: worktree-helper.sh that emits configurable output
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
		# Emit output with a parseable path. Tests intentionally use both
		# /Git/ and non-/Git/ paths to guard path-root assumptions.
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
	# For worktree list, return configured worktrees or nothing.
	if [[ "${1:-}" == "-C" && "${3:-}" == "worktree" && "${4:-}" == "list" ]]; then
		if [[ "${5:-}" == "--porcelain" && -n "${STUB_PORCELAIN_WORKTREE_PATH:-}" && -n "${STUB_PORCELAIN_WORKTREE_BRANCH:-}" ]]; then
			printf 'worktree %s\n' "$STUB_PORCELAIN_WORKTREE_PATH"
			printf 'HEAD abcdef0123456789\n'
			printf 'branch refs/heads/%s\n' "$STUB_PORCELAIN_WORKTREE_BRANCH"
			return 0
		fi
		if [[ -n "${STUB_EXISTING_WORKTREE_LINE:-}" ]]; then
			printf '%s\n' "$STUB_EXISTING_WORKTREE_LINE"
		fi
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
REGISTERED_WORKTREE_ARGS=""

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

# Re-stub register_worktree after sourcing; shared helper libraries may define
# the real registry function, but this test only needs to assert transferable
# ownership metadata passed by _dlw_precreate_worktree.
register_worktree() {
	local wt_path="$1"
	local branch="$2"
	shift 2
	local task="" session=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task="${2:-}"
			shift 2
			;;
		--session)
			session="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	REGISTERED_WORKTREE_ARGS="${wt_path}|${branch}|${task}|${session}"
	return 0
}

# Re-stub launch-orchestrator dependencies after sourcing; the module defines
# real implementations when loaded, but this test isolates precreation failure.
_ds_now_ns() { printf '0\n'; return 0; }
_ds_record() { return 0; }
_dlw_resolve_tier_and_model() {
	_DLW_DISPATCH_TIER="standard"
	_DLW_DISPATCH_MODEL_TIER="sonnet"
	_DLW_SELECTED_MODEL=""
	return 0
}
_dlw_canary_preflight() { return 0; }
STUB_REFRESH_STATE="OPEN"

gh() {
	if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
		printf '%s\n' "$STUB_REFRESH_STATE"
		return 0
	fi

	return 0
}
CLAIM_LOCK_CALLS_FILE="${TMP}/claim-lock-calls.txt"
_dedup_layer7_claim_lock() {
	printf '%s\n' "${1:-}" >>"$CLAIM_LOCK_CALLS_FILE"
	return "${STUB_CLAIM_LOCK_RC:-1}"
}

printf '\n%s\n' "=== t2981: worktree pre-creation failure observability ==="

# Stub dispatch-dedup-helper.sh used by _dlw_check_worker_branch_orphan_loop.
STUB_DEDUP_HELPER="${TMP}/dispatch-dedup-helper.sh"
cat >"$STUB_DEDUP_HELPER" <<'STUB_DEDUP_EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >>"${STUB_DEDUP_CALLS_FILE:?}"
printf 'orphan-loop-detected\n'
exit 0
STUB_DEDUP_EOF
chmod +x "$STUB_DEDUP_HELPER"
export STUB_DEDUP_CALLS_FILE="${TMP}/dedup-helper-calls.txt"

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
STUB_WT_SUCCESS_PATH="${TMP}/projects/fake-repo-feature"
export STUB_WT_SUCCESS_PATH
mkdir -p "$STUB_WT_SUCCESS_PATH"
: >"$LOGFILE"
REGISTERED_WORKTREE_ARGS=""
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

if [[ "${_DLW_WORKTREE_REUSED:-unset}" == "0" ]]; then
	pass "freshly-created worktree is marked non-reused"
else
	fail "freshly-created worktree is marked non-reused" "got: '${_DLW_WORKTREE_REUSED:-unset}', expected: '0'"
fi

if [[ "$REGISTERED_WORKTREE_ARGS" == "${STUB_WT_SUCCESS_PATH}|${_DLW_WORKTREE_BRANCH}|88888|dispatch-precreate-88888" ]]; then
	pass "fresh precreated worktree is registered as transferable"
else
	fail "fresh precreated worktree is registered as transferable" "got: '$REGISTERED_WORKTREE_ARGS'"
fi

# =============================================================================
# Test 2b: _dlw_precreate_worktree prefers git porcelain path resolution
# =============================================================================
export STUB_WT_MODE="success"
STUB_WT_SUCCESS_PATH="${TMP}/helper-output-should-not-win"
STUB_PORCELAIN_WORKTREE_PATH="${TMP}/projects/fake-repo-porcelain"
STUB_PORCELAIN_WORKTREE_BRANCH="feature/auto-$(date +%Y%m%d-%H%M%S)-gh77777"
export STUB_WT_SUCCESS_PATH STUB_PORCELAIN_WORKTREE_PATH STUB_PORCELAIN_WORKTREE_BRANCH
mkdir -p "$STUB_WT_SUCCESS_PATH" "$STUB_PORCELAIN_WORKTREE_PATH"
: >"$LOGFILE"
_dlw_precreate_worktree "77777" "$FAKE_REPO"
rc=$?
unset STUB_PORCELAIN_WORKTREE_PATH STUB_PORCELAIN_WORKTREE_BRANCH

if [[ $rc -eq 0 && "$_DLW_WORKTREE_PATH" == "${TMP}/projects/fake-repo-porcelain" ]]; then
	pass "precreate resolves non-/Git/ path from git porcelain"
else
	fail "precreate resolves non-/Git/ path from git porcelain" "rc=$rc path='$_DLW_WORKTREE_PATH'"
fi

# =============================================================================
# Test 3: _dlw_precreate_worktree marks existing issue worktree reuse
# =============================================================================
export STUB_WT_MODE="fail"
STUB_EXISTING_PATH="${TMP}/Git/fake-repo-existing"
STUB_EXISTING_BRANCH="feature/auto-20260502-000000-gh66666"
mkdir -p "$STUB_EXISTING_PATH"
export STUB_EXISTING_WORKTREE_LINE="${STUB_EXISTING_PATH} abcdef [${STUB_EXISTING_BRANCH}]"
: >"$LOGFILE"
REGISTERED_WORKTREE_ARGS=""
_dlw_precreate_worktree "66666" "$FAKE_REPO"
rc=$?
unset STUB_EXISTING_WORKTREE_LINE

if [[ $rc -eq 0 && "$_DLW_WORKTREE_PATH" == "$STUB_EXISTING_PATH" && "$_DLW_WORKTREE_BRANCH" == "$STUB_EXISTING_BRANCH" ]]; then
	pass "existing issue worktree is reused"
else
	fail "existing issue worktree is reused" "rc=$rc path='$_DLW_WORKTREE_PATH' branch='$_DLW_WORKTREE_BRANCH'"
fi

if [[ "${_DLW_WORKTREE_REUSED:-unset}" == "1" ]]; then
	pass "reused worktree is marked reused"
else
	fail "reused worktree is marked reused" "got: '${_DLW_WORKTREE_REUSED:-unset}', expected: '1'"
fi

if [[ "$REGISTERED_WORKTREE_ARGS" == "${STUB_EXISTING_PATH}|${STUB_EXISTING_BRANCH}|66666|dispatch-precreate-66666" ]]; then
	pass "reused precreated worktree is registered as transferable"
else
	fail "reused precreated worktree is registered as transferable" "got: '$REGISTERED_WORKTREE_ARGS'"
fi

# =============================================================================
# Test 4: _dlw_check_worker_branch_orphan_loop skips fresh branches
# =============================================================================
: >"$STUB_DEDUP_CALLS_FILE"
if _dlw_check_worker_branch_orphan_loop "55555" "owner/repo" "feature/auto-gh55555" "0"; then
	fail "fresh branch orphan-loop check is skipped" "check returned hold for a non-reused branch"
else
	if [[ ! -s "$STUB_DEDUP_CALLS_FILE" ]]; then
		pass "fresh branch orphan-loop check is skipped"
	else
		fail "fresh branch orphan-loop check is skipped" "dedup helper was called"
	fi
fi

# =============================================================================
# Test 5: _dlw_check_worker_branch_orphan_loop still checks reused branches
# =============================================================================
: >"$STUB_DEDUP_CALLS_FILE"
if _dlw_check_worker_branch_orphan_loop "44444" "owner/repo" "feature/auto-gh44444" "1"; then
	if grep -q '^check-orphan-loop$' "$STUB_DEDUP_CALLS_FILE" 2>/dev/null; then
		pass "reused branch orphan-loop check calls dedup helper"
	else
		fail "reused branch orphan-loop check calls dedup helper" "helper call log missing check-orphan-loop"
	fi
else
	fail "reused branch orphan-loop check calls dedup helper" "check did not return hold from stub helper"
fi

# =============================================================================
# Test 6: _dispatch_launch_worker skips dispatch before claim when canary fails
# =============================================================================

_dlw_canary_preflight() { return 1; }

: >"$LOGFILE"
: >"${TMP}/setsid-calls.txt"
: >"$CLAIM_LOCK_CALLS_FILE"

launch_rc=0
_dispatch_launch_worker "77777" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-1" "" "{}" || launch_rc=$?

if [[ "$launch_rc" -eq 2 ]]; then
	pass "canary failure returns explicit no-op rc=2"
else
	fail "canary failure returns explicit no-op rc=2" "got rc=$launch_rc"
fi

if [[ ! -s "$CLAIM_LOCK_CALLS_FILE" ]]; then
	pass "canary failure does not post dispatch claim"
else
	fail "canary failure does not post dispatch claim" "claim lock calls: $(cat "$CLAIM_LOCK_CALLS_FILE")"
fi

if [[ ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "canary failure does not spawn worker"
else
	fail "canary failure does not spawn worker" "setsid was called"
fi

# =============================================================================
# Test 7: _dispatch_launch_worker refreshes state before claim
# =============================================================================
_dlw_canary_preflight() { return 0; }
STUB_REFRESH_STATE="CLOSED"

: >"$LOGFILE"
: >"${TMP}/setsid-calls.txt"
: >"$CLAIM_LOCK_CALLS_FILE"

launch_rc=0
_dispatch_launch_worker "77778" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-closed" "" \
	'{"state":"OPEN","body":""}' || launch_rc=$?

if [[ "$launch_rc" -eq 2 ]]; then
	pass "closed pre-claim refresh returns explicit no-op rc=2"
else
	fail "closed pre-claim refresh returns explicit no-op rc=2" "got rc=$launch_rc"
fi

if [[ ! -s "$CLAIM_LOCK_CALLS_FILE" ]]; then
	pass "closed pre-claim refresh does not post dispatch claim"
else
	fail "closed pre-claim refresh does not post dispatch claim" "claim lock calls: $(cat "$CLAIM_LOCK_CALLS_FILE")"
fi

if [[ ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "closed pre-claim refresh does not spawn worker"
else
	fail "closed pre-claim refresh does not spawn worker" "setsid was called"
fi

if grep -q "refreshed issue state before claim is CLOSED" "$LOGFILE" 2>/dev/null; then
	pass "closed pre-claim refresh logs blocked state"
else
	fail "closed pre-claim refresh logs blocked state" "LOGFILE: $(cat "$LOGFILE")"
fi

STUB_REFRESH_STATE="OPEN"

# =============================================================================
# Test 8: _dispatch_launch_worker skips dispatch when pre-creation fails
# =============================================================================
_dlw_canary_preflight() { return 0; }

# Override _dlw_precreate_worktree to simulate failure
_dlw_precreate_worktree() {
	_DLW_WORKTREE_PATH=""
	_DLW_WORKTREE_BRANCH=""
	_DLW_WORKTREE_REUSED=0
	return 1
}

: >"$LOGFILE"
: >"${TMP}/setsid-calls.txt"
: >"$CLAIM_LOCK_CALLS_FILE"
# Reset stats file
printf '{"counters":{}}\n' >"$PULSE_STATS_FILE"

launch_rc=0
_dispatch_launch_worker "77777" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-1" "" "{}" || launch_rc=$?

if [[ ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "dispatch skipped (no setsid) when pre-creation fails"
else
	fail "dispatch skipped (no setsid) when pre-creation fails" "setsid was called"
fi

if [[ "$launch_rc" -eq 2 ]]; then
	pass "dispatch skip returns explicit no-op rc=2"
else
	fail "dispatch skip returns explicit no-op rc=2" "got rc=$launch_rc"
fi

if grep -q '^77777$' "$CLAIM_LOCK_CALLS_FILE" 2>/dev/null; then
	pass "pre-creation failure happens after claim lock"
else
	fail "pre-creation failure happens after claim lock" "claim lock not called"
fi

# =============================================================================
# Test 9: worktree_precreation_failed_count counter is incremented
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
# Test 10: --dir argument no longer contains repo_path fallback
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
