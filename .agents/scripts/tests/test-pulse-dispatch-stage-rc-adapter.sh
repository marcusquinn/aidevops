#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../pulse-dispatch-lib.sh
source "$SCRIPT_DIR/../pulse-dispatch-lib.sh"

TMP_DIR=$(mktemp -d)
cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

return_three() {
	return 3
}

return_seven() {
	return 7
}

assert_adapter_rc() {
	local expected_rc="$1"
	local rc_file="$2"
	shift 2

	local actual_rc=0
	_dispatch_stage_rc_adapter "$rc_file" "$@" || actual_rc=$?
	if [[ "$actual_rc" -ne "$expected_rc" ]]; then
		printf 'FAIL expected adapter rc=%s actual=%s rc_file=%s\n' "$expected_rc" "$actual_rc" "$rc_file" >&2
		return 1
	fi
	return 0
}

assert_file_content() {
	local expected="$1"
	local file_path="$2"
	local actual

	actual=$(<"$file_path")
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL expected %s in %s actual=%s\n' "$expected" "$file_path" "$actual" >&2
		return 1
	fi
	return 0
}

benign_rc_file="$TMP_DIR/benign.rc"
assert_adapter_rc 0 "$benign_rc_file" return_three
assert_file_content 3 "$benign_rc_file"

failure_rc_file="$TMP_DIR/failure.rc"
assert_adapter_rc 7 "$failure_rc_file" return_seven
assert_file_content 7 "$failure_rc_file"

unwritable_rc_file="/dev/null/dispatch.rc"
assert_adapter_rc 3 "$unwritable_rc_file" return_three

printf 'PASS pulse-dispatch-stage-rc-adapter\n'
