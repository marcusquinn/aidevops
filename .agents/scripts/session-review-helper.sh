#!/usr/bin/env bash
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

readonly BOLD='\033[1m'

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

# Sanitize a session ID filter to prevent injection attacks.
# Only allows alphanumeric characters, hyphens, underscores, and dots.
# Arguments:
#   $1 - raw session filter value
# Output: sanitized value on stdout
_sanitize_session_filter() {
	local raw="${1:-}"
	# Strip any characters that aren't alphanumeric, dash, underscore, or dot
	local sanitized="${raw//[^a-zA-Z0-9_.-]/}"
	echo "$sanitized"
	return 0
}

# Get cost summary from observability data.
# Aggregates by model, showing request count and total cost.
# Arguments:
#   $1 - session ID filter (optional, empty = all)
# Output: formatted cost table on stdout
_security_cost_summary() {
	local session_filter
	session_filter=$(_sanitize_session_filter "${1:-}")

	# Prefer SQLite DB (real-time via plugin)
	if [[ -f "$OBS_DB" ]] && command -v sqlite3 &>/dev/null; then
		local where_clause=""
		if [[ -n "$session_filter" ]]; then
			local safe_session
			safe_session=$(_sanitize_session_filter "$session_filter")
			# Belt-and-suspenders: escape single quotes for SQL even though
			# _sanitize_session_filter already strips them
			safe_session="${safe_session//\'/\'\'}"
			where_clause="WHERE session_id = '${safe_session}'"
		fi
		local result
		result=$(sqlite3 -separator '|' "$OBS_DB" "
            SELECT
                COALESCE(model_id, 'unknown') AS model,
                COUNT(*) AS requests,
                COALESCE(SUM(tokens_input), 0) AS input_tok,
                COALESCE(SUM(tokens_output), 0) AS output_tok,
                COALESCE(SUM(tokens_cache_read), 0) AS cache_tok,
                COALESCE(SUM(cost_total), 0) AS total_cost
            FROM llm_requests
            ${where_clause}
            GROUP BY model_id
            ORDER BY total_cost DESC;
        " 2>/dev/null) || result=""

		if [[ -n "$result" ]]; then
			printf "$FMT_COST_ROW" "Model" "Reqs" "Input" "Output" "Cache" "Cost"
			printf "$FMT_COST_ROW" "---" "---" "---" "---" "---" "---"
			# Collect costs/reqs for post-loop totalling (avoids awk-per-row)
			local all_costs="" all_reqs=""
			while IFS='|' read -r model reqs input_tok output_tok cache_tok cost; do
				[[ -z "$model" ]] && continue
				# Validate numeric fields to prevent injection via malformed DB data
				[[ "$reqs" =~ ^[0-9]+$ ]] || reqs=0
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
			local safe_session
			safe_session=$(_sanitize_session_filter "$session_filter")
			# Use jq --arg to pass session filter safely (prevents jq injection)
			result=$(jq -sr --arg sid "$safe_session" '[.[] | select(.session_id == $sid)] | group_by(.model) | map({
                model: .[0].model,
                requests: length,
                input_tokens: ([.[].input_tokens] | add),
                output_tokens: ([.[].output_tokens] | add),
                cache_tokens: ([.[].cache_read_tokens] | add),
                cost: ([.[].cost_total] | add)
            }) | sort_by(-.cost)' "$OBS_METRICS" 2>/dev/null) || result=""
		else
			result=$(jq -sr '[.[] ] | group_by(.model) | map({
                model: .[0].model,
                requests: length,
                input_tokens: ([.[].input_tokens] | add),
                output_tokens: ([.[].output_tokens] | add),
                cache_tokens: ([.[].cache_read_tokens] | add),
                cost: ([.[].cost_total] | add)
            }) | sort_by(-.cost)' "$OBS_METRICS" 2>/dev/null) || result=""
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
# Output: formatted event table on stdout
_security_audit_events() {
	if [[ ! -f "$AUDIT_LOG" ]] || [[ ! -s "$AUDIT_LOG" ]]; then
		echo "  No audit events recorded"
		return 0
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
# Output: formatted network summary on stdout
_security_network_summary() {
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
		jq -r '.domain // empty' "$NET_FLAGGED_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | while read -r count domain; do
			printf "    %-35s %s\n" "$domain" "$count"
		done
	fi

	return 0
}

# Get prompt guard detection summary.
# Shows blocked/warned/sanitized counts from prompt-guard logs.
# Output: formatted detection summary on stdout
_security_prompt_guard() {
	if [[ ! -f "$PG_ATTEMPTS_LOG" ]] || [[ ! -s "$PG_ATTEMPTS_LOG" ]]; then
		echo "  No prompt injection attempts detected"
		return 0
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
# Output: formatted context summary on stdout
_security_session_context() {
	local session_helper="${SCRIPT_DIR}/session-security-helper.sh"

	if [[ ! -x "$session_helper" ]]; then
		echo "  Not available (t1428.3 pending)"
		return 0
	fi

	# session-security-helper.sh exists — query it
	local score
	score=$("$session_helper" score 2>/dev/null) || score=""
	if [[ -n "$score" ]]; then
		echo "  Composite score: $score"
	else
		echo "  No session context data"
	fi

	return 0
}

# Get quarantine queue status (t1428.4 — may not exist yet).
# Shows pending quarantine items if quarantine-helper.sh is available.
# Output: formatted quarantine summary on stdout
_security_quarantine() {
	local quarantine_helper="${SCRIPT_DIR}/quarantine-helper.sh"

	if [[ ! -x "$quarantine_helper" ]]; then
		echo "  Not available (t1428.4 pending)"
		return 0
	fi

	# quarantine-helper.sh exists — query it
	local status
	status=$("$quarantine_helper" status 2>/dev/null) || status=""
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
	session_filter=$(_sanitize_session_filter "${1:-}")
	local output_format="${2:-text}"

	if [[ "$output_format" == "json" ]]; then
		_security_summary_json "$session_filter"
		return $?
	fi

	local posture
	posture=$(_security_posture)

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
	_security_audit_events
	echo ""

	# Section 3: Network access
	echo -e "${CYAN}## Network Access${NC}"
	_security_network_summary
	echo ""

	# Section 4: Prompt guard detections
	echo -e "${CYAN}## Prompt Injection Defense${NC}"
	_security_prompt_guard
	echo ""

	# Section 5: Session security context (t1428.3)
	echo -e "${CYAN}## Session Security Context${NC}"
	_security_session_context
	echo ""

	# Section 6: Quarantine queue (t1428.4)
	echo -e "${CYAN}## Quarantine Queue${NC}"
	_security_quarantine
	echo ""

	return 0
}

# JSON output for security summary (programmatic use).
# Arguments:
#   $1 - session ID filter (optional)
_security_summary_json() {
	local session_filter
	session_filter=$(_sanitize_session_filter "${1:-}")

	# Collect counts first (used by both posture calculation and JSON output)
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

	# Audit chain status
	local chain_intact="null"
	local audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
	if [[ -x "$audit_helper" ]] && [[ -f "$AUDIT_LOG" ]] && [[ -s "$AUDIT_LOG" ]]; then
		if "$audit_helper" verify --quiet 2>/dev/null; then
			chain_intact="true"
		else
			chain_intact="false"
		fi
	fi

	# Compute posture using pre-computed counts (avoids redundant file reads)
	local posture
	posture=$(_security_posture "$net_denied" "$pg_blocks" "$pg_warns" "$net_flagged" "$chain_intact")

	# Session context availability
	local session_context_available="false"
	[[ -x "${SCRIPT_DIR}/session-security-helper.sh" ]] && session_context_available="true"

	# Quarantine availability
	local quarantine_available="false"
	[[ -x "${SCRIPT_DIR}/quarantine-helper.sh" ]] && quarantine_available="true"

	# Build JSON safely using jq to prevent injection via session_filter
	local session_json="null"
	if [[ -n "$session_filter" ]]; then
		local safe_session
		safe_session=$(_sanitize_session_filter "$session_filter")
		session_json=$(jq -n --arg s "$safe_session" '$s')
	fi

	jq -n \
		--arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--argjson session_filter "$session_json" \
		--arg posture "$posture" \
		--argjson audit_count "$audit_count" \
		--argjson chain_intact "$chain_intact" \
		--argjson net_access "$net_access" \
		--argjson net_flagged "$net_flagged" \
		--argjson net_denied "$net_denied" \
		--argjson pg_total "$pg_total" \
		--argjson pg_blocks "$pg_blocks" \
		--argjson pg_warns "$pg_warns" \
		--argjson pg_sanitizes "$pg_sanitizes" \
		--argjson session_context_available "$session_context_available" \
		--argjson quarantine_available "$quarantine_available" \
		'{
			timestamp: $timestamp,
			session_filter: $session_filter,
			posture: $posture,
			audit: { total_events: $audit_count, chain_intact: $chain_intact },
			network: { logged_access: $net_access, flagged: $net_flagged, denied: $net_denied },
			prompt_guard: { total_detections: $pg_total, blocked: $pg_blocks, warned: $pg_warns, sanitized: $pg_sanitizes },
			session_context: { available: $session_context_available },
			quarantine: { available: $quarantine_available }
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
			shift
			focus="${1:-all}"
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
			session_filter=$(_sanitize_session_filter "$1")
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
