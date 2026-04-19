#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-markdownlint-diff-helper-biome-zero.sh — Regression test for GH#19827
#
# Guards against the grep -c arithmetic crash when biome reports zero violations.
#
# Root cause (fixed in t2376 / PR #19848):
#   grep -c '^::error' exits 1 when no matches found, even though it prints "0".
#   The old `|| echo "0"` fallback then appended a second "0", producing "0\n0"
#   as the captured value. The subsequent `$((_count - _base))` arithmetic
#   crashed: "syntax error in expression (error token is '0')".
#
# Fix applied: `|| true` + `${var:-0}` pattern so grep's exit-1 is swallowed
# and the empty/zero string is normalised to 0 before arithmetic.
#
# Tests:
#   1. zero-both-sides:  biome sees 0 violations at base AND head → exit 0, Delta: 0
#   2. zero-head-only:   biome sees violations at base, 0 at head  → exit 0 (improvement)
#
# Both tests stub `npx` via PATH injection to avoid real biome downloads in CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../markdownlint-diff-helper.sh"
ORIGINAL_PATH="$PATH"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# --- helpers ------------------------------------------------------------------

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [ "$passed" -eq 0 ]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [ -n "$message" ]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_git_repo() {
	TEST_ROOT="$(mktemp -d)"
	git -C "$TEST_ROOT" init -q
	git -C "$TEST_ROOT" config user.email "test@aidevops.test"
	git -C "$TEST_ROOT" config user.name "Test Runner"
	# Disable commit signing to avoid interactive passphrase prompts in CI
	git -C "$TEST_ROOT" config commit.gpgsign false
	git -C "$TEST_ROOT" config gpg.format openpgp
	return 0
}

teardown() {
	if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
		git -C "$TEST_ROOT" worktree prune 2>/dev/null || true
		rm -rf "$TEST_ROOT"
		TEST_ROOT=""
	fi
	return 0
}

# make_stub_npx <stub_dir> <base_errors> <head_errors>
# Creates a stub npx in <stub_dir>/npx that:
#   - On its FIRST invocation (base worktree): outputs <base_errors> ::error lines
#   - On subsequent invocations (head): outputs <head_errors> ::error lines
# A call counter file inside stub_dir tracks which invocation this is.
make_stub_npx() {
	local _dir="$1"
	local _base_errors="$2"
	local _head_errors="$3"
	local _counter_file="${_dir}/.call_count"
	local _stub="${_dir}/npx"

	mkdir -p "$_dir"
	printf '0\n' > "$_counter_file"

	# Build base-error lines and head-error lines as shell fragments
	local _base_body="exit 0"
	if [ "$_base_errors" -gt 0 ]; then
		local _base_lines=""
		local _i
		for _i in $(seq 1 "$_base_errors"); do
			_base_lines="${_base_lines}  printf '::error file=foo.ts,line=${_i},col=1::Lint error ${_i}\n'\n"
		done
		_base_body="${_base_lines}  exit 1"
	fi

	local _head_body="exit 0"
	if [ "$_head_errors" -gt 0 ]; then
		local _head_lines=""
		local _j
		for _j in $(seq 1 "$_head_errors"); do
			_head_lines="${_head_lines}  printf '::error file=foo.ts,line=${_j},col=1::Lint error ${_j}\n'\n"
		done
		_head_body="${_head_lines}  exit 1"
	fi

	# Write stub using printf with explicit format to avoid shellcheck SC2016
	# (intentional: we are writing literal shell syntax to the stub file)
	# shellcheck disable=SC2059
	printf "#!/usr/bin/env bash\n_counter='%s'\n_n=\$(cat \"\$_counter\" 2>/dev/null || printf 0)\n_n=\$((_n + 1))\nprintf '%%s\\\\n' \"\$_n\" > \"\$_counter\"\nif [ \"\$_n\" -eq 1 ]; then\n%s\nelse\n%s\nfi\n" \
		"$_counter_file" "$_base_body" "$_head_body" > "$_stub"
	chmod +x "$_stub"
	return 0
}

# make_test_commits — create base + head commits with a .ts file
make_test_commits() {
	printf 'const x = 1;\n' > "${TEST_ROOT}/foo.ts"
	git -C "$TEST_ROOT" add foo.ts
	git -C "$TEST_ROOT" commit -q -m "base: add foo.ts"

	# Modify to ensure the file shows up in git diff
	printf 'const x = 1;\nconst y = 2;\n' > "${TEST_ROOT}/foo.ts"
	git -C "$TEST_ROOT" add foo.ts
	git -C "$TEST_ROOT" commit -q -m "head: extend foo.ts"
	return 0
}

# run_helper <stub_dir> — runs the helper with the stub npx and returns output + exit code
run_helper() {
	local _stub_dir="$1"
	local _base
	_base=$(git -C "$TEST_ROOT" rev-parse HEAD~1)
	local _head
	_head=$(git -C "$TEST_ROOT" rev-parse HEAD)

	local _exit=0
	local _combined
	_combined=$(
		cd "$TEST_ROOT"
		PATH="${_stub_dir}:${ORIGINAL_PATH}" \
			bash "$HELPER" --mode biome --base "$_base" --head "$_head" 2>&1
	) || _exit=$?

	printf '%s\n' "$_combined"
	if [ "$_exit" -ne 0 ]; then
		return 1
	fi
	return 0
}

# --- test 1: zero violations on both sides ------------------------------------
#
# This is the primary regression for GH#19827: when biome produces zero errors,
# the old `|| echo "0"` created "0\n0" and bash arithmetic crashed.
# After the t2376 fix, the helper must return exit 0 with "Delta: 0".

test_zero_violations_both_sides() {
	local _desc="zero-violations-both-sides"
	setup_git_repo
	make_test_commits

	local _stub_dir="${TEST_ROOT}/stub"
	make_stub_npx "$_stub_dir" 0 0

	local _output _exit=0
	_output=$(run_helper "$_stub_dir") || _exit=$?

	local _fail=0
	local _fail_msg=""

	if [ "$_exit" -ne 0 ]; then
		_fail=1
		_fail_msg="expected exit 0, got $_exit — arithmetic crash or false violation"
	elif ! printf '%s\n' "$_output" | grep -q "Delta: 0"; then
		_fail=1
		_fail_msg="'Delta: 0' not found in output; got: $(printf '%s\n' "$_output" | tail -5)"
	fi

	print_result "$_desc" "$_fail" "$_fail_msg"
	teardown
	return 0
}

# --- test 2: zero violations at head, some at base (improvement) --------------
#
# Extra guard: when base has errors but head fixes them all, delta is negative.
# The helper must still return exit 0 (no regressions introduced).

test_zero_head_positive_base() {
	local _desc="zero-head-positive-base-exits-0"
	setup_git_repo
	make_test_commits

	local _stub_dir="${TEST_ROOT}/stub"
	make_stub_npx "$_stub_dir" 3 0  # base=3 errors, head=0

	local _output _exit=0
	_output=$(run_helper "$_stub_dir") || _exit=$?

	local _fail=0
	local _fail_msg=""

	if [ "$_exit" -ne 0 ]; then
		_fail=1
		_fail_msg="expected exit 0 (delta <= 0 is not a regression), got $_exit"
	fi

	print_result "$_desc" "$_fail" "$_fail_msg"
	teardown
	return 0
}

# --- summary ------------------------------------------------------------------

main() {
	printf 'Running biome-zero regression tests (GH#19827)...\n\n'

	test_zero_violations_both_sides
	test_zero_head_positive_base

	printf '\n%d test(s) run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [ "$TESTS_FAILED" -gt 0 ]; then
		exit 1
	fi

	exit 0
}

main "$@"
