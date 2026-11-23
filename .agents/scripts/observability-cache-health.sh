#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# `observability-helper.sh cache-health`: per-model prompt-cache hit rate over a
# window. Sourced by observability-helper.sh (GH#39959); needs OBS_DIR and the
# shared-constants print helpers/colours from the caller.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_OBSERVABILITY_CACHE_HEALTH_LIB_LOADED:-}" ]] && return 0
_OBSERVABILITY_CACHE_HEALTH_LIB_LOADED=1

readonly DEFAULT_CACHE_THRESHOLD=90
readonly DEFAULT_CACHE_WINDOW_HOURS=24
readonly _OBS_CACHE_DEGRADED="degraded"

cmd_cache_health() {
	local json_flag=0 threshold="$DEFAULT_CACHE_THRESHOLD" window_hours="$DEFAULT_CACHE_WINDOW_HOURS"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--json)
			json_flag=1
			shift
			;;
		--threshold)
			threshold="${2:-$DEFAULT_CACHE_THRESHOLD}"
			shift 2
			;;
		--window)
			window_hours="${2:-$DEFAULT_CACHE_WINDOW_HOURS}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local obs_db="${OBS_DIR}/llm-requests.db"
	[[ -f "$obs_db" ]] || {
		print_error "SQLite DB not found at $obs_db"
		return 1
	}
	command -v sqlite3 &>/dev/null || {
		print_error "sqlite3 required"
		return 1
	}

	# Single query: per-model cache stats over the window, only for providers
	# with Anthropic-style prompt caching (cache_read > 0 somewhere).
	local result
	result=$(sqlite3 -separator '|' "$obs_db" "
		SELECT
			model_id,
			COUNT(*) AS requests,
			SUM(tokens_cache_read) AS cache_read,
			SUM(tokens_cache_write) AS cache_write,
			SUM(tokens_input) AS uncached_input,
			ROUND(
				CAST(SUM(tokens_cache_read) AS REAL)
				/ NULLIF(SUM(tokens_cache_read) + SUM(tokens_input), 0) * 100, 1
			) AS cache_pct
		FROM llm_requests
		WHERE timestamp > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-${window_hours} hours')
		GROUP BY model_id
		HAVING SUM(tokens_cache_read) + SUM(tokens_cache_write) > 0
		ORDER BY requests DESC;
	" 2>/dev/null) || result=""

	[[ -z "$result" ]] && {
		if [[ "$json_flag" -eq 1 ]]; then
			echo '{"status":"ok","models":[],"message":"No cacheable requests in window"}'
		else
			print_info "No cacheable requests in the last ${window_hours}h"
		fi
		return 0
	}

	local overall_status="ok" degraded_models=""

	if [[ "$json_flag" -eq 1 ]]; then
		local json_arr="[" separator=""
		while IFS='|' read -r model reqs cr cw ui pct; do
			[[ -z "$model" ]] && continue
			local status="ok"
			if [[ -n "$pct" ]] && awk "BEGIN { exit !($pct < $threshold) }"; then
				status="$_OBS_CACHE_DEGRADED"
				overall_status="$_OBS_CACHE_DEGRADED"
			fi
			json_arr="${json_arr}${separator}"
			separator=","
			json_arr="${json_arr}{\"model\":\"${model}\",\"requests\":${reqs:-0},\"cache_read\":${cr:-0},\"cache_write\":${cw:-0},\"uncached_input\":${ui:-0},\"cache_pct\":${pct:-0},\"status\":\"${status}\"}"
		done <<<"$result"
		echo "{\"status\":\"${overall_status}\",\"threshold\":${threshold},\"window_hours\":${window_hours},\"models\":${json_arr}]}"
	else
		printf "\nPrompt Cache Health (%sh window, threshold %s%%)\n" "$window_hours" "$threshold"
		printf "  %-30s %8s %12s %12s %7s %s\n" "Model" "Requests" "Cache Read" "Uncached" "Hit %" "Status"
		while IFS='|' read -r model reqs cr cw ui pct; do
			[[ -z "$model" ]] && continue
			local status="${GREEN}ok${NC}"
			# Check cache hit rate against threshold
			[[ -z "$pct" ]] || ! awk "BEGIN { exit !($pct < $threshold) }" || {
				status="${YELLOW}DEGRADED${NC}"
				overall_status="$_OBS_CACHE_DEGRADED"
				degraded_models="${degraded_models}${model} (${pct}%), "
			}
			printf "  %-30s %8s %12s %12s %6s%% %b\n" "$model" "$reqs" "$cr" "$ui" "$pct" "$status"
		done <<<"$result"
		echo ""
		[[ "$overall_status" != "$_OBS_CACHE_DEGRADED" ]] && print_success "All models above ${threshold}% cache hit rate" ||
			print_warning "Cache degradation: ${degraded_models%, }"
	fi

	[[ "$overall_status" == "ok" ]] && return 0
	return 1
}
