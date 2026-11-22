#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36766: classify all branch pages without turning API failures into no_work.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/pulse-dispatch-dedup-layers.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
PR_COUNT=0
BRANCH_PAGES='[[],[]]'
PR_RC=0
BRANCH_RC=0
gh_pr_list() {
	printf '%s' "$PR_COUNT"
	return "$PR_RC"
}
gh() {
	local args="$*"
	[[ "$args" == *"--paginate --slurp"* && "$args" != *"--jq"* ]] || return 1
	printf '%s' "$BRANCH_PAGES"
	return "$BRANCH_RC"
}
assert_type() {
	local expected="$1" actual=""
	actual=$(_classify_stale_recovery_crash_type 42 owner/repo)
	[[ "$actual" == "$expected" ]] || { printf 'FAIL expected=%s actual=%s\n' "$expected" "$actual"; return 1; }
	printf 'PASS classifier=%s\n' "$expected"
	return 0
}
BRANCH_PAGES='[[{"name":"unrelated"}],[{"name":"feature/auto-gh42"}]]'
assert_type partial
BRANCH_PAGES='[[{"name":"feature/auto-gh42"}],[]]'
assert_type partial
BRANCH_PAGES='[[{"name":"feature/auto-issue-42"}]]'
assert_type partial
BRANCH_PAGES='[[{"name":"feature/auto-gh420"}],[]]'
assert_type no_work
BRANCH_PAGES='[[]]'
assert_type no_work
BRANCH_RC=1
assert_type unknown
BRANCH_RC=0
BRANCH_PAGES='not json'
assert_type unknown
BRANCH_PAGES='[]'
assert_type unknown
BRANCH_PAGES='[[{}]]'
assert_type unknown
BRANCH_PAGES='[[]]'
PR_RC=1
assert_type unknown
BRANCH_PAGES='[[{"name":"feature/auto-gh42"}]]'
assert_type partial
PR_RC=0
PR_COUNT=1
BRANCH_RC=1
assert_type partial
PR_COUNT=invalid
BRANCH_RC=0
BRANCH_PAGES='[[]]'
assert_type unknown

# Exercise the real layer with an unknown classifier result: stale ownership
# cleanup may continue, but unavailable evidence must not increment fast-fail.
mkdir "${TEST_ROOT}/helpers"
printf '#!/usr/bin/env bash\nprintf "STALE_RECOVERED old dispatch claim\\n"\nexit 1\n' >"${TEST_ROOT}/helpers/dispatch-dedup-helper.sh"
chmod +x "${TEST_ROOT}/helpers/dispatch-dedup-helper.sh"
SCRIPT_DIR="${TEST_ROOT}/helpers"
fast_fail_record() {
	: >"${TEST_ROOT}/fast-fail-called"
	return 0
}
rc=0
_dedup_layer6_assignee_and_stale 42 owner/repo runner || rc=$?
[[ "$rc" -eq 1 ]]
[[ ! -e "${TEST_ROOT}/fast-fail-called" ]]
grep -q 'evidence unavailable' "$LOGFILE"
printf 'PASS unknown evidence skips fast-fail\n'
