#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2121:
#
# provider-auth-request.mjs wraps the Anthropic proxy response stream to
# strip the "mcp__aidevops__" prefix from tool names (so OpenCode's tool
# registry — which uses bare names — can route the model's tool calls).
# The previous implementation ran the regex on each TCP/SSE chunk in
# isolation. If Anthropic's stream split a tool name across two chunks,
# neither chunk matched the regex and the reassembled stream passed
# through to OpenCode with the unstripped prefix. OpenCode then rejected
# the model's tool call as "unavailable tool", and the worker exited
# with zero JSON activity — classified as "no_activity" exit 75 at ~30s.
#
# The fix buffers incomplete SSE lines across chunk boundaries and only
# runs the regex against complete lines.
#
# Test structure kept flat so the nesting-depth ratchet check
# (.github/workflows/code-quality.yml) doesn't count heredoc content as
# nested control-flow. The actual test driver lives in
# fixtures/t2121/driver.mjs — this file only arranges extraction and
# invocation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PLUGIN_SRC="${REPO_ROOT}/.agents/plugins/opencode-aidevops/provider-auth-request.mjs"
DRIVER_FIXTURE="${SCRIPT_DIR}/fixtures/t2121/driver.mjs"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMP_DRIVER=""

print_result() {
	local name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	[[ "$passed" -eq 0 ]] && printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$name" && return 0
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cleanup() {
	[[ -n "$TEST_TMP_DRIVER" && -f "$TEST_TMP_DRIVER" ]] && rm -f "$TEST_TMP_DRIVER"
	return 0
}

# Extract the three functions the driver needs (TOOL_PREFIX + stripMcpPrefix
# + makeStreamPullHandler) from provider-auth-request.mjs and concatenate
# with the driver fixture into a standalone .mjs that Node can run without
# triggering the plugin's module-load side effects.
build_standalone_driver() {
	TEST_TMP_DRIVER=$(mktemp)
	local tmp_mjs="${TEST_TMP_DRIVER}.mjs"
	mv "$TEST_TMP_DRIVER" "$tmp_mjs"
	TEST_TMP_DRIVER="$tmp_mjs"

	awk '
		/^export const TOOL_PREFIX/ { print; next }
		/^function stripMcpPrefix/,/^}$/ { print; next }
		/^function makeStreamPullHandler/,/^}$/ { print; next }
	' "$PLUGIN_SRC" | sed 's/^export const /const /' >"$TEST_TMP_DRIVER"

	cat "$DRIVER_FIXTURE" >>"$TEST_TMP_DRIVER"
	return 0
}

test_structural_pending_buffer() {
	local fn_src
	fn_src=$(awk '/^function makeStreamPullHandler/,/^}$/ { print }' "$PLUGIN_SRC")
	[[ -z "$fn_src" ]] && print_result "structural: makeStreamPullHandler extracted" 1 "empty" && return 0

	printf '%s\n' "$fn_src" | grep -q "let pending" ||
		{
			print_result "structural: pending buffer present" 1 "missing 'let pending'"
			return 0
		}
	printf '%s\n' "$fn_src" | grep -qF 'lastIndexOf("\n")' ||
		{
			print_result "structural: lastIndexOf newline present" 1 "missing lastIndexOf"
			return 0
		}

	print_result "structural: pull handler uses newline buffering" 0
	return 0
}

run_driver_case() {
	local case_name="$1"
	local test_name="$2"
	command -v node >/dev/null 2>&1 || {
		print_result "$test_name" 1 "node not found"
		return 0
	}

	local result rc=0
	result=$(T2121_CASE="$case_name" node "$TEST_TMP_DRIVER" 2>&1) || rc=$?
	[[ "$rc" -eq 0 && "$result" == *"OK"* ]] &&
		print_result "$test_name" 0 ||
		print_result "$test_name" 1 "rc=${rc} output=${result: -200}"
	return 0
}

main() {
	trap cleanup EXIT

	test_structural_pending_buffer
	build_standalone_driver
	run_driver_case "whole" "runtime: whole-event chunk (no split)"
	run_driver_case "split" "runtime: chunk boundary mid-token"

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -gt 0 ]] && return 1
	return 0
}

main "$@"
