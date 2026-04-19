#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pre-commit-ratchet.sh — Integration test for ratchet-style quality
# validators in pre-commit-hook.sh (t2230).
#
# Validators under test:
#   1. validate_string_literals       — repeated string literals
#   2. validate_return_statements     — functions without explicit return
#   3. validate_positional_parameters — bare $1/$2 usage
#   4. run_shellcheck                 — ShellCheck findings
#
# Ratchet contract (AGENTS.md "Gate design — ratchet, not absolute"):
#   - Pre-existing violations (staged_count <= head_count) MUST pass, with a
#     warning. Authors cannot be trapped by legacy debt on files they touch.
#   - NEW violations (staged_count > head_count) MUST fail. Regression is
#     blocked at the exact point it is introduced.
#   - NEW files carrying violations (head_count = 0, staged_count > 0) MUST
#     fail — first arrival is caught by the strict inequality.
#
# Security exception: check_secrets remains absolute-count. Not covered here
# (covered by its own secretlint test suite).
#
# Test strategy:
#   Each test scenario initialises an ephemeral git repo, commits a "base"
#   version of a file, stages a "modified" version, and invokes the real
#   validator function sourced from pre-commit-hook.sh. Return value is the
#   contract; stdout/stderr is scanned for classification markers
#   ("NEW ..." = blocking, "Pre-existing ..." = advisory).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK_SCRIPT="${SCRIPT_DIR}/../pre-commit-hook.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIG_DIR=""

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

setup() {
	ORIG_DIR=$(pwd)
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown() {
	if [ -n "$ORIG_DIR" ]; then
		cd "$ORIG_DIR" || true
	fi
	if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Initialise an ephemeral git repo under $TEST_ROOT/<slug> and cd into it.
# Global: sets REPO_DIR to the new repo path.
# shellcheck disable=SC2034
init_repo() {
	local slug="$1"
	REPO_DIR="${TEST_ROOT}/${slug}"
	mkdir -p "$REPO_DIR"
	cd "$REPO_DIR" || return 1
	git init -q -b main
	git config user.email "test@example.invalid"
	git config user.name "Ratchet Test"
	git config commit.gpgsign false
	return 0
}

# Commit $2 as the base version of file $1. Leaves the working tree clean.
commit_base() {
	local file="$1"
	local content="$2"
	printf '%s' "$content" >"$file"
	git add "$file"
	git commit -q -m "base: $file" --no-verify
	return 0
}

# Overwrite $1 with $2 and stage it (no commit). This is the "staged" state
# the validators inspect.
stage_change() {
	local file="$1"
	local content="$2"
	printf '%s' "$content" >"$file"
	git add "$file"
	return 0
}

# Source just the helpers + validator we want to exercise, under a stubbed
# shared-constants so color codes and print_* work in a minimal environment.
source_hook_helpers() {
	# Provide stubs for print_* so output classification is captured.
	print_error() {
		local msg="$1"
		echo "[ERROR] $msg" >&2
		return 0
	}
	print_warning() {
		local msg="$1"
		echo "[WARNING] $msg" >&2
		return 0
	}
	print_info() {
		local msg="$1"
		echo "[INFO] $msg" >&2
		return 0
	}
	print_success() {
		local msg="$1"
		echo "[OK] $msg" >&2
		return 0
	}

	# Source helpers and validators by evaluating only the function definitions
	# from the hook script. The script's `main "$@"` call would run the full
	# hook, which we don't want here — extract only the definitions.
	local hook_funcs
	hook_funcs=$(awk '
		/^_get_head_content\(\)/              { c=1 }
		/^_make_head_temp\(\)/                { c=1 }
		/^_count_repeated_literals\(\)/       { c=1 }
		/^_show_repeated_literals\(\)/        { c=1 }
		/^validate_return_statements\(\)/     { c=1 }
		/^validate_positional_parameters\(\)/ { c=1 }
		/^validate_string_literals\(\)/       { c=1 }
		/^run_shellcheck\(\)/                 { c=1 }
		c { print }
		c && /^}$/                            { c=0 }
	' "$HOOK_SCRIPT")

	# shellcheck disable=SC1090  # dynamic eval is the whole point here
	eval "$hook_funcs"
	return 0
}

# ---------------------------------------------------------------------------
# Scenario: a file with N distinct literals repeated >= 3 times
# ---------------------------------------------------------------------------

STRING_LITERAL_BASE='#!/usr/bin/env bash
a1="assertion one matches"
a2="assertion one matches"
a3="assertion one matches"
b1="second repeated message"
b2="second repeated message"
b3="second repeated message"
'

STRING_LITERAL_MORE='#!/usr/bin/env bash
a1="assertion one matches"
a2="assertion one matches"
a3="assertion one matches"
b1="second repeated message"
b2="second repeated message"
b3="second repeated message"
c1="brand new repeated string"
c2="brand new repeated string"
c3="brand new repeated string"
'

STRING_LITERAL_UNCHANGED_BUT_TOUCHED='#!/usr/bin/env bash
a1="assertion one matches"
a2="assertion one matches"
a3="assertion one matches"
b1="second repeated message"
b2="second repeated message"
b3="second repeated message"
# Adding this comment is a no-op touch — no new literals.
'

# ---------------------------------------------------------------------------
# Scenario: a file with N functions missing explicit returns
# ---------------------------------------------------------------------------

RETURN_BASE='#!/usr/bin/env bash
foo() {
	echo "foo"
}

bar() {
	echo "bar"
}
'

RETURN_MORE='#!/usr/bin/env bash
foo() {
	echo "foo"
}

bar() {
	echo "bar"
}

baz() {
	echo "baz"
}
'

# ---------------------------------------------------------------------------
# Scenario: a file with N bare positional parameter references
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # $1/$2 are literal fixture bodies, not shell expansions
POSPARAM_BASE='#!/usr/bin/env bash
foo() {
	echo "$1 got value"
	echo "$2 was also here"
}
'

# shellcheck disable=SC2016  # $1/$2/$3 are literal fixture bodies, not shell expansions
POSPARAM_MORE='#!/usr/bin/env bash
foo() {
	echo "$1 got value"
	echo "$2 was also here"
	echo "$3 is a new offender"
}
'

# ---------------------------------------------------------------------------
# String literal validator — 3 cases
# ---------------------------------------------------------------------------

test_string_literals_preexisting_pass() {
	init_repo "strlit_preexisting"
	commit_base "offender.sh" "$STRING_LITERAL_BASE"
	stage_change "offender.sh" "$STRING_LITERAL_UNCHANGED_BUT_TOUCHED"

	source_hook_helpers
	local stderr_out ret=0
	stderr_out=$(validate_string_literals "offender.sh" 2>&1) || ret=$?

	if [ "$ret" -eq 0 ] && echo "$stderr_out" | grep -q 'Pre-existing repeated string literals'; then
		print_result "string_literals: pre-existing same-count PASSES (ratchet)" 0
	else
		print_result "string_literals: pre-existing same-count PASSES (ratchet)" 1 \
			"expected exit 0 + 'Pre-existing' warning, got exit=$ret output=[$stderr_out]"
	fi
	return 0
}

test_string_literals_new_literal_blocks() {
	init_repo "strlit_new"
	commit_base "offender.sh" "$STRING_LITERAL_BASE"
	stage_change "offender.sh" "$STRING_LITERAL_MORE"

	source_hook_helpers
	local stderr_out ret=0
	stderr_out=$(validate_string_literals "offender.sh" 2>&1) || ret=$?

	if [ "$ret" -gt 0 ] && echo "$stderr_out" | grep -q 'NEW repeated string literals'; then
		print_result "string_literals: NEW literal BLOCKS (ratchet)" 0
	else
		print_result "string_literals: NEW literal BLOCKS (ratchet)" 1 \
			"expected exit>0 + 'NEW' error, got exit=$ret output=[$stderr_out]"
	fi
	return 0
}

test_string_literals_new_file_with_debt_blocks() {
	init_repo "strlit_newfile"
	# Make git happy with an initial commit, then introduce the offender as new.
	commit_base "README.md" "seed"
	stage_change "offender.sh" "$STRING_LITERAL_BASE"

	source_hook_helpers
	local stderr_out ret=0
	stderr_out=$(validate_string_literals "offender.sh" 2>&1) || ret=$?

	if [ "$ret" -gt 0 ] && echo "$stderr_out" | grep -q 'NEW repeated string literals'; then
		print_result "string_literals: NEW file with debt BLOCKS" 0
	else
		print_result "string_literals: NEW file with debt BLOCKS" 1 \
			"expected exit>0 + 'NEW' error for new file, got exit=$ret output=[$stderr_out]"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Return statement validator — 2 cases
# ---------------------------------------------------------------------------

test_return_statements_preexisting_pass() {
	init_repo "return_preexisting"
	commit_base "returns.sh" "$RETURN_BASE"
	# Identical content — "touched" but no new missing returns.
	stage_change "returns.sh" "$RETURN_BASE
# trivial comment touch
"

	source_hook_helpers
	local stderr_out ret=0
	stderr_out=$(validate_return_statements "returns.sh" 2>&1) || ret=$?

	if [ "$ret" -eq 0 ] && echo "$stderr_out" | grep -q 'Pre-existing missing returns'; then
		print_result "return_statements: pre-existing missing returns PASS (ratchet)" 0
	else
		print_result "return_statements: pre-existing missing returns PASS (ratchet)" 1 \
			"expected exit 0 + 'Pre-existing' warning, got exit=$ret output=[$stderr_out]"
	fi
	return 0
}

test_return_statements_new_missing_blocks() {
	init_repo "return_new"
	commit_base "returns.sh" "$RETURN_BASE"
	stage_change "returns.sh" "$RETURN_MORE"

	source_hook_helpers
	local stderr_out ret=0
	stderr_out=$(validate_return_statements "returns.sh" 2>&1) || ret=$?

	if [ "$ret" -gt 0 ] && echo "$stderr_out" | grep -q 'NEW missing return statements'; then
		print_result "return_statements: NEW missing return BLOCKS (ratchet)" 0
	else
		print_result "return_statements: NEW missing return BLOCKS (ratchet)" 1 \
			"expected exit>0 + 'NEW' error, got exit=$ret output=[$stderr_out]"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Positional parameter validator — 2 cases
# ---------------------------------------------------------------------------

test_positional_params_preexisting_pass() {
	init_repo "posparam_preexisting"
	commit_base "posparam.sh" "$POSPARAM_BASE"
	stage_change "posparam.sh" "$POSPARAM_BASE
# trivial touch
"

	source_hook_helpers
	local stderr_out ret=0
	stderr_out=$(validate_positional_parameters "posparam.sh" 2>&1) || ret=$?

	if [ "$ret" -eq 0 ] && echo "$stderr_out" | grep -q 'Pre-existing positional parameter usage'; then
		print_result "positional_params: pre-existing usage PASSES (ratchet)" 0
	else
		print_result "positional_params: pre-existing usage PASSES (ratchet)" 1 \
			"expected exit 0 + 'Pre-existing' warning, got exit=$ret output=[$stderr_out]"
	fi
	return 0
}

test_positional_params_new_usage_blocks() {
	init_repo "posparam_new"
	commit_base "posparam.sh" "$POSPARAM_BASE"
	stage_change "posparam.sh" "$POSPARAM_MORE"

	source_hook_helpers
	local stderr_out ret=0
	stderr_out=$(validate_positional_parameters "posparam.sh" 2>&1) || ret=$?

	if [ "$ret" -gt 0 ] && echo "$stderr_out" | grep -q 'NEW direct positional parameter usage'; then
		print_result "positional_params: NEW usage BLOCKS (ratchet)" 0
	else
		print_result "positional_params: NEW usage BLOCKS (ratchet)" 1 \
			"expected exit>0 + 'NEW' error, got exit=$ret output=[$stderr_out]"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Classification labels (output contract)
# ---------------------------------------------------------------------------

test_classification_labels_present() {
	init_repo "labels"
	commit_base "offender.sh" "$STRING_LITERAL_BASE"

	# Case 1: unchanged → warning path
	stage_change "offender.sh" "$STRING_LITERAL_UNCHANGED_BUT_TOUCHED"
	source_hook_helpers
	local out_pre
	out_pre=$(validate_string_literals "offender.sh" 2>&1 || true)

	# Case 2: new → error path
	stage_change "offender.sh" "$STRING_LITERAL_MORE"
	local out_new
	out_new=$(validate_string_literals "offender.sh" 2>&1 || true)

	local ok=0
	if ! echo "$out_pre" | grep -q '(not blocking)'; then
		ok=1
	fi
	if ! echo "$out_new" | grep -q 'new:'; then
		ok=1
	fi

	if [ "$ok" -eq 0 ]; then
		print_result "output classification: 'not blocking' + 'new:' labels present" 0
	else
		print_result "output classification: 'not blocking' + 'new:' labels present" 1 \
			"pre-existing output: [$out_pre]; new output: [$out_new]"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Security exception: source check — check_secrets stays absolute
# ---------------------------------------------------------------------------

test_check_secrets_remains_absolute() {
	if [ ! -f "$HOOK_SCRIPT" ]; then
		print_result "check_secrets: security exception annotation present" 1 \
			"pre-commit-hook.sh not found"
		return 0
	fi

	# The function must be marked with the absolute-count annotation.
	if grep -q 'SECURITY EXCEPTION' "$HOOK_SCRIPT" && \
	   grep -q 'absolute-count security gate' "$HOOK_SCRIPT"; then
		print_result "check_secrets: security exception annotation present" 0
	else
		print_result "check_secrets: security exception annotation present" 1 \
			"expected SECURITY EXCEPTION + 'absolute-count security gate' annotation in hook source"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	setup

	test_string_literals_preexisting_pass
	test_string_literals_new_literal_blocks
	test_string_literals_new_file_with_debt_blocks
	test_return_statements_preexisting_pass
	test_return_statements_new_missing_blocks
	test_positional_params_preexisting_pass
	test_positional_params_new_usage_blocks
	test_classification_labels_present
	test_check_secrets_remains_absolute

	teardown

	echo ""
	if [ "$TESTS_FAILED" -eq 0 ]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	else
		printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
		return 1
	fi
}

main "$@"
