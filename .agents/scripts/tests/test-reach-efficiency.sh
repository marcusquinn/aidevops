#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reach-efficiency.sh - Deterministic reach routing efficiency policy tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../reach-helper.sh"

PASS=0
FAIL=0

assert_contains() {
	local output="$1"
	local expected="$2"
	local description="$3"

	if grep -Fq -- "$expected" <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Expected output to contain: %s\n' "$expected"
		printf '    Output: %s\n' "$output"
	fi
	return 0
}

assert_json_valid() {
	local output="$1"
	local description="$2"

	if python3 -m json.tool >/dev/null 2>&1 <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Invalid JSON: %s\n' "$output"
	fi
	return 0
}

printf '=== Reach Efficiency Tests ===\n\n'

public_output="$($HELPER route --objective "public static changelog fetch" --scope public --format json)"
assert_json_valid "$public_output" "public fetch route emits valid JSON"
assert_contains "$public_output" '"backend":"fetch"' "public static work uses fetch"
assert_contains "$public_output" '"headed":false' "public static work is headless"
assert_contains "$public_output" '"max_iterations":3' "public static route includes iteration budget"
assert_contains "$public_output" '"max_tool_calls":12' "public static route includes tool-call budget"
assert_contains "$public_output" '"max_token_estimate":6000' "public static route includes token budget"
assert_contains "$public_output" '"prefer API or fetch before browser"' "efficiency policy prefers API/fetch"

profile_output="$($HELPER route --objective "logged-in profile dashboard capture" --auth profile --scope private --format json)"
assert_json_valid "$profile_output" "profile route emits valid JSON"
assert_contains "$profile_output" '"backend":"persistent_profile"' "profile auth uses persistent profile"
assert_contains "$profile_output" '"headed":true' "profile auth is headed"
assert_contains "$profile_output" '"offload":"local"' "profile auth remains local"
assert_contains "$profile_output" 'not offloaded without private workspace' "profile route explains no offload"

long_crawl_output="$($HELPER route --objective "long recurring crawl many pages" --scope public --format json)"
assert_json_valid "$long_crawl_output" "long crawl route emits valid JSON"
assert_contains "$long_crawl_output" '"backend":"crawler"' "long crawl uses crawler"
assert_contains "$long_crawl_output" '"offload":"worker"' "long crawl recommends worker offload"
assert_contains "$long_crawl_output" '"routine_candidate":true' "long crawl is routine candidate"

manual_output="$($HELPER route --objective "submit payment form with CAPTCHA" --scope public --format json)"
assert_json_valid "$manual_output" "manual gate route emits valid JSON"
assert_contains "$manual_output" '"backend":"manual_review"' "manual gate uses manual review"
assert_contains "$manual_output" '"headed":true' "manual gate is headed"
assert_contains "$manual_output" '"offload":"manual"' "manual gate is not offloaded"

routine_output="$($HELPER route --objective "recurring public changelog capture routine" --scope public --format json)"
assert_json_valid "$routine_output" "routine candidate route emits valid JSON"
assert_contains "$routine_output" '"routine_candidate":true' "recurring capture is routine candidate"
assert_contains "$routine_output" '"route_decision_id":"reach-route-' "route includes decision id"
assert_contains "$routine_output" '"audit_refs"' "route includes audit refs"

sensitive_output="$($HELPER route --objective "sensitive cookie profile crawl" --auth cookie --scope private --format json)"
assert_json_valid "$sensitive_output" "sensitive route emits valid JSON"
assert_contains "$sensitive_output" '"backend":"cookie_session"' "cookie auth uses cookie session"
assert_contains "$sensitive_output" '"offload":"local"' "sensitive cookie work is not offloaded"
assert_contains "$sensitive_output" 'not offloaded without private workspace' "sensitive route explains no offload"

watch_output="$($HELPER watch --once --dry-run --format json)"
assert_json_valid "$watch_output" "watch dry-run emits valid JSON"
assert_contains "$watch_output" '"report_only":true' "watch is report-only"
assert_contains "$watch_output" '"mutates":false' "watch does not mutate by default"

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi

exit 0
