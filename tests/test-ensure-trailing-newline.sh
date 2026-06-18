#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

load_function() {
	awk '
	/^ensure_trailing_newline\(\) [{]/ { collect = 1 }
	collect {
		print
		depth += gsub(/[{]/, "{") - gsub(/[}]/, "}")
		if (depth == 0 && $0 ~ /^[[:space:]]*[}]/) {
			exit
		}
	}
	' "$REPO_DIR/aidevops.sh"
	return 0
}

eval "$(load_function)"

assert_file_content() {
	local file="$1"
	local expected="$2"
	local expected_file="$TMP_DIR/expected.txt"

	printf '%b' "$expected" >"$expected_file"
	if ! cmp -s "$file" "$expected_file"; then
		printf 'Expected %s to match expected content\n' "$file" >&2
		return 1
	fi
	return 0
}

with_newline="$TMP_DIR/with-newline.txt"
without_newline="$TMP_DIR/without-newline.txt"
empty_file="$TMP_DIR/empty.txt"

printf 'already newline\n' >"$with_newline"
printf 'missing newline' >"$without_newline"
: >"$empty_file"

ensure_trailing_newline "$with_newline"
ensure_trailing_newline "$without_newline"
ensure_trailing_newline "$empty_file"

assert_file_content "$with_newline" 'already newline\n'
assert_file_content "$without_newline" 'missing newline\n'
assert_file_content "$empty_file" ''

printf 'ensure_trailing_newline handles newline-present, newline-missing, and empty files\n'
