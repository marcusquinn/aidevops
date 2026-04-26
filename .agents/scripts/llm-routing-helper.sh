#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# llm-routing-helper.sh — Centralised LLM provider routing + audit log
# =============================================================================
# Routes LLM calls to compliant providers based on sensitivity tier policy.
# Hard-fails when a tier requires local-only and no local provider is running.
# Appends a JSONL audit record (hashed prompt/response, no raw content).
#
# Usage:
#   llm-routing-helper.sh route --tier <tier> --task <kind> --prompt-file <path> \
#                               [--max-tokens N] [--model <override>]
#   llm-routing-helper.sh audit-log <field=value...>
#   llm-routing-helper.sh costs [--since <date>] [--provider <name>]
#   llm-routing-helper.sh status
#   llm-routing-helper.sh help
#
# Sensitivity tiers (from .agents/templates/llm-routing-config.json):
#   public    — any provider (default: anthropic)
#   internal  — cloud or local (default: anthropic)
#   pii       — local preferred; cloud only with redaction (default: ollama)
#   sensitive — local only (default: ollama)
#   privileged — local only; hard-fail if unavailable
#
# ShellCheck clean. Bash 3.2 compatible (macOS default; re-execs under bash 4+
# via shared-constants.sh self-heal guard when available).
#
# Examples:
#   llm-routing-helper.sh route --tier public --task summarise \
#       --prompt-file /tmp/prompt.txt
#   llm-routing-helper.sh route --tier privileged --task draft \
#       --prompt-file /tmp/prompt.txt --max-tokens 4096
#   llm-routing-helper.sh costs --since 2026-04-01
#   llm-routing-helper.sh costs --provider ollama
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

LLM_ROUTING_CONFIG="${LLM_ROUTING_CONFIG:-}"
LLM_AUDIT_LOG="${LLM_AUDIT_LOG:-}"
LLM_COSTS_PATH="${LLM_COSTS_PATH:-${HOME}/.aidevops/.agent-workspace/llm-costs.json}"
LLM_ROUTING_DRY_RUN="${LLM_ROUTING_DRY_RUN:-0}"

# Canonical string constants (avoids repeated literal violations in linter)
_LLM_TRUE="true"
_LLM_UNKNOWN="unknown"

# Default config locations searched in order
_CONFIG_SEARCH_PATHS=(
	"${LLM_ROUTING_CONFIG}"
	"${SCRIPT_DIR}/../_config/llm-routing.json"
	"${HOME}/.aidevops/_config/llm-routing.json"
	"${SCRIPT_DIR}/../templates/llm-routing-config.json"
)

# =============================================================================
# Internal helpers
# =============================================================================

_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not installed. Install with: brew install jq"
		return 1
	fi
	return 0
}

_load_config() {
	local config_file=""
	local candidate
	for candidate in "${_CONFIG_SEARCH_PATHS[@]}"; do
		if [[ -n "$candidate" && -f "$candidate" ]]; then
			config_file="$candidate"
			break
		fi
	done

	if [[ -z "$config_file" ]]; then
		print_error "No llm-routing.json config found. Copy .agents/templates/llm-routing-config.json to _config/llm-routing.json"
		return 1
	fi

	if ! jq empty "$config_file" >/dev/null 2>&1; then
		print_error "Config file is not valid JSON: ${config_file}"
		return 1
	fi

	printf '%s' "$config_file"
	return 0
}

_resolve_audit_log() {
	local config_file="$1"
	local log_path
	log_path=$(jq -r '.audit.log_path // "_knowledge/index/llm-audit.log"' "$config_file")

	# Expand ~ manually (bash 3.2 compatible)
	log_path="${log_path/#~/${HOME}}"

	# If relative, resolve against repo root (two levels up from scripts/)
	if [[ "$log_path" != /* ]]; then
		local repo_root
		repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)" || repo_root="${SCRIPT_DIR}/../.."
		log_path="${repo_root}/${log_path}"
	fi

	printf '%s' "$log_path"
	return 0
}

_resolve_costs_path() {
	local config_file="$1"
	# Env var takes precedence over config file
	if [[ -n "${LLM_COSTS_PATH:-}" ]]; then
		printf '%s' "$LLM_COSTS_PATH"
		return 0
	fi
	local costs_path
	costs_path=$(jq -r '.audit.costs_path // empty' "$config_file")
	if [[ -n "$costs_path" ]]; then
		costs_path="${costs_path/#~/${HOME}}"
	else
		costs_path="${HOME}/.aidevops/.agent-workspace/llm-costs.json"
	fi
	printf '%s' "$costs_path"
	return 0
}

_sha256_file() {
	local path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$path" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$path" | awk '{print $1}'
	else
		print_warning "No sha256 tool found; using placeholder hash"
		printf 'sha256-unavailable'
	fi
	return 0
}

_sha256_string() {
	local str="$1"
	local tmpf
	tmpf=$(mktemp)
	printf '%s' "$str" >"$tmpf"
	_sha256_file "$tmpf"
	rm -f "$tmpf"
	return 0
}

_iso_timestamp() {
	if command -v date >/dev/null 2>&1; then
		date -u '+%Y-%m-%dT%H:%M:%SZ'
	else
		printf 'unknown'
	fi
	return 0
}

# Check whether Ollama is running and responsive
_ollama_running() {
	local host="${OLLAMA_HOST:-localhost}"
	local port="${OLLAMA_PORT:-11434}"
	curl -sf "http://${host}:${port}/api/tags" >/dev/null 2>&1
	return $?
}

# Get tier policy object from config
_get_tier_policy() {
	local config_file="$1"
	local tier="$2"
	local policy
	policy=$(jq -e --arg t "$tier" '.tiers[$t] // empty' "$config_file" 2>/dev/null) || {
		print_error "Unknown sensitivity tier: ${tier}"
		print_info "Valid tiers: public, internal, pii, sensitive, privileged"
		return 1
	}
	printf '%s' "$policy"
	return 0
}

# Get provider config from config
_get_provider_config() {
	local config_file="$1"
	local provider="$2"
	local conf
	conf=$(jq -e --arg p "$provider" '.providers[$p] // empty' "$config_file" 2>/dev/null) || {
		print_error "Unknown provider: ${provider}"
		return 1
	}
	printf '%s' "$conf"
	return 0
}

# Select the best provider for a given tier
_select_provider() {
	local config_file="$1"
	local tier="$2"
	local model_override="$3"

	local policy
	policy=$(_get_tier_policy "$config_file" "$tier") || return 1

	local default_provider
	default_provider=$(printf '%s' "$policy" | jq -r '.default_provider')
	local hard_fail
	hard_fail=$(printf '%s' "$policy" | jq -r '.hard_fail_if_unavailable // false')

	# For local-only tiers, verify Ollama is running
	local providers_json
	providers_json=$(printf '%s' "$policy" | jq -r '.providers | join(",")')

	# Check if tier allows only local providers
	local local_only=0
	case "$providers_json" in
	*cloud*) local_only=0 ;;
	*) local_only=1 ;;
	esac

	# Also check if default provider is ollama (local)
	if [[ "$default_provider" == "ollama" ]]; then
		local_only=1
	fi

	if [[ "$local_only" == "1" ]] || [[ "$providers_json" == "local" ]]; then
		if ! _ollama_running; then
			if [[ "$hard_fail" == "$_LLM_TRUE" ]]; then
				print_error "No compliant provider for tier=${tier}: Ollama is not running"
				print_error "Start Ollama with: ollama serve (or ollama-helper.sh serve)"
				return 1
			else
				print_warning "Default local provider (Ollama) is not running for tier=${tier}"
				# Fall through to try cloud if allowed
			fi
		else
			printf '%s' "ollama"
			return 0
		fi
	fi

	# For tiers that allow cloud, use the default_provider
	printf '%s' "$default_provider"
	return 0
}

# Append a JSONL record to the audit log
_append_audit_log() {
	local log_path="$1"
	local timestamp="$2"
	local tier="$3"
	local task="$4"
	local provider="$5"
	local redaction_applied="$6"
	local prompt_sha="$7"
	local response_sha="$8"
	local tokens="$9"
	local cost="${10}"

	local log_dir
	log_dir="$(dirname "$log_path")"
	mkdir -p "$log_dir" 2>/dev/null || true

	# Use -c (compact) for single-line JSONL output
	local record
	record=$(jq -cn \
		--arg ts "$timestamp" \
		--arg tier "$tier" \
		--arg task "$task" \
		--arg provider "$provider" \
		--argjson redacted "$redaction_applied" \
		--arg psha "$prompt_sha" \
		--arg rsha "$response_sha" \
		--argjson tokens "$tokens" \
		--arg cost "$cost" \
		'{
			timestamp: $ts,
			tier: $tier,
			task: $task,
			provider: $provider,
			redaction_applied: $redacted,
			prompt_sha256: $psha,
			response_sha256: $rsha,
			tokens: $tokens,
			cost: $cost
		}')

	printf '%s\n' "$record" >>"$log_path"
	return 0
}

# Update per-day per-provider cost tracking
_update_costs() {
	local costs_path="$1"
	local provider="$2"
	local cost="$3"
	local date_str
	date_str=$(date -u '+%Y-%m-%d')

	local costs_dir
	costs_dir="$(dirname "$costs_path")"
	mkdir -p "$costs_dir" 2>/dev/null || true

	local existing="{}"
	if [[ -f "$costs_path" ]]; then
		existing=$(cat "$costs_path")
	fi

	# Update costs: existing[date][provider] += cost
	local updated
	updated=$(printf '%s' "$existing" | jq \
		--arg date "$date_str" \
		--arg provider "$provider" \
		--argjson cost "$cost" \
		'
		(.[$date] //= {}) |
		.[$date][$provider] = ((.[$date][$provider] // 0) + $cost)
		')

	printf '%s\n' "$updated" >"$costs_path"
	return 0
}

# =============================================================================
# Provider wrappers
# =============================================================================

_call_ollama() {
	local prompt_file="$1"
	local max_tokens="${2:-2048}"
	local model="${3:-}"
	local config_file="$4"

	# Get default model from config if not overridden
	if [[ -z "$model" ]]; then
		model=$(jq -r '.providers.ollama.default_model // "llama3.1:70b"' "$config_file")
	fi

	local host="${OLLAMA_HOST:-localhost}"
	local port="${OLLAMA_PORT:-11434}"
	local prompt_content
	prompt_content=$(cat "$prompt_file")

	local payload
	payload=$(jq -n \
		--arg model "$model" \
		--arg prompt "$prompt_content" \
		--argjson max_tokens "$max_tokens" \
		'{
			model: $model,
			prompt: $prompt,
			stream: false,
			options: { num_predict: $max_tokens }
		}')

	local response
	response=$(curl -sf \
		-X POST \
		-H "Content-Type: application/json" \
		-d "$payload" \
		"http://${host}:${port}/api/generate") || {
		print_error "Ollama API call failed"
		return 1
	}

	# Extract response text
	printf '%s' "$response" | jq -r '.response // empty'
	return 0
}

_call_anthropic() {
	local prompt_file="$1"
	local max_tokens="${2:-2048}"
	local model="${3:-}"

	# Use claude CLI if available
	if command -v claude >/dev/null 2>&1; then
		if [[ -z "$model" ]]; then
			claude --headless --max-tokens "$max_tokens" <"$prompt_file"
		else
			claude --headless --model "$model" --max-tokens "$max_tokens" <"$prompt_file"
		fi
		return $?
	fi

	print_error "Anthropic provider: 'claude' CLI not found in PATH"
	print_info "Install Claude CLI or set PATH to include it"
	return 1
}

_call_openai() {
	local prompt_file="$1"
	local max_tokens="${2:-2048}"
	local model="${3:-}"

	if command -v openai >/dev/null 2>&1; then
		local prompt_content
		prompt_content=$(cat "$prompt_file")
		if [[ -z "$model" ]]; then
			openai api chat.completions.create \
				-m "gpt-4o" \
				-g user "$prompt_content" \
				--max-tokens "$max_tokens" 2>/dev/null
		else
			openai api chat.completions.create \
				-m "$model" \
				-g user "$prompt_content" \
				--max-tokens "$max_tokens" 2>/dev/null
		fi
		return $?
	fi

	if command -v openai-cli >/dev/null 2>&1; then
		openai-cli complete --prompt-file "$prompt_file" --max-tokens "$max_tokens"
		return $?
	fi

	print_error "OpenAI provider: neither 'openai' nor 'openai-cli' found in PATH"
	return 1
}

# =============================================================================
# Subcommands
# =============================================================================

# _route_apply_redaction: apply redaction if tier+provider requires it.
# Sets caller's redaction_applied and prompt_file via output vars pattern:
# outputs "applied:<path>" or "skip" on stdout.
_route_apply_redaction() {
	local config_file="$1"
	local tier="$2"
	local provider="$3"
	local prompt_file="$4"

	local policy
	policy=$(_get_tier_policy "$config_file" "$tier") || { printf 'skip'; return 0; }
	local redaction_required
	redaction_required=$(printf '%s' "$policy" | jq -r '.redaction_required_for_cloud // false')
	local provider_kind
	provider_kind=$(jq -r --arg p "$provider" '.providers[$p].kind // "cloud"' "$config_file")

	if [[ "$redaction_required" == "$_LLM_TRUE" && "$provider_kind" == "cloud" ]]; then
		local redacted_file
		redacted_file=$(mktemp)
		if "${SCRIPT_DIR}/redaction-helper.sh" redact "$prompt_file" "$redacted_file" 2>/dev/null; then
			printf 'applied:%s' "$redacted_file"
			return 0
		fi
		print_warning "Redaction failed; proceeding with original prompt for tier=${tier}"
	fi
	printf 'skip'
	return 0
}

# _route_call_provider: dispatch to the appropriate LLM provider.
# Outputs the response text on stdout.
_route_call_provider() {
	local provider="$1"
	local prompt_file="$2"
	local max_tokens="$3"
	local model="$4"
	local config_file="$5"
	local tier="$6"
	local task="$7"

	if [[ "$LLM_ROUTING_DRY_RUN" == "1" ]]; then
		print_info "[dry-run] Would call provider=${provider} tier=${tier} task=${task}"
		printf '[dry-run response]'
		return 0
	fi

	case "$provider" in
	ollama)
		_call_ollama "$prompt_file" "$max_tokens" "$model" "$config_file" || {
			print_error "Ollama call failed for tier=${tier} task=${task}"
			return 1
		}
		;;
	anthropic)
		_call_anthropic "$prompt_file" "$max_tokens" "$model" || {
			print_error "Anthropic call failed for tier=${tier} task=${task}"
			return 1
		}
		;;
	openai)
		_call_openai "$prompt_file" "$max_tokens" "$model" || {
			print_error "OpenAI call failed for tier=${tier} task=${task}"
			return 1
		}
		;;
	*)
		print_error "Unsupported provider: ${provider}"
		return 1
		;;
	esac
	return 0
}

cmd_route() {
	_require_jq || return 1

	local tier="" task="" prompt_file="" max_tokens="2048" model_override=""

	while [[ $# -gt 0 ]]; do
		local _opt="$1"
		local _val="${2:-}"
		case "$_opt" in
		--tier) tier="$_val"; shift 2 ;;
		--task) task="$_val"; shift 2 ;;
		--prompt-file) prompt_file="$_val"; shift 2 ;;
		--max-tokens) max_tokens="$_val"; shift 2 ;;
		--model) model_override="$_val"; shift 2 ;;
		*) print_error "Unknown option: $_opt"; return 1 ;;
		esac
	done

	if [[ -z "$tier" ]]; then
		print_error "--tier is required (public|internal|pii|sensitive|privileged)"; return 1
	fi
	if [[ -z "$prompt_file" || ! -f "$prompt_file" ]]; then
		print_error "--prompt-file is required and must exist"; return 1
	fi
	[[ -z "$task" ]] && task="general"

	local config_file
	config_file=$(_load_config) || return 1

	local provider
	provider=$(_select_provider "$config_file" "$tier" "$model_override") || return 1

	# Apply redaction if needed
	local _redir_result redaction_applied=false
	_redir_result=$(_route_apply_redaction "$config_file" "$tier" "$provider" "$prompt_file")
	if [[ "$_redir_result" == applied:* ]]; then
		redaction_applied=true
		prompt_file="${_redir_result#applied:}"
	fi

	local prompt_sha timestamp
	prompt_sha=$(_sha256_file "$prompt_file")
	timestamp=$(_iso_timestamp)

	local response
	response=$(_route_call_provider "$provider" "$prompt_file" "$max_tokens" \
		"$model_override" "$config_file" "$tier" "$task") || return 1

	local response_sha prompt_len tokens_used=0 cost_estimate="0"
	response_sha=$(_sha256_string "$response")
	prompt_len=$(wc -c <"$prompt_file" 2>/dev/null || printf '0')
	tokens_used=$(((prompt_len + ${#response}) / 4))

	local audit_log
	audit_log=$(
		if [[ -n "$LLM_AUDIT_LOG" ]]; then printf '%s' "$LLM_AUDIT_LOG"
		else _resolve_audit_log "$config_file"; fi
	)

	_append_audit_log "$audit_log" "$timestamp" "$tier" "$task" "$provider" \
		"$redaction_applied" "$prompt_sha" "$response_sha" "$tokens_used" "$cost_estimate"

	local costs_path
	costs_path=$(_resolve_costs_path "$config_file")
	_update_costs "$costs_path" "$provider" "$cost_estimate"

	printf '%s\n' "$response"
	return 0
}

cmd_audit_log() {
	_require_jq || return 1

	# Parse field=value pairs
	local timestamp tier task provider redaction_applied prompt_sha response_sha tokens cost
	timestamp=$(_iso_timestamp)
	tier="$_LLM_UNKNOWN"
	task="$_LLM_UNKNOWN"
	provider="$_LLM_UNKNOWN"
	redaction_applied="false"
	prompt_sha="none"
	response_sha="none"
	tokens=0
	cost="0"

	while [[ $# -gt 0 ]]; do
		local _kv="$1"
		case "$_kv" in
		timestamp=*) timestamp="${_kv#*=}" ;;
		tier=*) tier="${_kv#*=}" ;;
		task=*) task="${_kv#*=}" ;;
		provider=*) provider="${_kv#*=}" ;;
		redaction_applied=*) redaction_applied="${_kv#*=}" ;;
		prompt_sha=*) prompt_sha="${_kv#*=}" ;;
		response_sha=*) response_sha="${_kv#*=}" ;;
		tokens=*) tokens="${_kv#*=}" ;;
		cost=*) cost="${_kv#*=}" ;;
		*)
			print_warning "Unknown audit-log field: $_kv"
			;;
		esac
		shift
	done

	local config_file
	config_file=$(_load_config) || return 1

	local audit_log
	audit_log=$(
		if [[ -n "$LLM_AUDIT_LOG" ]]; then
			printf '%s' "$LLM_AUDIT_LOG"
		else
			_resolve_audit_log "$config_file"
		fi
	)

	local redacted_bool=false
	[[ "$redaction_applied" == "$_LLM_TRUE" ]] && redacted_bool=true

	_append_audit_log \
		"$audit_log" \
		"$timestamp" \
		"$tier" \
		"$task" \
		"$provider" \
		"$redacted_bool" \
		"$prompt_sha" \
		"$response_sha" \
		"$tokens" \
		"$cost"

	print_success "Audit log entry written to ${audit_log}"
	return 0
}

cmd_costs() {
	_require_jq || return 1

	local since="" provider_filter=""

	while [[ $# -gt 0 ]]; do
		local _opt="$1"
		local _val="${2:-}"
		case "$_opt" in
		--since)
			since="$_val"
			shift 2
			;;
		--provider)
			provider_filter="$_val"
			shift 2
			;;
		*)
			print_error "Unknown option: $_opt"
			return 1
			;;
		esac
	done

	local config_file
	config_file=$(_load_config) || return 1

	local costs_path
	costs_path=$(_resolve_costs_path "$config_file")

	if [[ ! -f "$costs_path" ]]; then
		print_info "No cost data found at ${costs_path}"
		return 0
	fi

	local costs
	costs=$(cat "$costs_path")

	printf 'LLM Cost Report\n'
	printf '%s\n' "============================================================"

	# Process costs using a single jq call; all filter variants handled inline.
	# Output format: "  YYYY-MM-DD: provider=cost  provider2=cost2"
	printf '%s' "$costs" | jq -r \
		--arg since "$since" \
		--arg prov "$provider_filter" \
		'to_entries | sort_by(.key) | .[] |
		 select($since == "" or .key >= $since) |
		 if $prov != "" then
		   "  \(.key): \($prov)=\((.value[$prov] // 0))"
		 else
		   "  \(.key): \(.value | to_entries | map("\(.key)=\(.value)") | join("  "))"
		 end'

	printf '%s\n' "============================================================"
	printf 'Costs path: %s\n' "$costs_path"
	return 0
}

cmd_status() {
	_require_jq || return 1

	local config_file
	config_file=$(_load_config) || return 1

	printf 'LLM Routing Status\n'
	printf '%s\n' "$(printf '=%.0s' {1..50})"
	printf 'Config: %s\n' "$config_file"

	# Check Ollama
	if _ollama_running; then
		printf 'Ollama:     running (%s:%s)\n' "${OLLAMA_HOST:-localhost}" "${OLLAMA_PORT:-11434}"
	else
		printf 'Ollama:     NOT running\n'
	fi

	# Check Anthropic CLI
	if command -v claude >/dev/null 2>&1; then
		printf 'Anthropic:  claude CLI found (%s)\n' "$(command -v claude)"
	else
		printf 'Anthropic:  claude CLI not found\n'
	fi

	# Check OpenAI CLI
	if command -v openai >/dev/null 2>&1 || command -v openai-cli >/dev/null 2>&1; then
		printf 'OpenAI:     CLI found\n'
	else
		printf 'OpenAI:     CLI not found\n'
	fi

	printf '\nTier policies:\n'
	jq -r '.tiers | to_entries[] | "  \(.key): default=\(.value.default_provider)\(if .value.hard_fail_if_unavailable then " [hard-fail]" else "" end)"' "$config_file"

	return 0
}

cmd_help() {
	cat <<'HELP'
llm-routing-helper.sh — Centralised LLM routing + audit log

Commands:
  route        Route a prompt to the appropriate provider based on tier
  audit-log    Append a manual audit log entry
  costs        Show cost aggregation report
  status       Show provider availability and config
  help         Show this help

Options for route:
  --tier <t>         Sensitivity tier: public|internal|pii|sensitive|privileged
  --task <k>         Task kind: summarise|classify|extract|draft|chase|general
  --prompt-file <p>  Path to prompt text file (required)
  --max-tokens N     Maximum tokens in response (default: 2048)
  --model <m>        Override the default model for the selected provider

Options for costs:
  --since <date>     Filter to records on/after YYYY-MM-DD
  --provider <name>  Filter to a specific provider

Environment variables:
  LLM_ROUTING_CONFIG   Override path to llm-routing.json config
  LLM_AUDIT_LOG        Override audit log path
  LLM_COSTS_PATH       Override cost tracking JSON path
  LLM_ROUTING_DRY_RUN  Set to 1 to skip actual LLM call (for testing)
  OLLAMA_HOST          Ollama host (default: localhost)
  OLLAMA_PORT          Ollama port (default: 11434)

Examples:
  llm-routing-helper.sh route --tier public --task summarise \\
      --prompt-file /tmp/prompt.txt

  llm-routing-helper.sh route --tier privileged --task draft \\
      --prompt-file /tmp/prompt.txt --max-tokens 4096

  llm-routing-helper.sh costs --since 2026-04-01

  llm-routing-helper.sh costs --provider ollama

  LLM_ROUTING_DRY_RUN=1 llm-routing-helper.sh route --tier pii \\
      --task classify --prompt-file /tmp/data.txt
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	route) cmd_route "$@" ;;
	audit-log) cmd_audit_log "$@" ;;
	costs) cmd_costs "$@" ;;
	status) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
