#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Test: headless contract clarity (t2983 / GH#21355, Fix C from t2980)
#
# Verifies that `append_worker_headless_contract` does NOT emit a contract
# that simultaneously tells the worker "do not call worktree-helper.sh" and
# "create a worktree via worktree-helper.sh add". The contradiction (present in
# V6) caused Mode B orphan log lines and was fixed by removing the fallback
# clause in V7.
#
# References:
#   - headless-runtime-lib.sh::append_worker_headless_contract
#   - reference/worker-branch-classification.md "Mode B", "Fix C"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
PARENT_DIR="${SCRIPT_DIR}/.."

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

_pass() {
	local test_name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf 'PASS %s\n' "$test_name"
	return 0
}

_fail() {
	local test_name="$1"
	local message="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '  %s\n' "$message"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: source headless-runtime-lib.sh in a subshell so the test stays
# isolated. The sub-libraries (headless-runtime-provider.sh, etc.) have no
# file-scope function calls — sourcing them only defines functions that are
# never invoked here. SCRIPT_DIR is set to the real scripts dir so the
# sub-library `source` directives resolve correctly.
# ---------------------------------------------------------------------------

SCRIPTS_DIR="$PARENT_DIR"

# Verify the target file exists.
LIB_FILE="${SCRIPTS_DIR}/headless-runtime-lib.sh"
if [[ ! -f "$LIB_FILE" ]]; then
	printf 'FAIL setup: %s not found\n' "$LIB_FILE"
	exit 1
fi

# Source the lib. Sub-libraries will resolve via SCRIPT_DIR.
SCRIPT_DIR="$SCRIPTS_DIR"
export SCRIPT_DIR
export AIDEVOPS_BASH_REEXECED=1
# shellcheck source=/dev/null
source "$LIB_FILE"

# ---------------------------------------------------------------------------
# Case 1: Contract marker is V7 (not the contradictory V6)
# ---------------------------------------------------------------------------
test_contract_version_is_v7() {
	local output
	output=$(append_worker_headless_contract "/full-loop Implement GH#1")

	if [[ "$output" == *"HEADLESS_CONTINUATION_CONTRACT_V7"* ]]; then
		_pass "contract_version_is_v7"
	else
		_fail "contract_version_is_v7" \
			"Expected HEADLESS_CONTINUATION_CONTRACT_V7 in output, not found"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 2: The fallback "create a worktree yourself via worktree-helper.sh add"
# clause is absent (removed in Fix C / V7)
# ---------------------------------------------------------------------------
test_no_worktree_creation_fallback() {
	local output
	output=$(append_worker_headless_contract "/full-loop Implement GH#1")

	if [[ "$output" == *"create a worktree yourself via worktree-helper.sh add"* ]]; then
		_fail "no_worktree_creation_fallback" \
			"Contradiction: contract still contains the forbidden fallback clause"
	else
		_pass "no_worktree_creation_fallback"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 3: The unconditional prohibition on worktree-helper.sh is present
# ---------------------------------------------------------------------------
test_unconditional_do_not_call_worktree_helper() {
	local output
	output=$(append_worker_headless_contract "/full-loop Implement GH#1")

	if [[ "$output" == *"worktree-helper.sh"* ]]; then
		_pass "unconditional_do_not_call_worktree_helper"
	else
		_fail "unconditional_do_not_call_worktree_helper" \
			"Expected 'worktree-helper.sh' mention (prohibition) in contract output"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 4: V6 contradiction pattern does NOT appear
#   - "do not call worktree-helper.sh" (prohibition) AND
#   - "create a worktree ... via worktree-helper.sh" (fallback)
# Both must not appear together.
# ---------------------------------------------------------------------------
test_no_simultaneous_prohibit_and_permit() {
	local output
	output=$(append_worker_headless_contract "/full-loop Implement GH#1")

	local has_prohibit=0
	local has_fallback=0

	# Prohibition clause — present in both V6 and V7
	if [[ "$output" == *"Do NOT call"*"worktree-helper.sh"* ]] || \
	   [[ "$output" == *"worktree-helper.sh"*"under any circumstances"* ]]; then
		has_prohibit=1
	fi

	# Fallback clause — was present in V6, must be absent in V7
	if [[ "$output" == *"create a worktree"*"worktree-helper.sh"* ]] || \
	   [[ "$output" == *"worktree-helper.sh add"* ]]; then
		has_fallback=1
	fi

	if [[ "$has_prohibit" -eq 1 && "$has_fallback" -eq 1 ]]; then
		_fail "no_simultaneous_prohibit_and_permit" \
			"Both the prohibition and the fallback clause are present (V6 contradiction)"
	else
		_pass "no_simultaneous_prohibit_and_permit"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 5: Non-/full-loop prompts pass through unchanged
# ---------------------------------------------------------------------------
test_non_fullloop_passthrough() {
	local prompt="Just a regular prompt with no slash commands"
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		_pass "non_fullloop_passthrough"
	else
		_fail "non_fullloop_passthrough" \
			"Non-/full-loop prompt was modified when it should pass through unchanged"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 6: Already-contracted prompts are not double-injected
# ---------------------------------------------------------------------------
test_no_double_injection() {
	local first
	first=$(append_worker_headless_contract "/full-loop Implement GH#1")

	local second
	second=$(append_worker_headless_contract "$first")

	# The contract marker should appear exactly once.
	local count
	count=$(printf '%s' "$second" | grep -c "HEADLESS_CONTINUATION_CONTRACT_V" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	if [[ "$count" -eq 1 ]]; then
		_pass "no_double_injection"
	else
		_fail "no_double_injection" \
			"Contract injected ${count} times, expected 1"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 7: AIDEVOPS_HEADLESS_APPEND_CONTRACT=0 suppresses injection
# ---------------------------------------------------------------------------
test_opt_out_env_var() {
	local prompt="/full-loop Implement GH#1"
	local output
	output=$(AIDEVOPS_HEADLESS_APPEND_CONTRACT=0 append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		_pass "opt_out_env_var"
	else
		_fail "opt_out_env_var" \
			"AIDEVOPS_HEADLESS_APPEND_CONTRACT=0 did not suppress injection"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_contract_version_is_v7
test_no_worktree_creation_fallback
test_unconditional_do_not_call_worktree_helper
test_no_simultaneous_prohibit_and_permit
test_non_fullloop_passthrough
test_no_double_injection
test_opt_out_env_var

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests, %d passed, %d failed\n' \
	"$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
