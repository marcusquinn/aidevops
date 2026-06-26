#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for config-helper fallback config-home validation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CONFIG_HELPER="${SCRIPT_DIR}/../config-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		printf '%bPASS%b %s\n' "$GREEN" "$NC" "$name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%bFAIL%b %s — %s\n' "$RED" "$NC" "$name" "$detail"
	fi
	return 0
}

cleanup_tmp_dir() {
	local tmp_dir="${TMP_DIR:-}"
	local tmp_base="${tmp_dir##*/}"

	if [[ -z "$tmp_dir" || ! -d "$tmp_dir" ]]; then
		return 0
	fi
	if [[ "$tmp_base" != aidevops-config-home.* ]]; then
		printf 'Refusing to remove unexpected temp directory: %s\n' "$tmp_dir" >&2
		return 1
	fi

	rm -rf "$tmp_dir"
	return 0
}

run_validate_config_home() {
	local config_home="$1"
	_SHARED_CONSTANTS_LOADED=1 HOME="${TMP_DIR}/home" bash -c '
		# shellcheck source=/dev/null
		source "$1"
		_validate_config_home "$2"
	' _ "$CONFIG_HELPER" "$config_home"
	return $?
}

TMP_DIR=$(mktemp -d /tmp/aidevops-config-home.XXXXXX) || exit 1
trap cleanup_tmp_dir EXIT

broken_symlink="${TMP_DIR}/broken-link"
ln -s "${TMP_DIR}/missing-target" "$broken_symlink" || exit 1
output=$(run_validate_config_home "$broken_symlink" 2>&1)
rc=$?
if [[ "$rc" -ne 0 && "$output" == *'is a symlink'* ]]; then
	print_result "rejects broken symlink config home" 0
else
	print_result "rejects broken symlink config home" 1 "rc=${rc} output=${output}"
fi

fresh_dir="${TMP_DIR}/fresh-config-home"
output=$(run_validate_config_home "$fresh_dir" 2>&1)
rc=$?
mode=""
if [[ -d "$fresh_dir" ]]; then
	mode=$(stat -c '%a' "$fresh_dir" 2>/dev/null || stat -f '%Lp' "$fresh_dir" 2>/dev/null || true)
fi
if [[ "$rc" -eq 0 && -d "$fresh_dir" && "$mode" == "700" ]]; then
	print_result "creates missing tmp config home with secure mode" 0
else
	print_result "creates missing tmp config home with secure mode" 1 "rc=${rc} mode=${mode} output=${output}"
fi

printf '\nTests: %d run, %d passed, %d failed\n' "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
