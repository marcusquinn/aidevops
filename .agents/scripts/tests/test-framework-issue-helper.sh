#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for framework-issue-helper.sh duplicate issue parsing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../framework-issue-helper.sh"

PASS=0
FAIL=0

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	printf 'PASS: %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s — %s\n' "$name" "$detail"
	return 0
}

assert_contains() {
	local output="$1"
	local expected="$2"
	local name="$3"

	if grep -Fq "$expected" <<<"$output"; then
		pass "$name"
	else
		fail "$name" "expected ${expected}; got: ${output}"
	fi
	return 0
}

assert_not_contains() {
	local output="$1"
	local unexpected="$2"
	local name="$3"

	if grep -Fq "$unexpected" <<<"$output"; then
		fail "$name" "unexpected ${unexpected}; got: ${output}"
	else
		pass "$name"
	fi
	return 0
}

run_case() {
	local duplicate_value="$1"
	local created_url="$2"
	local stub_dir="$3"
	local output_file="$4"

	cat >"${stub_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	printf '%s\n' "${TEST_DUPLICATE_VALUE:-}"
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
	printf '%s\n' "${TEST_CREATED_URL:-https://github.com/marcusquinn/aidevops/issues/9001}"
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
	printf '"testuser"\n'
	exit 0
fi

exit 0
EOF
	chmod +x "${stub_dir}/gh"

	if TEST_DUPLICATE_VALUE="$duplicate_value" \
		TEST_CREATED_URL="$created_url" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title "fix: duplicate parser regression" --body "body" >"$output_file" 2>&1; then
		return 0
	fi

	return 1
}

TMP_DIR=$(mktemp -d -t framework-issue-helper-test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

empty_output="${TMP_DIR}/empty.out"
run_case "[]" "https://github.com/marcusquinn/aidevops/issues/9001" "${TMP_DIR}" "$empty_output"
empty_text=$(<"$empty_output")
assert_contains "$empty_text" "status=created" "empty array result continues to issue creation"
assert_not_contains "$empty_text" "status=duplicate" "empty array result is not duplicate"
assert_not_contains "$empty_text" "issue_num=[]" "empty array result never emits issue_num=[]"

malformed_output="${TMP_DIR}/malformed.out"
run_case "not-a-number" "https://github.com/marcusquinn/aidevops/issues/9002" "${TMP_DIR}" "$malformed_output"
malformed_text=$(<"$malformed_output")
assert_contains "$malformed_text" "status=created" "malformed duplicate result continues to issue creation"
assert_not_contains "$malformed_text" "status=duplicate" "malformed duplicate result is not duplicate"

valid_output="${TMP_DIR}/valid.out"
run_case "12345" "https://github.com/marcusquinn/aidevops/issues/9003" "${TMP_DIR}" "$valid_output"
valid_text=$(<"$valid_output")
assert_contains "$valid_text" "status=duplicate" "valid duplicate result skips creation"
assert_contains "$valid_text" "issue_num=12345" "valid duplicate result emits numeric issue number"
assert_contains "$valid_text" "issue_url=https://github.com/marcusquinn/aidevops/issues/12345" "valid duplicate result emits valid issue URL"

invalid_create_output="${TMP_DIR}/invalid-create.out"
if run_case "" "https://github.com/marcusquinn/aidevops/issues/[]" "${TMP_DIR}" "$invalid_create_output"; then
	fail "invalid created issue URL is rejected" "helper succeeded for invalid created URL"
else
	invalid_create_text=$(<"$invalid_create_output")
	assert_not_contains "$invalid_create_text" "issue_url=https://github.com/marcusquinn/aidevops/issues/[]" "invalid created issue URL is not emitted"
fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi

exit 0
