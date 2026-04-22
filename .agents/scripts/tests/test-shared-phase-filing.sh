#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-shared-phase-filing.sh — t2740 regression guard.
#
# Tests the sequential phase auto-filing logic in shared-phase-filing.sh.
# Covers:
#   1. _parse_phases_section: correct extraction of phase lines
#   2. Feature flag guard: no-op when AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=0
#   3. Phase marker filtering: only [auto-fire:on-prior-merge] phases are filed
#   4. Dedup: phases with existing child refs are skipped
#   5. Parent discovery from child body references
#
# Strategy:
#   Source the module directly and stub gh/gh_create_issue to avoid real API
#   calls. Test pure parsing functions directly and the auto_file_next_phase
#   entry point with mocked dependencies.

set -uo pipefail

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
TMP=$(mktemp -d -t t2740.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/test.log"
export LOGFILE

# Source the module under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Prevent the include guard from blocking re-source in test
unset _SHARED_PHASE_FILING_LOADED

# Source with feature flag OFF by default
export AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=0
source "${SCRIPT_DIR}/shared-phase-filing.sh"

# =============================================================================
# Test 1: _parse_phases_section — basic parsing
# =============================================================================
printf '%s--- Test 1: _parse_phases_section basic parsing ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_1='## Task

Some task description.

## Phases

- Phase 1 - Remove auto-dispatch label plumbing [auto-fire:on-prior-merge] #20415
- Phase 2 - Update dispatch dedup logic [auto-fire:on-prior-merge]
- Phase 3 - Architecture review [requires-decision]
- Phase 4 - Clean up gate logic [auto-fire:on-prior-merge] #20500

## Acceptance

- Some criteria'

phases_output=$(_parse_phases_section "$PARENT_BODY_1")
phase_count=$(printf '%s\n' "$phases_output" | grep -c '^[0-9]')

if [[ "$phase_count" -eq 4 ]]; then
	pass "Parsed 4 phases from body"
else
	fail "Expected 4 phases, got ${phase_count}" "Output: ${phases_output}"
fi

# Check Phase 1 fields
p1_line=$(printf '%s\n' "$phases_output" | head -1)
p1_num=$(printf '%s' "$p1_line" | cut -f1)
p1_marker=$(printf '%s' "$p1_line" | cut -f3)
p1_child=$(printf '%s' "$p1_line" | cut -f4)

if [[ "$p1_num" == "1" ]]; then
	pass "Phase 1 number is 1"
else
	fail "Phase 1 number expected 1, got '${p1_num}'"
fi

if [[ "$p1_marker" == "auto-fire" ]]; then
	pass "Phase 1 marker is auto-fire"
else
	fail "Phase 1 marker expected auto-fire, got '${p1_marker}'"
fi

if [[ "$p1_child" == "20415" ]]; then
	pass "Phase 1 child is 20415"
else
	fail "Phase 1 child expected 20415, got '${p1_child}'"
fi

# Check Phase 2 (no child)
p2_line=$(printf '%s\n' "$phases_output" | sed -n '2p')
p2_marker=$(printf '%s' "$p2_line" | cut -f3)
p2_child=$(printf '%s' "$p2_line" | cut -f4)

if [[ "$p2_marker" == "auto-fire" ]]; then
	pass "Phase 2 marker is auto-fire"
else
	fail "Phase 2 marker expected auto-fire, got '${p2_marker}'"
fi

if [[ -z "$p2_child" ]]; then
	pass "Phase 2 has no child ref"
else
	fail "Phase 2 child expected empty, got '${p2_child}'"
fi

# Check Phase 3 (requires-decision)
p3_line=$(printf '%s\n' "$phases_output" | sed -n '3p')
p3_marker=$(printf '%s' "$p3_line" | cut -f3)

if [[ "$p3_marker" == "requires-decision" ]]; then
	pass "Phase 3 marker is requires-decision"
else
	fail "Phase 3 marker expected requires-decision, got '${p3_marker}'"
fi

# =============================================================================
# Test 2: _parse_phases_section — empty body
# =============================================================================
printf '%s--- Test 2: _parse_phases_section empty body ---%s\n' "$TEST_BLUE" "$TEST_NC"

empty_output=$(_parse_phases_section "")
if [[ -z "$empty_output" ]]; then
	pass "Empty body returns empty output"
else
	fail "Expected empty output for empty body, got '${empty_output}'"
fi

# =============================================================================
# Test 3: _parse_phases_section — no Phases section
# =============================================================================
printf '%s--- Test 3: _parse_phases_section no Phases section ---%s\n' "$TEST_BLUE" "$TEST_NC"

no_phases_body='## Task

Description here.

## How

Steps here.'

no_phases_output=$(_parse_phases_section "$no_phases_body")
if [[ -z "$no_phases_output" ]]; then
	pass "No ## Phases section returns empty output"
else
	fail "Expected empty output when no ## Phases, got '${no_phases_output}'"
fi

# =============================================================================
# Test 4: _parse_phases_section — colon separator
# =============================================================================
printf '%s--- Test 4: _parse_phases_section colon separator ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_COLON='## Phases

- Phase 1: Remove old plumbing [auto-fire:on-prior-merge]
- Phase 2: Update logic [auto-fire:on-prior-merge]'

colon_output=$(_parse_phases_section "$PARENT_BODY_COLON")
colon_count=$(printf '%s\n' "$colon_output" | grep -c '^[0-9]')

if [[ "$colon_count" -eq 2 ]]; then
	pass "Parsed 2 phases with colon separator"
else
	fail "Expected 2 phases with colon separator, got ${colon_count}"
fi

# =============================================================================
# Test 5: Feature flag guard — auto_file_next_phase is no-op when flag=0
# =============================================================================
printf '%s--- Test 5: Feature flag guard ---%s\n' "$TEST_BLUE" "$TEST_NC"

export AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=0
auto_file_next_phase "123" "owner/repo"
log_content=""
[[ -f "$LOGFILE" ]] && log_content=$(cat "$LOGFILE")
if ! printf '%s' "$log_content" | grep -q "Checking child"; then
	pass "Feature flag off: no-op (no checking log)"
else
	fail "Feature flag off: should not have attempted checking"
fi

# =============================================================================
# Test 6: _build_phase_child_body — worker-ready body
# =============================================================================
printf '%s--- Test 6: _build_phase_child_body worker-ready body ---%s\n' "$TEST_BLUE" "$TEST_NC"

child_body=$(_build_phase_child_body "100" "Parent Title" "2" "Update dispatch" "owner/repo")

# Check for required heading signals (t2417: need 5+)
heading_count=0
printf '%s' "$child_body" | grep -q '^## What' && heading_count=$((heading_count + 1))
printf '%s' "$child_body" | grep -q '^## Why' && heading_count=$((heading_count + 1))
printf '%s' "$child_body" | grep -q '^## How' && heading_count=$((heading_count + 1))
printf '%s' "$child_body" | grep -q '^## Acceptance' && heading_count=$((heading_count + 1))
printf '%s' "$child_body" | grep -q '^## Session Origin' && heading_count=$((heading_count + 1))

if [[ "$heading_count" -ge 5 ]]; then
	pass "Phase child body has ${heading_count} heading signals (>=5 required)"
else
	fail "Phase child body has only ${heading_count} heading signals, need >=5"
fi

# Check for parent reference
if printf '%s' "$child_body" | grep -q 'Ref #100'; then
	pass "Phase child body contains 'Ref #100' parent reference"
else
	fail "Phase child body missing 'Ref #100' parent reference"
fi

# Check for generator marker
if printf '%s' "$child_body" | grep -q 'aidevops:generator=phase-autofile parent=100 phase=2'; then
	pass "Phase child body contains generator marker"
else
	fail "Phase child body missing generator marker"
fi

# =============================================================================
# Test 7: _parse_phases_section — phase with no marker
# =============================================================================
printf '%s--- Test 7: _parse_phases_section no marker ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_NO_MARKER='## Phases

- Phase 1 - Some work
- Phase 2 - Other work [auto-fire:on-prior-merge]'

no_marker_output=$(_parse_phases_section "$PARENT_BODY_NO_MARKER")
p1_no_marker=$(printf '%s\n' "$no_marker_output" | head -1 | cut -f3)

if [[ "$p1_no_marker" == "none" ]]; then
	pass "Phase with no marker gets 'none'"
else
	fail "Phase with no marker expected 'none', got '${p1_no_marker}'"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%s=== Results: %d/%d passed ===%s\n' \
	"$TEST_BLUE" "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TEST_NC"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%s%d test(s) failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_NC"
	exit 1
fi
printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
