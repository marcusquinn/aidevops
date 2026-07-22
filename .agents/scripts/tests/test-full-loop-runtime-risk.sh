#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#28466 runtime-risk PR body classification.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
TESTS_RUN=0
TESTS_FAILED=0

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message" >&2
	return 0
}

assert_contains() {
	local name="$1"
	local actual="$2"
	local expected="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == *"$expected"* ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: missing %s\n' "$name" "$expected"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# shellcheck source=../full-loop-helper-risk.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-risk.sh"
# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-commit.sh"

high_body=$(_build_pr_body \
	"28466" \
	"Fix polling-loop state-machine behavior" \
	"runtime-verified with a polling fixture" \
	"src/poller.sh, tests/test-poller.sh" \
	"<!-- aidevops:sig -->" \
	"Resolves")
assert_contains "polling fixture derives High" "$high_body" "**Risk level:** High"
assert_contains "High fixture records runtime evidence" "$high_body" "**Verification:** runtime-verified"
assert_contains "closing keyword remains compatible" "$high_body" "Resolves #28466"
assert_contains "signature remains compatible" "$high_body" "<!-- aidevops:sig -->"

TESTS_RUN=$((TESTS_RUN + 1))
if _build_pr_body "1" "API endpoint" "unit tests pass" "src/api.sh" "" >/dev/null 2>&1; then
	printf 'FAIL High without runtime evidence is rejected\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
else
	printf 'PASS High without runtime evidence is rejected\n'
fi

TESTS_RUN=$((TESTS_RUN + 1))
if _build_pr_body "2" "Credential rotation" "self-assessed" "src/auth.sh" "" "Resolves" "Critical" "self-assessed" >/dev/null 2>&1; then
	printf 'FAIL Critical without runtime evidence is rejected\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
else
	printf 'PASS Critical without runtime evidence is rejected\n'
fi

low_body=$(_build_pr_body \
	"3" \
	"Update documentation and tests" \
	"focused tests pass" \
	"docs/runtime.md, .agents/scripts/tests/test-docs.sh" \
	"" \
	"Resolves")
assert_contains "docs and tests remain Low" "$low_body" "**Risk level:** Low"
assert_contains "Low fixture is self-assessed" "$low_body" "**Verification:** self-assessed"

runtime_risk=""
testing_level=""
issue_number=""
commit_message=""
pr_title=""
summary_what=""
summary_testing=""
summary_decisions=""
allow_parent_close=0
skip_hooks=0
skip_rebase=0
extra_labels=()
_parse_commit_and_pr_args --issue 4 --message "test" --risk-level High --testing-level runtime-verified
assert_contains "risk level flag is accepted" "$runtime_risk" "High"
assert_contains "testing level flag is accepted" "$testing_level" "runtime-verified"

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
