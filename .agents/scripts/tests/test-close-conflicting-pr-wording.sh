#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for the `_close_conflicting_pr` close-comment wording
# (GH#17574 / t2032).
#
# Verifies that when the deterministic merge pass detects "work already
# on main", the close comment:
#   1. Says "landed on main" — NOT "committed directly to main"
#   2. Includes "(via PR #NNN)" when the matching commit has a
#      squash-merge suffix
#   3. Omits the parenthetical when no PR number is parseable
#
# The test exercises the function against stubbed `gh` calls; the real
# pulse-merge.sh is sourced so we test the live code path.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
STUB_DIR=""
CAPTURED_COMMENT_FILE=""

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
	local commit_subjects="$1"

	TEST_ROOT=$(mktemp -d)
	STUB_DIR="${TEST_ROOT}/stubs"
	CAPTURED_COMMENT_FILE="${TEST_ROOT}/captured-comment.txt"
	mkdir -p "$STUB_DIR"
	: >"$CAPTURED_COMMENT_FILE"

	# Stub `gh` — returns predetermined commit subjects for `gh api ... /commits`
	# and captures the `--comment` body for `gh pr close`.
	cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
if [[ "\$1" == "api" ]]; then
	# Simulate: gh api repos/.../commits --jq '.[] | .commit.message | split("\\n")[0]'
	cat <<'SUBJECTS_EOF'
${commit_subjects}
SUBJECTS_EOF
	exit 0
fi

if [[ "\$1" == "pr" && "\$2" == "close" ]]; then
	# Capture --comment body to the file so the test can assert on it.
	shift 2
	while [[ \$# -gt 0 ]]; do
		if [[ "\$1" == "--comment" ]]; then
			printf '%s' "\$2" >"${CAPTURED_COMMENT_FILE}"
			shift 2
		else
			shift
		fi
	done
	exit 0
fi

if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
	# Used for origin:interactive label check — return empty labels.
	echo ""
	exit 0
fi

# Fallback — unknown stub invocation
exit 0
STUB_EOF
	chmod +x "${STUB_DIR}/gh"

	export PATH="${STUB_DIR}:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Source only the `_close_conflicting_pr` function from pulse-merge.sh in
# isolation. The parent module is sourced by pulse-wrapper.sh and depends
# on bootstrap state, so we extract just the function body into a temp file
# and source that.
load_function_under_test() {
	local repo_root
	repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
	local src="${repo_root}/.agents/scripts/pulse-merge.sh"
	local tmp_fn="${TEST_ROOT}/_close_conflicting_pr.sh"

	# Extract from "_close_conflicting_pr() {" through the matching closing
	# brace at column 0. Robust for this file because pulse-merge.sh uses
	# tab-indented function bodies and column-0 closing braces.
	awk '
		/^_close_conflicting_pr\(\) \{$/ { in_fn=1 }
		in_fn { print }
		in_fn && /^\}$/ { exit }
	' "$src" >"$tmp_fn"

	# shellcheck source=/dev/null
	source "$tmp_fn"
	return 0
}

# ── Test cases ──

test_wording_with_squash_merge_pr_number() {
	# Matching commit has the standard squash-merge "(#18480)" suffix
	setup_test_env "t2017: teach /review-issue-pr to do temporal-duplicate checks (#18480)
chore: something else
feat: another unrelated commit"

	load_function_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr with temporal-duplicate checks"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if ! printf '%s' "$body" | grep -q "has already landed on main (via PR #18480)"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi

	print_result "cites '(via PR #NNN)' when matching commit has squash-merge suffix" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_test_env
	return 0
}

test_wording_without_pr_number_fallback() {
	# Matching commit is a direct-to-main commit with no "(#NNN)" suffix
	setup_test_env "t2017: direct push to main without going through a PR
chore: unrelated"

	load_function_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if ! printf '%s' "$body" | grep -q "has already landed on main,"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "(via PR #"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi

	print_result "omits parenthetical when no PR number parseable" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_test_env
	return 0
}

test_no_match_uses_fallback_message() {
	# No commit on main matches the task ID → falls through to the
	# "work NOT on main" branch; comment must NOT claim "landed on main".
	setup_test_env "chore: totally unrelated commit
feat: still unrelated"

	load_function_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if printf '%s' "$body" | grep -q "landed on main"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi
	if ! printf '%s' "$body" | grep -q "merge conflicts"; then
		result=1
	fi

	print_result "no-match uses 're-attempt' fallback, not 'landed on main'" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_test_env
	return 0
}

# ── Run all tests ──

test_wording_with_squash_merge_pr_number
test_wording_without_pr_number_fallback
test_no_match_uses_fallback_message

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
