#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-headless-contract-escalation.sh — Regression tests for GH#14964
#
# Verifies that:
# 1. The headless continuation contract injected by headless-runtime-helper.sh
#    includes the model escalation requirement (rule 6).
# 2. The contract is NOT injected when AIDEVOPS_HEADLESS_APPEND_CONTRACT=0.
# 3. The contract is NOT injected for non-/full-loop prompts.
# 4. The contract is NOT injected when already present (idempotent).
# 5. The escalation rule text is present and references GH#14964.
#
# Strategy: extract the append_worker_headless_contract function body from the
# helper script and test it directly, avoiding the need to source the full
# script (which has complex dependencies and runs main() at load time).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HEADLESS_HELPER="${SCRIPT_DIR}/../headless-runtime-helper.sh"
# The contract heredoc and append_worker_headless_contract function live in
# headless-runtime-lib.sh after the helper was split for the LARGE_FILE gate.
HEADLESS_LIB="${SCRIPT_DIR}/../headless-runtime-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Extract the contract text directly from the heredoc in headless-runtime-helper.sh.
# This is the source of truth — we test the actual contract content, not the
# injection logic (which is already tested by the existing contract injection tests).
extract_contract_text() {
	python3 - "${HEADLESS_LIB}" <<'PY'
import re
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text()

# Find the heredoc block for the contract. The lib has only one cat <<'EOF',
# but anchor on the contract marker to be robust against future additions.
match = re.search(
    r"cat\s+<<'EOF'\s*\n(\[HEADLESS_CONTINUATION_CONTRACT_V\d+\].*?)\nEOF",
    content,
    re.DOTALL,
)
if match:
    print(match.group(1))
else:
    print("")
PY
	return 0
}

# Test the append_worker_headless_contract function by running it in a subprocess
# that sources only the function (not main). We do this by extracting the function
# body and running it standalone.
_call_append_contract() {
	local append_enabled="${1:-1}"
	local prompt_text="$2"

	# Extract just the append_worker_headless_contract function from the lib
	local func_body
	func_body=$(
		python3 - "${HEADLESS_LIB}" <<'PY'
import re
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text()

# Extract the append_worker_headless_contract function
match = re.search(
    r'(append_worker_headless_contract\(\)\s*\{.*?\n\})',
    content,
    re.DOTALL,
)
if match:
    print(match.group(1))
else:
    print("")
PY
	)

	if [[ -z "$func_body" ]]; then
		printf '%s' "ERROR: could not extract function"
		return 1
	fi

	AIDEVOPS_HEADLESS_APPEND_CONTRACT="$append_enabled" \
		bash --norc --noprofile -c "
			set -euo pipefail
			${func_body}
			append_worker_headless_contract \"\$1\"
		" -- "$prompt_text" 2>/dev/null
	return 0
}

test_contract_includes_escalation_rule() {
	local contract_text
	contract_text=$(extract_contract_text)

	if [[ "$contract_text" == *"GH#14964"* ]]; then
		print_result "contract heredoc includes GH#14964 escalation reference" 0
		return 0
	fi

	print_result "contract heredoc includes GH#14964 escalation reference" 1 \
		"Expected GH#14964 in contract heredoc; got: $(printf '%s' "$contract_text" | tail -5)"
	return 0
}

test_contract_includes_escalation_text() {
	local contract_text
	contract_text=$(extract_contract_text)

	if [[ "$contract_text" == *"escalation"* ]] ||
		[[ "$contract_text" == *"escalate"* ]]; then
		print_result "contract heredoc includes model escalation requirement text" 0
		return 0
	fi

	print_result "contract heredoc includes model escalation requirement text" 1 \
		"Expected escalation text in contract heredoc; got: $(printf '%s' "$contract_text" | tail -5)"
	return 0
}

test_contract_includes_rule_6() {
	local contract_text
	contract_text=$(extract_contract_text)

	# Rule 6 should be present (the new escalation rule)
	if [[ "$contract_text" == *"6."* ]]; then
		print_result "contract heredoc includes rule 6 (escalation)" 0
		return 0
	fi

	print_result "contract heredoc includes rule 6 (escalation)" 1 \
		"Expected rule 6 in contract heredoc; got: $(printf '%s' "$contract_text" | tail -10)"
	return 0
}

test_contract_not_injected_when_disabled() {
	local prompt='/full-loop Implement issue #14964'
	local result
	result=$(_call_append_contract "0" "$prompt")

	if [[ "$result" == *"HEADLESS_CONTINUATION_CONTRACT_V6"* ]]; then
		print_result "contract not injected when AIDEVOPS_HEADLESS_APPEND_CONTRACT=0" 1 \
			"Expected no contract injection when disabled"
		return 0
	fi

	print_result "contract not injected when AIDEVOPS_HEADLESS_APPEND_CONTRACT=0" 0
	return 0
}

test_contract_not_injected_for_non_full_loop() {
	local prompt='Run some other task'
	local result
	result=$(_call_append_contract "1" "$prompt")

	if [[ "$result" == *"HEADLESS_CONTINUATION_CONTRACT_V6"* ]]; then
		print_result "contract not injected for non-/full-loop prompts" 1 \
			"Expected no contract injection for non-/full-loop prompt"
		return 0
	fi

	print_result "contract not injected for non-/full-loop prompts" 0
	return 0
}

test_contract_idempotent() {
	local prompt
	prompt=$(printf '/full-loop Implement issue #14964\n\n[HEADLESS_CONTINUATION_CONTRACT_V6]\nThis worker run is unattended.')
	local result
	result=$(_call_append_contract "1" "$prompt")

	# Count occurrences of the contract marker
	local count
	count=$(printf '%s' "$result" | grep -c "HEADLESS_CONTINUATION_CONTRACT_V6" || true)

	if [[ "$count" -eq 1 ]]; then
		print_result "contract injection is idempotent (not duplicated)" 0
		return 0
	fi

	print_result "contract injection is idempotent (not duplicated)" 1 \
		"Expected exactly 1 contract marker, found ${count}"
	return 0
}

test_genuine_blockers_distinguished() {
	local contract_text
	contract_text=$(extract_contract_text)

	# The contract should mention that genuine blockers (missing credentials,
	# failing checks, explicit policy gates) ARE valid — it should not say ALL
	# blockers are invalid. The current V6 contract phrases this as the
	# concrete evidence list in rule 8: "failing check, missing permission,
	# unresolved conflict, or explicit policy gate".
	if [[ "$contract_text" == *"missing permission"* ]] &&
		[[ "$contract_text" == *"explicit policy gate"* ]]; then
		print_result "contract distinguishes genuine blockers from invalid ones" 0
		return 0
	fi
	# Legacy wording (kept for backward compatibility with older contract versions)
	if [[ "$contract_text" == *"genuine blocker"* ]] ||
		[[ "$contract_text" == *"persists after escalation"* ]]; then
		print_result "contract distinguishes genuine blockers from invalid ones" 0
		return 0
	fi

	print_result "contract distinguishes genuine blockers from invalid ones" 1 \
		"Expected contract to mention genuine blockers; got: $(printf '%s' "$contract_text" | tail -5)"
	return 0
}

test_contract_injected_for_full_loop() {
	local prompt='/full-loop Implement issue #14964'
	local result
	result=$(_call_append_contract "1" "$prompt")

	if [[ "$result" == *"HEADLESS_CONTINUATION_CONTRACT_V6"* ]]; then
		print_result "contract injected for /full-loop prompts" 0
		return 0
	fi

	print_result "contract injected for /full-loop prompts" 1 \
		"Expected contract injection for /full-loop prompt"
	return 0
}

main() {
	[[ -f "$HEADLESS_HELPER" ]] || {
		printf '%bFAIL%b headless-runtime-helper.sh not found at %s\n' \
			"$TEST_RED" "$TEST_RESET" "$HEADLESS_HELPER"
		exit 1
	}

	test_contract_includes_escalation_rule
	test_contract_includes_escalation_text
	test_contract_includes_rule_6
	test_contract_not_injected_when_disabled
	test_contract_not_injected_for_non_full_loop
	test_contract_idempotent
	test_genuine_blockers_distinguished
	test_contract_injected_for_full_loop

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
