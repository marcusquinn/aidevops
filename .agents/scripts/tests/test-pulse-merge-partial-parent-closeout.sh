#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for GH#23937: when a merged PR references a broad parent with
# `For #NNN` / `Ref #NNN`, deterministic post-merge automation must keep the
# parent open but post an explicit partial closeout trail with remaining
# follow-ups.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
readonly _PM_PARENT_TASK_LABEL_NEEDLE=",parent-task,"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
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
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export GH_COMMENT_LOG="${TEST_ROOT}/gh-comments.log"
	export TEST_PR_BODY=""
	export TEST_ISSUE_BODY=""
	export TEST_ISSUE_LABELS=""
	export TEST_EXISTING_COMMENTS="[]"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	: >"$GH_COMMENT_LOG"

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh for test-pulse-merge-partial-parent-closeout.sh
printf '%s\n' "$*" >>"${GH_CALL_LOG}"

if [[ "$1" == "api" && "$2" == *"/issues/23932/comments"* ]]; then
	printf '%s\n' "${TEST_EXISTING_COMMENTS:-[]}"
	exit 0
fi

if [[ "$1" == "api" && "$2" == *"/issues/23932"* ]]; then
	jq -n --arg body "${TEST_ISSUE_BODY:-}" --arg labels "${TEST_ISSUE_LABELS:-}" \
		'{body:$body,labels:($labels | split(",") | map(select(length > 0) | {name:.}))}'
	exit 0
fi

exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh_pr_view() {
	local pr_number="$1"
	shift
	printf '%s\n' "${TEST_PR_BODY:-}"
	return 0
}

gh_issue_comment() {
	printf '%s\n' "$*" >>"$GH_COMMENT_LOG"
	return 0
}

define_functions_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_pm_issue_api\(\) \{/,/^}$/ { print }
		/^_pm_extract_partial_parent_reference\(\) \{/,/^}$/ { print }
		/^_pm_issue_needs_partial_closeout\(\) \{/,/^}$/ { print }
		/^_pm_unmet_acceptance_criteria\(\) \{/,/^}$/ { print }
		/^_pm_handle_partial_parent_closeout\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract partial closeout helpers from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helpers
	eval "$fn_src"
	return 0
}

assert_comment_contains() {
	local pattern="$1"
	local label="$2"
	if grep -q -- "$pattern" "$GH_COMMENT_LOG" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected comment pattern: $pattern"
	fi
	return 0
}

assert_no_comment() {
	local label="$1"
	if [[ ! -s "$GH_COMMENT_LOG" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Unexpected comment: $(tr '\n' ' ' <"$GH_COMMENT_LOG")"
	fi
	return 0
}

assert_api_issue_fetch_count() {
	local expected="$1"
	local label="$2"
	local actual
	actual=$(grep -c 'repos/marcusquinn/aidevops/issues/23932$' "$GH_CALL_LOG" 2>/dev/null || true)
	if [[ "$actual" == "$expected" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected ${expected} issue fetches, saw ${actual}"
	fi
	return 0
}

test_for_reference_posts_partial_closeout() {
	: >"$GH_COMMENT_LOG"
	: >"$LOGFILE"
	export TEST_PR_BODY="For #23932

Delivered leaf work only."
	export TEST_ISSUE_LABELS="enhancement,tier:standard"
	export TEST_ISSUE_BODY="## Summary

Umbrella lifecycle parent.

## Acceptance Criteria

- [ ] Delivered leaf: dependency graph fail-closed unknown blocked-by resolution.
- [ ] Remaining: stale/no_work re-checks.
- [ ] Remaining: candidate ranking suppression.
- [ ] Remaining: worker bootstrap hard-stop."
	export TEST_EXISTING_COMMENTS="[]"

	_pm_handle_partial_parent_closeout "23936" "marcusquinn/aidevops" "Merged dependency graph leaf."

	assert_comment_contains "PARTIAL_PARENT_CLOSEOUT:PR#23936" \
		"For/Ref broad parent: posts dedup marker"
	assert_comment_contains "Remaining: stale/no_work re-checks" \
		"For/Ref broad parent: lists remaining acceptance criteria"
	assert_comment_contains "Do not close this parent" \
		"For/Ref broad parent: records no-close rule"
	assert_api_issue_fetch_count "1" \
		"For/Ref broad parent: fetches issue body and labels once"
	return 0
}

test_alternate_checklist_bullets_detect_parent_and_followups() {
	: >"$GH_COMMENT_LOG"
	: >"$GH_CALL_LOG"
	export TEST_PR_BODY="For #23932"
	export TEST_ISSUE_LABELS="bug,tier:simple"
	export TEST_ISSUE_BODY="Small parent checklist.

* [ ] Remaining: star bullet.
+ [ ] Remaining: plus bullet."
	export TEST_EXISTING_COMMENTS="[]"

	_pm_handle_partial_parent_closeout "23936" "marcusquinn/aidevops" "Leaf fix."

	assert_comment_contains "Remaining: star bullet" \
		"alternate checklist bullets: extracts star task"
	assert_comment_contains "Remaining: plus bullet" \
		"alternate checklist bullets: extracts plus task"
	return 0
}

test_primary_linked_issue_skips_partial_closeout() {
	: >"$GH_COMMENT_LOG"
	: >"$GH_CALL_LOG"
	export TEST_PR_BODY="Resolves #23932

For #23932"
	export TEST_ISSUE_LABELS="parent-task"
	export TEST_ISSUE_BODY="## Acceptance Criteria

- [ ] One
- [ ] Two"
	export TEST_EXISTING_COMMENTS="[]"

	_pm_handle_partial_parent_closeout "23936" "marcusquinn/aidevops" "Leaf fix." "23932"
	assert_no_comment "primary linked issue: partial parent closeout skipped"
	assert_api_issue_fetch_count "0" \
		"primary linked issue: skips issue fetch before duplicate path"
	return 0
}

test_leaf_reference_without_broad_signal_skips_comment() {
	: >"$GH_COMMENT_LOG"
	export TEST_PR_BODY="Ref #23932"
	export TEST_ISSUE_LABELS="bug,tier:simple"
	export TEST_ISSUE_BODY="Small leaf bug report without checklist."
	export TEST_EXISTING_COMMENTS="[]"

	_pm_handle_partial_parent_closeout "23936" "marcusquinn/aidevops" "Leaf fix."
	assert_no_comment "leaf issue: partial parent closeout skipped"
	return 0
}

test_existing_marker_skips_duplicate_comment() {
	: >"$GH_COMMENT_LOG"
	export TEST_PR_BODY="For #23932"
	export TEST_ISSUE_LABELS="parent-task"
	export TEST_ISSUE_BODY="## Acceptance Criteria

- [ ] One
- [ ] Two"
	export TEST_EXISTING_COMMENTS='[{"body":"<!-- PARTIAL_PARENT_CLOSEOUT:PR#23936 -->"}]'

	_pm_handle_partial_parent_closeout "23936" "marcusquinn/aidevops" "Leaf fix."
	assert_no_comment "duplicate marker: comment skipped"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_functions_under_test; then
		printf 'FATAL: function extraction failed\n' >&2
		return 1
	fi

	test_for_reference_posts_partial_closeout
	test_alternate_checklist_bullets_detect_parent_and_followups
	test_primary_linked_issue_skips_partial_closeout
	test_leaf_reference_without_broad_signal_skips_comment
	test_existing_marker_skips_duplicate_comment

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
