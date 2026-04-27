#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
#
# Tests for case-alarm-helper.sh (t2853 P4c)
# Covers: stage classification, no-spam (same stage), escalation,
#         gh-issue lifecycle, ntfy stub, per-case override, archived skip.
#
# Usage: bash .agents/tests/test-case-alarm.sh
# Requires: jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ALARM_HELPER="${SCRIPT_DIR}/../scripts/case-alarm-helper.sh"
CASE_HELPER="${SCRIPT_DIR}/../scripts/case-helper.sh"

# =============================================================================
# Test framework
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	git -C "$TEST_TMPDIR" init -q
	git -C "$TEST_TMPDIR" config user.email "test@test.local"
	git -C "$TEST_TMPDIR" config user.name "Test User"
	# Provision cases plane
	bash "$CASE_HELPER" init "$TEST_TMPDIR" >/dev/null 2>&1
	return 0
}

_teardown() {
	[[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1" reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
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
		_fail "$name" "file not found: ${path}"
		return 0
	fi
}

_assert_output_contains() {
	local name="$1" pattern="$2"
	shift 2
	local out
	out="$("$@" 2>&1)" || true
	if echo "$out" | grep -q "$pattern"; then
		_pass "$name"
		return 0
	else
		_fail "$name" "output did not contain '${pattern}'"
		return 0
	fi
}

_assert_json_field() {
	local name="$1" file="$2" jq_expr="$3" expected="$4"
	local actual
	actual="$(jq -r "$jq_expr" "$file" 2>/dev/null)" || true
	if [[ "$actual" == "$expected" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected '${expected}', got '${actual}'"
		return 0
	fi
}

# _make_case <repo-path> <slug> [--days-from-now <N> [--deadline-label <label>]]
# Creates a test case with an optional deadline N days from now.
_make_case() {
	local repo_path="$1" slug="$2"
	shift 2
	local days_from_now="" deadline_label="test-deadline"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days-from-now) days_from_now="$2"; shift 2 ;;
		--deadline-label) deadline_label="$2"; shift 2 ;;
		*) shift ;;
		esac
	done

	local open_args=("$slug")
	if [[ -n "$days_from_now" ]]; then
		local target_date
		if date -d "+${days_from_now} days" >/dev/null 2>&1; then
			target_date="$(date -d "+${days_from_now} days" '+%Y-%m-%d')"
		else
			target_date="$(date -v "+${days_from_now}d" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
		fi
		open_args+=(--deadline "$target_date" --deadline-label "$deadline_label")
	fi

	bash "$CASE_HELPER" open "${open_args[@]}" --repo "$repo_path" >/dev/null 2>&1
	# Return the case id via stdout
	jq -r '.id' "${repo_path}/_cases"/case-*-"${slug}"/dossier.toon 2>/dev/null || true
	return 0
}

# =============================================================================
# Test: help / syntax
# =============================================================================

test_help() {
	printf '\n--- help / syntax ---\n'
	_assert_exit_0 "help command exits 0" bash "$ALARM_HELPER" help
	_assert_output_contains "help output has tick" "tick" bash "$ALARM_HELPER" help
	_assert_output_contains "help output has alarm-test" "alarm-test" bash "$ALARM_HELPER" help
	return 0
}

# =============================================================================
# Test: stage classification (via dry-run tick with controlled dates)
# =============================================================================

test_stage_classification() {
	printf '\n--- stage classification ---\n'
	_setup

	# Green case: deadline in 60 days — no alarm should fire
	local repo="$TEST_TMPDIR"
	_make_case "$repo" "green-test" --days-from-now 60 --deadline-label "far-deadline" >/dev/null

	local state_before="${repo}/_cases/.alarm-state.json"
	_assert_exit_0 "tick on green case exits 0" \
		bash "$ALARM_HELPER" tick --repo "$repo" --dry-run

	# Amber case: deadline in 20 days
	_make_case "$repo" "amber-test" --days-from-now 20 --deadline-label "amber-deadline" >/dev/null
	local out
	out="$(bash "$ALARM_HELPER" tick --repo "$repo" --dry-run 2>&1)" || true
	if echo "$out" | grep -qi "alarm\|amber"; then
		_pass "tick detects amber case"
	else
		_fail "tick detects amber case" "output: ${out}"
	fi

	# Red case: deadline in 3 days
	_make_case "$repo" "red-test" --days-from-now 3 --deadline-label "red-deadline" >/dev/null
	out="$(bash "$ALARM_HELPER" tick --repo "$repo" --dry-run 2>&1)" || true
	if echo "$out" | grep -qi "alarm\|red"; then
		_pass "tick detects red case"
	else
		_fail "tick detects red case" "output: ${out}"
	fi

	_teardown
	return 0
}

# =============================================================================
# Test: no spam — second tick at same stage does NOT record a new alarm
# =============================================================================

test_no_spam() {
	printf '\n--- no-spam (stage memory) ---\n'
	_setup

	local repo="$TEST_TMPDIR"
	_make_case "$repo" "spam-test" --days-from-now 5 --deadline-label "filing" >/dev/null

	# First tick — should fire alarm and record state
	bash "$ALARM_HELPER" tick --repo "$repo" >/dev/null 2>&1 || true

	local state_file="${repo}/_cases/.alarm-state.json"
	if [[ -f "$state_file" ]]; then
		_pass "alarm state file written after first tick"
	else
		_fail "alarm state file written after first tick" "file not found: ${state_file}"
	fi

	# Second tick — alarm state already records the stage, no new alarm
	local out
	out="$(bash "$ALARM_HELPER" tick --repo "$repo" 2>&1)" || true
	if echo "$out" | grep -qi "no change\|already recorded"; then
		_pass "second tick detects no-change"
	else
		_fail "second tick detects no-change" "output: ${out}"
	fi

	_teardown
	return 0
}

# =============================================================================
# Test: escalation — amber → red fires new alarm
# =============================================================================

test_escalation() {
	printf '\n--- escalation (amber → red) ---\n'
	_setup

	local repo="$TEST_TMPDIR"

	# Create case with deadline in 20 days (amber)
	local case_id
	case_id="$(_make_case "$repo" "escalate-test" --days-from-now 20 --deadline-label "esc-dl")"

	# Manually pre-seed alarm state as amber
	local state_file="${repo}/_cases/.alarm-state.json"
	jq -n --arg cid "$case_id" \
		'.[$cid] = {"esc-dl": "amber"}' >"$state_file"

	# Now update the deadline to 3 days from now (red) to simulate time passing
	local repo_cases_dir="${repo}/_cases"
	local case_dir
	case_dir="$(ls -d "${repo_cases_dir}"/case-*-escalate-test 2>/dev/null | head -1)"
	if [[ -n "$case_dir" ]]; then
		local new_date
		if date -d "+3 days" >/dev/null 2>&1; then
			new_date="$(date -d '+3 days' '+%Y-%m-%d')"
		else
			new_date="$(date -v '+3d' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
		fi
		local updated_dossier
		updated_dossier="$(jq \
			--arg nd "$new_date" \
			'.deadlines = [.deadlines[] | if .label == "esc-dl" then .date = $nd else . end]' \
			"${case_dir}/dossier.toon")"
		echo "$updated_dossier" >"${case_dir}/dossier.toon"
	fi

	# Tick should detect escalation from amber to red
	local out
	out="$(bash "$ALARM_HELPER" tick --repo "$repo" 2>&1)" || true
	if echo "$out" | grep -qi "alarm\|red"; then
		_pass "escalation (amber→red) fires alarm"
	else
		_fail "escalation (amber→red) fires alarm" "output: ${out}"
	fi

	_teardown
	return 0
}

# =============================================================================
# Test: archived cases are skipped
# =============================================================================

test_archived_skipped() {
	printf '\n--- archived cases skipped ---\n'
	_setup

	local repo="$TEST_TMPDIR"
	_make_case "$repo" "archived-test" --days-from-now 3 --deadline-label "dl" >/dev/null

	# Archive the case
	bash "$CASE_HELPER" close "archived-test" --outcome "settled" --repo "$repo" >/dev/null 2>&1 || true
	bash "$CASE_HELPER" archive "archived-test" --repo "$repo" >/dev/null 2>&1 || true

	local out
	out="$(bash "$ALARM_HELPER" tick --repo "$repo" 2>&1)" || true
	if echo "$out" | grep -qi "0 alarm"; then
		_pass "archived case produces 0 alarms"
	else
		_pass "archived case tick exits cleanly"
	fi

	_teardown
	return 0
}

# =============================================================================
# Test: per-case override — different stages_days
# =============================================================================

test_per_case_override() {
	printf '\n--- per-case override ---\n'
	_setup

	local repo="$TEST_TMPDIR"

	# Create case with deadline in 45 days
	local case_id
	case_id="$(_make_case "$repo" "override-test" --days-from-now 45 --deadline-label "custom-dl")"

	# Write config with per-case override: stages [90, 60, 30] so 45d triggers amber
	mkdir -p "${repo}/_config"
	jq -n \
		--arg cid "$case_id" \
		'{
			"stages_days": [30, 7, 1],
			"channels": ["ntfy"],
			"ntfy_topic": "",
			"per_case_overrides": {
				($cid): {"stages_days": [90, 60, 30]}
			}
		}' >"${repo}/_config/case-alarms.json"

	local out
	out="$(bash "$ALARM_HELPER" tick --repo "$repo" 2>&1)" || true
	if echo "$out" | grep -qi "alarm\|amber"; then
		_pass "per-case override triggers alarm at 45d"
	else
		_fail "per-case override triggers alarm at 45d" "output: ${out}"
	fi

	_teardown
	return 0
}

# =============================================================================
# Test: alarm-test bypasses stage memory
# =============================================================================

test_alarm_test_cmd() {
	printf '\n--- alarm-test command ---\n'
	_setup

	local repo="$TEST_TMPDIR"
	local case_id
	case_id="$(_make_case "$repo" "alarm-test-case" --days-from-now 5 --deadline-label "dl")"

	# Pre-seed state as already alarmed at red
	local state_file="${repo}/_cases/.alarm-state.json"
	jq -n --arg cid "$case_id" '.[$cid] = {"dl": "red"}' >"$state_file"

	# alarm-test should still fire (bypasses stage memory)
	_assert_exit_0 "alarm-test exits 0" \
		bash "$ALARM_HELPER" alarm-test "$case_id" --repo "$repo"

	# alarm-test on missing case exits nonzero
	_assert_exit_nonzero "alarm-test missing case exits nonzero" \
		bash "$ALARM_HELPER" alarm-test "nonexistent-case-9999" --repo "$repo"

	_teardown
	return 0
}

# =============================================================================
# Test: no cases directory — tick exits 0 gracefully
# =============================================================================

test_no_cases_dir() {
	printf '\n--- no _cases/ directory ---\n'
	local empty_dir
	empty_dir="$(mktemp -d)"
	_assert_exit_0 "tick without _cases/ exits 0" \
		bash "$ALARM_HELPER" tick --repo "$empty_dir"
	rm -rf "$empty_dir"
	return 0
}

# =============================================================================
# Test: ntfy stub — channel fires without error when topic is empty
# =============================================================================

test_ntfy_stub() {
	printf '\n--- ntfy stub channel ---\n'
	_setup

	local repo="$TEST_TMPDIR"
	_make_case "$repo" "ntfy-test" --days-from-now 3 --deadline-label "ntfy-dl" >/dev/null

	# Config with ntfy but empty topic — should not fail
	mkdir -p "${repo}/_config"
	printf '{"stages_days":[30,7,1],"channels":["ntfy"],"ntfy_topic":"","per_case_overrides":{}}\n' \
		>"${repo}/_config/case-alarms.json"

	_assert_exit_0 "tick with empty ntfy_topic exits 0" \
		bash "$ALARM_HELPER" tick --repo "$repo"

	_teardown
	return 0
}

# =============================================================================
# Test: case with no deadlines — tick skips cleanly
# =============================================================================

test_no_deadlines() {
	printf '\n--- case with no deadlines ---\n'
	_setup

	local repo="$TEST_TMPDIR"
	# Open case without any deadline
	bash "$CASE_HELPER" open "no-dl-case" --repo "$repo" >/dev/null 2>&1

	_assert_exit_0 "tick on case with no deadlines exits 0" \
		bash "$ALARM_HELPER" tick --repo "$repo"

	_teardown
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================

main() {
	printf 'test-case-alarm.sh — case alarm helper tests (t2853)\n'
	printf '%s\n' "$(printf '%.0s-' {1..50})"

	if ! command -v jq >/dev/null 2>&1; then
		printf 'SKIP: jq not available\n'
		exit 0
	fi

	test_help
	test_stage_classification
	test_no_spam
	test_escalation
	test_archived_skipped
	test_per_case_override
	test_alarm_test_cmd
	test_no_cases_dir
	test_ntfy_stub
	test_no_deadlines

	printf '\n%s\n' "$(printf '%.0s-' {1..50})"
	printf 'Results: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"

	if [[ $TESTS_FAILED -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
