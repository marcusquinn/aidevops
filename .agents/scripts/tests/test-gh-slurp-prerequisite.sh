#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../shared-constants.sh
source "${AGENTS_SCRIPTS}/shared-constants.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_PATH="$PATH"

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	PATH="$ORIGINAL_PATH"
	return 0
}
trap cleanup EXIT

print_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	[[ -n "$detail" ]] && printf '  %s\n' "$detail" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_supported() {
	local version="$1"
	if aidevops_version_at_least "$version" "$AIDEVOPS_GH_MIN_SLURP_VERSION"; then
		print_result "gh ${version} supports --slurp" 0
	else
		print_result "gh ${version} supports --slurp" 1 "expected >= ${AIDEVOPS_GH_MIN_SLURP_VERSION} to pass"
	fi
	return 0
}

assert_not_supported() {
	local version="$1"
	if aidevops_version_at_least "$version" "$AIDEVOPS_GH_MIN_SLURP_VERSION"; then
		print_result "gh ${version} rejected below minimum" 1 "expected version to fail minimum check"
	else
		print_result "gh ${version} rejected below minimum" 0
	fi
	return 0
}

assert_parse() {
	local label="$1"
	local input="$2"
	local expected="$3"
	local got=""
	got=$(aidevops_parse_semver "$input" 2>/dev/null || true)
	if [[ "$got" == "$expected" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "got='${got}' expected='${expected}'"
	fi
	return 0
}

assert_parse_fails() {
	local label="$1"
	local input="$2"
	if aidevops_parse_semver "$input" >/dev/null 2>&1; then
		print_result "$label" 1 "expected parse failure"
	else
		print_result "$label" 0
	fi
	return 0
}

with_fake_gh() {
	local body="$1"
	TEST_ROOT=$(mktemp -d)
	cat >"${TEST_ROOT}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${body}'
exit 0
EOF
	chmod +x "${TEST_ROOT}/gh"
	PATH="${TEST_ROOT}:$ORIGINAL_PATH"
	return 0
}

assert_status_contains() {
	local label="$1"
	local expected="$2"
	local got=""
	got=$(aidevops_gh_slurp_status_message)
	if [[ "$got" == *"$expected"* ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "got='${got}' expected substring='${expected}'"
	fi
	return 0
}

assert_not_supported "2.50.9"
assert_supported "2.51.0"
assert_supported "2.52.0"
assert_parse "parse gh --version output" "gh version 2.51.0 (2024-05-29)" "2.51.0"
assert_parse "parse Ubuntu gh package output" "gh version 2.45.0 (2025-07-18 Ubuntu 2.45.0-1ubuntu0.3)" "2.45.0"
assert_parse "parse two-component output" "gh version 2.51" "2.51.0"
assert_parse_fails "malformed gh output fails clearly" "gh version unknown"
assert_parse_fails "empty gh output fails clearly" ""
with_fake_gh "gh version unknown"
assert_status_contains "malformed gh version emits clear warning" "version could not be parsed"
with_fake_gh "gh version 2.50.0"
assert_status_contains "old gh version emits minimum warning" "requires gh >= 2.51.0"
assert_status_contains "old gh version emits apt-pin guidance" "Ubuntu universe gh package"
with_fake_gh "gh version 2.51.0"
assert_status_contains "minimum gh version passes status" "minimum required 2.51.0"

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
