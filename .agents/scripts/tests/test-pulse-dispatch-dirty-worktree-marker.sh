#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for dirty-worktree recovery dispatch holds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
LIB_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

gh() {
	local subcommand="$1"
	local endpoint="${2:-}"
	if [[ "$subcommand" != "api" || "$endpoint" != "repos/marcusquinn/aidevops/issues/26635/comments?per_page=100" ]]; then
		printf 'unexpected gh call: %s\n' "$*" >&2
		return 1
	fi
	printf '%s\n' "${TEST_GH_COMMENTS_JSON:-[]}"
	return 0
}

load_lib() {
	LOGFILE="${TMPDIR:-/tmp}/test-pulse-dispatch-dirty-worktree-marker.log"
	: >"$LOGFILE"
	# shellcheck disable=SC1090 # test sources the library under test by path.
	source "$LIB_SCRIPT"
	return 0
}

test_recent_marker_blocks_dispatch() {
	local comments_json='[{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635"}]'
	TEST_GH_COMMENTS_JSON="$comments_json" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783291032" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_recent_dirty_worktree_marker_active "26635" "marcusquinn/aidevops"
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "recent dirty marker blocks dispatch" 0
		return 0
	fi
	print_result "recent dirty marker blocks dispatch" 1 "expected active marker to block"
	return 0
}

test_later_resolution_clears_marker() {
	local comments_json='[{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635"},{"created_at":"2026-07-05T22:40:00Z","body":"<!-- worker-dirty-worktree:resolved --> recovered into PR #26666"}]'
	set +e
	TEST_GH_COMMENTS_JSON="$comments_json" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783291032" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_recent_dirty_worktree_marker_active "26635" "marcusquinn/aidevops"
	local rc=$?
	set -e
	if [[ "$rc" -eq 1 ]]; then
		print_result "later resolution clears dirty marker" 0
		return 0
	fi
	print_result "later resolution clears dirty marker" 1 "expected resolved marker to fail open"
	return 0
}

test_expired_marker_does_not_block() {
	local comments_json='[{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635"}]'
	set +e
	TEST_GH_COMMENTS_JSON="$comments_json" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783377432" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_recent_dirty_worktree_marker_active "26635" "marcusquinn/aidevops"
	local rc=$?
	set -e
	if [[ "$rc" -eq 1 ]]; then
		print_result "expired dirty marker does not block" 0
		return 0
	fi
	print_result "expired dirty marker does not block" 1 "expected expired marker to allow dispatch"
	return 0
}

main() {
	load_lib
	test_recent_marker_blocks_dispatch
	test_later_resolution_clears_marker
	test_expired_marker_does_not_block

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
