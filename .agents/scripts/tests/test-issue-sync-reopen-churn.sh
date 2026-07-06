#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for the TODO reopen guard notification-churn fixes.
set -euo pipefail

PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/200" ]]; then
	printf '{"number":200,"pull_request":{}}\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/201" ]]; then
	printf '{"number":201,"title":"plain issue"}\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/202/comments" ]]; then
	printf '[{"body":"Reopened: TODO.md still has this as `[ ]` (open) and no merged PR was found."}]\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/203/comments" ]]; then
	printf '[{"body":"Unrelated comment"}]\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/204/comments" ]]; then
	printf '{"message":"server error"}\n'
	exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$TMPDIR/gh"

cat >"$TMPDIR/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '\n<!-- aidevops:sig -->\n---\n[mock-sig]\n'
exit 0
STUB
chmod +x "$TMPDIR/gh-signature-helper.sh"
export PATH="$TMPDIR:$PATH"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="${TEST_DIR}/../issue-sync-helper-close.sh"

# shellcheck source=../issue-sync-helper-close.sh
source "$HELPER_PATH"

check_success() {
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s\n' "$label"
	fi
	return 0
}

check_failure() {
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s\n' "$label"
	else
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	fi
	return 0
}

check_success "PR refs are identified before reopen" _reopen_ref_is_pull_request "owner/repo" "200"
check_failure "plain issue refs are not treated as PRs" _reopen_ref_is_pull_request "owner/repo" "201"
check_success "prefetched PR refs skip redundant API calls" _reopen_ref_is_pull_request "owner/repo" "999" '{"number":999,"pull_request":{}}'
check_failure "unexpected issue payloads are not treated as PRs" _reopen_ref_is_pull_request "owner/repo" "999" '{"message":"server error"}'
check_success "prior canonical reopen comments are detected" _has_prior_reopen_comment "owner/repo" "202"
check_failure "unrelated comments do not suppress reopen" _has_prior_reopen_comment "owner/repo" "203"
check_failure "unexpected comments payloads do not suppress reopen" _has_prior_reopen_comment "owner/repo" "204"
check_success "GraphQL NOT_PLANNED reason is skipped" _is_not_planned_state_reason "NOT_PLANNED"
check_success "REST not_planned reason is skipped" _is_not_planned_state_reason "not_planned"
check_success "hyphenated not-planned reason is skipped" _is_not_planned_state_reason "not-planned"
check_failure "completed reason is not treated as not planned" _is_not_planned_state_reason "COMPLETED"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
