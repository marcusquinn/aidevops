#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-footprint-overlap.sh — t2117 regression guard.
#
# Asserts the file-footprint overlap throttle works correctly:
#
#   1. _footprint_extract_paths correctly parses EDIT:/NEW:/backtick paths
#      from issue bodies and strips line qualifiers.
#   2. _footprint_check_overlap detects overlap between a candidate and
#      in-flight issues (via mock data).
#   3. _footprint_check_overlap allows dispatch when file sets are disjoint.
#   4. _footprint_extract_paths returns empty for issues with no file paths.
#   5. Overlap detection handles normalisation (stripping .agents/ prefix).
#
# Failure history motivating this test: GH#19106 (CONFLICTING cascades
# from overlapping file edits by parallel workers).

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# Source the footprint module directly
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/dispatch-dedup-footprint.sh"

# =============================================================================
# Test 1 — _footprint_extract_paths parses EDIT/NEW prefix paths
# =============================================================================
body_with_edits='## Files to Modify

- `EDIT: .agents/scripts/pulse-wrapper.sh:45-60` — add throttle
- `NEW: .agents/scripts/dispatch-dedup-footprint.sh` — new module
- `EDIT: .agents/configs/complexity-thresholds.conf` — update threshold'

result=$(_footprint_extract_paths "$body_with_edits")
# Should contain all three files, stripped of line qualifiers
if printf '%s' "$result" | grep -q "pulse-wrapper.sh" &&
	printf '%s' "$result" | grep -q "dispatch-dedup-footprint.sh" &&
	printf '%s' "$result" | grep -q "complexity-thresholds.conf"; then
	print_result "extract_paths: parses EDIT/NEW prefixed paths" 0
else
	print_result "extract_paths: parses EDIT/NEW prefixed paths" 1 "(got: ${result})"
fi

# =============================================================================
# Test 2 — _footprint_extract_paths strips line qualifiers
# =============================================================================
body_with_lines='- `EDIT: scripts/helper.sh:1477` — fix bug
- `EDIT: scripts/other.sh:221-253` — refactor section'

result=$(_footprint_extract_paths "$body_with_lines")
# Should NOT contain :1477 or :221-253
if printf '%s' "$result" | grep -q ":[0-9]"; then
	print_result "extract_paths: strips line qualifiers" 1 "(line qualifiers still present: ${result})"
else
	print_result "extract_paths: strips line qualifiers" 0
fi

# =============================================================================
# Test 3 ��� _footprint_extract_paths parses backtick paths on list items
# =============================================================================
body_backticks='## Context

Root-cause data and prior fix: GH#19106 / PR #19107. Relevant files:
- `.agents/scripts/dispatch-dedup-helper.sh` (the dedup ledger)
- `.agents/scripts/pulse-wrapper.sh` (dispatch caller)
- `.agents/templates/brief-template.md` (Files to modify section format)'

result=$(_footprint_extract_paths "$body_backticks")
if printf '%s' "$result" | grep -q "dispatch-dedup-helper.sh" &&
	printf '%s' "$result" | grep -q "pulse-wrapper.sh" &&
	printf '%s' "$result" | grep -q "brief-template.md"; then
	print_result "extract_paths: parses backtick paths on list items" 0
else
	print_result "extract_paths: parses backtick paths on list items" 1 "(got: ${result})"
fi

# =============================================================================
# Test 4 — _footprint_extract_paths returns empty for no-path body
# =============================================================================
body_no_paths='This issue is about improving performance.
No specific files mentioned here, just a general discussion.'

result=$(_footprint_extract_paths "$body_no_paths")
if [[ -z "$result" ]]; then
	print_result "extract_paths: returns empty for body with no file paths" 0
else
	print_result "extract_paths: returns empty for body with no file paths" 1 "(got: ${result})"
fi

# =============================================================================
# Test 5 — _footprint_check_overlap detects overlap via mock cache
# =============================================================================
# Simulate an in-flight issue #100 modifying pulse-wrapper.sh
_FOOTPRINT_CACHE_REPO="test/repo"
_FOOTPRINT_CACHE_DATA="scripts/pulse-wrapper.sh|100\nscripts/shared-constants.sh|100\n"
_FOOTPRINT_CACHE_EPOCH=$(date +%s)

# Candidate issue #200 also targets pulse-wrapper.sh
candidate_body='## Files to Modify
- `EDIT: scripts/pulse-wrapper.sh:100-120` — add new feature'

signal=""
overlap_rc=1
signal=$(_footprint_check_overlap "200" "test/repo" "$candidate_body") && overlap_rc=0 || overlap_rc=$?
if [[ "$overlap_rc" -eq 0 ]] && printf '%s' "$signal" | grep -q "FOOTPRINT_OVERLAP"; then
	print_result "check_overlap: detects overlapping files with in-flight issue" 0
else
	print_result "check_overlap: detects overlapping files with in-flight issue" 1 "(rc=${overlap_rc}, signal=${signal})"
fi

# =============================================================================
# Test 6 �� _footprint_check_overlap allows disjoint file sets
# =============================================================================
# In-flight #100 modifies pulse-wrapper.sh, candidate #201 modifies a different file
_FOOTPRINT_CACHE_REPO="test/repo"
_FOOTPRINT_CACHE_DATA="scripts/pulse-wrapper.sh|100\n"
_FOOTPRINT_CACHE_EPOCH=$(date +%s)

disjoint_body='## Files to Modify
- `EDIT: scripts/dispatch-claim-helper.sh:50-70` — different file entirely'

signal=""
overlap_rc=1
signal=$(_footprint_check_overlap "201" "test/repo" "$disjoint_body") && overlap_rc=0 || overlap_rc=$?
if [[ "$overlap_rc" -eq 1 ]]; then
	print_result "check_overlap: allows disjoint file sets" 0
else
	print_result "check_overlap: allows disjoint file sets" 1 "(rc=${overlap_rc}, signal=${signal})"
fi

# =============================================================================
# Test 7 — _footprint_check_overlap handles .agents/ prefix normalisation
# =============================================================================
# In-flight #100 has path without .agents/ prefix
_FOOTPRINT_CACHE_REPO="test/repo"
_FOOTPRINT_CACHE_DATA="scripts/pulse-wrapper.sh|100\n"
_FOOTPRINT_CACHE_EPOCH=$(date +%s)

# Candidate references same file WITH .agents/ prefix
normalise_body='## Files to Modify
- `EDIT: .agents/scripts/pulse-wrapper.sh:200-220` — same file, different prefix'

signal=""
overlap_rc=1
signal=$(_footprint_check_overlap "202" "test/repo" "$normalise_body") && overlap_rc=0 || overlap_rc=$?
if [[ "$overlap_rc" -eq 0 ]] && printf '%s' "$signal" | grep -q "FOOTPRINT_OVERLAP"; then
	print_result "check_overlap: handles .agents/ prefix normalisation" 0
else
	print_result "check_overlap: handles .agents/ prefix normalisation" 1 "(rc=${overlap_rc}, signal=${signal})"
fi

# =============================================================================
# Test 8 — _footprint_check_overlap excludes self from in-flight check
# =============================================================================
# In-flight includes issue #300 itself
_FOOTPRINT_CACHE_REPO="test/repo"
_FOOTPRINT_CACHE_DATA="scripts/pulse-wrapper.sh|300\n"
_FOOTPRINT_CACHE_EPOCH=$(date +%s)

self_body='## Files to Modify
- `EDIT: scripts/pulse-wrapper.sh:50-60` — same file as self'

signal=""
overlap_rc=1
signal=$(_footprint_check_overlap "300" "test/repo" "$self_body") && overlap_rc=0 || overlap_rc=$?
if [[ "$overlap_rc" -eq 1 ]]; then
	print_result "check_overlap: excludes self from overlap detection" 0
else
	print_result "check_overlap: excludes self from overlap detection" 1 "(rc=${overlap_rc}, signal=${signal})"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Tests: ${TESTS_RUN} run, ${TESTS_FAILED} failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
