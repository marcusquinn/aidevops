#!/usr/bin/env bash
# ai-research-helper.sh - Lightweight Anthropic API wrapper for AI judgment calls
# Provides haiku-tier (~$0.001/call) AI judgment for replacing hardcoded thresholds.
#
# Part of the conversational memory system (p035 / t1363.6).
# Used by conversation-helper.sh (idle detection), memory-helper.sh (prune relevance),
# matrix-dispatch-helper.sh (response sizing), and ai-judgment-helper.sh (threshold decisions).
#
# Usage:
#   ai-research-helper.sh --prompt "Is this conversation idle?" [--model haiku] [--max-tokens 50]
#   ai-research-helper.sh --prompt "Is this memory relevant?" --model haiku --max-tokens 10
#
# Options:
#   --prompt TEXT       The prompt to send (required)
#   --model MODEL       Model tier: haiku (default), sonnet, opus
#   --max-tokens N      Maximum response tokens (default: 100)
#   --system TEXT        System prompt (optional)
#   --json              Request JSON output format
#   --quiet             Suppress stderr logging
#
# Environment:
#   ANTHROPIC_API_KEY   API key (or loaded from gopass/credentials.sh)
#
# Cost guidance:
#   haiku:  ~$0.001 per call (judgment calls, yes/no decisions)
#   sonnet: ~$0.01 per call  (summaries, analysis)
#   opus:   ~$0.10 per call  (complex reasoning — avoid for thresholds)
#
# Exit codes:
#   0 - Success (response on stdout)
#   1 - Missing dependencies or configuration
#   2 - API error (rate limit, auth, etc.)
#   3 - Invalid arguments

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Source shared constants if available (for log_* functions)
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	# Minimal fallback logging
	log_info() { echo "[INFO] $*" >&2; }
	log_error() { echo "[ERROR] $*" >&2; }
	log_warn() { echo "[WARN] $*" >&2; }
fi

set -euo pipefail

# Model name mapping
declare -A MODEL_MAP=(
	[haiku]="claude-3-5-haiku-20241022"
	[sonnet]="claude-sonnet-4-20250514"
	[opus]="claude-opus-4-20250514"
)

#######################################
# Load Anthropic API key
# Priority: env var > gopass > credentials.sh
#######################################
load_api_key() {
	# Already set in environment
	if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
		return 0
	fi

	# Try gopass
	if command -v gopass >/dev/null 2>&1; then
		ANTHROPIC_API_KEY="$(gopass show -o "aidevops/anthropic-api-key" 2>/dev/null)" || true
		if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
			export ANTHROPIC_API_KEY
			return 0
		fi
	fi

	# Try credentials.sh
	local cred_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$cred_file" ]]; then
		# shellcheck source=/dev/null
		source "$cred_file"
		if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
			export ANTHROPIC_API_KEY
			return 0
		fi
	fi

	return 1
}

#######################################
# Make an Anthropic API call
# Arguments:
#   $1 - prompt text
#   $2 - model tier (haiku|sonnet|opus)
#   $3 - max tokens
#   $4 - system prompt (optional)
# Output: response text on stdout
#######################################
call_anthropic() {
	local prompt="$1"
	local model_tier="$2"
	local max_tokens="$3"
	local system_prompt="${4:-}"

	local model_id="${MODEL_MAP[$model_tier]:-${MODEL_MAP[haiku]}}"

	# Build the request JSON
	local request_body
	if [[ -n "$system_prompt" ]]; then
		request_body=$(jq -n \
			--arg model "$model_id" \
			--argjson max_tokens "$max_tokens" \
			--arg system "$system_prompt" \
			--arg prompt "$prompt" \
			'{
				model: $model,
				max_tokens: $max_tokens,
				system: $system,
				messages: [{ role: "user", content: $prompt }]
			}')
	else
		request_body=$(jq -n \
			--arg model "$model_id" \
			--argjson max_tokens "$max_tokens" \
			--arg prompt "$prompt" \
			'{
				model: $model,
				max_tokens: $max_tokens,
				messages: [{ role: "user", content: $prompt }]
			}')
	fi

	# Make the API call
	local response
	local http_code
	local temp_file
	temp_file=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$temp_file'" RETURN

	http_code=$(curl -s -w "%{http_code}" -o "$temp_file" \
		-X POST "https://api.anthropic.com/v1/messages" \
		-H "Content-Type: application/json" \
		-H "x-api-key: ${ANTHROPIC_API_KEY}" \
		-H "anthropic-version: 2023-06-01" \
		-d "$request_body" \
		--connect-timeout 10 \
		--max-time 30)

	response=$(cat "$temp_file")

	# Check HTTP status
	if [[ "$http_code" != "200" ]]; then
		local error_msg
		error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "HTTP $http_code")
		log_error "Anthropic API error ($http_code): $error_msg"
		return 2
	fi

	# Extract text from response
	local text
	text=$(echo "$response" | jq -r '.content[0].text // ""' 2>/dev/null || echo "")

	if [[ -z "$text" ]]; then
		log_error "Empty response from Anthropic API"
		return 2
	fi

	echo "$text"
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	local prompt=""
	local model="haiku"
	local max_tokens=100
	local system_prompt=""
	local quiet=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--prompt)
			prompt="$2"
			shift 2
			;;
		--model)
			model="$2"
			shift 2
			;;
		--max-tokens)
			max_tokens="$2"
			shift 2
			;;
		--system)
			system_prompt="$2"
			shift 2
			;;
		--json)
			# JSON output hint — append to system prompt
			if [[ -n "$system_prompt" ]]; then
				system_prompt="$system_prompt Respond in valid JSON."
			else
				system_prompt="Respond in valid JSON."
			fi
			shift
			;;
		--quiet)
			quiet=true
			shift
			;;
		*)
			log_error "Unknown argument: $1"
			return 3
			;;
		esac
	done

	if [[ -z "$prompt" ]]; then
		log_error "Usage: ai-research-helper.sh --prompt \"your prompt\" [--model haiku] [--max-tokens 100]"
		return 3
	fi

	# Validate model tier
	if [[ ! "${MODEL_MAP[$model]+_}" ]]; then
		log_error "Invalid model tier: $model. Valid: haiku, sonnet, opus"
		return 3
	fi

	# Check dependencies
	if ! command -v curl >/dev/null 2>&1; then
		log_error "curl is required but not installed"
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		log_error "jq is required but not installed"
		return 1
	fi

	# Load API key
	if ! load_api_key; then
		if [[ "$quiet" != true ]]; then
			log_error "ANTHROPIC_API_KEY not found. Set it via:"
			log_error "  export ANTHROPIC_API_KEY=sk-ant-..."
			log_error "  aidevops secret set anthropic-api-key"
			log_error "  Add to ~/.config/aidevops/credentials.sh"
		fi
		return 1
	fi

	# Make the call
	call_anthropic "$prompt" "$model" "$max_tokens" "$system_prompt"
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
