#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# vault-data-policy-helper.sh — Vault prompt/provider routing gate

set -euo pipefail

VAULT_POLICY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${VAULT_POLICY_SCRIPT_DIR}/shared-constants.sh"

# Shared with plugins/opencode-aidevops/local-only-policy.mjs (GH#34125).
# Not overridable from the environment: the list defines what "local" means.
VAULT_POLICY_LOCAL_PROVIDERS_FILE="${VAULT_POLICY_SCRIPT_DIR}/../configs/local-ai-providers.conf"
# Same pattern as LOCAL_PROVIDER_ID_PATTERN in local-only-policy.mjs.
VAULT_POLICY_LOCAL_PROVIDER_ID_RE='^[A-Za-z0-9._-]{1,64}$'

# Operator-owned replacement list (GH#35723), resolved like the plugin:
# ${XDG_CONFIG_HOME:-$HOME/.config}/aidevops/local-ai-providers.conf.
# It is a trusted operator file, not an environment override of the list.
_vault_policy_providers_override_file() {
	local config_home="${XDG_CONFIG_HOME:-}"
	if [[ -z "$config_home" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		config_home="${HOME}/.config"
	fi
	printf '%s/aidevops/local-ai-providers.conf' "$config_home"
	return 0
}

# Mirrors assertOperatorConfigStat in local-only-policy.mjs: regular file, not
# a symlink, mode exactly 600, current-user owned, at most 64 KiB.
_vault_policy_operator_file_trusted() {
	local config_file="$1"
	[[ ! -L "$config_file" && -f "$config_file" ]] || return 1
	local stat_fields=""
	# GNU first: BSD stat rejects -c without output, while GNU stat treats -f
	# as file-system mode and would print unrelated fields before failing.
	stat_fields=$(stat -c '%a %u %s' "$config_file" 2>/dev/null) \
		|| stat_fields=$(stat -f '%Lp %u %z' "$config_file" 2>/dev/null) \
		|| return 1
	local file_mode="" file_owner="" file_size=""
	read -r file_mode file_owner file_size <<<"$stat_fields"
	[[ "$file_mode" == "600" ]] || return 1
	[[ -n "$file_owner" && "$file_owner" == "$(id -u)" ]] || return 1
	[[ "$file_size" =~ ^[0-9]+$ ]] && [[ "$file_size" -le 65536 ]] || return 1
	return 0
}

# Prints the provider list path to use. Returns 1 when nothing is local: a
# present but untrusted override fails closed instead of using the shared list.
_vault_policy_local_providers_file() {
	local override_file=""
	if override_file=$(_vault_policy_providers_override_file); then
		local override_dir="${override_file%/*}"
		local config_home="${override_dir%/*}"
		if [[ -e "$override_file" || -L "$override_file" ]] \
			|| { [[ -d "$override_dir" ]] && [[ ! -x "$override_dir" ]]; } \
			|| { [[ -d "$config_home" ]] && [[ ! -x "$config_home" ]]; }; then
			_vault_policy_operator_file_trusted "$override_file" || return 1
			printf '%s' "$override_file"
			return 0
		fi
	fi
	printf '%s' "$VAULT_POLICY_LOCAL_PROVIDERS_FILE"
	return 0
}

_vault_policy_is_local_model() {
	local model_spec="$1"
	local provider="${model_spec%%/*}"
	[[ -n "$provider" ]] || return 1
	local providers_file=""
	providers_file=$(_vault_policy_local_providers_file) || return 1
	# Missing list: nothing is local, so local-only work fails closed.
	[[ -r "$providers_file" ]] || return 1
	local line=""
	local matched=1
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%%#*}"
		# Trim only the edges: internal whitespace is an invalid provider ID.
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -n "$line" ]] || continue
		# Any invalid entry invalidates the whole list: nothing is local.
		[[ "$line" =~ $VAULT_POLICY_LOCAL_PROVIDER_ID_RE ]] || return 1
		if [[ "$line" == "$provider" ]]; then
			matched=0
		fi
	done <"$providers_file"
	return "$matched"
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

# Operator launch binding (GH#34125), shared with the OpenCode plugin's
# local-only-policy.mjs: AIDEVOPS_RUNTIME_POLICY=local-only|local-llm-only|
# local-ai binds every model call in this process tree to a local provider.
# Unset/empty and the explicit provider-* opt-outs are unbound; any other
# value binds fail-closed.
_vault_runtime_policy_value() {
	printf '%s' "${AIDEVOPS_RUNTIME_POLICY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
	return 0
}

# Returns 0 when this process tree is bound to local AI.
vault_runtime_policy_bound() {
	case "$(_vault_runtime_policy_value)" in
	"" | provider-ai | provider-allowed | provider-ai-approved)
		return 1
		;;
	esac
	return 0
}

vault_runtime_policy_check() {
	local selected_model="$1"
	vault_runtime_policy_bound || return 0
	local bound_policy=""
	bound_policy=$(_vault_runtime_policy_value)
	if _vault_policy_is_local_model "$selected_model"; then
		return 0
	fi
	print_error "VAULT_POLICY_DENIED: AIDEVOPS_RUNTIME_POLICY=${bound_policy} binds this run to local AI; request to ${selected_model:-unknown model} was blocked before sending"
	return 64
}

vault_data_policy_check() {
	local selected_model="$1"
	local title_text="$2"
	local prompt_text="$3"
	local context_text="${title_text}
${prompt_text}"
	context_text=$(printf '%s' "$context_text" | tr '[:upper:]' '[:lower:]')

	vault_runtime_policy_check "$selected_model" || return 64

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
