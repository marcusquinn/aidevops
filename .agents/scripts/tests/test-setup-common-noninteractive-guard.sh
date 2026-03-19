#!/usr/bin/env bash
# shellcheck disable=SC1090

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COMMON_HELPER="${SCRIPT_DIR}/../setup/_common.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_skips_prompt_when_non_interactive_true() {
	local output=""
	local exit_code=0

	output=$(
		PATH="/usr/bin:/bin"
		NON_INTERACTIVE="true"
		READ_CALLED=0

		uname() {
			printf 'Linux\n'
			return 0
		}

		read() {
			READ_CALLED=1
			return 1
		}

		source "$COMMON_HELPER"
		ensure_homebrew </dev/null
		exit_code=$?
		printf 'exit=%s read=%s\n' "$exit_code" "$READ_CALLED"
		return 0
	) || true

	if [[ "$output" == *"exit=1 read=0"* ]]; then
		print_result "ensure_homebrew skips prompt when NON_INTERACTIVE=true" 0
		return 0
	fi

	print_result "ensure_homebrew skips prompt when NON_INTERACTIVE=true" 1 "output=${output}"
	return 0
}

test_skips_prompt_when_stdin_not_tty() {
	local output=""
	local exit_code=0

	output=$(
		PATH="/usr/bin:/bin"
		unset NON_INTERACTIVE
		READ_CALLED=0

		uname() {
			printf 'Linux\n'
			return 0
		}

		read() {
			READ_CALLED=1
			return 1
		}

		source "$COMMON_HELPER"
		ensure_homebrew </dev/null
		exit_code=$?
		printf 'exit=%s read=%s\n' "$exit_code" "$READ_CALLED"
		return 0
	) || true

	if [[ "$output" == *"exit=1 read=0"* ]]; then
		print_result "ensure_homebrew skips prompt when stdin is non-TTY" 0
		return 0
	fi

	print_result "ensure_homebrew skips prompt when stdin is non-TTY" 1 "output=${output}"
	return 0
}

main() {
	test_skips_prompt_when_non_interactive_true
	test_skips_prompt_when_stdin_not_tty

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
