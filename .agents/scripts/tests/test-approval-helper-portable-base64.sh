#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for portable approval comment decoding (GH#27703).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../approval-helper.sh
source "${SCRIPT_DIR}/approval-helper.sh"

TEST_ROOT="$(mktemp -d -t approval-portable-base64.XXXXXX)"
FLAG_LOG="${TEST_ROOT}/base64-flag"
TEST_UNAME="Linux"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

uname() {
	printf '%s\n' "$TEST_UNAME"
	return 0
}

base64() {
	local decode_flag="$1"
	printf '%s\n' "$decode_flag" >"$FLAG_LOG"
	if command base64 -d; then
		return 0
	fi
	return 1
}

_approval_classify_signed_comment() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local comment_id="$4"
	local body="$5"
	local pub_key="$6"
	local expected_head_sha="${7:-}"
	: "$target_type" "$target_number" "$slug" "$comment_id" "$pub_key" "$expected_head_sha"
	[[ "$body" == $'portable\tapproval\nbody' ]] || return 1
	printf 'VERIFIED\n'
	return 0
}

run_decode_case() {
	local os_name="$1"
	local expected_flag="$2"
	local comments_json result actual_flag
	TEST_UNAME="$os_name"
	comments_json=$(jq -cn --arg body $'portable\tapproval\nbody' '[{id: 42, body: $body}]')
	result=$(_approval_classify_marked_comments issue 123 owner/repo "$comments_json" unused-key "" 1)
	actual_flag=$(<"$FLAG_LOG")
	if [[ "$result" == "VERIFIED" && "$actual_flag" == "$expected_flag" ]]; then
		return 0
	fi
	return 1
}

run_decode_case Linux -d
run_decode_case Darwin -D

printf 'approval helper portable base64 tests passed\n'
