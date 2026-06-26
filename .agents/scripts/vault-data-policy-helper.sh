#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# vault-data-policy-helper.sh — Vault prompt/provider routing gate

set -euo pipefail

VAULT_POLICY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${VAULT_POLICY_SCRIPT_DIR}/shared-constants.sh"

_vault_policy_is_local_model() {
	local model_spec="$1"
	local provider="${model_spec%%/*}"
	case "$provider" in
	local | ollama | llama | llama.cpp | llamacpp)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

_vault_policy_extract_metadata() {
	local context_text="$1"
	local key_name="$2"
	printf '%s\n' "$context_text" | awk -v key="$key_name" '
BEGIN { gsub(/[-_]/, "[-_]", key); pattern = "^[[:space:]>*-]*`?" key "`?[[:space:]]*:" }
{
  line = tolower($0)
  gsub(/`/, "", line)
  if (line ~ pattern) {
    sub(/^[^:]*:[[:space:]]*/, "", line)
    gsub(/[][(){}]/, " ", line)
    gsub(/[,;|]/, " ", line)
    gsub(/[[:space:]]+/, " ", line)
    sub(/^[[:space:]]+/, "", line)
    sub(/[[:space:]]+$/, "", line)
    print line
    exit
  }
}'
	return 0
}

_vault_policy_tokens_have() {
	local token_text="$1"
	local wanted_token="$2"
	case " ${token_text} " in
	*" ${wanted_token} "*) return 0 ;;
	*) return 1 ;;
	esac
}

_vault_policy_context_has_restricted_metadata() {
	local context_text="$1"
	case "$context_text" in
	*data_classification:* | *runtime_policy:* | *needs_vault:* | *needs_remote_unlock:* | *needs_device:* | *needs_collections:*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

vault_data_policy_check() {
	local selected_model="$1"
	local title_text="$2"
	local prompt_text="$3"
	local context_text="${title_text}
${prompt_text}"
	context_text=$(printf '%s' "$context_text" | tr '[:upper:]' '[:lower:]')

	if ! _vault_policy_context_has_restricted_metadata "$context_text"; then
		return 0
	fi

	local data_classification=""
	local runtime_policy=""
	data_classification=$(_vault_policy_extract_metadata "$context_text" "data_classification")
	runtime_policy=$(_vault_policy_extract_metadata "$context_text" "runtime_policy")

	local is_local_model=1
	if _vault_policy_is_local_model "$selected_model"; then
		is_local_model=0
	fi

	if _vault_policy_tokens_have "$data_classification" "secret"; then
		print_error "VAULT_POLICY_DENIED: data_classification=secret must not enter AI prompts; use secret tooling outside model context"
		return 64
	fi

	if _vault_policy_tokens_have "$data_classification" "local-only" \
		|| _vault_policy_tokens_have "$data_classification" "local-llm-only" \
		|| _vault_policy_tokens_have "$runtime_policy" "local-only" \
		|| _vault_policy_tokens_have "$runtime_policy" "local-llm-only" \
		|| _vault_policy_tokens_have "$runtime_policy" "local-ai"; then
		if [[ "$is_local_model" -ne 0 ]]; then
			print_error "VAULT_POLICY_DENIED: task metadata requires local AI but selected model is ${selected_model}"
			return 64
		fi
		return 0
	fi

	if [[ "$is_local_model" -eq 0 ]]; then
		return 0
	fi

	local provider_approved=1
	if _vault_policy_tokens_have "$data_classification" "provider-allowed" \
		|| _vault_policy_tokens_have "$runtime_policy" "provider-allowed" \
		|| _vault_policy_tokens_have "$runtime_policy" "provider-ai-approved" \
		|| [[ "${AIDEVOPS_VAULT_PROVIDER_AI_APPROVED:-0}" == "1" ]]; then
		provider_approved=0
	fi

	if _vault_policy_tokens_have "$data_classification" "confidential" \
		|| _vault_policy_tokens_have "$data_classification" "client-confidential"; then
		if [[ "$provider_approved" -ne 0 ]]; then
			print_error "VAULT_POLICY_DENIED: ${data_classification:-confidential} tasks require provider-allowed metadata or AIDEVOPS_VAULT_PROVIDER_AI_APPROVED=1 before remote provider dispatch"
			return 64
		fi
	fi

	return 0
}

cmd_check() {
	local selected_model=""
	local title_text=""
	local prompt_text=""
	local prompt_file=""
	while [[ $# -gt 0 ]]; do
		local current_arg="$1"
		local current_value="${2:-}"
		case "$current_arg" in
		--model)
			selected_model="$current_value"
			shift 2
			;;
		--title)
			title_text="$current_value"
			shift 2
			;;
		--prompt)
			prompt_text="$current_value"
			shift 2
			;;
		--prompt-file)
			prompt_file="$current_value"
			shift 2
			;;
		*)
			print_error "Unknown option for check: $current_arg"
			return 2
			;;
		esac
	done
	if [[ -n "$prompt_file" ]]; then
		[[ -f "$prompt_file" ]] || {
			print_error "Prompt file not found: $prompt_file"
			return 2
		}
		prompt_text=$(<"$prompt_file")
	fi
	[[ -n "$selected_model" ]] || {
		print_error "check requires --model"
		return 2
	}
	vault_data_policy_check "$selected_model" "$title_text" "$prompt_text"
	return $?
}

cmd_help() {
	cat <<'USAGE'
Usage: vault-data-policy-helper.sh check --model provider/model --title TEXT --prompt TEXT

Checks task metadata before provider dispatch. Supported metadata keys include
data_classification, runtime_policy, needs_vault, needs_collections,
needs_device, and needs_remote_unlock.
USAGE
	return 0
}

main() {
	local first_arg="${1:-help}"
	local command="$first_arg"
	shift || true
	case "$command" in
	check) cmd_check "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown Vault data policy command: $command"
		return 2
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
