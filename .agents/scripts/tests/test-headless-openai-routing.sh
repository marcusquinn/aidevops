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

test_entitlement_rejections_classify_as_model_unavailable() {
	local classifier="${SCRIPT_DIR}/../headless-runtime-provider-classifier.py"
	local structured="${TEST_ROOT}/entitlement-structured.jsonl"
	local codex="${TEST_ROOT}/entitlement-codex.jsonl"
	local plaintext="${TEST_ROOT}/entitlement-plaintext.log"
	local permission="${TEST_ROOT}/permission.jsonl"
	printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"statusCode":404,"responseBody":"{\"error\":{\"code\":\"model_not_found\"}}"}}}' >"$structured"
	printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"statusCode":400,"responseBody":"{\"detail\":\"The '"'"'gpt-6-sol'"'"' model is not supported when using Codex with a ChatGPT account.\"}"}}}' >"$codex"
	printf '%s\n' "[provider_error] The 'gpt-6-sol' model is not supported when using Codex with a ChatGPT account." >"$plaintext"
	printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"statusCode":403,"responseBody":"{\"error\":{\"code\":\"model_not_found\"}}"}}}' >"$permission"
	local structured_reason codex_reason plaintext_reason permission_reason
	structured_reason=$(python3 "$classifier" "$structured" | cut -f1)
	codex_reason=$(python3 "$classifier" "$codex" | cut -f1)
	plaintext_reason=$(python3 "$classifier" "$plaintext" | cut -f1)
	permission_reason=$(python3 "$classifier" "$permission" | cut -f1)
	if [[ "$structured_reason" == "model_unavailable" && "$codex_reason" == "model_unavailable" &&
		"$plaintext_reason" == "model_unavailable" && "$permission_reason" == "access_denied" ]]; then
		print_result "Entitlement rejections classify as model_unavailable only" 0
		return 0
	fi
	print_result "Entitlement rejections classify as model_unavailable only" 1 \
		"structured=${structured_reason} codex=${codex_reason} plaintext=${plaintext_reason} permission=${permission_reason}"
	return 0
}

test_entitlement_backoff_is_model_scoped() {
	printf '{"openai":{"type":"oauth","access":"test-openai-access"}}\n' >"${HOME}/.local/share/opencode/auth.json"
	local status="" standard="" simple=""
	bash "$HELPER_SCRIPT" backoff set openai/gpt-6.1-sol model_unavailable 3600
	status=$(bash "$HELPER_SCRIPT" backoff status)
	# Sol is skipped for the next same-tier OpenAI candidate; Luna stays usable.
	standard=$(select_model standard)
	simple=$(select_model simple)
	bash "$HELPER_SCRIPT" backoff clear openai/gpt-6.1-sol >/dev/null 2>&1 || true
	if [[ "$status" == *"openai/gpt-6.1-sol|model_unavailable|"* && "$standard" == "openai/gpt-6.1-terra" && "$simple" == "openai/gpt-6-luna" ]]; then
		print_result "Entitlement rejection backs off only the rejected model" 0
		return 0
	fi
	print_result "Entitlement rejection backs off only the rejected model" 1 \
		"status=${status:-<empty>} standard=${standard:-<empty>} simple=${simple:-<empty>}"
	return 0
}

test_entitlement_backoff_clears_on_auth_change() {
	printf '{"openai":{"type":"oauth","access":"test-openai-access"}}\n' >"${HOME}/.local/share/opencode/auth.json"
	local before="" after=""
	bash "$HELPER_SCRIPT" backoff set openai/gpt-6.1-sol model_unavailable 3600
	before=$(select_model standard)
	# A re-login (new token) changes the auth signature and clears the record.
	printf '{"openai":{"type":"oauth","access":"test-openai-access-relogin"}}\n' >"${HOME}/.local/share/opencode/auth.json"
	# The signature uses whole-second mtime; force a distinct one so a rewrite in
	# the same second cannot leave the signature unchanged (flaky on fast runs).
	touch -d '2 minutes' "${HOME}/.local/share/opencode/auth.json" 2>/dev/null ||
		touch -t "$(date -v+2M +%Y%m%d%H%M.%S 2>/dev/null)" "${HOME}/.local/share/opencode/auth.json" 2>/dev/null || true
	after=$(select_model standard)
	if [[ "$before" == "openai/gpt-6.1-terra" && "$after" == "openai/gpt-6.1-sol" ]]; then
		print_result "Model backoff clears when the OpenAI auth changes" 0
		return 0
	fi
	print_result "Model backoff clears when the OpenAI auth changes" 1 "before=${before:-<empty>} after=${after:-<empty>}"
	return 0
}

main_test() {
	setup_test_env
	test_openai_allowlist_selects_standard_tier_model
	test_openai_allowlist_selects_simple_tier_model
	test_openai_allowlist_selects_thinking_tier_model
	test_openai_allowlist_requires_openai_auth_entry
	test_standard_alternatives_are_scoped
	test_entitlement_rejections_classify_as_model_unavailable
	test_entitlement_backoff_is_model_scoped
	test_entitlement_backoff_clears_on_auth_change
	teardown_test_env

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
