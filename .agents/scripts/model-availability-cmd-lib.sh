#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Model Availability Commands Library -- CLI command implementations
# =============================================================================
# Command handler functions (cmd_check, cmd_probe, cmd_status, cmd_rate_limits,
# cmd_resolve, cmd_invalidate, cmd_resolve_chain, cmd_help) extracted from
# model-availability-helper.sh.
#
# Usage: source "${SCRIPT_DIR}/model-availability-cmd-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - model-availability-probe-lib.sh (probe_provider, check_model_available,
#     resolve_tier, resolve_tier_chain, _status_print_* helpers)
#   - model-availability-helper.sh constants and core functions
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MODEL_AVAILABILITY_CMD_LIB_LOADED:-}" ]] && return 0
_MODEL_AVAILABILITY_CMD_LIB_LOADED=1

# SCRIPT_DIR fallback -- needed when sourced from a non-standard location
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Commands
# =============================================================================

cmd_check() {
	local target="${1:-}"
	local force=false
	local quiet=false
	local json_flag=false
	local custom_ttl=""
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		--quiet)
			quiet=true
			shift
			;;
		--json)
			json_flag=true
			shift
			;;
		--ttl)
			custom_ttl="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$target" ]]; then
		print_error "Usage: model-availability-helper.sh check <provider|model>"
		return 1
	fi

	# Determine if target is a provider name, tier, or model spec
	if is_known_provider "$target"; then
		probe_provider "$target" "$force" "$custom_ttl" "$quiet"
		return $?
	elif is_known_tier "$target"; then
		resolve_tier "$target" "$force" "$quiet" >/dev/null
		return $?
	else
		# Assume it's a model spec (provider/model or model name)
		check_model_available "$target" "$force" "$quiet"
		return $?
	fi
}

cmd_probe() {
	local all=false
	local target=""
	local force=false
	local quiet=false
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--all)
			all=true
			shift
			;;
		--force)
			force=true
			shift
			;;
		--quiet)
			quiet=true
			shift
			;;
		--json)
			json_flag=true
			shift
			;;
		*)
			if [[ -z "$target" ]]; then
				target="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -n "$target" ]] && ! is_known_provider "$target"; then
		print_error "Unknown provider: $target"
		print_info "Available: $KNOWN_PROVIDERS"
		return 1
	fi

	local providers_to_probe=()
	if [[ -n "$target" ]]; then
		providers_to_probe=("$target")
	elif [[ "$all" == "true" ]]; then
		# Probe all known providers
		for p in $KNOWN_PROVIDERS; do
			providers_to_probe+=("$p")
		done
	else
		# Probe only providers with configured keys
		for p in $KNOWN_PROVIDERS; do
			if resolve_api_key "$p" >/dev/null 2>&1; then
				providers_to_probe+=("$p")
			fi
		done
	fi

	if [[ ${#providers_to_probe[@]} -eq 0 ]]; then
		print_warning "No providers to probe (no API keys configured)"
		return 1
	fi

	[[ "$quiet" != "true" ]] && echo ""
	[[ "$quiet" != "true" ]] && echo "Provider Availability Probe"
	[[ "$quiet" != "true" ]] && echo "==========================="
	[[ "$quiet" != "true" ]] && echo ""

	local healthy=0 unhealthy=0 no_key=0
	for provider in "${providers_to_probe[@]}"; do
		local exit_code=0
		probe_provider "$provider" "$force" "" "$quiet" || exit_code=$?
		case "$exit_code" in
		0) healthy=$((healthy + 1)) ;;
		3) no_key=$((no_key + 1)) ;;
		*) unhealthy=$((unhealthy + 1)) ;;
		esac
	done

	[[ "$quiet" != "true" ]] && echo ""
	[[ "$quiet" != "true" ]] && print_info "Summary: $healthy healthy, $unhealthy unhealthy, $no_key no key"

	if [[ "$json_flag" == "true" ]]; then
		db_query_json "SELECT provider, status, http_code, response_ms, models_count, checked_at FROM provider_health ORDER BY provider;"
	fi

	[[ "$unhealthy" -gt 0 ]] && return 1
	return 0
}

# Print the provider health table section of the status output.
_status_print_providers() {
	echo "Provider Health:"
	echo ""
	printf "  %-12s %-12s %-6s %-8s %-8s %-20s\n" \
		"Provider" "Status" "HTTP" "Time" "Models" "Last Check"
	printf "  %-12s %-12s %-6s %-8s %-8s %-20s\n" \
		"--------" "------" "----" "----" "------" "----------"

	db_query "
        SELECT provider, status, http_code, response_ms, models_count, checked_at
        FROM provider_health ORDER BY provider;
    " | while IFS='|' read -r prov stat code ms models checked; do
		local status_display="$stat"
		case "$stat" in
		healthy) status_display="${GREEN}healthy${NC}" ;;
		unhealthy | unreachable) status_display="${RED}$stat${NC}" ;;
		rate_limited) status_display="${YELLOW}rate-ltd${NC}" ;;
		key_invalid) status_display="${RED}bad-key${NC}" ;;
		no_key) status_display="${YELLOW}no-key${NC}" ;;
		esac

		local age_display="$checked"
		local checked_epoch now_epoch
		if [[ "$(uname)" == "Darwin" ]]; then
			checked_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$checked" "+%s" 2>/dev/null || echo "0")
		else
			checked_epoch=$(date -d "$checked" "+%s" 2>/dev/null || echo "0")
		fi
		now_epoch=$(date "+%s")
		local age=$((now_epoch - checked_epoch))
		if [[ "$age" -lt 60 ]]; then
			age_display="${age}s ago"
		elif [[ "$age" -lt 3600 ]]; then
			age_display="$((age / 60))m ago"
		else
			age_display="$((age / 3600))h ago"
		fi

		printf "  %-12s %-12b %-6s %-8s %-8s %-20s\n" \
			"$prov" "$status_display" "$code" "${ms}ms" "$models" "$age_display"
	done
	return 0
}

# Print the rate limits table section of the status output (only when data exists).
_status_print_rate_limits() {
	local rl_count
	rl_count=$(db_query "SELECT COUNT(*) FROM rate_limits WHERE requests_limit > 0;")
	if [[ "$rl_count" -eq 0 ]]; then
		return 0
	fi

	echo ""
	echo "Rate Limits:"
	echo ""
	printf "  %-12s %-15s %-15s %-15s\n" \
		"Provider" "Req Remaining" "Tok Remaining" "Reset"
	printf "  %-12s %-15s %-15s %-15s\n" \
		"--------" "-------------" "-------------" "-----"

	db_query "
        SELECT provider, requests_limit, requests_remaining, requests_reset,
               tokens_limit, tokens_remaining, tokens_reset
        FROM rate_limits WHERE requests_limit > 0 ORDER BY provider;
    " | while IFS='|' read -r prov rl rr rres tl tr tres; do
		local req_display="${rr}/${rl}"
		local tok_display="${tr}/${tl}"
		[[ "$tl" == "0" ]] && tok_display="n/a"
		printf "  %-12s %-15s %-15s %-15s\n" \
			"$prov" "$req_display" "$tok_display" "${rres:-n/a}"
	done
	return 0
}

# Print the tier resolution table section of the status output.
_status_print_tiers() {
	echo ""
	echo "Tier Resolution:"
	echo ""
	printf "  %-8s %-35s %-35s\n" "Tier" "Primary" "Fallback"
	printf "  %-8s %-35s %-35s\n" "----" "-------" "--------"
	for tier in haiku flash sonnet pro opus health eval coding; do
		local spec
		spec=$(get_tier_models "$tier" 2>/dev/null) || spec=""
		local primary="${spec%%|*}"
		local fallback="${spec#*|}"
		printf "  %-8s %-35s %-35s\n" "$tier" "$primary" "$fallback"
	done
	return 0
}

# Print the recent probe log section of the status output (only when entries exist).
_status_print_probe_log() {
	local log_count
	log_count=$(db_query "SELECT COUNT(*) FROM probe_log;")
	if [[ "$log_count" -eq 0 ]]; then
		return 0
	fi

	echo ""
	echo "Recent Probes (last 10):"
	echo ""
	db_query "
        SELECT timestamp, provider, action, result, duration_ms
        FROM probe_log ORDER BY timestamp DESC LIMIT 10;
    " | while IFS='|' read -r ts prov _action result ms; do
		echo "  $ts  $prov  $result  ${ms}ms"
	done
	echo ""
	return 0
}

cmd_status() {
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ ! -f "$AVAILABILITY_DB" ]]; then
		print_warning "No availability data. Run 'model-availability-helper.sh probe' first."
		return 0
	fi

	if [[ "$json_flag" == "true" ]]; then
		echo "{"
		echo "  \"providers\":"
		db_query_json "SELECT provider, status, http_code, response_ms, models_count, error_message, checked_at FROM provider_health ORDER BY provider;"
		echo ","
		echo "  \"rate_limits\":"
		db_query_json "SELECT provider, requests_limit, requests_remaining, requests_reset, tokens_limit, tokens_remaining, tokens_reset, checked_at FROM rate_limits ORDER BY provider;"
		echo "}"
		return 0
	fi

	echo ""
	echo "Model Availability Status"
	echo "========================="
	echo ""

	_status_print_providers
	_status_print_rate_limits
	_status_print_tiers
	echo ""
	_status_print_probe_log

	return 0
}

cmd_rate_limits() {
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ ! -f "$AVAILABILITY_DB" ]]; then
		print_warning "No rate limit data. Run 'model-availability-helper.sh probe' first."
		return 0
	fi

	if [[ "$json_flag" == "true" ]]; then
		db_query_json "SELECT * FROM rate_limits ORDER BY provider;"
		return 0
	fi

	echo ""
	echo "Rate Limit Status (from API response headers)"
	echo "============================================="
	echo ""

	local count
	count=$(db_query "SELECT COUNT(*) FROM rate_limits;")

	if [[ "$count" -eq 0 ]]; then
		print_info "No rate limit data cached. Probe providers to collect rate limit headers."
	else
		printf "  %-12s %-12s %-12s %-20s %-12s %-12s %-20s %-20s\n" \
			"Provider" "Req Limit" "Req Left" "Req Reset" "Tok Limit" "Tok Left" "Tok Reset" "Checked"
		printf "  %-12s %-12s %-12s %-20s %-12s %-12s %-20s %-20s\n" \
			"--------" "---------" "--------" "---------" "---------" "--------" "---------" "-------"

		db_query "SELECT * FROM rate_limits ORDER BY provider;" |
			while IFS='|' read -r prov rl rr rres tl tr tres checked _ttl; do
				printf "  %-12s %-12s %-12s %-20s %-12s %-12s %-20s %-20s\n" \
					"$prov" "$rl" "$rr" "${rres:-n/a}" "$tl" "$tr" "${tres:-n/a}" "$checked"
			done
	fi

	echo ""

	# Also show observability-derived utilisation (t1330)
	local obs_helper="${SCRIPT_DIR}/observability-helper.sh"
	if [[ -x "$obs_helper" ]]; then
		echo "Rate Limit Utilisation (from observability DB, t1330)"
		echo "====================================================="
		echo ""
		bash "$obs_helper" rate-limits || true
	fi

	return 0
}

cmd_resolve() {
	local tier="${1:-}"
	local force=false
	local quiet=false
	local json_flag=false
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		--quiet)
			quiet=true
			shift
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$tier" ]]; then
		print_error "Usage: model-availability-helper.sh resolve <tier>"
		print_info "Available tiers: haiku flash sonnet pro opus health eval coding"
		return 1
	fi

	local resolved
	resolved=$(resolve_tier "$tier" "$force" "$quiet")
	local exit_code=$?

	if [[ "$json_flag" == "true" ]]; then
		if [[ $exit_code -eq 0 ]]; then
			local provider model_id
			provider="${resolved%%/*}"
			model_id="${resolved#*/}"
			echo "{\"tier\":\"$tier\",\"provider\":\"$provider\",\"model\":\"$model_id\",\"full_id\":\"$resolved\",\"status\":\"available\"}"
		else
			echo "{\"tier\":\"$tier\",\"status\":\"unavailable\"}"
		fi
	else
		if [[ $exit_code -eq 0 ]]; then
			echo "$resolved"
		fi
	fi

	return "$exit_code"
}

cmd_invalidate() {
	local target="${1:-}"
	invalidate_cache "$target"
	return 0
}

# Resolve using the full fallback chain (t132.4).
# Delegates to fallback-chain-helper.sh for extended chain resolution
# including gateway providers and per-agent overrides.
cmd_resolve_chain() {
	local tier="${1:-}"
	local force=false
	local quiet=false
	local json_flag=false
	local agent_file=""
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		--quiet)
			quiet=true
			shift
			;;
		--json)
			json_flag=true
			shift
			;;
		--agent)
			agent_file="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$tier" ]]; then
		print_error "Usage: model-availability-helper.sh resolve-chain <tier> [--agent file]"
		print_info "Available tiers: haiku flash sonnet pro opus health eval coding"
		return 1
	fi

	local resolved
	resolved=$(resolve_tier_chain "$tier" "$force" "$quiet" "$agent_file")
	local exit_code=$?

	if [[ "$json_flag" == "true" ]]; then
		if [[ $exit_code -eq 0 ]]; then
			local provider model_id
			provider="${resolved%%/*}"
			model_id="${resolved#*/}"
			echo "{\"tier\":\"$tier\",\"provider\":\"$provider\",\"model\":\"$model_id\",\"full_id\":\"$resolved\",\"status\":\"available\",\"method\":\"chain\"}"
		else
			echo "{\"tier\":\"$tier\",\"status\":\"exhausted\",\"method\":\"chain\"}"
		fi
	else
		if [[ $exit_code -eq 0 ]]; then
			echo "$resolved"
		fi
	fi

	return "$exit_code"
}

cmd_help() {
	echo ""
	echo "Model Availability Helper - Probe before dispatch"
	echo "================================================="
	echo ""
	echo "Usage: model-availability-helper.sh [command] [options]"
	echo ""
	echo "Commands:"
	echo "  check <provider|model|tier>  Check availability (exit 0=yes, 1=no, 2=rate-limited, 3=bad-key)"
	echo "  probe [provider] [--all]     Probe providers (default: only those with keys)"
	echo "  status                       Show cached availability status"
	echo "  rate-limits                  Show rate limit data from cache"
	echo "  resolve <tier>               Resolve best available model for tier (primary + fallback)"
	echo "  resolve-chain <tier>         Resolve via full fallback chain (t132.4, includes gateways)"
	echo "  invalidate [provider]        Clear cache (all or specific provider)"
	echo "  help                         Show this help"
	echo ""
	echo "Options:"
	echo "  --json        Output in JSON format"
	echo "  --quiet       Suppress informational output"
	echo "  --force       Bypass cache and probe live"
	echo "  --ttl N       Override cache TTL in seconds"
	echo "  --agent FILE  Per-agent fallback chain override (resolve-chain only)"
	echo ""
	echo "Tiers:"
	echo "  haiku   - Cheapest (triage, classification)"
	echo "  flash   - Low cost (large context, summarization)"
	echo "  sonnet  - Medium (code implementation, review)"
	echo "  pro     - Medium-high (large codebase analysis)"
	echo "  opus    - Highest (architecture, complex reasoning)"
	echo "  health  - Cheapest probe model"
	echo "  eval    - Cheap evaluation model"
	echo "  coding  - Best SOTA coding model"
	echo ""
	echo "Providers:"
	echo "  anthropic, openai, google, openrouter, groq, deepseek"
	echo "  NOTE: opencode/* gateway models are NOT used for dispatch — they route"
	echo "  through per-token billing and are far more expensive than direct API keys."
	echo ""
	echo "Examples:"
	echo "  model-availability-helper.sh check anthropic"
	echo "  model-availability-helper.sh check anthropic/claude-sonnet-4-6"
	echo "  model-availability-helper.sh check sonnet"
	echo "  model-availability-helper.sh probe --all"
	echo "  model-availability-helper.sh resolve opus --json"
	echo "  model-availability-helper.sh resolve-chain coding --json"
	echo "  model-availability-helper.sh resolve-chain sonnet --agent models/sonnet.md"
	echo "  model-availability-helper.sh status"
	echo "  model-availability-helper.sh rate-limits --json"
	echo "  model-availability-helper.sh invalidate anthropic"
	echo ""
	echo "Integration with supervisor:"
	echo "  # In supervisor dispatch, replace check_model_health() with:"
	echo "  model-availability-helper.sh check anthropic --quiet"
	echo ""
	echo "  # Resolve model with fallback for a tier:"
	echo "  MODEL=\$(model-availability-helper.sh resolve coding --quiet)"
	echo ""
	echo "  # Resolve via full fallback chain (includes gateway providers):"
	echo "  MODEL=\$(model-availability-helper.sh resolve-chain coding --quiet)"
	echo ""
	echo "Exit codes:"
	echo "  0 - Available"
	echo "  1 - Unavailable or error"
	echo "  2 - Rate limited"
	echo "  3 - API key invalid or missing"
	echo ""
	echo "Cache: $AVAILABILITY_DB"
	echo "OpenCode models: $OPENCODE_MODELS_CACHE"
	echo "TTL: ${DEFAULT_HEALTH_TTL}s (health), ${DEFAULT_RATELIMIT_TTL}s (rate limits)"
	echo ""
	return 0
}

