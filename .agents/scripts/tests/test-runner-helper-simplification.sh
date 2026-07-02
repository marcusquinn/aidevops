#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-runner-helper-simplification.sh — Regression guard for GH#5750

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../runner-helper.sh"
THRESHOLD="${COMPLEXITY_FUNC_LINE_THRESHOLD:-100}"

measure_function_lines() {
	local function_name="$1"
	awk -v target="${function_name}() {" '
		index($0, target) == 1 {
			in_func = 1
			next
		}
		in_func {
			line_count++
			if ($0 ~ /^\}/) {
				print line_count - 1
				exit
			}
		}
	' "$HELPER"
	return 0
}

assert_under_threshold() {
	local function_name="$1"
	local lines
	lines="$(measure_function_lines "$function_name")"

	if [[ -z "$lines" ]]; then
		printf 'FAIL %s not found in runner-helper.sh\n' "$function_name" >&2
		return 1
	fi

	if [[ "$lines" -gt "$THRESHOLD" ]]; then
		printf 'FAIL %s is %s lines, threshold is %s\n' "$function_name" "$lines" "$THRESHOLD" >&2
		return 1
	fi

	printf 'PASS %s is %s lines (<= %s)\n' "$function_name" "$lines" "$THRESHOLD"
	return 0
}

assert_under_threshold "cmd_create"
assert_under_threshold "cmd_run"
