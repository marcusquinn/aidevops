#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-setup-debt-helper.sh — unit tests for setup-debt-helper.sh
#
# Each test mounts a temporary HOME directory containing a fake
# ~/.aidevops/advisories/ tree, then asserts the helper's behaviour.
# verify-secret is NOT covered here — that path requires live gh CLI
# and is exercised manually during /setup-git operator testing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../setup-debt-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "FAIL: helper not executable at $HELPER" >&2
	exit 1
fi

# Per-test sandbox — each test calls _setup_sandbox; teardown is done by
# overwriting HOME on the next call and removing the trap directory at exit.
TEST_TMPDIR=""

_setup_sandbox() {
	TEST_TMPDIR="$(mktemp -d -t setup-debt-test.XXXXXX)"
	export HOME="$TEST_TMPDIR"
	mkdir -p "$HOME/.aidevops/advisories"
}

_teardown_sandbox() {
	if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
		rm -rf "$TEST_TMPDIR"
	fi
	TEST_TMPDIR=""
}

trap _teardown_sandbox EXIT

# Test runner
PASS=0
FAIL=0

_run_test() {
	local name="$1"
	local fn="$2"
	if "$fn"; then
		echo "  PASS: $name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $name" >&2
		FAIL=$((FAIL + 1))
	fi
	_teardown_sandbox
}

_assert_eq() {
	local expected="$1"
	local actual="$2"
	local msg="${3:-assertion}"
	if [[ "$expected" != "$actual" ]]; then
		echo "    $msg: expected '$expected', got '$actual'" >&2
		return 1
	fi
	return 0
}

_assert_empty() {
	local actual="$1"
	local msg="${2:-empty assertion}"
	if [[ -n "$actual" ]]; then
		echo "    $msg: expected empty, got '$actual'" >&2
		return 1
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------

test_zero_advisories_empty_summary() {
	_setup_sandbox
	local out
	out="$("$HELPER" summary)"
	_assert_empty "$out" "summary should be empty when no advisories"
}

test_zero_advisories_empty_toast() {
	_setup_sandbox
	local out
	out="$("$HELPER" summary --format=toast)"
	_assert_empty "$out" "toast format should be empty when no advisories"
}

test_zero_advisories_empty_list() {
	_setup_sandbox
	local out
	out="$("$HELPER" list-sync-pat-missing)"
	_assert_empty "$out" "list should be empty when no advisories"
}

test_single_advisory_human() {
	_setup_sandbox
	# Use a single-segment owner so the lastsplit reconstructs cleanly
	echo "[ADVISORY] SYNC_PAT not set for awardsapp/awardsapp" > "$HOME/.aidevops/advisories/sync-pat-awardsapp-awardsapp.advisory"
	local out
	out="$("$HELPER" summary --format=human)"
	# Expect: "1 SYNC_PAT advisory (awardsapp/awardsapp)"
	if [[ "$out" != *"1 SYNC_PAT"* || "$out" != *"awardsapp/awardsapp"* ]]; then
		echo "    expected count + slug, got: '$out'" >&2
		return 1
	fi
	return 0
}

test_single_advisory_toast() {
	_setup_sandbox
	echo "[ADVISORY] SYNC_PAT not set for awardsapp/awardsapp" > "$HOME/.aidevops/advisories/sync-pat-awardsapp-awardsapp.advisory"
	local out
	out="$("$HELPER" summary --format=toast)"
	# Expect: "[WARN] 1 repo needs SYNC_PAT setup — run /setup-git in OpenCode or Claude Code"
	# Singular subject-verb agreement: "1 repo needs" (NOT "1 repo need" / "1 repos needs").
	if [[ "$out" != "[WARN] 1 repo needs"* ]]; then
		echo "    expected '[WARN] 1 repo needs ...', got: '$out'" >&2
		return 1
	fi
	if [[ "$out" != *"/setup-git"* ]]; then
		echo "    expected /setup-git mention, got: '$out'" >&2
		return 1
	fi
	return 0
}

test_multi_advisory_count() {
	_setup_sandbox
	echo "[ADVISORY] X" > "$HOME/.aidevops/advisories/sync-pat-foo-bar.advisory"
	echo "[ADVISORY] X" > "$HOME/.aidevops/advisories/sync-pat-baz-qux.advisory"
	echo "[ADVISORY] X" > "$HOME/.aidevops/advisories/sync-pat-quux-quuz.advisory"
	local out
	out="$("$HELPER" summary --format=toast)"
	if [[ "$out" != "[WARN] 3 repos need"* ]]; then
		echo "    expected '3 repos need', got: '$out'" >&2
		return 1
	fi
	return 0
}

test_dismissed_advisory_excluded() {
	_setup_sandbox
	echo "[ADVISORY] X" > "$HOME/.aidevops/advisories/sync-pat-foo-bar.advisory"
	echo "[ADVISORY] X" > "$HOME/.aidevops/advisories/sync-pat-baz-qux.advisory"
	# Dismiss one
	echo "sync-pat-foo-bar" > "$HOME/.aidevops/advisories/dismissed.txt"
	local out
	out="$("$HELPER" summary --format=toast)"
	# Should count only the non-dismissed one
	if [[ "$out" != "[WARN] 1 repo need"* ]]; then
		echo "    expected 1 repo (other dismissed), got: '$out'" >&2
		return 1
	fi
}

test_list_returns_slugs() {
	_setup_sandbox
	echo "[ADVISORY] X" > "$HOME/.aidevops/advisories/sync-pat-foo-bar.advisory"
	echo "[ADVISORY] X" > "$HOME/.aidevops/advisories/sync-pat-baz-qux.advisory"
	local out
	out="$("$HELPER" list-sync-pat-missing | sort)"
	local expected
	expected="$(printf 'baz/qux\nfoo/bar\n')"
	_assert_eq "$expected" "$out" "list output mismatch"
}

test_json_format_structure() {
	_setup_sandbox
	if ! command -v jq >/dev/null 2>&1; then
		echo "    skipping json test (jq not installed)" >&2
		return 0
	fi
	echo "[ADVISORY] X" > "$HOME/.aidevops/advisories/sync-pat-foo-bar.advisory"
	local out count
	out="$("$HELPER" summary --format=json)"
	count="$(echo "$out" | jq -r '.count')"
	_assert_eq "1" "$count" "json count mismatch"
}

test_help_command() {
	_setup_sandbox
	local out
	out="$("$HELPER" help 2>&1 || true)"
	if [[ "$out" != *"setup-debt-helper.sh"* ]]; then
		echo "    expected help banner, got: '$out'" >&2
		return 1
	fi
	return 0
}

test_unknown_command_returns_error() {
	_setup_sandbox
	local rc=0
	"$HELPER" nonexistent >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		echo "    expected nonzero exit, got 0" >&2
		return 1
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

echo "=== test-setup-debt-helper.sh ==="

_run_test "zero advisories: empty human summary" test_zero_advisories_empty_summary
_run_test "zero advisories: empty toast line" test_zero_advisories_empty_toast
_run_test "zero advisories: empty list" test_zero_advisories_empty_list
_run_test "single advisory: human format" test_single_advisory_human
_run_test "single advisory: toast format with [WARN] + /setup-git" test_single_advisory_toast
_run_test "multiple advisories: pluralised count" test_multi_advisory_count
_run_test "dismissed advisory excluded from count" test_dismissed_advisory_excluded
_run_test "list returns reconstructed slugs" test_list_returns_slugs
_run_test "json format has expected structure" test_json_format_structure
_run_test "help command emits banner" test_help_command
_run_test "unknown command returns error" test_unknown_command_returns_error

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
