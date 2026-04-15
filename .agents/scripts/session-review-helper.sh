#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# session-review-helper.sh - Gather session context for AI review
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   session-review-helper.sh [command] [options]
#
# Commands:
#   gather    Collect session context (default)
#   summary   Quick summary only
#   json      Output as JSON for programmatic use
#   security  Post-session security summary (t1428.5)
#
# Options:
#   --focus <area>  Focus on: objectives, workflow, knowledge, all (default: all)
#   --security      Add security summary to gather output
#   --session <id>  Filter to specific session ID (for security command)
#   --json          Output security summary as JSON

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# =============================================================================
# Security Summary Data Sources (t1428.5)
# =============================================================================

readonly OBS_DIR="${HOME}/.aidevops/.agent-workspace/observability"
readonly OBS_METRICS="${OBS_DIR}/metrics.jsonl"
readonly OBS_DB="${OBS_DIR}/llm-requests.db"
readonly AUDIT_LOG="${OBS_DIR}/audit.jsonl"
readonly NET_ACCESS_LOG="${HOME}/.aidevops/.agent-workspace/network/access.jsonl"
readonly NET_FLAGGED_LOG="${HOME}/.aidevops/.agent-workspace/network/flagged.jsonl"
readonly NET_DENIED_LOG="${HOME}/.aidevops/.agent-workspace/network/denied.jsonl"
readonly PG_ATTEMPTS_LOG="${HOME}/.aidevops/logs/prompt-guard/attempts.jsonl"
readonly SESSION_CONTEXT_FILE="${HOME}/.aidevops/.agent-workspace/security/session-context.json"
readonly QUARANTINE_LOG="${HOME}/.aidevops/.agent-workspace/security/quarantine.jsonl"

# Shared format strings for summary tables
readonly FMT_COST_ROW="  %-35s %6s %10s %10s %10s %10s\n"
readonly FMT_COST_DATA="  %-35s %6s %10s %10s %10s \$%s\n"
readonly FMT_AUDIT_ROW="  %-25s %6s\n"
readonly FMT_SUMMARY_ROW="  %-20s %6s\n"

# Validate and normalize a session ID filter.
# Only allows alphanumeric characters, hyphens, underscores, and dots.
# Arguments:
#   $1 - raw session filter value
# Output: validated value on stdout
_sanitize_session_filter() {
	local raw="${1:-}"
	if [[ -z "$raw" ]]; then
		return 0
	fi

	if [[ "$raw" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
		echo "$raw"
		return 0
	fi

	return 1
}

# Run the observability cost query against SQLite with an optional bound session.
# Arguments:
#   $1 - output format: "text" or "json"
#   $2 - session ID filter (optional)
# Output: sqlite query result on stdout
_security_cost_query_sqlite() {
	local output_format="${1:-text}"
	local session_filter=""
	if ! session_filter=$(_sanitize_session_filter "${2:-}"); then
		return 1
	fi

	local session_param="null"
	if [[ -n "$session_filter" ]]; then
		session_param="'${session_filter}'"
	fi

	local -a sqlite_cmd=(sqlite3)
	if [[ "$output_format" == "json" ]]; then
		sqlite_cmd+=(-json)
	else
		sqlite_cmd+=(-separator '|')
	fi
	sqlite_cmd+=("$OBS_DB")

	"${sqlite_cmd[@]}" \
		".param init" \
		".param set @session_id ${session_param}" \
		"SELECT
			COALESCE(model_id, 'unknown') AS model,
			COUNT(*) AS requests,
			COALESCE(SUM(tokens_input), 0) AS input_tokens,
			COALESCE(SUM(tokens_output), 0) AS output_tokens,
			COALESCE(SUM(tokens_cache_read), 0) AS cache_tokens,
			COALESCE(SUM(cost), 0) AS cost
		FROM llm_requests
		WHERE (@session_id IS NULL OR session_id = @session_id)
		GROUP BY model_id
		ORDER BY cost DESC;"
	return 0
}

# Get cost summary from observability data.
# Aggregates by model, showing request count and total cost.
# Arguments:
#   $1 - session ID filter (optional, empty = all)
# Output: formatted cost table on stdout
_security_cost_summary() {
	local session_filter
	if ! session_filter=$(_sanitize_session_filter "${1:-}"); then
		echo "  Invalid session filter"
		return 1
	fi

	# Prefer SQLite DB (real-time via plugin)
	if [[ -f "$OBS_DB" ]] && command -v sqlite3 &>/dev/null; then
		local result
		result=$(_security_cost_query_sqlite "text" "$session_filter" 2>/dev/null || echo "")

		if [[ -n "$result" ]]; then
			printf "$FMT_COST_ROW" "Model" "Reqs" "Input" "Output" "Cache" "Cost"
			printf "$FMT_COST_ROW" "---" "---" "---" "---" "---" "---"
			# Collect costs/reqs for post-loop totalling (avoids awk-per-row)
			local all_costs="" all_reqs=""
			while IFS='|' read -r model reqs input_tok output_tok cache_tok cost; do
				[[ -z "$model" ]] && continue
				# Validate numeric fields to prevent injection via malformed DB data
				[[ "$reqs" =~ ^[0-9]+$ ]] || reqs=0
				[[ "$input_tok" =~ ^[0-9]+$ ]] || input_tok=0
				[[ "$output_tok" =~ ^[0-9]+$ ]] || output_tok=0
				[[ "$cache_tok" =~ ^[0-9]+$ ]] || cache_tok=0
				[[ "$cost" =~ ^[0-9.]+$ ]] || cost="0"
				local short_model="${model##*/}"
				short_model="${short_model:0:35}"
				printf "$FMT_COST_DATA" \
					"$short_model" "$reqs" "$input_tok" "$output_tok" "$cache_tok" "$cost"
				all_costs="${all_costs}${cost}\n"
				all_reqs="${all_reqs}${reqs}\n"
			done <<<"$result"
			# Calculate totals in a single awk call outside the loop
			local grand_total_cost grand_total_reqs
			grand_total_cost=$(printf '%b' "$all_costs" | awk '{s+=$1} END {printf "%.6f", s}')
			grand_total_reqs=$(printf '%b' "$all_reqs" | awk '{s+=$1} END {print s}')
			printf "$FMT_COST_DATA" \
				"TOTAL" "$grand_total_reqs" "" "" "" "$grand_total_cost"
			return 0
		fi
	fi

	# Fallback to JSONL metrics
	if [[ -f "$OBS_METRICS" ]] && command -v jq &>/dev/null; then
		local result
		if [[ -n "$session_filter" ]]; then
			# Use jq --arg to pass session filter safely (prevents jq injection)
			result=$(jq -sr --arg sid "$session_filter" '[.[] | select(.session_id == $sid)] | group_by(.model) | map({
                model: .[0].model,
                requests: length,
                input_tokens: ([.[].input_tokens] | add),
                output_tokens: ([.[].output_tokens] | add),
                cache_tokens: ([.[].cache_read_tokens] | add),
                cost: ([.[].cost_total] | add)
	            }) | sort_by(-.cost)' "$OBS_METRICS" 2>/dev/null || echo "")
		else
			result=$(jq -sr '[.[] ] | group_by(.model) | map({
                model: .[0].model,
                requests: length,
                input_tokens: ([.[].input_tokens] | add),
                output_tokens: ([.[].output_tokens] | add),
                cache_tokens: ([.[].cache_read_tokens] | add),
                cost: ([.[].cost_total] | add)
	            }) | sort_by(-.cost)' "$OBS_METRICS" 2>/dev/null || echo "")
		fi

		if [[ -n "$result" && "$result" != "[]" ]]; then
			printf "$FMT_COST_ROW" "Model" "Reqs" "Input" "Output" "Cache" "Cost"
			printf "$FMT_COST_ROW" "---" "---" "---" "---" "---" "---"
			# Single jq pass: format rows + compute totals (avoids 3 separate jq calls)
			echo "$result" | jq -r '
				(.[] |
					(.model | split("/")[-1][:35]) as $short |
					"  \($short | . + " " * (35 - length) | .[:35]) \(.requests | tostring | " " * (6 - length) + .) \(.input_tokens | tostring | " " * (10 - length) + .) \(.output_tokens | tostring | " " * (10 - length) + .) \(.cache_tokens | tostring | " " * (10 - length) + .) $\(.cost)"
				),
				(
					([.[].requests] | add) as $treqs |
					([.[].cost] | add) as $tcost |
					"  \("TOTAL" | . + " " * (35 - length) | .[:35]) \($treqs | tostring | " " * (6 - length) + .)                                           $\($tcost)"
				)
			' 2>/dev/null
			return 0
		fi
	fi

	echo "  No cost data available"
	return 0
}

# Get audit log security events summary.
# Shows event type breakdown from the tamper-evident audit log.
# Arguments:
#   $1 - session ID filter (optional; audit log has no session_id field,
#        so this parameter is accepted for API consistency but noted as unfiltered)
# Output: formatted event table on stdout
_security_audit_events() {
	local session_filter="${1:-}"

	if [[ ! -f "$AUDIT_LOG" ]] || [[ ! -s "$AUDIT_LOG" ]]; then
		echo "  No audit events recorded"
		return 0
	fi

	if [[ -n "$session_filter" ]]; then
		echo "  (global — audit log has no session_id field)"
	fi

	if ! command -v jq &>/dev/null; then
		local total_events
		total_events=$(wc -l <"$AUDIT_LOG" | tr -d ' ')
		echo "  $total_events total events (install jq for breakdown)"
		return 0
	fi

	# Event type breakdown
	local breakdown
	breakdown=$(jq -r '.type' "$AUDIT_LOG" 2>/dev/null | sort | uniq -c | sort -rn) || breakdown=""

	if [[ -z "$breakdown" ]]; then
		echo "  No audit events recorded"
		return 0
	fi

	local total_events
	total_events=$(wc -l <"$AUDIT_LOG" | tr -d ' ')

	printf "$FMT_AUDIT_ROW" "Event Type" "Count"
	printf "$FMT_AUDIT_ROW" "---" "---"
	echo "$breakdown" | while read -r count event_type; do
		[[ -z "$event_type" ]] && continue
		printf "$FMT_AUDIT_ROW" "$event_type" "$count"
	done
	printf "$FMT_AUDIT_ROW" "TOTAL" "$total_events"

	# Chain integrity check
	local chain_status="UNKNOWN"
	local audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
	if [[ -x "$audit_helper" ]]; then
		if "$audit_helper" verify --quiet 2>/dev/null; then
			chain_status="INTACT"
		else
			chain_status="BROKEN"
		fi
	fi
	echo ""
	echo "  Audit chain: $chain_status"

	return 0
}

# Get network tier summary.
# Shows flagged and denied domain counts from network-tier logs.
# Arguments:
#   $1 - session ID filter (optional; network logs have no session_id field,
#        so this parameter is accepted for API consistency but noted as unfiltered)
# Output: formatted network summary on stdout
_security_network_summary() {
	local session_filter="${1:-}"
	local has_data=false

	local access_count=0 flagged_count=0 denied_count=0

	if [[ -f "$NET_ACCESS_LOG" ]]; then
		access_count=$(wc -l <"$NET_ACCESS_LOG" | tr -d ' ')
		has_data=true
	fi
	if [[ -f "$NET_FLAGGED_LOG" ]]; then
		flagged_count=$(wc -l <"$NET_FLAGGED_LOG" | tr -d ' ')
		has_data=true
	fi
	if [[ -f "$NET_DENIED_LOG" ]]; then
		denied_count=$(wc -l <"$NET_DENIED_LOG" | tr -d ' ')
		has_data=true
	fi

	if [[ "$has_data" == "false" ]]; then
		echo "  No network access logs"
		return 0
	fi

	if [[ -n "$session_filter" ]]; then
		echo "  (global — network logs have no session_id field)"
	fi

	printf "$FMT_SUMMARY_ROW" "Category" "Count"
	printf "$FMT_SUMMARY_ROW" "---" "---"
	printf "$FMT_SUMMARY_ROW" "Logged (Tier 2-3)" "$access_count"
	if [[ "$flagged_count" -gt 0 ]]; then
		printf "  ${YELLOW}%-20s %6s${NC}\n" "Flagged (Tier 4)" "$flagged_count"
	else
		printf "$FMT_SUMMARY_ROW" "Flagged (Tier 4)" "$flagged_count"
	fi
	if [[ "$denied_count" -gt 0 ]]; then
		printf "  ${RED}%-20s %6s${NC}\n" "Denied (Tier 5)" "$denied_count"
	else
		printf "$FMT_SUMMARY_ROW" "Denied (Tier 5)" "$denied_count"
	fi

	# Show top flagged domains if any
	if [[ "$flagged_count" -gt 0 ]] && command -v jq &>/dev/null; then
		echo ""
		echo "  Top flagged domains:"
		jq -r '(.domain // empty) | select(. != "")' "$NET_FLAGGED_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | while read -r count domain; do
			printf "    %-35s %s\n" "$domain" "$count"
		done
	fi

	return 0
}

# Get prompt guard detection summary.
# Shows blocked/warned/sanitized counts from prompt-guard logs.
# Arguments:
#   $1 - session ID filter (optional; prompt-guard logs have no session_id field,
#        so this parameter is accepted for API consistency but noted as unfiltered)
# Output: formatted detection summary on stdout
_security_prompt_guard() {
	local session_filter="${1:-}"

	if [[ ! -f "$PG_ATTEMPTS_LOG" ]] || [[ ! -s "$PG_ATTEMPTS_LOG" ]]; then
		echo "  No prompt injection attempts detected"
		return 0
	fi

	if [[ -n "$session_filter" ]]; then
		echo "  (global — prompt-guard logs have no session_id field)"
	fi

	local total_entries
	total_entries=$(wc -l <"$PG_ATTEMPTS_LOG" | tr -d ' ')

	local blocks=0 warns=0 sanitizes=0
	blocks=$(grep -c '"action":"BLOCK"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
	warns=$(grep -c '"action":"WARN"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
	sanitizes=$(grep -c '"action":"SANITIZE"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")

	printf "$FMT_SUMMARY_ROW" "Action" "Count"
	printf "$FMT_SUMMARY_ROW" "---" "---"
	if [[ "$blocks" -gt 0 ]]; then
		printf "  ${RED}%-20s %6s${NC}\n" "Blocked" "$blocks"
	else
		printf "$FMT_SUMMARY_ROW" "Blocked" "$blocks"
	fi
	if [[ "$warns" -gt 0 ]]; then
		printf "  ${YELLOW}%-20s %6s${NC}\n" "Warned" "$warns"
	else
		printf "$FMT_SUMMARY_ROW" "Warned" "$warns"
	fi
	printf "$FMT_SUMMARY_ROW" "Sanitized" "$sanitizes"
	printf "$FMT_SUMMARY_ROW" "TOTAL" "$total_entries"

	# Severity breakdown
	if command -v jq &>/dev/null; then
		echo ""
		echo "  By severity:"
		jq -r '.max_severity // "UNKNOWN"' "$PG_ATTEMPTS_LOG" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count sev; do
			[[ -z "$sev" ]] && continue
			printf "    %-15s %s\n" "$sev" "$count"
		done
	fi

	return 0
}

# Get session security context (t1428.3 — may not exist yet).
# Shows composite security score if session-security-helper.sh is available.
# Arguments:
#   $1 - session ID filter (optional, passed to session-security-helper.sh)
# Output: formatted context summary on stdout
_security_session_context() {
	local session_filter="${1:-}"
	local session_helper="${SCRIPT_DIR}/session-security-helper.sh"

	if [[ ! -x "$session_helper" ]]; then
		echo "  Not available (t1428.3 pending)"
		return 0
	fi

	# session-security-helper.sh exists — query it
	local score
	if [[ -n "$session_filter" ]]; then
		score=$("$session_helper" get-score --session-id "$session_filter" 2>/dev/null || echo "")
	else
		score=$("$session_helper" get-score 2>/dev/null || echo "")
	fi
	if [[ -n "$score" ]]; then
		echo "  Composite score: $score"
	else
		echo "  No session context data"
	fi

	return 0
}

# Get quarantine queue status (t1428.4 — may not exist yet).
# Shows pending quarantine items if quarantine-helper.sh is available.
# Arguments:
#   $1 - session ID filter (optional, passed to quarantine-helper.sh)
# Output: formatted quarantine summary on stdout
_security_quarantine() {
	local session_filter="${1:-}"
	local quarantine_helper="${SCRIPT_DIR}/quarantine-helper.sh"

	if [[ ! -x "$quarantine_helper" ]]; then
		echo "  Not available (t1428.4 pending)"
		return 0
	fi

	# quarantine-helper.sh exists — query it
	local status
	if [[ -n "$session_filter" ]]; then
		echo "  (global - quarantine helper has no session filter)"
	fi
	status=$("$quarantine_helper" stats 2>/dev/null || echo "")
	if [[ -n "$status" ]]; then
		echo "$status" | sed 's/^/  /'
	else
		echo "  No quarantine items"
	fi

	return 0
}

# Compute overall security posture from available data.
# Accepts optional pre-computed counts to avoid redundant file processing.
# Arguments:
#   $1 - denied count (optional, computed from logs if empty)
#   $2 - prompt-guard blocks count (optional)
#   $3 - prompt-guard warns count (optional)
#   $4 - flagged domains count (optional)
#   $5 - audit chain intact: "true"/"false"/"" (optional, checked if empty)
# Returns: CLEAN, LOW, MEDIUM, HIGH, CRITICAL on stdout
_security_posture() {
	local denied_count="${1:-}"
	local blocks="${2:-}"
	local warns="${3:-}"
	local flagged_count="${4:-}"
	local chain_intact="${5:-}"
	local posture="CLEAN"

	# Compute any counts not passed as arguments
	if [[ -z "$denied_count" ]] && [[ -f "$NET_DENIED_LOG" ]]; then
		denied_count=$(wc -l <"$NET_DENIED_LOG" | tr -d ' ')
	fi
	denied_count="${denied_count:-0}"

	if [[ -z "$blocks" || -z "$warns" ]] && [[ -f "$PG_ATTEMPTS_LOG" ]]; then
		[[ -z "$blocks" ]] && blocks=$(grep -c '"action":"BLOCK"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
		[[ -z "$warns" ]] && warns=$(grep -c '"action":"WARN"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
	fi
	blocks="${blocks:-0}"
	warns="${warns:-0}"

	if [[ -z "$flagged_count" ]] && [[ -f "$NET_FLAGGED_LOG" ]]; then
		flagged_count=$(wc -l <"$NET_FLAGGED_LOG" | tr -d ' ')
	fi
	flagged_count="${flagged_count:-0}"

	# Check for denied network access
	if [[ "$denied_count" -gt 0 ]]; then
		posture="HIGH"
	fi

	# Check for prompt injection attempts (escalate posture based on severity)
	if [[ "$blocks" -gt 0 && ("$posture" == "CLEAN" || "$posture" == "LOW") ]]; then
		posture="MEDIUM"
	elif [[ "$warns" -gt 0 && "$posture" == "CLEAN" ]]; then
		posture="LOW"
	fi

	# Check for flagged domains
	if [[ "$flagged_count" -gt 0 && "$posture" == "CLEAN" ]]; then
		posture="LOW"
	fi

	# Check audit chain integrity
	if [[ -z "$chain_intact" ]]; then
		local audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
		if [[ -x "$audit_helper" ]] && [[ -f "$AUDIT_LOG" ]] && [[ -s "$AUDIT_LOG" ]]; then
			if "$audit_helper" verify --quiet 2>/dev/null; then
				chain_intact="true"
			else
				chain_intact="false"
			fi
		fi
	fi
	if [[ "$chain_intact" == "false" ]]; then
		posture="CRITICAL"
	fi

	echo "$posture"
	return 0
}

# Main security summary output (t1428.5).
# Aggregates all security data sources into a single CLI summary.
# Arguments:
#   $1 - session ID filter (optional)
#   $2 - output format: "text" or "json" (default: text)
output_security_summary() {
	local session_filter
	if ! session_filter=$(_sanitize_session_filter "${1:-}"); then
		echo "Invalid session filter" >&2
		return 1
	fi
	local output_format="${2:-text}"

	if [[ "$output_format" == "json" ]]; then
		_security_summary_json "$session_filter"
		return $?
	fi

	# Pre-compute counts once for both posture calculation and display
	# (mirrors the JSON path to avoid redundant file reads)
	local _denied=0 _flagged=0 _blocks=0 _warns=0 _chain=""
	[[ -f "$NET_DENIED_LOG" ]] && _denied=$(wc -l <"$NET_DENIED_LOG" | tr -d ' ')
	[[ -f "$NET_FLAGGED_LOG" ]] && _flagged=$(wc -l <"$NET_FLAGGED_LOG" | tr -d ' ')
	if [[ -f "$PG_ATTEMPTS_LOG" ]]; then
		_blocks=$(grep -c '"action":"BLOCK"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
		_warns=$(grep -c '"action":"WARN"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
	fi
	local audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
	if [[ -x "$audit_helper" ]] && [[ -f "$AUDIT_LOG" ]] && [[ -s "$AUDIT_LOG" ]]; then
		if "$audit_helper" verify --quiet 2>/dev/null; then
			_chain="true"
		else
			_chain="false"
		fi
	fi

	local posture
	posture=$(_security_posture "$_denied" "$_blocks" "$_warns" "$_flagged" "$_chain")

	local posture_color="$GREEN"
	case "$posture" in
	LOW) posture_color="$YELLOW" ;;
	MEDIUM) posture_color="$YELLOW" ;;
	HIGH) posture_color="$RED" ;;
	CRITICAL) posture_color="${RED}${BOLD}" ;;
	esac

	echo -e "${BOLD}${BLUE}=== Post-Session Security Summary ===${NC}"
	echo ""
	echo -e "  Date:     $(date '+%Y-%m-%d %H:%M')"
	if [[ -n "$session_filter" ]]; then
		echo "  Session:  $session_filter"
	fi
	echo -e "  Posture:  ${posture_color}${posture}${NC}"
	echo ""

	# Section 1: Cost breakdown
	echo -e "${CYAN}## Cost Breakdown${NC}"
	_security_cost_summary "$session_filter"
	echo ""

	# Section 2: Audit log events
	echo -e "${CYAN}## Audit Events${NC}"
	_security_audit_events "$session_filter"
	echo ""

	# Section 3: Network access
	echo -e "${CYAN}## Network Access${NC}"
	_security_network_summary "$session_filter"
	echo ""

	# Section 4: Prompt guard detections
	echo -e "${CYAN}## Prompt Injection Defense${NC}"
	_security_prompt_guard "$session_filter"
	echo ""

	# Section 5: Session security context (t1428.3)
	echo -e "${CYAN}## Session Security Context${NC}"
	_security_session_context "$session_filter"
	echo ""

	# Section 6: Quarantine queue (t1428.4)
	echo -e "${CYAN}## Quarantine Queue${NC}"
	_security_quarantine "$session_filter"
	echo ""

	return 0
}

# Collect log file counts for JSON security summary.
# Outputs key=value pairs for eval by the caller.
# No arguments.
_security_json_collect_counts() {
	local audit_count=0 net_access=0 net_flagged=0 net_denied=0
	local pg_total=0 pg_blocks=0 pg_warns=0 pg_sanitizes=0

	[[ -f "$AUDIT_LOG" ]] && audit_count=$(wc -l <"$AUDIT_LOG" | tr -d ' ')
	[[ -f "$NET_ACCESS_LOG" ]] && net_access=$(wc -l <"$NET_ACCESS_LOG" | tr -d ' ')
	[[ -f "$NET_FLAGGED_LOG" ]] && net_flagged=$(wc -l <"$NET_FLAGGED_LOG" | tr -d ' ')
	[[ -f "$NET_DENIED_LOG" ]] && net_denied=$(wc -l <"$NET_DENIED_LOG" | tr -d ' ')
	if [[ -f "$PG_ATTEMPTS_LOG" ]]; then
		pg_total=$(wc -l <"$PG_ATTEMPTS_LOG" | tr -d ' ')
		pg_blocks=$(grep -c '"action":"BLOCK"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
		pg_warns=$(grep -c '"action":"WARN"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
		pg_sanitizes=$(grep -c '"action":"SANITIZE"' "$PG_ATTEMPTS_LOG" 2>/dev/null || echo "0")
	fi

	printf 'audit_count=%s\nnet_access=%s\nnet_flagged=%s\nnet_denied=%s\n' \
		"$audit_count" "$net_access" "$net_flagged" "$net_denied"
	printf 'pg_total=%s\npg_blocks=%s\npg_warns=%s\npg_sanitizes=%s\n' \
		"$pg_total" "$pg_blocks" "$pg_warns" "$pg_sanitizes"
	return 0
}

# Check audit chain integrity for JSON security summary.
# Outputs key=value pair for eval by the caller.
# No arguments.
_security_json_audit_chain() {
	local chain_intact="null"
	local audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
	if [[ -x "$audit_helper" ]] && [[ -f "$AUDIT_LOG" ]] && [[ -s "$AUDIT_LOG" ]]; then
		if "$audit_helper" verify --quiet 2>/dev/null; then
			chain_intact="true"
		else
			chain_intact="false"
		fi
	fi
	printf 'chain_intact=%s\n' "$chain_intact"
	return 0
}

# Get cost breakdown for JSON security summary.
# Queries SQLite DB first, falls back to JSONL metrics.
# Arguments:
#   $1 - session ID filter (optional)
# Outputs key=value pairs for eval by the caller.
_security_json_cost_breakdown() {
	local session_filter="${1:-}"
	local cost_json="[]"
	local cost_total=0

	if [[ -f "$OBS_DB" ]] && command -v sqlite3 &>/dev/null; then
		local db_result
		db_result=$(_security_cost_query_sqlite "json" "$session_filter" 2>/dev/null || echo "")
		if [[ -n "$db_result" && "$db_result" != "[]" ]]; then
			cost_json="$db_result"
			cost_total=$(echo "$db_result" | jq '[.[].cost] | add // 0' 2>/dev/null || echo "0")
		fi
	elif [[ -f "$OBS_METRICS" ]] && command -v jq &>/dev/null; then
		local jq_result
		if [[ -n "$session_filter" ]]; then
			jq_result=$(jq -sr --arg sid "$session_filter" '[.[] | select(.session_id == $sid)] | group_by(.model) | map({
				model: .[0].model,
				requests: length,
				input_tokens: ([.[].input_tokens] | add),
				output_tokens: ([.[].output_tokens] | add),
				cache_tokens: ([.[].cache_read_tokens] | add),
				cost: ([.[].cost_total] | add)
			}) | sort_by(-.cost)' "$OBS_METRICS" 2>/dev/null || echo "")
		else
			jq_result=$(jq -sr '[.[] ] | group_by(.model) | map({
				model: .[0].model,
				requests: length,
				input_tokens: ([.[].input_tokens] | add),
				output_tokens: ([.[].output_tokens] | add),
				cache_tokens: ([.[].cache_read_tokens] | add),
				cost: ([.[].cost_total] | add)
			}) | sort_by(-.cost)' "$OBS_METRICS" 2>/dev/null || echo "")
		fi
		if [[ -n "$jq_result" && "$jq_result" != "[]" ]]; then
			cost_json="$jq_result"
			cost_total=$(echo "$jq_result" | jq '[.[].cost] | add // 0' 2>/dev/null || echo "0")
		fi
	fi

	# Output cost_json via a temp file to avoid eval injection on arbitrary JSON
	local tmp_cost
	tmp_cost=$(mktemp) || return 1
	printf '%s' "$cost_json" >"$tmp_cost"
	printf 'cost_json_file=%s\ncost_total=%s\n' "$tmp_cost" "$cost_total"
	return 0
}

# Get session security context JSON for JSON security summary.
# Arguments:
#   $1 - session ID filter (optional)
# Outputs the JSON string on stdout.
_security_json_session_context() {
	local session_filter="${1:-}"
	local session_context_json='{"available":false}'
	local session_helper="${SCRIPT_DIR}/session-security-helper.sh"

	if [[ -x "$session_helper" ]]; then
		local context_result
		if [[ -n "$session_filter" ]]; then
			context_result=$("$session_helper" get-context --session-id "$session_filter" 2>/dev/null || echo "")
		else
			context_result=$("$session_helper" get-context 2>/dev/null || echo "")
		fi
		session_context_json=$(printf '%s' "$context_result" | jq -ce --argjson available true '. + {available: $available}' 2>/dev/null || echo '{"available":false}')
	fi

	printf '%s' "$session_context_json"
	return 0
}

# Get quarantine status for JSON security summary.
# Outputs key=value pairs for eval by the caller.
# No arguments.
_security_json_quarantine() {
	local quarantine_available="false"
	local quarantine_pending=0
	local quarantine_helper="${SCRIPT_DIR}/quarantine-helper.sh"

	if [[ -x "$quarantine_helper" ]]; then
		quarantine_available="true"
		local q_stats q_status
		q_stats=$("$quarantine_helper" stats 2>/dev/null || echo "")
		q_status=$(printf '%s\n' "$q_stats" | awk '/^[[:space:]]*Pending:[[:space:]]*[0-9]+$/ {print $2; exit}' || echo "")
		if [[ -n "$q_status" && "$q_status" =~ ^[0-9]+$ ]]; then
			quarantine_pending="$q_status"
		fi
	fi

	printf 'quarantine_available=%s\nquarantine_pending=%s\n' \
		"$quarantine_available" "$quarantine_pending"
	return 0
}

# JSON output for security summary (programmatic use).
# Arguments:
#   $1 - session ID filter (optional)
_security_summary_json() {
	local session_filter
	if ! session_filter=$(_sanitize_session_filter "${1:-}"); then
		echo "Invalid session filter" >&2
		return 1
	fi

	# Collect log file counts
	local audit_count=0 net_access=0 net_flagged=0 net_denied=0
	local pg_total=0 pg_blocks=0 pg_warns=0 pg_sanitizes=0
	eval "$(_security_json_collect_counts)"

	# Audit chain integrity
	local chain_intact="null"
	eval "$(_security_json_audit_chain)"

	# Compute posture using pre-computed counts (avoids redundant file reads)
	local posture
	posture=$(_security_posture "$net_denied" "$pg_blocks" "$pg_warns" "$net_flagged" "$chain_intact")

	# Cost breakdown — query SQLite DB or JSONL for per-model cost data
	local cost_json="[]"
	local cost_total=0
	local cost_json_file=""
	eval "$(_security_json_cost_breakdown "$session_filter")"
	if [[ -n "$cost_json_file" && -f "$cost_json_file" ]]; then
		cost_json=$(cat "$cost_json_file")
		rm -f "$cost_json_file"
	fi

	# Session context — query helper if available
	local session_context_json
	session_context_json=$(_security_json_session_context "$session_filter")

	# Quarantine — query helper if available
	local quarantine_available="false"
	local quarantine_pending=0
	eval "$(_security_json_quarantine)"

	# Build JSON safely using jq to prevent injection via session_filter
	local session_json="null"
	if [[ -n "$session_filter" ]]; then
		session_json=$(jq -n --arg s "$session_filter" '$s')
	fi
	local session_mode="false"
	if [[ -n "$session_filter" ]]; then
		session_mode="true"
	fi

	jq -n \
		--arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--argjson session_filter "$session_json" \
		--argjson session_mode "$session_mode" \
		--arg posture "$posture" \
		--argjson cost_breakdown "$cost_json" \
		--argjson cost_total "$cost_total" \
		--argjson audit_count "$audit_count" \
		--argjson chain_intact "$chain_intact" \
		--argjson net_access "$net_access" \
		--argjson net_flagged "$net_flagged" \
		--argjson net_denied "$net_denied" \
		--argjson pg_total "$pg_total" \
		--argjson pg_blocks "$pg_blocks" \
		--argjson pg_warns "$pg_warns" \
		--argjson pg_sanitizes "$pg_sanitizes" \
		--argjson session_context "$session_context_json" \
		--argjson quarantine_available "$quarantine_available" \
		--argjson quarantine_pending "$quarantine_pending" \
		'{
			timestamp: $timestamp,
			session_filter: $session_filter,
			posture: $posture,
			cost: { total: $cost_total, breakdown: $cost_breakdown },
			audit: ({ total_events: $audit_count, chain_intact: $chain_intact } + if $session_mode then {global_only: true} else {} end),
			network: ({ logged_access: $net_access, flagged: $net_flagged, denied: $net_denied } + if $session_mode then {global_only: true} else {} end),
			prompt_guard: ({ total_detections: $pg_total, blocked: $pg_blocks, warned: $pg_warns, sanitized: $pg_sanitizes } + if $session_mode then {global_only: true} else {} end),
			session_context: $session_context,
			quarantine: ({ available: $quarantine_available, pending_items: $quarantine_pending } + if $session_mode then {global_only: true} else {} end)
		}'
	return 0
}

# Find project root (look for .git or TODO.md)
find_project_root() {
	local dir="$PWD"
	while [[ "$dir" != "/" ]]; do
		if [[ -d "$dir/.git" ]] || [[ -f "$dir/TODO.md" ]]; then
			echo "$dir"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	echo "$PWD"
	return 0
}

# Get current branch
get_branch() {
	git branch --show-current 2>/dev/null || echo "not-a-git-repo"
	return 0
}

# Check if on protected branch
is_protected_branch() {
	local branch
	branch=$(get_branch)
	[[ "$branch" == "main" || "$branch" == "master" ]]
}

# Get recent commits
get_recent_commits() {
	local count="${1:-10}"
	git log --oneline -"$count" 2>/dev/null || echo "No commits"
	return 0
}

# Get uncommitted changes count
get_uncommitted_changes() {
	local staged unstaged
	staged=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d '[:space:]')
	unstaged=$(git diff --name-only 2>/dev/null | wc -l | tr -d '[:space:]')
	echo "staged:${staged:-0},unstaged:${unstaged:-0}"
	return 0
}

# Get TODO.md status
get_todo_status() {
	local project_root="$1"
	local todo_file="$project_root/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		echo "no-todo-file"
		return
	fi

	local completed incomplete in_progress
	completed=$(grep -cE '^\s*- \[x\]' "$todo_file" 2>/dev/null) || completed=0
	incomplete=$(grep -cE '^\s*- \[ \]' "$todo_file" 2>/dev/null) || incomplete=0
	in_progress=$(grep -cE '^\s*- \[>\]' "$todo_file" 2>/dev/null) || in_progress=0

	echo "completed:$completed,incomplete:$incomplete,in_progress:$in_progress"
}

# Check for Ralph loop
get_ralph_status() {
	local project_root="$1"
	# Check new location first, then legacy
	local ralph_file="$project_root/.agents/loop-state/ralph-loop.local.state"
	local ralph_file_legacy="$project_root/.claude/ralph-loop.local.state"

	local active_file=""
	[[ -f "$ralph_file" ]] && active_file="$ralph_file"
	[[ -z "$active_file" && -f "$ralph_file_legacy" ]] && active_file="$ralph_file_legacy"

	if [[ -n "$active_file" ]]; then
		local iteration max_iter
		iteration=$(grep '^iteration:' "$active_file" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "0")
		max_iter=$(grep '^max_iterations:' "$active_file" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "unlimited")
		echo "active:true,iteration:$iteration,max:$max_iter"
	else
		echo "active:false"
	fi
	return 0
}

# Get open PRs
get_pr_status() {
	if command -v gh &>/dev/null; then
		local open_prs
		open_prs=$(gh pr list --state open --limit 5 --json number,title 2>/dev/null || echo "[]")
		if [[ "$open_prs" == "[]" ]]; then
			echo "no-open-prs"
		else
			echo "$open_prs" | jq -r '.[] | "\(.number):\(.title)"' 2>/dev/null | head -3 || echo "error-parsing"
		fi
	else
		echo "gh-not-installed"
	fi
	return 0
}

# Check workflow adherence
check_workflow_adherence() {
	local project_root="$1"
	local issues=""
	local passed=""

	# Check if we're in a git repo
	local is_git_repo=true
	if ! git rev-parse --git-dir &>/dev/null; then
		is_git_repo=false
		issues+="not-a-git-repo,"
	fi

	if [[ "$is_git_repo" == "true" ]]; then
		# Check 1: Not on main
		if is_protected_branch; then
			issues+="on-protected-branch,"
		else
			passed+="feature-branch,"
		fi

		# Check 2: Recent commits have good messages
		local short_messages
		short_messages=$(git log --oneline -5 2>/dev/null | awk 'length($0) < 15' | wc -l | tr -d ' ' || echo "0")
		short_messages="${short_messages:-0}"
		if [[ "$short_messages" -gt 0 ]]; then
			issues+="short-commit-messages,"
		else
			passed+="good-commit-messages,"
		fi

		# Check 3: No secrets in staged files
		if git diff --cached --name-only 2>/dev/null | grep -qE '\.(env|key|pem|secret)$'; then
			issues+="potential-secrets-staged,"
		else
			passed+="no-secrets-staged,"
		fi
	fi

	# Check 4: TODO.md exists (works in any directory)
	if [[ -f "$project_root/TODO.md" ]]; then
		passed+="todo-exists,"
	else
		issues+="no-todo-file,"
	fi

	# Check 5: Issue-sync drift (t179.4)
	local issue_sync_script="${SCRIPT_DIR}/issue-sync-helper.sh"
	if [[ -f "$issue_sync_script" && -f "$project_root/TODO.md" ]] && command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
		local completed_no_close
		completed_no_close=$(grep -cE '^- \[x\] t[0-9]+' "$project_root/TODO.md" 2>/dev/null || echo "0")
		if [[ "$completed_no_close" -gt 0 ]]; then
			passed+="issue-sync-available,"
		fi
	fi

	echo "passed:${passed%,}|issues:${issues%,}"
	return 0
}

# Gather all context
gather_context() {
	local project_root="$1"
	local focus="${2:-all}"

	echo -e "${BOLD}${BLUE}=== Session Review Context ===${NC}"
	echo ""

	# Basic info
	echo -e "${CYAN}## Environment${NC}"
	echo "Project: $project_root"
	echo "Branch: $(get_branch)"
	echo "Date: $(date '+%Y-%m-%d %H:%M')"
	echo ""

	if [[ "$focus" == "all" || "$focus" == "objectives" ]]; then
		echo -e "${CYAN}## Objective Status${NC}"
		echo "Recent commits:"
		get_recent_commits 5 | sed 's/^/  /'
		echo ""
		echo "Uncommitted: $(get_uncommitted_changes)"
		echo "TODO status: $(get_todo_status "$project_root")"
		echo ""
	fi

	if [[ "$focus" == "all" || "$focus" == "workflow" ]]; then
		echo -e "${CYAN}## Workflow Adherence${NC}"
		local adherence
		adherence=$(check_workflow_adherence "$project_root")
		local passed issues
		passed=$(echo "$adherence" | cut -d'|' -f1 | cut -d: -f2)
		issues=$(echo "$adherence" | cut -d'|' -f2 | cut -d: -f2)

		if [[ -n "$passed" ]]; then
			echo -e "${GREEN}Passed:${NC}"
			echo "$passed" | tr ',' '\n' | sed 's/^/  - /' | grep -v '^  - $'
		fi

		if [[ -n "$issues" ]]; then
			echo -e "${YELLOW}Issues:${NC}"
			echo "$issues" | tr ',' '\n' | sed 's/^/  - /' | grep -v '^  - $'
		fi
		echo ""
	fi

	if [[ "$focus" == "all" || "$focus" == "knowledge" ]]; then
		echo -e "${CYAN}## Session Context${NC}"
		echo "Ralph loop: $(get_ralph_status "$project_root")"
		echo "Open PRs: $(get_pr_status)"
		echo ""
	fi

	# Recommendations
	echo -e "${CYAN}## Quick Recommendations${NC}"

	if is_protected_branch; then
		echo -e "${RED}! Create feature branch before making changes${NC}"
	fi

	local todo_status
	todo_status=$(get_todo_status "$project_root")
	# Only show TODO stats if we have a valid TODO file
	if [[ "$todo_status" != "no-todo-file" ]]; then
		local incomplete
		incomplete=$(echo "$todo_status" | grep -oE 'incomplete:[0-9]+' | cut -d: -f2 || echo "0")
		incomplete="${incomplete:-0}"
		if [[ "$incomplete" -gt 0 ]]; then
			echo "- $incomplete incomplete tasks in TODO.md"
		fi
	fi

	local changes
	changes=$(get_uncommitted_changes)
	local staged unstaged
	# Extract staged count (match 'staged:N' at start, before comma)
	staged=$(echo "$changes" | sed -n 's/^staged:\([0-9]*\),.*/\1/p')
	# Extract unstaged count (match 'unstaged:N' after comma)
	unstaged=$(echo "$changes" | sed -n 's/.*,unstaged:\([0-9]*\)$/\1/p')
	staged="${staged:-0}"
	unstaged="${unstaged:-0}"
	if [[ "$staged" -gt 0 ]] || [[ "$unstaged" -gt 0 ]]; then
		echo "- Uncommitted changes: $staged staged, $unstaged unstaged"
	fi

	# Issue-sync reminder (t179.4)
	local issue_sync_script="${SCRIPT_DIR}/issue-sync-helper.sh"
	if [[ -f "$issue_sync_script" && -f "$project_root/TODO.md" ]] && command -v gh &>/dev/null; then
		echo "- Run 'issue-sync-helper.sh status' to check GitHub issue drift"
	fi

	echo ""
	echo -e "${BOLD}Run /session-review in AI assistant for full analysis${NC}"
	return 0
}

# Output as JSON
output_json() {
	local project_root="$1"

	local branch todo_status ralph_status adherence changes
	branch=$(get_branch)
	todo_status=$(get_todo_status "$project_root")
	ralph_status=$(get_ralph_status "$project_root")
	adherence=$(check_workflow_adherence "$project_root")
	changes=$(get_uncommitted_changes)

	# Extract values using sed for reliable parsing
	local completed incomplete in_progress staged unstaged
	completed=$(echo "$todo_status" | sed -n 's/.*completed:\([0-9]*\).*/\1/p')
	incomplete=$(echo "$todo_status" | sed -n 's/.*incomplete:\([0-9]*\).*/\1/p')
	in_progress=$(echo "$todo_status" | sed -n 's/.*in_progress:\([0-9]*\).*/\1/p')
	staged=$(echo "$changes" | sed -n 's/^staged:\([0-9]*\),.*/\1/p')
	unstaged=$(echo "$changes" | sed -n 's/.*,unstaged:\([0-9]*\)$/\1/p')

	cat <<EOF
{
  "project": "$project_root",
  "branch": "$branch",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "todo": {
    "completed": ${completed:-0},
    "incomplete": ${incomplete:-0},
    "in_progress": ${in_progress:-0}
  },
  "changes": {
    "staged": ${staged:-0},
    "unstaged": ${unstaged:-0}
  },
  "ralph_loop": {
    "active": $(echo "$ralph_status" | grep -q 'active:true' && echo "true" || echo "false")
  },
  "workflow": {
    "on_protected_branch": $(is_protected_branch && echo "true" || echo "false")
  }
}
EOF
	return 0
}

# Quick summary
output_summary() {
	local project_root="$1"

	echo "Branch: $(get_branch)"
	echo "TODO: $(get_todo_status "$project_root")"
	echo "Changes: $(get_uncommitted_changes)"

	if is_protected_branch; then
		echo -e "${RED}WARNING: On protected branch${NC}"
	fi

	return 0
}

# Show help
show_help() {
	cat <<EOF
session-review-helper.sh - Gather session context for AI review

Usage:
  session-review-helper.sh [command] [options]

Commands:
  gather    Collect session context (default)
  summary   Quick summary only
  json      Output as JSON for programmatic use
  security  Post-session security summary (t1428.5)
  help      Show this help

Options:
  --focus <area>     Focus on: objectives, workflow, knowledge, all (default: all)
  --security         Add security summary to gather output
  --session <id>     Filter security data to specific session ID
  --json             Output security summary as JSON (with security command)

Examples:
  session-review-helper.sh                          # Full context gathering
  session-review-helper.sh summary                  # Quick summary
  session-review-helper.sh json                     # JSON output
  session-review-helper.sh gather --focus workflow   # Focus on workflow
  session-review-helper.sh security                 # Security summary
  session-review-helper.sh security --json           # Security summary as JSON
  session-review-helper.sh security --session abc123 # Filter to session
  session-review-helper.sh gather --security         # Full review + security

EOF
	return 0
}

# Main
main() {
	local command="gather"
	local focus="all"
	local include_security=false
	local session_filter=""
	local json_flag=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		gather | summary | json | help | security)
			command="$1"
			;;
		--focus)
			if [[ $# -le 1 ]] || [[ "${2:-}" == --* ]]; then
				echo "Error: --focus requires an area argument (objectives, workflow, knowledge, all)" >&2
				exit 1
			fi
			shift
			focus="$1"
			;;
		--security)
			include_security=true
			;;
		--session)
			if [[ $# -le 1 ]] || [[ "${2:-}" == --* ]]; then
				echo "Error: --session requires a session ID argument" >&2
				exit 1
			fi
			shift
			local raw_session="$1"
			if ! session_filter=$(_sanitize_session_filter "$raw_session"); then
				echo "Error: --session may only contain letters, numbers, dots, hyphens, and underscores" >&2
				exit 1
			fi
			;;
		--json)
			json_flag=true
			;;
		--help | -h)
			command="help"
			;;
		*)
			echo "Unknown option: $1" >&2
			show_help
			exit 1
			;;
		esac
		shift
	done

	local project_root
	project_root=$(find_project_root)

	case "$command" in
	gather)
		gather_context "$project_root" "$focus"
		if [[ "$include_security" == "true" ]]; then
			output_security_summary "$session_filter" "text"
		fi
		;;
	summary)
		output_summary "$project_root"
		;;
	json)
		output_json "$project_root"
		;;
	security)
		local sec_format="text"
		if [[ "$json_flag" == "true" ]]; then
			sec_format="json"
		fi
		output_security_summary "$session_filter" "$sec_format"
		;;
	help)
		show_help
		;;
	*)
		gather_context "$project_root" "$focus"
		;;
	esac

	return 0
}

main "$@"
exit $?
