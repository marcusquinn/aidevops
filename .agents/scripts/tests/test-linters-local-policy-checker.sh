#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-linters-local-policy-checker.sh — secret-policy checker resolution tests

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VALIDATORS_SCRIPT="${TEST_SCRIPT_DIR}/../linters-local-validators.sh"
TEST_ROOT="$(mktemp -d)"
CONSUMER_ROOT="${TEST_ROOT}/consumer"
PROJECT_CHECKER="${CONSUMER_ROOT}/.agents/scripts/safety-policy-check.sh"
DEPLOYED_DIR="${TEST_ROOT}/deployed"
DEPLOYED_CHECKER="${DEPLOYED_DIR}/safety-policy-check.sh"
PATH_DIR="${TEST_ROOT}/path-bin"
PATH_CHECKER="${PATH_DIR}/safety-policy-check.sh"
POLICY_TEST_LOG="${TEST_ROOT}/policy.log"
SYSTEM_PATH="${BASH%/*}:/usr/bin:/bin"
TESTS_RUN=0
TESTS_FAILED=0

export POLICY_TEST_LOG

[[ -z "${BLUE+x}" ]] && BLUE=""
[[ -z "${NC+x}" ]] && NC=""

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message" >&2
	return 0
}

print_success() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

SCRIPT_DIR="${TEST_SCRIPT_DIR}/.."
# shellcheck source=../linters-local-validators.sh
source "$VALIDATORS_SCRIPT"

reset_fixture() {
	rm -rf "$CONSUMER_ROOT" "$DEPLOYED_DIR" "$PATH_DIR"
	mkdir -p "${CONSUMER_ROOT}/.agents/scripts" "$DEPLOYED_DIR" "$PATH_DIR"
	: >"$POLICY_TEST_LOG"
	return 0
}

write_checker() {
	local checker_path="$1"
	local marker="$2"
	local exit_code="$3"
	mkdir -p "${checker_path%/*}"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		"printf '%s\\n' '${marker}' >>\"\${POLICY_TEST_LOG:?}\"" \
		"exit ${exit_code}" >"$checker_path"
	chmod +x "$checker_path"
	return 0
}

assert_policy_check() {
	local test_name="$1"
	local expected_success="$2"
	local expected_log="$3"
	local deployed_dir="$4"
	local test_path="$5"
	local status=0
	local status_ok=false
	local actual_log=""

	: >"$POLICY_TEST_LOG"
	(
		cd "$CONSUMER_ROOT" || exit 99
		SCRIPT_DIR="$deployed_dir"
		PATH="$test_path"
		check_secret_policy >/dev/null 2>&1
	) || status=$?
	actual_log=$(<"$POLICY_TEST_LOG")

	if [[ "$expected_success" == "true" && "$status" -eq 0 ]]; then
		status_ok=true
	elif [[ "$expected_success" == "false" && "$status" -ne 0 ]]; then
		status_ok=true
	fi

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status_ok" == "true" && "$actual_log" == "$expected_log" ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s (status=%s, log=%q)\n' "$test_name" "$status" "$actual_log"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_project_override_precedence() {
	reset_fixture
	write_checker "$PROJECT_CHECKER" "project" 0
	write_checker "$DEPLOYED_CHECKER" "deployed" 0
	write_checker "$PATH_CHECKER" "path" 0
	assert_policy_check "project override takes precedence" true "project" "$DEPLOYED_DIR" "${PATH_DIR}:${SYSTEM_PATH}"
	return 0
}

test_deployed_sibling_fallback() {
	reset_fixture
	write_checker "$DEPLOYED_CHECKER" "deployed" 0
	write_checker "$PATH_CHECKER" "path" 0
	assert_policy_check "sparse consumer uses deployed sibling" true "deployed" "$DEPLOYED_DIR" "${PATH_DIR}:${SYSTEM_PATH}"
	return 0
}

test_path_fallback() {
	reset_fixture
	write_checker "$PATH_CHECKER" "path" 0
	assert_policy_check "PATH fallback uses executable regular file" true "path" "$DEPLOYED_DIR" "${PATH_DIR}:${SYSTEM_PATH}"
	return 0
}

test_missing_all_fails() {
	reset_fixture
	assert_policy_check "missing all candidates fails closed" false "" "$DEPLOYED_DIR" "$SYSTEM_PATH"
	return 0
}

test_non_executable_project_override_fails() {
	reset_fixture
	write_checker "$PROJECT_CHECKER" "project" 0
	chmod -x "$PROJECT_CHECKER"
	write_checker "$DEPLOYED_CHECKER" "deployed" 0
	write_checker "$PATH_CHECKER" "path" 0
	assert_policy_check "non-executable project override fails closed" false "" "$DEPLOYED_DIR" "${PATH_DIR}:${SYSTEM_PATH}"
	return 0
}

test_selected_checker_failure_propagates() {
	reset_fixture
	write_checker "$PROJECT_CHECKER" "project-failure" 7
	write_checker "$DEPLOYED_CHECKER" "deployed" 0
	assert_policy_check "selected checker failure remains blocking" false "project-failure" "$DEPLOYED_DIR" "$SYSTEM_PATH"
	return 0
}

test_path_directory_rejected() {
	reset_fixture
	mkdir -p "$PATH_CHECKER"
	assert_policy_check "PATH directory is rejected" false "" "$DEPLOYED_DIR" "${PATH_DIR}:${SYSTEM_PATH}"
	return 0
}

test_non_executable_path_file_rejected() {
	reset_fixture
	write_checker "$PATH_CHECKER" "path" 0
	chmod -x "$PATH_CHECKER"
	assert_policy_check "non-executable PATH file is rejected" false "" "$DEPLOYED_DIR" "${PATH_DIR}:${SYSTEM_PATH}"
	return 0
}

test_path_function_rejected() {
	reset_fixture
	safety-policy-check.sh() {
		return 0
	}
	assert_policy_check "shell function is rejected as a PATH checker" false "" "$DEPLOYED_DIR" "$SYSTEM_PATH"
	unset -f safety-policy-check.sh
	return 0
}

test_path_alias_rejected() {
	reset_fixture
	alias safety-policy-check.sh=':'
	assert_policy_check "shell alias is rejected as a PATH checker" false "" "$DEPLOYED_DIR" "$SYSTEM_PATH"
	unalias safety-policy-check.sh
	return 0
}

main() {
	test_project_override_precedence
	test_deployed_sibling_fallback
	test_path_fallback
	test_missing_all_fails
	test_non_executable_project_override_fails
	test_selected_checker_failure_propagates
	test_path_directory_rejected
	test_non_executable_path_file_rejected
	test_path_function_rejected
	test_path_alias_rejected

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
