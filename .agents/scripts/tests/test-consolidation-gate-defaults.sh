#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-consolidation-gate-defaults.sh — regression test for t2142 (GH#19343)
#
# Covers the defensive-default hardening on _issue_needs_consolidation:
#   - Function must behave correctly when ISSUE_CONSOLIDATION_COMMENT_THRESHOLD
#     and ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS are UNSET in the environment.
#   - Fallback defaults (threshold=2, min_chars=500) must match the source of
#     truth at pulse-wrapper.sh:816-817.
#
# Why this matters: pulse-triage.sh is intended to be sourced from
# pulse-wrapper.sh which declares these defaults at top-level. If the module
# is ever sourced standalone (tests, one-off scripts, future refactors), the
# gate function must remain correct. Bash 5.x `[[ N -ge "" ]]` evaluates TRUE
# for any N, so an unset threshold would silently flip the gate permanently
# on and falsely label every eligible issue `needs-consolidation`.
#
# Strategy: source pulse-triage.sh with ISSUE_CONSOLIDATION_COMMENT_* unset,
# stub `gh` to return a canned comments payload, call _issue_needs_consolidation
# with (a) 1 substantive comment → expect return 1 (below default threshold=2),
# (b) 3 substantive comments → expect return 0 (meets default threshold=2).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

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

# Write a minimal `gh` stub that serves:
#   - gh issue view --json labels → returns labels CSV from GH_ISSUE_VIEW_LABELS
#   - gh issue list               → returns GH_ISSUE_LIST_CHILD_JSON (dedup check)
#   - gh api repos/.../comments   → returns GH_API_COMMENTS_JSON
_write_gh_stub() {
	mkdir -p "${TEST_ROOT}/bin"
	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

cmd1="${1:-}"
cmd2="${2:-}"

if [[ "$cmd1" == "issue" && "$cmd2" == "view" ]]; then
	shift 2
	local_json=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			local_json="$2"
			shift 2
			;;
		--jq)
			shift 2
			;;
		*) shift ;;
		esac
	done
	case "$local_json" in
	labels) printf '%s\n' "${GH_ISSUE_VIEW_LABELS:-bug,tier:standard}" ;;
	*) printf '\n' ;;
	esac
	exit 0
fi

if [[ "$cmd1" == "issue" && "$cmd2" == "list" ]]; then
	jq_filter=""
	prev_arg=""
	for arg in "$@"; do
		if [[ "$prev_arg" == "--jq" ]]; then
			jq_filter="$arg"
		fi
		prev_arg="$arg"
	done
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "${GH_ISSUE_LIST_CHILD_JSON:-[]}" | jq -r "$jq_filter"
	else
		printf '%s\n' "${GH_ISSUE_LIST_CHILD_JSON:-[]}"
	fi
	exit 0
fi

if [[ "$cmd1" == "api" ]]; then
	printf '%s\n' "${GH_API_COMMENTS_JSON:-[]}"
	exit 0
fi

exit 0
STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d -t t2142-gate.XXXXXX)
	GH_LOG="${TEST_ROOT}/gh.log"
	: >"$GH_LOG"
	_write_gh_stub

	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_LOG
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"

	# Critical: DO NOT set ISSUE_CONSOLIDATION_COMMENT_{THRESHOLD,MIN_CHARS}.
	# The whole point is verifying the defensive defaults kick in when unset.
	unset ISSUE_CONSOLIDATION_COMMENT_THRESHOLD
	unset ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS

	# Source pulse-triage.sh in isolation (without pulse-wrapper.sh).
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-triage.sh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	GH_LOG=""
	unset GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON
	# t2143: Reset the module-load guard so the next setup_test_env re-sources
	# pulse-triage.sh and re-runs the := defaults block. Without this, the
	# second test's `unset ISSUE_CONSOLIDATION_COMMENT_*` leaves the vars unset
	# and the guard prevents re-initialization → unbound variable on bash -u.
	unset _PULSE_TRIAGE_LOADED
	return 0
}

# Fixture: 1 substantive comment (600 chars) — below default threshold=2.
fixture_one_substantive_comment() {
	# Body is 600 chars to clear default min_chars=500.
	local body
	body=$(printf 'Detailed review feedback from alice. %.0s' {1..20})
	jq -n --arg body "$body" '[
		{user: {login: "alice", type: "User"}, body: $body}
	]'
}

# Fixture: 3 substantive comments (each 600 chars) — meets default threshold=2.
fixture_three_substantive_comments() {
	local body
	body=$(printf 'Detailed review feedback from the reviewer. %.0s' {1..15})
	jq -n --arg body "$body" '[
		{user: {login: "alice", type: "User"}, body: $body},
		{user: {login: "bob", type: "User"}, body: $body},
		{user: {login: "carol", type: "User"}, body: $body}
	]'
}

# Fixture: 3 comments, each BELOW default min_chars=500 — should be filtered out.
# Ensures the min_chars default (500) applies, not a weaker fallback.
fixture_three_short_comments() {
	jq -n '[
		{user: {login: "alice", type: "User"}, body: "Short comment, under 500 chars."},
		{user: {login: "bob", type: "User"}, body: "Another short comment."},
		{user: {login: "carol", type: "User"}, body: "Also short."}
	]'
}

test_below_threshold_returns_one() {
	setup_test_env
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_API_COMMENTS_JSON=$(fixture_one_substantive_comment)
	export GH_ISSUE_VIEW_LABELS GH_ISSUE_LIST_CHILD_JSON GH_API_COMMENTS_JSON

	local rc=0
	_issue_needs_consolidation 123 "owner/repo" || rc=$?

	if [[ "$rc" -eq 1 ]]; then
		print_result "unset env + 1 substantive comment → returns 1 (below default threshold=2)" 0
	else
		print_result "unset env + 1 substantive comment → returns 1 (below default threshold=2)" 1 \
			"expected rc=1, got rc=${rc} — default threshold likely not applied"
	fi

	teardown_test_env
	return 0
}

test_meets_threshold_returns_zero() {
	setup_test_env
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_API_COMMENTS_JSON=$(fixture_three_substantive_comments)
	export GH_ISSUE_VIEW_LABELS GH_ISSUE_LIST_CHILD_JSON GH_API_COMMENTS_JSON

	local rc=0
	_issue_needs_consolidation 123 "owner/repo" || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "unset env + 3 substantive comments → returns 0 (meets default threshold=2)" 0
	else
		print_result "unset env + 3 substantive comments → returns 0 (meets default threshold=2)" 1 \
			"expected rc=0, got rc=${rc}"
	fi

	teardown_test_env
	return 0
}

test_min_chars_default_filters_short_comments() {
	setup_test_env
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_API_COMMENTS_JSON=$(fixture_three_short_comments)
	export GH_ISSUE_VIEW_LABELS GH_ISSUE_LIST_CHILD_JSON GH_API_COMMENTS_JSON

	local rc=0
	_issue_needs_consolidation 123 "owner/repo" || rc=$?

	# All 3 comments are below default min_chars=500, so they should not count
	# as substantive → gate should NOT trigger (return 1).
	if [[ "$rc" -eq 1 ]]; then
		print_result "unset env + 3 short comments → returns 1 (default min_chars=500 filters them)" 0
	else
		print_result "unset env + 3 short comments → returns 1 (default min_chars=500 filters them)" 1 \
			"expected rc=1, got rc=${rc} — default min_chars=500 likely not applied"
	fi

	teardown_test_env
	return 0
}

# t2143: Verify that _consolidation_substantive_comments also uses the module
# default min_chars=500, not the prior stale fallback of 200. A comment with
# 350 chars (above 200 but below 500) must NOT be returned by the helper when
# ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS is unset (module default=500 applies).
test_substantive_comments_helper_uses_500_not_200() {
	setup_test_env

	# A comment between 200 and 500 chars — should be filtered by 500, not by 200.
	# printf '%350s' '' | tr ' ' 'A' produces exactly 350 'A' characters.
	local mid_body
	mid_body=$(printf '%350s' '' | tr ' ' 'A') # exactly 350 chars: above 200, below 500
	local comments_json
	comments_json=$(jq -n --arg body "$mid_body" '[
		{user: {login: "alice", type: "User"}, body: $body}
	]')
	GH_API_COMMENTS_JSON="$comments_json"
	export GH_API_COMMENTS_JSON

	local result
	result=$(_consolidation_substantive_comments 123 "owner/repo" 2>/dev/null)
	local count
	count=$(printf '%s' "$result" | jq 'length' 2>/dev/null) || count=0

	# With min_chars=500 (module default), a 350-char comment is NOT substantive.
	if [[ "$count" -eq 0 ]]; then
		print_result "_consolidation_substantive_comments: 350-char comment filtered (module default=500, not stale 200)" 0
	else
		print_result "_consolidation_substantive_comments: 350-char comment filtered (module default=500, not stale 200)" 1 \
			"expected count=0 (filtered by 500), got count=${count} — stale 200 fallback may still be in effect"
	fi

	teardown_test_env
	return 0
}

main() {
	test_below_threshold_returns_one
	test_meets_threshold_returns_zero
	test_min_chars_default_filters_short_comments
	test_substantive_comments_helper_uses_500_not_200

	echo
	echo "============================================"
	printf 'Tests run:    %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	echo "============================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
