#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-shellcheckrc-parity.sh — GH#19877 regression guard.
#
# Asserts that every `disable=SCNNNN` directive in the root `.shellcheckrc`
# is also present in `.agents/scripts/.shellcheckrc`.
#
# ShellCheck's rcfile auto-discovery stops at the FIRST `.shellcheckrc`
# found when walking up from the linted file. For files under
# `.agents/scripts/`, this means the scripts-dir rcfile wins and the root
# rcfile is never read. Any disable present in root but absent from the
# scripts-dir rcfile silently re-enables that warning for 255+ scripts,
# causing spurious pre-commit failures on otherwise-clean PRs.
#
# Discovery: PR #19876 (t2377) — SC1091 drift blocked unrelated files.
# Fix: t2377 added the missing disable. This test prevents recurrence.
#
# Tests:
#   1. All root disables are present in scripts-dir rcfile
#   2. A synthetic missing disable is detected (self-test)
#   3. Scripts-dir-only disables are allowed (no false positive)
#   4. Direct invocation of check_shellcheckrc_parity function
#
# Usage:
#   bash .agents/scripts/tests/test-shellcheckrc-parity.sh
#   # or from linters-local.sh via check_shellcheckrc_parity()

set -uo pipefail

# --- Locate repo root ---
SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1

# --- Test harness (mirrors test-auto-dispatch-no-assign.sh pattern) ---
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
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	return 0
}

header() {
	local msg="$1"
	printf '\n%s=== %s ===%s\n' "$TEST_BLUE" "$msg" "$TEST_NC"
	return 0
}

# --- Core parity logic (extracted for reuse by linters-local.sh) ---
# Returns 0 if parity holds, 1 if disables are missing.
# Outputs missing codes to stdout (one per line).
check_parity() {
	local root_rc="$1"
	local scripts_rc="$2"

	if [[ ! -f "$root_rc" ]]; then
		echo "ERROR: root .shellcheckrc not found at $root_rc" >&2
		return 1
	fi
	if [[ ! -f "$scripts_rc" ]]; then
		echo "ERROR: scripts-dir .shellcheckrc not found at $scripts_rc" >&2
		return 1
	fi

	# Extract disable=SCNNNN lines, sort for comparison
	local root_disables scripts_disables
	root_disables=$(grep -E '^disable=SC[0-9]+' "$root_rc" | sort)
	scripts_disables=$(grep -E '^disable=SC[0-9]+' "$scripts_rc" | sort)

	# Find root disables not in scripts-dir rcfile
	local missing=""
	local code
	while IFS= read -r code; do
		[[ -z "$code" ]] && continue
		if ! grep -qF "$code" <<<"$scripts_disables"; then
			missing="${missing}${code}
"
		fi
	done <<<"$root_disables"

	if [[ -n "$missing" ]]; then
		echo "$missing"
		return 1
	fi

	return 0
}

# --- Exported function for linters-local.sh integration ---
# shellcheck disable=SC2034
CHECK_SHELLCHECKRC_PARITY_LOADED=1

check_shellcheckrc_parity() {
	local root_rc="${REPO_ROOT}/.shellcheckrc"
	local scripts_rc="${REPO_ROOT}/.agents/scripts/.shellcheckrc"
	local missing

	if missing=$(check_parity "$root_rc" "$scripts_rc"); then
		return 0
	else
		echo "$missing" >&2
		return 1
	fi
}

# --- Tests (only run when script is executed directly) ---
run_tests() {
	header "test-shellcheckrc-parity"

	local root_rc="${REPO_ROOT}/.shellcheckrc"
	local scripts_rc="${REPO_ROOT}/.agents/scripts/.shellcheckrc"

	# Test 1: Real rcfiles are in parity
	header "Test 1: Real rcfiles are in parity"
	local missing
	if missing=$(check_parity "$root_rc" "$scripts_rc"); then
		pass "All root disables present in scripts-dir rcfile"
	else
		fail "Missing disables in scripts-dir rcfile: $(echo "$missing" | tr '\n' ' ')"
	fi

	# Test 2: Synthetic missing disable is detected
	header "Test 2: Synthetic missing disable is detected"
	local tmp_root tmp_scripts
	tmp_root=$(mktemp)
	tmp_scripts=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$tmp_root' '$tmp_scripts'" EXIT

	cat >"$tmp_root" <<'EOF'
disable=SC1091
disable=SC2329
disable=SC9999
EOF
	cat >"$tmp_scripts" <<'EOF'
disable=SC1091
disable=SC2329
EOF

	if missing=$(check_parity "$tmp_root" "$tmp_scripts"); then
		fail "Should have detected missing SC9999"
	else
		if echo "$missing" | grep -q "SC9999"; then
			pass "Detected missing disable=SC9999"
		else
			fail "Did not identify SC9999 specifically (got: $missing)"
		fi
	fi

	# Test 3: Scripts-dir-only disables are allowed
	header "Test 3: Scripts-dir-only disables are allowed"
	cat >"$tmp_root" <<'EOF'
disable=SC1091
EOF
	cat >"$tmp_scripts" <<'EOF'
disable=SC1091
disable=SC8888
EOF

	if check_parity "$tmp_root" "$tmp_scripts" >/dev/null 2>&1; then
		pass "Scripts-dir-only disables do not trigger failure"
	else
		fail "Scripts-dir-only disables should be allowed"
	fi

	# Test 4: check_shellcheckrc_parity function works
	header "Test 4: check_shellcheckrc_parity function works"
	if check_shellcheckrc_parity 2>/dev/null; then
		pass "check_shellcheckrc_parity() returns success on current repo"
	else
		fail "check_shellcheckrc_parity() failed on current repo"
	fi

	# --- Summary ---
	echo ""
	if [[ $TESTS_FAILED -gt 0 ]]; then
		printf '%sFAILED%s: %d/%d tests failed\n' "$TEST_RED" "$TEST_NC" "$TESTS_FAILED" "$TESTS_RUN"
		return 1
	else
		printf '%sALL PASSED%s: %d/%d tests\n' "$TEST_GREEN" "$TEST_NC" "$TESTS_RUN" "$TESTS_RUN"
		return 0
	fi
}

# Run tests when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	run_tests
	exit $?
fi
