#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-clear-active-status-on-release-no-pr.sh — t2451 regression guard.
#
# Asserts: when `clear_active_status_on_release` is called on an issue that
# has NO open linked PR, the helper preserves its pre-t2451 behaviour
# byte-for-byte:
#
#   1. Removes --remove-label status:queued, status:claimed, status:in-progress, status:in-review
#   2. Removes --remove-assignee "$worker_login" (when provided)
#
# This complements test-clear-active-status-on-release-preserves-pr.sh which
# covers the open-PR case (Fix C of t2451). Together they assert the
# conditional branch: open PR → preserve; no open PR → full cleanup.
#
# NOTE: not using `set -e` — assertions capture non-zero exits.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
export GH_CALLS_FILE="${TEST_ROOT}/gh_calls.log"
export GH_VIEW_LABELS="${TEST_ROOT}/gh_view_labels.txt"
export GH_PR_LIST_JSON="${TEST_ROOT}/gh_pr_list.json"

write_stub_gh() {
	: >"$GH_CALLS_FILE"
	: >"$GH_VIEW_LABELS"
	: >"$GH_PR_LIST_JSON"
	cat >"${STUB_DIR}/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	cat "${GH_VIEW_LABELS}" 2>/dev/null || true
	exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
	cat "${GH_PR_LIST_JSON}" 2>/dev/null || true
	exit 0
fi
printf '%s\n' "$*" >>"${GH_CALLS_FILE}"
exit 0
STUBEOF
	chmod +x "${STUB_DIR}/gh"
	return 0
}

export PATH="${STUB_DIR}:${PATH}"
write_stub_gh

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"

reset_stub() {
	: >"$GH_CALLS_FILE"
	: >"$GH_VIEW_LABELS"
	: >"$GH_PR_LIST_JSON"
	return 0
}

assert_grep() {
	local pattern="$1" label="$2"
	if grep -q -- "$pattern" "$GH_CALLS_FILE" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found in gh calls"
	fi
	return 0
}

# -------------------------------------------------------------------
# Case 1: empty PR list → full cleanup (pre-t2451 byte-for-byte)
# -------------------------------------------------------------------
reset_stub
printf '[]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "remove-label status:queued" "removes queued (no PR)"
assert_grep "remove-label status:claimed" "removes claimed (no PR)"
assert_grep "remove-label status:in-progress" "removes in-progress (no PR)"
assert_grep "remove-label status:in-review" "removes in-review (no PR)"
assert_grep "remove-assignee alice" "removes assignee alice (no PR)"

# -------------------------------------------------------------------
# Case 2: entirely empty gh pr list output (offline/error case)
#         → full cleanup (fail-open preserves pre-t2451 behaviour)
# -------------------------------------------------------------------
reset_stub
: >"$GH_PR_LIST_JSON" # deliberately empty file
clear_active_status_on_release 20156 owner/repo bob
assert_grep "remove-label status:in-review" "full cleanup when gh pr list returns empty"
assert_grep "remove-assignee bob" "removes assignee when gh pr list returns empty"

# -------------------------------------------------------------------
# Case 3: PR exists but references a DIFFERENT issue → full cleanup
# -------------------------------------------------------------------
reset_stub
printf '[{"number":42,"body":"Resolves #99999"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "remove-label status:in-review" "full cleanup when PR references different issue"
assert_grep "remove-assignee alice" "removes assignee when PR references different issue"

# -------------------------------------------------------------------
# Case 4: PR exists with only planning references (For/Ref) → full cleanup
#         (planning-only references must NOT block assignee cleanup, t2046)
# -------------------------------------------------------------------
reset_stub
printf '[{"number":42,"body":"For #20156 — tracks this work"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "remove-label status:in-review" "full cleanup when PR only has For #N"
assert_grep "remove-assignee alice" "removes assignee when PR only has For #N"

reset_stub
printf '[{"number":42,"body":"Ref #20156"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "remove-assignee alice" "removes assignee when PR only has Ref #N"

# -------------------------------------------------------------------
# Case 5: empty worker_login + no PR → labels cleared, no assignee call
# -------------------------------------------------------------------
reset_stub
printf '[]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo ""
assert_grep "remove-label status:in-review" "clears in-review with empty worker_login (no PR)"
if grep -q "remove-assignee" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "no assignee call when worker_login empty (no PR)" 1 "unexpected assignee call"
else
	print_result "no assignee call when worker_login empty (no PR)" 0
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
