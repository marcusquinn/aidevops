#!/usr/bin/env bash
# generate-models-md.sh - Generate MODELS.md leaderboard from pattern-tracker and response-scoring data
# Part of t1012: live model leaderboard with success rates
#
# Usage:
#   generate-models-md.sh [--output PATH] [--quiet]
#   generate-models-md.sh help
#
# Data sources:
#   1. Model registry DB (model catalog, pricing, tiers)
#   2. Pattern-tracker (memory.db — success/failure rates by model)
#   3. Response-scoring DB (head-to-head contest results, quality scores)
#
# Output: Markdown file (default: MODELS.md in repo root) with:
#   - Model catalog table (all available models)
#   - Performance leaderboard (from pattern data)
#   - Contest results (from response-scoring data)
#   - Auto-generation timestamp

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

readonly MEMORY_DB="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"
readonly SCORING_DB="${SCORING_DB_OVERRIDE:-$HOME/.aidevops/.agent-workspace/response-scoring.db}"
readonly REGISTRY_DB="${MODEL_REGISTRY_DB:-$HOME/.aidevops/.agent-workspace/model-registry.db}"
readonly PATTERN_TYPES="'SUCCESS_PATTERN','FAILURE_PATTERN','WORKING_SOLUTION','FAILED_APPROACH','ERROR_FIX'"
readonly SUCCESS_TYPES="'SUCCESS_PATTERN','WORKING_SOLUTION'"
readonly FAILURE_TYPES="'FAILURE_PATTERN','FAILED_APPROACH','ERROR_FIX'"

# Defaults
OUTPUT_PATH=""
QUIET=0

log_info() {
	[[ "$QUIET" -eq 1 ]] && return 0
	echo -e "${BLUE}[INFO]${NC} $*"
	return 0
}
log_success() {
	[[ "$QUIET" -eq 1 ]] && return 0
	echo -e "${GREEN}[OK]${NC} $*"
	return 0
}
log_warn() {
	echo -e "${YELLOW}[WARN]${NC} $*"
	return 0
}
log_error() {
	echo -e "${RED}[ERROR]${NC} $*" >&2
	return 0
}

#######################################
# Find the repo root for default output path
# Returns: repo root path or empty string
#######################################
find_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || echo ""
	return 0
}

#######################################
# Check if a SQLite database exists and has data
# Arguments: db_path, table_name
# Returns: 0 if table has rows, 1 otherwise
#######################################
db_has_data() {
	local db_path="$1"
	local table_name="$2"

	[[ -f "$db_path" ]] || return 1
	local count
	count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM $table_name;" 2>/dev/null) || return 1
	[[ "$count" -gt 0 ]] && return 0
	return 1
}

#######################################
# Generate the model catalog section from registry DB
# Outputs: markdown table to stdout
#######################################
generate_catalog() {
	if ! [[ -f "$REGISTRY_DB" ]]; then
		echo "No model registry database found."
		echo ""
		return 0
	fi

	local count
	count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM models;" 2>/dev/null) || count=0
	if [[ "$count" -eq 0 ]]; then
		echo "No models registered yet."
		echo ""
		return 0
	fi

	echo "| Model | Provider | Tier | Context | Input/1M | Output/1M |"
	echo "|-------|----------|------|---------|----------|-----------|"

	sqlite3 -separator '|' "$REGISTRY_DB" "
        SELECT
            model_id,
            provider,
            CASE tier
                WHEN 'high' THEN 'opus'
                WHEN 'medium' THEN 'sonnet'
                WHEN 'low' THEN 'haiku'
                ELSE tier
            END,
            CASE
                WHEN context_window >= 1000000 THEN (context_window / 1000000) || 'M'
                ELSE (context_window / 1000) || 'K'
            END,
            printf('\$%.2f', input_price),
            printf('\$%.2f', output_price)
        FROM models
        ORDER BY
            CASE tier WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
            provider,
            model_id;
    " 2>/dev/null | while IFS='|' read -r model provider tier ctx input output; do
		echo "| $model | $provider | $tier | $ctx | $input | $output |"
	done

	echo ""
	return 0
}

#######################################
# Generate the routing tiers section from subagent_models
# Outputs: markdown table to stdout
#######################################
generate_routing_tiers() {
	if ! [[ -f "$REGISTRY_DB" ]]; then
		return 0
	fi

	local count
	count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM subagent_models;" 2>/dev/null) || count=0
	if [[ "$count" -eq 0 ]]; then
		return 0
	fi

	echo "## Routing Tiers"
	echo ""
	echo "Active model assignments for each dispatch tier:"
	echo ""
	echo "| Tier | Primary Model | Relative Cost |"
	echo "|------|---------------|---------------|"

	sqlite3 -separator '|' "$REGISTRY_DB" "
        SELECT
            sm.tier,
            sm.model_id,
            CASE sm.tier
                WHEN 'haiku' THEN '~0.25x'
                WHEN 'flash' THEN '~0.20x'
                WHEN 'sonnet' THEN '1x (baseline)'
                WHEN 'pro' THEN '~1.5x'
                WHEN 'opus' THEN '~3x'
                ELSE '?'
            END
        FROM subagent_models sm
        ORDER BY
            CASE sm.tier
                WHEN 'haiku' THEN 1
                WHEN 'flash' THEN 2
                WHEN 'sonnet' THEN 3
                WHEN 'pro' THEN 4
                WHEN 'opus' THEN 5
                ELSE 6
            END;
    " 2>/dev/null | while IFS='|' read -r tier model cost; do
		echo "| $tier | $model | $cost |"
	done

	echo ""
	return 0
}

#######################################
# Generate the performance leaderboard from pattern-tracker data
# Outputs: markdown table to stdout
#######################################
generate_leaderboard() {
	if ! [[ -f "$MEMORY_DB" ]]; then
		echo "No pattern data available yet. Run tasks to build the leaderboard."
		echo ""
		return 0
	fi

	local total
	total=$(sqlite3 "$MEMORY_DB" "
        SELECT COUNT(*) FROM learnings
        WHERE type IN ($PATTERN_TYPES);
    " 2>/dev/null) || total=0

	if [[ "$total" -eq 0 ]]; then
		echo "No pattern data available yet. Run tasks to build the leaderboard."
		echo ""
		return 0
	fi

	echo "| Model | Tasks | Successes | Failures | Success Rate | Last Used |"
	echo "|-------|-------|-----------|----------|--------------|-----------|"

	# Query each known model tier
	local tiers="opus sonnet pro flash haiku"
	for tier in $tiers; do
		local successes failures last_used
		successes=$(sqlite3 "$MEMORY_DB" "
            SELECT COUNT(*) FROM learnings
            WHERE type IN ($SUCCESS_TYPES)
            AND (tags LIKE '%model:${tier}%' OR content LIKE '%[model:${tier}]%');
        " 2>/dev/null) || successes=0

		failures=$(sqlite3 "$MEMORY_DB" "
            SELECT COUNT(*) FROM learnings
            WHERE type IN ($FAILURE_TYPES)
            AND (tags LIKE '%model:${tier}%' OR content LIKE '%[model:${tier}]%');
        " 2>/dev/null) || failures=0

		local tasks_total=$((successes + failures))
		[[ "$tasks_total" -eq 0 ]] && continue

		local rate
		if [[ "$tasks_total" -gt 0 ]]; then
			rate=$(((successes * 100) / tasks_total))
		else
			rate=0
		fi

		last_used=$(sqlite3 "$MEMORY_DB" "
            SELECT SUBSTR(MAX(created_at), 1, 10) FROM learnings
            WHERE type IN ($PATTERN_TYPES)
            AND (tags LIKE '%model:${tier}%' OR content LIKE '%[model:${tier}]%');
        " 2>/dev/null) || last_used="—"
		[[ -z "$last_used" ]] && last_used="—"

		echo "| $tier | $tasks_total | $successes | $failures | ${rate}% | $last_used |"
	done

	echo ""
	return 0
}

#######################################
# Generate performance breakdown by task type
# Outputs: markdown table to stdout
#######################################
generate_task_type_breakdown() {
	if ! [[ -f "$MEMORY_DB" ]]; then
		return 0
	fi

	local total
	total=$(sqlite3 "$MEMORY_DB" "
        SELECT COUNT(*) FROM learnings
        WHERE type IN ($PATTERN_TYPES);
    " 2>/dev/null) || total=0
	[[ "$total" -eq 0 ]] && return 0

	local has_data=0
	local task_types="feature bugfix refactor code-review docs testing deployment security architecture planning research content seo"
	local rows=""

	for task_type in $task_types; do
		local successes failures
		successes=$(sqlite3 "$MEMORY_DB" "
            SELECT COUNT(*) FROM learnings
            WHERE type IN ($SUCCESS_TYPES)
            AND (tags LIKE '%${task_type}%' OR content LIKE '%[task:${task_type}]%');
        " 2>/dev/null) || successes=0

		failures=$(sqlite3 "$MEMORY_DB" "
            SELECT COUNT(*) FROM learnings
            WHERE type IN ($FAILURE_TYPES)
            AND (tags LIKE '%${task_type}%' OR content LIKE '%[task:${task_type}]%');
        " 2>/dev/null) || failures=0

		local task_total=$((successes + failures))
		[[ "$task_total" -eq 0 ]] && continue

		has_data=1
		local rate=$(((successes * 100) / task_total))
		rows+="| $task_type | $task_total | $successes | $failures | ${rate}% |"$'\n'
	done

	if [[ "$has_data" -eq 1 ]]; then
		echo "### By Task Type"
		echo ""
		echo "| Task Type | Tasks | Successes | Failures | Success Rate |"
		echo "|-----------|-------|-----------|----------|--------------|"
		printf '%s' "$rows"
		echo ""
	fi

	return 0
}

#######################################
# Generate contest results from response-scoring DB
# Outputs: markdown section to stdout
#######################################
generate_contest_results() {
	if ! [[ -f "$SCORING_DB" ]]; then
		echo "No contest data available yet. Run \`/compare-models\` or enable contest mode (t1011) to generate data."
		echo ""
		return 0
	fi

	local response_count
	response_count=$(sqlite3 "$SCORING_DB" "SELECT COUNT(*) FROM responses;" 2>/dev/null) || response_count=0
	if [[ "$response_count" -eq 0 ]]; then
		echo "No contest data available yet."
		echo ""
		return 0
	fi

	# Model quality scores (from scored responses)
	local score_count
	score_count=$(sqlite3 "$SCORING_DB" "SELECT COUNT(*) FROM scores;" 2>/dev/null) || score_count=0

	if [[ "$score_count" -gt 0 ]]; then
		echo "### Quality Scores"
		echo ""
		echo "Weighted average across all evaluated responses (correctness 30%, completeness 25%, code quality 25%, clarity 20%):"
		echo ""
		echo "| Model | Responses | Avg Score | Avg Time (s) |"
		echo "|-------|-----------|-----------|--------------|"

		sqlite3 -separator '|' "$SCORING_DB" "
            SELECT
                r.model_id,
                COUNT(DISTINCT r.response_id),
                printf('%.2f', AVG(ws.weighted_score)),
                printf('%.1f', AVG(r.response_time))
            FROM responses r
            JOIN (
                SELECT response_id,
                       SUM(CASE criterion
                           WHEN 'correctness'  THEN score * 0.30
                           WHEN 'completeness' THEN score * 0.25
                           WHEN 'code_quality' THEN score * 0.25
                           WHEN 'clarity'      THEN score * 0.20
                           ELSE 0 END) / NULLIF(
                           SUM(CASE criterion
                               WHEN 'correctness'  THEN 0.30
                               WHEN 'completeness' THEN 0.25
                               WHEN 'code_quality' THEN 0.25
                               WHEN 'clarity'      THEN 0.20
                               ELSE 0 END), 0) * 5.0 AS weighted_score
                FROM scores
                GROUP BY response_id
            ) ws ON r.response_id = ws.response_id
            GROUP BY r.model_id
            ORDER BY AVG(ws.weighted_score) DESC;
        " 2>/dev/null | while IFS='|' read -r model responses avg_score avg_time; do
			echo "| $model | $responses | $avg_score/5.0 | $avg_time |"
		done

		echo ""
	fi

	# Head-to-head comparison wins
	local comparison_count
	comparison_count=$(sqlite3 "$SCORING_DB" "SELECT COUNT(*) FROM comparisons;" 2>/dev/null) || comparison_count=0

	if [[ "$comparison_count" -gt 0 ]]; then
		echo "### Head-to-Head Results"
		echo ""
		echo "| Model | Wins | Contests |"
		echo "|-------|------|----------|"

		sqlite3 -separator '|' "$SCORING_DB" "
            SELECT
                r.model_id,
                COUNT(*),
                (SELECT COUNT(*) FROM comparisons c2
                 JOIN responses r2 ON c2.prompt_id = r2.prompt_id
                 WHERE r2.model_id = r.model_id) as total_contests
            FROM comparisons c
            JOIN responses r ON c.winner_id = r.response_id
            GROUP BY r.model_id
            ORDER BY COUNT(*) DESC;
        " 2>/dev/null | while IFS='|' read -r model wins contests; do
			echo "| $model | $wins | $contests |"
		done

		echo ""
	fi

	return 0
}

#######################################
# Generate the overall stats summary
# Outputs: markdown to stdout
#######################################
generate_stats_summary() {
	local pattern_total=0
	local scoring_total=0

	if [[ -f "$MEMORY_DB" ]]; then
		pattern_total=$(sqlite3 "$MEMORY_DB" "
            SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES);
        " 2>/dev/null) || pattern_total=0
	fi

	if [[ -f "$SCORING_DB" ]]; then
		scoring_total=$(sqlite3 "$SCORING_DB" "SELECT COUNT(*) FROM responses;" 2>/dev/null) || scoring_total=0
	fi

	echo "- **Pattern data points**: $pattern_total"
	echo "- **Scored responses**: $scoring_total"

	if [[ -f "$MEMORY_DB" ]] && [[ "$pattern_total" -gt 0 ]]; then
		local oldest newest
		oldest=$(sqlite3 "$MEMORY_DB" "
            SELECT SUBSTR(MIN(created_at), 1, 10) FROM learnings WHERE type IN ($PATTERN_TYPES);
        " 2>/dev/null) || oldest="—"
		newest=$(sqlite3 "$MEMORY_DB" "
            SELECT SUBSTR(MAX(created_at), 1, 10) FROM learnings WHERE type IN ($PATTERN_TYPES);
        " 2>/dev/null) || newest="—"
		echo "- **Date range**: $oldest to $newest"
	fi

	echo ""
	return 0
}

#######################################
# Main: assemble the full MODELS.md
#######################################
generate_models_md() {
	local output="$1"
	local timestamp
	timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	{
		echo "# Model Leaderboard"
		echo ""
		echo "Live performance data from pattern-tracker and response-scoring databases."
		echo "Auto-generated by \`generate-models-md.sh\` — do not edit manually."
		echo ""
		echo "**Last updated**: $timestamp"
		echo ""
		generate_stats_summary
		echo "## Available Models"
		echo ""
		generate_catalog
		generate_routing_tiers
		echo "## Performance Leaderboard"
		echo ""
		echo "Success rates from autonomous task execution (pattern-tracker data):"
		echo ""
		generate_leaderboard
		generate_task_type_breakdown
		echo "## Contest Results"
		echo ""
		echo "Quality evaluations from model comparison sessions (response-scoring data):"
		echo ""
		generate_contest_results
		echo "---"
		echo ""
		echo "*Generated by [aidevops](https://github.com/anomalyco/aidevops) t1012*"
	} >"$output"

	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	echo "generate-models-md.sh - Generate MODELS.md leaderboard"
	echo ""
	echo "Usage:"
	echo "  generate-models-md.sh [--output PATH] [--quiet]"
	echo "  generate-models-md.sh help"
	echo ""
	echo "Options:"
	echo "  --output PATH   Output file path (default: MODELS.md in repo root)"
	echo "  --quiet         Suppress info messages"
	echo ""
	echo "Data sources:"
	echo "  Model registry:    $REGISTRY_DB"
	echo "  Pattern tracker:   $MEMORY_DB"
	echo "  Response scoring:  $SCORING_DB"
	return 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
	--output)
		if [[ $# -lt 2 ]]; then
			log_error "--output requires a value"
			exit 1
		fi
		OUTPUT_PATH="$2"
		shift 2
		;;
	--quiet)
		QUIET=1
		shift
		;;
	help | --help | -h)
		cmd_help
		exit 0
		;;
	*)
		log_error "Unknown argument: $1"
		cmd_help
		exit 1
		;;
	esac
done

# Determine output path
if [[ -z "$OUTPUT_PATH" ]]; then
	local_repo_root="$(find_repo_root)"
	if [[ -n "$local_repo_root" ]]; then
		OUTPUT_PATH="${local_repo_root}/MODELS.md"
	else
		OUTPUT_PATH="./MODELS.md"
	fi
fi

# Verify sqlite3 is available
if ! command -v sqlite3 &>/dev/null; then
	log_error "sqlite3 is required but not found"
	exit 1
fi

log_info "Generating MODELS.md from live data..."
log_info "  Registry: $REGISTRY_DB"
log_info "  Patterns: $MEMORY_DB"
log_info "  Scoring:  $SCORING_DB"

generate_models_md "$OUTPUT_PATH"

log_success "Generated $OUTPUT_PATH"
