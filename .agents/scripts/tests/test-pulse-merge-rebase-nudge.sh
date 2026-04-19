#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _post_rebase_nudge_on_interactive_conflicting() (GH#18650 / Fix 4).
#
# The nudge is posted by the pulse merge pass when it skips auto-close on an
# origin:interactive CONFLICTING PR. These tests exercise the helper in
# isolation with a mock gh stub and a mock _gh_idempotent_comment so we can
# verify the body construction (marker presence, rebase command, branch
# interpolation) without touching a real repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-conflict.sh"  # GH#19836: rebase-nudge helper extracted here

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
LAST_NUDGE_ARGS=""
LAST_NUDGE_BODY=""

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

	# Stub `gh pr view --json headRefName` to return a fixed branch name.
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "pr" && "${2:-}" == "view" && "$*" == *"headRefName"* ]]; then
	printf 'fix/example-branch\n'
	exit 0
fi
# Any other gh call — return empty
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

# Extract the helper under test from pulse-merge.sh and eval it so we run
# against the real source code, not a duplicate. Same pattern as the
# force-dispatch and bot-cleanup test helpers.
define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_post_rebase_nudge_on_interactive_conflicting\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _post_rebase_nudge_on_interactive_conflicting from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

# Mock _gh_idempotent_comment that captures the body for inspection.
define_mock_idempotent_comment() {
	_gh_idempotent_comment() {
		LAST_NUDGE_ARGS="entity=$1 repo=$2 marker_len=${#3} type=${5:-issue}"
		LAST_NUDGE_BODY="$4"
		return 0
	}
	return 0
}

# No-op helper that intentionally leaves _gh_idempotent_comment undefined.
undefine_idempotent_comment() {
	unset -f _gh_idempotent_comment 2>/dev/null || true
	return 0
}

test_nudge_body_contains_marker_and_branch() {
	define_mock_idempotent_comment
	LAST_NUDGE_BODY=""
	LAST_NUDGE_ARGS=""

	_post_rebase_nudge_on_interactive_conflicting "18604" "marcusquinn/aidevops"

	if [[ "$LAST_NUDGE_BODY" != *"<!-- pulse-rebase-nudge -->"* ]]; then
		print_result "nudge body contains the idempotency marker" 1 \
			"Expected marker '<!-- pulse-rebase-nudge -->' in body"
		return 0
	fi
	if [[ "$LAST_NUDGE_BODY" != *"wt switch fix/example-branch"* ]]; then
		print_result "nudge body contains the idempotency marker" 1 \
			"Expected 'wt switch fix/example-branch' in body (branch interpolation)"
		return 0
	fi
	if [[ "$LAST_NUDGE_BODY" != *"git push --force-with-lease"* ]]; then
		print_result "nudge body contains the idempotency marker" 1 \
			"Expected 'git push --force-with-lease' in body"
		return 0
	fi
	print_result "nudge body contains the idempotency marker" 0
	return 0
}

test_nudge_posts_as_pr_entity() {
	define_mock_idempotent_comment
	LAST_NUDGE_ARGS=""

	_post_rebase_nudge_on_interactive_conflicting "18604" "marcusquinn/aidevops"

	if [[ "$LAST_NUDGE_ARGS" != *"type=pr"* ]]; then
		print_result "nudge posts as PR entity, not issue" 1 \
			"Expected entity_type='pr' in idempotent-comment call. Got: ${LAST_NUDGE_ARGS}"
		return 0
	fi
	print_result "nudge posts as PR entity, not issue" 0
	return 0
}

test_nudge_passes_pr_number_and_repo() {
	define_mock_idempotent_comment
	LAST_NUDGE_ARGS=""

	_post_rebase_nudge_on_interactive_conflicting "18604" "marcusquinn/aidevops"

	if [[ "$LAST_NUDGE_ARGS" != *"entity=18604"* ]]; then
		print_result "nudge passes PR number and repo slug" 1 \
			"Expected entity=18604. Got: ${LAST_NUDGE_ARGS}"
		return 0
	fi
	if [[ "$LAST_NUDGE_ARGS" != *"repo=marcusquinn/aidevops"* ]]; then
		print_result "nudge passes PR number and repo slug" 1 \
			"Expected repo=marcusquinn/aidevops. Got: ${LAST_NUDGE_ARGS}"
		return 0
	fi
	print_result "nudge passes PR number and repo slug" 0
	return 0
}

test_noops_when_idempotent_helper_undefined() {
	undefine_idempotent_comment
	LAST_NUDGE_BODY=""

	# Must return 0 (not fail) and not call anything.
	if ! _post_rebase_nudge_on_interactive_conflicting "18604" "marcusquinn/aidevops"; then
		print_result "no-ops when _gh_idempotent_comment is undefined" 1 \
			"Expected return 0 on missing helper (fail-open)"
		return 0
	fi
	# Log should record the skip reason.
	if ! grep -q "_gh_idempotent_comment not defined" "$LOGFILE" 2>/dev/null; then
		print_result "no-ops when _gh_idempotent_comment is undefined" 1 \
			"Expected log entry about missing helper"
		return 0
	fi
	print_result "no-ops when _gh_idempotent_comment is undefined" 0
	return 0
}

test_noops_on_invalid_pr_number() {
	define_mock_idempotent_comment
	LAST_NUDGE_ARGS=""

	if ! _post_rebase_nudge_on_interactive_conflicting "not-a-number" "marcusquinn/aidevops"; then
		print_result "no-ops on invalid PR number" 1 \
			"Expected return 0 on invalid input"
		return 0
	fi
	if [[ -n "$LAST_NUDGE_ARGS" ]]; then
		print_result "no-ops on invalid PR number" 1 \
			"Expected no mock call. Got: ${LAST_NUDGE_ARGS}"
		return 0
	fi
	print_result "no-ops on invalid PR number" 0
	return 0
}

test_noops_on_empty_repo_slug() {
	define_mock_idempotent_comment
	LAST_NUDGE_ARGS=""

	if ! _post_rebase_nudge_on_interactive_conflicting "18604" ""; then
		print_result "no-ops on empty repo slug" 1 \
			"Expected return 0 on invalid input"
		return 0
	fi
	if [[ -n "$LAST_NUDGE_ARGS" ]]; then
		print_result "no-ops on empty repo slug" 1 \
			"Expected no mock call. Got: ${LAST_NUDGE_ARGS}"
		return 0
	fi
	print_result "no-ops on empty repo slug" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_nudge_body_contains_marker_and_branch
	test_nudge_posts_as_pr_entity
	test_nudge_passes_pr_number_and_repo
	test_noops_when_idempotent_helper_undefined
	test_noops_on_invalid_pr_number
	test_noops_on_empty_repo_slug

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
