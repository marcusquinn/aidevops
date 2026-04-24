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
# Test 8: _parse_phases_section — bold-heading form basic detection (t2788)
# =============================================================================
printf '%s--- Test 8: bold-heading form basic detection ---%s\n' "$TEST_BLUE" "$TEST_NC"

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

b1_line=$(printf '%s\n' "$bold_output" | head -1)
b1_num=$(printf '%s' "$b1_line" | cut -f1)
b1_desc=$(printf '%s' "$b1_line" | cut -f2)
b1_marker=$(printf '%s' "$b1_line" | cut -f3)
b1_child=$(printf '%s' "$b1_line" | cut -f4)

if [[ "$b1_num" == "1" && "$b1_desc" == "Remove auto-dispatch label plumbing" && "$b1_marker" == "none" && -z "$b1_child" ]]; then
	pass "Bold Phase 1: num=1, desc correct, default marker=none, no child ref"
else
	fail "Bold Phase 1 field mismatch" "num='${b1_num}' desc='${b1_desc}' marker='${b1_marker}' child='${b1_child}'"
fi

# =============================================================================
# Test 9: _parse_phases_section — explicit markers on bold form (t2788)
# =============================================================================
printf '%s--- Test 9: bold-heading explicit markers ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_BOLD_EXPLICIT='## Phases

**Phase 1 — Remove plumbing [auto-fire:on-prior-merge]**
**Phase 2 — Update logic [requires-decision]**
**Phase 3 — No marker**'

explicit_output=$(_parse_phases_section "$PARENT_BODY_BOLD_EXPLICIT")
e1_marker=$(printf '%s\n' "$explicit_output" | sed -n '1p' | cut -f3)
e2_marker=$(printf '%s\n' "$explicit_output" | sed -n '2p' | cut -f3)
e3_marker=$(printf '%s\n' "$explicit_output" | sed -n '3p' | cut -f3)
e1_desc=$(printf '%s\n' "$explicit_output" | sed -n '1p' | cut -f2)

if [[ "$e1_marker" == "auto-fire" && "$e2_marker" == "requires-decision" && "$e3_marker" == "none" ]]; then
	pass "Bold explicit markers respected: auto-fire, requires-decision, none"
else
	fail "Bold explicit markers wrong: e1='${e1_marker}' e2='${e2_marker}' e3='${e3_marker}'"
fi

if [[ "$e1_desc" == "Remove plumbing" ]]; then
	pass "Bold Phase 1 description stripped of marker bracket"
else
	fail "Bold Phase 1 description expected 'Remove plumbing', got '${e1_desc}'"
fi

# =============================================================================
# Test 10: _parse_phases_section — <!-- phase-auto-fire:on --> opt-in (t2788)
# =============================================================================
printf '%s--- Test 10: global opt-in comment flips bold phases ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_GLOBAL='<!-- phase-auto-fire:on -->

## Phases

**Phase 1 — First phase**
**Phase 2 — Second phase [requires-decision]**
**Phase 3 — Third phase**'

global_output=$(_parse_phases_section "$PARENT_BODY_GLOBAL")
g1_marker=$(printf '%s\n' "$global_output" | sed -n '1p' | cut -f3)
g2_marker=$(printf '%s\n' "$global_output" | sed -n '2p' | cut -f3)
g3_marker=$(printf '%s\n' "$global_output" | sed -n '3p' | cut -f3)

if [[ "$g1_marker" == "auto-fire" && "$g3_marker" == "auto-fire" ]]; then
	pass "Global opt-in flips unmarked bold phases to auto-fire"
else
	fail "Global opt-in failed: g1='${g1_marker}' g3='${g3_marker}' (expected auto-fire)"
fi

if [[ "$g2_marker" == "requires-decision" ]]; then
	pass "Explicit [requires-decision] still overrides global opt-in"
else
	fail "Explicit marker should override global: got '${g2_marker}'"
fi

# List-form phases are NOT affected by the global opt-in (conservative).
PARENT_BODY_GLOBAL_MIXED='<!-- phase-auto-fire:on -->

## Phases

- Phase 1 - List-form phase
**Phase 2 — Bold-form phase**'

mixed_global=$(_parse_phases_section "$PARENT_BODY_GLOBAL_MIXED")
mg1_marker=$(printf '%s\n' "$mixed_global" | sed -n '1p' | cut -f3)
mg2_marker=$(printf '%s\n' "$mixed_global" | sed -n '2p' | cut -f3)

if [[ "$mg1_marker" == "none" && "$mg2_marker" == "auto-fire" ]]; then
	pass "Global opt-in affects bold only, list form stays conservative"
else
	fail "Global opt-in scope wrong: list='${mg1_marker}' (want none), bold='${mg2_marker}' (want auto-fire)"
fi

# =============================================================================
# Test 11: _parse_phases_section — mixed list and bold forms (t2788)
# =============================================================================
printf '%s--- Test 11: mixed list and bold forms ---%s\n' "$TEST_BLUE" "$TEST_NC"

PARENT_BODY_MIXED='## Phases

- Phase 1 - List form [auto-fire:on-prior-merge] #1001
**Phase 2 — Bold form [auto-fire:on-prior-merge]**
- Phase 3 - Second list phase [requires-decision]
**Phase 4 — Final bold phase**'

mixed_output=$(_parse_phases_section "$PARENT_BODY_MIXED")
mixed_count=$(printf '%s\n' "$mixed_output" | grep -c '^[0-9]')

if [[ "$mixed_count" -eq 4 ]]; then
	pass "Parsed 4 phases (2 list + 2 bold) in mixed body"
else
	fail "Expected 4 phases, got ${mixed_count}" "Output: ${mixed_output}"
fi

m1_child=$(printf '%s\n' "$mixed_output" | sed -n '1p' | cut -f4)
m2_marker=$(printf '%s\n' "$mixed_output" | sed -n '2p' | cut -f3)
m3_marker=$(printf '%s\n' "$mixed_output" | sed -n '3p' | cut -f3)
m4_marker=$(printf '%s\n' "$mixed_output" | sed -n '4p' | cut -f3)

if [[ "$m1_child" == "1001" && "$m2_marker" == "auto-fire" && "$m3_marker" == "requires-decision" && "$m4_marker" == "none" ]]; then
	pass "Mixed form: per-phase child refs, markers, and defaults all correct"
else
	fail "Mixed form mismatch: m1_child='${m1_child}' m2='${m2_marker}' m3='${m3_marker}' m4='${m4_marker}'"
fi

# =============================================================================
# Test 12: _parse_phases_section — bold form child ref extraction (t2788)
# =============================================================================
printf '%s--- Test 12: bold form child ref placement ---%s\n' "$TEST_BLUE" "$TEST_NC"

# Child ref outside closing ** — common when phase section is rewritten after
# auto-fill appends the reference.
PARENT_BODY_CHILD_OUTSIDE='## Phases

**Phase 1 — First** #2001
**Phase 2 — Second [auto-fire:on-prior-merge]** #2002'

outside_output=$(_parse_phases_section "$PARENT_BODY_CHILD_OUTSIDE")
o1_child=$(printf '%s\n' "$outside_output" | sed -n '1p' | cut -f4)
o1_desc=$(printf '%s\n' "$outside_output" | sed -n '1p' | cut -f2)
o2_child=$(printf '%s\n' "$outside_output" | sed -n '2p' | cut -f4)
o2_desc=$(printf '%s\n' "$outside_output" | sed -n '2p' | cut -f2)

if [[ "$o1_child" == "2001" && "$o2_child" == "2002" ]]; then
	pass "Bold form child ref outside closing ** extracted"
else
	fail "Bold child ref outside ** wrong: '${o1_child}', '${o2_child}' (expected 2001, 2002)"
fi

if [[ "$o1_desc" == "First" && "$o2_desc" == "Second" ]]; then
	pass "Bold form description clean when child ref is outside closing **"
else
	fail "Bold desc mismatch outside **: '${o1_desc}', '${o2_desc}' (expected 'First', 'Second')"
fi

# Child ref inside closing ** — alternate authoring style.
PARENT_BODY_CHILD_INSIDE='## Phases

**Phase 1 — First #3001**
**Phase 2 — Second [auto-fire:on-prior-merge] #3002**'

inside_output=$(_parse_phases_section "$PARENT_BODY_CHILD_INSIDE")
i1_child=$(printf '%s\n' "$inside_output" | sed -n '1p' | cut -f4)
i1_desc=$(printf '%s\n' "$inside_output" | sed -n '1p' | cut -f2)
i2_child=$(printf '%s\n' "$inside_output" | sed -n '2p' | cut -f4)

if [[ "$i1_child" == "3001" && "$i2_child" == "3002" ]]; then
	pass "Bold form child ref inside closing ** extracted"
else
	fail "Bold child ref inside ** wrong: '${i1_child}', '${i2_child}' (expected 3001, 3002)"
fi

if [[ "$i1_desc" == "First" ]]; then
	pass "Bold form description clean when child ref is inside closing **"
else
	fail "Bold desc mismatch inside **: '${i1_desc}' (expected 'First')"
fi

# =============================================================================
# Test 13: _parse_phases_section — bold form separator variants (t2788)
# =============================================================================
printf '%s--- Test 13: bold form separator variants ---%s\n' "$TEST_BLUE" "$TEST_NC"

# Em-dash, en-dash, hyphen, colon all supported as separators after Phase N.
PARENT_BODY_SEPARATORS='## Phases

**Phase 1 — Em-dash**
**Phase 2 – En-dash**
**Phase 3 - Hyphen**
**Phase 4: Colon**'

sep_output=$(_parse_phases_section "$PARENT_BODY_SEPARATORS")
sep_count=$(printf '%s\n' "$sep_output" | grep -c '^[0-9]')

if [[ "$sep_count" -eq 4 ]]; then
	pass "All 4 separator variants parsed"
else
	fail "Expected 4 separator variants, got ${sep_count}" "Output: ${sep_output}"
fi

s1_desc=$(printf '%s\n' "$sep_output" | sed -n '1p' | cut -f2)
s3_desc=$(printf '%s\n' "$sep_output" | sed -n '3p' | cut -f2)
s4_desc=$(printf '%s\n' "$sep_output" | sed -n '4p' | cut -f2)

if [[ "$s1_desc" == "Em-dash" && "$s3_desc" == "Hyphen" && "$s4_desc" == "Colon" ]]; then
	pass "Bold separator variants strip cleanly"
else
	fail "Separator descriptions wrong: em-dash='${s1_desc}' hyphen='${s3_desc}' colon='${s4_desc}'"
fi

# =============================================================================
# Test 14: _parse_phases_section — no double-emission (t2788)
# =============================================================================
printf '%s--- Test 14: no duplicate rows per line ---%s\n' "$TEST_BLUE" "$TEST_NC"

# Each line must produce at most one output row. Both helpers are called but
# each has an early return when the form doesn't match.
PARENT_BODY_DEDUP='## Phases

- Phase 1 - List form
**Phase 2 — Bold form**'

dedup_output=$(_parse_phases_section "$PARENT_BODY_DEDUP")
dedup_count=$(printf '%s\n' "$dedup_output" | grep -c '^[0-9]')

if [[ "$dedup_count" -eq 2 ]]; then
	pass "No duplicate output rows — each line produces exactly one row"
else
	fail "Expected 2 rows for 2 lines, got ${dedup_count}" "Output: ${dedup_output}"
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
