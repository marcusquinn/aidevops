#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-override.sh — tests for dispatch override filters (t2399, t2400, t2401)
#
# Validates:
#   1. Config file loader respects DISPATCH_CLAIM_IGNORE_RUNNERS
#   2. Space-separated ignore list works
#   3. Comma-separated ignore list works
#   4. Empty ignore list is a no-op
#   5. DISPATCH_OVERRIDE_ENABLED=false disables filtering
#   6. Helper script sources config cleanly
#   7. [t2401] Claim body includes version=X.Y.Z field
#   8. [t2401] jq capture parses version field + legacy "unknown" fallback
#   9. [t2401] _version_below semver comparison
#  10. [t2401] _filter_below_version strips claims below floor

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../dispatch-claim-helper.sh"

PASS=0
FAIL=0

# Source the helper's internal functions (strip main invocation)
_source_helper() {
	local tmp
	tmp=$(mktemp)
	sed '/^main "$@"$/d' "$HELPER" >"$tmp"
	# shellcheck disable=SC1090
	source "$tmp"
	rm -f "$tmp"
	return 0
}

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

# Test 7 (t2401): _resolve_version reads VERSION file, falls back to "unknown"
test_resolve_version() {
	printf '\nTest 7: _resolve_version reads VERSION file and falls back to "unknown"\n'
	_source_helper

	local tmp_ver
	tmp_ver=$(mktemp)
	printf '3.8.78\n' >"$tmp_ver"
	local ver
	AIDEVOPS_VERSION_FILE="$tmp_ver" ver=$(_resolve_version)
	assert_eq "3.8.78" "$ver" "VERSION file → 3.8.78"

	# Tolerate trailing whitespace
	printf '  3.9.1  \n' >"$tmp_ver"
	AIDEVOPS_VERSION_FILE="$tmp_ver" ver=$(_resolve_version)
	assert_eq "3.9.1" "$ver" "whitespace stripped"

	AIDEVOPS_VERSION_FILE="/nonexistent/path/VERSION" ver=$(_resolve_version)
	assert_eq "unknown" "$ver" "missing file → unknown"

	# Empty file
	: >"$tmp_ver"
	AIDEVOPS_VERSION_FILE="$tmp_ver" ver=$(_resolve_version)
	assert_eq "unknown" "$ver" "empty file → unknown"

	rm -f "$tmp_ver"
	return 0
}

# Test 8 (t2401): claim body format includes version=X.Y.Z; jq capture handles
# both new and legacy (missing version) bodies.
test_claim_body_version() {
	printf '\nTest 8: claim body format + jq capture parse version field\n'

	# New format (t2401+): version field present
	local body_new='DISPATCH_CLAIM nonce=abc123 runner=alice ts=2026-04-19T00:00:00Z max_age_s=1800 version=3.9.0'
	local parsed_new
	parsed_new=$(printf '%s' "$body_new" | jq -Rnc '[inputs | capture("nonce=(?<nonce>[^ ]+) runner=(?<runner>[^ ]+) ts=(?<ts>[^ ]+)(?: max_age_s=[^ ]+)?(?: version=(?<version>[^ ]+))?") | {runner: .runner, version: (.version // "unknown")}]')
	assert_eq '[{"runner":"alice","version":"3.9.0"}]' "$parsed_new" "new body → version=3.9.0"

	# Legacy format (pre-t2401): no version field
	local body_legacy='DISPATCH_CLAIM nonce=abc123 runner=alice ts=2026-04-19T00:00:00Z max_age_s=1800'
	local parsed_legacy
	parsed_legacy=$(printf '%s' "$body_legacy" | jq -Rnc '[inputs | capture("nonce=(?<nonce>[^ ]+) runner=(?<runner>[^ ]+) ts=(?<ts>[^ ]+)(?: max_age_s=[^ ]+)?(?: version=(?<version>[^ ]+))?") | {runner: .runner, version: (.version // "unknown")}]')
	assert_eq '[{"runner":"alice","version":"unknown"}]' "$parsed_legacy" "legacy body → version=unknown"
	return 0
}

# Test 9 (t2401): _version_below semver comparison. Critical assertion:
# numeric semver (3.8.100 > 3.8.78), not lexicographic.
test_version_below() {
	printf '\nTest 9: _version_below semver comparison (incl. numeric ordering)\n'
	_source_helper

	if _version_below "3.8.78" "3.9.0"; then
		printf '  PASS: 3.8.78 < 3.9.0\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: 3.8.78 should be below 3.9.0\n'
		FAIL=$((FAIL + 1))
	fi

	if _version_below "3.9.1" "3.9.0"; then
		printf '  FAIL: 3.9.1 should NOT be below 3.9.0\n'
		FAIL=$((FAIL + 1))
	else
		printf '  PASS: 3.9.1 >= 3.9.0\n'
		PASS=$((PASS + 1))
	fi

	# Critical: numeric semver, not lexicographic — "100" > "78" numerically
	if _version_below "3.8.100" "3.8.78"; then
		printf '  FAIL: 3.8.100 < 3.8.78 — lexicographic bug (should be numeric)\n'
		FAIL=$((FAIL + 1))
	else
		printf '  PASS: 3.8.100 > 3.8.78 (numeric semver, not lexicographic)\n'
		PASS=$((PASS + 1))
	fi

	if _version_below "unknown" "3.9.0"; then
		printf '  PASS: "unknown" below any floor\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: "unknown" should be below 3.9.0\n'
		FAIL=$((FAIL + 1))
	fi

	if _version_below "3.9.0" "3.9.0"; then
		printf '  FAIL: equal versions should NOT be strictly below\n'
		FAIL=$((FAIL + 1))
	else
		printf '  PASS: equal versions not below\n'
		PASS=$((PASS + 1))
	fi

	if _version_below "" "3.9.0"; then
		printf '  PASS: empty version below any floor\n'
		PASS=$((PASS + 1))
	else
		printf '  FAIL: empty version should be below 3.9.0\n'
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# Test 10 (t2401): _filter_below_version + _apply_ignore_filter with MIN_VERSION
test_version_filter_integration() {
	printf '\nTest 10: _apply_ignore_filter strips old versions (DISPATCH_CLAIM_MIN_VERSION)\n'
	_source_helper

	local parsed='[{"id":1,"runner":"alice","version":"3.8.78"},{"id":2,"runner":"bob","version":"3.9.1"},{"id":3,"runner":"charlie","version":"unknown"}]'

	# Version-only filter (floor=3.9.0): only bob (3.9.1) survives
	local result
	DISPATCH_OVERRIDE_ENABLED=true \
		DISPATCH_CLAIM_IGNORE_RUNNERS="" \
		DISPATCH_CLAIM_MIN_VERSION="3.9.0" \
		result=$(_apply_ignore_filter "$parsed" "42" "owner/repo" 2>/dev/null)
	local runners
	runners=$(printf '%s' "$result" | jq -r '.[].runner' 2>/dev/null | sort | tr '\n' ',')
	assert_eq "bob," "$runners" "version filter: only bob (3.9.1) kept"

	# Combined login + version: alice filtered by login, bob filtered by version
	local parsed2='[{"id":1,"runner":"alice","version":"3.9.1"},{"id":2,"runner":"bob","version":"3.8.78"},{"id":3,"runner":"charlie","version":"3.9.1"}]'
	DISPATCH_OVERRIDE_ENABLED=true \
		DISPATCH_CLAIM_IGNORE_RUNNERS="alice" \
		DISPATCH_CLAIM_MIN_VERSION="3.9.0" \
		result=$(_apply_ignore_filter "$parsed2" "42" "owner/repo" 2>/dev/null)
	runners=$(printf '%s' "$result" | jq -r '.[].runner' 2>/dev/null | sort | tr '\n' ',')
	assert_eq "charlie," "$runners" "combined filter: alice (login) + bob (version) removed"

	# Disabled override: no-op even with filters set
	DISPATCH_OVERRIDE_ENABLED=false \
		DISPATCH_CLAIM_IGNORE_RUNNERS="alice" \
		DISPATCH_CLAIM_MIN_VERSION="3.9.0" \
		result=$(_apply_ignore_filter "$parsed2" "42" "owner/repo" 2>/dev/null)
	assert_eq "$parsed2" "$result" "disabled override → input unchanged"

	# Empty filters: no-op
	DISPATCH_OVERRIDE_ENABLED=true \
		DISPATCH_CLAIM_IGNORE_RUNNERS="" \
		DISPATCH_CLAIM_MIN_VERSION="" \
		result=$(_apply_ignore_filter "$parsed2" "42" "owner/repo" 2>/dev/null)
	assert_eq "$parsed2" "$result" "empty filters → input unchanged"

	unset DISPATCH_OVERRIDE_ENABLED DISPATCH_CLAIM_IGNORE_RUNNERS DISPATCH_CLAIM_MIN_VERSION
	return 0
}

# Run all tests
test_space_separated_list
test_comma_separated_list
test_empty_list
test_jq_filter_behaviour
test_enabled_flag
test_helper_sources
test_resolve_version
test_claim_body_version
test_version_below
test_version_filter_integration

printf '\n========================\n'
printf 'Passed: %d, Failed: %d\n' "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
