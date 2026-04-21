#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-shared-gh-wrappers-source.sh — t2709 / GH#20357 regression guard.
#
# Asserts that sourcing shared-constants.sh (which sources shared-gh-wrappers.sh)
# emits zero output about shared-gh-wrappers-rest-fallback.sh under both bash
# and zsh, and that the REST fallback helpers are loaded correctly in both.
#
# Root cause: shared-gh-wrappers.sh:44-46 used ${BASH_SOURCE[0]%/*} to resolve
# its own directory. Under zsh, BASH_SOURCE is not populated, so the expansion
# returned empty, and the subsequent source call tried to load
# /shared-gh-wrappers-rest-fallback.sh (leading-slash absolute path), emitting:
#   shared-gh-wrappers.sh:source:46: no such file or directory: /shared-gh-wrappers-rest-fallback.sh
# Additionally the previous attempt used ${(%):-%x} (zsh-only syntax) which
# caused shfmt to fail parsing the file, triggering the AWK fallback that
# reported a false nesting depth of 14 and failed the CI regression gate.
#
# Fix: use _SC_SELF (set by shared-constants.sh before sourcing us) as the zsh
# fallback — pure bash syntax, shfmt-parseable, same directory.
#
# Tests:
#   1. bash: source shared-constants.sh emits zero REST-fallback warnings
#   2. bash: _gh_issue_create_rest is defined after sourcing
#   3. zsh:  source shared-constants.sh emits zero REST-fallback warnings (t2709)
#   4. zsh:  _gh_issue_create_rest is defined after sourcing (t2709)

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPTS_DIR}/../.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
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
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sSKIP%s %s\n' "$TEST_BLUE" "$TEST_NC" "$1"
	return 0
}

# =============================================================================
# Test 1 + 2: bash — source emits no REST-fallback warning, helper defined
# =============================================================================
printf '\n=== bash source tests ===\n'

bash_output=$(bash -c "source '${SCRIPTS_DIR}/shared-constants.sh' 2>&1" || true)
if printf '%s\n' "$bash_output" | grep -q 'shared-gh-wrappers-rest-fallback.sh'; then
	fail "bash source emits REST-fallback warning" "$bash_output"
else
	pass "bash source emits no REST-fallback warning"
fi

bash_fn=$(bash -c "source '${SCRIPTS_DIR}/shared-constants.sh' 2>/dev/null && type _gh_issue_create_rest 2>/dev/null" || true)
if printf '%s\n' "$bash_fn" | grep -q 'function\|_gh_issue_create_rest'; then
	pass "bash: _gh_issue_create_rest defined after source"
else
	fail "bash: _gh_issue_create_rest NOT defined after source" "$bash_fn"
fi

# =============================================================================
# Test 3 + 4: zsh — source emits no REST-fallback warning, helper defined
# =============================================================================
printf '\n=== zsh source tests ===\n'

if ! command -v zsh >/dev/null 2>&1; then
	skip "zsh not available — skipping zsh tests (not a failure)"
	skip "zsh: _gh_issue_create_rest defined after source (zsh unavailable)"
else
	zsh_output=$(zsh -c "source '${SCRIPTS_DIR}/shared-constants.sh' 2>&1" || true)
	if printf '%s\n' "$zsh_output" | grep -q 'shared-gh-wrappers-rest-fallback.sh'; then
		fail "zsh source emits REST-fallback warning (t2709)" "$zsh_output"
	else
		pass "zsh source emits no REST-fallback warning (t2709)"
	fi

	zsh_fn=$(zsh -c "source '${SCRIPTS_DIR}/shared-constants.sh' 2>/dev/null && type _gh_issue_create_rest 2>/dev/null" || true)
	if printf '%s\n' "$zsh_fn" | grep -q 'function\|_gh_issue_create_rest\|shell function'; then
		pass "zsh: _gh_issue_create_rest defined after source (REST fallback loaded)"
	else
		fail "zsh: _gh_issue_create_rest NOT defined after source" "$zsh_fn"
	fi
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n=== Results: %d/%d passed ===\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
