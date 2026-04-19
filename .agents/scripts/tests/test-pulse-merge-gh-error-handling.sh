#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#19864 — hardened gh API error handling in the
# pulse-merge split modules (pulse-merge-conflict.sh, pulse-merge-feedback.sh).
#
# Tests verify that:
#   1. _close_conflicting_pr skips auto-close when gh pr view fails (finding 2)
#   2. _close_conflicting_pr uses exact-match for origin:interactive (finding 2)
#   3. _interactive_pr_is_stale returns not-stale when no-takeover label present (finding 1)
#   4. _interactive_pr_is_stale validates HANDOVER_HOURS (finding 4)
#   5. _carry_forward_pr_diff uses dynamic backtick fence (finding 3)
#   6. Feedback helpers abort on gh issue view failure (finding 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CONFLICT_SCRIPT="${SCRIPT_DIR}/../pulse-merge-conflict.sh"
FEEDBACK_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback.sh"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# =============================================================================
# Test 1: _close_conflicting_pr skips when gh pr view fails
# =============================================================================
test_close_conflicting_pr_skips_on_gh_failure() {
	# Mock gh that always fails for pr view
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
if [[ "${1:-} ${2:-}" == "pr view" ]]; then
	exit 1
fi
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Extract _close_conflicting_pr
	local fn_src
	fn_src=$(awk '/^_close_conflicting_pr\(\) \{/,/^}$/ { print }' "$CONFLICT_SCRIPT")
	# shellcheck disable=SC1090
	eval "$fn_src"

	# Stub helpers it calls
	_post_rebase_nudge_on_interactive_conflicting() { return 0; }
	_extract_linked_issue() { echo "42"; return 0; }
	_verify_pr_overlaps_commit() { return 0; }
	_post_rebase_nudge_on_worker_conflicting() { return 0; }
	_carry_forward_pr_diff() { return 0; }
	_gh_idempotent_comment() { return 0; }

	: >"$LOGFILE"
	_close_conflicting_pr "99" "owner/repo" "t123: some fix"
	local rc=$?

	# Should return 0 (fail-open) and log the API failure
	local failed=0
	if [[ $rc -ne 0 ]]; then
		failed=1
	fi
	if ! grep -q "gh pr view failed" "$LOGFILE"; then
		failed=1
	fi
	# Should NOT have called pr close (skipped)
	if grep -q "pr close" "$GH_LOG"; then
		failed=1
	fi
	print_result "close_conflicting_pr skips on gh pr view failure" "$failed" \
		"Expected return 0, 'gh pr view failed' in log, no pr close call"
	return 0
}

# =============================================================================
# Test 2: _close_conflicting_pr uses exact-match for origin:interactive
# =============================================================================
test_close_conflicting_pr_exact_label_match() {
	# Mock gh that returns a label that contains "origin:interactive" as substring
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_subcmd="${1:-} ${2:-}"
case "$_subcmd" in
"pr view")
	if [[ "$*" == *"--json labels"* ]]; then
		# Return a label that is NOT exactly "origin:interactive" but contains it
		printf 'not-origin:interactive-extended\n'
		exit 0
	fi
	;;
"pr close" | "pr edit" | "label create")
	exit 0
	;;
"issue view")
	if [[ "$*" == *"--json body"* ]]; then
		echo 'body text'
		exit 0
	fi
	exit 0
	;;
"issue edit")
	exit 0
	;;
esac
if [[ "${1:-}" == "api" ]]; then
	echo '[]'
	exit 0
fi
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	local fn_src
	fn_src=$(awk '/^_close_conflicting_pr\(\) \{/,/^}$/ { print }' "$CONFLICT_SCRIPT")
	# shellcheck disable=SC1090
	eval "$fn_src"

	_post_rebase_nudge_on_interactive_conflicting() { return 0; }
	_extract_linked_issue() { echo "42"; return 0; }
	_verify_pr_overlaps_commit() { return 0; }
	_post_rebase_nudge_on_worker_conflicting() { return 0; }
	_carry_forward_pr_diff() { return 0; }
	_gh_idempotent_comment() { return 0; }

	: >"$LOGFILE"
	_close_conflicting_pr "99" "owner/repo" "t123: some fix"

	# With exact-match, the label "not-origin:interactive-extended" should NOT match
	# So the function should NOT skip with the "maintainer session" message
	local failed=0
	if grep -q "skipping auto-close of origin:interactive" "$LOGFILE"; then
		failed=1
	fi
	print_result "close_conflicting_pr uses exact-match for origin:interactive" "$failed" \
		"Substring label should not trigger origin:interactive skip"
	return 0
}

# =============================================================================
# Test 3: _interactive_pr_is_stale returns not-stale when no-takeover present
# =============================================================================
test_stale_check_honors_no_takeover() {
	# Mock gh that returns labels including no-takeover
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
if [[ "${1:-} ${2:-}" == "pr view" ]]; then
	if [[ "$*" == *"--json labels"* ]]; then
		printf '{"labels":[{"name":"origin:interactive"},{"name":"no-takeover"}],"updatedAt":"2026-01-01T00:00:00Z"}\n'
		exit 0
	fi
fi
if [[ "${1:-}" == "api" ]]; then
	printf '{"state":"open","labels":[]}\n'
	exit 0
fi
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	local fn_src
	fn_src=$(awk '/^_interactive_pr_is_stale\(\) \{/,/^}$/ { print }' "$CONFLICT_SCRIPT")
	# shellcheck disable=SC1090
	eval "$fn_src"

	export AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE="enforce"
	: >"$LOGFILE"
	local rc=0
	_interactive_pr_is_stale "99" "owner/repo" || rc=$?

	local failed=0
	if [[ $rc -eq 0 ]]; then
		failed=1  # Should return 1 (not stale) because of no-takeover
	fi
	if ! grep -q "no-takeover label" "$LOGFILE"; then
		failed=1
	fi
	print_result "stale check returns not-stale when no-takeover label present" "$failed" \
		"Expected rc=1 (not stale) and 'no-takeover label' in log"

	unset AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE
	return 0
}

# =============================================================================
# Test 4: _interactive_pr_is_stale validates HANDOVER_HOURS
# =============================================================================
test_stale_check_validates_hours() {
	# Mock gh that returns a very old PR
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
if [[ "${1:-} ${2:-}" == "pr view" ]]; then
	if [[ "$*" == *"--json labels"* ]]; then
		printf '{"labels":[{"name":"origin:interactive"}],"updatedAt":"2025-01-01T00:00:00Z"}\n'
		exit 0
	fi
fi
if [[ "${1:-}" == "api" ]]; then
	printf '{"state":"open","labels":[]}\n'
	exit 0
fi
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	local fn_src
	fn_src=$(awk '/^_interactive_pr_is_stale\(\) \{/,/^}$/ { print }' "$CONFLICT_SCRIPT")
	# shellcheck disable=SC1090
	eval "$fn_src"

	# Stub for linked issue extraction
	_extract_linked_issue() { echo "42"; return 0; }

	export AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE="enforce"
	export AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS="not-a-number"
	: >"$LOGFILE"
	_interactive_pr_is_stale "99" "owner/repo" 2>/dev/null || true

	local failed=0
	if ! grep -q "invalid.*falling back to 24" "$LOGFILE"; then
		failed=1
	fi
	print_result "stale check validates HANDOVER_HOURS and falls back to 24" "$failed" \
		"Expected 'invalid.*falling back to 24' in log"

	unset AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE
	unset AIDEVOPS_INTERACTIVE_PR_HANDOVER_HOURS
	return 0
}

# =============================================================================
# Test 5: _carry_forward_pr_diff uses dynamic fence when diff contains backticks
# =============================================================================
test_carry_forward_uses_dynamic_fence() {
	# _carry_forward_pr_diff takes (pr_number, repo_slug, linked_issue) and
	# fetches the diff itself via `gh pr diff`. The mock returns diff content
	# with embedded triple backticks to trigger the dynamic fence logic.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_subcmd="${1:-} ${2:-}"
case "$_subcmd" in
"pr diff")
	# Return diff content containing triple backticks
	cat <<'DIFF'
--- a/file.sh
+++ b/file.sh
@@ -1,3 +1,5 @@
 line1
+```bash
+echo "hello"
+```
 line3
DIFF
	exit 0
	;;
"issue view")
	if [[ "$*" == *"--json body"* ]]; then
		echo ''
		exit 0
	fi
	exit 0
	;;
"issue edit")
	_args=("$@")
	for _i in "${!_args[@]}"; do
		if [[ "${_args[$_i]}" == "--body" ]]; then
			printf '%s' "${_args[$((_i + 1))]}" >"${TEST_ROOT}/edit-body.txt"
			break
		fi
	done
	exit 0
	;;
esac
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	local fn_src
	fn_src=$(awk '/^_carry_forward_pr_diff\(\) \{/,/^}$/ { print }' "$CONFLICT_SCRIPT")
	# shellcheck disable=SC1090
	eval "$fn_src"

	: >"$LOGFILE"
	_carry_forward_pr_diff "99" "owner/repo" "42"

	local failed=0
	if [[ -f "${TEST_ROOT}/edit-body.txt" ]]; then
		# The fence should be at least 4 backticks (longer than the 3 in the diff)
		if ! grep -E '^`{4,}diff' "${TEST_ROOT}/edit-body.txt" >/dev/null 2>&1; then
			failed=1
		fi
	else
		failed=1
	fi
	print_result "carry_forward uses dynamic fence when diff has backticks" "$failed" \
		"Expected fence with 4+ backticks in issue body"
	return 0
}

# =============================================================================
# Test 6: _dispatch_ci_fix_worker aborts on gh issue view failure
# =============================================================================
test_ci_fix_worker_aborts_on_fetch_failure() {
	# _dispatch_ci_fix_worker takes (pr_number, repo_slug, linked_issue).
	# It calls `gh pr checks` first — mock must return failing checks so it
	# doesn't return early. Then `gh issue view` must fail.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_subcmd="${1:-} ${2:-}"
case "$_subcmd" in
"label create")
	exit 0
	;;
"pr checks")
	printf '%s\n' '- **lint**: fail — [https://example.com](https://example.com)'
	exit 0
	;;
"issue view")
	exit 1
	;;
"issue edit")
	printf 'SHOULD_NOT_BE_CALLED\n' >>"${TEST_ROOT}/unexpected.log"
	exit 0
	;;
esac
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	local fn_src
	fn_src=$(awk '/^_dispatch_ci_fix_worker\(\) \{/,/^}$/ { print }' "$FEEDBACK_SCRIPT")
	# shellcheck disable=SC1090
	eval "$fn_src"

	# Stub set_issue_status
	set_issue_status() { return 0; }

	: >"$LOGFILE"
	rm -f "${TEST_ROOT}/unexpected.log"
	local rc=0
	_dispatch_ci_fix_worker "99" "owner/repo" "42" 2>/dev/null || rc=$?

	local failed=0
	# Should fail (return 1) and log the fetch failure
	if [[ $rc -eq 0 ]]; then
		failed=1
	fi
	if ! grep -q "failed to fetch issue.*skipping edit to avoid data loss" "$LOGFILE"; then
		failed=1
	fi
	# issue edit should NOT have been called
	if [[ -f "${TEST_ROOT}/unexpected.log" ]]; then
		failed=1
	fi
	print_result "ci_fix_worker aborts on gh issue view failure" "$failed" \
		"Expected return 1, fetch failure log, no issue edit"
	return 0
}

# =============================================================================
# Test 7: _dispatch_conflict_fix_worker aborts on gh issue view failure
# =============================================================================
test_conflict_fix_worker_aborts_on_fetch_failure() {
	# Same mock — gh issue view fails
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
if [[ "${1:-} ${2:-}" == "issue view" ]]; then
	exit 1
fi
if [[ "${1:-} ${2:-}" == "issue edit" ]]; then
	printf 'SHOULD_NOT_BE_CALLED\n' >>"${TEST_ROOT}/unexpected.log"
	exit 0
fi
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	local fn_src
	fn_src=$(awk '/^_dispatch_conflict_fix_worker\(\) \{/,/^}$/ { print }' "$FEEDBACK_SCRIPT")
	# shellcheck disable=SC1090
	eval "$fn_src"

	set_issue_status() { return 0; }

	: >"$LOGFILE"
	rm -f "${TEST_ROOT}/unexpected.log"
	local rc=0
	_dispatch_conflict_fix_worker "99" "owner/repo" "42" "## Conflict Feedback" 2>/dev/null || rc=$?

	local failed=0
	if [[ $rc -eq 0 ]]; then
		failed=1
	fi
	if ! grep -q "failed to fetch issue.*skipping edit to avoid data loss" "$LOGFILE"; then
		failed=1
	fi
	if [[ -f "${TEST_ROOT}/unexpected.log" ]]; then
		failed=1
	fi
	print_result "conflict_fix_worker aborts on gh issue view failure" "$failed" \
		"Expected return 1, fetch failure log, no issue edit"
	return 0
}

# =============================================================================
# Test 8: _dispatch_pr_fix_worker aborts on gh issue view failure
# =============================================================================
test_pr_fix_worker_aborts_on_fetch_failure() {
	# _dispatch_pr_fix_worker takes (pr_number, repo_slug, linked_issue).
	# It fetches reviews via `gh api repos/.../reviews` and inline comments
	# via `gh api repos/.../comments` before calling _build_review_feedback_section.
	# The mock must return substantive review data for those, then fail on issue view.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_subcmd="${1:-} ${2:-}"
case "$_subcmd" in
"label create")
	exit 0
	;;
"pr close" | "pr edit")
	exit 0
	;;
"issue view")
	exit 1
	;;
"issue edit")
	printf 'SHOULD_NOT_BE_CALLED\n' >>"${TEST_ROOT}/unexpected.log"
	exit 0
	;;
esac
if [[ "${1:-}" == "api" ]]; then
	if [[ "$*" == *"/reviews"* ]]; then
		printf '[{"author":"coderabbitai[bot]","state":"CHANGES_REQUESTED","body":"Two issues found.","url":"https://example.com"}]\n'
		exit 0
	fi
	if [[ "$*" == *"/comments"* ]]; then
		printf '[{"author":"coderabbitai[bot]","path":"f.sh","line":1,"body":"off-by-one","url":"https://example.com"}]\n'
		exit 0
	fi
fi
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Extract both _build_review_feedback_section and _dispatch_pr_fix_worker
	local build_src dispatch_src
	build_src=$(awk '/^_build_review_feedback_section\(\) \{/,/^}$/ { print }' "$FEEDBACK_SCRIPT")
	dispatch_src=$(awk '/^_dispatch_pr_fix_worker\(\) \{/,/^}$/ { print }' "$FEEDBACK_SCRIPT")
	# shellcheck disable=SC1090
	eval "$build_src"
	# shellcheck disable=SC1090
	eval "$dispatch_src"

	set_issue_status() { return 0; }

	: >"$LOGFILE"
	rm -f "${TEST_ROOT}/unexpected.log"
	local rc=0
	_dispatch_pr_fix_worker "99" "owner/repo" "42" 2>/dev/null || rc=$?

	local failed=0
	if [[ $rc -eq 0 ]]; then
		failed=1
	fi
	if ! grep -q "failed to fetch issue.*skipping edit to avoid data loss" "$LOGFILE"; then
		failed=1
	fi
	if [[ -f "${TEST_ROOT}/unexpected.log" ]]; then
		failed=1
	fi
	print_result "pr_fix_worker aborts on gh issue view failure" "$failed" \
		"Expected return 1, fetch failure log, no issue edit"
	return 0
}

# =============================================================================
# Main
# =============================================================================

setup_test_env
trap teardown_test_env EXIT

test_close_conflicting_pr_skips_on_gh_failure
test_close_conflicting_pr_exact_label_match
test_stale_check_honors_no_takeover
test_stale_check_validates_hours
test_carry_forward_uses_dynamic_fence
test_ci_fix_worker_aborts_on_fetch_failure
test_conflict_fix_worker_aborts_on_fetch_failure
test_pr_fix_worker_aborts_on_fetch_failure

printf '\nRan %d tests, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
