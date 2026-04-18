#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _interactive_pr_is_stale() and _interactive_pr_trigger_handover()
# (t2189).
#
# An origin:interactive PR that has sat idle past AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS
# without any active-session signal (no claim stamp, no status:* label on linked
# issue) must be handover-eligible so the worker pipeline (CI fix, conflict fix,
# review fix) can drive it to merge. The helpers isolate the staleness signal
# and the idempotent label+comment action.
#
# These tests exercise both helpers in isolation with a mock `gh` stub. No
# real repository is touched.

# Note: set -e removed intentionally. The test harness deliberately invokes
# helpers that return non-zero (e.g., _interactive_pr_is_stale returning 1 when
# a PR is fresh); under set -e those calls would abort the whole script before
# `$?` could be captured. Each test captures the return code explicitly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Mock state files reset between tests. The mock gh reads these to
# produce canned responses; tests mutate them to drive scenarios.
#   labels.txt            — pr labels (comma-separated, newline-terminated)
#   updated.txt           — PR updatedAt ISO timestamp
#   issue-state.txt       — "open" or "closed"
#   issue-labels-json.txt — JSON array of label names on linked issue
#   title.txt             — PR title (used by _extract_linked_issue fallback)
#   body.txt              — PR body (used by _extract_linked_issue primary)
reset_mock_state() {
	: >"$GH_LOG"
	printf 'origin:interactive' >"${TEST_ROOT}/labels.txt"
	# Default: 48h ago → idle
	local epoch_48h
	epoch_48h=$(( $(date +%s) - 48 * 3600 ))
	# Portable ISO-8601 UTC emit
	if date -u -r "$epoch_48h" "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
		date -u -r "$epoch_48h" "+%Y-%m-%dT%H:%M:%SZ" >"${TEST_ROOT}/updated.txt"
	else
		date -u -d "@$epoch_48h" "+%Y-%m-%dT%H:%M:%SZ" >"${TEST_ROOT}/updated.txt"
	fi
	printf 'open' >"${TEST_ROOT}/issue-state.txt"
	printf '[]' >"${TEST_ROOT}/issue-labels-json.txt"
	printf 't2189: test PR' >"${TEST_ROOT}/title.txt"
	printf 'Resolves #42' >"${TEST_ROOT}/body.txt"
	# Clean up any stamp files left by prior tests
	rm -rf "${TEST_ROOT}/interactive-claims"
	mkdir -p "${TEST_ROOT}/interactive-claims"
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG CLAIM_STAMP_DIR="${TEST_ROOT}/interactive-claims"

	# Install the mock gh stub from fixtures/ (kept out of this file to keep
	# setup_test_env under the 100-line function-complexity threshold).
	local mock_src="${SCRIPT_DIR}/fixtures/mock-gh-interactive-handover.sh"
	if [[ ! -f "$mock_src" ]]; then
		printf 'ERROR: mock gh fixture not found at %s\n' "$mock_src" >&2
		return 1
	fi
	cp "$mock_src" "${TEST_ROOT}/bin/gh"
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract helpers under test and eval them in this shell.
define_helpers_under_test() {
	local is_stale_src
	is_stale_src=$(awk '/^_interactive_pr_is_stale\(\) \{/,/^\}$/ { print }' "$MERGE_SCRIPT")
	if [[ -z "$is_stale_src" ]]; then
		printf 'ERROR: could not extract _interactive_pr_is_stale from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$is_stale_src"

	local handover_src
	handover_src=$(awk '/^_interactive_pr_trigger_handover\(\) \{/,/^\}$/ { print }' "$MERGE_SCRIPT")
	if [[ -z "$handover_src" ]]; then
		printf 'ERROR: could not extract _interactive_pr_trigger_handover from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$handover_src"

	local extract_src
	extract_src=$(awk '/^_extract_linked_issue\(\) \{/,/^\}$/ { print }' "$MERGE_SCRIPT")
	if [[ -z "$extract_src" ]]; then
		printf 'ERROR: could not extract _extract_linked_issue from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$extract_src"

	# Stub _gh_idempotent_comment — records a call and returns success.
	_gh_idempotent_comment() {
		printf '_gh_idempotent_comment pr=%s repo=%s marker=%s\n' "$1" "$2" "$3" >>"${TEST_ROOT}/idempotent-comments.log"
		return 0
	}
	return 0
}

# =============================================================================
# Tests — _interactive_pr_is_stale
# =============================================================================

test_A_fresh_pr_returns_not_stale() {
	reset_mock_state
	# Override: PR updated 2h ago — fresh
	local epoch_2h
	epoch_2h=$(( $(date +%s) - 2 * 3600 ))
	if date -u -r "$epoch_2h" "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
		date -u -r "$epoch_2h" "+%Y-%m-%dT%H:%M:%SZ" >"${TEST_ROOT}/updated.txt"
	else
		date -u -d "@$epoch_2h" "+%Y-%m-%dT%H:%M:%SZ" >"${TEST_ROOT}/updated.txt"
	fi
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=enforce _interactive_pr_is_stale "100" "owner/repo"
	local rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "A: fresh PR (2h old) returns not-stale" 0
	else
		print_result "A: fresh PR (2h old) returns not-stale" 1 "Expected 1, got $rc"
	fi
	return 0
}

test_B_stamp_present_returns_not_stale() {
	reset_mock_state
	# Create a stamp for the linked issue #42 in slug owner/repo → slug_flat=owner-repo
	echo '{"pid":12345}' >"${TEST_ROOT}/interactive-claims/owner-repo-42.json"
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=enforce _interactive_pr_is_stale "100" "owner/repo"
	local rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "B: live claim stamp blocks handover" 0
	else
		print_result "B: live claim stamp blocks handover" 1 "Expected 1, got $rc"
	fi
	return 0
}

test_C_active_status_label_returns_not_stale() {
	reset_mock_state
	printf '["status:in-review"]' >"${TEST_ROOT}/issue-labels-json.txt"
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=enforce _interactive_pr_is_stale "100" "owner/repo"
	local rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "C: linked issue with status:in-review blocks handover" 0
	else
		print_result "C: linked issue with status:in-review blocks handover" 1 "Expected 1, got $rc"
	fi
	return 0
}

test_D_idle_no_stamp_no_status_returns_stale() {
	reset_mock_state
	# Defaults: 48h old, open issue, no status labels, no stamp
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=enforce _interactive_pr_is_stale "100" "owner/repo"
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "D: idle PR with no stamp and no active status returns stale" 0
	else
		print_result "D: idle PR with no stamp and no active status returns stale" 1 "Expected 0, got $rc"
	fi
	return 0
}

test_E_missing_origin_interactive_returns_not_stale() {
	reset_mock_state
	printf 'origin:worker,enhancement' >"${TEST_ROOT}/labels.txt"
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=enforce _interactive_pr_is_stale "100" "owner/repo"
	local rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "E: PR without origin:interactive returns not-stale" 0
	else
		print_result "E: PR without origin:interactive returns not-stale" 1 "Expected 1, got $rc"
	fi
	return 0
}

test_F_mode_off_returns_not_stale_unconditionally() {
	reset_mock_state
	# Mode off should short-circuit even when all other gates pass
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=off _interactive_pr_is_stale "100" "owner/repo"
	local rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "F: mode=off returns not-stale unconditionally" 0
	else
		print_result "F: mode=off returns not-stale unconditionally" 1 "Expected 1, got $rc"
	fi
	return 0
}

test_G_mode_detect_logs_and_returns_stale() {
	reset_mock_state
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=detect _interactive_pr_is_stale "100" "owner/repo"
	local rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_result "G: mode=detect returns stale signal on idle PR" 1 "Expected 0, got $rc"
		return 0
	fi
	if ! grep -q "would-handover: PR #100 in owner/repo" "$LOGFILE"; then
		print_result "G: mode=detect logs would-handover line" 1 "Expected log line not found"
		return 0
	fi
	print_result "G: mode=detect logs would-handover + returns stale" 0
	return 0
}

# =============================================================================
# Tests — _interactive_pr_trigger_handover
# =============================================================================

test_H_mode_detect_is_noop() {
	reset_mock_state
	: >"${TEST_ROOT}/idempotent-comments.log"
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=detect _interactive_pr_trigger_handover "100" "owner/repo"
	# Should not issue any label-add or comment call
	if grep -q "issue edit" "$GH_LOG"; then
		print_result "H: mode=detect does not apply label" 1 "issue edit seen in mock log"
		return 0
	fi
	if [[ -s "${TEST_ROOT}/idempotent-comments.log" ]]; then
		print_result "H: mode=detect does not post comment" 1 "comment call recorded"
		return 0
	fi
	print_result "H: mode=detect is a no-op" 0
	return 0
}

test_I_mode_enforce_applies_label_and_posts_comment() {
	reset_mock_state
	: >"${TEST_ROOT}/idempotent-comments.log"
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=enforce _interactive_pr_trigger_handover "100" "owner/repo"
	# Mock records label add when it sees origin:worker-takeover
	if ! grep -q "issue edit 100 --repo owner/repo --add-label origin:worker-takeover" "$GH_LOG"; then
		print_result "I: mode=enforce applies origin:worker-takeover label" 1 \
			"Expected label add in gh log. Got: $(cat "$GH_LOG")"
		return 0
	fi
	# _gh_idempotent_comment stub records one call
	if ! grep -q "marker=<!-- pulse-interactive-handover -->" "${TEST_ROOT}/idempotent-comments.log"; then
		print_result "I: mode=enforce posts handover comment" 1 \
			"Expected marker in comment log"
		return 0
	fi
	print_result "I: mode=enforce applies label and posts one comment" 0
	return 0
}

test_J_enforce_is_idempotent_when_label_already_present() {
	reset_mock_state
	# Pre-apply label — trigger_handover should short-circuit
	printf 'origin:interactive,origin:worker-takeover' >"${TEST_ROOT}/labels.txt"
	: >"${TEST_ROOT}/idempotent-comments.log"
	AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE=enforce _interactive_pr_trigger_handover "100" "owner/repo"
	# Should NOT call issue edit again
	if grep -q "issue edit" "$GH_LOG"; then
		print_result "J: idempotent — no re-add when label already present" 1 \
			"Unexpected issue edit call: $(cat "$GH_LOG")"
		return 0
	fi
	# Should NOT post a second comment
	if [[ -s "${TEST_ROOT}/idempotent-comments.log" ]]; then
		print_result "J: idempotent — no second comment" 1 "Unexpected comment call"
		return 0
	fi
	print_result "J: idempotent when label already present" 0
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	if [[ ! -f "$MERGE_SCRIPT" ]]; then
		printf 'ERROR: pulse-merge.sh not found at %s\n' "$MERGE_SCRIPT" >&2
		exit 1
	fi

	setup_test_env
	trap teardown_test_env EXIT

	define_helpers_under_test || {
		printf 'ERROR: could not define helpers under test\n' >&2
		exit 1
	}

	test_A_fresh_pr_returns_not_stale
	test_B_stamp_present_returns_not_stale
	test_C_active_status_label_returns_not_stale
	test_D_idle_no_stamp_no_status_returns_stale
	test_E_missing_origin_interactive_returns_not_stale
	test_F_mode_off_returns_not_stale_unconditionally
	test_G_mode_detect_logs_and_returns_stale
	test_H_mode_detect_is_noop
	test_I_mode_enforce_applies_label_and_posts_comment
	test_J_enforce_is_idempotent_when_label_already_present

	printf '\n=== %d test(s), %d failure(s) ===\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
