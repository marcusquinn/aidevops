#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#23640.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../supply-chain-advisory-helper.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

make_tmpdir() {
	local tmpdir
	tmpdir=$(mktemp -d) || return 1
	printf '%s\n' "$tmpdir"
	return 0
}

prepare_test_dirs() {
	local test_name="$1"
	local tmpdir="$2"
	shift 2
	local paths=("$@")
	if mkdir -p "${paths[@]}"; then
		return 0
	fi
	print_result "$test_name" 1 "mkdir failed"
	rm -rf "$tmpdir"
	return 1
}

test_self_reference_only_scan_succeeds() {
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "self-reference-only scan exits cleanly" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "self-reference-only scan exits cleanly" "$tmpdir" \
		"${tmpdir}/.agents/reference" "${tmpdir}/.agents/scripts" || return 0
	printf '%s\n' 'Documented IOC: router_''init.js and gh-token-''monitor.' \
		>"${tmpdir}/.agents/reference/npm-supply-chain-response.md"
	printf '%s\n' 'readonly IOC_PATTERN="router_''init.js|gh-token-''monitor"' \
		>"${tmpdir}/.agents/scripts/supply-chain-advisory-helper.sh"

	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 0 ]] \
		&& [[ "$output" == *"known-safe scanner self-reference"* ]] \
		&& [[ "$output" != *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "self-reference-only scan exits cleanly" 0
	else
		print_result "self-reference-only scan exits cleanly" 1 "status=${status} output=${output}"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_relative_self_reference_only_scan_succeeds() {
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "relative self-reference-only scan exits cleanly" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "relative self-reference-only scan exits cleanly" "$tmpdir" \
		"${tmpdir}/.agents/reference" "${tmpdir}/.agents/scripts" || return 0
	printf '%s\n' 'Documented IOC: router_''init.js and gh-token-''monitor.' \
		>"${tmpdir}/.agents/reference/npm-supply-chain-response.md"
	printf '%s\n' 'readonly IOC_PATTERN="router_''init.js|gh-token-''monitor"' \
		>"${tmpdir}/.agents/scripts/supply-chain-advisory-helper.sh"

	local output
	local status=0
	output=$(cd "$tmpdir" && HOME="$tmpdir" bash "$HELPER_SCRIPT" scan .agents 2>&1) || status=$?
	if [[ "$status" -eq 0 ]] \
		&& [[ "$output" == *"known-safe scanner self-reference"* ]] \
		&& [[ "$output" != *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "relative self-reference-only scan exits cleanly" 0
	else
		print_result "relative self-reference-only scan exits cleanly" 1 "status=${status} output=${output}"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_single_file_self_reference_only_scan_succeeds() {
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "single-file self-reference-only scan exits cleanly" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "single-file self-reference-only scan exits cleanly" "$tmpdir" \
		"${tmpdir}/.agents/scripts" || return 0
	printf '%s\n' 'readonly IOC_PATTERN="router_''init.js|gh-token-''monitor"' \
		>"${tmpdir}/.agents/scripts/supply-chain-advisory-helper.sh"

	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "${tmpdir}/.agents/scripts/supply-chain-advisory-helper.sh" 2>&1) || status=$?
	if [[ "$status" -eq 0 ]] \
		&& [[ "$output" == *"known-safe scanner self-reference"* ]] \
		&& [[ "$output" != *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "single-file self-reference-only scan exits cleanly" 0
	else
		print_result "single-file self-reference-only scan exits cleanly" 1 "status=${status} output=${output}"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_non_self_ioc_scan_fails() {
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "non-self IOC scan still fails" 1 "mktemp failed"
		return 0
	}

	prepare_test_dirs "non-self IOC scan still fails" "$tmpdir" "${tmpdir}/docs" || return 0
	printf '%s\n' 'Suspicious artifact: router_''init.js' >"${tmpdir}/docs/evidence.md"

	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 1 ]] \
		&& [[ "$output" == *"docs/evidence.md"* ]] \
		&& [[ "$output" == *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "non-self IOC scan still fails" 0
	else
		print_result "non-self IOC scan still fails" 1 "status=${status} output=${output}"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_similar_agents_suffix_ioc_scan_fails() {
	local tmpdir
	tmpdir=$(make_tmpdir) || {
		print_result "similarly named agents directory still fails" 1 "mktemp failed"
		return 0
	}

	if ! prepare_test_dirs "similarly named agents directory still fails" "$tmpdir" \
		"${tmpdir}/not.agents/reference"; then
		return 0
	fi
	if ! printf '%s\n' 'Suspicious artifact: router_''init.js' >"${tmpdir}/not.agents/reference/npm-supply-chain-response.md"; then
		print_result "similarly named agents directory still fails" 1 "fixture write failed"
		rm -rf "$tmpdir"
		return 0
	fi

	local output
	local status=0
	output=$(HOME="$tmpdir" bash "$HELPER_SCRIPT" scan "$tmpdir" 2>&1) || status=$?
	if [[ "$status" -eq 1 ]] \
		&& [[ "$output" == *"not.agents/reference/npm-supply-chain-response.md"* ]] \
		&& [[ "$output" == *"Potential supply-chain compromise indicators found"* ]]; then
		print_result "similarly named agents directory still fails" 0
	else
		print_result "similarly named agents directory still fails" 1 "status=${status} output=${output}"
	fi
	rm -rf "$tmpdir"
	return 0
}

main() {
	test_self_reference_only_scan_succeeds
	test_relative_self_reference_only_scan_succeeds
	test_single_file_self_reference_only_scan_succeeds
	test_non_self_ioc_scan_fails
	test_similar_agents_suffix_ioc_scan_fails

	printf '\nTests run: %s, failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
