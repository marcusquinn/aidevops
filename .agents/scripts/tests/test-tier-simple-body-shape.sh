#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC1090  # dynamic source of helper under test is intentional
# shellcheck disable=SC2016  # single-quoted fixture bodies are heredoc-like literals
#
# test-tier-simple-body-shape.sh — fixture tests for t2389 (GH#19929)
#
# Exercises the 4 _check_* disqualifier functions in
# tier-simple-body-shape-helper.sh with pass + fail fixtures for each.
#
# Strategy: source the helper's check functions into a subshell (the
# helper has a `if [[ BASH_SOURCE == $0 ]]; then main; fi` guard so
# sourcing doesn't execute main), then call each _check_* function
# directly with fixture body strings. No gh/jq stubs needed — these
# functions are pure string processing.
#
# The cmd_check orchestrator and _apply_downgrade (which make gh API
# calls) are NOT tested here — they are exercised live on the first
# dispatch of a disqualified tier:simple issue. A structural test
# verifies the wiring is in place.
#
# Test coverage:
#   1a. _check_file_count: pass on 2-file brief
#   1b. _check_file_count: fail on 3-file brief (NEW:/EDIT: markers)
#   1c. _check_file_count: fail on 4-file brief (inline paths)
#   2a. _check_estimate: pass on ~30m
#   2b. _check_estimate: pass on ~1h
#   2c. _check_estimate: fail on ~2h
#   2d. _check_estimate: fail on ~1d
#   3a. _check_acceptance_count: pass on 3 checkboxes
#   3b. _check_acceptance_count: fail on 5 checkboxes
#   3c. _check_acceptance_count: does NOT count checkboxes outside Acceptance section
#   4a. _check_judgment_keywords: pass on clean brief
#   4b. _check_judgment_keywords: fail on "fallback" keyword
#   4c. _check_judgment_keywords: fail on "design the" phrase
#   4d. _check_judgment_keywords: does NOT flag keyword in tier checklist section
#   4e. _check_judgment_keywords: does NOT flag keyword in signature footer
#   5.  cmd_help prints usage
#   6.  Structural: cmd_check handler exists

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

assert_pass() {
	local label="$1" fn="$2" body="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	DISQUALIFIER_REASON=""
	DISQUALIFIER_EVIDENCE=""
	local rc=0
	"$fn" "$body" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: pass (rc=0)"
		echo "  actual:   rc=${rc}, reason=${DISQUALIFIER_REASON}"
	fi
	return 0
}

assert_fail() {
	local label="$1" fn="$2" body="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	DISQUALIFIER_REASON=""
	DISQUALIFIER_EVIDENCE=""
	local rc=0
	"$fn" "$body" || rc=$?
	if [[ "$rc" -eq 10 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label (reason: ${DISQUALIFIER_REASON})"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: fail (rc=10)"
		echo "  actual:   rc=${rc}"
	fi
	return 0
}

# --- Source the helper ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPT_DIR/tier-simple-body-shape-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $HELPER not found"
	exit 1
fi

# The helper uses `if [[ BASH_SOURCE == $0 ]]; then main; fi` so we can
# source safely without triggering main execution. Disable strict set -e
# during source since shared-constants.sh may have lenient expectations.
# shellcheck source=/dev/null
set +e
source "$HELPER"
set -e

# Sanity check the functions we expect are available
for fn in _check_file_count _check_estimate _check_acceptance_count _check_judgment_keywords cmd_check cmd_help; do
	if ! declare -f "$fn" >/dev/null 2>&1; then
		echo "${TEST_RED}FATAL${TEST_NC}: function $fn not available after source"
		exit 1
	fi
done

echo "${TEST_BLUE}=== t2389: tier-simple-body-shape-helper disqualifier tests ===${TEST_NC}"
echo ""

# -----------------------------------------------------------------------
# Disqualifier 1: file count
# -----------------------------------------------------------------------

BODY_1A='## How

### Files to modify

- NEW: `.agents/scripts/foo.sh` — helper
- EDIT: `.agents/scripts/bar.sh:45-60` — wire it in'

assert_pass "1a: 2-file brief passes file-count check" _check_file_count "$BODY_1A"

BODY_1B='## How

### Files to modify

- NEW: `.agents/scripts/foo.sh` — helper
- EDIT: `.agents/scripts/bar.sh:45-60` — wire it in
- EDIT: `.agents/scripts/baz.sh:100` — also patch this'

assert_fail "1b: 3-file brief fails file-count check (NEW:/EDIT: markers)" _check_file_count "$BODY_1B"

BODY_1C='## How

### Files to modify

- `.agents/scripts/foo.sh`
- `.agents/scripts/bar.sh`
- `.agents/scripts/baz.sh`
- `.agents/scripts/qux.sh`'

assert_fail "1c: 4-file brief fails file-count check (inline paths)" _check_file_count "$BODY_1C"

# -----------------------------------------------------------------------
# Disqualifier 2: estimate
# -----------------------------------------------------------------------

assert_pass "2a: ~30m estimate passes" _check_estimate "Description.
Estimate: ~30m."

assert_pass "2b: ~1h estimate passes (boundary)" _check_estimate "Description.
Estimate: ~1h."

assert_fail "2c: ~2h estimate fails" _check_estimate "Description.
Estimate: ~2h."

assert_fail "2d: ~1d estimate fails (1d = 8h)" _check_estimate "Description.
Estimate: ~1d."

# -----------------------------------------------------------------------
# Disqualifier 3: acceptance count
# -----------------------------------------------------------------------

BODY_3A='## Description

text

## Acceptance

- [ ] first
- [ ] second
- [ ] third'

assert_pass "3a: 3 acceptance criteria passes" _check_acceptance_count "$BODY_3A"

BODY_3B='## Description

text

## Acceptance criteria

- [ ] first
- [ ] second
- [ ] third
- [ ] fourth
- [ ] fifth'

assert_fail "3b: 5 acceptance criteria fails" _check_acceptance_count "$BODY_3B"

BODY_3C='## Description

Rollout plan:

- [ ] step one
- [ ] step two
- [ ] step three
- [ ] step four
- [ ] step five
- [ ] step six

## Acceptance

- [ ] check one
- [ ] check two'

assert_pass "3c: checkboxes outside Acceptance section do not count" _check_acceptance_count "$BODY_3C"

# -----------------------------------------------------------------------
# Disqualifier 4: judgment keywords
# -----------------------------------------------------------------------

assert_pass "4a: clean brief passes keyword check" _check_judgment_keywords \
	"Mechanical edit: replace foo with bar in config file."

assert_fail "4b: \"fallback\" keyword fails" _check_judgment_keywords \
	"Add a fallback path when the API times out."

assert_fail "4c: \"design the\" phrase fails" _check_judgment_keywords \
	"We need to design the error handling strategy here."

BODY_4D='## How

Simple edit — replace line X with line Y.

## Tier checklist

- [ ] Files: 1 (meets tier:simple threshold)
- [ ] Disqualifier check: no fallback, no retry, no coordinate keywords'

assert_pass "4d: keyword in Tier checklist section is ignored" _check_judgment_keywords "$BODY_4D"

BODY_4E='## How

Simple edit.

<!-- aidevops:sig -->
---
[aidevops.sh] plugin with claude-opus-4-7 spent time coordinating session state retry timing.'

assert_pass "4e: keyword in signature footer is ignored" _check_judgment_keywords "$BODY_4E"

# -----------------------------------------------------------------------
# Structural / help
# -----------------------------------------------------------------------

TESTS_RUN=$((TESTS_RUN + 1))
if cmd_help 2>&1 | grep -q "tier-simple-body-shape-helper.sh"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 5: cmd_help prints usage"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5: cmd_help did not print expected usage"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if declare -f cmd_check >/dev/null 2>&1; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 6: cmd_check function declared"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 6: cmd_check function missing"
fi

# -----------------------------------------------------------------------
# Integration — dispatch-core wiring
# -----------------------------------------------------------------------

DISPATCH_CORE="$SCRIPT_DIR/pulse-dispatch-core.sh"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "_run_tier_simple_body_shape_check" "$DISPATCH_CORE"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 7: pulse-dispatch-core.sh wires _run_tier_simple_body_shape_check"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 7: pulse-dispatch-core.sh missing wiring"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------

echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
