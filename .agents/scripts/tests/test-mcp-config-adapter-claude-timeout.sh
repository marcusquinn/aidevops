#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ADAPTER="${SCRIPT_DIR}/../mcp-config-adapter.sh"

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

make_stub_claude() {
	local temp_dir="$1"
	local mode="$2"

	cat >"${temp_dir}/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mode="${mode}"
if [[ "\${1:-} \${2:-}" == "mcp list" ]]; then
	if [[ "\$mode" == "list-hangs" ]]; then
		sleep 5
	fi
	printf 'openapi-search: npx - status\n'
	exit 0
fi
if [[ "\${1:-} \${2:-}" == "mcp add-json" ]]; then
	if [[ "\$mode" == "add-hangs" ]]; then
		sleep 5
	fi
	printf 'added\n'
	exit 0
fi
exit 1
EOF
	chmod +x "${temp_dir}/claude"
	return 0
}

run_claude_registration_with_stub() {
	local mode="$1"
	local temp_dir
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "$temp_dir"' RETURN

	make_stub_claude "$temp_dir" "$mode"

	PATH="${temp_dir}:$PATH" AIDEVOPS_MCP_CLAUDE_TIMEOUT_SECONDS=1 bash -c '
		set -euo pipefail
		source "$1"
		_register_mcp_claude "macos-automator" "{\"command\":\"npx\",\"args\":[\"-y\",\"@example/mcp\"]}"
	' bash "$ADAPTER"
	return 0
}

test_claude_mcp_list_timeout_is_non_blocking() {
	local start end duration output
	start="$(date +%s)"
	output="$(run_claude_registration_with_stub "list-hangs" 2>&1)" || true
	end="$(date +%s)"
	duration=$((end - start))

	if [[ "$duration" -lt 4 && "$output" == *"timed out or failed"* ]]; then
		print_result "Claude MCP list timeout is non-blocking" 0
		return 0
	fi

	print_result "Claude MCP list timeout is non-blocking" 1 "duration=${duration} output=${output}"
	return 0
}

test_claude_mcp_add_timeout_is_non_blocking() {
	local start end duration output
	start="$(date +%s)"
	output="$(run_claude_registration_with_stub "add-hangs" 2>&1)" || true
	end="$(date +%s)"
	duration=$((end - start))

	if [[ "$duration" -lt 4 && "$output" == *"Failed or timed out registering"* ]]; then
		print_result "Claude MCP add-json timeout is non-blocking" 0
		return 0
	fi

	print_result "Claude MCP add-json timeout is non-blocking" 1 "duration=${duration} output=${output}"
	return 0
}

main() {
	test_claude_mcp_list_timeout_is_non_blocking
	test_claude_mcp_add_timeout_is_non_blocking

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
