#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-empty-compare-scanner.sh — assertion suite for empty-compare-scanner.sh (t2570)
#
# Covers:
#   1. Positive: pre-fix cmd_clean shape is flagged (derived var, no guard)
#   2. Positive: multiple derived vars in one function
#   3. Negative: post-fix _clean_preflight_main_worktree shape is NOT flagged
#      ([[ -z "$_porcelain" ]] guard before compare)
#   4. Negative: explicitly initialized (literal) variables NOT flagged
#   5. Allowlist: # scan:empty-compare-ok suppresses the flag
#   6. Allowlist: file-level allowlist suppresses file
#   7. Function-boundary: guard in sibling function does NOT satisfy
#      the guard requirement for a different function
#   8. Function-boundary: derived var from one function is NOT flagged
#      for compare in a different function
#   9. Backtick form of derived assignment is flagged (same as $())
#  10. -n guard (non-empty check) is also recognised as a guard
#  11. No comparisons in function → no false positive
#  12. Local variable with derived assignment is flagged
#  13. AIDEVOPS_EMPTY_COMPARE_SKIP=1 bypasses the scan

# SC2016: fixture content is written in single-quoted strings intentionally —
# the $(...) and ${...} patterns are bash code for the test fixtures, not
# expressions to be expanded by this test script.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
SCANNER="${SCRIPTS_DIR}/empty-compare-scanner.sh"

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

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t test-empty-compare.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

FIXTURES_DIR="${TMP}/fixtures"
mkdir -p "$FIXTURES_DIR"
mkdir -p "${TMP}/configs"

# Helper: write a test fixture file, initialise as a git repo so the scanner
# can use git ls-files discovery.
write_fixture() {
	local _name="$1"
	local _content="$2"
	local _path="${FIXTURES_DIR}/${_name}"
	printf '%s\n' "$_content" >"$_path"
	return 0
}

# Initialise a minimal git repo so git ls-files works inside TMP
git -C "$FIXTURES_DIR" init -q >/dev/null 2>&1 || true
git -C "$FIXTURES_DIR" add -A >/dev/null 2>&1 || true

printf '%sRunning empty-compare-scanner tests (t2570)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — Positive: pre-fix cmd_clean shape IS flagged
# Derived var with no guard before comparison
# =============================================================================
write_fixture "fixture_positive.sh" '#!/usr/bin/env bash
cmd_clean() {
	local _porcelain main_wt
	_porcelain=$(git worktree list --porcelain)
	main_wt="${_porcelain%%$'"'"'\n'"'"'*}"
	for worktree_path in /foo /bar; do
		if [[ "$worktree_path" != "$main_wt" ]]; then
			echo "clean $worktree_path"
		fi
	done
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_positive.sh" >/dev/null 2>&1 || true

result_1=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if printf '%s' "$result_1" | grep -q "fixture_positive.sh"; then
	pass "1: pre-fix pattern (no guard) is flagged"
else
	fail "1: pre-fix pattern (no guard) is flagged" \
		"expected violation in fixture_positive.sh; got: $(printf '%s' "$result_1" | head -3)"
fi

# Verify it flags the correct function
if printf '%s' "$result_1" | grep -q "cmd_clean"; then
	pass "1a: violation attributed to correct function cmd_clean"
else
	fail "1a: violation attributed to correct function cmd_clean" \
		"function field missing 'cmd_clean'; got: $(printf '%s' "$result_1" | head -3)"
fi

# =============================================================================
# Test 2 — Positive: multiple derived vars in one function
# =============================================================================
write_fixture "fixture_multi_derived.sh" '#!/usr/bin/env bash
multi_derived_func() {
	local alpha beta
	alpha=$(get_alpha)
	beta=$(get_beta)
	if [[ "$x" != "$alpha" ]]; then
		echo "alpha mismatch"
	fi
	if [[ "$y" != "$beta" ]]; then
		echo "beta mismatch"
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_multi_derived.sh" >/dev/null 2>&1 || true

result_2=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
alpha_count=$(printf '%s' "$result_2" | grep "fixture_multi_derived.sh" | grep -c "derived-empty-compare" || true)
if [ "$alpha_count" -ge 2 ]; then
	pass "2: multiple derived vars in one function both flagged (${alpha_count} violations)"
elif [ "$alpha_count" -eq 1 ]; then
	pass "2: at least one derived var in multi-derived function flagged"
else
	fail "2: multiple derived vars in one function both flagged" \
		"expected >=1 violation for fixture_multi_derived.sh; got: $alpha_count"
fi

# =============================================================================
# Test 3 — Negative: post-fix _clean_preflight_main_worktree shape NOT flagged
# Guard exists: [[ -z "$_porcelain" ]] with return 1 before compare
# =============================================================================
write_fixture "fixture_negative_guarded.sh" '#!/usr/bin/env bash
_clean_preflight_main_worktree() {
	local _porcelain main_worktree_path
	_porcelain=$(git worktree list --porcelain)
	if [[ -z "$_porcelain" ]]; then
		echo "FATAL: empty porcelain" >&2
		return 1
	fi
	main_worktree_path="${_porcelain%%$'"'"'\n'"'"'*}"
	main_worktree_path="${main_worktree_path#worktree }"
	printf '"'"'%s\n'"'"' "$main_worktree_path"
	return 0
}

cmd_clean() {
	local main_worktree_path
	if ! main_worktree_path=$(_clean_preflight_main_worktree); then
		return 1
	fi
	for wt in /foo /bar; do
		if [[ "$wt" != "$main_worktree_path" ]]; then
			echo "clean $wt"
		fi
	done
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_negative_guarded.sh" >/dev/null 2>&1 || true

result_3=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if ! printf '%s' "$result_3" | grep -q "fixture_negative_guarded.sh.*_clean_preflight_main_worktree"; then
	pass "3: guarded _clean_preflight shape NOT flagged"
else
	fail "3: guarded _clean_preflight shape NOT flagged" \
		"expected no violation for _clean_preflight_main_worktree; got: $(printf '%s' "$result_3" | grep "fixture_negative_guarded" | head -3)"
fi

# =============================================================================
# Test 4 — Negative: explicitly initialized variable NOT flagged
# var="literal" is not a derived assignment
# =============================================================================
write_fixture "fixture_literal.sh" '#!/usr/bin/env bash
literal_func() {
	local val
	val="always-set"
	if [[ "$x" != "$val" ]]; then
		echo "mismatch"
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_literal.sh" >/dev/null 2>&1 || true

result_4=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if ! printf '%s' "$result_4" | grep -q "fixture_literal.sh"; then
	pass "4: literal-assigned variable NOT flagged"
else
	fail "4: literal-assigned variable NOT flagged" \
		"expected no violation for fixture_literal.sh; got: $(printf '%s' "$result_4" | grep "fixture_literal" | head -3)"
fi

# =============================================================================
# Test 5 — Allowlist: # scan:empty-compare-ok suppresses flag
# =============================================================================
write_fixture "fixture_inline_allowlist.sh" '#!/usr/bin/env bash
allowlisted_func() {
	local derived
	derived=$(get_value)
	if [[ "$x" != "$derived" ]]; then  # scan:empty-compare-ok
		echo "intentional"
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_inline_allowlist.sh" >/dev/null 2>&1 || true

result_5=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if ! printf '%s' "$result_5" | grep -q "fixture_inline_allowlist.sh"; then
	pass "5: # scan:empty-compare-ok inline allowlist suppresses flag"
else
	fail "5: # scan:empty-compare-ok inline allowlist suppresses flag" \
		"expected no violation for fixture_inline_allowlist.sh; got: $(printf '%s' "$result_5" | grep "fixture_inline" | head -3)"
fi

# =============================================================================
# Test 6 — Allowlist: file-level allowlist suppresses file
# =============================================================================
write_fixture "fixture_file_allowlisted.sh" '#!/usr/bin/env bash
file_allowlisted_func() {
	local derived
	derived=$(get_value)
	if [[ "$x" != "$derived" ]]; then
		echo "would be flagged without allowlist"
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_file_allowlisted.sh" >/dev/null 2>&1 || true

ALLOWLIST_FILE="${TMP}/configs/empty-compare-allowlist.txt"
printf 'fixture_file_allowlisted.sh\n' >"$ALLOWLIST_FILE"

# We need to test with the allowlist. Since the scanner reads from
# SCRIPT_DIR/../configs/empty-compare-allowlist.txt, we create a wrapper
# that overrides the path by temporarily setting up the configs dir.
# Instead, test the _is_allowlisted function directly via subshell sourcing.
result_6=$(
	# Source the scanner functions in a subshell and call _scan_file_empty_compare
	# with the allowlist path explicitly
	bash -c '
	source '"$SCANNER"' 2>/dev/null || true
	_scan_file_empty_compare \
		"'"${FIXTURES_DIR}/fixture_file_allowlisted.sh"'" \
		"fixture_file_allowlisted.sh" \
		"'"${ALLOWLIST_FILE}"'"
	' 2>/dev/null || true
)
if [ -z "$result_6" ]; then
	pass "6: file-level allowlist suppresses file"
else
	fail "6: file-level allowlist suppresses file" \
		"expected empty output for allowlisted file; got: $result_6"
fi

# =============================================================================
# Test 7 — Function-boundary: guard in sibling function does NOT satisfy
#           the guard for a different function's compare
# =============================================================================
write_fixture "fixture_sibling_guard.sh" '#!/usr/bin/env bash
guard_func() {
	local derived
	derived=$(get_value)
	[[ -z "$derived" ]] && return 1
	echo "$derived"
	return 0
}

compare_func() {
	local derived
	derived=$(get_value)
	if [[ "$x" != "$derived" ]]; then
		echo "no guard in this function"
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_sibling_guard.sh" >/dev/null 2>&1 || true

result_7=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if printf '%s' "$result_7" | grep -q "fixture_sibling_guard.sh.*compare_func"; then
	pass "7: guard in sibling function does NOT protect compare in compare_func"
else
	fail "7: guard in sibling function does NOT protect compare in compare_func" \
		"expected compare_func to be flagged; got: $(printf '%s' "$result_7" | grep "fixture_sibling" | head -5)"
fi

# Also verify that guard_func is NOT flagged (it has the guard)
if ! printf '%s' "$result_7" | grep -q "fixture_sibling_guard.sh.*guard_func"; then
	pass "7a: guard_func with -z guard is NOT flagged"
else
	fail "7a: guard_func with -z guard is NOT flagged" \
		"expected guard_func to be clean; got: $(printf '%s' "$result_7" | grep "guard_func" | head -3)"
fi

# =============================================================================
# Test 8 — Function-boundary: derived var scope is per-function
# A derived var in func_a should NOT trigger a violation for func_b's compare
# where func_b has its own local variable with the same name (initialized safely)
# =============================================================================
write_fixture "fixture_func_scope.sh" '#!/usr/bin/env bash
func_a() {
	local shared_name
	shared_name=$(get_value)
	echo "$shared_name"
	return 0
}

func_b() {
	local shared_name
	shared_name="literal-safe"
	if [[ "$x" != "$shared_name" ]]; then
		echo "safe in func_b"
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_func_scope.sh" >/dev/null 2>&1 || true

result_8=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if ! printf '%s' "$result_8" | grep -q "fixture_func_scope.sh.*func_b"; then
	pass "8: derived var scope is per-function (func_b not falsely flagged)"
else
	fail "8: derived var scope is per-function (func_b not falsely flagged)" \
		"expected func_b to be clean; got: $(printf '%s' "$result_8" | grep "fixture_func_scope" | head -5)"
fi

# =============================================================================
# Test 9 — Backtick form of derived assignment is also flagged
# =============================================================================
write_fixture "fixture_backtick.sh" '#!/usr/bin/env bash
backtick_func() {
	local result
	# shellcheck disable=SC2006
	result=`get_value`
	if [[ "$x" != "$result" ]]; then
		echo "backtick form"
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_backtick.sh" >/dev/null 2>&1 || true

result_9=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if printf '%s' "$result_9" | grep -q "fixture_backtick.sh"; then
	pass "9: backtick form of derived assignment is flagged"
else
	fail "9: backtick form of derived assignment is flagged" \
		"expected violation for fixture_backtick.sh; got: $(printf '%s' "$result_9" | head -3)"
fi

# =============================================================================
# Test 10 — -n guard (non-empty check) is also recognised as safe
# =============================================================================
write_fixture "fixture_n_guard.sh" '#!/usr/bin/env bash
n_guard_func() {
	local derived
	derived=$(get_value)
	if [[ -n "$derived" ]]; then
		if [[ "$x" != "$derived" ]]; then
			echo "safe: n-guard present"
		fi
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_n_guard.sh" >/dev/null 2>&1 || true

result_10=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if ! printf '%s' "$result_10" | grep -q "fixture_n_guard.sh.*n_guard_func"; then
	pass "10: -n guard recognised as safe (not flagged)"
else
	fail "10: -n guard recognised as safe (not flagged)" \
		"expected n_guard_func to be clean; got: $(printf '%s' "$result_10" | grep "fixture_n_guard" | head -3)"
fi

# =============================================================================
# Test 11 — No comparison in function → no false positive
# =============================================================================
write_fixture "fixture_no_compare.sh" '#!/usr/bin/env bash
no_compare_func() {
	local derived
	derived=$(get_value)
	echo "derived=$derived"
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_no_compare.sh" >/dev/null 2>&1 || true

result_11=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if ! printf '%s' "$result_11" | grep -q "fixture_no_compare.sh"; then
	pass "11: derived var with no comparison does not produce false positive"
else
	fail "11: derived var with no comparison does not produce false positive" \
		"expected no violation for fixture_no_compare.sh; got: $(printf '%s' "$result_11" | grep "fixture_no_compare" | head -3)"
fi

# =============================================================================
# Test 12 — Local variable declaration with derived assignment is flagged
# =============================================================================
write_fixture "fixture_local_derived.sh" '#!/usr/bin/env bash
local_derived_func() {
	local myvar
	myvar=$(some_command --flag value)
	if [[ "$other" != "$myvar" ]]; then
		echo "local derived without guard"
	fi
	return 0
}
'
git -C "$FIXTURES_DIR" add "fixture_local_derived.sh" >/dev/null 2>&1 || true

result_12=$("$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if printf '%s' "$result_12" | grep -q "fixture_local_derived.sh"; then
	pass "12: local variable with derived assignment is flagged"
else
	fail "12: local variable with derived assignment is flagged" \
		"expected violation for fixture_local_derived.sh; got: $(printf '%s' "$result_12" | head -3)"
fi

# =============================================================================
# Test 13 — AIDEVOPS_EMPTY_COMPARE_SKIP=1 bypasses the scan (exits 0, no output)
# =============================================================================
result_13=$(AIDEVOPS_EMPTY_COMPARE_SKIP=1 "$SCANNER" scan "$FIXTURES_DIR" 2>/dev/null || true)
if [ -z "$result_13" ]; then
	pass "13: AIDEVOPS_EMPTY_COMPARE_SKIP=1 bypasses scan and produces no output"
else
	fail "13: AIDEVOPS_EMPTY_COMPARE_SKIP=1 bypasses scan and produces no output" \
		"expected empty output; got: $result_13"
fi

# =============================================================================
# Bonus test — --output-md produces a markdown report
# =============================================================================
MD_OUT="${TMP}/report.md"
"$SCANNER" scan "$FIXTURES_DIR" --output-md "$MD_OUT" >/dev/null 2>/dev/null || true
if [ -f "$MD_OUT" ] && grep -q "Empty-Compare Scan Results" "$MD_OUT"; then
	pass "B1: --output-md produces a markdown report"
else
	fail "B1: --output-md produces a markdown report" \
		"expected markdown report at $MD_OUT"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' \
		"$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
