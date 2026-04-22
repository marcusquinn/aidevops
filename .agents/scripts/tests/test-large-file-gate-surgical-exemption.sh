#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-large-file-gate-surgical-exemption.sh — t2713 regression guard.
#
# Verifies that `_large_file_gate_check_surgical_brief()` in
# pulse-dispatch-large-file-gate.sh correctly exempts the large-file gate
# when every large file cited in an issue has an explicit line-range
# reference in the linked task brief.
#
# Background: the gate blocks dispatch on any issue that references a file
# exceeding 2000 lines, assuming workers will spend their context budget
# reading the whole file. This assumption is wrong for surgical edits with
# explicit line ranges. The brief already carries the signal (line ranges);
# the gate now reads it via _large_file_gate_check_surgical_brief().
#
# Canonical trigger: GH#20341 (t2706) — a 25-line fix across two functions
# in auto-update-helper.sh (2251 lines) was held behind a full file-split
# PR cycle because the gate couldn't tell surgical from holistic.
#
# Tests:
#   1. Full coverage: task ID + brief exists + all paths have line-range refs
#      → EXEMPTED (returns 0), _LFG_SURGICAL_EXEMPTED_FILES populated
#   2. Partial coverage: brief exists + one path has no line-range ref
#      → gate applied (returns 1)
#   3. No brief: task ID found + brief file missing
#      → gate applied (returns 1)
#   4. Brief exists but no line-range signals for any file
#      → gate applied (returns 1)
#   5. No task ID in title: title not in tNNN: format
#      → gate applied (returns 1)
#   6. Canonical t2706 brief: using the actual todo/tasks/t2706-brief.md
#      → EXEMPTED for auto-update-helper.sh (pattern a: basename:NNN-NNN)
#   7. Log format: source file contains the exact log string from the spec
#      → structural check (no live pulse needed)
#
# Cross-references: GH#20371 / t2713, GH#20341 / t2706 (canonical trigger),
# GH#20343 (child split issue this exemption makes unnecessary).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
GATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

# ---- shared assert helpers -----------------------------------------------

assert_rc() {
	local test_name="$1"
	local expected_rc="$2"
	local actual_rc="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected rc=%s, got rc=%s\n' "$expected_rc" "$actual_rc"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_contains() {
	local test_name="$1"
	local haystack="$2"
	local needle="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       missing: %s\n' "$needle"
	printf '       in:      %s\n' "$haystack"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_empty() {
	local test_name="$1"
	local actual="$2"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -z "$actual" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected empty, got: %s\n' "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# ---- load the gate module ------------------------------------------------

# LOGFILE, LARGE_FILE_LINE_THRESHOLD, and SCOPED_RANGE_THRESHOLD are used
# by siblings of _large_file_gate_check_surgical_brief; set safe defaults
# so the module sources cleanly.
LOGFILE="/dev/null"
export LOGFILE
LARGE_FILE_LINE_THRESHOLD="${LARGE_FILE_LINE_THRESHOLD:-2000}"
export LARGE_FILE_LINE_THRESHOLD
SCOPED_RANGE_THRESHOLD="${SCOPED_RANGE_THRESHOLD:-200}"
export SCOPED_RANGE_THRESHOLD

# shellcheck source=/dev/null
source "$GATE_SCRIPT"

# ---- temp workspace ------------------------------------------------------

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t 'lfg_test')"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: create a temp repo dir containing todo/tasks/<task_id>-brief.md
setup_test_repo() {
	local task_id="$1"
	local brief_content="$2"
	local repo_dir="${TMPDIR_BASE}/${task_id}-repo"
	mkdir -p "${repo_dir}/todo/tasks"
	printf '%s\n' "$brief_content" >"${repo_dir}/todo/tasks/${task_id}-brief.md"
	printf '%s' "$repo_dir"
}

# =========================================================================
printf '\n=== test-large-file-gate-surgical-exemption.sh (t2713) ===\n\n'

# =========================================================================
# Test 1: Full coverage — task ID + brief + all paths have line-range refs
#         → EXEMPTED (function returns 0), _LFG_SURGICAL_EXEMPTED_FILES set
# =========================================================================
BRIEF_FULL=$(cat <<'EOF'
# t9999: example brief

## Relevant Files

- `big-file.sh:500-600` — the main function we are editing
- `another-file.sh:100-200` — helper used by the main function

## How

EDIT: .agents/scripts/big-file.sh
EDIT: .agents/scripts/another-file.sh
EOF
)
REPO1=$(setup_test_repo "t9999" "$BRIEF_FULL")

PATHS_FULL=$'agents/scripts/big-file.sh\nagents/scripts/another-file.sh'
EXEMPT_RC=99
_large_file_gate_check_surgical_brief \
	"t9999: example fix for the large file" \
	"$PATHS_FULL" \
	"$REPO1" && EXEMPT_RC=0 || EXEMPT_RC=$?

assert_rc \
	"full coverage → function returns 0 (exemption applies)" \
	0 "$EXEMPT_RC"

assert_contains \
	"full coverage → _LFG_SURGICAL_EXEMPTED_FILES contains big-file.sh" \
	"$_LFG_SURGICAL_EXEMPTED_FILES" \
	"big-file.sh"

assert_contains \
	"full coverage → _LFG_SURGICAL_EXEMPTED_FILES contains another-file.sh" \
	"$_LFG_SURGICAL_EXEMPTED_FILES" \
	"another-file.sh"

# =========================================================================
# Test 2: Partial coverage — one path has no line-range ref → gate applied
# =========================================================================
BRIEF_PARTIAL=$(cat <<'EOF'
# t8888: partial brief

## Relevant Files

- `big-file.sh:500-600` — has line range

## How

EDIT: .agents/scripts/big-file.sh
EDIT: .agents/scripts/uncovered-file.sh
EOF
)
REPO2=$(setup_test_repo "t8888" "$BRIEF_PARTIAL")

PATHS_PARTIAL=$'agents/scripts/big-file.sh\nagents/scripts/uncovered-file.sh'
PARTIAL_RC=99
_large_file_gate_check_surgical_brief \
	"t8888: partial brief example" \
	"$PATHS_PARTIAL" \
	"$REPO2" && PARTIAL_RC=0 || PARTIAL_RC=$?

assert_rc \
	"partial coverage → function returns 1 (gate applied)" \
	1 "$PARTIAL_RC"

assert_empty \
	"partial coverage → _LFG_SURGICAL_EXEMPTED_FILES is empty" \
	"$_LFG_SURGICAL_EXEMPTED_FILES"

# =========================================================================
# Test 3: No brief file — brief path does not exist → gate applied
# =========================================================================
REPO3="${TMPDIR_BASE}/no-brief-repo"
mkdir -p "${REPO3}/todo/tasks"
# Deliberately do NOT create a brief for t7777

PATHS_SIMPLE='agents/scripts/big-file.sh'
NOBRIRF_RC=99
_large_file_gate_check_surgical_brief \
	"t7777: task with no brief" \
	"$PATHS_SIMPLE" \
	"$REPO3" && NOBRIRF_RC=0 || NOBRIRF_RC=$?

assert_rc \
	"missing brief → function returns 1 (gate applied)" \
	1 "$NOBRIRF_RC"

# =========================================================================
# Test 4: Brief exists but contains no line-range signals → gate applied
# =========================================================================
BRIEF_NO_RANGES=$(cat <<'EOF'
# t6666: brief without ranges

## How

Edit big-file.sh to fix the bug. Look at the function near the top.
The file is referenced but without any line numbers.

EDIT: .agents/scripts/big-file.sh
EOF
)
REPO4=$(setup_test_repo "t6666" "$BRIEF_NO_RANGES")

PATHS_NORANGE='agents/scripts/big-file.sh'
NORANGE_RC=99
_large_file_gate_check_surgical_brief \
	"t6666: task with no ranges in brief" \
	"$PATHS_NORANGE" \
	"$REPO4" && NORANGE_RC=0 || NORANGE_RC=$?

assert_rc \
	"brief with no line ranges → function returns 1 (gate applied)" \
	1 "$NORANGE_RC"

# =========================================================================
# Test 5: No task ID in issue title → gate applied (first guard short-circuits)
# =========================================================================
REPO5=$(setup_test_repo "t5555" "$BRIEF_FULL")

PATHS_NOTASKID='agents/scripts/big-file.sh'
NOTASKID_RC=99
_large_file_gate_check_surgical_brief \
	"This title has no recognised task ID format" \
	"$PATHS_NOTASKID" \
	"$REPO5" && NOTASKID_RC=0 || NOTASKID_RC=$?

assert_rc \
	"no task ID in title → function returns 1 (gate applied)" \
	1 "$NOTASKID_RC"

# =========================================================================
# Test 6: Canonical t2706 brief — auto-update-helper.sh:1320-1345 present
#         Uses the actual brief from the repo to verify the canonical case.
#         Simulates the GH#20341 triggering path that motivated this issue.
# =========================================================================
T2706_BRIEF="${REPO_ROOT}/todo/tasks/t2706-brief.md"
if [[ -f "$T2706_BRIEF" ]]; then
	# The brief contains `auto-update-helper.sh:1320-1345` (pattern a) and
	# `aidevops.sh:540-580` (pattern a) — both should be covered.
	# For the gate check, we test with just auto-update-helper.sh since
	# that is the file that triggered needs-simplification on GH#20341.
	PATHS_T2706='agents/scripts/auto-update-helper.sh'
	T2706_RC=99
	_large_file_gate_check_surgical_brief \
		"t2706: redeploy on .deployed-sha drift, not just VERSION/sentinel" \
		"$PATHS_T2706" \
		"$REPO_ROOT" && T2706_RC=0 || T2706_RC=$?

	assert_rc \
		"canonical t2706 brief: auto-update-helper.sh → EXEMPTED (rc=0)" \
		0 "$T2706_RC"

	assert_contains \
		"canonical t2706 brief: exempted files contains auto-update-helper.sh" \
		"$_LFG_SURGICAL_EXEMPTED_FILES" \
		"auto-update-helper.sh"
else
	printf '  SKIP  canonical t2706 brief test (todo/tasks/t2706-brief.md not found)\n'
fi

# =========================================================================
# Test 7: Log format — structural check that the source file contains the
#         exact log string specified in the issue (GH#20371).
# =========================================================================
LOG_NEEDLE='Large-file gate EXEMPTED for #'
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qF "$LOG_NEEDLE" "$GATE_SCRIPT" 2>/dev/null; then
	printf '  %sPASS%s log format: source contains expected log prefix\n' "$TEST_GREEN" "$TEST_NC"
else
	printf '  %sFAIL%s log format: source missing expected log prefix\n' "$TEST_RED" "$TEST_NC"
	printf '       missing: %s\n' "$LOG_NEEDLE"
	TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ---- summary -------------------------------------------------------------

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
