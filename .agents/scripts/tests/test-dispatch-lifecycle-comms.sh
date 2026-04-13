#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2042: Regression test for dispatch-lifecycle communication fixes.
#
# Covers two distinct fixes that landed together:
#
# Fix A — _post_simplification_gate_cleared_comment:
#   When the simplification gate's `needs-simplification` label is
#   cleared (either by re-eval in pulse-triage.sh or by the inline
#   auto-clear in pulse-dispatch-core.sh), a follow-up "CLEARED" comment
#   is posted exactly once per issue (idempotent via marker).
#
# Fix B — _classify_stale_recovery_crash_type:
#   Stale-recovered workers are classified as "partial" (open PR or
#   issue-named remote branch exists) or "no_work" (truly zero
#   artifact). The classification is passed to fast_fail_record so the
#   cascade tier escalation comment renders a Crash type line.
#
# shellcheck disable=SC1090,SC1091

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1

# Isolated environment
TMP_HOME=$(mktemp -d)
export HOME="$TMP_HOME"
export LOGFILE="${TMP_HOME}/test.log"
export REPOS_JSON="${TMP_HOME}/repos.json"
printf '{"initialized_repos":[]}' >"$REPOS_JSON"

# Source dependencies in the same order as pulse-wrapper.sh
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/pulse-triage.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/pulse-dispatch-core.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		echo "PASS $name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $name"
		[[ -n "$detail" ]] && printf '  %s\n' "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# --- Mock gh ---
# State files for each gh subcommand the helpers touch.
GH_COMMENT_LOG="${TMP_HOME}/gh-comment.log"
GH_API_COMMENTS_RESPONSE="${TMP_HOME}/gh-api-comments.json"
GH_PR_LIST_RESPONSE="${TMP_HOME}/gh-pr-list.json"
GH_API_BRANCHES_RESPONSE="${TMP_HOME}/gh-api-branches.json"
: >"$GH_COMMENT_LOG"
printf '[]' >"$GH_API_COMMENTS_RESPONSE"
printf '[]' >"$GH_PR_LIST_RESPONSE"
printf '[]' >"$GH_API_BRANCHES_RESPONSE"

# Helper: extract the value of --jq from an argv list, if present.
_extract_jq_filter() {
	local prev=""
	local arg
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			printf '%s' "$arg"
			return 0
		fi
		prev="$arg"
	done
	return 1
}

# Helper: dump a canned response, optionally piped through jq if the
# caller passed --jq. The real gh applies the jq filter server-side
# after JSON parsing; we approximate that by piping through real jq.
_mock_gh_response() {
	local response_file="$1"
	shift
	local jq_filter
	if jq_filter=$(_extract_jq_filter "$@"); then
		jq -r "$jq_filter" <"$response_file" 2>/dev/null || cat "$response_file"
	else
		cat "$response_file"
	fi
	return 0
}

gh() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	api)
		# Path-based dispatch
		local path="${1:-}"
		shift || true
		case "$path" in
		repos/*/issues/*/comments)
			_mock_gh_response "$GH_API_COMMENTS_RESPONSE" "$@"
			;;
		repos/*/branches)
			_mock_gh_response "$GH_API_BRANCHES_RESPONSE" "$@"
			;;
		*)
			echo "{}"
			;;
		esac
		;;
	pr)
		local sub="${1:-}"
		shift || true
		case "$sub" in
		list)
			_mock_gh_response "$GH_PR_LIST_RESPONSE" "$@"
			;;
		view)
			_mock_gh_response "$GH_API_COMMENTS_RESPONSE" "$@"
			;;
		*)
			echo "{}"
			;;
		esac
		;;
	issue)
		local sub="${1:-}"
		shift || true
		case "$sub" in
		comment)
			# Capture the --body for assertions.
			while [[ $# -gt 0 ]]; do
				if [[ "$1" == "--body" ]]; then
					printf '%s\n---END_COMMENT---\n' "$2" >>"$GH_COMMENT_LOG"
					shift 2
				else
					shift
				fi
			done
			;;
		view)
			# Used by some helpers to fetch issue body/labels — return empty
			echo "{}"
			;;
		*) ;;
		esac
		;;
	*) ;;
	esac
	return 0
}

# Replace jq's argument-passing for the test by exporting it. The helpers
# call `gh ... --jq '...'` which routes through our mock above; we don't
# actually need to interpret the jq filter — we just return canned
# responses based on the subcommand path. The mock above already
# handles this correctly.

# --- Fix A: _post_simplification_gate_cleared_comment ---

reset_gh_state() {
	: >"$GH_COMMENT_LOG"
	printf '[]' >"$GH_API_COMMENTS_RESPONSE"
	return 0
}

count_gh_comments() {
	# Count the number of ---END_COMMENT--- separators in the log.
	# `grep -c` exits 1 with stdout "0" when there are no matches; suppress
	# the exit code so this function never returns non-zero, and emit a
	# single integer on stdout regardless.
	local n
	n=$(grep -c '^---END_COMMENT---$' "$GH_COMMENT_LOG" 2>/dev/null || true)
	[[ "$n" =~ ^[0-9]+$ ]] || n=0
	printf '%s' "$n"
	return 0
}

# Test 1: cleared comment posted on first call when no marker exists
reset_gh_state
_post_simplification_gate_cleared_comment "12345" "owner/repo"
count1=$(count_gh_comments)
if [[ "$count1" -eq 1 ]]; then
	print_result "Fix A: posts cleared comment when marker absent" 0
else
	print_result "Fix A: posts cleared comment when marker absent" 1 "expected 1 comment got $count1"
fi

# Test 2: comment body contains the marker and the CLEARED heading
if grep -q '<!-- simplification-gate-cleared:12345 -->' "$GH_COMMENT_LOG" &&
	grep -q 'Large File Simplification Gate — CLEARED' "$GH_COMMENT_LOG"; then
	print_result "Fix A: posted comment body contains marker and heading" 0
else
	print_result "Fix A: posted comment body contains marker and heading" 1 "log: $(cat "$GH_COMMENT_LOG")"
fi

# Test 3: idempotent — second call with marker present does NOT post again
# Simulate the marker already being present by feeding it back via the
# api comments response. _gh_idempotent_comment fetches existing comments
# and skips if the marker is found.
reset_gh_state
printf '[{"body":"<!-- simplification-gate-cleared:12345 -->\\n## Large File Simplification Gate — CLEARED"}]' \
	>"$GH_API_COMMENTS_RESPONSE"
_post_simplification_gate_cleared_comment "12345" "owner/repo"
count_after_idempotent=$(count_gh_comments)
if [[ "$count_after_idempotent" -eq 0 ]]; then
	print_result "Fix A: idempotent — does not re-post when marker present" 0
else
	print_result "Fix A: idempotent — does not re-post when marker present" 1 "expected 0 got $count_after_idempotent"
fi

# Test 4: handles invalid issue number gracefully
reset_gh_state
_post_simplification_gate_cleared_comment "not-a-number" "owner/repo"
count_invalid=$(count_gh_comments)
if [[ "$count_invalid" -eq 0 ]]; then
	print_result "Fix A: skips when issue number invalid" 0
else
	print_result "Fix A: skips when issue number invalid" 1 "posted $count_invalid"
fi

# --- Fix B: _classify_stale_recovery_crash_type ---

# Test 5: returns 'partial' when an open PR exists for the issue
reset_gh_state
printf '[{"number":777}]' >"$GH_PR_LIST_RESPONSE"
printf '[]' >"$GH_API_BRANCHES_RESPONSE"
crash_type_pr=$(_classify_stale_recovery_crash_type "18418" "owner/repo")
if [[ "$crash_type_pr" == "partial" ]]; then
	print_result "Fix B: partial when open PR exists" 0
else
	print_result "Fix B: partial when open PR exists" 1 "got '$crash_type_pr'"
fi

# Test 6: returns 'partial' when a remote branch references the issue
reset_gh_state
printf '[]' >"$GH_PR_LIST_RESPONSE"
printf '[{"name":"bugfix/t18418-fix"},{"name":"main"}]' >"$GH_API_BRANCHES_RESPONSE"
crash_type_branch=$(_classify_stale_recovery_crash_type "18418" "owner/repo")
if [[ "$crash_type_branch" == "partial" ]]; then
	print_result "Fix B: partial when issue-named branch exists" 0
else
	print_result "Fix B: partial when issue-named branch exists" 1 "got '$crash_type_branch'"
fi

# Test 7: returns 'no_work' when no PR and no matching branch
reset_gh_state
printf '[]' >"$GH_PR_LIST_RESPONSE"
printf '[{"name":"main"},{"name":"feature/unrelated-9999"}]' >"$GH_API_BRANCHES_RESPONSE"
crash_type_none=$(_classify_stale_recovery_crash_type "18418" "owner/repo")
if [[ "$crash_type_none" == "no_work" ]]; then
	print_result "Fix B: no_work when no PR and no matching branch" 0
else
	print_result "Fix B: no_work when no PR and no matching branch" 1 "got '$crash_type_none'"
fi

# Test 8: defensive — returns no_work for invalid issue number
crash_type_invalid=$(_classify_stale_recovery_crash_type "not-a-number" "owner/repo")
if [[ "$crash_type_invalid" == "no_work" ]]; then
	print_result "Fix B: no_work on invalid issue number" 0
else
	print_result "Fix B: no_work on invalid issue number" 1 "got '$crash_type_invalid'"
fi

# Test 9: defensive — returns no_work for empty repo slug
crash_type_no_repo=$(_classify_stale_recovery_crash_type "18418" "")
if [[ "$crash_type_no_repo" == "no_work" ]]; then
	print_result "Fix B: no_work on empty repo slug" 0
else
	print_result "Fix B: no_work on empty repo slug" 1 "got '$crash_type_no_repo'"
fi

# Cleanup
rm -rf "$TMP_HOME"

echo
echo "Tests run: $TESTS_RUN passed: $TESTS_PASSED failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
