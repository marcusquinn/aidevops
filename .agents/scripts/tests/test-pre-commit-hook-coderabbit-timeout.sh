#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for optional CodeRabbit CLI pre-push review bounding.

set -u

_script_dir() {
	local _src="${BASH_SOURCE[0]}"
	while [[ -L "$_src" ]]; do
		local _dir
		_dir=$(cd -P "$(dirname "$_src")" && pwd)
		_src=$(readlink "$_src")
		[[ "$_src" != /* ]] && _src="${_dir}/${_src}"
	done
	cd -P "$(dirname "$_src")" && pwd
	return 0
}

TESTS_DIR=$(_script_dir)
REPO_ROOT=$(cd "${TESTS_DIR}/../../.." && pwd)
PRE_COMMIT_HOOK="${REPO_ROOT}/.agents/scripts/pre-commit-hook.sh"
TMP_DIR=""
TESTS_PASSED=0
TESTS_FAILED=0

setup_tmp() {
	TMP_DIR=$(mktemp -d)
	mkdir -p "${TMP_DIR}/bin"
	return 0
}

cleanup_tmp() {
	if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
		rm -rf "$TMP_DIR"
	fi
	TMP_DIR=""
	return 0
}

pass() {
	local name="$1"
	printf '[PASS] %s\n' "$name"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	return 0
}

fail() {
	local name="$1"
	local reason="$2"
	printf '[FAIL] %s: %s\n' "$name" "$reason" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

write_fake_coderabbit() {
	local body="$1"
	printf '%s\n' '#!/usr/bin/env bash' "$body" >"${TMP_DIR}/bin/coderabbit"
	chmod +x "${TMP_DIR}/bin/coderabbit"
	return 0
}

run_pre_push_with_fake_coderabbit() {
	(
		cd "$REPO_ROOT" || exit 1
		PATH="${TMP_DIR}/bin:${PATH}" \
			AIDEVOPS_CODERABBIT_CLI_REVIEW_TIMEOUT="${AIDEVOPS_CODERABBIT_CLI_REVIEW_TIMEOUT:-1}" \
			AIDEVOPS_SKIP_CODERABBIT_CLI_REVIEW="${AIDEVOPS_SKIP_CODERABBIT_CLI_REVIEW:-0}" \
			bash -c '
				set -euo pipefail
				# shellcheck disable=SC1090
				source "$1"
				check_secrets() { return 0; }
				check_quality_standards() { return 0; }
				main_pre_push
			' bash "$PRE_COMMIT_HOOK"
	)
	return $?
}

test_coderabbit_review_times_out_fail_open() {
	local name="CodeRabbit CLI review timeout is fail-open"
	setup_tmp
	write_fake_coderabbit 'sleep 5'

	local start end duration output status
	start=$(date +%s)
	status=0
	output=$(AIDEVOPS_CODERABBIT_CLI_REVIEW_TIMEOUT=1 run_pre_push_with_fake_coderabbit 2>&1) || status=$?
	end=$(date +%s)
	duration=$((end - start))

	if [[ $status -ne 0 ]]; then
		fail "$name" "expected exit 0, got ${status}; output=${output}"
	elif ((duration > 4)); then
		fail "$name" "expected bounded runtime <=4s, got ${duration}s"
	elif [[ "$output" != *"timed out after 1s"* ]]; then
		fail "$name" "missing timeout skip message; output=${output}"
	else
		pass "$name"
	fi
	cleanup_tmp
	return 0
}

test_coderabbit_review_skip_env_bypasses_only_optional_step() {
	local name="AIDEVOPS_SKIP_CODERABBIT_CLI_REVIEW bypasses optional review"
	setup_tmp
	write_fake_coderabbit 'exit 42'

	local output status
	status=0
	output=$(AIDEVOPS_SKIP_CODERABBIT_CLI_REVIEW=1 run_pre_push_with_fake_coderabbit 2>&1) || status=$?

	if [[ $status -ne 0 ]]; then
		fail "$name" "expected exit 0, got ${status}; output=${output}"
	elif [[ "$output" != *"AIDEVOPS_SKIP_CODERABBIT_CLI_REVIEW=1"* ]]; then
		fail "$name" "missing skip-env message; output=${output}"
	else
		pass "$name"
	fi
	cleanup_tmp
	return 0
}

main() {
	test_coderabbit_review_times_out_fail_open
	test_coderabbit_review_skip_env_bypasses_only_optional_step

	printf '\nTests passed: %s\n' "$TESTS_PASSED"
	printf 'Tests failed: %s\n' "$TESTS_FAILED"
	if [[ $TESTS_FAILED -eq 0 ]]; then
		return 0
	fi
	return 1
}

trap cleanup_tmp EXIT
main "$@"
