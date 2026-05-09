#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="${SCRIPT_DIR}/../../.."
SETUP_SH="${REPO_ROOT}/setup.sh"
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_contains() {
	local test_name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "missing: $needle"
	return 0
}

file_text() {
	local path="$1"
	python3 - "$path" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).read_text())
PY
	return $?
}

test_setup_stage_contract() {
	local text=""
	text="$(file_text "$SETUP_SH")" || {
		print_result "setup.sh is readable" 1 "$SETUP_SH"
		return 0
	}

	assert_contains "setup.sh accepts --stage" "$text" "--stage <name>"
	assert_contains "opencode scope maps to setup_opencode_cli" "$text" "opencode | \"\$SETUP_STAGE_OPENCODE\") printf '%s' \"\$SETUP_STAGE_OPENCODE\""
	assert_contains "agents scope maps to deploy_aidevops_agents" "$text" "agents | \"\$SETUP_STAGE_AGENTS\") printf '%s' \"\$SETUP_STAGE_AGENTS\""
	assert_contains "hooks scope maps to setup_safety_hooks" "$text" "hooks | \"\$SETUP_STAGE_HOOKS\") printf '%s' \"\$SETUP_STAGE_HOOKS\""
	assert_contains "tabby scope maps to setup_tabby" "$text" "tabby | \"\$SETUP_STAGE_TABBY\") printf '%s' \"\$SETUP_STAGE_TABBY\""
	assert_contains "pulse scope maps to setup_supervisor_pulse" "$text" "pulse | \"\$SETUP_STAGE_PULSE\") printf '%s' \"\$SETUP_STAGE_PULSE\""
	assert_contains "unknown stages print actionable help" "$text" "Unknown setup stage/scope"
	return 0
}

test_cli_scope_contract() {
	local text=""
	text="$(file_text "$AIDEVOPS_SH")" || {
		print_result "aidevops.sh is readable" 1 "$AIDEVOPS_SH"
		return 0
	}

	assert_contains "aidevops exposes setup command" "$text" "setup) cmd_setup \"\$@\" ;;"
	assert_contains "aidevops setup requires scope" "$text" "Usage: aidevops setup --scope <scope>"
	assert_contains "aidevops setup passes scope to setup.sh" "$text" "bash \"\$setup_script\" --stage \"\$scope\""
	assert_contains "aidevops setup full preserves full setup" "$text" "bash \"\$setup_script\" --non-interactive"
	return 0
}

main() {
	test_setup_stage_contract
	test_cli_scope_contract

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
