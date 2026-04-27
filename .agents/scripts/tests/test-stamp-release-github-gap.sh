#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stamp-release-github-gap.sh (GH#21057)
#
# Synthetic regression test for the Phase 1 auto-release GitHub gap:
#   - _isc_release_claim_by_stamp_path MUST call _isc_cmd_release --unassign
#   - _isc_cmd_release MUST surface gh failures, not silently swallow them
#
# Usage:
#   bash .agents/scripts/tests/test-stamp-release-github-gap.sh
#
# No external dependencies. Uses a mocked gh and set_issue_status to avoid
# touching real GitHub repos. All tests self-contained; cleans up after itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ISH="${REPO_ROOT}/.agents/scripts/interactive-session-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_equals() {
	local desc="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		print_result "$desc" 0
	else
		print_result "$desc" 1 "expected='$expected' actual='$actual'"
	fi
	return 0
}

assert_contains() {
	local desc="$1" needle="$2" haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		print_result "$desc" 0
	else
		print_result "$desc" 1 "expected to contain '$needle'; got '$haystack'"
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	[[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
	return 0
}

# ---------------------------------------------------------------------------
# Helper: write a minimal stamp file for testing
# ---------------------------------------------------------------------------
write_stamp() {
	local stamp_dir="$1" issue="$2" slug="$3" pid="${4:-9999999}"
	mkdir -p "$stamp_dir"
	local slug_safe="${slug//\//-}"
	local stamp_path="${stamp_dir}/${slug_safe}-${issue}.json"
	printf '{"issue":"%s","slug":"%s","pid":%d}\n' "$issue" "$slug" "$pid" >"$stamp_path"
	printf '%s\n' "$stamp_path"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: _isc_release_claim_by_stamp_path passes --unassign to _isc_cmd_release
#
# Strategy: source the helper with CLAIM_STAMP_DIR pointing at our temp dir,
# stub _isc_cmd_release and _isc_gh_reachable so we can capture call args.
# ---------------------------------------------------------------------------
test_auto_release_passes_unassign() {
	local stamp_dir="${TEST_DIR}/stamps"
	local captured_args_file="${TEST_DIR}/captured_args"

	# Create a fake stamp
	local stamp_path
	stamp_path=$(write_stamp "$stamp_dir" "12345" "owner/repo")

	# Source helper in a subshell so stubs don't leak
	local result
	result=$(
		# Minimal stubs required to prevent actual network calls
		_isc_gh_reachable() { return 0; }
		_isc_current_user() { printf 'testuser'; return 0; }
		set_issue_status() {
			# Record what we were called with
			printf 'set_issue_status %s\n' "$*" >>"$captured_args_file"
			return 0
		}
		_isc_has_in_review() {
			# Pretend the issue IS in-review (rc=0)
			return 0
		}
		_isc_delete_stamp() { return 0; }
		_isc_info() { printf 'INFO: %s\n' "$*"; return 0; }
		_isc_warn() { printf 'WARN: %s\n' "$*"; return 0; }
		_isc_err() { printf 'ERR: %s\n' "$*"; return 0; }
		export -f _isc_gh_reachable _isc_current_user set_issue_status
		export -f _isc_has_in_review _isc_delete_stamp _isc_info _isc_warn _isc_err
		CLAIM_STAMP_DIR="$stamp_dir"
		export CLAIM_STAMP_DIR

		# Source only the functions we need (avoid full init)
		# We extract and eval the two target functions from the helper.
		eval "$(sed -n '/^_isc_cmd_release()/,/^}/p' "$ISH")"
		eval "$(sed -n '/^_isc_release_claim_by_stamp_path()/,/^}/p' "$ISH")"

		_isc_release_claim_by_stamp_path "$stamp_path"
		printf 'EXIT:%d\n' $?
	) 2>&1 || true

	# Verify: set_issue_status was called with --remove-assignee
	local captured=""
	[[ -f "$captured_args_file" ]] && captured=$(cat "$captured_args_file")

	assert_contains \
		"auto-release passes --remove-assignee to set_issue_status" \
		"--remove-assignee" \
		"$captured"

	assert_contains \
		"auto-release calls set_issue_status with available" \
		"available" \
		"$captured"

	return 0
}

# ---------------------------------------------------------------------------
# Test 2: _isc_cmd_release surfaces gh failures with actual error text
# (previously swallowed by >/dev/null 2>&1)
# ---------------------------------------------------------------------------
test_release_surfaces_failure_message() {
	local captured_warn_file="${TEST_DIR}/captured_warn"

	local result
	result=$(
		_isc_gh_reachable() { return 0; }
		_isc_current_user() { printf 'testuser'; return 0; }
		set_issue_status() {
			# Simulate a gh failure with an error message on stderr
			printf 'gh: HTTP 422: bad credentials\n' >&2
			return 1
		}
		_isc_has_in_review() { return 0; }
		_isc_delete_stamp() { return 0; }
		_isc_info() { printf 'INFO: %s\n' "$*"; return 0; }
		_isc_warn() {
			printf 'WARN: %s\n' "$*"
			printf '%s\n' "$*" >>"$captured_warn_file"
			return 0
		}
		_isc_err() { printf 'ERR: %s\n' "$*"; return 0; }
		export -f _isc_gh_reachable _isc_current_user set_issue_status
		export -f _isc_has_in_review _isc_delete_stamp _isc_info _isc_warn _isc_err

		eval "$(sed -n '/^_isc_cmd_release()/,/^}/p' "$ISH")"

		_isc_cmd_release "99999" "owner/repo"
		printf 'EXIT:%d\n' $?
	) 2>&1 || true

	local warn_content=""
	[[ -f "$captured_warn_file" ]] && warn_content=$(cat "$captured_warn_file")

	# The warning MUST contain the rc and the gh error text
	assert_contains \
		"release surfaces gh error rc in warning" \
		"rc=1" \
		"$warn_content"

	assert_contains \
		"release surfaces gh error message in warning" \
		"HTTP 422" \
		"$warn_content"

	# The function MUST still exit 0 (fail-open)
	assert_contains \
		"release exits 0 even on gh failure (fail-open)" \
		"EXIT:0" \
		"$result"

	return 0
}

# ---------------------------------------------------------------------------
# Test 3: _isc_release_claim_by_stamp_path skips gracefully on missing stamp
# ---------------------------------------------------------------------------
test_missing_stamp_is_noop() {
	local result
	result=$(
		_isc_gh_reachable() { return 0; }
		_isc_current_user() { printf 'testuser'; return 0; }
		set_issue_status() { printf 'SHOULD_NOT_BE_CALLED\n'; return 0; }
		_isc_has_in_review() { return 0; }
		_isc_delete_stamp() { return 0; }
		_isc_info() { printf 'INFO: %s\n' "$*"; return 0; }
		_isc_warn() { printf 'WARN: %s\n' "$*"; return 0; }
		_isc_err() { printf 'ERR: %s\n' "$*"; return 0; }
		export -f _isc_gh_reachable _isc_current_user set_issue_status
		export -f _isc_has_in_review _isc_delete_stamp _isc_info _isc_warn _isc_err

		eval "$(sed -n '/^_isc_release_claim_by_stamp_path()/,/^}/p' "$ISH")"

		_isc_release_claim_by_stamp_path "/nonexistent/stamp.json"
		printf 'EXIT:%d\n' $?
	) 2>&1 || true

	local status=0
	[[ "$result" == *"SHOULD_NOT_BE_CALLED"* ]] && status=1
	print_result "missing stamp is noop (does not call set_issue_status)" "$status"

	assert_contains "missing stamp exits 0" "EXIT:0" "$result"

	return 0
}

# ---------------------------------------------------------------------------
# Test 4: offline gh → stamp deleted locally, warning printed, exit 0
# ---------------------------------------------------------------------------
test_offline_gh_is_fail_open() {
	local stamp_dir="${TEST_DIR}/stamps_offline"
	local stamp_path
	stamp_path=$(write_stamp "$stamp_dir" "11111" "owner/repo2")

	local result
	result=$(
		_isc_gh_reachable() { return 1; }  # offline
		_isc_delete_stamp() {
			# Verify the stamp is actually deleted
			[[ -f "$stamp_path" ]] && rm -f "$stamp_path"
			return 0
		}
		_isc_info() { printf 'INFO: %s\n' "$*"; return 0; }
		_isc_warn() { printf 'WARN: %s\n' "$*"; return 0; }
		_isc_err() { printf 'ERR: %s\n' "$*"; return 0; }
		export -f _isc_gh_reachable _isc_delete_stamp _isc_info _isc_warn _isc_err

		eval "$(sed -n '/^_isc_cmd_release()/,/^}/p' "$ISH")"

		_isc_cmd_release "11111" "owner/repo2"
		printf 'EXIT:%d\n' $?
	) 2>&1 || true

	assert_contains "offline gh exits 0 (fail-open)" "EXIT:0" "$result"
	assert_contains "offline gh prints warning" "offline" "$result"

	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	setup

	printf 'Running GH#21057 regression tests (stamp-release GitHub gap)...\n\n'

	test_auto_release_passes_unassign
	test_release_surfaces_failure_message
	test_missing_stamp_is_noop
	test_offline_gh_is_fail_open

	printf '\n--- Results: %d/%d passed, %d failed ---\n' \
		"$TESTS_PASSED" "$TESTS_RUN" "$TESTS_FAILED"

	[[ "$TESTS_FAILED" -eq 0 ]] && exit 0
	exit 1
}

main "$@"
