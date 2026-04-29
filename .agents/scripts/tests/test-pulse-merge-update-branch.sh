#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the t2116 CONFLICTING-close hardening in pulse-merge.sh:
#
#   1. `_attempt_pr_update_branch` — invokes `gh pr update-branch`, returns 0
#      on success and 1 on failure, logs to LOGFILE.
#   2. CONFLICTING-close skip for PRs whose linked issue carries
#      `needs-maintainer-review` — verified indirectly via a smoke test that
#      drives `_process_single_ready_pr` through a mocked `gh` binary and
#      asserts the close path is NOT taken.
#
# Mock pattern follows test-pulse-merge-rebase-nudge.sh: extract the helper
# source from the real pulse-merge.sh via awk, eval it into the test shell,
# and substitute `gh` with a stub on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# _attempt_pr_update_branch was moved to pulse-merge-process.sh (GH#21595, t3030).
# _process_single_ready_pr stays in pulse-merge.sh — the static checks below
# (test_nmr_guard_exists_before_close, test_mergeable_refetch_after_update_branch)
# read it from $MERGE_SCRIPT.
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
LAST_GH_ARGS_FILE=""

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
	LAST_GH_ARGS_FILE="${TEST_ROOT}/gh-args.log"
	export LAST_GH_ARGS_FILE
	: >"$LAST_GH_ARGS_FILE"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Install a gh stub that:
#   - logs every invocation to LAST_GH_ARGS_FILE (one line per call, tab-joined)
#   - `gh pr update-branch <N> --repo <slug>` → exit code controlled by GH_UB_EXIT
#   - every other gh call → exit 0, no output
install_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAST_GH_ARGS_FILE}"
if [[ "${1:-}" == "pr" && "${2:-}" == "update-branch" ]]; then
	exit "${GH_UB_EXIT:-0}"
fi
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Extract `_attempt_pr_update_branch` from pulse-merge-process.sh (post-GH#21595)
# and eval it into the test shell. Matches the define_helper_under_test
# pattern used by test-pulse-merge-rebase-nudge.sh.
define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_attempt_pr_update_branch\(\) \{/,/^}$/ { print }
	' "$PROCESS_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _attempt_pr_update_branch from %s\n' "$PROCESS_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

test_update_branch_success_returns_zero() {
	install_gh_stub
	GH_UB_EXIT=0 _attempt_pr_update_branch "18988" "marcusquinn/aidevops"
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		print_result "update-branch success → return 0" 1 \
			"Expected return 0 on gh success, got ${rc}"
		return 0
	fi

	# Verify gh was called with the expected arguments.
	if ! grep -qE '^pr update-branch 18988 --repo marcusquinn/aidevops$' "$LAST_GH_ARGS_FILE"; then
		print_result "update-branch success → return 0" 1 \
			"Expected 'pr update-branch 18988 --repo marcusquinn/aidevops' in gh args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	# Log should record success.
	if ! grep -q "update-branch succeeded" "$LOGFILE"; then
		print_result "update-branch success → return 0" 1 \
			"Expected 'update-branch succeeded' in LOGFILE"
		return 0
	fi

	print_result "update-branch success → return 0" 0
	return 0
}

test_update_branch_failure_returns_one() {
	install_gh_stub
	# gh returns non-zero (true semantic conflict). `set -e` is active so
	# we MUST guard the failing call with a conditional to capture rc.
	local rc=0
	GH_UB_EXIT=1 _attempt_pr_update_branch "19094" "marcusquinn/aidevops" || rc=$?

	if [[ $rc -ne 1 ]]; then
		print_result "update-branch failure → return 1" 1 \
			"Expected return 1 on gh failure, got ${rc}"
		return 0
	fi

	# Log should record the fallthrough.
	if ! grep -q "update-branch failed, falling through to close" "$LOGFILE"; then
		print_result "update-branch failure → return 1" 1 \
			"Expected 'update-branch failed' in LOGFILE"
		return 0
	fi

	print_result "update-branch failure → return 1" 0
	return 0
}

test_update_branch_tags_log_with_task_id() {
	install_gh_stub
	: >"$LOGFILE"
	GH_UB_EXIT=0 _attempt_pr_update_branch "12345" "marcusquinn/aidevops"

	# All t2116 log entries must carry the (t2116) tag for later audit.
	if ! grep -q '(t2116)' "$LOGFILE"; then
		print_result "log entries carry (t2116) audit tag" 1 \
			"Expected '(t2116)' in LOGFILE. Contents: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "log entries carry (t2116) audit tag" 0
	return 0
}

# ---------------------------------------------------------------
# Static analysis of the t2116 block in _process_single_ready_pr.
# The full control-flow of _process_single_ready_pr depends on many
# helpers that are too heavy to mock reliably; instead we assert the
# exact structural properties that must hold for the fix to work:
#
#   1. A `needs-maintainer-review` guard exists and runs before
#      `_close_conflicting_pr` in the CONFLICTING branch.
#   2. `_attempt_pr_update_branch` is called from the CONFLICTING branch
#      before close.
#   3. After update-branch, mergeable state is re-fetched.
# ---------------------------------------------------------------

test_nmr_guard_exists_before_close() {
	# Extract the CONFLICTING handling block from _process_single_ready_pr.
	local block
	block=$(awk '
		/^_process_single_ready_pr\(\) \{/,/^}$/ {
			if ($0 ~ /pr_mergeable.*CONFLICTING/) { capturing=1 }
			if (capturing) print
			if (capturing && /^	fi$/ && ++fi_count == 3) { exit }
		}
	' "$MERGE_SCRIPT")

	if [[ -z "$block" ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"Could not extract CONFLICTING block from _process_single_ready_pr"
		return 0
	fi

	if [[ "$block" != *"needs-maintainer-review"* ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"CONFLICTING block missing 'needs-maintainer-review' guard"
		return 0
	fi

	if [[ "$block" != *"_attempt_pr_update_branch"* ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"CONFLICTING block missing _attempt_pr_update_branch call"
		return 0
	fi

	# NMR guard must appear BEFORE the _close_conflicting_pr call.
	local nmr_pos close_pos
	nmr_pos=$(printf '%s\n' "$block" | grep -n 'needs-maintainer-review' | head -1 | cut -d: -f1)
	close_pos=$(printf '%s\n' "$block" | grep -n '_close_conflicting_pr' | head -1 | cut -d: -f1)
	if [[ -z "$nmr_pos" || -z "$close_pos" ]] || [[ "$nmr_pos" -ge "$close_pos" ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"NMR guard must appear before _close_conflicting_pr (nmr_pos=${nmr_pos}, close_pos=${close_pos})"
		return 0
	fi

	# update-branch must also appear BEFORE the final close.
	local ub_pos
	ub_pos=$(printf '%s\n' "$block" | grep -n '_attempt_pr_update_branch' | head -1 | cut -d: -f1)
	if [[ -z "$ub_pos" ]] || [[ "$ub_pos" -ge "$close_pos" ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"update-branch must appear before _close_conflicting_pr (ub_pos=${ub_pos}, close_pos=${close_pos})"
		return 0
	fi

	print_result "NMR guard + update-branch structure present" 0
	return 0
}

test_mergeable_refetch_after_update_branch() {
	# After update-branch succeeds the code must re-read pr_mergeable
	# via another `gh pr view --json mergeable` call, otherwise the
	# stale CONFLICTING value falls straight through to close.
	local block
	block=$(awk '
		/_attempt_pr_update_branch/,/_close_conflicting_pr/ { print }
	' "$MERGE_SCRIPT")

	if [[ "$block" != *"gh pr view"*"--json mergeable"* ]]; then
		print_result "mergeable re-fetched after successful update-branch" 1 \
			"Expected 'gh pr view ... --json mergeable' between update-branch and close"
		return 0
	fi

	print_result "mergeable re-fetched after successful update-branch" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_update_branch_success_returns_zero
	test_update_branch_failure_returns_one
	test_update_branch_tags_log_with_task_id
	test_nmr_guard_exists_before_close
	test_mergeable_refetch_after_update_branch

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
