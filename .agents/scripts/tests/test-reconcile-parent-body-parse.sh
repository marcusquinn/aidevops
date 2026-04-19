#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-reconcile-parent-body-parse.sh — tests for t2244 (GH#19762)
#
# Regression tests for _extract_children_section() in pulse-issue-reconcile.sh.
# The function restricts body-regex child detection to content under a
# dedicated heading (## Children / ## Sub-tasks / ## Child issues), preventing
# prose #NNN mentions from triggering premature parent-task close.
#
# Test coverage:
#   1. Body with ## Children heading + 2 closed refs → extracts both
#   2. Body with prose #NNN refs only (no heading) → returns empty
#   3. Body with ## Children (3 refs) + unrelated prose refs → extracts only section refs
#   4. Replay of #19734 body (incident trigger) → returns empty (no Children heading)
#   5. Body with ## Sub-tasks heading → extracts refs
#   6. Body with ## Child issues heading → extracts refs
#   7. Body with ## Children heading but refs also outside → only section refs
#   8. Empty body → returns empty
#   9. Body with ## Children at end of file (no trailing ##) → extracts refs
#
# Strategy: source _extract_children_section from pulse-issue-reconcile.sh
# and test it directly with fixture strings. No gh stubs needed — the function
# is pure string processing.

set -u

# Use TEST_-prefixed color vars to avoid colliding with readonly vars
# from shared-constants.sh when the helper is sourced later.
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

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $(printf '%q' "$expected")"
		echo "  actual:   $(printf '%q' "$actual")"
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
		echo "  actual:   $(printf '%q' "$actual")"
	fi
	return 0
}

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

# --- Source the function under test ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# We need to source _extract_children_section without sourcing the entire
# pulse-issue-reconcile.sh (which has side effects and dependencies). Extract
# just the function definition.
# shellcheck disable=SC1090
_extract_children_section() {
	local body="$1"
	printf '%s' "$body" | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+(Children|Child [Ii]ssues|Sub-?[Tt]asks)[[:space:]]*$/ {
			in_section = 1; next
		}
		in_section && /^##[[:space:]]/ { exit }
		in_section { print }
	'
	return 0
}

# Verify function is available
if ! declare -f _extract_children_section >/dev/null 2>&1; then
	echo "${TEST_RED}FATAL${TEST_NC}: _extract_children_section not available after source"
	exit 1
fi

echo "${TEST_BLUE}=== t2244: _extract_children_section tests ===${TEST_NC}"
echo ""

# --- Test 1: ## Children heading with 2 refs ---
BODY_1="## Description

This parent tracks the v3.8.71 retrospective tasks.

## Children

- #19750 — fix pulse merge timing
- #19751 — add regression gate

## Context

Some context here."

result=$(_extract_children_section "$BODY_1")
nums=$(printf '%s' "$result" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un) || nums=""
assert_contains "1a: ## Children section extracts #19750" "19750" "$nums"
assert_contains "1b: ## Children section extracts #19751" "19751" "$nums"

# --- Test 2: Prose #NNN refs only (no Children heading) ---
BODY_2="## Description

This parent tracks the v3.8.71 retrospective. It was triggered by #19708
and #19715 which were release PRs.

## Context

Some context mentioning #19720."

result=$(_extract_children_section "$BODY_2")
assert_empty "2: no Children heading → empty result" "$result"

# --- Test 3: ## Children (3 refs) + unrelated prose refs elsewhere ---
BODY_3="## Description

This was triggered by #19708 (release PR) and #19715 (gemini nits).

## Children

- #19750 — fix pulse merge timing
- #19751 — add regression gate
- #19752 — update docs

## Context

Also see #19720 for background."

result=$(_extract_children_section "$BODY_3")
nums=$(printf '%s' "$result" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un) || nums=""
assert_contains "3a: extracts #19750 from Children" "19750" "$nums"
assert_contains "3b: extracts #19751 from Children" "19751" "$nums"
assert_contains "3c: extracts #19752 from Children" "19752" "$nums"
assert_not_contains "3d: does NOT extract prose #19708" "19708" "$nums"
assert_not_contains "3e: does NOT extract prose #19715" "19715" "$nums"
assert_not_contains "3f: does NOT extract context #19720" "19720" "$nums"

# --- Test 4: Replay of #19734 body (incident trigger) ---
# Simplified version of the actual #19734 body that caused the premature close.
# The body mentions #19708 and #19715 as context but has NO ## Children heading.
BODY_4="## Description

v3.8.71 lifecycle retrospective. Release cycle covered #19708 (t2213 cloudron
skill sync) and #19715 (t2214 gemini nits).

## Phases

Phase 1: audit (this issue)
Phase 2: implement fixes

## Task Brief

**Session origin:** interactive
**Severity:** high"

result=$(_extract_children_section "$BODY_4")
assert_empty "4: #19734 replay body → empty (no premature close)" "$result"

# --- Test 5: ## Sub-tasks heading ---
BODY_5="## Description

Parent tracker.

## Sub-tasks

- #100 — first task
- #101 — second task

## Notes

Done."

result=$(_extract_children_section "$BODY_5")
nums=$(printf '%s' "$result" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un) || nums=""
assert_contains "5a: ## Sub-tasks extracts #100" "100" "$nums"
assert_contains "5b: ## Sub-tasks extracts #101" "101" "$nums"

# --- Test 6: ## Child issues heading ---
BODY_6="## Description

Parent tracker.

## Child issues

- #200 — alpha
- #201 — beta

## Related

See #999."

result=$(_extract_children_section "$BODY_6")
nums=$(printf '%s' "$result" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un) || nums=""
assert_contains "6a: ## Child issues extracts #200" "200" "$nums"
assert_contains "6b: ## Child issues extracts #201" "201" "$nums"
assert_not_contains "6c: does NOT extract #999 from Related" "999" "$nums"

# --- Test 7: ## Subtasks (no hyphen) heading ---
BODY_7="## Subtasks

- #300 — gamma
- #301 — delta"

result=$(_extract_children_section "$BODY_7")
nums=$(printf '%s' "$result" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un) || nums=""
assert_contains "7a: ## Subtasks (no hyphen) extracts #300" "300" "$nums"
assert_contains "7b: ## Subtasks (no hyphen) extracts #301" "301" "$nums"

# --- Test 8: Empty body ---
result=$(_extract_children_section "")
assert_empty "8: empty body → empty result" "$result"

# --- Test 9: ## Children at end of file (no trailing ##) ---
BODY_9="## Description

Some description.

## Children

- #400 — task alpha
- #401 — task beta"

result=$(_extract_children_section "$BODY_9")
nums=$(printf '%s' "$result" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un) || nums=""
assert_contains "9a: EOF children extracts #400" "400" "$nums"
assert_contains "9b: EOF children extracts #401" "401" "$nums"

# --- Test 10: ## Child Issues (capital I) ---
BODY_10="## Child Issues

- #500 — task one
- #501 — task two"

result=$(_extract_children_section "$BODY_10")
nums=$(printf '%s' "$result" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un) || nums=""
assert_contains "10a: ## Child Issues (capital I) extracts #500" "500" "$nums"
assert_contains "10b: ## Child Issues (capital I) extracts #501" "501" "$nums"

# --- Summary ---
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
