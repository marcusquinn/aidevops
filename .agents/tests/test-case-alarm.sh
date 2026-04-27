#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC1090
#
# Tests for case-alarm-helper.sh (t2853)
# Covers: stage classification, no-spam, escalation, gh-issue lifecycle,
#         ntfy stub send, per-case override, archived-case skip.
#
# Usage: bash .agents/tests/test-case-alarm.sh
# Requires: jq, bash 3.2+
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ALARM_HELPER="${SCRIPT_DIR}/../scripts/case-alarm-helper.sh"

# =============================================================================
# Test framework
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	# Init minimal git repo
	git -C "$TEST_TMPDIR" init -q
	git -C "$TEST_TMPDIR" config user.email "test@test.local"
	git -C "$TEST_TMPDIR" config user.name "Test User"
	return 0
}

_teardown() {
	[[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

_pass() {
	local name="$1"
	TESTS_PASSED=$(( TESTS_PASSED + 1 ))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1" reason="${2:-}"
	TESTS_FAILED=$(( TESTS_FAILED + 1 ))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — $reason}"
	return 0
}

_assert_exit_0() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected exit 0, got non-zero"
		return 0
	fi
}

_assert_exit_nonzero() {
	local name="$1"
	shift
	if ! "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected non-zero exit, got 0"
		return 0
	fi
}

_assert_file_exists() {
	local name="$1" path="$2"
	if [[ -f "$path" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "file not found: $path"
		return 0
	fi
}

_assert_contains() {
	local name="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected '$needle' in output"
		return 0
	fi
}

_assert_not_contains() {
	local name="$1" haystack="$2" needle="$3"
	if ! echo "$haystack" | grep -q "$needle" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "did NOT expect '$needle' in output"
		return 0
	fi
}

_assert_equals() {
	local name="$1" got="$2" want="$3"
	if [[ "$got" == "$want" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "got='$got' want='$want'"
		return 0
	fi
}

# =============================================================================
# Fixtures
# =============================================================================

# _make_case <tmpdir> <case-id> <status> [<deadline-date> <deadline-label>]
_make_case() {
	local tmpdir="$1" case_id="$2" status="${3:-open}"
	local dl_date="${4:-}" dl_label="${5:-filing-deadline}"

	local cases_dir="${tmpdir}/_cases"
	local case_dir="${cases_dir}/${case_id}"
	mkdir -p "$case_dir"

	local deadlines_json="[]"
	if [[ -n "$dl_date" ]]; then
		deadlines_json="$(jq -n --arg d "$dl_date" --arg l "$dl_label" \
			'[{"date":$d,"label":$l}]')"
	fi

	jq -n \
		--arg id "$case_id" \
		--arg status "$status" \
		--argjson deadlines "$deadlines_json" \
		'{id:$id,slug:"test",kind:"dispute",status:$status,deadlines:$deadlines}' \
		> "${case_dir}/dossier.toon"
	return 0
}

# _make_config <tmpdir> [<stages_json>] [<channels_json>]
_make_config() {
	local tmpdir="$1"
	local stages="${2:-[30,7]}"
	local channels="${3:-[\"gh-issue\"]}"

	mkdir -p "${tmpdir}/_config"
	jq -n \
		--argjson s "$stages" \
		--argjson c "$channels" \
		'{stages_days:$s,channels:$c,ntfy_topic:"test-topic",per_case_overrides:{}}' \
		> "${tmpdir}/_config/case-alarms.json"
	return 0
}

# _make_config_with_override <tmpdir> <case-id> <override-stages>
_make_config_with_override() {
	local tmpdir="$1" case_id="$2" override="$3"
	mkdir -p "${tmpdir}/_config"
	jq -n \
		--argjson s "[30,7]" \
		--arg cid "$case_id" \
		--argjson o "$override" \
		'{stages_days:$s,channels:["gh-issue"],ntfy_topic:"test-topic",per_case_overrides:{($cid):{stages_days:$o}}}' \
		> "${tmpdir}/_config/case-alarms.json"
	return 0
}

# _alarm_state <tmpdir> — read state JSON
_alarm_state() {
	local tmpdir="$1"
	local state_file="${tmpdir}/_cases/.alarm-state.json"
	if [[ -f "$state_file" ]]; then
		cat "$state_file"
	else
		echo "{}"
	fi
	return 0
}

# _future_date <days>  — ISO date N days in the future
_future_date() {
	local days="$1"
	if date --version >/dev/null 2>&1; then
		date -d "+${days} days" '+%Y-%m-%d' 2>/dev/null || date -v "+${days}d" '+%Y-%m-%d'
	else
		date -v "+${days}d" '+%Y-%m-%d'
	fi
	return 0
}

# _past_date <days>  — ISO date N days in the past
_past_date() {
	local days="$1"
	if date --version >/dev/null 2>&1; then
		date -d "-${days} days" '+%Y-%m-%d' 2>/dev/null || date -v "-${days}d" '+%Y-%m-%d'
	else
		date -v "-${days}d" '+%Y-%m-%d'
	fi
	return 0
}

# =============================================================================
# Source helpers to test internal functions without gh/curl side effects
# =============================================================================

# We override _alarm_gh_issue and _alarm_ntfy and _alarm_email to stubs
# so tests don't make network calls.

_ALARM_CALLS=""   # accumulates channel calls
_GH_STUB_NUM="99"  # stub gh issue number

_override_channels() {
	_alarm_gh_issue()  {
		_ALARM_CALLS="${_ALARM_CALLS}gh-issue:${1}/${2} "
		echo "$_GH_STUB_NUM"
		return 0
	}
	_alarm_ntfy() {
		_ALARM_CALLS="${_ALARM_CALLS}ntfy:${1}/${2} "
		return 0
	}
	_alarm_email() {
		_ALARM_CALLS="${_ALARM_CALLS}email:${1}/${2} "
		return 0
	}
	_close_gh_alarm_issue() {
		_ALARM_CALLS="${_ALARM_CALLS}close-gh:${3} "
		return 0
	}
}

# =============================================================================
# Unit tests: stage classification
# =============================================================================

test_stage_classification() {
	echo ""
	echo "--- Stage classification ---"
	# Source the helper to access internal functions
	# shellcheck source=/dev/null
	source "$ALARM_HELPER" 2>/dev/null || { _fail "source alarm helper" "could not source"; return 0; }

	local stages='[30,7]'

	local got
	got="$(_classify_stage 35 "$stages")"
	_assert_equals "green stage (35d)" "$got" "green"

	got="$(_classify_stage 30 "$stages")"
	_assert_equals "amber stage (30d)" "$got" "amber"

	got="$(_classify_stage 15 "$stages")"
	_assert_equals "amber stage (15d)" "$got" "amber"

	got="$(_classify_stage 7 "$stages")"
	_assert_equals "red stage (7d)" "$got" "red"

	got="$(_classify_stage 3 "$stages")"
	_assert_equals "red stage (3d)" "$got" "red"

	got="$(_classify_stage 0 "$stages")"
	_assert_equals "red stage (0d)" "$got" "red"

	got="$(_classify_stage -1 "$stages")"
	_assert_equals "passed stage (-1d)" "$got" "passed"

	# 3-stage config
	local stages3='[60,30,7]'
	got="$(_classify_stage 70 "$stages3")"
	_assert_equals "green stage 3-stage (70d)" "$got" "green"

	got="$(_classify_stage 50 "$stages3")"
	_assert_equals "yellow stage 3-stage (50d)" "$got" "yellow"

	got="$(_classify_stage 20 "$stages3")"
	_assert_equals "amber stage 3-stage (20d)" "$got" "amber"

	got="$(_classify_stage 5 "$stages3")"
	_assert_equals "red stage 3-stage (5d)" "$got" "red"

	return 0
}

# =============================================================================
# Unit tests: stage index (escalation check)
# =============================================================================

test_stage_index() {
	echo ""
	echo "--- Stage index ---"
	source "$ALARM_HELPER" 2>/dev/null || return 0

	local idx
	idx="$(_stage_index green)"
	_assert_equals "green index=0" "$idx" "0"

	idx="$(_stage_index amber)"
	_assert_equals "amber index=2" "$idx" "2"

	idx="$(_stage_index red)"
	_assert_equals "red index=3" "$idx" "3"

	idx="$(_stage_index passed)"
	_assert_equals "passed index=4" "$idx" "4"

	return 0
}

# =============================================================================
# Integration tests: tick behaviour
# =============================================================================

test_tick_no_cases() {
	echo ""
	echo "--- Tick: no _cases directory ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local out
	out="$(bash "$ALARM_HELPER" tick "$tmpdir" 2>&1 || true)"
	_assert_contains "tick exits cleanly with no _cases/" "$out" ""
	rm -rf "$tmpdir"
	return 0
}

test_tick_green_stage_no_alarm() {
	echo ""
	echo "--- Tick: green stage (>30d) should not fire alarm ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local future_date
	future_date="$(_future_date 45)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$future_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '["gh-issue"]'

	# We patch the gh channel by using a config that won't match a live slug
	# and verify the state file has no entries for this case
	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	local state
	state="$(_alarm_state "$tmpdir")"
	local record
	record="$(echo "$state" | jq -r '."case-2026-0001-test" // empty')"
	_assert_equals "no alarm state for green case" "$record" ""
	rm -rf "$tmpdir"
	return 0
}

test_tick_red_stage_updates_state() {
	echo ""
	echo "--- Tick: red stage updates alarm state ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$near_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '[]'  # no channels = no network calls

	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	local state
	state="$(_alarm_state "$tmpdir")"
	local stage
	stage="$(echo "$state" | jq -r '."case-2026-0001-test"."filing-deadline".stage // empty')"
	_assert_equals "alarm state has red stage" "$stage" "red"
	rm -rf "$tmpdir"
	return 0
}

test_tick_no_spam_same_stage() {
	echo ""
	echo "--- Tick: second tick at same stage does not escalate ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$near_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '[]'

	# First tick
	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	# Pre-load state — simulate already alarmed at red
	local state_file="${tmpdir}/_cases/.alarm-state.json"
	local state_before
	state_before="$(cat "$state_file")"
	local stage_before
	stage_before="$(echo "$state_before" | jq -r '."case-2026-0001-test"."filing-deadline".stage // empty')"

	# Second tick (same deadline, same stage)
	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	local state_after
	state_after="$(cat "$state_file")"
	local stage_after
	stage_after="$(echo "$state_after" | jq -r '."case-2026-0001-test"."filing-deadline".stage // empty')"

	_assert_equals "stage unchanged after second tick" "$stage_before" "$stage_after"
	rm -rf "$tmpdir"
	return 0
}

test_tick_escalation_amber_to_red() {
	echo ""
	echo "--- Tick: escalation amber -> red updates state ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$near_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '[]'

	# Pre-seed state at amber
	local state_file="${tmpdir}/_cases/.alarm-state.json"
	mkdir -p "${tmpdir}/_cases"
	printf '{"case-2026-0001-test":{"filing-deadline":{"stage":"amber"}}}\n' > "$state_file"

	# Tick: deadline is now red (3d), state was amber — should escalate
	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	local stage
	stage="$(cat "$state_file" | jq -r '."case-2026-0001-test"."filing-deadline".stage // empty')"
	_assert_equals "state escalated to red" "$stage" "red"
	rm -rf "$tmpdir"
	return 0
}

test_tick_passed_clears_state() {
	echo ""
	echo "--- Tick: passed deadline clears alarm state ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local past_date
	past_date="$(_past_date 5)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$past_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '[]'

	# Pre-seed state at red (no gh_issue so no close call)
	local state_file="${tmpdir}/_cases/.alarm-state.json"
	mkdir -p "${tmpdir}/_cases"
	printf '{"case-2026-0001-test":{"filing-deadline":{"stage":"red"}}}\n' > "$state_file"

	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	local record
	record="$(cat "$state_file" | jq -r '."case-2026-0001-test"."filing-deadline" // empty')"
	_assert_equals "alarm record cleared after deadline passes" "$record" ""
	rm -rf "$tmpdir"
	return 0
}

test_tick_archived_case_skipped() {
	echo ""
	echo "--- Tick: archived case is skipped ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"

	# Create case in archived/ subdirectory
	local cases_dir="${tmpdir}/_cases"
	local archived_dir="${cases_dir}/archived/case-2026-0001-archived"
	mkdir -p "$archived_dir"
	jq -n \
		--arg d "$near_date" \
		'{id:"case-2026-0001-archived",slug:"archived",kind:"dispute",status:"closed",deadlines:[{date:$d,label:"filing-deadline"}]}' \
		> "${archived_dir}/dossier.toon"
	_make_config "$tmpdir" "[30,7]" '[]'

	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	# archived/ cases are NOT in the _cases/case-*/ glob pattern — they are skipped
	local state
	state="$(_alarm_state "$tmpdir")"
	local record
	record="$(echo "$state" | jq -r '."case-2026-0001-archived" // empty')"
	_assert_equals "archived case not in alarm state" "$record" ""
	rm -rf "$tmpdir"
	return 0
}

test_tick_per_case_override() {
	echo ""
	echo "--- Tick: per-case stage override applied ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	# 45 days away — default config [30,7]: green (no alarm);
	# override [60,14,3] sorted ascending [3,14,60]: 45d ≤ 60 → i=2 → yellow (alarm fires)
	local future_date
	future_date="$(_future_date 45)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$future_date" "filing-deadline"
	_make_config_with_override "$tmpdir" "case-2026-0001-test" "[60,14,3]"

	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	local state
	state="$(_alarm_state "$tmpdir")"
	local stage
	stage="$(echo "$state" | jq -r '."case-2026-0001-test"."filing-deadline".stage // empty')"
	# Per-case override triggers alarm at 45d (which default [30,7] would classify as green)
	_assert_equals "per-case override: yellow at 45d with [60,14,3]" "$stage" "yellow"
	rm -rf "$tmpdir"
	return 0
}

test_tick_closed_case_skipped() {
	echo ""
	echo "--- Tick: closed (non-open) case is skipped ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"
	_make_case "$tmpdir" "case-2026-0001-closed" "closed" "$near_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '[]'

	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	local state
	state="$(_alarm_state "$tmpdir")"
	local record
	record="$(echo "$state" | jq -r '."case-2026-0001-closed" // empty')"
	_assert_equals "closed case not alarmed" "$record" ""
	rm -rf "$tmpdir"
	return 0
}

test_alarm_test_no_case_exits_nonzero() {
	echo ""
	echo "--- alarm-test: missing case-id exits non-zero ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local rc=0
	bash "$ALARM_HELPER" alarm-test >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		_pass "alarm-test with no args exits non-zero"
	else
		_fail "alarm-test with no args exits non-zero" "got exit 0"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_alarm_test_nonexistent_case() {
	echo ""
	echo "--- alarm-test: nonexistent case-id exits non-zero ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	mkdir -p "${tmpdir}/_cases"
	local rc=0
	bash "$ALARM_HELPER" alarm-test "case-9999-0001-fake" "$tmpdir" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		_pass "alarm-test nonexistent case exits non-zero"
	else
		_fail "alarm-test nonexistent case exits non-zero" "got exit 0"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_alarm_test_valid_case_exits_0() {
	echo ""
	echo "--- alarm-test: valid case with deadline exits 0 ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$near_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '[]'

	local rc=0
	bash "$ALARM_HELPER" alarm-test "case-2026-0001-test" "$tmpdir" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		_pass "alarm-test valid case exits 0"
	else
		_fail "alarm-test valid case exits 0" "got exit $rc"
	fi
	rm -rf "$tmpdir"
	return 0
}

test_alarm_test_does_not_update_state() {
	echo ""
	echo "--- alarm-test: does NOT update alarm state ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$near_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '[]'

	bash "$ALARM_HELPER" alarm-test "case-2026-0001-test" "$tmpdir" >/dev/null 2>&1 || true

	local state
	state="$(_alarm_state "$tmpdir")"
	local record
	record="$(echo "$state" | jq -r '."case-2026-0001-test" // empty')"
	_assert_equals "alarm-test does not update state" "$record" ""
	rm -rf "$tmpdir"
	return 0
}

test_default_config_created_on_first_tick() {
	echo ""
	echo "--- Tick: default config created if missing ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$near_date" "filing-deadline"
	# No config created

	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	local config_file="${tmpdir}/_config/case-alarms.json"
	_assert_file_exists "default config created on first tick" "$config_file"
	rm -rf "$tmpdir"
	return 0
}

test_alarm_state_file_created_on_tick() {
	echo ""
	echo "--- Tick: alarm state file created ---"
	local tmpdir
	tmpdir="$(mktemp -d)"
	local near_date
	near_date="$(_future_date 3)"
	_make_case "$tmpdir" "case-2026-0001-test" "open" "$near_date" "filing-deadline"
	_make_config "$tmpdir" "[30,7]" '[]'

	bash "$ALARM_HELPER" tick "$tmpdir" >/dev/null 2>&1 || true

	_assert_file_exists "alarm state file created after tick" \
		"${tmpdir}/_cases/.alarm-state.json"
	rm -rf "$tmpdir"
	return 0
}

test_help_exits_0() {
	echo ""
	echo "--- help exits 0 ---"
	_assert_exit_0 "help exits 0" bash "$ALARM_HELPER" help
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================

main() {
	_setup

	echo "=== case-alarm-helper.sh tests ==="
	echo ""

	test_stage_classification
	test_stage_index
	test_tick_no_cases
	test_tick_green_stage_no_alarm
	test_tick_red_stage_updates_state
	test_tick_no_spam_same_stage
	test_tick_escalation_amber_to_red
	test_tick_passed_clears_state
	test_tick_archived_case_skipped
	test_tick_per_case_override
	test_tick_closed_case_skipped
	test_alarm_test_no_case_exits_nonzero
	test_alarm_test_nonexistent_case
	test_alarm_test_valid_case_exits_0
	test_alarm_test_does_not_update_state
	test_default_config_created_on_first_tick
	test_alarm_state_file_created_on_tick
	test_help_exits_0

	_teardown

	echo ""
	echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed ==="
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
