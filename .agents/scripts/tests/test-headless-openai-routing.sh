#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../headless-runtime-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.local/share/opencode" "${HOME}/.aidevops/logs"
	export OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"
	unset OPENAI_API_KEY ANTHROPIC_API_KEY
	printf '{"openai":{"type":"oauth","access":"test-openai-access"},"anthropic":{"type":"oauth","access":"test-anthropic-access"}}\n' >"${HOME}/.local/share/opencode/auth.json"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	unset OPENCODE_AUTH_FILE
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

select_model() {
	local tier="$1"
	AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai \
		AIDEVOPS_SKIP_CANARY_NEG_CACHE=1 \
		bash "$HELPER_SCRIPT" select --role worker --tier "$tier"
	return $?
}

test_openai_allowlist_selects_sonnet_tier_model() {
	local selected=""
	selected=$(select_model sonnet)
	if [[ "$selected" == "openai/gpt-5.5" ]]; then
		print_result "OpenAI allowlist selects sonnet tier from routing table" 0
		return 0
	fi
	print_result "OpenAI allowlist selects sonnet tier from routing table" 1 "Expected openai/gpt-5.5, got ${selected:-<empty>}"
	return 0
}

test_openai_allowlist_selects_haiku_tier_model() {
	local selected=""
	selected=$(select_model haiku)
	if [[ "$selected" == "openai/gpt-5.4-mini" ]]; then
		print_result "OpenAI allowlist selects haiku tier from routing table" 0
		return 0
	fi
	print_result "OpenAI allowlist selects haiku tier from routing table" 1 "Expected openai/gpt-5.4-mini, got ${selected:-<empty>}"
	return 0
}

test_openai_allowlist_selects_opus_tier_model() {
	local selected=""
	selected=$(select_model opus)
	if [[ "$selected" == "openai/gpt-5.5" ]]; then
		print_result "OpenAI allowlist selects opus tier fallback from routing table" 0
		return 0
	fi
	print_result "OpenAI allowlist selects opus tier fallback from routing table" 1 "Expected openai/gpt-5.5, got ${selected:-<empty>}"
	return 0
}

test_openai_allowlist_requires_openai_auth_entry() {
	printf '{"anthropic":{"type":"oauth","access":"test-anthropic-access"}}\n' >"${HOME}/.local/share/opencode/auth.json"
	local selected=""
	selected=$(select_model sonnet 2>/dev/null || true)
	if [[ -z "$selected" ]]; then
		print_result "OpenAI allowlist requires provider-specific auth entry" 0
		return 0
	fi
	print_result "OpenAI allowlist requires provider-specific auth entry" 1 "Expected no OpenAI model without openai auth entry, got ${selected}"
	return 0
}

main_test() {
	setup_test_env
	test_openai_allowlist_selects_sonnet_tier_model
	test_openai_allowlist_selects_haiku_tier_model
	test_openai_allowlist_selects_opus_tier_model
	test_openai_allowlist_requires_openai_auth_entry
	teardown_test_env

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
