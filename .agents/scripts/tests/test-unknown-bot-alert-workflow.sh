#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/unknown-bot-alert.yml"

pass_count=0
fail_count=0

print_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	if [[ "$status" -eq 0 ]]; then
		printf 'ok - %s\n' "$name"
		pass_count=$((pass_count + 1))
		return 0
	fi
	printf 'not ok - %s' "$name"
	if [[ -n "$detail" ]]; then
		printf ' (%s)' "$detail"
	fi
	printf '\n'
	fail_count=$((fail_count + 1))
	return 1
}

assert_contains() {
	local name="$1"
	local needle="$2"
	if grep -Fq -- "$needle" "$WORKFLOW_FILE"; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "missing: $needle"
	return 1
}

assert_not_contains() {
	local name="$1"
	local needle="$2"
	if grep -Fq -- "$needle" "$WORKFLOW_FILE"; then
		print_result "$name" 1 "unexpected: $needle"
		return 1
	fi
	print_result "$name" 0
	return 0
}

test_comment_body_is_data_not_shell_source() {
	assert_contains "comment body is passed via environment" "COMMENT_BODY: \${{ github.event.comment.body }}"
	assert_contains "body length uses printf on env var" "BODY_LEN=\$(printf '%s' \"\$COMMENT_BODY\" | wc -c | tr -d ' ')"
	assert_not_contains "workflow does not inline raw comment body into run script" "echo -n \"\${{ github.event.comment.body }}\""
	return 0
}

test_missing_unknown_bot_label_does_not_break_workflow() {
	assert_contains "dedup search does not require unknown-bot label" "--search \"unknown bot: \$BOT_LOGIN in:title\""
	assert_not_contains "dedup no longer filters by missing unknown-bot label" '--label "unknown-bot"'
	assert_contains "issue creation builds optional labels" 'label_args=()'
	assert_contains "issue creation sends body through body-file" "--body-file \"\$body_file\""
	return 0
}

main() {
	if [[ ! -f "$WORKFLOW_FILE" ]]; then
		print_result "workflow exists" 1 "$WORKFLOW_FILE"
		return 1
	fi

	test_comment_body_is_data_not_shell_source
	test_missing_unknown_bot_label_does_not_break_workflow

	printf '\nPassed: %d, Failed: %d\n' "$pass_count" "$fail_count"
	if [[ "$fail_count" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
