#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../secret-helper.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR=""
ORIG_PATH="$PATH"

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${GREEN}PASS${RESET} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${RED}FAIL${RESET} $test_name"
		if [[ -n "$message" ]]; then
			echo "       $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	mkdir -p "$TEST_DIR/bin"

	cat >"$TEST_DIR/bin/gopass" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
	ls)
		exit 0
		;;
	insert)
		if [[ "${1:-}" == "--force" ]]; then
			shift
		fi
		path="${1:-}"
		printf '%s' "$path" >"${AIDEVOPS_TEST_DIR}/stored_path"
		cat >"${AIDEVOPS_TEST_DIR}/stored_value"
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "$TEST_DIR/bin/gopass"

	export AIDEVOPS_TEST_DIR="$TEST_DIR"
	export PATH="$TEST_DIR/bin:$ORIG_PATH"

	return 0
}

teardown() {
	export PATH="$ORIG_PATH"
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	TEST_DIR=""
	unset AIDEVOPS_TEST_DIR || true
	return 0
}

test_set_uses_provided_stdin_value() {
	setup
	trap 'teardown' RETURN

	local output_file="$TEST_DIR/output.log"
	local exit_code=0
	printf '%s\n' 'actual-secret-value' | bash "$HELPER" set test-key >"$output_file" 2>&1 || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "set stores provided stdin value" 1 "Command failed (exit=$exit_code)"
		return 0
	fi

	local stored_value=""
	stored_value=$(<"$TEST_DIR/stored_value")

	local stored_path=""
	stored_path=$(<"$TEST_DIR/stored_path")

	if [[ "$stored_value" == "actual-secret-value" && "$stored_path" == "aidevops/TEST_KEY" ]]; then
		print_result "set stores provided stdin value" 0
	else
		print_result "set stores provided stdin value" 1 "stored_value='$stored_value' stored_path='$stored_path'"
	fi

	return 0
}

test_credentials_read_unescapes_special_chars() {
	local test_name="credentials.sh read path unescapes backslash and double-quote"

	# Simulate what the write path stores for value: foo\bar"baz
	# write: escaped_value="${value//\\/\\\\}"; escaped_value="${escaped_value//\"/\\\"}"
	# result: export KEY="foo\\bar\"baz"
	local stored_line='export ROUND_TRIP_KEY="foo\\bar\"baz"'

	# Apply the same sed pipeline as get_secret_value()
	local readback
	readback=$(printf '%s\n' "$stored_line" | sed 's/^export [^=]*=//' | sed 's/^"//' | sed 's/"$//' | sed 's/\\"/"/g' | sed 's/\\\\/\\/g')

	if [[ "$readback" == 'foo\bar"baz' ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "expected 'foo\\bar\"baz', got '$readback'"
	fi

	return 0
}

test_set_rejects_command_literal_input() {
	setup
	trap 'teardown' RETURN
	local test_name="set rejects command-literal input"

	local output_file="$TEST_DIR/output.log"
	local exit_code=0
	printf '%s\n' 'aidevops secret set TEST_KEY' | bash "$HELPER" set TEST_KEY >"$output_file" 2>&1 || exit_code=$?

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "$test_name" 1 "Expected non-zero exit code"
		return 0
	fi

	if [[ -f "$TEST_DIR/stored_value" ]]; then
		print_result "$test_name" 1 "Secret was unexpectedly stored"
		return 0
	fi

	if grep -q "looks like a command" "$output_file"; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "Missing rejection message"
	fi

	return 0
}

main() {
	echo "Running secret-helper regression tests..."
	echo ""

	test_set_uses_provided_stdin_value
	test_credentials_read_unescapes_special_chars
	test_set_rejects_command_literal_input

	echo ""
	echo "Tests run: $TESTS_RUN"
	echo "Passed:    $TESTS_PASSED"
	echo "Failed:    $TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
