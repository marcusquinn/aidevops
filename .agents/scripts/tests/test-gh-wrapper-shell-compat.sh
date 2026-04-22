#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-wrapper-shell-compat.sh — t2743 / GH#20480 regression guard.
#
# Asserts that shared-gh-wrappers-rest-fallback.sh correctly tokenises
# CSV arguments (--label, --assignee, --add-label, etc.) under both
# bash and zsh, and that shared-gh-wrappers.sh loads the REST fallback
# helper without requiring _SHARED_GH_WRAPPERS_DIR or shared-constants.sh
# to be pre-set.
#
# Root cause (t2743, 2026-04-22):
#   `IFS=',' read -ra _toks <<<"$val"` is bash-only. In zsh, `read -a`
#   is not recognised (zsh uses `read -A`) and the command fails with
#   "bad option: -a", silently producing empty arrays. Issues created
#   via _gh_issue_create_rest in zsh sessions received no labels and
#   no assignees, breaking tier-routing, origin-detection, and
#   auto-dispatch pipelines.
#
# Fix: replaced all 16 `read -ra` sites with a portable helper
# `_gh_split_csv` that uses POSIX parameter expansion only.
#
# Test scenarios:
#   1. _gh_split_csv: basic CSV split under bash
#   2. _gh_split_csv: same split under zsh (skip if zsh unavailable)
#   3. _gh_split_csv: single token (no delimiter) returns string unchanged
#   4. _gh_split_csv: empty string returns nothing
#   5. _gh_split_csv: trailing delimiter — raw output, caller skips empty
#   6. Integration: _gh_issue_create_rest labels+assignees reach gh api
#      payload under bash (via stubbed gh)
#   7. Integration: same under zsh (skip if zsh unavailable)
#   8. Load-order: sourcing shared-gh-wrappers.sh with no _SHARED_GH_WRAPPERS_DIR
#      and no shared-constants.sh still defines _gh_should_fallback_to_rest
#
# macOS vs Linux:
#   macOS: /bin/bash is 3.2; /bin/zsh is the default interactive shell.
#   Linux: /bin/bash is 4+/5+; zsh may or may not be installed.
#   Tests skip gracefully when zsh is absent — they are supplementary
#   guards alongside the existing t2574 bash-only suite.
#
# CI matrix note:
#   For zsh tests to run on Ubuntu CI, add `apt-get install -y zsh` to the
#   test-setup step in ShellCheck (ubuntu-latest) workflow.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_YELLOW=$'\033[1;33m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_YELLOW="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

skip() {
	printf '  %sSKIP%s %s (%s)\n' "$TEST_YELLOW" "$TEST_NC" "$1" "${2:-}"
	return 0
}

FALLBACK_FILE="${SCRIPTS_DIR}/shared-gh-wrappers-rest-fallback.sh"
WRAPPERS_FILE="${SCRIPTS_DIR}/shared-gh-wrappers.sh"

if [[ ! -f "$FALLBACK_FILE" ]]; then
	printf '%sFATAL%s shared-gh-wrappers-rest-fallback.sh not found at %s\n' \
		"$TEST_RED" "$TEST_NC" "$FALLBACK_FILE"
	exit 1
fi

# Source the fallback file under bash to load _gh_split_csv and helpers.
# Stub out print_info / print_warning so sourcing is noise-free.
print_info() { return 0; }
print_warning() { return 0; }
export -f print_info print_warning

# shellcheck source=../shared-gh-wrappers-rest-fallback.sh
source "$FALLBACK_FILE"

printf '%sRunning gh-wrapper shell-compat tests (t2743 / GH#20480)%s\n' \
	"$TEST_GREEN" "$TEST_NC"

# =============================================================================
# Test 1: _gh_split_csv basic CSV split under bash
# =============================================================================
out=$(_gh_split_csv "a,b,c" ",")
expected=$(printf 'a\nb\nc')
if [[ "$out" == "$expected" ]]; then
	pass "1: _gh_split_csv splits 'a,b,c' into 3 tokens under bash"
else
	fail "1: _gh_split_csv splits 'a,b,c' into 3 tokens under bash" \
		"expected: $(printf '%q' "$expected")  got: $(printf '%q' "$out")"
fi

# =============================================================================
# Test 2: _gh_split_csv under zsh
# =============================================================================
if ! command -v zsh >/dev/null 2>&1; then
	skip "2: _gh_split_csv splits correctly under zsh" "zsh not installed"
else
	zsh_out=$(zsh -c "
source '${FALLBACK_FILE}'
out=\$(_gh_split_csv 'a,b,c' ',')
printf '%s' \"\$out\"
" 2>&1)
	zsh_expected=$(printf 'a\nb\nc')
	if [[ "$zsh_out" == "$zsh_expected" ]]; then
		pass "2: _gh_split_csv splits 'a,b,c' into 3 tokens under zsh"
	else
		fail "2: _gh_split_csv splits 'a,b,c' into 3 tokens under zsh" \
			"expected: $(printf '%q' "$zsh_expected")  got: $(printf '%q' "$zsh_out")"
	fi
fi

# =============================================================================
# Test 3: _gh_split_csv single token (no delimiter) returns string unchanged
# =============================================================================
out=$(_gh_split_csv "solo" ",")
if [[ "$out" == "solo" ]]; then
	pass "3: _gh_split_csv returns single token unchanged when no delimiter present"
else
	fail "3: _gh_split_csv returns single token unchanged when no delimiter present" \
		"expected 'solo' got: $(printf '%q' "$out")"
fi

# =============================================================================
# Test 4: _gh_split_csv empty string returns nothing (no spurious empty line)
# =============================================================================
out=$(_gh_split_csv "" ",")
if [[ -z "$out" ]]; then
	pass "4: _gh_split_csv empty string returns empty output"
else
	fail "4: _gh_split_csv empty string returns empty output" \
		"expected empty, got: $(printf '%q' "$out")"
fi

# =============================================================================
# Test 5: _gh_split_csv trailing delimiter — function does NOT emit spurious
# trailing empty token. The `while [[ -n "$_str" ]]` guard in _gh_split_csv
# ensures the loop exits when _str becomes "" after the last delimited token,
# so "a,b," produces exactly 2 lines ("a" and "b") — no empty trailing line.
# The caller's `[[ -n "$_tok" ]]` guard remains a defensive safety measure
# for callers that feed raw shell word-splitting output, not _gh_split_csv output.
# =============================================================================
out=$(_gh_split_csv "a,b," ",")
line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
if [[ "$line_count" == "2" ]]; then
	pass "5: _gh_split_csv trailing delimiter produces 2 tokens (no spurious empty)"
else
	fail "5: _gh_split_csv trailing delimiter produces 2 tokens (no spurious empty)" \
		"expected 2, got: $line_count  (raw output: $(printf '%q' "$out"))"
fi

# =============================================================================
# Test 6: Integration — _gh_issue_create_rest labels+assignees reach gh api
# under bash. Stub `gh` as a shell function; capture calls to a temp file.
# =============================================================================
TMP=$(mktemp -d -t t2743.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
GH_CALLS="${TMP}/gh_calls.log"

gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
		printf '5000\n'
		return 0
	fi
	if [[ "$1" == "api" && "$2" == "-X" ]]; then
		printf 'https://github.com/owner/repo/issues/9999\n'
		return 0
	fi
	return 0
}
export -f gh

: >"$GH_CALLS"
_gh_issue_create_rest \
	--repo "owner/repo" \
	--title "t2743: shell compat test" \
	--body "test body" \
	--label "tier:standard,auto-dispatch,framework" \
	--assignee "marcusquinn,otheruser" >/dev/null 2>&1 || true

label_standard=$(grep -c 'labels\[\]=tier:standard' "$GH_CALLS" 2>/dev/null || printf '0')
label_auto=$(grep -c 'labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null || printf '0')
label_fw=$(grep -c 'labels\[\]=framework' "$GH_CALLS" 2>/dev/null || printf '0')
assignee_main=$(grep -c 'assignees\[\]=marcusquinn' "$GH_CALLS" 2>/dev/null || printf '0')
assignee_other=$(grep -c 'assignees\[\]=otheruser' "$GH_CALLS" 2>/dev/null || printf '0')

if [[ "$label_standard" -ge 1 && "$label_auto" -ge 1 && "$label_fw" -ge 1 && \
      "$assignee_main" -ge 1 && "$assignee_other" -ge 1 ]]; then
	pass "6: _gh_issue_create_rest sends all labels and assignees to gh api under bash"
else
	fail "6: _gh_issue_create_rest sends all labels and assignees to gh api under bash" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 7: Integration — same test under zsh
# =============================================================================
if ! command -v zsh >/dev/null 2>&1; then
	skip "7: _gh_issue_create_rest labels+assignees under zsh" "zsh not installed"
else
	ZSH_CALLS="${TMP}/zsh_calls.log"
	: >"$ZSH_CALLS"

	zsh -c "
print_info() { return 0; }
print_warning() { return 0; }
gh() {
    printf '%s\n' \"\$*\" >>\"${ZSH_CALLS}\"
    if [[ \"\$1\" == 'api' && \"\$2\" == '-X' ]]; then
        printf 'https://github.com/owner/repo/issues/9999\n'
        return 0
    fi
    return 0
}
source '${FALLBACK_FILE}'
_gh_issue_create_rest \
    --repo 'owner/repo' \
    --title 't2743: zsh compat test' \
    --body 'zsh body' \
    --label 'tier:standard,auto-dispatch,framework' \
    --assignee 'marcusquinn,otheruser' >/dev/null 2>&1 || true
" 2>&1 || true

	zsh_label_standard=$(grep -c 'labels\[\]=tier:standard' "$ZSH_CALLS" 2>/dev/null || printf '0')
	zsh_label_auto=$(grep -c 'labels\[\]=auto-dispatch' "$ZSH_CALLS" 2>/dev/null || printf '0')
	zsh_label_fw=$(grep -c 'labels\[\]=framework' "$ZSH_CALLS" 2>/dev/null || printf '0')
	zsh_assignee_main=$(grep -c 'assignees\[\]=marcusquinn' "$ZSH_CALLS" 2>/dev/null || printf '0')
	zsh_assignee_other=$(grep -c 'assignees\[\]=otheruser' "$ZSH_CALLS" 2>/dev/null || printf '0')

	if [[ "$zsh_label_standard" -ge 1 && "$zsh_label_auto" -ge 1 && "$zsh_label_fw" -ge 1 && \
	      "$zsh_assignee_main" -ge 1 && "$zsh_assignee_other" -ge 1 ]]; then
		pass "7: _gh_issue_create_rest sends all labels and assignees under zsh"
	else
		fail "7: _gh_issue_create_rest sends all labels and assignees under zsh" \
			"ZSH_CALLS=$(cat "$ZSH_CALLS")"
	fi
fi

# =============================================================================
# Test 8: Load-order — sourcing shared-gh-wrappers.sh with no
# _SHARED_GH_WRAPPERS_DIR and no shared-constants.sh defines the REST helpers.
# Verifies Bug 2a fix: _SHARED_GH_WRAPPERS_DIR is derived from BASH_SOURCE[0]
# (or $0 in zsh) rather than requiring the caller to pre-set it.
# =============================================================================
bash_out=$(
	/bin/bash -c "
unset _SHARED_GH_WRAPPERS_DIR 2>/dev/null || true
unset _SC_SELF 2>/dev/null || true
# No shared-constants.sh sourced — test that stubs prevent command-not-found.
source '${WRAPPERS_FILE}' 2>/dev/null
if declare -F _gh_should_fallback_to_rest >/dev/null 2>&1 && \
   declare -F _gh_issue_create_rest >/dev/null 2>&1 && \
   declare -F _gh_pr_create_rest >/dev/null 2>&1; then
    printf 'OK\n'
else
    printf 'MISSING\n'
fi
" 2>&1
)
if [[ "$bash_out" == *"OK"* ]]; then
	pass "8: sourcing shared-gh-wrappers.sh alone (no _SHARED_GH_WRAPPERS_DIR) defines REST helpers under bash"
else
	fail "8: sourcing shared-gh-wrappers.sh alone (no _SHARED_GH_WRAPPERS_DIR) defines REST helpers under bash" \
		"output: $(printf '%q' "$bash_out")"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
