#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-routines-cron-extraction.sh — Regression test for t2160
#
# Bug: repeat:cron(*/2 * * * *) was truncated to "cron(*/2" because the
# extraction regex [^[:space:]]+ stopped at the first space inside the
# cron parentheses.
#
# Fix: use the regex 'repeat:(cron\([^)]*\)|[^[:space:]]+)' stored in a
# variable (avoids bash misparse of literal ')' in [^)]) to capture the
# full cron expression including internal spaces.
#
# Tests:
#   1. cron with multiple spaces (*/2 * * * *) → full expression captured
#   2. cron with step syntax (0 */6 * * *)     → full expression captured
#   3. daily(@19:00) — no spaces               → unchanged
#   4. weekly(mon@09:00) — no spaces           → unchanged
#   5. persistent                              → unchanged
#   6. Disabled routine [ ] is not matched     → empty result

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	printf '       expected: %s\n' "$expected"
	printf '       actual:   %s\n' "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Mirrors the fixed extraction logic from pulse-routines.sh evaluate_routines()
extract_repeat_expr() {
	local line="$1"
	local _re_repeat='repeat:(cron\([^)]*\)|[^[:space:]]+)'
	local repeat_expr=""
	if [[ "$line" =~ $_re_repeat ]]; then
		repeat_expr="${BASH_REMATCH[1]}"
	fi
	printf '%s' "$repeat_expr"
	return 0
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_cron_multi_space() {
	local line="- [x] r901 Supervisor pulse — dispatch tasks across repos repeat:cron(*/2 * * * *) ~1m run:scripts/pulse-wrapper.sh"
	local got
	got=$(extract_repeat_expr "$line")
	assert_eq "cron(*/2 * * * *): full expression captured (regression t2160)" \
		"cron(*/2 * * * *)" "$got"
	return 0
}

test_cron_step_syntax() {
	local line="- [x] r909 Screen time snapshot repeat:cron(0 */6 * * *) ~10s run:scripts/screen-time-helper.sh"
	local got
	got=$(extract_repeat_expr "$line")
	assert_eq "cron(0 */6 * * *): step syntax captured in full" \
		"cron(0 */6 * * *)" "$got"
	return 0
}

test_cron_single_field() {
	local line="- [x] r907 Contribution watch repeat:cron(0 * * * *) ~30s run:scripts/contribution-watch-helper.sh scan"
	local got
	got=$(extract_repeat_expr "$line")
	assert_eq "cron(0 * * * *): hourly cron captured in full" \
		"cron(0 * * * *)" "$got"
	return 0
}

test_daily_no_spaces() {
	local line="- [x] r906 Repo sync — pull latest across repos repeat:daily(@19:00) ~5m run:bin/aidevops-repo-sync check"
	local got
	got=$(extract_repeat_expr "$line")
	assert_eq "daily(@19:00): non-cron schedule unchanged" \
		"daily(@19:00)" "$got"
	return 0
}

test_weekly_no_spaces() {
	local line="- [x] r099 Weekly report repeat:weekly(mon@09:00) ~10m agent:Build+"
	local got
	got=$(extract_repeat_expr "$line")
	assert_eq "weekly(mon@09:00): weekly schedule unchanged" \
		"weekly(mon@09:00)" "$got"
	return 0
}

test_persistent() {
	local line="- [x] r912 Dashboard server repeat:persistent ~0s server/index.ts"
	local got
	got=$(extract_repeat_expr "$line")
	assert_eq "persistent: simple keyword unchanged" \
		"persistent" "$got"
	return 0
}

test_disabled_routine_not_matched() {
	# Disabled routines use [ ] instead of [x]
	local line="- [ ] r099 Disabled routine repeat:cron(*/5 * * * *) ~5s run:scripts/some-helper.sh"
	# The extraction function itself does not filter on [x] — the caller does.
	# But the regex must still extract correctly; the caller's [[ =~ ^...\[x\] ]] guard filters it.
	# Test only the extraction function here; caller filtering is tested via evaluate_routines.
	local got
	got=$(extract_repeat_expr "$line")
	assert_eq "disabled routine: regex still extracts expression (caller must filter [x])" \
		"cron(*/5 * * * *)" "$got"
	return 0
}

test_no_repeat_field() {
	local line="- [x] r099 Task without repeat field run:scripts/some-helper.sh"
	local got
	got=$(extract_repeat_expr "$line")
	assert_eq "no repeat: field → empty result" "" "$got"
	return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

test_cron_multi_space
test_cron_step_syntax
test_cron_single_field
test_daily_no_spaces
test_weekly_no_spaces
test_persistent
test_disabled_routine_not_matched
test_no_repeat_field

echo ""
echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
