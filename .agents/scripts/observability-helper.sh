#!/usr/bin/env bash
# shellcheck disable=SC1091

# Observability Helper - LLM request tracking and analytics (t1307)
#
# SQLite WAL-mode database tracking all LLM requests parsed from Claude Code
# JSONL session logs. Tracks: model, provider, tokens (input/output/cache
# read/write), costs (per-category), duration, TTFT (time to first token),
# stop reason, error messages.
#
# Inspired by oh-my-pi's packages/stats/ system. Uses incremental parsing
# with byte-offset tracking to avoid re-processing already-parsed log entries.
#
# Usage: observability-helper.sh [command] [options]
#
# Commands:
#   ingest          Parse new log entries from Claude JSONL files
#   summary         Show overall usage summary
#   models          Show per-model breakdown
#   projects        Show per-project breakdown
#   costs           Show cost analysis with per-category breakdown
#   trend           Show usage trends over time
#   record          Manually record an LLM request
#   sync-budget     Sync parsed data to budget-tracker (t1100)
#   prune           Remove old data (default: keep 90 days)
#   help            Show this help
#
# Options:
#   --json          Output in JSON format
#   --days N        Look back N days (default: 30)
#   --project X     Filter by project
#   --model X       Filter by model
#   --provider X    Filter by provider
#
# Storage: ~/.aidevops/.agent-workspace/observability.db
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly OBS_DIR="${HOME}/.aidevops/.agent-workspace"
readonly OBS_DB="${OBS_DIR}/observability.db"
readonly CLAUDE_LOG_DIR="${HOME}/.claude/projects"
readonly DEFAULT_LOOKBACK_DAYS=30
readonly DEFAULT_PRUNE_DAYS=90

# =============================================================================
# Database Setup
# =============================================================================

init_db() {
	mkdir -p "$OBS_DIR" 2>/dev/null || true

	sqlite3 "$OBS_DB" "
		PRAGMA journal_mode=WAL;
		PRAGMA busy_timeout=5000;

		-- LLM request tracking (one row per assistant response)
		CREATE TABLE IF NOT EXISTS llm_requests (
			id                    INTEGER PRIMARY KEY AUTOINCREMENT,
			provider              TEXT NOT NULL,
			model                 TEXT NOT NULL,
			session_id            TEXT DEFAULT '',
			request_id            TEXT DEFAULT '',
			project               TEXT DEFAULT '',
			input_tokens          INTEGER NOT NULL DEFAULT 0,
			output_tokens         INTEGER NOT NULL DEFAULT 0,
			cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
			cache_write_tokens    INTEGER NOT NULL DEFAULT 0,
			cost_input            REAL NOT NULL DEFAULT 0,
			cost_output           REAL NOT NULL DEFAULT 0,
			cost_cache_read       REAL NOT NULL DEFAULT 0,
			cost_cache_write      REAL NOT NULL DEFAULT 0,
			cost_total            REAL NOT NULL DEFAULT 0,
			duration_ms           INTEGER DEFAULT 0,
			ttft_ms               INTEGER DEFAULT 0,
			stop_reason           TEXT DEFAULT '',
			error_message         TEXT DEFAULT '',
			service_tier          TEXT DEFAULT '',
			git_branch            TEXT DEFAULT '',
			log_source            TEXT DEFAULT '',
			recorded_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		);

		-- Incremental parse offset tracking (one row per log file)
		CREATE TABLE IF NOT EXISTS parse_offsets (
			file_path             TEXT PRIMARY KEY,
			byte_offset           INTEGER NOT NULL DEFAULT 0,
			last_parsed           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		);

		-- Indexes for common query patterns
		CREATE INDEX IF NOT EXISTS idx_llm_requests_recorded
			ON llm_requests(recorded_at);
		CREATE INDEX IF NOT EXISTS idx_llm_requests_model
			ON llm_requests(model);
		CREATE INDEX IF NOT EXISTS idx_llm_requests_provider
			ON llm_requests(provider);
		CREATE INDEX IF NOT EXISTS idx_llm_requests_project
			ON llm_requests(project);
		CREATE INDEX IF NOT EXISTS idx_llm_requests_session
			ON llm_requests(session_id);
	" >/dev/null 2>/dev/null || {
		print_error "Failed to initialize observability database"
		return 1
	}

	return 0
}

db_query() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" "$OBS_DB" "$query" 2>/dev/null
	return $?
}

db_query_json() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" -json "$OBS_DB" "$query" 2>/dev/null
	return $?
}

sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

# =============================================================================
# Pricing (reuse budget-tracker patterns)
# =============================================================================

get_model_pricing() {
	local model="$1"
	local model_short="${model#*/}"
	model_short="${model_short%%-202*}" # Strip date suffix for matching

	# Returns: input_price|output_price|cache_read_price|cache_write_price per 1M tokens
	case "$model_short" in
	*opus-4* | *claude-opus*)
		echo "15.0|75.0|1.50|18.75"
		;;
	*sonnet-4* | *claude-sonnet*)
		echo "3.0|15.0|0.30|3.75"
		;;
	*haiku-4* | *haiku-3* | *claude-haiku*)
		echo "0.80|4.0|0.08|1.0"
		;;
	*gpt-4.1-mini*)
		echo "0.40|1.60|0.10|0.40"
		;;
	*gpt-4.1*)
		echo "2.0|8.0|0.50|2.0"
		;;
	*o3*)
		echo "10.0|40.0|2.50|10.0"
		;;
	*o4-mini*)
		echo "1.10|4.40|0.275|1.10"
		;;
	*gemini-2.5-pro*)
		echo "1.25|10.0|0.3125|2.50"
		;;
	*gemini-2.5-flash*)
		echo "0.15|0.60|0.0375|0.15"
		;;
	*deepseek-r1*)
		echo "0.55|2.19|0.14|0.55"
		;;
	*deepseek-v3*)
		echo "0.27|1.10|0.07|0.27"
		;;
	*)
		echo "3.0|15.0|0.30|3.75" # Default to sonnet-tier
		;;
	esac
	return 0
}

calculate_costs() {
	local input_tokens="$1"
	local output_tokens="$2"
	local cache_read_tokens="$3"
	local cache_write_tokens="$4"
	local model="$5"

	local pricing
	pricing=$(get_model_pricing "$model")
	local input_price output_price cache_read_price cache_write_price
	IFS='|' read -r input_price output_price cache_read_price cache_write_price <<<"$pricing"

	# Cost = tokens / 1M * price_per_1M
	local cost_input cost_output cost_cache_read cost_cache_write cost_total
	cost_input=$(awk "BEGIN { printf \"%.8f\", $input_tokens / 1000000.0 * $input_price }")
	cost_output=$(awk "BEGIN { printf \"%.8f\", $output_tokens / 1000000.0 * $output_price }")
	cost_cache_read=$(awk "BEGIN { printf \"%.8f\", $cache_read_tokens / 1000000.0 * $cache_read_price }")
	cost_cache_write=$(awk "BEGIN { printf \"%.8f\", $cache_write_tokens / 1000000.0 * $cache_write_price }")
	cost_total=$(awk "BEGIN { printf \"%.8f\", $cost_input + $cost_output + $cost_cache_read + $cost_cache_write }")

	echo "${cost_input}|${cost_output}|${cost_cache_read}|${cost_cache_write}|${cost_total}"
	return 0
}

# =============================================================================
# JSONL Log Parsing
# =============================================================================

# Derive project name from log file path
# ~/.claude/projects/-Users-marcusquinn-Git-aidevops/session.jsonl -> aidevops
get_project_from_path() {
	local file_path="$1"
	local dir_name
	dir_name=$(basename "$(dirname "$file_path")")
	# Pattern: -Users-username-Git-projectname or -Users-username-Git-project-branch
	# Extract the last meaningful segment after Git-
	local project
	project=$(echo "$dir_name" | sed -E 's/^-Users-[^-]+-Git-//' | sed -E 's/-.*(feature|bugfix|hotfix|chore|refactor|experiment|release)-.*//')
	if [[ -z "$project" || "$project" == "-" ]]; then
		project="unknown"
	fi
	echo "$project"
	return 0
}

# Derive provider from model string
get_provider_from_model() {
	local model="$1"
	case "$model" in
	claude-* | anthropic/*)
		echo "anthropic"
		;;
	gpt-* | openai/*)
		echo "openai"
		;;
	gemini-* | google/*)
		echo "google"
		;;
	deepseek-* | deepseek/*)
		echo "deepseek"
		;;
	grok-* | xai/*)
		echo "xai"
		;;
	*)
		echo "unknown"
		;;
	esac
	return 0
}

# Parse a single JSONL log file from a given byte offset.
# Uses a single jq invocation for the entire file (fast), then batch-inserts
# into SQLite via a single transaction (avoids per-line jq + per-row INSERT).
parse_jsonl_file() {
	local file_path="$1"
	local start_offset="${2:-0}"

	if [[ ! -f "$file_path" ]]; then
		return 0
	fi

	local file_size
	file_size=$(wc -c <"$file_path" | tr -d ' ')

	if [[ "$start_offset" -ge "$file_size" ]]; then
		echo "$start_offset"
		return 0
	fi

	local project
	project=$(get_project_from_path "$file_path")
	local escaped_project
	escaped_project=$(sql_escape "$project")
	local escaped_file_path
	escaped_file_path=$(sql_escape "$file_path")

	# Single jq invocation: extract all assistant messages with usage data.
	# Outputs pipe-delimited rows for efficient bash processing.
	# dd reads from byte offset; jq processes entire stream at once.
	local parsed_rows
	parsed_rows=$(dd if="$file_path" bs=1 skip="$start_offset" count=$((file_size - start_offset)) 2>/dev/null |
		jq -r '
			select(.type == "assistant" and .message.usage != null) |
			[
				(.message.model // "unknown"),
				(.sessionId // ""),
				(.requestId // ""),
				(.message.usage.input_tokens // 0),
				(.message.usage.output_tokens // 0),
				(.message.usage.cache_read_input_tokens // 0),
				((.message.usage.cache_creation_input_tokens // 0) +
				 (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) +
				 (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0)),
				(.message.stop_reason // ""),
				(.timestamp // ""),
				(.message.usage.service_tier // ""),
				(.gitBranch // "")
			] | join("|")
		' 2>/dev/null) || parsed_rows=""

	if [[ -z "$parsed_rows" ]]; then
		# No assistant messages found — still update offset
		db_query "
			INSERT INTO parse_offsets (file_path, byte_offset, last_parsed)
			VALUES ('$escaped_file_path', $file_size, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
			ON CONFLICT(file_path) DO UPDATE SET
				byte_offset = $file_size,
				last_parsed = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
		" || true
		echo "$file_size"
		return 0
	fi

	# Build a single SQL transaction with all INSERTs for this file
	local sql_batch="BEGIN TRANSACTION;"
	local insert_count=0

	while IFS='|' read -r model session_id request_id input_tokens output_tokens \
		cache_read_tokens cache_write_tokens stop_reason timestamp \
		service_tier git_branch; do

		[[ -z "$model" ]] && continue

		# Skip entries with no meaningful token usage
		local total_tokens=$((input_tokens + output_tokens + cache_read_tokens + cache_write_tokens))
		if [[ "$total_tokens" -eq 0 ]]; then
			continue
		fi

		local provider
		provider=$(get_provider_from_model "$model")

		# Calculate costs inline (avoid subshell per row)
		local pricing
		pricing=$(get_model_pricing "$model")
		local input_price output_price cache_read_price cache_write_price
		IFS='|' read -r input_price output_price cache_read_price cache_write_price <<<"$pricing"

		local cost_input cost_output cost_cache_read cost_cache_write cost_total
		cost_input=$(awk "BEGIN { printf \"%.8f\", $input_tokens / 1000000.0 * $input_price }")
		cost_output=$(awk "BEGIN { printf \"%.8f\", $output_tokens / 1000000.0 * $output_price }")
		cost_cache_read=$(awk "BEGIN { printf \"%.8f\", $cache_read_tokens / 1000000.0 * $cache_read_price }")
		cost_cache_write=$(awk "BEGIN { printf \"%.8f\", $cache_write_tokens / 1000000.0 * $cache_write_price }")
		cost_total=$(awk "BEGIN { printf \"%.8f\", $cost_input + $cost_output + $cost_cache_read + $cost_cache_write }")

		sql_batch="${sql_batch}
INSERT INTO llm_requests (
	provider, model, session_id, request_id, project,
	input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
	cost_input, cost_output, cost_cache_read, cost_cache_write, cost_total,
	stop_reason, service_tier, git_branch, log_source, recorded_at
) VALUES (
	'$(sql_escape "$provider")', '$(sql_escape "$model")',
	'$(sql_escape "$session_id")', '$(sql_escape "$request_id")', '$escaped_project',
	$input_tokens, $output_tokens, $cache_read_tokens, $cache_write_tokens,
	$cost_input, $cost_output, $cost_cache_read, $cost_cache_write, $cost_total,
	'$(sql_escape "$stop_reason")', '$(sql_escape "$service_tier")',
	'$(sql_escape "$git_branch")', '$escaped_file_path',
	'$(sql_escape "$timestamp")'
);"
		insert_count=$((insert_count + 1))
	done <<<"$parsed_rows"

	# Update parse offset in same transaction
	sql_batch="${sql_batch}
INSERT INTO parse_offsets (file_path, byte_offset, last_parsed)
VALUES ('$escaped_file_path', $file_size, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
ON CONFLICT(file_path) DO UPDATE SET
	byte_offset = $file_size,
	last_parsed = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
COMMIT;"

	# Execute entire batch in one sqlite3 call
	db_query "$sql_batch" || true

	if [[ "$insert_count" -gt 0 ]]; then
		print_info "Parsed $insert_count requests from $(basename "$file_path")"
	fi

	echo "$file_size"
	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Ingest new log entries from all Claude JSONL files
cmd_ingest() {
	local quiet=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--quiet)
			quiet=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ ! -d "$CLAUDE_LOG_DIR" ]]; then
		print_warning "Claude log directory not found: $CLAUDE_LOG_DIR"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_error "jq is required for log parsing. Install with: brew install jq"
		return 1
	fi

	local files_processed=0

	# Find all JSONL files recursively
	while IFS= read -r jsonl_file; do
		[[ -z "$jsonl_file" ]] && continue

		# Get current offset for this file
		local current_offset
		current_offset=$(db_query "
			SELECT COALESCE(byte_offset, 0) FROM parse_offsets
			WHERE file_path = '$(sql_escape "$jsonl_file")';
		") || current_offset=0
		current_offset="${current_offset:-0}"

		# Check if file has new data
		local file_size
		file_size=$(wc -c <"$jsonl_file" | tr -d ' ')
		if [[ "$current_offset" -ge "$file_size" ]]; then
			continue
		fi

		# Parse new entries (offset returned but tracked in DB)
		parse_jsonl_file "$jsonl_file" "$current_offset" >/dev/null
		files_processed=$((files_processed + 1))

	done < <(find "$CLAUDE_LOG_DIR" -name "*.jsonl" -type f 2>/dev/null)

	if [[ "$quiet" != "true" ]]; then
		print_success "Ingestion complete: processed $files_processed files"
	fi

	return 0
}

# Show overall usage summary
cmd_summary() {
	local days=$DEFAULT_LOOKBACK_DAYS
	local json_flag=false
	local project_filter="" provider_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-$DEFAULT_LOOKBACK_DAYS}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		--project)
			project_filter="${2:-}"
			shift 2
			;;
		--provider)
			provider_filter="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Auto-ingest before showing stats
	cmd_ingest --quiet 2>/dev/null || true

	local where_clause="WHERE recorded_at >= datetime('now', '-${days} days')"
	[[ -n "$project_filter" ]] && where_clause="$where_clause AND project = '$(sql_escape "$project_filter")'"
	[[ -n "$provider_filter" ]] && where_clause="$where_clause AND provider = '$(sql_escape "$provider_filter")'"

	if [[ "$json_flag" == "true" ]]; then
		db_query_json "
			SELECT
				COUNT(*) as total_requests,
				COALESCE(SUM(input_tokens), 0) as total_input_tokens,
				COALESCE(SUM(output_tokens), 0) as total_output_tokens,
				COALESCE(SUM(cache_read_tokens), 0) as total_cache_read_tokens,
				COALESCE(SUM(cache_write_tokens), 0) as total_cache_write_tokens,
				COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens), 0) as total_tokens,
				ROUND(COALESCE(SUM(cost_total), 0), 4) as total_cost_usd,
				ROUND(COALESCE(SUM(cost_input), 0), 4) as cost_input_usd,
				ROUND(COALESCE(SUM(cost_output), 0), 4) as cost_output_usd,
				ROUND(COALESCE(SUM(cost_cache_read), 0), 4) as cost_cache_read_usd,
				ROUND(COALESCE(SUM(cost_cache_write), 0), 4) as cost_cache_write_usd,
				ROUND(COALESCE(AVG(ttft_ms), 0), 0) as avg_ttft_ms,
				COUNT(DISTINCT session_id) as unique_sessions,
				COUNT(DISTINCT model) as unique_models,
				COUNT(DISTINCT project) as unique_projects,
				$days as lookback_days
			FROM llm_requests
			$where_clause;
		"
		return 0
	fi

	echo ""
	echo "LLM Usage Summary (last ${days} days)"
	echo "======================================"
	echo ""

	local stats
	stats=$(db_query "
		SELECT
			COUNT(*),
			COALESCE(SUM(input_tokens), 0),
			COALESCE(SUM(output_tokens), 0),
			COALESCE(SUM(cache_read_tokens), 0),
			COALESCE(SUM(cache_write_tokens), 0),
			ROUND(COALESCE(SUM(cost_total), 0), 4),
			ROUND(COALESCE(SUM(cost_input), 0), 4),
			ROUND(COALESCE(SUM(cost_output), 0), 4),
			ROUND(COALESCE(SUM(cost_cache_read), 0), 4),
			ROUND(COALESCE(SUM(cost_cache_write), 0), 4),
			ROUND(COALESCE(AVG(CASE WHEN ttft_ms > 0 THEN ttft_ms END), 0), 0),
			COUNT(DISTINCT session_id),
			COUNT(DISTINCT model),
			COUNT(DISTINCT project)
		FROM llm_requests
		$where_clause;
	") || stats="0|0|0|0|0|0|0|0|0|0|0|0|0|0"

	local total_requests input_tokens output_tokens cache_read cache_write
	local cost_total cost_input cost_output cost_cache_read cost_cache_write
	local avg_ttft sessions models projects

	IFS='|' read -r total_requests input_tokens output_tokens cache_read cache_write \
		cost_total cost_input cost_output cost_cache_read cost_cache_write \
		avg_ttft sessions models projects <<<"$stats"

	local total_tokens=$((input_tokens + output_tokens + cache_read + cache_write))

	echo "  Requests:          $total_requests"
	echo "  Sessions:          $sessions"
	echo "  Models used:       $models"
	echo "  Projects:          $projects"
	echo ""
	echo "  Tokens:"
	printf "    Input:           %'d\n" "$input_tokens"
	printf "    Output:          %'d\n" "$output_tokens"
	printf "    Cache read:      %'d\n" "$cache_read"
	printf "    Cache write:     %'d\n" "$cache_write"
	printf "    Total:           %'d\n" "$total_tokens"
	echo ""
	echo "  Costs:"
	echo "    Input:           \$${cost_input}"
	echo "    Output:          \$${cost_output}"
	echo "    Cache read:      \$${cost_cache_read}"
	echo "    Cache write:     \$${cost_cache_write}"
	echo "    Total:           \$${cost_total}"
	echo ""
	echo "  Performance:"
	echo "    Avg TTFT:        ${avg_ttft}ms"
	echo ""

	# Top stop reasons
	echo "  Stop Reasons:"
	db_query "
		SELECT stop_reason, COUNT(*) as cnt
		FROM llm_requests
		$where_clause
		AND stop_reason != ''
		GROUP BY stop_reason
		ORDER BY cnt DESC
		LIMIT 5;
	" | while IFS='|' read -r reason cnt; do
		printf "    %-20s %s\n" "$reason" "$cnt"
	done
	echo ""

	return 0
}

# Show per-model breakdown
cmd_models() {
	local days=$DEFAULT_LOOKBACK_DAYS
	local json_flag=false
	local project_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-$DEFAULT_LOOKBACK_DAYS}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		--project)
			project_filter="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	cmd_ingest --quiet 2>/dev/null || true

	local where_clause="WHERE recorded_at >= datetime('now', '-${days} days')"
	[[ -n "$project_filter" ]] && where_clause="$where_clause AND project = '$(sql_escape "$project_filter")'"

	if [[ "$json_flag" == "true" ]]; then
		db_query_json "
			SELECT
				model,
				provider,
				COUNT(*) as requests,
				SUM(input_tokens) as input_tokens,
				SUM(output_tokens) as output_tokens,
				SUM(cache_read_tokens) as cache_read_tokens,
				SUM(cache_write_tokens) as cache_write_tokens,
				ROUND(SUM(cost_total), 4) as cost_usd,
				ROUND(AVG(CASE WHEN ttft_ms > 0 THEN ttft_ms END), 0) as avg_ttft_ms
			FROM llm_requests
			$where_clause
			GROUP BY model, provider
			ORDER BY cost_usd DESC;
		"
		return 0
	fi

	echo ""
	echo "Model Breakdown (last ${days} days)"
	echo "===================================="
	echo ""
	printf "  %-35s %-8s %-12s %-12s %-10s %-8s\n" \
		"Model" "Reqs" "Input Tok" "Output Tok" "Cost" "TTFT"
	printf "  %-35s %-8s %-12s %-12s %-10s %-8s\n" \
		"-----------------------------------" "----" "----------" "----------" "------" "----"

	db_query "
		SELECT
			model,
			COUNT(*),
			SUM(input_tokens),
			SUM(output_tokens),
			ROUND(SUM(cost_total), 4),
			ROUND(AVG(CASE WHEN ttft_ms > 0 THEN ttft_ms END), 0)
		FROM llm_requests
		$where_clause
		GROUP BY model
		ORDER BY SUM(cost_total) DESC;
	" | while IFS='|' read -r model reqs inp outp cost ttft; do
		ttft="${ttft:-0}"
		printf "  %-35s %-8s %-12s %-12s \$%-9s %sms\n" \
			"$model" "$reqs" "$inp" "$outp" "$cost" "$ttft"
	done
	echo ""

	return 0
}

# Show per-project breakdown
cmd_projects() {
	local days=$DEFAULT_LOOKBACK_DAYS
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-$DEFAULT_LOOKBACK_DAYS}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	cmd_ingest --quiet 2>/dev/null || true

	local where_clause="WHERE recorded_at >= datetime('now', '-${days} days')"

	if [[ "$json_flag" == "true" ]]; then
		db_query_json "
			SELECT
				project,
				COUNT(*) as requests,
				COUNT(DISTINCT session_id) as sessions,
				COUNT(DISTINCT model) as models_used,
				SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) as total_tokens,
				ROUND(SUM(cost_total), 4) as cost_usd,
				ROUND(AVG(CASE WHEN ttft_ms > 0 THEN ttft_ms END), 0) as avg_ttft_ms
			FROM llm_requests
			$where_clause
			GROUP BY project
			ORDER BY cost_usd DESC;
		"
		return 0
	fi

	echo ""
	echo "Project Breakdown (last ${days} days)"
	echo "======================================"
	echo ""
	printf "  %-25s %-8s %-8s %-12s %-10s\n" \
		"Project" "Reqs" "Sessions" "Tokens" "Cost"
	printf "  %-25s %-8s %-8s %-12s %-10s\n" \
		"-------------------------" "----" "--------" "----------" "------"

	db_query "
		SELECT
			project,
			COUNT(*),
			COUNT(DISTINCT session_id),
			SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens),
			ROUND(SUM(cost_total), 4)
		FROM llm_requests
		$where_clause
		GROUP BY project
		ORDER BY SUM(cost_total) DESC;
	" | while IFS='|' read -r proj reqs sess tokens cost; do
		printf "  %-25s %-8s %-8s %-12s \$%-9s\n" \
			"$proj" "$reqs" "$sess" "$tokens" "$cost"
	done
	echo ""

	return 0
}

# Show cost analysis with per-category breakdown
cmd_costs() {
	local days=$DEFAULT_LOOKBACK_DAYS
	local json_flag=false
	local project_filter="" provider_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-$DEFAULT_LOOKBACK_DAYS}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		--project)
			project_filter="${2:-}"
			shift 2
			;;
		--provider)
			provider_filter="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	cmd_ingest --quiet 2>/dev/null || true

	local where_clause="WHERE recorded_at >= datetime('now', '-${days} days')"
	[[ -n "$project_filter" ]] && where_clause="$where_clause AND project = '$(sql_escape "$project_filter")'"
	[[ -n "$provider_filter" ]] && where_clause="$where_clause AND provider = '$(sql_escape "$provider_filter")'"

	if [[ "$json_flag" == "true" ]]; then
		db_query_json "
			SELECT
				provider,
				model,
				COUNT(*) as requests,
				ROUND(SUM(cost_input), 4) as cost_input,
				ROUND(SUM(cost_output), 4) as cost_output,
				ROUND(SUM(cost_cache_read), 4) as cost_cache_read,
				ROUND(SUM(cost_cache_write), 4) as cost_cache_write,
				ROUND(SUM(cost_total), 4) as cost_total,
				ROUND(SUM(cost_total) / COUNT(*), 6) as cost_per_request
			FROM llm_requests
			$where_clause
			GROUP BY provider, model
			ORDER BY cost_total DESC;
		"
		return 0
	fi

	echo ""
	echo "Cost Analysis (last ${days} days)"
	echo "=================================="
	echo ""

	# Overall cost summary
	local totals
	totals=$(db_query "
		SELECT
			ROUND(COALESCE(SUM(cost_input), 0), 4),
			ROUND(COALESCE(SUM(cost_output), 0), 4),
			ROUND(COALESCE(SUM(cost_cache_read), 0), 4),
			ROUND(COALESCE(SUM(cost_cache_write), 0), 4),
			ROUND(COALESCE(SUM(cost_total), 0), 4),
			COUNT(*)
		FROM llm_requests
		$where_clause;
	") || totals="0|0|0|0|0|0"

	local t_input t_output t_cache_read t_cache_write t_total t_count
	IFS='|' read -r t_input t_output t_cache_read t_cache_write t_total t_count <<<"$totals"

	echo "  Cost Category Breakdown:"
	echo "    Input tokens:      \$${t_input}"
	echo "    Output tokens:     \$${t_output}"
	echo "    Cache read:        \$${t_cache_read}"
	echo "    Cache write:       \$${t_cache_write}"
	echo "    ─────────────────────────"
	echo "    Total:             \$${t_total}"
	echo ""

	if [[ "$t_count" -gt 0 ]]; then
		local avg_cost
		avg_cost=$(awk "BEGIN { printf \"%.6f\", $t_total / $t_count }")
		echo "  Avg cost/request:    \$${avg_cost}"
		local daily_avg
		daily_avg=$(awk "BEGIN { printf \"%.4f\", $t_total / $days }")
		echo "  Avg cost/day:        \$${daily_avg}"
	fi
	echo ""

	# Per-provider breakdown
	echo "  By Provider:"
	printf "    %-15s %-8s %-10s %-10s\n" "Provider" "Reqs" "Cost" "Avg/Req"
	printf "    %-15s %-8s %-10s %-10s\n" "---------------" "----" "------" "-------"

	db_query "
		SELECT
			provider,
			COUNT(*),
			ROUND(SUM(cost_total), 4),
			ROUND(SUM(cost_total) / COUNT(*), 6)
		FROM llm_requests
		$where_clause
		GROUP BY provider
		ORDER BY SUM(cost_total) DESC;
	" | while IFS='|' read -r prov reqs cost avg; do
		printf "    %-15s %-8s \$%-9s \$%-9s\n" "$prov" "$reqs" "$cost" "$avg"
	done
	echo ""

	# Cache efficiency
	local cache_stats
	cache_stats=$(db_query "
		SELECT
			COALESCE(SUM(cache_read_tokens), 0),
			COALESCE(SUM(input_tokens + cache_read_tokens), 0),
			COALESCE(SUM(cost_cache_read), 0),
			COALESCE(SUM(cost_input + cost_cache_read), 0)
		FROM llm_requests
		$where_clause;
	") || cache_stats="0|0|0|0"

	local cr_tokens total_input_tokens cr_cost _total_input_cost
	IFS='|' read -r cr_tokens total_input_tokens cr_cost _total_input_cost <<<"$cache_stats"

	if [[ "$total_input_tokens" -gt 0 ]]; then
		local cache_hit_pct
		cache_hit_pct=$(awk "BEGIN { printf \"%.1f\", $cr_tokens * 100.0 / $total_input_tokens }")
		local cache_savings
		cache_savings=$(awk "BEGIN { printf \"%.4f\", ($cr_tokens / 1000000.0 * 3.0) - $cr_cost }")
		echo "  Cache Efficiency:"
		echo "    Cache hit rate:    ${cache_hit_pct}% of input tokens served from cache"
		echo "    Est. savings:      \$${cache_savings} (vs full-price input)"
	fi
	echo ""

	return 0
}

# Show usage trends over time
cmd_trend() {
	local days=$DEFAULT_LOOKBACK_DAYS
	local json_flag=false
	local project_filter="" granularity="daily"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-$DEFAULT_LOOKBACK_DAYS}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		--project)
			project_filter="${2:-}"
			shift 2
			;;
		--weekly)
			granularity="weekly"
			shift
			;;
		--hourly)
			granularity="hourly"
			shift
			;;
		*) shift ;;
		esac
	done

	cmd_ingest --quiet 2>/dev/null || true

	local where_clause="WHERE recorded_at >= datetime('now', '-${days} days')"
	[[ -n "$project_filter" ]] && where_clause="$where_clause AND project = '$(sql_escape "$project_filter")'"

	local date_expr
	case "$granularity" in
	hourly) date_expr="strftime('%Y-%m-%d %H:00', recorded_at)" ;;
	weekly) date_expr="strftime('%Y-W%W', recorded_at)" ;;
	*) date_expr="date(recorded_at)" ;;
	esac

	if [[ "$json_flag" == "true" ]]; then
		db_query_json "
			SELECT
				$date_expr as period,
				COUNT(*) as requests,
				SUM(input_tokens + output_tokens) as tokens,
				SUM(cache_read_tokens) as cache_tokens,
				ROUND(SUM(cost_total), 4) as cost_usd,
				COUNT(DISTINCT session_id) as sessions,
				ROUND(AVG(CASE WHEN ttft_ms > 0 THEN ttft_ms END), 0) as avg_ttft_ms
			FROM llm_requests
			$where_clause
			GROUP BY period
			ORDER BY period;
		"
		return 0
	fi

	echo ""
	echo "Usage Trend (last ${days} days, ${granularity})"
	echo "================================================"
	echo ""
	printf "  %-14s %-8s %-12s %-12s %-10s %-8s\n" \
		"Period" "Reqs" "Tokens" "Cache Tok" "Cost" "Sessions"
	printf "  %-14s %-8s %-12s %-12s %-10s %-8s\n" \
		"--------------" "----" "----------" "----------" "------" "--------"

	db_query "
		SELECT
			$date_expr,
			COUNT(*),
			SUM(input_tokens + output_tokens),
			SUM(cache_read_tokens),
			ROUND(SUM(cost_total), 4),
			COUNT(DISTINCT session_id)
		FROM llm_requests
		$where_clause
		GROUP BY $date_expr
		ORDER BY $date_expr;
	" | while IFS='|' read -r period reqs tokens cache cost sess; do
		printf "  %-14s %-8s %-12s %-12s \$%-9s %-8s\n" \
			"$period" "$reqs" "$tokens" "$cache" "$cost" "$sess"
	done
	echo ""

	# Show sparkline-style cost trend (simple bar chart)
	echo "  Cost per day:"
	local max_cost
	max_cost=$(db_query "
		SELECT ROUND(MAX(daily_cost), 4) FROM (
			SELECT SUM(cost_total) as daily_cost
			FROM llm_requests
			$where_clause
			GROUP BY date(recorded_at)
		);
	") || max_cost=1
	max_cost="${max_cost:-1}"

	db_query "
		SELECT date(recorded_at), ROUND(SUM(cost_total), 4)
		FROM llm_requests
		$where_clause
		GROUP BY date(recorded_at)
		ORDER BY date(recorded_at)
		LIMIT 14;
	" | while IFS='|' read -r dt cost; do
		local bar_len
		bar_len=$(awk "BEGIN { if ($max_cost > 0) printf \"%d\", ($cost / $max_cost * 30); else print 0 }")
		local bar=""
		local i
		for ((i = 0; i < bar_len; i++)); do
			bar="${bar}#"
		done
		printf "    %s  \$%-8s %s\n" "$dt" "$cost" "$bar"
	done
	echo ""

	return 0
}

# Manually record an LLM request
cmd_record() {
	local provider="" model="" input_tokens=0 output_tokens=0
	local cache_read_tokens=0 cache_write_tokens=0
	local session_id="" project="" stop_reason="" ttft_ms=0
	local error_message=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="${2:-}"
			shift 2
			;;
		--model)
			model="${2:-}"
			shift 2
			;;
		--input-tokens)
			input_tokens="${2:-0}"
			shift 2
			;;
		--output-tokens)
			output_tokens="${2:-0}"
			shift 2
			;;
		--cache-read)
			cache_read_tokens="${2:-0}"
			shift 2
			;;
		--cache-write)
			cache_write_tokens="${2:-0}"
			shift 2
			;;
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--project)
			project="${2:-}"
			shift 2
			;;
		--stop-reason)
			stop_reason="${2:-}"
			shift 2
			;;
		--ttft)
			ttft_ms="${2:-0}"
			shift 2
			;;
		--error)
			error_message="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$model" ]]; then
		print_error "Usage: observability-helper.sh record --model X [--provider Y] [--input-tokens N] [--output-tokens N] ..."
		return 1
	fi

	# Infer provider if not specified
	if [[ -z "$provider" ]]; then
		provider=$(get_provider_from_model "$model")
	fi

	local costs
	costs=$(calculate_costs "$input_tokens" "$output_tokens" "$cache_read_tokens" "$cache_write_tokens" "$model")
	local cost_input cost_output cost_cache_read cost_cache_write cost_total
	IFS='|' read -r cost_input cost_output cost_cache_read cost_cache_write cost_total <<<"$costs"

	db_query "
		INSERT INTO llm_requests (
			provider, model, session_id, project,
			input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
			cost_input, cost_output, cost_cache_read, cost_cache_write, cost_total,
			ttft_ms, stop_reason, error_message
		) VALUES (
			'$(sql_escape "$provider")',
			'$(sql_escape "$model")',
			'$(sql_escape "$session_id")',
			'$(sql_escape "$project")',
			$input_tokens, $output_tokens, $cache_read_tokens, $cache_write_tokens,
			$cost_input, $cost_output, $cost_cache_read, $cost_cache_write, $cost_total,
			$ttft_ms,
			'$(sql_escape "$stop_reason")',
			'$(sql_escape "$error_message")'
		);
	"

	print_success "Recorded: $model ($provider) - \$${cost_total}"
	return 0
}

# Sync parsed observability data to budget-tracker (t1100 integration)
cmd_sync_budget() {
	local days=1
	local quiet=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-1}"
			shift 2
			;;
		--quiet)
			quiet=true
			shift
			;;
		*) shift ;;
		esac
	done

	local budget_helper="${SCRIPT_DIR}/budget-tracker-helper.sh"
	if [[ ! -f "$budget_helper" ]]; then
		print_warning "budget-tracker-helper.sh not found — skipping budget sync"
		return 0
	fi

	local synced=0

	# Aggregate by provider+model+day and feed into budget tracker
	db_query "
		SELECT
			provider,
			model,
			date(recorded_at) as day,
			SUM(input_tokens),
			SUM(output_tokens),
			ROUND(SUM(cost_total), 6)
		FROM llm_requests
		WHERE recorded_at >= datetime('now', '-${days} days')
		GROUP BY provider, model, date(recorded_at);
	" | while IFS='|' read -r prov mdl _day inp outp cost; do
		[[ -z "$prov" ]] && continue
		bash "$budget_helper" record \
			--provider "$prov" \
			--model "$mdl" \
			--input-tokens "$inp" \
			--output-tokens "$outp" \
			--cost "$cost" 2>/dev/null || true
		synced=$((synced + 1))
	done

	if [[ "$quiet" != "true" ]]; then
		print_success "Synced observability data to budget tracker"
	fi

	return 0
}

# Prune old data
cmd_prune() {
	local days=$DEFAULT_PRUNE_DAYS

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-$DEFAULT_PRUNE_DAYS}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local before_count
	before_count=$(db_query "SELECT COUNT(*) FROM llm_requests;") || before_count=0

	db_query "
		DELETE FROM llm_requests WHERE recorded_at < datetime('now', '-${days} days');
		DELETE FROM parse_offsets WHERE last_parsed < datetime('now', '-${days} days');
	" || true

	local after_count
	after_count=$(db_query "SELECT COUNT(*) FROM llm_requests;") || after_count=0

	local pruned=$((before_count - after_count))
	print_info "Pruned $pruned records (kept last ${days} days, $after_count remaining)"

	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	echo ""
	echo "Observability Helper - LLM request tracking and analytics (t1307)"
	echo "================================================================="
	echo ""
	echo "Usage: observability-helper.sh [command] [options]"
	echo "  or:  aidevops stats [command] [options]"
	echo ""
	echo "Commands:"
	echo "  ingest              Parse new entries from Claude JSONL logs"
	echo "  summary             Show overall usage summary (default)"
	echo "  models              Show per-model breakdown"
	echo "  projects            Show per-project breakdown"
	echo "  costs               Show cost analysis with per-category breakdown"
	echo "  trend               Show usage trends over time"
	echo "  record              Manually record an LLM request"
	echo "  sync-budget         Sync data to budget-tracker (t1100)"
	echo "  prune               Remove old data (default: keep 90 days)"
	echo "  help                Show this help"
	echo ""
	echo "Options:"
	echo "  --json              Output in JSON format"
	echo "  --days N            Look back N days (default: 30)"
	echo "  --project X         Filter by project"
	echo "  --model X           Filter by model"
	echo "  --provider X        Filter by provider"
	echo "  --weekly            Use weekly granularity (trend command)"
	echo "  --hourly            Use hourly granularity (trend command)"
	echo ""
	echo "Record options:"
	echo "  --model X           Model name (required)"
	echo "  --provider X        Provider name (auto-detected from model)"
	echo "  --input-tokens N    Input token count"
	echo "  --output-tokens N   Output token count"
	echo "  --cache-read N      Cache read token count"
	echo "  --cache-write N     Cache write token count"
	echo "  --session X         Session ID"
	echo "  --project X         Project name"
	echo "  --stop-reason X     Stop reason (end_turn, max_tokens, etc.)"
	echo "  --ttft N            Time to first token in milliseconds"
	echo "  --error X           Error message"
	echo ""
	echo "Examples:"
	echo "  # Show usage summary for last 7 days"
	echo "  aidevops stats summary --days 7"
	echo ""
	echo "  # Show cost breakdown by model"
	echo "  aidevops stats costs --json"
	echo ""
	echo "  # Show daily trend for a specific project"
	echo "  aidevops stats trend --project aidevops --days 14"
	echo ""
	echo "  # Manually record a request"
	echo "  aidevops stats record --model claude-opus-4-6 --input-tokens 50000 --output-tokens 10000"
	echo ""
	echo "  # Sync to budget tracker"
	echo "  aidevops stats sync-budget --days 7"
	echo ""
	echo "Storage: $OBS_DB"
	echo ""
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-summary}"
	shift || true

	# Initialize DB for all commands except help
	if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
		init_db || return 1
	fi

	case "$command" in
	ingest | parse | import)
		cmd_ingest "$@"
		;;
	summary | s)
		cmd_summary "$@"
		;;
	models | model | m)
		cmd_models "$@"
		;;
	projects | project | p)
		cmd_projects "$@"
		;;
	costs | cost | c)
		cmd_costs "$@"
		;;
	trend | trends | t)
		cmd_trend "$@"
		;;
	record | r)
		cmd_record "$@"
		;;
	sync-budget | sync_budget | budget)
		cmd_sync_budget "$@"
		;;
	prune | cleanup)
		cmd_prune "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
