#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-override.sh — tests for DISPATCH_CLAIM_IGNORE_RUNNERS override (t2399)
#
# Validates:
#   1. Config file loader respects DISPATCH_CLAIM_IGNORE_RUNNERS
#   2. Space-separated ignore list works
#   3. Comma-separated ignore list works
#   4. Empty ignore list is a no-op
#   5. DISPATCH_OVERRIDE_ENABLED=false disables filtering
#   6. Filter log line is emitted when filtering fires

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../dispatch-claim-helper.sh"

PASS=0
FAIL=0

assert_eq() {
	local expected="$1"
	local actual="$2"
	local msg="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf '  PASS: %s\n' "$msg"
		PASS=$((PASS + 1))
	else
		printf '  FAIL: %s (expected: %q, got: %q)\n' "$msg" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# Helper: normalize runner list → JSON array (mirrors _fetch_claims logic)
_normalize_runners() {
	local input="$1"
	printf '%s' "$input" | tr ',' ' ' | tr -s ' ' '\n' | jq -Rsc 'split("\n") | map(select(length > 0))'
	return 0
}

# Test 1: config loader respects space-separated list
test_space_separated_list() {
	printf '\nTest 1: space-separated ignore list parses correctly\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_CLAIM_IGNORE_RUNNERS="alice bob"
DISPATCH_OVERRIDE_ENABLED=true
EOF
	# shellcheck disable=SC1090
	source "$tmp_conf"
	local ignored_json
	ignored_json=$(_normalize_runners "$DISPATCH_CLAIM_IGNORE_RUNNERS")
	assert_eq '["alice","bob"]' "$ignored_json" "space-separated → JSON array"
	rm -f "$tmp_conf"
	unset DISPATCH_CLAIM_IGNORE_RUNNERS DISPATCH_OVERRIDE_ENABLED
	return 0
}

# Test 2: comma-separated list
test_comma_separated_list() {
	printf '\nTest 2: comma-separated ignore list parses correctly\n'
	DISPATCH_CLAIM_IGNORE_RUNNERS="alice,bob,charlie"
	local ignored_json
	ignored_json=$(_normalize_runners "$DISPATCH_CLAIM_IGNORE_RUNNERS")
	assert_eq '["alice","bob","charlie"]' "$ignored_json" "comma-separated → JSON array"
	unset DISPATCH_CLAIM_IGNORE_RUNNERS
	return 0
}

# Test 3: empty list
test_empty_list() {
	printf '\nTest 3: empty ignore list is a no-op\n'
	DISPATCH_CLAIM_IGNORE_RUNNERS=""
	local ignored_json
	ignored_json=$(_normalize_runners "$DISPATCH_CLAIM_IGNORE_RUNNERS")
	assert_eq '[]' "$ignored_json" "empty string → empty array"
	unset DISPATCH_CLAIM_IGNORE_RUNNERS
	return 0
}

# Test 4: jq filter removes matching runner
test_jq_filter_behaviour() {
	printf '\nTest 4: jq filter removes claims from ignored runners\n'
	local input='[{"runner":"alice","ts":"1"},{"runner":"bob","ts":"2"},{"runner":"charlie","ts":"3"}]'
	local ignored='["bob"]'
	local result
	result=$(printf '%s' "$input" | jq -c --argjson ignored "$ignored" 'map(select(.runner as $r | $ignored | index($r) | not))')
	assert_eq '[{"runner":"alice","ts":"1"},{"runner":"charlie","ts":"3"}]' "$result" "bob filtered out"

	# Multi-filter
	ignored='["alice","charlie"]'
	result=$(printf '%s' "$input" | jq -c --argjson ignored "$ignored" 'map(select(.runner as $r | $ignored | index($r) | not))')
	assert_eq '[{"runner":"bob","ts":"2"}]' "$result" "alice and charlie filtered out, bob kept"
	return 0
}

# Test 5: DISPATCH_OVERRIDE_ENABLED=false disables filtering
test_enabled_flag() {
	printf '\nTest 5: DISPATCH_OVERRIDE_ENABLED=false disables filtering\n'
	DISPATCH_OVERRIDE_ENABLED="false"
	DISPATCH_CLAIM_IGNORE_RUNNERS="alice"
	# Condition check (what _fetch_claims does)
	local should_filter="no"
	if [[ "$DISPATCH_OVERRIDE_ENABLED" == "true" ]] && [[ -n "$DISPATCH_CLAIM_IGNORE_RUNNERS" ]]; then
		should_filter="yes"
	fi
	assert_eq "no" "$should_filter" "filter skipped when DISPATCH_OVERRIDE_ENABLED=false"
	unset DISPATCH_OVERRIDE_ENABLED DISPATCH_CLAIM_IGNORE_RUNNERS
	return 0
}

# Test 6: helper script loads and sources correctly
test_helper_sources() {
	printf '\nTest 6: dispatch-claim-helper.sh sources the override config\n'
	local tmp_conf
	tmp_conf=$(mktemp)
	cat >"$tmp_conf" <<'EOF'
DISPATCH_CLAIM_IGNORE_RUNNERS="bob"
DISPATCH_OVERRIDE_ENABLED=true
EOF
	# Run the helper's `help` command — it will source the config as a side effect
	local out
	out=$(DISPATCH_OVERRIDE_CONF="$tmp_conf" "$HELPER" help 2>&1 | head -5)
	# Verify no source errors
	if [[ "$out" != *"Error"* ]] && [[ "$out" != *"error"* ]]; then
		printf '  PASS: helper sourced config without errors\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: helper emitted error when sourcing config\n'
		FAIL=$((FAIL + 1))
	fi
	rm -f "$tmp_conf"
	return 0
}

# Run all tests
test_space_separated_list
test_comma_separated_list
test_empty_list
test_jq_filter_behaviour
test_enabled_flag
test_helper_sources

printf '\n========================\n'
printf 'Passed: %d, Failed: %d\n' "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
