#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-empty-compare-scanner.sh — assertion suite for empty-compare-scanner.sh (t2570)
#
# Covers:
#   P1 positive: derived var via $() in compare without guard → FLAGGED
#   P2 positive: derived var via param-expansion in compare without guard → FLAGGED
#   N1 negative: derived var with -z guard before compare → NOT FLAGGED
#   N2 negative: explicitly initialized var (non-derived) → NOT FLAGGED
#   N3 negative: derived var with :? guard → NOT FLAGGED
#   A1 allowlist: inline # scan:empty-compare-ok suppresses flag
#   A2 allowlist: AIDEVOPS_EMPTY_COMPARE_SKIP=1 suppresses all
#   B1 function-boundary: guard in sibling function does NOT apply to different function
#
# Usage: bash tests/test-empty-compare-scanner.sh [path-to-scanner]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="${1:-${SCRIPT_DIR}/../empty-compare-scanner.sh}"
TMPDIR_TESTS=$(mktemp -d /tmp/test-empty-compare.XXXXXX)
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TMPDIR_TESTS"
	return 0
}
trap cleanup EXIT

assert_violations() {
	local _label="$1"
	local _expected="$2"
	local _dir="$3"
	local _actual

	_actual=$(AIDEVOPS_EMPTY_COMPARE_SKIP="" bash "$SCANNER" scan "$_dir" 2>/dev/null | wc -l | tr -d ' ')
	[ -z "$_actual" ] && _actual=0
	# empty output from a zero-violation scan → wc gives 0
	_actual_violations=$(AIDEVOPS_EMPTY_COMPARE_SKIP="" bash "$SCANNER" scan "$_dir" 2>/dev/null | grep -c '	' || true)

	if [ "$_actual_violations" -eq "$_expected" ]; then
		printf '[PASS] %s (expected=%d got=%d)\n' "$_label" "$_expected" "$_actual_violations"
		PASS=$((PASS + 1))
	else
		printf '[FAIL] %s (expected=%d got=%d)\n' "$_label" "$_expected" "$_actual_violations" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_var_flagged() {
	local _label="$1"
	local _var="$2"
	local _dir="$3"
	local _output

	_output=$(AIDEVOPS_EMPTY_COMPARE_SKIP="" bash "$SCANNER" scan "$_dir" 2>/dev/null || true)
	if printf '%s\n' "$_output" | grep -q "	${_var}$"; then
		printf '[PASS] %s (var=%s flagged)\n' "$_label" "$_var"
		PASS=$((PASS + 1))
	else
		printf '[FAIL] %s (var=%s NOT flagged in output)\n' "$_label" "$_var" >&2
		printf '  output: %s\n' "$_output" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_var_not_flagged() {
	local _label="$1"
	local _var="$2"
	local _dir="$3"
	local _output

	_output=$(AIDEVOPS_EMPTY_COMPARE_SKIP="" bash "$SCANNER" scan "$_dir" 2>/dev/null || true)
	if printf '%s\n' "$_output" | grep -qv "	${_var}$" 2>/dev/null || [ -z "$_output" ]; then
		if ! printf '%s\n' "$_output" | grep -q "	${_var}$"; then
			printf '[PASS] %s (var=%s not flagged)\n' "$_label" "$_var"
			PASS=$((PASS + 1))
			return 0
		fi
	fi
	printf '[FAIL] %s (var=%s unexpectedly flagged)\n' "$_label" "$_var" >&2
	printf '  output: %s\n' "$_output" >&2
	FAIL=$((FAIL + 1))
	return 0
}

# ---------------------------------------------------------------------------
# Test fixture helpers
# make_fixture_stdin <name>: reads fixture content from stdin, returns dir path
# ---------------------------------------------------------------------------
make_fixture_stdin() {
	local _name="$1"
	local _dir="${TMPDIR_TESTS}/${_name}"
	mkdir -p "$_dir"
	cat >"${_dir}/fixture.sh"
	printf '%s' "$_dir"
	return 0
}

# ---------------------------------------------------------------------------
# P1: derived var via $() used in compare without guard → FLAGGED
# ---------------------------------------------------------------------------
P1_DIR=$(make_fixture_stdin "p1" <<"FIXTURE"
#!/usr/bin/env bash
p1_test() {
    local main_wt
    main_wt=$(git worktree list | head -1)
    local worktree_path="/some/path"
    if [[ "$worktree_path" != "$main_wt" ]]; then
        echo "different"
    fi
    return 0
}
FIXTURE
)
assert_var_flagged "P1: command-sub var flagged in compare" "main_wt" "$P1_DIR"

# ---------------------------------------------------------------------------
# P2: derived var via param-expansion used in compare without guard → FLAGGED
# ---------------------------------------------------------------------------
P2_DIR=$(make_fixture_stdin "p2" <<"FIXTURE"
#!/usr/bin/env bash
p2_test() {
    local _porcelain main_wt
    _porcelain=$(git worktree list --porcelain)
    main_wt="${_porcelain%%
*}"
    local path="/some/path"
    if [[ "$path" != "$main_wt" ]]; then
        echo "different"
    fi
    return 0
}
FIXTURE
)
assert_var_flagged "P2: param-expansion derived var flagged" "main_wt" "$P2_DIR"

# ---------------------------------------------------------------------------
# N1: derived var guarded with -z before compare → NOT FLAGGED
# (post-fix shape from _clean_preflight_main_worktree)
# ---------------------------------------------------------------------------
N1_DIR=$(make_fixture_stdin "n1" <<"FIXTURE"
#!/usr/bin/env bash
n1_safe() {
    local main_wt
    main_wt=$(git worktree list | head -1)
    if [[ -z "$main_wt" ]]; then
        return 1
    fi
    local path="/some/path"
    if [[ "$path" != "$main_wt" ]]; then
        echo "different"
    fi
    return 0
}
FIXTURE
)
assert_var_not_flagged "N1: guarded var not flagged" "main_wt" "$N1_DIR"

# ---------------------------------------------------------------------------
# N2: non-derived literal initialization → NOT FLAGGED
# ---------------------------------------------------------------------------
N2_DIR=$(make_fixture_stdin "n2" <<"FIXTURE"
#!/usr/bin/env bash
n2_test() {
    local target="main"
    local branch="feature"
    if [[ "$branch" != "$target" ]]; then
        echo "different branch"
    fi
    return 0
}
FIXTURE
)
assert_var_not_flagged "N2: literal var not flagged" "target" "$N2_DIR"

# ---------------------------------------------------------------------------
# N3: derived var guarded with :? expansion → NOT FLAGGED
# ---------------------------------------------------------------------------
N3_DIR=$(make_fixture_stdin "n3" <<"FIXTURE"
#!/usr/bin/env bash
n3_test() {
    local slug
    slug=$(jq -r .slug config.json)
    : "${slug:?slug must not be empty}"
    local other="expected"
    if [[ "$slug" != "$other" ]]; then
        echo "different"
    fi
    return 0
}
FIXTURE
)
assert_var_not_flagged "N3: :? guarded var not flagged" "slug" "$N3_DIR"

# ---------------------------------------------------------------------------
# A1: inline # scan:empty-compare-ok suppresses the flag
# ---------------------------------------------------------------------------
A1_DIR=$(make_fixture_stdin "a1" <<"FIXTURE"
#!/usr/bin/env bash
a1_test() {
    local val
    val=$(some_command)
    local other="expected"
    if [[ "$val" != "$other" ]]; then # scan:empty-compare-ok
        echo "suppressed"
    fi
    return 0
}
FIXTURE
)
assert_violations "A1: inline suppress comment → 0 violations" 0 "$A1_DIR"

# ---------------------------------------------------------------------------
# A2: AIDEVOPS_EMPTY_COMPARE_SKIP=1 bypasses all detection
# ---------------------------------------------------------------------------
# Use same dir as P1 (which has a violation)
A2_violations=$(AIDEVOPS_EMPTY_COMPARE_SKIP=1 bash "$SCANNER" scan "$P1_DIR" 2>/dev/null | grep -c '	' || true)
if [ "$A2_violations" -eq 0 ]; then
	printf '[PASS] A2: AIDEVOPS_EMPTY_COMPARE_SKIP=1 bypasses scan\n'
	PASS=$((PASS + 1))
else
	printf '[FAIL] A2: AIDEVOPS_EMPTY_COMPARE_SKIP=1 still emitted %d violations\n' "$A2_violations" >&2
	FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# B1: guard in sibling function does NOT satisfy compare in different function
# ---------------------------------------------------------------------------
B1_DIR=$(make_fixture_stdin "b1" <<"FIXTURE"
#!/usr/bin/env bash
b1_sibling_with_guard() {
    local val
    val=$(derive_value)
    if [[ -z "$val" ]]; then
        return 1
    fi
    if [[ "$val" != "expected" ]]; then
        echo "guarded compare"
    fi
    return 0
}
b1_different_function_no_guard() {
    local val
    val=$(derive_value)
    if [[ "$val" != "expected" ]]; then
        echo "unguarded compare in different function"
    fi
    return 0
}
FIXTURE
)
assert_var_flagged "B1: unguarded compare in sibling function flagged" "val" "$B1_DIR"

# Also verify the guarded function in B1 does NOT contribute a flag
B1_guarded_count=$(AIDEVOPS_EMPTY_COMPARE_SKIP="" bash "$SCANNER" scan "$B1_DIR" 2>/dev/null | grep -c "b1_sibling_with_guard" || true)
if [ "$B1_guarded_count" -eq 0 ]; then
	printf '[PASS] B1b: sibling function with guard not flagged\n'
	PASS=$((PASS + 1))
else
	printf '[FAIL] B1b: sibling function with guard unexpectedly flagged (%d)\n' "$B1_guarded_count" >&2
	FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$((PASS + FAIL))
printf '\n--- Results: %d/%d passed ---\n' "$PASS" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
