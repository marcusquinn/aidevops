#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
HELPER="${SCRIPT_DIR}/../cloudron-helper.sh"

tests_run=0
tests_failed=0

run_help_case() {
	local case_name="$1"
	shift
	local output=""
	local status=0

	output=$(bash "$HELPER" "$@" 2>&1) || status=$?
	tests_run=$((tests_run + 1))
	if [[ "$status" -eq 0 ]] &&
		[[ "$output" == *"Cloudron Helper Script"* ]] &&
		[[ "$output" != *"unbound variable"* ]]; then
		printf 'PASS: %s\n' "$case_name"
		return 0
	fi

	printf 'FAIL: %s (status=%s)\n%s\n' "$case_name" "$status" "$output" >&2
	tests_failed=$((tests_failed + 1))
	return 0
}

run_help_case "no arguments"
run_help_case "help command" help
run_help_case "short help flag" -h
run_help_case "long help flag" --help

printf 'Tests run: %d, failed: %d\n' "$tests_run" "$tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
exit 0
