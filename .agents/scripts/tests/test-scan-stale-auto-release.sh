#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-scan-stale-auto-release.sh — stale interactive claim regression guard.
#
# Asserts that `_isc_cmd_scan_stale` Phase 1 auto-releases only verifiably dead
# claims without a surviving worktree or no-auto-dispatch lockdown.
#
# Background (GH#20012, t2414):
#   scan-stale Phase 1 previously ONLY reported dead stamps, requiring N manual
#   `interactive-session-helper.sh release` calls per crashed session. Dead
#   owner PID is safe to auto-release only when no surviving worktree or
#   explicit lockdown provides contrary ownership evidence.
#
# t3205 (GH#21913): the bare TTY check `[[ -t 0 && -t 1 ]]` collapsed two
#   distinct concepts (truly-headless vs AI-agent-interactive). OpenCode TUI
#   and Claude Code CLI agents pipe their bash subprocess from the runtime,
#   so the TTY check returned false in user-driving-an-agent sessions, leaving
#   stale stamps unreleased every session-start scan. Tests 8 and 9 lock in
#   the three-way detection that distinguishes:
#     - human TTY → ON
#     - explicit headless markers → OFF (wins over AI-agent markers)
#     - AI-agent runtime markers → ON
#     - unknown → OFF (conservative)
#
# Tests:
#   1. dead PID + missing worktree → stamp auto-released (file removed)
#   2. live PID + missing worktree → stamp preserved
#   3. dead PID + existing worktree → stamp preserved
#   4. live PID + existing worktree → stamp preserved
#   5. recycled PID / argv-hash mismatch + existing worktree → stamp preserved
#   6. --no-auto-release flag → dead+missing stamp NOT released (report only)
#   7. AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 env → dead+missing stamp NOT released
#   8. AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 env + non-TTY → dead+missing released
#   9. OPENCODE_SESSION_ID set, no TTY, no headless → dead+missing released (t3205)
#   10. AIDEVOPS_HEADLESS + OPENCODE_SESSION_ID → stamp preserved (headless wins, t3205)
#   11. report-only scan preserves claims with a surviving worktree.
#   12. release-if-dead releases one same-host dead claim.
#   13. release-if-dead preserves live, cross-host, and lockdown claims.
#   14. scan-stale preserves lockdown and unverifiable claims.
#   15. claim stamps record the durable runtime owner rather than the helper PID.
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
	local s_owner_argv_hash="${6:-}"
	jq -n \
		--arg issue "$s_issue" \
		--arg slug "$s_slug" \
		--argjson pid "$s_pid" \
		--arg worktree_path "$s_worktree" \
		--arg hostname "$LOCAL_HOST" \
		--arg owner_argv_hash "$s_owner_argv_hash" \
		'{issue: $issue, slug: $slug, pid: $pid, worktree_path: $worktree_path, hostname: $hostname, owner_argv_hash: $owner_argv_hash}' \
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

# Override WORKER_PROCESS_PATTERN so the test bash process matches when we
# plant a stamp with pid=$$ (Test 2 / Test 4). The default pattern
# 'opencode|claude|Claude' (shared-constants.sh:1104) intentionally rejects
# non-runtime PIDs to defeat macOS PID reuse spoofing (t2421, GH#20027). The
# test process is bash, so we extend the pattern. Must be `export`ed BEFORE
# `source` so subshells in Tests 8/9 inherit it; the
# `[[ -z "${WORKER_PROCESS_PATTERN+x}" ]]` guard in shared-constants.sh
# preserves our value across `source` calls. Mirrors the precedent in
# test-worktree-cleanup-claim-guard.sh:75 (t2421 fan-out).
export WORKER_PROCESS_PATTERN='opencode|claude|Claude|bash'

# shellcheck source=../interactive-session-helper.sh
source "${SCRIPTS_DIR}/interactive-session-helper.sh" >/dev/null 2>&1 || true

# Post-source stubs — override to keep tests hermetic.

ISC_LABEL_MODE="absent"
export ISC_LABEL_MODE
_isc_has_label() {
	local issue="$1"
	local slug="$2"
	local label="$3"
	: "$issue" "$slug" "$label"
	case "$ISC_LABEL_MODE" in
	present) return 0 ;;
	unknown) return 2 ;;
	esac
	return 1
}
export -f _isc_has_label

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
		"stamp was deleted despite a surviving worktree"
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
# Test 5 — recycled PID / argv-hash mismatch + existing worktree → stamp preserved
# =============================================================================
write_stamp "owner-repo-105.json" "$LIVE_PID" "$EXISTING_WORKTREE" "105" "owner/repo" "not-the-live-process-hash"

_isc_cmd_scan_stale --auto-release >/dev/null 2>/dev/null || true

if [[ -f "${STAMP_DIR}/owner-repo-105.json" ]]; then
	pass "recycled PID + existing worktree → stamp preserved"
else
	fail "recycled PID + existing worktree → stamp preserved" \
		"stamp was deleted despite a surviving worktree"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-105.json"

# =============================================================================
# Test 6 — --no-auto-release flag → dead+missing stamp NOT released (report only)
# =============================================================================
write_stamp "owner-repo-106.json" "99999" "/nonexistent/path/106" "106" "owner/repo"

_isc_cmd_scan_stale --no-auto-release >/dev/null 2>/dev/null || true

if [[ -f "${STAMP_DIR}/owner-repo-106.json" ]]; then
	pass "--no-auto-release flag → dead+missing stamp preserved (report only)"
else
	fail "--no-auto-release flag → dead+missing stamp preserved (report only)" \
		"stamp was deleted even though --no-auto-release was specified"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-106.json"

# =============================================================================
# Test 7 — AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 env → dead+missing stamp NOT released
# =============================================================================
write_stamp "owner-repo-107.json" "99999" "/nonexistent/path/107" "107" "owner/repo"

AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 _isc_cmd_scan_stale >/dev/null 2>/dev/null || true

if [[ -f "${STAMP_DIR}/owner-repo-107.json" ]]; then
	pass "AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 → stamp preserved"
else
	fail "AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0 → stamp preserved" \
		"stamp was deleted despite env var disabling auto-release"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-107.json"

# =============================================================================
# Test 8 — AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 env → dead+missing stamp released
# =============================================================================
write_stamp "owner-repo-108.json" "99999" "/nonexistent/path/108" "108" "owner/repo"

AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 _isc_cmd_scan_stale >/dev/null 2>/dev/null || true

if [[ ! -f "${STAMP_DIR}/owner-repo-108.json" ]]; then
	pass "AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 env → dead+missing stamp released"
else
	fail "AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1 env → dead+missing stamp released" \
		"stamp still exists despite AIDEVOPS_SCAN_STALE_AUTO_RELEASE=1"
fi

# =============================================================================
# Test 9 — AI-agent runtime markers (no TTY, no headless) → auto-released (t3205)
# =============================================================================
# t3205: previously, scan-stale defaulted auto-release OFF in OpenCode/Claude
# Code agent sessions because the agent's bash subprocess is piped from the
# runtime ([[ -t 0 && -t 1 ]] returns false). Tests 8/9 lock in the new
# three-way detection: runtime markers count as "interactive enough".
write_stamp "owner-repo-109.json" "99999" "/nonexistent/path/109" "109" "owner/repo"

# Force off all override paths and headless markers; set AI-agent marker only.
# Tests run via `bash test.sh`, so [[ -t 0 && -t 1 ]] is already false here.
unset AIDEVOPS_SCAN_STALE_AUTO_RELEASE
env -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS \
	-u GITHUB_ACTIONS -u OPENCODE_RUN_ID -u OPENCODE_PID \
	-u CLAUDECODE -u CLAUDE_CODE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SSE_PORT \
	OPENCODE_SESSION_ID=test-session-id \
	bash -c "
		set -uo pipefail
		# Re-source the helper inside this clean env subshell.
		# shellcheck source=/dev/null
		source '${SCRIPTS_DIR}/interactive-session-helper.sh' >/dev/null 2>&1 || true
		_isc_release_claim_by_stamp_path() {
			rm -f \"\$1\" 2>/dev/null || true
			return 0
		}
		_isc_has_label() { return 1; }
		_isc_scan_stampless_phase() { :; return 0; }
		_isc_scan_closed_pr_orphans() { printf '0'; return 0; }
		CLAIM_STAMP_DIR='$STAMP_DIR'
		_isc_cmd_scan_stale >/dev/null 2>/dev/null || true
	"

if [[ ! -f "${STAMP_DIR}/owner-repo-109.json" ]]; then
	pass "OPENCODE_SESSION_ID set, no TTY → dead+missing stamp auto-released"
else
	fail "OPENCODE_SESSION_ID set, no TTY → dead+missing stamp auto-released" \
		"stamp still exists despite AI-agent runtime marker — t3205 branch did not fire"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-109.json"

# =============================================================================
# Test 10 — Headless wins over AI-agent marker → stamp preserved (t3205)
# =============================================================================
# When BOTH AIDEVOPS_HEADLESS and OPENCODE_SESSION_ID are set, the headless
# marker MUST take precedence. Pulse-spawned workers run inside an OpenCode
# child process and inherit OPENCODE_SESSION_ID; without this precedence rule,
# the worker would auto-release stamps owned by other live sessions.
write_stamp "owner-repo-110.json" "99999" "/nonexistent/path/110" "110" "owner/repo"

env -u FULL_LOOP_HEADLESS -u OPENCODE_HEADLESS -u GITHUB_ACTIONS \
	-u OPENCODE_RUN_ID -u OPENCODE_PID -u CLAUDECODE -u CLAUDE_CODE \
	-u CLAUDE_SESSION_ID -u CLAUDE_CODE_SSE_PORT \
	AIDEVOPS_HEADLESS=1 OPENCODE_SESSION_ID=test-session-id \
	bash -c "
		set -uo pipefail
		unset AIDEVOPS_SCAN_STALE_AUTO_RELEASE
		# shellcheck source=/dev/null
		source '${SCRIPTS_DIR}/interactive-session-helper.sh' >/dev/null 2>&1 || true
		_isc_release_claim_by_stamp_path() {
			rm -f \"\$1\" 2>/dev/null || true
			return 0
		}
		_isc_scan_stampless_phase() { :; return 0; }
		_isc_scan_closed_pr_orphans() { printf '0'; return 0; }
		CLAIM_STAMP_DIR='$STAMP_DIR'
		_isc_cmd_scan_stale >/dev/null 2>/dev/null || true
	"

if [[ -f "${STAMP_DIR}/owner-repo-110.json" ]]; then
	pass "AIDEVOPS_HEADLESS=1 + OPENCODE_SESSION_ID → stamp preserved (headless wins)"
else
	fail "AIDEVOPS_HEADLESS=1 + OPENCODE_SESSION_ID → stamp preserved (headless wins)" \
		"stamp deleted — headless marker must take precedence over AI-agent marker"
fi

# =============================================================================
# Tests 12-13 — bounded pulse command releases only a safe dead claim
# =============================================================================
ISC_LABEL_MODE="absent"
write_stamp "owner-repo-112.json" "99999" "$EXISTING_WORKTREE" "112" "owner/repo"
if _isc_cmd_release_if_dead "112" "owner/repo" >/dev/null 2>&1 && [[ ! -f "${STAMP_DIR}/owner-repo-112.json" ]]; then
	pass "release-if-dead releases a same-host dead claim"
else
	fail "release-if-dead releases a same-host dead claim"
fi

write_stamp "owner-repo-113.json" "$LIVE_PID" "$EXISTING_WORKTREE" "113" "owner/repo"
if ! _isc_cmd_release_if_dead "113" "owner/repo" >/dev/null 2>&1 && [[ -f "${STAMP_DIR}/owner-repo-113.json" ]]; then
	pass "release-if-dead preserves a live claim"
else
	fail "release-if-dead preserves a live claim"
fi
rm -f "${STAMP_DIR}/owner-repo-113.json"

write_stamp "owner-repo-114.json" "99999" "$EXISTING_WORKTREE" "114" "owner/repo"
jq '.hostname = "another-host"' "${STAMP_DIR}/owner-repo-114.json" >"${STAMP_DIR}/owner-repo-114.tmp"
mv "${STAMP_DIR}/owner-repo-114.tmp" "${STAMP_DIR}/owner-repo-114.json"
if ! _isc_cmd_release_if_dead "114" "owner/repo" >/dev/null 2>&1 && [[ -f "${STAMP_DIR}/owner-repo-114.json" ]]; then
	pass "release-if-dead preserves a cross-host claim"
else
	fail "release-if-dead preserves a cross-host claim"
fi
rm -f "${STAMP_DIR}/owner-repo-114.json"

ISC_LABEL_MODE="present"
write_stamp "owner-repo-115.json" "99999" "$EXISTING_WORKTREE" "115" "owner/repo"
if ! _isc_cmd_release_if_dead "115" "owner/repo" >/dev/null 2>&1 && [[ -f "${STAMP_DIR}/owner-repo-115.json" ]]; then
	pass "release-if-dead preserves a no-auto-dispatch lockdown"
else
	fail "release-if-dead preserves a no-auto-dispatch lockdown"
fi
rm -f "${STAMP_DIR}/owner-repo-115.json"
ISC_LABEL_MODE="absent"
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-110.json"

# =============================================================================
# Test 11 — report-only scan ignores claims with a surviving worktree
# =============================================================================
write_stamp "owner-repo-111.json" "99999" "$EXISTING_WORKTREE" "111" "owner/repo"

REPORT_OUTPUT=$(_isc_cmd_scan_stale --no-auto-release 2>/dev/null || true)

if [[ -f "${STAMP_DIR}/owner-repo-111.json" ]] && \
	[[ "$REPORT_OUTPUT" != *"#111 in owner/repo"* ]]; then
	pass "report-only scan preserves and ignores an existing worktree"
else
	fail "report-only scan preserves and ignores an existing worktree"
fi
# Cleanup
rm -f "${STAMP_DIR}/owner-repo-111.json"

# =============================================================================
# Test 14 — scan-stale lockdown and label lookup failures fail closed
# =============================================================================
ISC_LABEL_MODE="present"
write_stamp "owner-repo-116.json" "99999" "/nonexistent/path/116" "116" "owner/repo"
_isc_cmd_scan_stale --auto-release >/dev/null 2>/dev/null || true
if [[ -f "${STAMP_DIR}/owner-repo-116.json" ]]; then
	pass "scan-stale preserves a no-auto-dispatch lockdown"
else
	fail "scan-stale preserves a no-auto-dispatch lockdown"
fi
rm -f "${STAMP_DIR}/owner-repo-116.json"

ISC_LABEL_MODE="unknown"
write_stamp "owner-repo-117.json" "99999" "/nonexistent/path/117" "117" "owner/repo"
_isc_cmd_scan_stale --auto-release >/dev/null 2>/dev/null || true
if [[ -f "${STAMP_DIR}/owner-repo-117.json" ]]; then
	pass "scan-stale preserves a claim when labels are unverifiable"
else
	fail "scan-stale preserves a claim when labels are unverifiable"
fi
rm -f "${STAMP_DIR}/owner-repo-117.json"
ISC_LABEL_MODE="absent"

write_stamp "owner-repo-119.json" "99999" "/nonexistent/path/119" "119" "owner/repo"
jq 'del(.pid)' "${STAMP_DIR}/owner-repo-119.json" >"${STAMP_DIR}/owner-repo-119.tmp"
mv "${STAMP_DIR}/owner-repo-119.tmp" "${STAMP_DIR}/owner-repo-119.json"
_isc_cmd_scan_stale --auto-release >/dev/null 2>/dev/null || true
if [[ -f "${STAMP_DIR}/owner-repo-119.json" ]]; then
	pass "scan-stale preserves a claim with unverifiable owner metadata"
else
	fail "scan-stale preserves a claim with unverifiable owner metadata"
fi
rm -f "${STAMP_DIR}/owner-repo-119.json"

# =============================================================================
# Test 15 — stamps bind to the durable runtime owner, not the helper shell
# =============================================================================
_resolve_worktree_owner_pid() { printf '4242'; return 0; }
_compute_argv_hash() {
	local pid="$1"
	printf 'hash-%s' "$pid"
	return 0
}
CLAIM_STAMP_DIR="$STAMP_DIR"
_isc_write_stamp "118" "owner/repo" "/nonexistent/path/118" "owner"
DURABLE_STAMP="${STAMP_DIR}/owner-repo-118.json"
if [[ "$(jq -r '.pid' "$DURABLE_STAMP")" == "4242" ]] && \
	[[ "$(jq -r '.owner_argv_hash' "$DURABLE_STAMP")" == "hash-4242" ]]; then
	pass "claim stamp records the durable runtime owner"
else
	fail "claim stamp records the durable runtime owner"
fi
rm -f "$DURABLE_STAMP"

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
