#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_CHECK="${SCRIPT_DIR}/../aidevops-update-check.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_PATH="$PATH"
ORIGINAL_HOME="$HOME"

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	PATH="$ORIGINAL_PATH"
	HOME="$ORIGINAL_HOME"
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

setup_fake_tools() {
	local gh_version_line="$1"
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home"
	HOME="${TEST_ROOT}/home"
	PATH="${TEST_ROOT}/bin:${ORIGINAL_PATH}"

	cat >"${TEST_ROOT}/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${gh_version_line}'
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"

	cat >"${TEST_ROOT}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
	chmod +x "${TEST_ROOT}/bin/curl"
	return 0
}

test_old_gh_warns_in_update_check() {
	setup_fake_tools "gh version 2.45.0 (2025-07-18 Ubuntu 2.45.0-1ubuntu0.3)"
	local output=""
	output=$(bash "$UPDATE_CHECK" --interactive 2>/dev/null || true)
	if [[ "$output" == *"[WARN] GitHub CLI prerequisite:"* && "$output" == *"requires gh >= 2.51.0"* ]]; then
		print_result "old gh emits session-start prerequisite warning" 0
	else
		print_result "old gh emits session-start prerequisite warning" 1 "output='${output}'"
	fi
	return 0
}

test_supported_gh_has_no_warning() {
	setup_fake_tools "gh version 2.51.0 (2024-05-29)"
	local output=""
	output=$(bash "$UPDATE_CHECK" --interactive 2>/dev/null || true)
	if [[ "$output" != *"[WARN] GitHub CLI prerequisite:"* ]]; then
		print_result "supported gh omits session-start prerequisite warning" 0
	else
		print_result "supported gh omits session-start prerequisite warning" 1 "output='${output}'"
	fi
	return 0
}

test_old_gh_warns_in_update_check
test_supported_gh_has_no_warning

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
