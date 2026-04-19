#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-sync-pat-detection.sh — t2374 regression guard.
#
# Verifies check_sync_pat() in security-posture-helper.sh correctly detects
# repos that need SYNC_PAT but don't have it set, and skips repos where
# SYNC_PAT is not needed.
#
# Six test cases:
#   1. Has issue-sync.yml + branch protection + NO SYNC_PAT → emits advisory
#   2. Has issue-sync.yml + branch protection + HAS SYNC_PAT → no advisory (pass)
#   3. No issue-sync.yml → no advisory (irrelevant)
#   4. No branch protection requiring reviews → no advisory (not needed)
#   5. Dismissed advisory → skip silently
#   6. Stale advisory cleaned up when SYNC_PAT set
#
# Stub strategy: a single configurable gh() stub dispatches based on
# STUB_* variables set per test. This avoids redefining gh() 6 times
# and eliminates direct positional parameter usage across stub functions.

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
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2374.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Override HOME so advisory files go into sandbox
export HOME="$TMP"
mkdir -p "$TMP/.aidevops/advisories"

# Create a fake repo dir
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/.git"

# Constants for stub responses
readonly ISSUE_SYNC_RESPONSE='{"name":"issue-sync.yml"}'
readonly PROTECTION_WITH_REVIEWS='{"required_pull_request_reviews":{"required_approving_review_count":1}}'
readonly GH_API_SYNC_PATTERN="contents/.github/workflows/issue-sync.yml"
readonly GH_API_PROT_PATTERN="/protection"

# =============================================================================
# Configurable stub variables (set per test case)
# =============================================================================
STUB_HAS_ISSUE_SYNC="true"     # "true" = API returns 200, "false" = API returns 1
STUB_PROTECTION_RESPONSE=""     # JSON response from /protection, empty = no protection
STUB_SECRET_RESPONSE=""         # Output from gh secret list, empty = no SYNC_PAT

# Single shared gh stub — dispatches based on STUB_* variables
gh() {
	local cmd="$1"
	case "$cmd" in
	auth)
		return 0
		;;
	api)
		local url="${2:-}"
		if [[ "$url" == *"$GH_API_SYNC_PATTERN"* ]]; then
			if [[ "$STUB_HAS_ISSUE_SYNC" == "true" ]]; then
				echo "$ISSUE_SYNC_RESPONSE"
				return 0
			fi
			return 1
		elif [[ "$url" == *"$GH_API_PROT_PATTERN"* ]]; then
			if [[ -n "$STUB_PROTECTION_RESPONSE" ]]; then
				echo "$STUB_PROTECTION_RESPONSE"
				return 0
			fi
			echo "Branch not protected"
			return 1
		fi
		return 1
		;;
	secret)
		echo "$STUB_SECRET_RESPONSE"
		return 0
		;;
	esac
	return 0
}

# Stub git for default branch detection
git() {
	local subcmd="${2:-}"
	if [[ "$subcmd" == "symbolic-ref" ]]; then
		echo "refs/remotes/origin/main"
		return 0
	fi
	command git "$@"
}

# Stub jq for protection JSON parsing
jq() {
	local args=("$@")
	if [[ "${args[*]}" == *"required_approving_review_count"* ]]; then
		echo "1"
		return 0
	fi
	command jq "$@"
}

export -f gh git jq

# =============================================================================
# Source the helper to get check_sync_pat
# =============================================================================

# Prevent shared-constants.sh from doing anything destructive
export AIDEVOPS_AGENTS_DIR="$TMP/.aidevops/agents"
mkdir -p "$AIDEVOPS_AGENTS_DIR"

# Source shared-constants.sh fallbacks
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Counters (same as in the helper)
FINDINGS_CRITICAL=0
FINDINGS_WARNING=0
FINDINGS_INFO=0
FINDINGS_PASS=0
FINDINGS_JSON="[]"

# Stubs for print functions — capture output for assertions
OUTPUT_LOG="$TMP/output.log"

print_header() { local msg="$1"; echo "[HEADER] $msg" >>"$OUTPUT_LOG"; return 0; }
print_info() { local msg="$1"; echo "[INFO] $msg" >>"$OUTPUT_LOG"; return 0; }
print_pass() {
	local msg="$1"
	echo "[PASS] $msg" >>"$OUTPUT_LOG"
	((++FINDINGS_PASS))
	return 0
}
print_warn() {
	local msg="$1"
	echo "[WARN] $msg" >>"$OUTPUT_LOG"
	((++FINDINGS_WARNING))
	return 0
}
print_crit() {
	local msg="$1"
	echo "[CRIT] $msg" >>"$OUTPUT_LOG"
	((++FINDINGS_CRITICAL))
	return 0
}
print_skip() {
	local msg="$1"
	echo "[SKIP] $msg" >>"$OUTPUT_LOG"
	((++FINDINGS_INFO))
	return 0
}

add_finding() {
	# No-op for tests — we check output log and advisory files instead
	return 0
}

# resolve_slug stub
resolve_slug() {
	echo "testowner/testrepo"
	return 0
}

# Extract function bodies from the helper (check_sync_pat + its sub-functions)
eval "$(sed -n '/^_emit_sync_pat_advisory()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper.sh")"
eval "$(sed -n '/^_check_sync_pat_need()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper.sh")"
eval "$(sed -n '/^check_sync_pat()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper.sh")"

# =============================================================================
# Severity constants needed by the function
# =============================================================================
SEVERITY_CRITICAL="critical"
SEVERITY_WARNING="warning"
SEVERITY_INFO="info"
SEVERITY_PASS="pass"
CAT_SYNC_PAT="sync_pat"

# =============================================================================
# Helper to reset state between tests
# =============================================================================
reset_state() {
	FINDINGS_CRITICAL=0
	FINDINGS_WARNING=0
	FINDINGS_INFO=0
	FINDINGS_PASS=0
	FINDINGS_JSON="[]"
	true >"$OUTPUT_LOG"
	rm -f "$TMP/.aidevops/advisories/sync-pat-"*
	rm -f "$TMP/.aidevops/advisories/.dismissed-sync-pat-"*
	# Reset stub defaults
	STUB_HAS_ISSUE_SYNC="true"
	STUB_PROTECTION_RESPONSE="$PROTECTION_WITH_REVIEWS"
	STUB_SECRET_RESPONSE=""
	return 0
}

ADVISORY_PATH="$TMP/.aidevops/advisories/sync-pat-testowner-testrepo.advisory"

# =============================================================================
# Test 1: Needs SYNC_PAT — emits advisory
# =============================================================================
printf '\n%sTest 1: Repo needs SYNC_PAT (issue-sync + protection + no secret)%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_HAS_ISSUE_SYNC="true"
STUB_PROTECTION_RESPONSE="$PROTECTION_WITH_REVIEWS"
STUB_SECRET_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ -f "$ADVISORY_PATH" ]]; then
	pass "Advisory file created for repo needing SYNC_PAT"
else
	fail "Advisory file NOT created" "Expected: $ADVISORY_PATH"
fi

if [[ -f "$ADVISORY_PATH" ]] && grep -q "gh secret set SYNC_PAT" "$ADVISORY_PATH" 2>/dev/null; then
	pass "Advisory contains remediation command"
else
	fail "Advisory missing remediation command"
fi

if grep -q '\[WARN\].*SYNC_PAT not set' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Warning emitted for missing SYNC_PAT"
else
	fail "No warning emitted" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 2: SYNC_PAT already set — no advisory
# =============================================================================
printf '\n%sTest 2: SYNC_PAT already set — should pass cleanly%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_SECRET_RESPONSE="SYNC_PAT"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when SYNC_PAT is set"
else
	fail "Advisory created despite SYNC_PAT being set"
fi

if grep -q '\[PASS\].*SYNC_PAT is set' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message emitted for set SYNC_PAT"
else
	fail "No pass message" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 3: No issue-sync.yml — no advisory
# =============================================================================
printf '\n%sTest 3: No issue-sync.yml — should skip%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_HAS_ISSUE_SYNC="false"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when issue-sync.yml absent"
else
	fail "Advisory created for repo without issue-sync.yml"
fi

if grep -q '\[PASS\].*No issue-sync.yml' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message emitted for no issue-sync.yml"
else
	fail "No pass message for absent workflow" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 4: No branch protection requiring reviews — no advisory
# =============================================================================
printf '\n%sTest 4: No branch protection requiring reviews — should skip%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when no branch protection"
else
	fail "Advisory created for repo without branch protection"
fi

if grep -q '\[PASS\].*No branch protection' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message emitted for no branch protection"
else
	fail "No pass message for unprotected branch" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 5: Dismissed advisory — should skip silently
# =============================================================================
printf '\n%sTest 5: Dismissed advisory — should skip%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
touch "$TMP/.aidevops/advisories/.dismissed-sync-pat-testowner-testrepo"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when dismissed"
else
	fail "Advisory created despite being dismissed"
fi

if grep -q '\[PASS\].*dismissed' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message emitted for dismissed advisory"
else
	fail "No pass message for dismissed advisory" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 6: Stale advisory cleaned up when SYNC_PAT is set
# =============================================================================
printf '\n%sTest 6: Stale advisory cleaned up when SYNC_PAT set%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
echo "stale" >"$ADVISORY_PATH"
STUB_SECRET_RESPONSE="SYNC_PAT"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "Stale advisory cleaned up after SYNC_PAT set"
else
	fail "Stale advisory NOT cleaned up"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "======================================="
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
fi
echo "======================================="

exit "$TESTS_FAILED"
