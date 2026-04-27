#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-large-file-gate-continuation-verify.sh — t2164 Fix B regression guard.
#
# `_large_file_gate_create_debt_issue()` in pulse-dispatch-large-file-gate.sh
# previously short-circuited as "recently-closed — continuation" whenever a
# closed file-size-debt issue mentioned the file's basename within the
# 30-day reopen window (GH#18960). This had no outcome verification: a
# closed function-complexity-debt issue whose merge PR did NOT reduce the file
# below the file-size threshold would be cited as in-flight continuation,
# permanently stranding the file behind the gate.
#
# Concrete failure (GH#19415):
#   - function-complexity-debt #18706 ("reduce function complexity in
#     issue-sync-helper.sh, 1 functions >100 lines") closed by PR #18715,
#     which decomposed cmd_enrich() but added net +29 lines (file went
#     from ~2165 to 2194 lines).
#   - The large-file gate (file > 2000) then fired on a different parent
#     issue and posted "Simplification issues: #18706 (recently-closed —
#     continuation)" — phantom continuation; nothing was in flight to
#     reduce file size.
#
# Fix (t2164): add a wc -l verification step in the recently-closed branch.
# Only short-circuit as continuation when the file is now under threshold.
# If still over, log and fall through to file a fresh debt issue. Preserve
# the pre-t2164 behaviour (trust the closed signal) when repo_path is
# missing or the file isn't on disk in this checkout — measurement
# unavailable is safer-as-continuation than safer-as-duplicate.
#
# Tests:
#   1. Closed exists, file UNDER threshold, repo_path provided
#      → returns "(recently-closed — continuation)"
#   2. Closed exists, file OVER threshold, repo_path provided
#      → does NOT return continuation; creates new issue with prior-attempt ref
#   3. Closed exists, no repo_path
#      → returns "(recently-closed — continuation)" (backward-compat fallback)
#   4. Closed exists, repo_path set but file not on disk
#      → returns "(recently-closed — continuation)" (measurement unavailable)
#   5. No open, no closed match
#      → returns "(new)"
#
# Cross-references: GH#19415 / t2152 (the blocked investigation that
# surfaced this bug), GH#18960 (the dedup the bug exists inside),
# GH#19483 / t2164 (this fix).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
GATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2164.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
export LOGFILE
LARGE_FILE_LINE_THRESHOLD=2000

# Files that exercise the threshold (over and under)
OVER_FILE="${TMP}/over.sh"
UNDER_FILE="${TMP}/under.sh"
yes ":" 2>/dev/null | head -n 2050 >"$OVER_FILE"
yes ":" 2>/dev/null | head -n 100 >"$UNDER_FILE"

# =============================================================================
# Stub state — writeable by stubs, read by assertions
# =============================================================================
GH_OPEN_RESPONSE=""   # what the open-issue search returns
GH_CLOSED_RESPONSE="" # what the closed-issue search returns
GH_CALLS_LOG="${TMP}/gh_calls.log"
GH_CREATE_RESPONSE_URL=""
: >"$GH_CALLS_LOG"

# =============================================================================
# Stubs — defined AFTER source so they shadow whatever the module loaded
# =============================================================================
# shellcheck source=/dev/null
source "$GATE_SCRIPT"

# t2995: define wrapper stubs so the gate's gh_issue_list calls reach the
# gh() shell-function stub below. Without these, gh_issue_list resolves to
# a missing external command (rc=127), which the old gate code path
# swallowed as "no match" but the new t2995 path correctly treats as
# "lookup failed → defer".
gh_issue_list() {
	gh issue list "$@"
	return $?
}

# t2995: no-op the 2-second retry sleep introduced for search-index lag
# so the test doesn't actually pause.
sleep() { return 0; }

gh() {
	# Log every call for debugging
	printf '%s\n' "gh $*" >>"$GH_CALLS_LOG"

	# Pattern-match on the args we care about.
	# Open file-size-debt search:
	#   gh issue list --repo X --state open --label file-size-debt --search ...
	# Closed file-size-debt search:
	#   gh issue list --repo X --state closed --label file-size-debt --search ...
	local saw_open="false" saw_closed="false"
	local arg
	for arg in "$@"; do
		case "$arg" in
		open) saw_open="true" ;;
		closed) saw_closed="true" ;;
		esac
	done

	if [[ "$1" == "issue" && "$2" == "list" ]]; then
		if [[ "$saw_closed" == "true" ]]; then
			printf '%s\n' "$GH_CLOSED_RESPONSE"
			return 0
		fi
		if [[ "$saw_open" == "true" ]]; then
			printf '%s\n' "$GH_OPEN_RESPONSE"
			return 0
		fi
	fi

	# label create — silent no-op
	if [[ "$1" == "label" && "$2" == "create" ]]; then
		return 0
	fi

	# Anything else — silent no-op
	return 0
}

gh_create_issue() {
	printf '%s\n' "gh_create_issue $*" >>"$GH_CALLS_LOG"
	# Emit a synthetic issue URL so _new_num parsing succeeds
	if [[ -n "$GH_CREATE_RESPONSE_URL" ]]; then
		printf '%s\n' "$GH_CREATE_RESPONSE_URL"
	fi
	return 0
}

# =============================================================================
# Assertions
# =============================================================================
assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected: %q\n' "$expected"
	printf '       actual:   %q\n' "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected to contain: %q\n' "$needle"
	printf '       actual:              %q\n' "$haystack"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# =============================================================================
# Tests
# =============================================================================
printf '\n=== test-large-file-gate-continuation-verify.sh (t2164 Fix B) ===\n\n'

# ---- Test 1 — closed exists, file UNDER threshold → continuation ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_CREATE_RESPONSE_URL=""
out=$(_large_file_gate_create_debt_issue "under.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"closed + file under threshold → continuation" \
	"#18706 (recently-closed — continuation)" \
	"$out"

# ---- Test 2 — closed exists, file OVER threshold → fall through to new ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_CREATE_RESPONSE_URL="https://github.com/owner/repo/issues/77777"
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"closed + file over threshold → NEW (not continuation, GH#19415 root cause)" \
	"#77777 (new)" \
	"$out"
assert_contains \
	"file-over-threshold path logs the prior-attempt skip" \
	"prior file-size-debt #18706 closed but over.sh still 2050 lines" \
	"$(cat "$LOGFILE")"

# ---- Test 3 — closed exists, no repo_path → backward-compat continuation ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_CREATE_RESPONSE_URL=""
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo")
assert_eq \
	"closed + no repo_path → continuation (backward-compat fallback)" \
	"#18706 (recently-closed — continuation)" \
	"$out"

# ---- Test 4 — closed exists, repo_path set but file missing → continuation ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_CREATE_RESPONSE_URL=""
out=$(_large_file_gate_create_debt_issue "missing.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"closed + file missing on disk → continuation (measurement unavailable)" \
	"#18706 (recently-closed — continuation)" \
	"$out"

# ---- Test 5 — no open, no closed → creates new ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE=""
GH_CREATE_RESPONSE_URL="https://github.com/owner/repo/issues/88888"
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"no prior issue → NEW" \
	"#88888 (new)" \
	"$out"

# ---- Test 6 — open exists → existing (short-circuit before continuation logic) ----
GH_OPEN_RESPONSE="55555"
GH_CLOSED_RESPONSE=""
GH_CREATE_RESPONSE_URL=""
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"open exists → existing (short-circuit)" \
	"#55555 (existing)" \
	"$out"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '\n--- gh call log ---\n'
	cat "$GH_CALLS_LOG"
	printf '\n--- pulse log ---\n'
	cat "$LOGFILE"
	exit 1
fi
exit 0
