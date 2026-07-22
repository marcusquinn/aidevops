#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#28489: issue sync list reads must use the shared
# timeout path and must not convert transport failures into an empty success.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

# shellcheck source=../issue-sync-helper.sh
source "${SCRIPTS_DIR}/issue-sync-helper.sh"

cat >"${TMP_DIR}/gh" <<'GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALL_LOG}"
sleep 5
printf '[]\n'
GH_EOF
chmod +x "${TMP_DIR}/gh"

export GH_CALL_LOG="${TMP_DIR}/gh-calls.log"
export PATH="${TMP_DIR}:${PATH}"
export AIDEVOPS_GH_READ_TIMEOUT=1

# Keep this test on the primary gh_issue_list path. REST routing has separate
# coverage and would add a rate-limit probe before the operation under test.
_rest_read_first_enabled() {
	return 1
}
_rest_should_fallback() {
	return 1
}
github_app_should_route_rest() {
	return 1
}

started_at=$(date +%s)
list_rc=0
list_output=$(gh_list_issues example/repo open 200) || list_rc=$?
elapsed=$(($(date +%s) - started_at))

[[ "$list_rc" -eq 124 ]] || fail "timed-out issue list returned rc=${list_rc}, expected 124"
[[ -z "$list_output" ]] || fail "timed-out issue list emitted false-success output: ${list_output}"
[[ "$elapsed" -le 3 ]] || fail "issue list exceeded read timeout allowance (${elapsed}s)"
grep -q '^issue list --repo example/repo --state open --limit 200 --json number,title,assignees,state,labels$' \
	"$GH_CALL_LOG" || fail "issue list did not preserve the requested arguments"
pass "issue sync list reads are bounded and propagate timeout failure"

gh_issue_list() {
	return 23
}
list_rc=0
list_output=$(gh_list_issues example/repo closed 500) || list_rc=$?
[[ "$list_rc" -eq 23 ]] || fail "canonical wrapper failure was not propagated"
[[ -z "$list_output" ]] || fail "canonical wrapper failure was converted into data"
pass "issue sync does not convert list failures into an empty success"
