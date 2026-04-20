#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-scan-stale-auto-release.sh — t2414 regression guard.
#
# Asserts that `_isc_cmd_scan_stale` Phase 1 auto-releases stamps ONLY when
# BOTH conditions hold: dead PID AND missing worktree. Any live signal (live
# PID or existing worktree) must preserve the stamp.
#
# Background (GH#20012, t2414):
#   scan-stale Phase 1 previously ONLY reported dead stamps, requiring N manual
#   `interactive-session-helper.sh release` calls per crashed session. Dead
#   PID + missing worktree is definitionally safe to auto-release — the owning
#   session died without cleanup, there is no ambiguity and no false-positive
#   surface.
#
# Tests:
#   1. dead PID + missing worktree → stamp auto-released (file removed)
#   2. live PID + missing worktree → stamp preserved
#   3. dead PID + existing worktree → stamp preserved
#   4. live PID + existing worktree → stamp preserved
#   5. --no-auto-release flag → dead+missing stamp NOT released (report only)
#   6. AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 env → dead+missing stamp NOT released
#   7. AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 env + non-TTY → dead+missing released
#
# Stub strategy: override `_isc_release_claim_by_stamp_path` as a shell function
# after sourcing the helper to capture auto-release calls without real gh ops.
# We also override `_isc_gh_reachable`, `_isc_has_in_review`, `set_issue_status`,
# `_isc_scan_stampless_phase`, and `_isc_scan_closed_pr_orphans` to keep the
# test hermetic.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
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
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2414.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

STAMP_DIR="${TMP}/interactive-claims"
mkdir -p "$STAMP_DIR"

EXISTING_WORKTREE="${TMP}/existing-worktree"
mkdir -p "$EXISTING_WORKTREE"

RELEASE_LOG="${TMP}/release_calls.log"

# Current hostname for stamps (scan-stale skips cross-machine stamps)
LOCAL_HOST=$(hostname 2>/dev/null || echo "unknown")

# Write a stamp file with given PID and worktree path.
write_stamp() {
	local filename="$1"   # e.g. owner-repo-42.json
	local s_pid="$2"
	local s_worktree="$3"
	local s_issue="${4:-42}"
	local s_slug="${5:-owner/repo}"
	jq -n \
		--arg issue "$s_issue" \
		--arg slug "$s_slug" \
		--argjson pid "$s_pid" \
		--arg worktree_path "$s_worktree" \
		--arg hostname "$LOCAL_HOST" \
		'{issue: $issue, slug: $slug, pid: $pid, worktree_path: $worktree_path, hostname: $hostname}' \
		>"${STAMP_DIR}/${filename}"
	return 0
}

# =============================================================================
# Source helper with stubs to suppress side-effects
# =============================================================================
print_info() { :; return 0; }
print_warning() { :; return 0; }
print_error() { :; return 0; }
print_success() { :; return 0; }
log_verbose() { :; return 0; }
export -f print_info print_warning print_error print_success log_verbose

# shellcheck source=../interactive-session-helper.sh
source "${SCRIPTS_DIR}/interactive-session-helper.sh" >/dev/null 2>&1 || true

# Post-source stubs — override to keep tests hermetic.

# Record auto-release calls and simulate stamp deletion.
_isc_release_claim_by_stamp_path() {
	local stamp_path="$1"
	printf '%s\n' "$stamp_path" >>"${RELEASE_LOG}"
	rm -f "$stamp_path" 2>/dev/null || true
	return 0
}
export -f _isc_release_claim_by_stamp_path

# Phase 1a and Phase 2 are not under test here — suppress them.
_isc_scan_stampless_phase() { :; return 0; }
export -f _isc_scan_stampless_phase

_isc_scan_closed_pr_orphans() { printf '0'; return 0; }
export -f _isc_scan_closed_pr_orphans

# Override CLAIM_STAMP_DIR to the test sandbox.
CLAIM_STAMP_DIR="$STAMP_DIR"

printf '%sRunning scan-stale auto-release tests (t2414 / GH#20012)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — dead PID + missing worktree → stamp auto-released
# =============================================================================
: >"$RELEASE_LOG"
write_stamp "owner-repo-101.json" "99999" "/nonexistent/path/101" "101" "owner/repo"

_isc_cmd_scan_stale --auto-release >/dev/null 2>/dev/null || true

if [[ ! -f "${STAMP_DIR}/owner-repo-101.json" ]]; then
	pass "dead PID + missing worktree → stamp auto-released"
else
	fail "dead PID + missing worktree → stamp auto-released" \
		"stamp file still exists after --auto-release"
fi

# =============================================================================
# Test 2 — live PID + missing worktree → stamp preserved
# =============================================================================
LIVE_PID=$$
write_stamp "owner-repo-102.json" "$LIVE_PID" "/nonexistent/path/102" "102" "owner/repo"

_isc_cmd_scan_stale --auto-release >/dev/null 2>/dev/null || true

if [[ -f "${STAMP_DIR}/owner-repo-102.json" ]]; then
	pass "live PID + missing worktree → stamp preserved"
else
	fail "live PID + missing worktree → stamp preserved" \
		"stamp was deleted despite live PID — must not touch live-PID stamps"
fi
# Cleanup for next tests
rm -f "${STAMP_DIR}/owner-repo-102.json"

# =============================================================================
# Test 3 — dead PID + existing worktree → stamp preserved
# =============================================================================
write_stamp "owner-repo-103.json" "99999" "$EXISTING_WORKTREE" "103" "owner/repo"

_isc_cmd_scan_stale --auto-release >/dev/null 2>/dev/null || true

if [[ -f "${STAMP_DIR}/owner-repo-103.json" ]]; then
	pass "dead PID + existing worktree → stamp preserved"
else
	fail "dead PID + existing worktree → stamp preserved" \
		"stamp was deleted despite existing worktree — in-progress work may exist"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-103.json"

# =============================================================================
# Test 4 — live PID + existing worktree → stamp preserved
# =============================================================================
write_stamp "owner-repo-104.json" "$LIVE_PID" "$EXISTING_WORKTREE" "104" "owner/repo"

_isc_cmd_scan_stale --auto-release >/dev/null 2>/dev/null || true

if [[ -f "${STAMP_DIR}/owner-repo-104.json" ]]; then
	pass "live PID + existing worktree → stamp preserved"
else
	fail "live PID + existing worktree → stamp preserved" \
		"stamp was deleted despite live PID and existing worktree"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-104.json"

# =============================================================================
# Test 5 — --no-auto-release flag → dead+missing stamp NOT released (report only)
# =============================================================================
write_stamp "owner-repo-105.json" "99999" "/nonexistent/path/105" "105" "owner/repo"

_isc_cmd_scan_stale --no-auto-release >/dev/null 2>/dev/null || true

if [[ -f "${STAMP_DIR}/owner-repo-105.json" ]]; then
	pass "--no-auto-release flag → dead+missing stamp preserved (report only)"
else
	fail "--no-auto-release flag → dead+missing stamp preserved (report only)" \
		"stamp was deleted even though --no-auto-release was specified"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-105.json"

# =============================================================================
# Test 6 — AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 env → dead+missing stamp NOT released
# =============================================================================
write_stamp "owner-repo-106.json" "99999" "/nonexistent/path/106" "106" "owner/repo"

AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 _isc_cmd_scan_stale >/dev/null 2>/dev/null || true

if [[ -f "${STAMP_DIR}/owner-repo-106.json" ]]; then
	pass "AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 → stamp preserved"
else
	fail "AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 → stamp preserved" \
		"stamp was deleted despite env var disabling auto-release"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-106.json"

# =============================================================================
# Test 7 — AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 env → dead+missing stamp released
# =============================================================================
write_stamp "owner-repo-107.json" "99999" "/nonexistent/path/107" "107" "owner/repo"

AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 _isc_cmd_scan_stale >/dev/null 2>/dev/null || true

if [[ ! -f "${STAMP_DIR}/owner-repo-107.json" ]]; then
	pass "AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 env → dead+missing stamp released"
else
	fail "AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 env → dead+missing stamp released" \
		"stamp still exists despite AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
