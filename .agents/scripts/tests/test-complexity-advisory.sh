#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-complexity-advisory.sh — t2864 regression tests.
#
# Validates complexity_advisory_pre_edit.py behaviour:
#   1. Small function (< 80 lines) → no advisory output
#   2. Large function (> 80 lines, < 100) → advisory with "approaching CI gate"
#   3. Very large function (> 100 lines) → advisory with "EXCEEDS CI gate"
#   4. Multi-function edit → each oversized function reported separately
#   5. Non-shell file → silent pass (no output)
#   6. Malformed bash → silent pass (never blocks)
#   7. Write tool call (not Edit) → functions in content are also checked
#   8. Bash tool call → silently ignored (not Edit/Write)
#   9. Always permissionDecision=allow (never blocks)
#  10. function keyword style detection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HOOK_SCRIPT="${SCRIPT_DIR}/../../hooks/complexity_advisory_pre_edit.py"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Emit a JSON hook payload for Edit tool
_edit_payload() {
	local file_path="$1"
	local new_string="$2"
	python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Edit', 'tool_input': {'filePath': sys.argv[1], 'newString': sys.argv[2]}}))
" "$file_path" "$new_string"
	return 0
}

# Emit a JSON hook payload for Write tool
_write_payload() {
	local file_path="$1"
	local content="$2"
	python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Write', 'tool_input': {'filePath': sys.argv[1], 'content': sys.argv[2]}}))
" "$file_path" "$content"
	return 0
}

# Generate a bash function with N body lines
_make_function() {
	local name="$1"
	local body_lines="$2"
	python3 -c "
import sys
name, n = sys.argv[1], int(sys.argv[2])
lines = [name + '() {'] + ['  echo x'] * n + ['}']
print('\n'.join(lines))
" "$name" "$body_lines"
	return 0
}

# --- Test 1: Small function → no output ---
test_small_function_no_advisory() {
	local content
	content=$(_make_function "small_func" 10)
	local result
	result=$(_edit_payload "test.sh" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	if [[ -z "$result" ]]; then
		print_result "small function (10 lines) → no advisory" 0
	else
		print_result "small function (10 lines) → no advisory" 1 "unexpected output: $result"
	fi
	return 0
}

# --- Test 2: Large function approaching CI gate → advisory ---
test_large_function_advisory() {
	local content
	content=$(_make_function "large_func" 83)
	local result
	result=$(_edit_payload "test.sh" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	if echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('hookSpecificOutput', {})
assert r.get('permissionDecision') == 'allow', 'permissionDecision != allow'
assert 'large_func' in r.get('permissionDecisionReason', ''), 'func name missing'
assert 'approaching CI gate' in r.get('permissionDecisionReason', ''), 'wrong advisory type'
" 2>/dev/null; then
		print_result "large function (83 lines) → approaching advisory" 0
	else
		print_result "large function (83 lines) → approaching advisory" 1 "output: $result"
	fi
	return 0
}

# --- Test 3: Very large function → EXCEEDS advisory ---
test_very_large_function_exceeds() {
	local content
	content=$(_make_function "huge_func" 150)
	local result
	result=$(_edit_payload "test.sh" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	if echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('hookSpecificOutput', {})
assert r.get('permissionDecision') == 'allow', 'permissionDecision != allow'
assert 'huge_func' in r.get('permissionDecisionReason', ''), 'func name missing'
assert 'EXCEEDS CI gate' in r.get('permissionDecisionReason', ''), 'wrong advisory type'
" 2>/dev/null; then
		print_result "huge function (150 lines) → EXCEEDS advisory" 0
	else
		print_result "huge function (150 lines) → EXCEEDS advisory" 1 "output: $result"
	fi
	return 0
}

# --- Test 4: Multi-function edit → both warned ---
test_multi_function_advisory() {
	local content
	content="$(_make_function "func_a" 85)
$(_make_function "func_b" 90)"
	local result
	result=$(_edit_payload "multi.sh" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	if echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
reason = d.get('hookSpecificOutput', {}).get('permissionDecisionReason', '')
assert 'func_a' in reason, 'func_a missing'
assert 'func_b' in reason, 'func_b missing'
assert '2 function(s)' in reason, '2 functions count missing'
" 2>/dev/null; then
		print_result "multi-function edit → both functions warned" 0
	else
		print_result "multi-function edit → both functions warned" 1 "output: $result"
	fi
	return 0
}

# --- Test 5: Non-shell file → silent pass ---
test_non_shell_file_silent() {
	local content
	content="function big() { $(python3 -c "print('\n  echo x\n' * 90)") }"
	local result
	result=$(_edit_payload "script.js" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	if [[ -z "$result" ]]; then
		print_result "non-shell file (.js) → silent pass" 0
	else
		print_result "non-shell file (.js) → silent pass" 1 "unexpected output: $result"
	fi
	return 0
}

# --- Test 6: Malformed bash → silent pass ---
test_malformed_bash_silent() {
	local content="this { is {{ not valid bash"
	local result
	result=$(_edit_payload "broken.sh" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	# May produce output or not depending on brace depth — key thing is it exits 0 (no block)
	if echo "$result" | python3 -c "
import json, sys
s = sys.stdin.read().strip()
if not s:
    sys.exit(0)
d = json.loads(s)
r = d.get('hookSpecificOutput', {})
assert r.get('permissionDecision') == 'allow', 'blocked on malformed bash'
" 2>/dev/null; then
		print_result "malformed bash → never blocks" 0
	else
		print_result "malformed bash → never blocks" 1 "output: $result"
	fi
	return 0
}

# --- Test 7: Write tool → functions in content are checked ---
test_write_tool_checked() {
	local content
	content=$(_make_function "write_func" 100)
	local result
	result=$(_write_payload "output.sh" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	if echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('hookSpecificOutput', {})
assert r.get('permissionDecision') == 'allow', 'permissionDecision != allow'
assert 'write_func' in r.get('permissionDecisionReason', ''), 'func name missing'
" 2>/dev/null; then
		print_result "Write tool → content functions checked" 0
	else
		print_result "Write tool → content functions checked" 1 "output: $result"
	fi
	return 0
}

# --- Test 8: Bash tool → silently ignored ---
test_bash_tool_ignored() {
	local result
	result=$(python3 -c "import json; print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'echo hello'}}))" \
		| python3 "$HOOK_SCRIPT" 2>/dev/null)
	if [[ -z "$result" ]]; then
		print_result "Bash tool → silently ignored" 0
	else
		print_result "Bash tool → silently ignored" 1 "unexpected output: $result"
	fi
	return 0
}

# --- Test 9: permissionDecision always allow ---
test_always_allow() {
	local content
	content=$(_make_function "big_func" 200)
	local result
	result=$(_edit_payload "big.sh" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	local decision
	decision=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('hookSpecificOutput', {}).get('permissionDecision', ''))
" 2>/dev/null)
	if [[ "$decision" == "allow" ]]; then
		print_result "permissionDecision always allow (never deny)" 0
	else
		print_result "permissionDecision always allow (never deny)" 1 "got: $decision"
	fi
	return 0
}

# --- Test 10: 'function' keyword style ---
test_function_keyword_style() {
	local content
	content="function kw_style {
$(python3 -c "print('  echo x\n' * 90)")
}"
	local result
	result=$(_edit_payload "kw.sh" "$content" | python3 "$HOOK_SCRIPT" 2>/dev/null)
	if echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('hookSpecificOutput', {})
assert r.get('permissionDecision') == 'allow', 'permissionDecision != allow'
assert 'kw_style' in r.get('permissionDecisionReason', ''), 'func name missing from keyword style'
" 2>/dev/null; then
		print_result "function keyword style → detected" 0
	else
		print_result "function keyword style → detected" 1 "output: $result"
	fi
	return 0
}

# --- Main ---
if [[ ! -f "$HOOK_SCRIPT" ]]; then
	printf '%sFAIL%s Hook script not found: %s\n' "$TEST_RED" "$TEST_RESET" "$HOOK_SCRIPT"
	exit 1
fi

test_small_function_no_advisory
test_large_function_advisory
test_very_large_function_exceeds
test_multi_function_advisory
test_non_shell_file_silent
test_malformed_bash_silent
test_write_tool_checked
test_bash_tool_ignored
test_always_allow
test_function_keyword_style

echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
