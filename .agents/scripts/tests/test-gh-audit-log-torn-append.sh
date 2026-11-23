#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#38229: an interrupted audit append must not swallow
# the next event. A log whose last byte is not a newline is separated before the
# new record is written, so every later event stays parsable NDJSON and the
# anomaly scanner keeps reading the log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
LOG_HELPER="${SCRIPT_DIR}/../gh-audit-log-helper.sh"
TEST_ROOT=""

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

# Count lines that parse as NDJSON objects.
# Args: log_file
parsable_lines() {
	local log_file="$1"
	jq -Rr 'if (fromjson? | type) == "object" then . else empty end' <"$log_file" | wc -l | tr -d ' '
	return 0
}

TEST_ROOT="$(mktemp -d -t aidevops-gh-audit-torn-XXXXXX)"
TORN_LOG="${TEST_ROOT}/gh-audit.log"

# A truncated write: no trailing newline.
printf '%s' '{"ts":"2026-07-31T01' >"$TORN_LOG"

GH_AUDIT_LOG_FILE="$TORN_LOG" GH_AUDIT_QUIET=true \
	"$LOG_HELPER" record --op issue_edit --repo example/repo --number 7 \
	--caller-function main >/dev/null 2>&1 ||
	fail "record failed against a torn audit log"

total_lines="$(wc -l <"$TORN_LOG" | tr -d ' ')"
[[ "$total_lines" == "2" ]] ||
	fail "expected the torn line and the new event on separate lines, got ${total_lines}"
[[ "$(parsable_lines "$TORN_LOG")" == "1" ]] ||
	fail "the new event was not parsable after a torn predecessor"

last_number="$(tail -n 1 "$TORN_LOG" | jq -r '.number')"
[[ "$last_number" == "7" ]] || fail "the new event was corrupted by the torn predecessor"

# A newline-terminated log must not gain a blank separator line.
CLEAN_LOG="${TEST_ROOT}/clean-audit.log"
printf '%s\n' '{"ts":"2026-07-31T02:00:00Z","op":"issue_edit","repo":"example/repo","number":1,"suspicious":[]}' >"$CLEAN_LOG"
GH_AUDIT_LOG_FILE="$CLEAN_LOG" GH_AUDIT_QUIET=true \
	"$LOG_HELPER" record --op issue_edit --repo example/repo --number 8 \
	--caller-function main >/dev/null 2>&1 ||
	fail "record failed against a clean audit log"
[[ "$(wc -l <"$CLEAN_LOG" | tr -d ' ')" == "2" ]] ||
	fail "a newline-terminated log gained an extra line"
[[ "$(parsable_lines "$CLEAN_LOG")" == "2" ]] ||
	fail "a clean append produced unparsable NDJSON"

# Concurrent writers must not interleave into unparsable lines.
CONCURRENT_LOG="${TEST_ROOT}/concurrent-audit.log"
: >"$CONCURRENT_LOG"
for i in 1 2 3 4 5 6 7 8; do
	GH_AUDIT_LOG_FILE="$CONCURRENT_LOG" GH_AUDIT_QUIET=true \
		"$LOG_HELPER" record --op issue_edit --repo example/repo --number "$i" \
		--caller-function main >/dev/null 2>&1 &
done
wait
concurrent_total="$(wc -l <"$CONCURRENT_LOG" | tr -d ' ')"
[[ "$(parsable_lines "$CONCURRENT_LOG")" == "$concurrent_total" ]] ||
	fail "concurrent audit appends produced unparsable NDJSON"
[[ "$concurrent_total" == "8" ]] ||
	fail "expected 8 concurrent audit events, got ${concurrent_total}"

printf 'PASS: torn, clean, and concurrent audit appends stay parsable NDJSON\n'
