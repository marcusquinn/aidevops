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

test_openai_allowlist_selects_standard_tier_model() {
	local selected=""
	selected=$(select_model standard)
	if [[ "$selected" == "openai/gpt-6.1-sol" ]]; then
		print_result "OpenAI allowlist selects standard tier from routing table" 0
		return 0
	fi
	print_result "OpenAI allowlist selects standard tier from routing table" 1 "Expected openai/gpt-6.1-sol, got ${selected:-<empty>}"
	return 0
}

test_openai_allowlist_selects_simple_tier_model() {
	local selected=""
	selected=$(select_model simple)
	if [[ "$selected" == "openai/gpt-6-luna" ]]; then
		print_result "OpenAI allowlist selects simple tier from routing table" 0
		return 0
	fi
	print_result "OpenAI allowlist selects simple tier from routing table" 1 "Expected openai/gpt-6-luna, got ${selected:-<empty>}"
	return 0
}

test_openai_allowlist_selects_thinking_tier_model() {
	local selected=""
	selected=$(select_model thinking)
	if [[ "$selected" == "openai/gpt-6.1-sol" ]]; then
		print_result "OpenAI allowlist selects thinking tier from routing table" 0
		return 0
	fi
	print_result "OpenAI allowlist selects thinking tier from routing table" 1 "Expected openai/gpt-6.1-sol, got ${selected:-<empty>}"
	return 0
}

test_openai_allowlist_requires_openai_auth_entry() {
	printf '{"anthropic":{"type":"oauth","access":"test-anthropic-access"}}\n' >"${HOME}/.local/share/opencode/auth.json"
	local selected=""
	selected=$(select_model standard 2>/dev/null || true)
	if [[ -z "$selected" ]]; then
		print_result "OpenAI allowlist requires provider-specific auth entry" 0
		return 0
	fi
	print_result "OpenAI allowlist requires provider-specific auth entry" 1 "Expected no OpenAI model without openai auth entry, got ${selected}"
	return 0
}

test_standard_alternatives_are_scoped() {
	local routing_table="${SCRIPT_DIR}/../../configs/model-routing-table.json"
	local models=""
	models=$(jq -r '.tiers.standard.models[]' "$routing_table")
	if ! grep -q '^zai' <<<"$models"; then
		print_result "Standard tier ships no Z.AI GLM candidate" 0
		return 0
	fi
	print_result "Standard tier ships no Z.AI GLM candidate" 1
	return 0
}

test_entitlement_backoff_is_model_scoped() {
	printf '{"openai":{"type":"oauth","access":"test-openai-access"}}\n' >"${HOME}/.local/share/opencode/auth.json"
	local failure="${TEST_ROOT}/entitlement.jsonl" reason status selected
	printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"statusCode":404,"responseBody":"{\"error\":{\"code\":\"model_not_found\"}}"}}}' >"$failure"
	reason=$(python3 "${SCRIPT_DIR}/../headless-runtime-provider-classifier.py" "$failure" | cut -f1)
	bash "$HELPER_SCRIPT" backoff set openai/gpt-6.1-sol "$reason" 3600
	status=$(bash "$HELPER_SCRIPT" backoff status)
	selected=$(select_model simple)
	if [[ "$reason" == "model_unavailable" && "$status" == *"openai/gpt-6.1-sol|model_unavailable|"* && "$selected" == "openai/gpt-6-luna" ]]; then
		print_result "Entitlement rejection backs off only the rejected model" 0
	else
		print_result "Entitlement rejection backs off only the rejected model" 1
	fi
	return 0
}

main_test() {
	setup_test_env
	test_openai_allowlist_selects_standard_tier_model
	test_openai_allowlist_selects_simple_tier_model
	test_openai_allowlist_selects_thinking_tier_model
	test_openai_allowlist_requires_openai_auth_entry
	test_standard_alternatives_are_scoped
	test_entitlement_backoff_is_model_scoped
	teardown_test_env

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
