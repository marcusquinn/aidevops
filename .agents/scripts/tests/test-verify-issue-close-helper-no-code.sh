#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#35105: verified no-code triage disposition (check-no-code) must accept a
# merged For/Ref prerequisite PR for a trusted triage issue, while the strict
# file-overlap `check` and all trust/closing-keyword guards stay intact.

set -euo pipefail

PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="${TEST_DIR}/../verify-issue-close-helper.sh"

cat >"$TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	case "${3:-}" in
	300 | 302) printf 'Triage of parent #900. Update `.agents/scripts/target.sh`.\n' ;;
	301) printf 'Unrelated triage without parent link. `.agents/scripts/target.sh`\n' ;;
	*) exit 1 ;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" ]]; then
	case "${2:-}|${4:-}" in
	repos/owner/repo/issues/300\|* | repos/owner/repo/issues/301\|*) printf 'OWNER\n' ;;
	repos/owner/repo/issues/302\|*) printf 'NONE\n' ;;
	repos/owner/repo/pulls/400\|'if .merged_at'* | repos/owner/repo/pulls/401\|'if .merged_at'* | repos/owner/repo/pulls/403\|'if .merged_at'*) printf 'merged\n' ;;
	repos/owner/repo/pulls/402\|'if .merged_at'*) printf 'unmerged\n' ;;
	repos/owner/repo/pulls/400\|*) printf 'Prerequisite.\n\nFor #900\n' ;;
	repos/owner/repo/pulls/401\|*) printf 'Resolves #300\n\nFor #900\n' ;;
	repos/owner/repo/pulls/402\|*) printf 'For #900\n' ;;
	repos/owner/repo/pulls/403\|*) printf 'Unrelated change.\n' ;;
	*) exit 1 ;;
	esac
	exit 0
fi

exit 1
STUB
chmod +x "$TMPDIR/gh"
export PATH="$TMPDIR:$PATH"

assert_no_code() {
	local label="$1"
	local expected="$2"
	local issue="$3"
	local pr="$4"
	local parent="${5:-900}"
	local output rc=0

	output=$(bash "$HELPER_PATH" check-no-code "$issue" "$pr" owner/repo "$parent" 2>&1) || rc=$?
	if [[ "$expected" == "ok" && "$rc" -eq 0 && "$output" == *"VERIFIED-NO-CODE"* ]] ||
		[[ "$expected" == "reject" && "$rc" -ne 0 && "$output" == *"REJECTED-NO-CODE"* ]]; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s (rc=%s)\n%s\n' "$label" "$rc" "$output"
	fi
	return 0
}

assert_no_code "merged For/Ref prerequisite verifies no-code" ok 300 400
assert_no_code "closing keyword for triage issue is rejected" reject 300 401
assert_no_code "unmerged PR is rejected" reject 300 402
assert_no_code "PR without parent link is rejected" reject 300 403
assert_no_code "issue not referencing parent is rejected" reject 301 400
assert_no_code "untrusted issue author is rejected" reject 302 400
assert_no_code "wrong parent number is rejected" reject 300 400 901

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
