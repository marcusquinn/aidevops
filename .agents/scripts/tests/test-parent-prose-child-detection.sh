#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex/grep patterns are literal by design
#
# test-parent-prose-child-detection.sh — tests for t2442 Fix #3
#
# Regression tests for _extract_children_from_prose() in pulse-issue-reconcile.sh.
# The function is called as a THIRD fallback after the GraphQL sub-issue graph
# and the ## Children heading extraction both come back empty. It matches
# FOUR narrow prose patterns only:
#
#   1. "Phase N <anything> #NNNN"   — e.g. "Phase 1 split out as #19996"
#   2. "filed as #NNNN"              — e.g. "Phase 2 was filed as #20001"
#   3. "tracks #NNNN"                 — e.g. "tracks #19808 and #19858"
#   4. "[Bb]locked by:? #NNNN"        — e.g. "Blocked by: #42"
#
# CRITICAL constraint (t2244 memory lesson — CodeRabbit review of PR #19810):
# we MUST NOT match bare `#NNN` mentions like "triggered by #19708", "see
# #42", "cf. #12345". That would re-introduce the #19734 incident where
# prose context refs were mistaken for children and closed parents
# prematurely. Tests 5-9 cover these negative cases.
#
# Strategy: source the function body directly (it's pure string processing
# with no dependencies) and test with fixture strings.

set -u

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

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to contain: $needle"
		echo "  actual: $(printf '%q' "$haystack")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected NOT to contain: $needle"
		echo "  actual: $(printf '%q' "$haystack")"
	fi
	return 0
}

assert_empty() {
	local label="$1" actual="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -z "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: (empty)"
		echo "  actual: $(printf '%q' "$actual")"
	fi
	return 0
}

# --- Function under test (byte-for-byte mirror of pulse-issue-reconcile.sh) ---
# If the source helper drifts, CI integration tests will catch it via the
# live reconciler path. Keeping the test self-contained avoids needing
# side-effectful sourcing.

_extract_children_from_prose() {
	local body="$1"
	[[ -n "$body" ]] || return 0

	local patterns=(
		'([Pp]hase[[:space:]]+[0-9]+[^#]*#[0-9]+)'
		'([Ff]iled[[:space:]]+as[[:space:]]*#[0-9]+)'
		'([Tt]racks[[:space:]]+#[0-9]+)'
		'([Bb]locked[[:space:]]-?[[:space:]]*by[[:space:]]*:?[[:space:]]*#[0-9]+)'
	)

	local all_matches=""
	local pat
	for pat in "${patterns[@]}"; do
		local hits
		hits=$(printf '%s' "$body" | grep -oE "$pat" 2>/dev/null || true)
		[[ -n "$hits" ]] || continue
		all_matches="${all_matches}${hits}"$'\n'
	done

	[[ -n "$all_matches" ]] || return 0
	printf '%s' "$all_matches" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un
	return 0
}

if ! declare -f _extract_children_from_prose >/dev/null 2>&1; then
	echo "${TEST_RED}FATAL${TEST_NC}: _extract_children_from_prose not available"
	exit 1
fi

echo "${TEST_BLUE}=== t2442 Fix #3: _extract_children_from_prose tests ===${TEST_NC}"
echo ""

# ------- Positive cases (each of the 4 narrow patterns) -------

# 1. "Phase N ... #NNNN"
BODY_1="## Decomposition

Phase 1 split out as #19996 (merged). Phase 2 pending."
result=$(_extract_children_from_prose "$BODY_1")
assert_contains "1: Phase N ... #NNNN extracts #19996" "19996" "$result"

# 2. "filed as #NNNN"
BODY_2="## Status

Phase 1 was filed as #19996. Phase 2 was filed as #20001."
result=$(_extract_children_from_prose "$BODY_2")
assert_contains "2a: 'filed as' extracts #19996" "19996" "$result"
assert_contains "2b: 'filed as' extracts #20001" "20001" "$result"

# 3. "tracks #NNNN"
BODY_3="This epic tracks #19808 and also tracks #19858."
result=$(_extract_children_from_prose "$BODY_3")
assert_contains "3a: 'tracks' extracts #19808" "19808" "$result"
assert_contains "3b: 'tracks' extracts #19858" "19858" "$result"

# 4. "Blocked by: #NNNN"
BODY_4="Blocked by: #42
Also blocked by #43."
result=$(_extract_children_from_prose "$BODY_4")
assert_contains "4a: 'Blocked by:' extracts #42" "42" "$result"
assert_contains "4b: 'blocked by' (no colon) extracts #43" "43" "$result"

# ------- Negative cases (MUST NOT match bare prose #NNN) -------
# These guard against re-introducing the #19734 incident where bare
# prose mentions were mistaken for children.

# 5. "triggered by #NNN" — no match
BODY_5="This issue was triggered by #19708 and relates to #19715."
result=$(_extract_children_from_prose "$BODY_5")
assert_empty "5: bare 'triggered by #N' does NOT match" "$result"

# 6. "see #NNN" / "cf. #NNN" — no match
BODY_6="For context see #12345 and cf. #54321 for prior art."
result=$(_extract_children_from_prose "$BODY_6")
assert_empty "6: bare 'see #N' / 'cf. #N' does NOT match" "$result"

# 7. Closing keywords ("closes #N", "resolves #N") — no match (that's a
#    GitHub closing keyword, not a child declaration)
BODY_7="closes #17 resolves #18 fixes #19"
result=$(_extract_children_from_prose "$BODY_7")
assert_empty "7: closing keywords do NOT match as children" "$result"

# 8. Empty body → empty result
result=$(_extract_children_from_prose "")
assert_empty "8: empty body returns empty" "$result"

# 9. t2244 incident replay — #19734 body shape (prose refs only, no markers)
BODY_9="## Description

v3.8.71 lifecycle retrospective. Release cycle covered #19708 (t2213
cloudron skill sync) and #19715 (t2214 gemini nits).

## Phases

Phase 1: audit (this issue)
Phase 2: implement fixes"
# Note: "Phase 1:" / "Phase 2:" don't match because the pattern requires
# a `#NNNN` trailing the phase word within the same match window.
result=$(_extract_children_from_prose "$BODY_9")
assert_empty "9: #19734 replay body (no declarative children) → empty" "$result"

# ------- Mixed cases -------

# 10. Prose refs + declarative refs → only declarative match
BODY_10="Triggered by #100 (see also #101). The work was filed as #200.
This also tracks #201."
result=$(_extract_children_from_prose "$BODY_10")
assert_contains "10a: 'filed as #200' extracted" "200" "$result"
assert_contains "10b: 'tracks #201' extracted" "201" "$result"
assert_not_contains "10c: 'triggered by #100' NOT extracted" "100" "$result"
assert_not_contains "10d: 'see also #101' NOT extracted" "101" "$result"

# 11. Dedup — same issue matched multiple ways → appears once
BODY_11="Phase 1 #500. Also filed as #500. And tracks #500."
result=$(_extract_children_from_prose "$BODY_11")
count=$(printf '%s' "$result" | grep -c '^500$' || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$count" == "1" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 11: duplicate matches deduplicated"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 11: duplicate matches deduplicated"
	echo "  expected count=1, got count=$count"
fi

# --- Source wiring assertion — the helper is actually called in reconcile ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$SCRIPT_DIR/pulse-issue-reconcile.sh"

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qF '_extract_children_from_prose' "$TARGET" 2>/dev/null &&
	grep -qE 'prose_children=\$\(_extract_children_from_prose' "$TARGET" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 12: _extract_children_from_prose wired in reconcile_completed_parent_tasks"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 12: _extract_children_from_prose NOT wired in reconcile_completed_parent_tasks"
fi

# --- Summary ---
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
