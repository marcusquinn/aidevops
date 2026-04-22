#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for t2118: _carry_forward_pr_diff in pulse-merge.sh
#
# Verifies that when a CONFLICTING PR is closed via the "work NOT on main"
# path, its diff is appended to the linked issue body in a marker-guarded
# <details> section.
#
# Test cases:
#   1. Happy path — mock `gh pr diff` output appears on issue body with marker
#   2. Idempotency — running twice for the same PR does not duplicate the section
#   3. Size cap — 25KB diff is truncated with the truncation marker
#   4. origin:interactive skip — _close_conflicting_pr returns 0 without
#      appending for origin:interactive PRs (early return before carry-forward)
#
# Mock pattern follows test-pulse-merge-update-branch.sh: extract the helper
# source from pulse-merge.sh via awk, eval it into the test shell, and
# substitute `gh` with a stub on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-conflict.sh"  # GH#19836: _carry_forward_pr_diff extracted here

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
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	# Shared files for gh stub state
	export GH_DIFF_FILE="${TEST_ROOT}/diff-content.txt"
	export GH_ISSUE_BODY_FILE="${TEST_ROOT}/issue-body.txt"
	export GH_EDITED_BODY_FILE="${TEST_ROOT}/edited-body.txt"
	export GH_ARGS_FILE="${TEST_ROOT}/gh-args.log"
	: >"$GH_DIFF_FILE"
	: >"$GH_ISSUE_BODY_FILE"
	: >"$GH_EDITED_BODY_FILE"
	: >"$GH_ARGS_FILE"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Install a gh stub that:
#   - logs every invocation to GH_ARGS_FILE
#   - `gh pr diff <N> --repo <slug>` → prints GH_DIFF_FILE content
#   - `gh issue view <N> --repo <slug> --json body ...` → prints GH_ISSUE_BODY_FILE
#   - `gh issue edit <N> --repo <slug> --body <body>` → captures body arg to GH_EDITED_BODY_FILE
#   - every other gh call → exit 0, no output
install_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_ARGS_FILE}"

case "${1:-} ${2:-}" in
	"pr diff")
		cat "${GH_DIFF_FILE}"
		exit 0
		;;
	"issue view")
		# Return current body JSON for --json body --jq '.body // ""'
		printf '%s' "$(cat "${GH_ISSUE_BODY_FILE}")"
		exit 0
		;;
	"issue edit")
		# Capture the --body argument
		# Args are: issue edit <N> --repo <slug> --body <body>
		shift 2  # remove "issue edit"
		shift    # remove issue number
		while [[ $# -gt 0 ]]; do
			case "$1" in
				--repo) shift; shift ;;
				--body) shift; printf '%s' "$1" >"${GH_EDITED_BODY_FILE}"; shift ;;
				*) shift ;;
			esac
		done
		exit "${GH_EDIT_EXIT:-0}"
		;;
	*)
		exit 0
		;;
esac
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Extract _carry_forward_pr_diff from pulse-merge.sh and eval into this shell.
define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_carry_forward_pr_diff\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _carry_forward_pr_diff from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

# ---------------------------------------------------------------
# Test 1: Happy path — diff appears on issue body with the marker
# ---------------------------------------------------------------
test_happy_path_diff_appended() {
	install_gh_stub
	: >"$LOGFILE"
	printf 'diff --git a/foo.sh b/foo.sh\n+added line\n' >"$GH_DIFF_FILE"
	printf 'Existing issue body.' >"$GH_ISSUE_BODY_FILE"
	: >"$GH_EDITED_BODY_FILE"

	_carry_forward_pr_diff "42" "owner/repo" "99"

	local edited
	edited=$(cat "$GH_EDITED_BODY_FILE")

	if ! printf '%s' "$edited" | grep -qF '<!-- t2118:prior-worker-diff:PR42 -->'; then
		print_result "happy path: marker present in updated body" 1 \
			"Marker not found. Body: ${edited}"
		return 0
	fi

	if ! printf '%s' "$edited" | grep -qF 'Prior worker attempt (PR #42, closed CONFLICTING)'; then
		print_result "happy path: section heading present" 1 \
			"Section heading not found. Body: ${edited}"
		return 0
	fi

	if ! printf '%s' "$edited" | grep -qF 'added line'; then
		print_result "happy path: diff content in body" 1 \
			"Diff content not found. Body: ${edited}"
		return 0
	fi

	if ! grep -q "appended diff from PR #42" "$LOGFILE"; then
		print_result "happy path: success logged" 1 \
			"Expected success log entry. LOGFILE: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "happy path: diff appended to issue with marker" 0
	return 0
}

# ---------------------------------------------------------------
# Test 2: Idempotency — second call for same PR does not duplicate
# ---------------------------------------------------------------
test_idempotency_no_duplicate() {
	install_gh_stub
	: >"$LOGFILE"
	printf 'diff --git a/foo.sh b/foo.sh\n+added line\n' >"$GH_DIFF_FILE"

	# Issue body already contains the marker from a prior run
	local existing_body
	existing_body='Existing body.

<!-- t2118:prior-worker-diff:PR42 -->
## Prior worker attempt (PR #42, closed CONFLICTING)'
	printf '%s' "$existing_body" >"$GH_ISSUE_BODY_FILE"
	: >"$GH_EDITED_BODY_FILE"

	_carry_forward_pr_diff "42" "owner/repo" "99"

	# GH_EDITED_BODY_FILE should be empty — no edit was made
	local edited_size
	edited_size=$(wc -c <"$GH_EDITED_BODY_FILE")
	if [[ "$edited_size" -ne 0 ]]; then
		print_result "idempotency: no duplicate append when marker present" 1 \
			"Expected no edit (body unchanged), but gh issue edit was called. Size: ${edited_size}"
		return 0
	fi

	if ! grep -q "already has diff marker" "$LOGFILE"; then
		print_result "idempotency: skipped with log message" 1 \
			"Expected 'already has diff marker' in LOGFILE. Got: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "idempotency: no duplicate append when marker present" 0
	return 0
}

# ---------------------------------------------------------------
# Test 3: Size cap — 25KB diff truncated with note
# ---------------------------------------------------------------
test_size_cap_truncation() {
	install_gh_stub
	: >"$LOGFILE"

	# Generate a diff larger than 20KB (20480 bytes)
	local big_diff
	big_diff=$(printf 'diff --git a/big.sh b/big.sh\n')
	# Pad to ~25KB
	local line
	line=$(printf '%0.s+padding line of approximately 64 characters here XXXX\n' {1..400})
	big_diff="${big_diff}${line}"
	printf '%s' "$big_diff" >"$GH_DIFF_FILE"

	printf 'Existing issue body.' >"$GH_ISSUE_BODY_FILE"
	: >"$GH_EDITED_BODY_FILE"

	_carry_forward_pr_diff "77" "owner/repo" "55"

	local edited
	edited=$(cat "$GH_EDITED_BODY_FILE")

	if ! printf '%s' "$edited" | grep -qF '... (truncated, full diff at PR #77)'; then
		print_result "size cap: truncation note present" 1 \
			"Truncation note not found. Body length: ${#edited}"
		return 0
	fi

	# The diff content portion in the body must be <= 20KB + overhead
	# (we just check it's shorter than the original 25KB diff)
	local diff_in_body_len=${#edited}
	if [[ $diff_in_body_len -gt 25000 ]]; then
		print_result "size cap: body not bloated beyond 25KB" 1 \
			"Body length ${diff_in_body_len} exceeds expected maximum"
		return 0
	fi

	print_result "size cap: 25KB diff truncated with note" 0
	return 0
}

# ---------------------------------------------------------------
# Test 4: origin:interactive skip — static analysis
# Verify _close_conflicting_pr returns 0 early for origin:interactive PRs
# (the carry-forward call must live in the "work NOT on main" else branch,
# which is never reached by origin:interactive PRs).
#
# t2438 / GH#20060: _close_conflicting_pr was decomposed into an
# orchestrator plus helpers:
#   - _close_conflicting_pr_check_ownership_guard    (origin:interactive
#     + contributor check; called as Gate 1; renamed GH#20485)
#   - _close_conflicting_pr_comment_not_landed       (contains the
#     _carry_forward_pr_diff call; only called on the "not landed" branch)
# The structural invariants are asserted on the orchestrator's call
# order and on the helpers' bodies.
# ---------------------------------------------------------------
test_origin_interactive_skip_static() {
	local orch_src guard_src not_landed_src
	orch_src=$(awk '
		/^_close_conflicting_pr\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	guard_src=$(awk '
		/^_close_conflicting_pr_check_ownership_guard\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	not_landed_src=$(awk '
		/^_close_conflicting_pr_comment_not_landed\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")

	if [[ -z "$orch_src" ]]; then
		print_result "origin:interactive skip: orchestrator extractable" 1 \
			"Could not extract _close_conflicting_pr from $MERGE_SCRIPT"
		return 0
	fi
	if [[ -z "$guard_src" ]]; then
		print_result "origin:interactive skip: guard helper extractable" 1 \
			"Could not extract _close_conflicting_pr_check_ownership_guard from $MERGE_SCRIPT"
		return 0
	fi
	if [[ -z "$not_landed_src" ]]; then
		print_result "origin:interactive skip: not-landed helper extractable" 1 \
			"Could not extract _close_conflicting_pr_comment_not_landed from $MERGE_SCRIPT"
		return 0
	fi

	# The guard helper must contain the origin:interactive check itself
	if ! printf '%s' "$guard_src" | grep -q 'origin:interactive'; then
		print_result "origin:interactive skip: guard contains label check" 1 \
			"_close_conflicting_pr_check_ownership_guard missing origin:interactive check"
		return 0
	fi

	# The not-landed helper must contain the carry-forward call
	if ! printf '%s' "$not_landed_src" | grep -q '_carry_forward_pr_diff'; then
		print_result "origin:interactive skip: not-landed helper contains carry-forward" 1 \
			"_close_conflicting_pr_comment_not_landed missing _carry_forward_pr_diff call"
		return 0
	fi

	# The orchestrator must call the guard BEFORE the not-landed helper —
	# this preserves the original "origin:interactive check runs before
	# carry-forward" invariant through the decomposition.
	local guard_pos not_landed_pos
	guard_pos=$(printf '%s\n' "$orch_src" |
		grep -n '_close_conflicting_pr_check_ownership_guard' |
		head -1 | cut -d: -f1)
	not_landed_pos=$(printf '%s\n' "$orch_src" |
		grep -n '_close_conflicting_pr_comment_not_landed' |
		head -1 | cut -d: -f1)

	if [[ -z "$guard_pos" ]]; then
		print_result "origin:interactive skip: orchestrator calls guard" 1 \
			"Orchestrator missing _close_conflicting_pr_check_ownership_guard call"
		return 0
	fi
	if [[ -z "$not_landed_pos" ]]; then
		print_result "origin:interactive skip: orchestrator calls not-landed helper" 1 \
			"Orchestrator missing _close_conflicting_pr_comment_not_landed call"
		return 0
	fi
	if [[ "$guard_pos" -ge "$not_landed_pos" ]]; then
		print_result "origin:interactive skip: guard before not-landed helper" 1 \
			"Guard call (line ${guard_pos}) must precede not-landed helper call (line ${not_landed_pos})"
		return 0
	fi

	# The not-landed helper call must be in the "else" branch of the
	# orchestrator's work-on-main conditional — i.e. after the last `else`.
	local else_pos
	else_pos=$(printf '%s\n' "$orch_src" |
		grep -nE '^[[:space:]]*else$' | tail -1 | cut -d: -f1)
	if [[ -n "$else_pos" && "$not_landed_pos" -le "$else_pos" ]]; then
		print_result "origin:interactive skip: not-landed helper in else branch" 1 \
			"not-landed helper call (line ${not_landed_pos}) must appear after the orchestrator's final else (line ${else_pos})"
		return 0
	fi

	print_result "origin:interactive skip: static structure correct" 0
	return 0
}

# ---------------------------------------------------------------
# Test 5: Empty diff — skip gracefully (no issue edit, log message)
# ---------------------------------------------------------------
test_empty_diff_skipped() {
	install_gh_stub
	: >"$LOGFILE"
	: >"$GH_DIFF_FILE" # empty diff
	printf 'Existing issue body.' >"$GH_ISSUE_BODY_FILE"
	: >"$GH_EDITED_BODY_FILE"

	_carry_forward_pr_diff "33" "owner/repo" "11"

	local edited_size
	edited_size=$(wc -c <"$GH_EDITED_BODY_FILE")
	if [[ "$edited_size" -ne 0 ]]; then
		print_result "empty diff: no issue edit" 1 \
			"Expected no issue edit for empty diff"
		return 0
	fi

	if ! grep -q "diff is empty or unavailable" "$LOGFILE"; then
		print_result "empty diff: log message" 1 \
			"Expected 'diff is empty or unavailable' in LOGFILE. Got: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "empty diff: skipped gracefully" 0
	return 0
}

# ---------------------------------------------------------------
# Test 6: gh issue view failure — no data-loss overwrite
# When `gh issue view` returns non-zero, the function must skip
# the edit entirely (fail-open without clobbering the issue body).
# ---------------------------------------------------------------
test_issue_view_failure_skipped() {
	# Override gh stub to fail on `issue view`
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_ARGS_FILE}"

case "${1:-} ${2:-}" in
	"pr diff")
		printf 'diff --git a/foo.sh b/foo.sh\n+added line\n'
		exit 0
		;;
	"issue view")
		exit 1
		;;
	"issue edit")
		# Capture the --body argument
		shift 2
		shift
		while [[ $# -gt 0 ]]; do
			case "$1" in
				--repo) shift; shift ;;
				--body) shift; printf '%s' "$1" >"${GH_EDITED_BODY_FILE}"; shift ;;
				*) shift ;;
			esac
		done
		exit 0
		;;
	*)
		exit 0
		;;
esac
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	: >"$LOGFILE"
	: >"$GH_DIFF_FILE"
	printf 'diff --git a/foo.sh b/foo.sh\n+added line\n' >"$GH_DIFF_FILE"
	: >"$GH_EDITED_BODY_FILE"

	_carry_forward_pr_diff "88" "owner/repo" "22"

	local edited_size
	edited_size=$(wc -c <"$GH_EDITED_BODY_FILE")
	if [[ "$edited_size" -ne 0 ]]; then
		print_result "issue view failure: no issue edit (data loss guard)" 1 \
			"Expected no gh issue edit when gh issue view fails"
		return 0
	fi

	if ! grep -q "failed to fetch issue" "$LOGFILE"; then
		print_result "issue view failure: error logged" 1 \
			"Expected 'failed to fetch issue' in LOGFILE. Got: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "issue view failure: skipped edit to prevent data loss" 0
	return 0
}

# ---------------------------------------------------------------
# Test 7: t2383 Fix 4 — diff containing triple backticks uses dynamic fence
# A diff that modifies markdown files can contain ``` runs.
# The carry-forward function must use a fence longer than the longest
# backtick run in the diff content so rendering is not corrupted.
# ---------------------------------------------------------------
test_dynamic_fence_with_triple_backticks() {
	install_gh_stub
	: >"$LOGFILE"

	# Create a diff that contains triple backticks (common in markdown diffs)
	local diff_with_backticks
	diff_with_backticks='diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1,5 +1,8 @@
 # My Project
 
+```bash
+echo "hello world"
+```
+
 Some text here.'
	printf '%s' "$diff_with_backticks" >"$GH_DIFF_FILE"
	printf 'Existing issue body.' >"$GH_ISSUE_BODY_FILE"
	: >"$GH_EDITED_BODY_FILE"

	_carry_forward_pr_diff "50" "owner/repo" "30"

	local edited
	edited=$(cat "$GH_EDITED_BODY_FILE")

	# The fence in the output must be longer than the 3-backtick runs in the diff.
	# So we expect at least ```` (4 backticks) as the fence.
	if printf '%s' "$edited" | grep -qE '^\`{4,}diff$'; then
		print_result "dynamic fence: uses 4+ backtick fence for diff with triple backticks" 0
	else
		# Check if the old static fence is still there (regression)
		if printf '%s' "$edited" | grep -qE '^\`{3}diff$'; then
			print_result "dynamic fence: uses 4+ backtick fence" 1 \
				"Still using 3-backtick fence — dynamic fence not applied"
		else
			print_result "dynamic fence: uses 4+ backtick fence" 1 \
				"Could not find fence line in output. Body: ${edited:0:500}"
		fi
	fi
	return 0
}

# ---------------------------------------------------------------
# Test 8: t2383 Fix 4 — diff without backticks keeps standard 3-fence
# ---------------------------------------------------------------
test_standard_fence_without_backticks() {
	install_gh_stub
	: >"$LOGFILE"
	printf 'diff --git a/foo.sh b/foo.sh\n+added line\n' >"$GH_DIFF_FILE"
	printf 'Existing issue body.' >"$GH_ISSUE_BODY_FILE"
	: >"$GH_EDITED_BODY_FILE"

	_carry_forward_pr_diff "51" "owner/repo" "31"

	local edited
	edited=$(cat "$GH_EDITED_BODY_FILE")

	# Standard diff without backticks should use exactly 3-backtick fence
	if printf '%s' "$edited" | grep -qE '^\`{3}diff$'; then
		print_result "standard fence: 3-backtick fence for plain diff" 0
	else
		print_result "standard fence: 3-backtick fence for plain diff" 1 \
			"Expected 3-backtick fence. Body: ${edited:0:500}"
	fi
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_happy_path_diff_appended
	test_idempotency_no_duplicate
	test_size_cap_truncation
	test_origin_interactive_skip_static
	test_empty_diff_skipped
	test_issue_view_failure_skipped
	test_dynamic_fence_with_triple_backticks
	test_standard_fence_without_backticks

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
