#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# ai-research-helper.sh — Lightweight Anthropic API wrapper for AI judgments
# Provides cheap haiku-tier AI calls (~$0.001 each) for threshold decisions,
# classification, and short-form reasoning tasks.
#
# Part of the Intelligence Over Determinism principle: use AI judgment
# where fixed thresholds would fail on outliers.
#
# Usage:
#   ai-research-helper.sh --prompt "Is this conversation idle?" [--model haiku|sonnet] [--max-tokens 100]
#   echo "prompt text" | ai-research-helper.sh --stdin [--model haiku]
#
# Environment:
#   ANTHROPIC_API_KEY — set directly, or resolved from gopass/credentials.sh
#   OAuth pool — falls back to ~/.aidevops/oauth-pool.json when the three
#                static sources above miss. Uses the first active/idle
#                Anthropic account's access token as x-api-key (Anthropic
#                accepts the OAuth access token in both `x-api-key` and
#                `Authorization: Bearer` schemes on /v1/messages).
#
# Exit codes: 0=success (response on stdout), 1=error, 2=no API key

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

LOG_PREFIX="AI-RESEARCH"

#######################################
# Resolve model short name to full model ID
# Arguments: $1 — short name (haiku, sonnet, opus)
# Output: full model ID on stdout
#######################################
resolve_model_id() {
	local name="${1:-haiku}"
	case "$name" in
	haiku) echo "claude-haiku-4-5-20251001" ;;
	sonnet) echo "claude-sonnet-4-6" ;;
	opus) echo "claude-opus-4-6" ;;
	*) echo "claude-haiku-4-5-20251001" ;; # default to haiku
	esac
	return 0
}

#######################################
# Resolve a fresh, non-expired access token from the OAuth pool.
# Reads ~/.aidevops/oauth-pool.json directly (no shelling to oauth-pool-helper)
# so this stays callable from detached pulse contexts where the helper might
# be missing or not on PATH.
#
# Honoured fields per pool account:
#   .access          — access token string (used as x-api-key)
#   .status          — must be "active" or "idle"
#   .expires         — millisecond epoch; entries already past expiry are
#                      skipped (Anthropic returns 401 anyway and refresh
#                      requires the dedicated helper).
#   .cooldownUntil   — millisecond epoch; entries still cooling down are skipped.
#
# Output: access token on stdout when a usable entry exists.
# Returns: 0 if a token was emitted, 1 otherwise.
#######################################
resolve_oauth_pool_token() {
	local pool_file="${HOME}/.aidevops/oauth-pool.json"
	[[ -f "$pool_file" ]] || return 1
	command -v jq &>/dev/null || return 1

	local now_ms
	now_ms=$(date +%s%3N 2>/dev/null) || now_ms="0"
	# date +%s%3N is GNU-only; fall back to seconds-only when unavailable.
	[[ "$now_ms" =~ ^[0-9]+$ ]] || now_ms=0
	if [[ "${#now_ms}" -lt 10 ]]; then
		now_ms=$(($(date +%s) * 1000))
	fi

	local token
	token=$(jq -r --argjson now "$now_ms" '
		(.anthropic // [])
		| map(select(
			(.access // "") != ""
			and ((.status // "") == "active" or (.status // "") == "idle")
			and ((.expires // 0) > $now)
			and ((.cooldownUntil // 0) <= $now)
		))
		| .[0].access // ""
	' "$pool_file" 2>/dev/null) || return 1

	if [[ -z "$token" || "$token" == "null" ]]; then
		return 1
	fi
	printf '%s\n' "$token"
	return 0
}

#######################################
# Resolve Anthropic API key from available sources
# Priority: env var > gopass > credentials.sh > OAuth pool
# Output: API key on stdout
# Returns: 0 if found, 1 if not
#######################################
resolve_api_key() {
	# 1. Environment variable
	if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
		echo "$ANTHROPIC_API_KEY"
		return 0
	fi

	# 2. gopass
	if command -v gopass &>/dev/null; then
		local key
		key=$(gopass show -o "aidevops/anthropic-api-key" 2>/dev/null) || true
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	# 3. credentials.sh
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		local key
		key=$(grep -E '^ANTHROPIC_API_KEY=' "$creds_file" 2>/dev/null | cut -d= -f2- | tr -d '"'"'" || true)
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	# 4. OAuth pool (managed aidevops Anthropic accounts).
	# GH#23594: detached pulse contexts often have no static key but a
	# healthy OAuth pool — fall back to it so fix-the-fixer-detector and
	# other AI-judgement callers keep working.
	local oauth_token
	if oauth_token=$(resolve_oauth_pool_token); then
		printf '%s\n' "$oauth_token"
		return 0
	fi

	return 1
}

#######################################
# Call Anthropic Messages API
# Arguments:
#   $1 — prompt text
#   $2 — model short name (default: haiku)
#   $3 — max tokens (default: 150)
# Output: response text on stdout
# Returns: 0 on success, 1 on failure
#######################################
call_anthropic() {
	local prompt="$1"
	local model_name="${2:-haiku}"
	local max_tokens="${3:-150}"

	local api_key
	api_key=$(resolve_api_key) || {
		log_error "No Anthropic API key found (env, gopass, credentials.sh, or OAuth pool)"
		return 2
	}

	local model_id
	model_id=$(resolve_model_id "$model_name")

	# Escape prompt for JSON — use python3 if available, else basic escaping
	local escaped_prompt
	if command -v python3 &>/dev/null; then
		escaped_prompt=$(printf '%s' "$prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
	else
		# Basic JSON escaping
		escaped_prompt="\"$(printf '%s' "$prompt" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\t/\\t/g')\""
	fi

	local response
	response=$(curl -sS --max-time 30 \
		-H "x-api-key: ${api_key}" \
		-H "anthropic-version: 2023-06-01" \
		-H "${CONTENT_TYPE_JSON}" \
		-d "{
			\"model\": \"${model_id}\",
			\"max_tokens\": ${max_tokens},
			\"messages\": [{
				\"role\": \"user\",
				\"content\": ${escaped_prompt}
			}]
		}" \
		"https://api.anthropic.com/v1/messages" 2>/dev/null) || {
		log_error "API call failed"
		return 1
	}

	# Extract text from response
	local text
	if command -v jq &>/dev/null; then
		text=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)
	elif command -v python3 &>/dev/null; then
		text=$(echo "$response" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data["content"][0]["text"])' 2>/dev/null)
	else
		log_error "Neither jq nor python3 available for JSON parsing"
		return 1
	fi

	if [[ -z "$text" ]]; then
		# Check for error in response
		local error_msg
		error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null || echo "")
		if [[ -n "$error_msg" ]]; then
			log_error "API error: $error_msg"
		else
			log_error "Empty response from API"
		fi
		return 1
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
	local max_tokens="150"
	local use_stdin=false

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
		--stdin)
			use_stdin=true
			shift
			;;
		--help | -h)
			echo "Usage: ai-research-helper.sh --prompt \"text\" [--model haiku|sonnet|opus] [--max-tokens 150]"
			echo "       echo \"text\" | ai-research-helper.sh --stdin [--model haiku]"
			echo ""
			echo "Lightweight Anthropic API wrapper for AI threshold judgments."
			echo "Default model: haiku (~\$0.001/call). Use for classification and short reasoning."
			return 0
			;;
		*)
			shift
			;;
		esac
	done

	if [[ "$use_stdin" == true ]]; then
		prompt=$(cat)
	fi

	if [[ -z "$prompt" ]]; then
		log_error "No prompt provided. Use --prompt \"text\" or --stdin"
		return 1
	fi

	call_anthropic "$prompt" "$model" "$max_tokens"
	return $?
}

# Run main only when invoked as a script — allows tests and other helpers
# to source this file and call resolve_api_key / resolve_oauth_pool_token
# directly. Matches the pattern used by pulse-fix-the-fixer-detector.sh and
# other helpers in this repo.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	main "$@"
fi
