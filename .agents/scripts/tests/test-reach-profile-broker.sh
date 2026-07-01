#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reach-profile-broker.sh - Focused tests for reach profile/cookie broker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../reach-helper.sh"

PASS=0
FAIL=0
TEST_WORKSPACE=""

cleanup() {
	if [[ -n "$TEST_WORKSPACE" && -d "$TEST_WORKSPACE" ]]; then
		rm -rf "$TEST_WORKSPACE"
	fi
	return 0
}
trap cleanup EXIT

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

assert_not_contains() {
	local output="$1"
	local unexpected="$2"
	local description="$3"

	if grep -Fq -- "$unexpected" <<<"$output"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Unexpected output: %s\n' "$unexpected"
		printf '    Output: %s\n' "$output"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
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

assert_file_contains() {
	local file_path="$1"
	local expected="$2"
	local description="$3"

	if grep -Fq -- "$expected" "$file_path"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Expected file to contain: %s\n' "$expected"
	fi
	return 0
}

run_helper() {
	if AIDEVOPS_REACH_WORKSPACE="$TEST_WORKSPACE" "$HELPER" "$@"; then
		return 0
	fi
	return 1
}

printf '=== Reach Profile Broker Tests ===\n\n'

TEST_WORKSPACE="$(mktemp -d)"
private_cookie_source="${TEST_WORKSPACE}/private-cookie-export.json"
printf '{"cookie":"secret-value"}\n' >"$private_cookie_source"

lease_output="$(run_helper profile lease --target-key test-target --type persistent --ttl 30m --format json)"
assert_json_valid "$lease_output" "profile lease emits valid JSON"
assert_contains "$lease_output" '"lease_status":"active"' "profile lease is active"
assert_contains "$lease_output" '"profile_type":"persistent"' "profile lease records type"
assert_not_contains "$lease_output" "$TEST_WORKSPACE" "profile lease output omits workspace path"

status_output="$(run_helper profile status --target-key test-target --format json)"
assert_contains "$status_output" '"lease_status":"active"' "profile status reports active lease"

if overwrite_output="$(run_helper profile lease --target-key test-target --type clean --ttl 30m --format json 2>/dev/null)"; then
	FAIL=$((FAIL + 1))
	printf '  FAIL: unforced overwrite should fail\n'
else
	PASS=$((PASS + 1))
	printf '  PASS: unforced overwrite fails\n'
	assert_contains "$overwrite_output" '"refused_overwrite":true' "unforced overwrite reports refusal"
fi

forced_output="$(run_helper profile lease --target-key test-target --type clean --ttl 30m --force --format json)"
assert_contains "$forced_output" '"profile_type":"clean"' "forced overwrite updates profile type"

release_output="$(run_helper profile release --target-key test-target --format json)"
assert_contains "$release_output" '"released":true' "profile release removes lease"

expired_output="$(run_helper profile lease --target-key expired-target --type persistent --ttl 0 --format json)"
assert_json_valid "$expired_output" "expired lease creation emits valid JSON"
reuse_output="$(run_helper profile lease --target-key expired-target --type warm --ttl 30m --format json)"
assert_contains "$reuse_output" '"profile_type":"warm"' "expired lease can be reused without force"

cookie_output="$(run_helper cookie register --target-key test-target --source "$private_cookie_source" --ttl 30m --format json)"
assert_json_valid "$cookie_output" "cookie register emits valid JSON"
assert_contains "$cookie_output" '"cookie_status":"registered"' "cookie register records session"
assert_contains "$cookie_output" '"source_hash":' "cookie output includes safe hash"
assert_not_contains "$cookie_output" "$private_cookie_source" "cookie register output omits private cookie path"
assert_not_contains "$cookie_output" "secret-value" "cookie register output omits cookie value"

cookie_file="${TEST_WORKSPACE}/cookie-sessions/test-target.json"
assert_file_contains "$cookie_file" "$private_cookie_source" "cookie metadata stores private path locally"

cookie_status_output="$(run_helper cookie status --target-key test-target --format json)"
assert_contains "$cookie_status_output" '"cookie_status":"registered"' "cookie status reports registered session"
assert_not_contains "$cookie_status_output" "$private_cookie_source" "cookie status omits private path"

route_cookie_output="$(run_helper route --objective "logged-in dashboard export" --auth cookie --format json)"
assert_contains "$route_cookie_output" '"cookie_policy":"reuse_approved_session"' "route uses registered cookie policy"

route_profile_output="$(run_helper route --objective "logged-in dashboard export" --auth profile --format json)"
assert_contains "$route_profile_output" '"profile_policy":"use_existing_approved_profile"' "route uses active profile lease policy"

clear_output="$(run_helper cookie clear --target-key test-target --format json)"
assert_contains "$clear_output" '"cleared":true' "cookie clear removes registration"

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi

exit 0
