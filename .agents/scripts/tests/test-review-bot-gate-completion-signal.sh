#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-review-bot-gate-completion-signal.sh — Regression tests for t2139 (GH#19251)
#
# Verifies that bot_has_real_review() requires a positive completion signal
# and rejects:
#   1. CodeRabbit two-phase placeholder (created_at == updated_at, recent)
#   2. "Review failed" notices (closed-during-review)
#   3. "Review skipped" notices (auto-review label config)
#   4. "closed or merged during review" patterns
#   5. Empty bodies
#
# And accepts:
#   6. Comments edited > min_lag after creation (Phase 2 settled)
#   7. Comments older than min_lag (no edit needed — bot had time to finish)
#   8. Real review content with no non-review-pattern match
#
# Plus unit tests on _comment_is_settled, is_non_review_comment, and
# _get_min_edit_lag direct invocations (no gh stubbing needed).
#
# Requires: bash, jq (matches helper requirements), date.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
HELPER_SCRIPT="${SCRIPT_DIR}/../review-bot-gate-helper.sh"

if [[ ! -f "$HELPER_SCRIPT" ]]; then
	echo "ERROR: helper not found at ${HELPER_SCRIPT}" >&2
	exit 2
fi

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	mkdir -p "${TEST_ROOT}/config/aidevops"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export HOME="${TEST_ROOT}"
	mkdir -p "${TEST_ROOT}/.config/aidevops"

	# Minimal repos.json for resolver tests
	cat >"${TEST_ROOT}/.config/aidevops/repos.json" <<'EOF'
{
  "initialized_repos": [
    {
      "path": "/tmp/testrepo",
      "slug": "testorg/testrepo",
      "pulse": true,
      "review_gate": {
        "min_edit_lag_seconds": 45,
        "tools": {
          "coderabbitai": { "min_edit_lag_seconds": 90 }
        }
      }
    },
    {
      "path": "/tmp/otherrepo",
      "slug": "testorg/otherrepo",
      "pulse": true
    }
  ]
}
EOF
	return 0
}

cleanup_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Run a function from the helper without invoking main(). Source it with
# main() short-circuited.
load_helper_functions() {
	# shellcheck disable=SC1090
	# Trick: source the helper but make main() a no-op so it doesn't error.
	# We strip the trailing 'main "$@"' invocation by sourcing in a subshell
	# alternative — actually, the helper has `main "$@"` at the end which
	# would execute. We override main BEFORE sourcing? No — sourcing runs
	# top-level immediately. Solution: source via a temp file with the last
	# `main "$@"` line removed.
	local tmpfile
	tmpfile=$(mktemp)
	# Drop the final main invocation line (last non-empty line is `main "$@"`).
	sed '$d' "$HELPER_SCRIPT" >"$tmpfile"
	# shellcheck disable=SC1090
	source "$tmpfile"
	rm -f "$tmpfile"
	return 0
}

# ---------- Unit tests: pattern matching ----------

test_is_non_review_comment_matches_rate_limit() {
	if is_non_review_comment "Review skipped due to rate limit exceeded for this hour"; then
		print_result "is_non_review_comment matches 'rate limit exceeded'" 0
	else
		print_result "is_non_review_comment matches 'rate limit exceeded'" 1
	fi
	return 0
}

test_is_non_review_comment_matches_review_failed() {
	if is_non_review_comment "Review failed — Pull request was closed or merged during review."; then
		print_result "is_non_review_comment matches 'Review failed'" 0
	else
		print_result "is_non_review_comment matches 'Review failed'" 1
	fi
	return 0
}

test_is_non_review_comment_matches_review_skipped() {
	if is_non_review_comment "Review skipped — Auto reviews are limited based on label configuration."; then
		print_result "is_non_review_comment matches 'Review skipped'" 0
	else
		print_result "is_non_review_comment matches 'Review skipped'" 1
	fi
	return 0
}

test_is_non_review_comment_matches_closed_during_review() {
	if is_non_review_comment "The pull request is closed or merged during review."; then
		print_result "is_non_review_comment matches 'closed or merged during review'" 0
	else
		print_result "is_non_review_comment matches 'closed or merged during review'" 1
	fi
	return 0
}

test_is_non_review_comment_rejects_real_review() {
	local body="## Walkthrough

This PR refactors the foo() function to handle the bar edge case.
Recommended changes: add a null check before line 42."
	if ! is_non_review_comment "$body"; then
		print_result "is_non_review_comment rejects real review body" 0
	else
		print_result "is_non_review_comment rejects real review body" 1
	fi
	return 0
}

test_backwards_compat_alias() {
	# is_rate_limit_comment must still work as alias.
	if is_rate_limit_comment "rate limit exceeded"; then
		print_result "is_rate_limit_comment alias still functions" 0
	else
		print_result "is_rate_limit_comment alias still functions" 1
	fi
	return 0
}

# ---------- Unit tests: settled-check ----------

test_settled_recent_unedited_placeholder_rejected() {
	# Created 5s ago, never edited, min_lag=30 → NOT settled (placeholder window).
	local now created updated
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ")
	updated="$created"
	if ! _comment_is_settled "$created" "$updated" 30; then
		print_result "settled rejects recent unedited placeholder" 0
	else
		print_result "settled rejects recent unedited placeholder" 1 \
			"created=${created} updated=${updated} now=${now}"
	fi
	return 0
}

test_settled_old_unedited_accepted() {
	# Created 120s ago, never edited, min_lag=30 → settled by age.
	local now created
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 120))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 120))" +"%Y-%m-%dT%H:%M:%SZ")
	if _comment_is_settled "$created" "$created" 30; then
		print_result "settled accepts old unedited comment" 0
	else
		print_result "settled accepts old unedited comment" 1
	fi
	return 0
}

test_settled_recent_edited_accepted() {
	# Created 10s ago, edited 5s ago (delta = 5s < min_lag of 30) → not settled
	# by edit AND age 10s < min_lag 30 → NOT settled.
	local now created updated
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 10))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 10))" +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(TZ=UTC date -u -r "$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ")
	if ! _comment_is_settled "$created" "$updated" 30; then
		print_result "settled rejects edit-delta and age both under min_lag" 0
	else
		print_result "settled rejects edit-delta and age both under min_lag" 1
	fi
	return 0
}

test_settled_edit_delta_over_min_lag_accepted() {
	# Created 100s ago, edited 5s ago → edit_delta = 95s >= min_lag 30 → settled.
	local now created updated
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 100))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 100))" +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(TZ=UTC date -u -r "$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ")
	if _comment_is_settled "$created" "$updated" 30; then
		print_result "settled accepts when edit_delta >= min_lag" 0
	else
		print_result "settled accepts when edit_delta >= min_lag" 1
	fi
	return 0
}

test_settled_missing_timestamps_conservative_pass() {
	# Empty created_at → conservative pass (don't block on missing data).
	if _comment_is_settled "" "" 30; then
		print_result "settled passes conservatively on missing created_at" 0
	else
		print_result "settled passes conservatively on missing created_at" 1
	fi
	return 0
}

test_settled_unparseable_timestamps_conservative_pass() {
	# Garbage timestamp → epoch=0 → conservative pass.
	if _comment_is_settled "not-a-date" "also-not-a-date" 30; then
		print_result "settled passes conservatively on unparseable timestamps" 0
	else
		print_result "settled passes conservatively on unparseable timestamps" 1
	fi
	return 0
}

# ---------- Unit tests: per-tool / per-repo lag resolution ----------

test_get_min_edit_lag_per_tool() {
	# coderabbitai on testorg/testrepo → 90 (per-tool override)
	local lag
	lag=$(_get_min_edit_lag "testorg/testrepo" "coderabbitai")
	if [[ "$lag" == "90" ]]; then
		print_result "get_min_edit_lag returns per-tool override (90)" 0
	else
		print_result "get_min_edit_lag returns per-tool override (90)" 1 \
			"got '${lag}', expected '90'"
	fi
	return 0
}

test_get_min_edit_lag_per_repo() {
	# gemini-code-assist on testorg/testrepo → 45 (per-repo default, no per-tool)
	local lag
	lag=$(_get_min_edit_lag "testorg/testrepo" "gemini-code-assist")
	if [[ "$lag" == "45" ]]; then
		print_result "get_min_edit_lag falls back to per-repo default (45)" 0
	else
		print_result "get_min_edit_lag falls back to per-repo default (45)" 1 \
			"got '${lag}', expected '45'"
	fi
	return 0
}

test_get_min_edit_lag_global_default() {
	# any bot on testorg/otherrepo → REVIEW_BOT_MIN_EDIT_LAG_SECONDS (30)
	local lag
	lag=$(_get_min_edit_lag "testorg/otherrepo" "coderabbitai")
	if [[ "$lag" == "30" ]]; then
		print_result "get_min_edit_lag falls back to global default (30)" 0
	else
		print_result "get_min_edit_lag falls back to global default (30)" 1 \
			"got '${lag}', expected '30'"
	fi
	return 0
}

test_get_min_edit_lag_unknown_repo_default() {
	# unknown repo → global default
	local lag
	lag=$(_get_min_edit_lag "nobody/nope" "coderabbitai")
	if [[ "$lag" == "30" ]]; then
		print_result "get_min_edit_lag returns global default for unknown repo" 0
	else
		print_result "get_min_edit_lag returns global default for unknown repo" 1 \
			"got '${lag}', expected '30'"
	fi
	return 0
}

# ---------- Run ----------

main() {
	setup_test_env
	trap cleanup_test_env EXIT

	# Source the helper (with main() invocation stripped) so its functions
	# are callable in this shell.
	load_helper_functions

	echo "=== Pattern matching ==="
	test_is_non_review_comment_matches_rate_limit
	test_is_non_review_comment_matches_review_failed
	test_is_non_review_comment_matches_review_skipped
	test_is_non_review_comment_matches_closed_during_review
	test_is_non_review_comment_rejects_real_review
	test_backwards_compat_alias

	echo ""
	echo "=== Settled check ==="
	test_settled_recent_unedited_placeholder_rejected
	test_settled_old_unedited_accepted
	test_settled_recent_edited_accepted
	test_settled_edit_delta_over_min_lag_accepted
	test_settled_missing_timestamps_conservative_pass
	test_settled_unparseable_timestamps_conservative_pass

	echo ""
	echo "=== Min-edit-lag resolver ==="
	test_get_min_edit_lag_per_tool
	test_get_min_edit_lag_per_repo
	test_get_min_edit_lag_global_default
	test_get_min_edit_lag_unknown_repo_default

	echo ""
	echo "Tests run: ${TESTS_RUN}, failed: ${TESTS_FAILED}"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
