#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-qlty-smell-threshold-helper.sh — regression tests for GH#26017

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

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc: $expected"
		echo "  actual rc:   $actual"
	fi
	return 0
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to find: $(printf '%q' "$needle")"
		echo "  in output:        $(printf '%q' "${haystack:0:300}")"
	fi
	return 0
}

write_stub_qlty() {
	local mode="$1" bin_dir="$2"
	mkdir -p "$bin_dir"
	cat >"$bin_dir/qlty" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then
	printf 'qlty test-stub\n'
	exit 0
fi
case "${QLTY_STUB_MODE:-empty}" in
	empty)
		printf 'simulated qlty empty output\n' >&2
		exit 0
		;;
	empty-fail)
		printf 'simulated qlty empty failure diagnostics\n' >&2
		exit 2
		;;
	blank)
		printf '  \n\t\n'
		printf 'simulated qlty blank output\n' >&2
		exit 0
		;;
	invalid)
		printf 'simulated non-sarif stdout\n'
		printf 'simulated qlty invalid output diagnostics\n' >&2
		exit 0
		;;
	pass)
		printf '{"runs":[{"results":[{"ruleId":"file-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"ok.py"}}}]}]}]}'
		exit 0
		;;
	fail)
		printf '{"runs":[{"results":[{"ruleId":"file-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.py"}}}]},{"ruleId":"function-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"b.py"}}}]},{"ruleId":"function-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"b.py"}}}]}]}]}'
		exit 0
		;;
esac
exit 1
STUB
	chmod +x "$bin_dir/qlty"
	QLTY_STUB_MODE="$mode"
	export QLTY_STUB_MODE
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPT_DIR/qlty-smell-threshold-helper.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/qlty-threshold-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

CONF="$TMP_ROOT/complexity-thresholds.conf"
printf 'QLTY_SMELL_THRESHOLD=2\n' >"$CONF"
BIN_DIR="$TMP_ROOT/bin"
PATH="$BIN_DIR:$PATH"
export PATH

echo "${TEST_BLUE}=== GH#26017: qlty smell threshold helper tests ===${TEST_NC}"
echo ""

write_stub_qlty empty "$BIN_DIR"
empty_output=$("$HELPER" "$CONF" 2>&1)
empty_rc=$?
assert_rc "empty SARIF output is warning-only" "0" "$empty_rc"
assert_contains "empty SARIF warning emitted" "empty SARIF output" "$empty_output"
assert_contains "empty SARIF explains diagnostic-only scope" "Absolute threshold status: diagnostic-only" "$empty_output"
assert_contains "empty SARIF includes command context" "smells --all --sarif --no-snippets --quiet" "$empty_output"
assert_contains "empty SARIF includes qlty version" "Qlty version: qlty test-stub" "$empty_output"
assert_contains "empty SARIF includes stderr diagnostics" "simulated qlty empty output" "$empty_output"

write_stub_qlty empty-fail "$BIN_DIR"
empty_fail_output=$("$HELPER" "$CONF" 2>&1)
empty_fail_rc=$?
assert_rc "empty SARIF output with qlty failure is warning-only" "0" "$empty_fail_rc"
assert_contains "empty SARIF failure includes qlty exit code" "qlty smells exit code: 2" "$empty_fail_output"
assert_contains "empty SARIF failure includes stderr diagnostics" "simulated qlty empty failure diagnostics" "$empty_fail_output"

write_stub_qlty blank "$BIN_DIR"
blank_output=$("$HELPER" "$CONF" 2>&1)
blank_rc=$?
assert_rc "blank SARIF output is warning-only" "0" "$blank_rc"
assert_contains "blank SARIF warning emitted" "empty SARIF output" "$blank_output"

write_stub_qlty invalid "$BIN_DIR"
invalid_output=$("$HELPER" "$CONF" 2>&1)
invalid_rc=$?
assert_rc "invalid SARIF output is warning-only" "0" "$invalid_rc"
assert_contains "invalid SARIF warning emitted" "invalid SARIF output" "$invalid_output"
assert_contains "invalid SARIF includes stdout preview" "simulated non-sarif stdout" "$invalid_output"
assert_contains "invalid SARIF includes stderr diagnostics" "simulated qlty invalid output diagnostics" "$invalid_output"

write_stub_qlty pass "$BIN_DIR"
pass_output=$("$HELPER" "$CONF" 2>&1)
pass_rc=$?
assert_rc "valid SARIF below threshold passes" "0" "$pass_rc"
assert_contains "valid SARIF reports headroom" "Within threshold" "$pass_output"

write_stub_qlty fail "$BIN_DIR"
fail_output=$("$HELPER" "$CONF" 2>&1)
fail_rc=$?
assert_rc "valid SARIF above threshold fails" "1" "$fail_rc"
assert_contains "threshold failure remains blocking" "Qlty smell regression" "$fail_output"

echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}All $TESTS_RUN tests passed${TEST_NC}"
	exit 0
fi

echo "${TEST_RED}$TESTS_FAILED of $TESTS_RUN tests failed${TEST_NC}"
exit 1
