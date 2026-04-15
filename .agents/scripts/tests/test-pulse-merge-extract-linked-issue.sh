#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for t2108 / GH#19051: pulse-merge.sh _extract_linked_issue
# must treat the PR body keyword as AUTHORITATIVE. The PR-title fallback
# (GH#NNN: prefix) may only return an issue number when the PR body ALSO
# contains a GitHub-native closing keyword (Closes/Fixes/Resolves + #NNN).
#
# Root cause: every PR in this repo follows the canonical title format
# "GH#NNN: description". _extract_linked_issue fell back to that title
# prefix even when the body intentionally used "For #NNN" or "Ref #NNN"
# to avoid auto-close. The result: planning-only and multi-PR roadmap
# PRs silently closed their linked issues on merge.
#
# Discovered live on 2026-04-15 — the t2105 brief PR (#19043) hit this
# exact pattern 14 minutes after the t2099 parent-task label guard merged.
#
# Strategy: extract _extract_linked_issue from pulse-merge.sh, eval it,
# and exercise it against a mock `gh pr view` stub that returns canned
# title + body fixtures. Assert the four scenarios below.
#
# Scenarios:
#   1. "For #NNN" body (no closing keyword) + GH#NNN title → empty
#      (regression guard for the t2105 incident)
#   2. "Resolves #NNN" body + GH#NNN title → issue number
#      (normal leaf close path still works)
#   3. "Closes #99999" body + GH#19042 title → 19042
#      (title disambiguates when body references a different issue)
#   4. "Ref #NNN" body (no closing keyword) + tNNN title → empty
#      (tNNN: title format has no GH# — both gates fail)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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

# Prepare a mock `gh` that:
#   - Returns TEST_PR_TITLE when queried for PR title JSON
#   - Returns TEST_PR_BODY when queried for PR body JSON
#   - Stays silent for everything else
setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export TEST_PR_TITLE=""
	export TEST_PR_BODY=""
	: >"$LOGFILE"

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh for test-pulse-merge-extract-linked-issue.sh
# Serves canned PR title/body fixtures via environment variables.

# gh pr view NNN --repo SLUG --json title --jq '.title // empty'
if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"--json title"* ]]; then
	printf '%s\n' "${TEST_PR_TITLE:-}"
	exit 0
fi

# gh pr view NNN --repo SLUG --json body --jq '.body // empty'
if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"--json body"* ]]; then
	printf '%s\n' "${TEST_PR_BODY:-}"
	exit 0
fi

# Everything else — silent success
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

# Extract the function under test from pulse-merge.sh and eval it.
define_function_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_extract_linked_issue\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract _extract_linked_issue from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$fn_src"
	return 0
}

# Assert that the function returns (on stdout) the expected value.
assert_returns() {
	local expected="$1"
	local label="$2"
	local actual
	actual=$(_extract_linked_issue "1" "owner/repo")
	if [[ "$actual" == "$expected" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected: '${expected}', got: '${actual}'"
	fi
	return 0
}

# Scenario 1: "For #NNN" body (no closing keyword) + GH#NNN title → empty
# This is the regression guard for the t2105 incident.
test_for_ref_body_no_close_returns_empty() {
	export TEST_PR_TITLE="GH#19042: plan t2105"
	export TEST_PR_BODY="For #19042

No closing keyword."
	assert_returns "" \
		"scenario1: For #NNN body with GH#NNN title returns empty (regression guard)"
	return 0
}

# Scenario 2: "Resolves #NNN" body + GH#NNN title → issue number
# The normal leaf-issue close path must still work after the fix.
test_resolves_body_returns_issue() {
	export TEST_PR_TITLE="GH#19042: fix bug"
	export TEST_PR_BODY="Resolves #19042
"
	assert_returns "19042" \
		"scenario2: Resolves #NNN body with GH#NNN title returns issue number"
	return 0
}

# Scenario 3: "Closes #99999" body + GH#19042 title → 19042
# Title disambiguates when the body's closing keyword references a different
# issue number (historical behaviour preserved: title is the primary identifier).
test_title_disambiguates_when_body_has_different_issue() {
	export TEST_PR_TITLE="GH#19042: cross-issue"
	export TEST_PR_BODY="Closes #99999

Also references #19042."
	assert_returns "19042" \
		"scenario3: title issue number preferred when body has closing keyword"
	return 0
}

# Scenario 4: "Ref #NNN" body + tNNN title → empty
# tNNN: title format has no GH# — title regex misses.
# "Ref #NNN" body has no closing keyword — body check also misses.
# Both gates fail → empty.
test_ref_body_tnnn_title_returns_empty() {
	export TEST_PR_TITLE="t2108: planning brief"
	export TEST_PR_BODY="Ref #19051
"
	assert_returns "" \
		"scenario4: Ref #NNN body with tNNN title (no GH#) returns empty"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_function_under_test; then
		printf 'FATAL: function extraction failed\n' >&2
		return 1
	fi

	test_for_ref_body_no_close_returns_empty
	test_resolves_body_returns_issue
	test_title_disambiguates_when_body_has_different_issue
	test_ref_body_tnnn_title_returns_empty

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
