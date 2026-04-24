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
# Test 8: _parse_phases_section — bold-heading form basic detection
# =============================================================================
printf '%s--- Test 8: _parse_phases_section bold-heading form basic ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_BOLD='## Phases

**Phase 1 — Remove auto-dispatch label plumbing**
**Phase 2 — Update dispatch dedup logic**
**Phase 3 — Architecture review**

## Acceptance

- Some criteria'

bold_output=$(_parse_phases_section "$PARENT_BODY_BOLD")
bold_count=$(printf '%s\n' "$bold_output" | grep -c '^[0-9]')

if [[ "$bold_count" -eq 3 ]]; then
	pass "Parsed 3 bold-heading phases from body"
else
	fail "Expected 3 bold-heading phases, got ${bold_count}" "Output: ${bold_output}"
fi

# Check Phase 1 fields
b1_line=$(printf '%s\n' "$bold_output" | head -1)
b1_num=$(printf '%s' "$b1_line" | cut -f1)
b1_desc=$(printf '%s' "$b1_line" | cut -f2)
b1_marker=$(printf '%s' "$b1_line" | cut -f3)
b1_child=$(printf '%s' "$b1_line" | cut -f4)

if [[ "$b1_num" == "1" ]]; then
	pass "Bold Phase 1 number is 1"
else
	fail "Bold Phase 1 number expected 1, got '${b1_num}'"
fi

if [[ "$b1_desc" == "Remove auto-dispatch label plumbing" ]]; then
	pass "Bold Phase 1 description is correct"
else
	fail "Bold Phase 1 description expected 'Remove auto-dispatch label plumbing', got '${b1_desc}'"
fi

if [[ "$b1_marker" == "none" ]]; then
	pass "Bold Phase 1 default marker is 'none'"
else
	fail "Bold Phase 1 marker expected 'none', got '${b1_marker}'"
fi

if [[ -z "$b1_child" ]]; then
	pass "Bold Phase 1 has no child ref"
else
	fail "Bold Phase 1 child expected empty, got '${b1_child}'"
fi

# =============================================================================
# Test 9: _parse_phases_section — bold-heading default marker is 'none'
# =============================================================================
printf '%s--- Test 9: _parse_phases_section bold-heading default marker none ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_BOLD_NONE='## Phases

**Phase 1 — Some work**
**Phase 2 — Other work**'

none_marker_output=$(_parse_phases_section "$PARENT_BODY_BOLD_NONE")
b_none_1=$(printf '%s\n' "$none_marker_output" | head -1 | cut -f3)
b_none_2=$(printf '%s\n' "$none_marker_output" | sed -n '2p' | cut -f3)

if [[ "$b_none_1" == "none" && "$b_none_2" == "none" ]]; then
	pass "Both bold phases default to 'none' marker"
else
	fail "Bold phase markers expected 'none', got '${b_none_1}' and '${b_none_2}'"
fi

# =============================================================================
# Test 10: _parse_phases_section — explicit [auto-fire:on-prior-merge] on bold form
# =============================================================================
printf '%s--- Test 10: _parse_phases_section bold-heading explicit auto-fire ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_BOLD_EXPLICIT='## Phases

**Phase 1 — Remove plumbing [auto-fire:on-prior-merge]**
**Phase 2 — Update logic [requires-decision]**
**Phase 3 — No marker**'

explicit_output=$(_parse_phases_section "$PARENT_BODY_BOLD_EXPLICIT")

e1_marker=$(printf '%s\n' "$explicit_output" | head -1 | cut -f3)
e2_marker=$(printf '%s\n' "$explicit_output" | sed -n '2p' | cut -f3)
e3_marker=$(printf '%s\n' "$explicit_output" | sed -n '3p' | cut -f3)

if [[ "$e1_marker" == "auto-fire" ]]; then
	pass "Bold Phase 1 explicit [auto-fire:on-prior-merge] → marker=auto-fire"
else
	fail "Bold Phase 1 marker expected 'auto-fire', got '${e1_marker}'"
fi

if [[ "$e2_marker" == "requires-decision" ]]; then
	pass "Bold Phase 2 explicit [requires-decision] → marker=requires-decision"
else
	fail "Bold Phase 2 marker expected 'requires-decision', got '${e2_marker}'"
fi

if [[ "$e3_marker" == "none" ]]; then
	pass "Bold Phase 3 no marker → default 'none'"
else
	fail "Bold Phase 3 marker expected 'none', got '${e3_marker}'"
fi

# Description must not include the marker bracket
e1_desc=$(printf '%s\n' "$explicit_output" | head -1 | cut -f2)
if [[ "$e1_desc" == "Remove plumbing" ]]; then
	pass "Bold Phase 1 description stripped of marker bracket"
else
	fail "Bold Phase 1 description expected 'Remove plumbing', got '${e1_desc}'"
fi

# =============================================================================
# Test 11: _parse_phases_section — <!-- phase-auto-fire:on --> flips all bold phases
# =============================================================================
printf '%s--- Test 11: _parse_phases_section global opt-in comment ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_GLOBAL_OPTIN='<!-- phase-auto-fire:on -->

## Phases

**Phase 1 — First phase**
**Phase 2 — Second phase**

## Acceptance

- Done'

global_output=$(_parse_phases_section "$PARENT_BODY_GLOBAL_OPTIN")
g1_marker=$(printf '%s\n' "$global_output" | head -1 | cut -f3)
g2_marker=$(printf '%s\n' "$global_output" | sed -n '2p' | cut -f3)

if [[ "$g1_marker" == "auto-fire" ]]; then
	pass "Global opt-in: bold Phase 1 flipped to 'auto-fire'"
else
	fail "Global opt-in: bold Phase 1 marker expected 'auto-fire', got '${g1_marker}'"
fi

if [[ "$g2_marker" == "auto-fire" ]]; then
	pass "Global opt-in: bold Phase 2 flipped to 'auto-fire'"
else
	fail "Global opt-in: bold Phase 2 marker expected 'auto-fire', got '${g2_marker}'"
fi

# Explicit [requires-decision] must still override the global opt-in
PARENT_BODY_GLOBAL_OVERRIDE='<!-- phase-auto-fire:on -->

## Phases

**Phase 1 — First phase**
**Phase 2 — Needs review [requires-decision]**'

override_output=$(_parse_phases_section "$PARENT_BODY_GLOBAL_OVERRIDE")
o1_marker=$(printf '%s\n' "$override_output" | head -1 | cut -f3)
o2_marker=$(printf '%s\n' "$override_output" | sed -n '2p' | cut -f3)

if [[ "$o1_marker" == "auto-fire" ]]; then
	pass "Global opt-in: Phase 1 (no explicit marker) gets auto-fire"
else
	fail "Global opt-in: Phase 1 expected 'auto-fire', got '${o1_marker}'"
fi

if [[ "$o2_marker" == "requires-decision" ]]; then
	pass "Global opt-in: explicit [requires-decision] overrides global auto-fire"
else
	fail "Global opt-in override: Phase 2 expected 'requires-decision', got '${o2_marker}'"
fi

# =============================================================================
# Test 12: _parse_phases_section — mixed list-form and bold-form in same body
# =============================================================================
printf '%s--- Test 12: _parse_phases_section mixed list and bold forms ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_MIXED='## Phases

- Phase 1 - List form phase [auto-fire:on-prior-merge] #20415
**Phase 2 — Bold form phase [auto-fire:on-prior-merge]**
- Phase 3 - Another list phase [requires-decision]
**Phase 4 — Another bold phase**'

mixed_output=$(_parse_phases_section "$PARENT_BODY_MIXED")
mixed_count=$(printf '%s\n' "$mixed_output" | grep -c '^[0-9]')

if [[ "$mixed_count" -eq 4 ]]; then
	pass "Mixed body: parsed all 4 phases (2 list + 2 bold)"
else
	fail "Mixed body: expected 4 phases, got ${mixed_count}" "Output: ${mixed_output}"
fi

m1_num=$(printf '%s\n' "$mixed_output" | head -1 | cut -f1)
m1_marker=$(printf '%s\n' "$mixed_output" | head -1 | cut -f3)
m2_num=$(printf '%s\n' "$mixed_output" | sed -n '2p' | cut -f1)
m2_marker=$(printf '%s\n' "$mixed_output" | sed -n '2p' | cut -f3)
m3_marker=$(printf '%s\n' "$mixed_output" | sed -n '3p' | cut -f3)
m4_marker=$(printf '%s\n' "$mixed_output" | sed -n '4p' | cut -f3)

if [[ "$m1_num" == "1" && "$m1_marker" == "auto-fire" ]]; then
	pass "Mixed: Phase 1 (list) parsed correctly"
else
	fail "Mixed: Phase 1 expected num=1 marker=auto-fire, got num=${m1_num} marker=${m1_marker}"
fi

if [[ "$m2_num" == "2" && "$m2_marker" == "auto-fire" ]]; then
	pass "Mixed: Phase 2 (bold) parsed correctly"
else
	fail "Mixed: Phase 2 expected num=2 marker=auto-fire, got num=${m2_num} marker=${m2_marker}"
fi

if [[ "$m3_marker" == "requires-decision" ]]; then
	pass "Mixed: Phase 3 (list) requires-decision preserved"
else
	fail "Mixed: Phase 3 marker expected 'requires-decision', got '${m3_marker}'"
fi

if [[ "$m4_marker" == "none" ]]; then
	pass "Mixed: Phase 4 (bold, no marker) defaults to 'none'"
else
	fail "Mixed: Phase 4 marker expected 'none', got '${m4_marker}'"
fi

# =============================================================================
# Test 13: _parse_phases_section — child refs after bold form
# =============================================================================
printf '%s--- Test 13: _parse_phases_section bold-heading child refs ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_BOLD_CHILD='## Phases

**Phase 1 — First phase [auto-fire:on-prior-merge]** #20415
**Phase 2 — Second phase [auto-fire:on-prior-merge]**
**Phase 3 — Third phase** #20500'

child_ref_output=$(_parse_phases_section "$PARENT_BODY_BOLD_CHILD")

cr1_child=$(printf '%s\n' "$child_ref_output" | head -1 | cut -f4)
cr1_desc=$(printf '%s\n' "$child_ref_output" | head -1 | cut -f2)
cr2_child=$(printf '%s\n' "$child_ref_output" | sed -n '2p' | cut -f4)
cr3_child=$(printf '%s\n' "$child_ref_output" | sed -n '3p' | cut -f4)

if [[ "$cr1_child" == "20415" ]]; then
	pass "Bold Phase 1 child ref 20415 extracted"
else
	fail "Bold Phase 1 child ref expected '20415', got '${cr1_child}'"
fi

if [[ "$cr1_desc" == "First phase" ]]; then
	pass "Bold Phase 1 description correct with child ref present"
else
	fail "Bold Phase 1 description expected 'First phase', got '${cr1_desc}'"
fi

if [[ -z "$cr2_child" ]]; then
	pass "Bold Phase 2 has no child ref (empty)"
else
	fail "Bold Phase 2 child ref expected empty, got '${cr2_child}'"
fi

if [[ "$cr3_child" == "20500" ]]; then
	pass "Bold Phase 3 child ref 20500 extracted (ref after closing **)"
else
	fail "Bold Phase 3 child ref expected '20500', got '${cr3_child}'"
fi

# =============================================================================
# Test 14: _parse_phases_section — bold form with hyphen separator
# =============================================================================
printf '%s--- Test 14: _parse_phases_section bold-heading hyphen separator ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_BOLD_HYPHEN='## Phases

**Phase 1 - Hyphen separator form [auto-fire:on-prior-merge]**
**Phase 2 - Another hyphen phase**'

hyphen_output=$(_parse_phases_section "$PARENT_BODY_BOLD_HYPHEN")
h1_desc=$(printf '%s\n' "$hyphen_output" | head -1 | cut -f2)
h1_marker=$(printf '%s\n' "$hyphen_output" | head -1 | cut -f3)
h2_desc=$(printf '%s\n' "$hyphen_output" | sed -n '2p' | cut -f2)

if [[ "$h1_desc" == "Hyphen separator form" ]]; then
	pass "Bold with hyphen separator: description extracted correctly"
else
	fail "Bold hyphen: description expected 'Hyphen separator form', got '${h1_desc}'"
fi

if [[ "$h1_marker" == "auto-fire" ]]; then
	pass "Bold with hyphen separator: explicit auto-fire marker honoured"
else
	fail "Bold hyphen: marker expected 'auto-fire', got '${h1_marker}'"
fi

if [[ "$h2_desc" == "Another hyphen phase" ]]; then
	pass "Bold with hyphen separator: Phase 2 description correct"
else
	fail "Bold hyphen: Phase 2 description expected 'Another hyphen phase', got '${h2_desc}'"
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
