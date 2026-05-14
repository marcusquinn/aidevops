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

	if grep -Fq -- "$expected" <<<"$output"; then
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

	if grep -Fq -- "$unexpected" <<<"$output"; then
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

if [[ -n "${TEST_GH_TRACE:-}" ]]; then
	printf '%s\n' "$*" >>"$TEST_GH_TRACE"
fi

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

run_auto_dispatch_case() {
	local stub_dir="$1"
	local output_file="$2"
	local trace_file="$3"

	if TEST_DUPLICATE_VALUE="" \
		TEST_CREATED_URL="https://github.com/marcusquinn/aidevops/issues/9100" \
		TEST_GH_TRACE="$trace_file" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title "fix: auto dispatch labels" --body "body" --label bug --auto-dispatch --tier standard >"$output_file" 2>&1; then
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

auto_dispatch_output="${TMP_DIR}/auto-dispatch.out"
auto_dispatch_trace="${TMP_DIR}/auto-dispatch.trace"
if run_auto_dispatch_case "${TMP_DIR}" "$auto_dispatch_output" "$auto_dispatch_trace"; then
	auto_dispatch_text=$(<"$auto_dispatch_output")
	auto_dispatch_calls=$(<"$auto_dispatch_trace")
	assert_contains "$auto_dispatch_text" "status=created" "auto-dispatch case creates issue"
	assert_contains "$auto_dispatch_calls" "issue create" "auto-dispatch case uses issue creation"
	assert_contains "$auto_dispatch_calls" "--label bug" "auto-dispatch case preserves requested label"
	assert_contains "$auto_dispatch_calls" "--label auto-dispatch" "auto-dispatch case passes auto-dispatch at create time"
	assert_contains "$auto_dispatch_calls" "--label tier:standard" "auto-dispatch case passes tier at create time"
	assert_contains "$auto_dispatch_calls" "--label status:available" "auto-dispatch case includes worker-ready status label"
	assert_not_contains "$auto_dispatch_calls" "issue edit" "auto-dispatch case avoids post-create issue edits"
else
	fail "auto-dispatch case creates issue" "helper failed"
fi

help_output="${TMP_DIR}/help.out"
"$HELPER" help >"$help_output" 2>&1
help_text=$(<"$help_output")
assert_contains "$help_text" "--auto-dispatch" "usage documents auto-dispatch flag"
assert_contains "$help_text" "--tier TIER" "usage documents tier flag"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi

exit 0
