#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-tier-label-dedup.sh — Unit tests for _resolve_worker_tier function (t1997)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source the dispatcher to get _resolve_worker_tier
source "$REPO_ROOT/.agents/scripts/pulse-dispatch-core.sh"

# Test counter
tests_run=0
tests_passed=0

#######################################
# Assert helper
#######################################
assert_equals() {
	local expected="$1"
	local actual="$2"
	local test_name="$3"

	# NOTE: use arithmetic assignment (not `((x++))`) — under `set -e`,
	# post-increment returns the value before increment, which is 0 on
	# the first call and trips ERR-exit. GH#18781 follow-up.
	tests_run=$((tests_run + 1))
	if [[ "$expected" == "$actual" ]]; then
		tests_passed=$((tests_passed + 1))
		echo "✓ $test_name"
		return 0
	else
		echo "✗ $test_name"
		echo "  Expected: $expected"
		echo "  Actual:   $actual"
		return 1
	fi
}

#######################################
# Test cases
#######################################

# Test 1: Single tier:simple label
result=$(_resolve_worker_tier "bug,tier:simple")
assert_equals "tier:simple" "$result" "Single tier:simple label"

# Test 2: Single tier:standard label
result=$(_resolve_worker_tier "bug,tier:standard,auto-dispatch")
assert_equals "tier:standard" "$result" "Single tier:standard label"

# Test 3: Single tier:thinking label
result=$(_resolve_worker_tier "tier:thinking,bug")
assert_equals "tier:thinking" "$result" "Single tier:thinking label"

# Test 4: Multiple tiers - prefer tier:standard over tier:simple
result=$(_resolve_worker_tier "bug,tier:standard,tier:simple")
assert_equals "tier:standard" "$result" "Multiple tiers: standard > simple"

# Test 5: Multiple tiers - prefer tier:thinking over tier:standard
result=$(_resolve_worker_tier "tier:thinking,tier:standard,bug")
assert_equals "tier:thinking" "$result" "Multiple tiers: thinking > standard"

# Test 6: Multiple tiers - prefer tier:thinking over tier:simple
result=$(_resolve_worker_tier "tier:simple,tier:thinking")
assert_equals "tier:thinking" "$result" "Multiple tiers: thinking > simple"

# Test 7: All three tiers present - prefer tier:thinking
result=$(_resolve_worker_tier "tier:simple,tier:standard,tier:thinking")
assert_equals "tier:thinking" "$result" "All three tiers: thinking wins"

# Test 8: No tier label - default to tier:standard
result=$(_resolve_worker_tier "bug,auto-dispatch,help-wanted")
assert_equals "tier:standard" "$result" "No tier label: default to standard"

# Test 9: Empty label list - default to tier:standard
result=$(_resolve_worker_tier "")
assert_equals "tier:standard" "$result" "Empty label list: default to standard"

# Test 10: Case insensitivity - uppercase TIER:STANDARD
result=$(_resolve_worker_tier "bug,TIER:STANDARD")
assert_equals "tier:standard" "$result" "Case insensitive: TIER:STANDARD"

# Test 11: Case insensitivity - mixed case Tier:Simple
result=$(_resolve_worker_tier "Tier:Simple,bug")
assert_equals "tier:simple" "$result" "Case insensitive: Tier:Simple"

# Test 12: Order independence - tier:simple first, tier:standard second
result=$(_resolve_worker_tier "tier:simple,tier:standard")
assert_equals "tier:standard" "$result" "Order independence: simple then standard"

# Test 13: Order independence - tier:standard first, tier:simple second
result=$(_resolve_worker_tier "tier:standard,tier:simple")
assert_equals "tier:standard" "$result" "Order independence: standard then simple"

#######################################
# Summary
#######################################
echo ""
echo "Tests passed: $tests_passed / $tests_run"

if [[ $tests_passed -eq $tests_run ]]; then
	exit 0
else
	exit 1
fi
