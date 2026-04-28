#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Profile README Data Library — Formatting, Data Collection and Cost Helpers
# =============================================================================
# Functions for gathering and formatting raw data used to generate profile stats:
#   1. Format   — number/hours/cost/token formatting utilities
#   2. Gather   — screen time, AI session time, model usage from multiple sources
#   3. Tokens   — token totals from OpenCode DB, observability DB, and JSONL
#   4. Pricing  — model cost rates and savings calculations
#
# Usage: source "${SCRIPT_DIR}/profile-readme-data-lib.sh"
#        (Sourced automatically by profile-readme-helper.sh)
#
# Dependencies:
#   - shared-constants.sh (via orchestrator)
#   - SCRIPT_DIR — set by orchestrator; this file provides a fallback
#   - METRICS_FILE, OBS_DB_FILE, OPENCODE_DB_FILE, OPENCODE_ARCHIVE_DB_FILE
#     — global vars defined in profile-readme-helper.sh (orchestrator)
#   - sqlite3 (optional), jq, bc
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PROFILE_README_DATA_LIB_LOADED:-}" ]] && return 0
_PROFILE_README_DATA_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback — needed when sourced from test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Format — Number / Hours / Cost / Token Utilities
# =============================================================================

# --- Format number with commas (bash 3.2 compatible) ---
_format_number() {
	local num="$1"
	# Handle decimals: split on dot
	local integer_part decimal_part
	integer_part="${num%%.*}"
	if [[ "$num" == *"."* ]]; then
		decimal_part=".${num#*.}"
	else
		decimal_part=""
	fi

	# Add commas to integer part using printf + sed
	local formatted
	formatted=$(echo "$integer_part" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta')
	echo "${formatted}${decimal_part}"
	return 0
}

# --- Format hours with 1 decimal place ---
_format_hours() {
	local val="$1"
	printf "%.1f" "$val"
	return 0
}

# --- Format dollar amount with commas and 2 decimal places ---
_format_cost() {
	local val="$1"
	local rounded
	rounded=$(printf "%.2f" "$val")
	_format_number "$rounded"
	return 0
}

# --- Format token count (K/M suffix, with comma thousands separators) ---
_format_tokens() {
	local tokens="$1"
	if [[ "$tokens" -ge 1000000 ]]; then
		local m
		m=$(echo "scale=1; $tokens / 1000000" | bc)
		local formatted
		formatted=$(_format_number "$m")
		echo "${formatted}M"
	elif [[ "$tokens" -ge 1000 ]]; then
		local k
		k=$(echo "scale=0; $tokens / 1000" | bc)
		local formatted
		formatted=$(_format_number "$k")
		echo "${formatted}K"
	else
		echo "$tokens"
	fi
	return 0
}

# =============================================================================
# Pricing — Model Cost Rates and Savings Calculations
# =============================================================================

# --- Get model pricing rates (input|output|cache_read per M tokens) ---
# Mirrors shared-constants.sh get_model_pricing() hardcoded fallback.
# Returns: input_price|output_price|cache_read_price
_model_cost_rates() {
	local model="$1"
	local ms="${model#*/}"
	ms="${ms%%-202*}"
	case "$ms" in
	*opus-4* | *claude-opus*) echo "15.0|75.0|1.50" ;;
	*sonnet-4* | *claude-sonnet*) echo "3.0|15.0|0.30" ;;
	*haiku-4* | *haiku-3* | *claude-haiku*) echo "0.80|4.0|0.08" ;;
	*gpt-5.4*) echo "2.50|10.0|0.625" ;;
	*gpt-5.3-codex*) echo "2.50|10.0|0.625" ;;
	*gpt-5.2-codex* | *gpt-5.2*) echo "2.50|10.0|0.625" ;;
	*gpt-5.1-codex*) echo "2.50|10.0|0.625" ;;
	*gpt-5.1-chat*) echo "2.50|10.0|0.625" ;;
	*gpt-4.1-mini*) echo "0.40|1.60|0.10" ;;
	*gpt-4.1*) echo "2.0|8.0|0.50" ;;
	*o3*) echo "10.0|40.0|2.50" ;;
	*o4-mini*) echo "1.10|4.40|0.275" ;;
	*gemini-2.5-pro* | *gemini-3-pro*) echo "1.25|10.0|0.3125" ;;
	*gemini-2.5-flash* | *gemini-3-flash*) echo "0.15|0.60|0.0375" ;;
	*deepseek-r1*) echo "0.55|2.19|0.14" ;;
	*deepseek-v3*) echo "0.27|1.10|0.07" ;;
	*grok*) echo "3.0|15.0|0.30" ;;
	*kimi* | *minimax* | *big-pickle*) echo "0.0|0.0|0.0" ;;
	*) echo "3.0|15.0|0.30" ;;
	esac
	return 0
}

# --- Clean model name for display ---
_clean_model_name() {
	local model="$1"
	# Remove date suffixes like -20251101, -20250929
	local cleaned
	cleaned=$(echo "$model" | sed -E 's/-[0-9]{8}$//')
	echo "$cleaned"
	return 0
}

# --- Compute per-row cache and model-routing savings ---
# Usage: _compute_model_row_savings <model> <input_tokens> <output_tokens> <cache_tokens>
# Prints: cache_savings|model_savings  (scale=6 for accumulation accuracy)
_compute_model_row_savings() {
	local model="$1"
	local input="$2"
	local output="$3"
	local cache="$4"

	# Opus rates used as baseline for model routing savings
	local opus_input_rate="15.0" opus_output_rate="75.0" opus_cache_rate="1.50"

	local rates m_input_rate m_output_rate m_cache_rate
	rates=$(_model_cost_rates "$model")
	m_input_rate=$(echo "$rates" | cut -d'|' -f1)
	m_output_rate=$(echo "$rates" | cut -d'|' -f2)
	m_cache_rate=$(echo "$rates" | cut -d'|' -f3)

	local row_cache_savings row_model_savings
	row_cache_savings=$(echo "scale=6; $cache / 1000000 * ($m_input_rate - $m_cache_rate)" | bc)
	row_model_savings=$(echo "scale=6; ($opus_input_rate - $m_input_rate) * $input / 1000000 + ($opus_output_rate - $m_output_rate) * $output / 1000000 + ($opus_cache_rate - $m_cache_rate) * $cache / 1000000" | bc)

	echo "${row_cache_savings}|${row_model_savings}"
	return 0
}

# =============================================================================
# Gather — Screen Time, Session Time, Model Usage
# =============================================================================

# --- Gather screen time data ---
_get_screen_time() {
	local screen_json
	screen_json=$("${SCRIPT_DIR}/screen-time-helper.sh" profile-stats) || screen_json="{}"
	echo "$screen_json"
	return 0
}

# --- Gather AI session time for a period ---
_get_session_time() {
	local period="$1"
	local session_json
	# GH#17550: Use --all-dirs to aggregate sessions across all repos/directories.
	# The profile README is a user-level summary — not per-repo.
	# The DB is global; filtering by a single repo path missed 99%+ of sessions.
	session_json=$("${SCRIPT_DIR}/contributor-activity-helper.sh" session-time \
		--all-dirs --period "$period" --format json 2>/dev/null) || session_json="{}"
	echo "$session_json"
	return 0
}

# --- Compute cost from token counts using _model_cost_rates ---
# Takes JSON array with model/input_tokens/output_tokens/cache_read_tokens,
# adds cost_total field computed from pricing table, sorts by cost desc.
_compute_costs_from_tokens() {
	local raw_json="$1"
	local result="[]"

	while IFS= read -r row; do
		local model input output cache
		model=$(echo "$row" | jq -r '.model')
		input=$(echo "$row" | jq -r '.input_tokens')
		output=$(echo "$row" | jq -r '.output_tokens')
		cache=$(echo "$row" | jq -r '.cache_read_tokens')

		local rates m_input_rate m_output_rate m_cache_rate
		rates=$(_model_cost_rates "$model")
		m_input_rate=$(echo "$rates" | cut -d'|' -f1)
		m_output_rate=$(echo "$rates" | cut -d'|' -f2)
		m_cache_rate=$(echo "$rates" | cut -d'|' -f3)

		local cost
		cost=$(echo "scale=2; $m_input_rate * $input / 1000000 + $m_output_rate * $output / 1000000 + $m_cache_rate * $cache / 1000000" | bc)

		result=$(echo "$result" | jq --argjson row "$row" --argjson cost "$cost" \
			'. + [$row + {cost_total: $cost}]')
	done < <(echo "$raw_json" | jq -c '.[]')

	echo "$result" | jq -c 'sort_by(-.cost_total)'
	return 0
}

# --- Gather model usage from OpenCode session DB (full history) ---
# Returns JSON array with cost_total computed, or empty string if unavailable.
_get_model_usage_from_opencode() {
	if ! command -v sqlite3 &>/dev/null || [[ ! -f "$OPENCODE_DB_FILE" ]]; then
		echo ""
		return 0
	fi

	local raw_json
	# GH#17549: Query both active and archive DBs for all-time stats.
	# The archive DB contains sessions >14 days old, moved by opencode-db-archive.sh.
	local attach_clause=""
	local union_clause=""
	if [[ -f "$OPENCODE_ARCHIVE_DB_FILE" ]]; then
		attach_clause="ATTACH DATABASE '${OPENCODE_ARCHIVE_DB_FILE}' AS archive;"
		union_clause="UNION ALL
			SELECT
				json_extract(data, '\$.modelID') AS model,
				COUNT(*) AS requests,
				COALESCE(SUM(json_extract(data, '\$.tokens.input')), 0) AS input_tokens,
				COALESCE(SUM(json_extract(data, '\$.tokens.output')), 0) AS output_tokens,
				COALESCE(SUM(json_extract(data, '\$.tokens.cache.read')), 0) AS cache_read_tokens,
				COALESCE(SUM(json_extract(data, '\$.tokens.cache.write')), 0) AS cache_write_tokens
			FROM archive.message
			WHERE json_extract(data, '\$.role') = 'assistant'
			  AND json_extract(data, '\$.modelID') IS NOT NULL
			  AND json_extract(data, '\$.modelID') != ''
			GROUP BY model"
	fi
	raw_json=$(sqlite3 "$OPENCODE_DB_FILE" "
		${attach_clause}
		SELECT COALESCE(
			json_group_array(
				json_object(
					'model', model,
					'requests', requests,
					'input_tokens', input_tokens,
					'output_tokens', output_tokens,
					'cache_read_tokens', cache_read_tokens,
					'cache_write_tokens', cache_write_tokens
				)
			),
			'[]'
		)
		FROM (
			SELECT model, SUM(requests) AS requests,
				SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
				SUM(cache_read_tokens) AS cache_read_tokens, SUM(cache_write_tokens) AS cache_write_tokens
			FROM (
				SELECT
					json_extract(data, '\$.modelID') AS model,
					COUNT(*) AS requests,
					COALESCE(SUM(json_extract(data, '\$.tokens.input')), 0) AS input_tokens,
					COALESCE(SUM(json_extract(data, '\$.tokens.output')), 0) AS output_tokens,
					COALESCE(SUM(json_extract(data, '\$.tokens.cache.read')), 0) AS cache_read_tokens,
					COALESCE(SUM(json_extract(data, '\$.tokens.cache.write')), 0) AS cache_write_tokens
				FROM message
				WHERE json_extract(data, '\$.role') = 'assistant'
				  AND json_extract(data, '\$.modelID') IS NOT NULL
				  AND json_extract(data, '\$.modelID') != ''
				GROUP BY model
				${union_clause}
			)
			GROUP BY model
		);
	" 2>/dev/null || true)

	if [[ -z "$raw_json" ]] || [[ "$raw_json" == "[]" ]]; then
		echo ""
		return 0
	fi

	# Merge model variants (e.g., claude-opus-4-5-20251101 -> claude-opus-4-5)
	local merged_json
	merged_json=$(echo "$raw_json" | jq -c '
		[.[] | .model = (.model | gsub("-[0-9]{8}$"; ""))]
		| group_by(.model)
		| map({
			model: .[0].model,
			requests: ([.[].requests] | add),
			input_tokens: ([.[].input_tokens] | add),
			output_tokens: ([.[].output_tokens] | add),
			cache_read_tokens: ([.[].cache_read_tokens] | add),
			cache_write_tokens: ([.[].cache_write_tokens] | add)
		})
	')
	_compute_costs_from_tokens "$merged_json"
	return 0
}

# --- Gather model usage from observability DB (accurate cost data) ---
# date_filter: optional SQL WHERE clause fragment (e.g. "AND timestamp >= ...")
# Returns JSON array or empty string if unavailable.
_get_model_usage_from_obs_db() {
	local date_filter="${1:-}"

	if ! command -v sqlite3 &>/dev/null || [[ ! -f "$OBS_DB_FILE" ]]; then
		echo ""
		return 0
	fi

	local sqlite_json
	sqlite_json=$(sqlite3 "$OBS_DB_FILE" "
		SELECT COALESCE(
			json_group_array(
				json_object(
					'model', model_id,
					'requests', requests,
					'input_tokens', input_tokens,
					'output_tokens', output_tokens,
					'cache_read_tokens', cache_read_tokens,
					'cache_write_tokens', cache_write_tokens,
					'cost_total', ROUND(cost_total, 2)
				)
			),
			'[]'
		)
		FROM (
			SELECT
				model_id,
				COUNT(*) AS requests,
				COALESCE(SUM(tokens_input), 0) AS input_tokens,
				COALESCE(SUM(tokens_output), 0) AS output_tokens,
				COALESCE(SUM(tokens_cache_read), 0) AS cache_read_tokens,
				COALESCE(SUM(tokens_cache_write), 0) AS cache_write_tokens,
				COALESCE(SUM(cost), 0.0) AS cost_total
			FROM llm_requests
			WHERE model_id IS NOT NULL
			  AND model_id != ''
			  ${date_filter}
			GROUP BY model_id
			ORDER BY cost_total DESC
		);
	" 2>/dev/null || true)

	if [[ -n "$sqlite_json" ]]; then
		echo "$sqlite_json" | jq -c '.' 2>/dev/null || echo "[]"
	else
		echo ""
	fi
	return 0
}

# --- Gather model usage stats ---
# Usage: _get_model_usage [period]
#   period: "30d" (default) or "all" (no date filter)
_get_model_usage() {
	local period="${1:-30d}"

	# For "all" period, use OpenCode session DB (has full history back to first use).
	# The observability DB (llm-requests.db) only has data from when it was created.
	if [[ "$period" == "all" ]]; then
		local oc_result
		oc_result=$(_get_model_usage_from_opencode)
		if [[ -n "$oc_result" ]]; then
			echo "$oc_result"
			return 0
		fi
	fi

	# For 30d or fallback: use observability DB (has accurate cost data).
	local date_filter=""
	if [[ "$period" != "all" ]]; then
		date_filter="AND timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')"
	fi

	local obs_result
	obs_result=$(_get_model_usage_from_obs_db "$date_filter")
	if [[ -n "$obs_result" ]]; then
		echo "$obs_result"
		return 0
	fi

	# Legacy fallback: JSONL metrics file.
	if [[ ! -f "$METRICS_FILE" ]]; then
		echo "[]"
		return 0
	fi

	if [[ "$period" == "all" ]]; then
		jq -s '
			group_by(.model)
			| map({
				model: .[0].model,
				requests: length,
				input_tokens: ([.[].input_tokens // 0] | add),
				output_tokens: ([.[].output_tokens // 0] | add),
				cache_read_tokens: ([.[].cache_read_tokens // 0] | add),
				cache_write_tokens: ([.[].cache_write_tokens // 0] | add),
				cost_total: ([.[].cost_total // 0] | add | . * 100 | round / 100)
			})
			| sort_by(-.cost_total)
		' "$METRICS_FILE" 2>/dev/null || echo "[]"
	else
		local cutoff
		cutoff=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo "1970-01-01")

		jq -s --arg cutoff "$cutoff" '
			[.[] | select(.recorded_at >= $cutoff)]
			| group_by(.model)
			| map({
				model: .[0].model,
				requests: length,
				input_tokens: ([.[].input_tokens // 0] | add),
				output_tokens: ([.[].output_tokens // 0] | add),
				cache_read_tokens: ([.[].cache_read_tokens // 0] | add),
				cache_write_tokens: ([.[].cache_write_tokens // 0] | add),
				cost_total: ([.[].cost_total // 0] | add | . * 100 | round / 100)
			})
			| sort_by(-.cost_total)
		' "$METRICS_FILE" 2>/dev/null || echo "[]"
	fi

	return 0
}

# =============================================================================
# Tokens — Token Totals from Multiple Sources
# =============================================================================

# --- Token totals: shared jq expression for computing total_all and cache_hit_pct ---
_token_totals_jq_expr() {
	echo '. + {total_all: (.total_input + .total_output + .total_cache_read + .total_cache_write)}
		| . + {cache_hit_pct: (if .total_all > 0 then ((.total_cache_read / .total_all * 1000 | round) / 10) else 0 end)}'
	return 0
}

# --- Token totals: apply jq enrichment and emit JSON, with fallback ---
# Usage: _token_totals_enrich <raw_json>
_token_totals_enrich() {
	local raw_json="$1"
	local jq_totals
	jq_totals=$(_token_totals_jq_expr)

	if [[ -n "$raw_json" ]]; then
		echo "$raw_json" | jq -c "$jq_totals" 2>/dev/null || echo '{"total_all":0,"cache_hit_pct":0}'
	else
		echo '{"total_all":0,"cache_hit_pct":0}'
	fi
	return 0
}

# --- Token totals: query OpenCode session DB (all-time only) ---
# GH#17549: Query both active and archive DBs for complete totals.
# Returns: JSON string on stdout, or empty string if unavailable.
_token_totals_from_opencode_db() {
	if ! command -v sqlite3 &>/dev/null || [[ ! -f "$OPENCODE_DB_FILE" ]]; then
		return 1
	fi

	local _totals_attach="" _totals_union=""
	if [[ -f "$OPENCODE_ARCHIVE_DB_FILE" ]]; then
		_totals_attach="ATTACH DATABASE '${OPENCODE_ARCHIVE_DB_FILE}' AS archive;"
		_totals_union="UNION ALL
			SELECT json_extract(data, '\$.tokens.input'),
				json_extract(data, '\$.tokens.output'),
				json_extract(data, '\$.tokens.cache.read'),
				json_extract(data, '\$.tokens.cache.write')
			FROM archive.message
			WHERE json_extract(data, '\$.role') = 'assistant'"
	fi

	local oc_stats total_input total_output total_cache_read total_cache_write
	oc_stats=$(sqlite3 "$OPENCODE_DB_FILE" "
		${_totals_attach}
		SELECT
			COALESCE(SUM(tokens_input), 0) || '|' ||
			COALESCE(SUM(tokens_output), 0) || '|' ||
			COALESCE(SUM(cache_read), 0) || '|' ||
			COALESCE(SUM(cache_write), 0)
		FROM (
			SELECT json_extract(data, '\$.tokens.input') AS tokens_input,
				json_extract(data, '\$.tokens.output') AS tokens_output,
				json_extract(data, '\$.tokens.cache.read') AS cache_read,
				json_extract(data, '\$.tokens.cache.write') AS cache_write
			FROM message
			WHERE json_extract(data, '\$.role') = 'assistant'
			${_totals_union}
		);
	" 2>/dev/null || true)

	if [[ -n "$oc_stats" ]]; then
		local IFS='|'
		read -r total_input total_output total_cache_read total_cache_write <<<"$oc_stats"
		total_input="${total_input:-0}"
		total_output="${total_output:-0}"
		total_cache_read="${total_cache_read:-0}"
		total_cache_write="${total_cache_write:-0}"
		printf '{"total_input":%s,"total_output":%s,"total_cache_read":%s,"total_cache_write":%s}\n' \
			"$total_input" "$total_output" "$total_cache_read" "$total_cache_write"
		return 0
	fi
	return 1
}

# --- Token totals: query observability DB ---
# Usage: _token_totals_from_obs_db [period]
#   period: "30d" (default) or "all" (no date filter)
# Returns: JSON string on stdout, or empty string if unavailable.
_token_totals_from_obs_db() {
	local period="${1:-30d}"

	if ! command -v sqlite3 &>/dev/null || [[ ! -f "$OBS_DB_FILE" ]]; then
		return 1
	fi

	local date_filter=""
	if [[ "$period" != "all" ]]; then
		date_filter="WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')"
	fi

	local sqlite_totals
	sqlite_totals=$(sqlite3 "$OBS_DB_FILE" "
		SELECT json_object(
			'total_input', COALESCE(SUM(tokens_input), 0),
			'total_output', COALESCE(SUM(tokens_output), 0),
			'total_cache_read', COALESCE(SUM(tokens_cache_read), 0),
			'total_cache_write', COALESCE(SUM(tokens_cache_write), 0)
		)
		FROM llm_requests
		${date_filter};
	" 2>/dev/null || true)

	if [[ -n "$sqlite_totals" ]]; then
		echo "$sqlite_totals"
		return 0
	fi
	return 1
}

# --- Token totals: legacy JSONL metrics fallback ---
# Usage: _token_totals_from_jsonl [period]
#   period: "30d" (default) or "all" (no date filter)
# Returns: JSON string on stdout, or empty string if unavailable.
_token_totals_from_jsonl() {
	local period="${1:-30d}"

	if [[ ! -f "$METRICS_FILE" ]]; then
		return 1
	fi

	if [[ "$period" == "all" ]]; then
		jq -s '
			{
				total_input: ([.[].input_tokens // 0] | add),
				total_output: ([.[].output_tokens // 0] | add),
				total_cache_read: ([.[].cache_read_tokens // 0] | add),
				total_cache_write: ([.[].cache_write_tokens // 0] | add)
			}
		' "$METRICS_FILE" 2>/dev/null || { return 1; }
	else
		local cutoff
		cutoff=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo "1970-01-01")

		jq -s --arg cutoff "$cutoff" '
			[.[] | select(.recorded_at >= $cutoff)]
			| {
				total_input: ([.[].input_tokens // 0] | add),
				total_output: ([.[].output_tokens // 0] | add),
				total_cache_read: ([.[].cache_read_tokens // 0] | add),
				total_cache_write: ([.[].cache_write_tokens // 0] | add)
			}
		' "$METRICS_FILE" 2>/dev/null || { return 1; }
	fi
	return 0
}

# --- Get total token stats for footer ---
# Usage: _get_token_totals [period]
#   period: "30d" (default) or "all" (no date filter)
# Queries data sources in priority order: OpenCode DB → Observability DB → JSONL.
# Each source helper returns raw totals; enrichment (total_all, cache_hit_pct) is
# applied once by _token_totals_enrich.
_get_token_totals() {
	local period="${1:-30d}"
	local raw_totals=""

	# Source 1: OpenCode session DB (all-time only)
	if [[ "$period" == "all" ]]; then
		raw_totals=$(_token_totals_from_opencode_db) && {
			_token_totals_enrich "$raw_totals"
			return 0
		}
	fi

	# Source 2: Observability DB
	raw_totals=$(_token_totals_from_obs_db "$period") && {
		_token_totals_enrich "$raw_totals"
		return 0
	}

	# Source 3: Legacy JSONL metrics
	raw_totals=$(_token_totals_from_jsonl "$period") && {
		_token_totals_enrich "$raw_totals"
		return 0
	}

	# No data source available
	echo '{"total_all":0,"cache_hit_pct":0}'
	return 0
}
