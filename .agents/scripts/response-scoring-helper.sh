#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2001

# Response Scoring Helper - Evaluate AI Model Responses Side-by-Side
# Stores prompts, responses, and structured scores in SQLite for comparison.
# Criteria: correctness, completeness, code quality, clarity (1-5 scale).
#
# Usage: response-scoring-helper.sh [command] [options]
#
# Commands:
#   init              Initialize the scoring database
#   prompt            Create or list evaluation prompts
#   record            Record a model response for a prompt
#   score             Score a recorded response on all criteria
#   compare           Compare scored responses side-by-side
#   leaderboard       Show aggregate model rankings
#   export            Export results as JSON or CSV
#   history           Show scoring history for a prompt
#   criteria          List scoring criteria and rubrics
#   help              Show this help
#
# Options:
#   --json            Output in JSON format
#   --csv             Output in CSV format
#   --quiet           Suppress informational output
#   --db PATH         Override database path
#
# Storage: ~/.aidevops/.agent-workspace/response-scoring.db
#
# Author: AI DevOps Framework
# Version: 1.1.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly SCORING_DIR="${HOME}/.aidevops/.agent-workspace"
readonly SCORING_DB_DEFAULT="${SCORING_DIR}/response-scoring.db"
SCORING_DB="${SCORING_DB_OVERRIDE:-$SCORING_DB_DEFAULT}"

# Pattern tracker integration (t1099)
readonly PATTERN_TRACKER="${SCRIPT_DIR}/pattern-tracker-helper.sh"
# Set SCORING_NO_PATTERN_SYNC=1 to disable automatic pattern sync
SCORING_NO_PATTERN_SYNC="${SCORING_NO_PATTERN_SYNC:-0}"

# Threshold for success/failure classification (score * 100, so 350 = 3.5/5.0)
readonly SUCCESS_THRESHOLD_SCORE_X100=350

# Scoring criteria definitions (name|weight|description|rubric_1|rubric_3|rubric_5)
readonly SCORING_CRITERIA="correctness|0.30|Factual accuracy and technical correctness|Major errors or incorrect approach|Mostly correct with minor issues|Fully correct, no errors
completeness|0.25|Coverage of all requirements and edge cases|Missing major requirements|Covers main requirements, misses edge cases|Comprehensive coverage including edge cases
code_quality|0.25|Clean code, best practices, maintainability|Poor structure, no error handling|Reasonable structure, some best practices|Clean, idiomatic, well-structured with error handling
clarity|0.20|Clear explanation, good formatting, readability|Confusing or poorly organized|Understandable but could be clearer|Crystal clear, well-organized, easy to follow"

# =============================================================================
# Database Setup
# =============================================================================

init_db() {
	mkdir -p "$SCORING_DIR" 2>/dev/null || true

	log_stderr "db init" sqlite3 "$SCORING_DB" "
        CREATE TABLE IF NOT EXISTS prompts (
            prompt_id      INTEGER PRIMARY KEY AUTOINCREMENT,
            title          TEXT NOT NULL,
            prompt_text    TEXT NOT NULL,
            category       TEXT DEFAULT 'general',
            difficulty     TEXT DEFAULT 'medium',
            created_at     TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS responses (
            response_id    INTEGER PRIMARY KEY AUTOINCREMENT,
            prompt_id      INTEGER NOT NULL,
            model_id       TEXT NOT NULL,
            response_text  TEXT NOT NULL,
            response_time  REAL DEFAULT 0.0,
            token_count    INTEGER DEFAULT 0,
            cost_estimate  REAL DEFAULT 0.0,
            recorded_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            FOREIGN KEY (prompt_id) REFERENCES prompts(prompt_id)
        );

        CREATE TABLE IF NOT EXISTS scores (
            score_id       INTEGER PRIMARY KEY AUTOINCREMENT,
            response_id    INTEGER NOT NULL,
            criterion      TEXT NOT NULL,
            score          INTEGER NOT NULL CHECK(score BETWEEN 1 AND 5),
            rationale      TEXT DEFAULT '',
            scored_by      TEXT DEFAULT 'human',
            scored_at      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            FOREIGN KEY (response_id) REFERENCES responses(response_id),
            UNIQUE(response_id, criterion, scored_by)
        );

        CREATE TABLE IF NOT EXISTS comparisons (
            comparison_id  INTEGER PRIMARY KEY AUTOINCREMENT,
            prompt_id      INTEGER NOT NULL,
            winner_id      INTEGER,
            notes          TEXT DEFAULT '',
            compared_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            FOREIGN KEY (prompt_id) REFERENCES prompts(prompt_id),
            FOREIGN KEY (winner_id) REFERENCES responses(response_id)
        );

        CREATE INDEX IF NOT EXISTS idx_responses_prompt ON responses(prompt_id);
        CREATE INDEX IF NOT EXISTS idx_responses_model ON responses(model_id);
        CREATE INDEX IF NOT EXISTS idx_scores_response ON scores(response_id);
    "
	return 0
}

ensure_db() {
	if [[ ! -f "$SCORING_DB" ]]; then
		init_db
	fi
	return 0
}

# =============================================================================
# Prompt Management
# =============================================================================

cmd_prompt() {
	local action="${1:-list}"
	shift || true

	ensure_db

	case "$action" in
	add)
		local title="" text="" category="general" difficulty="medium"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--title)
				title="$2"
				shift 2
				;;
			--text)
				text="$2"
				shift 2
				;;
			--file)
				if [[ -f "$2" ]]; then
					text=$(cat "$2")
				else
					print_error "File not found: $2"
					return 1
				fi
				shift 2
				;;
			--category)
				category="$2"
				shift 2
				;;
			--difficulty)
				difficulty="$2"
				shift 2
				;;
			*) shift ;;
			esac
		done

		if [[ -z "$title" || -z "$text" ]]; then
			print_error "Usage: response-scoring-helper.sh prompt add --title \"Title\" --text \"Prompt text\""
			return 1
		fi

		local escaped_title escaped_text
		escaped_title=$(echo "$title" | sed "s/'/''/g")
		escaped_text=$(echo "$text" | sed "s/'/''/g")

		local prompt_id
		prompt_id=$(log_stderr "prompt add" sqlite3 "$SCORING_DB" \
			"INSERT INTO prompts (title, prompt_text, category, difficulty) VALUES ('${escaped_title}', '${escaped_text}', '${category}', '${difficulty}'); SELECT last_insert_rowid();")

		print_success "Created prompt #${prompt_id}: ${title}"
		;;

	list)
		echo ""
		echo "Evaluation Prompts"
		echo "=================="
		echo ""
		printf "%-5s %-30s %-12s %-10s %-10s %s\n" \
			"ID" "Title" "Category" "Difficulty" "Responses" "Created"
		printf "%-5s %-30s %-12s %-10s %-10s %s\n" \
			"---" "-----" "--------" "----------" "---------" "-------"

		log_stderr "prompt list" sqlite3 -separator '|' "$SCORING_DB" \
			"SELECT p.prompt_id, p.title, p.category, p.difficulty,
                        COUNT(r.response_id), p.created_at
                 FROM prompts p
                 LEFT JOIN responses r ON p.prompt_id = r.prompt_id
                 GROUP BY p.prompt_id
                 ORDER BY p.created_at DESC;" | while IFS='|' read -r pid ptitle pcat pdiff rcount pcreated; do
			local short_title="${ptitle:0:28}"
			local short_date="${pcreated:0:10}"
			printf "%-5s %-30s %-12s %-10s %-10s %s\n" \
				"$pid" "$short_title" "$pcat" "$pdiff" "$rcount" "$short_date"
		done
		echo ""
		;;

	show)
		local prompt_id="${1:-}"
		if [[ -z "$prompt_id" ]]; then
			print_error "Usage: response-scoring-helper.sh prompt show <prompt_id>"
			return 1
		fi

		local result
		result=$(log_stderr "prompt show" sqlite3 -separator '|' "$SCORING_DB" \
			"SELECT title, prompt_text, category, difficulty, created_at
                 FROM prompts WHERE prompt_id = ${prompt_id};")

		if [[ -z "$result" ]]; then
			print_error "Prompt #${prompt_id} not found"
			return 1
		fi

		local ptitle ptext pcat pdiff pcreated
		IFS='|' read -r ptitle ptext pcat pdiff pcreated <<<"$result"

		echo ""
		echo "Prompt #${prompt_id}: ${ptitle}"
		echo "=========================="
		echo "Category: ${pcat} | Difficulty: ${pdiff} | Created: ${pcreated}"
		echo ""
		echo "--- Prompt Text ---"
		echo "$ptext"
		echo "---"
		echo ""
		;;

	*)
		print_error "Unknown prompt action: $action (use add, list, show)"
		return 1
		;;
	esac
	return 0
}

# =============================================================================
# Response Recording
# =============================================================================

cmd_record() {
	local prompt_id="" model_id="" response_text="" response_time="0" token_count="0" cost="0"

	ensure_db

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--prompt)
			prompt_id="$2"
			shift 2
			;;
		--model)
			model_id="$2"
			shift 2
			;;
		--text)
			response_text="$2"
			shift 2
			;;
		--file)
			if [[ -f "$2" ]]; then
				response_text=$(cat "$2")
			else
				print_error "File not found: $2"
				return 1
			fi
			shift 2
			;;
		--time)
			response_time="$2"
			shift 2
			;;
		--tokens)
			token_count="$2"
			shift 2
			;;
		--cost)
			cost="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$prompt_id" || -z "$model_id" || -z "$response_text" ]]; then
		print_error "Usage: response-scoring-helper.sh record --prompt <id> --model <model_id> --text \"response\" [--time <seconds>] [--tokens <count>] [--cost <usd>]"
		return 1
	fi

	# Verify prompt exists
	local prompt_exists
	prompt_exists=$(log_stderr "record check" sqlite3 "$SCORING_DB" \
		"SELECT COUNT(*) FROM prompts WHERE prompt_id = ${prompt_id};")
	if [[ "$prompt_exists" == "0" ]]; then
		print_error "Prompt #${prompt_id} not found"
		return 1
	fi

	local escaped_text escaped_model
	escaped_text=$(echo "$response_text" | sed "s/'/''/g")
	escaped_model=$(echo "$model_id" | sed "s/'/''/g")

	local response_id
	response_id=$(log_stderr "record insert" sqlite3 "$SCORING_DB" \
		"INSERT INTO responses (prompt_id, model_id, response_text, response_time, token_count, cost_estimate)
         VALUES (${prompt_id}, '${escaped_model}', '${escaped_text}', ${response_time}, ${token_count}, ${cost});
         SELECT last_insert_rowid();")

	print_success "Recorded response #${response_id} from ${model_id} for prompt #${prompt_id}"
	return 0
}

# =============================================================================
# Pattern Tracker Integration (t1099)
# Syncs scoring results to the shared pattern tracker DB for model routing.
# =============================================================================

# Validate that a value is a positive integer (for safe SQL interpolation).
# Returns 0 if valid, 1 if not.
_validate_integer() {
	local value="$1"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		return 0
	fi
	return 1
}

# Reusable SQL fragment for computing weighted average score from the scores table.
# Use with a correlated subquery: replace the outer response_id reference as needed.
# shellcheck disable=SC2034
readonly WEIGHTED_AVG_SQL="COALESCE((
                   SELECT ROUND(
                       SUM(CASE s.criterion
                           WHEN 'correctness' THEN s.score * 0.30
                           WHEN 'completeness' THEN s.score * 0.25
                           WHEN 'code_quality' THEN s.score * 0.25
                           WHEN 'clarity' THEN s.score * 0.20
                           ELSE s.score * 0.25
                       END)
                       / NULLIF(SUM(CASE s.criterion
                           WHEN 'correctness' THEN 0.30
                           WHEN 'completeness' THEN 0.25
                           WHEN 'code_quality' THEN 0.25
                           WHEN 'clarity' THEN 0.20
                           ELSE 0.25
                       END), 0)
                   , 2)
                   FROM scores s WHERE s.response_id = r.response_id
               ), 0)"

# Sync a scored response to the pattern tracker as a SUCCESS_PATTERN entry.
# This enables /route and /patterns to use A/B comparison data.
#
# Args:
#   $1 - response_id
#
# Reads model_id, prompt category, and weighted average from the scoring DB,
# then records a pattern with structured metadata.
_sync_score_to_patterns() {
	local response_id="$1"

	# Validate response_id is a safe integer before SQL interpolation
	if ! _validate_integer "$response_id"; then
		print_error "Invalid response_id: must be a positive integer"
		return 1
	fi

	# Skip if pattern sync is disabled or tracker not available
	if [[ "$SCORING_NO_PATTERN_SYNC" == "1" ]]; then
		return 0
	fi
	if [[ ! -x "$PATTERN_TRACKER" ]]; then
		return 0
	fi

	# Get response metadata including per-criterion scores and token usage (t1094)
	local result
	result=$(sqlite3 -separator '|' "$SCORING_DB" "
        SELECT r.model_id, p.category, p.difficulty,
               ${WEIGHTED_AVG_SQL} as weighted_avg,
               r.token_count, r.cost_estimate,
               (SELECT score FROM scores s WHERE s.response_id = r.response_id AND s.criterion = 'correctness' LIMIT 1) as corr,
               (SELECT score FROM scores s WHERE s.response_id = r.response_id AND s.criterion = 'completeness' LIMIT 1) as comp,
               (SELECT score FROM scores s WHERE s.response_id = r.response_id AND s.criterion = 'code_quality' LIMIT 1) as cq,
               (SELECT score FROM scores s WHERE s.response_id = r.response_id AND s.criterion = 'clarity' LIMIT 1) as clar
        FROM responses r
        JOIN prompts p ON r.prompt_id = p.prompt_id
        WHERE r.response_id = ${response_id};
    ") || return 0

	if [[ -z "$result" ]]; then
		return 0
	fi

	local model_id category difficulty weighted_avg token_count _cost_estimate
	local score_corr score_comp score_cq score_clar
	IFS='|' read -r model_id category difficulty weighted_avg token_count _cost_estimate \
		score_corr score_comp score_cq score_clar <<<"$result"

	# Skip if no scores recorded yet (weighted_avg = 0)
	if [[ "$weighted_avg" == "0" || "$weighted_avg" == "0.0" ]]; then
		return 0
	fi

	# Map full model name to tier for pattern tracker
	local model_tier
	model_tier=$(_model_to_tier "$model_id")

	# Use the unified score command (t1094) for richer metadata capture
	local score_args=(
		--model "$model_tier"
		--task-type "$category"
		--weighted-avg "$weighted_avg"
		--source "response-scoring"
		--description "Response scoring: ${model_id} scored ${weighted_avg}/5.0 on ${difficulty} ${category} task"
	)
	[[ -n "$score_corr" && "$score_corr" != "0" ]] && score_args+=(--correctness "$score_corr")
	[[ -n "$score_comp" && "$score_comp" != "0" ]] && score_args+=(--completeness "$score_comp")
	[[ -n "$score_cq" && "$score_cq" != "0" ]] && score_args+=(--code-quality "$score_cq")
	[[ -n "$score_clar" && "$score_clar" != "0" ]] && score_args+=(--clarity "$score_clar")
	if [[ -n "$token_count" ]] && [[ "$token_count" =~ ^[0-9]+$ ]] && [[ "$token_count" -gt 0 ]]; then
		score_args+=(--tokens-out "$token_count")
	fi

	# Record via unified score command (fire-and-forget)
	"$PATTERN_TRACKER" score "${score_args[@]}" >/dev/null 2>&1 || true

	return 0
}

# Sync a comparison winner to the pattern tracker.
# Records which model won a head-to-head comparison.
#
# Args:
#   $1 - prompt_id
#   $2 - winner model_id
#   $3 - winner weighted_avg
#   $4 - total responses compared
_sync_comparison_to_patterns() {
	local prompt_id="$1"
	local winner_model="$2"
	local winner_avg="$3"
	local compared_count="$4"

	# Validate prompt_id is a safe integer before SQL interpolation
	if ! _validate_integer "$prompt_id"; then
		return 1
	fi

	if [[ "$SCORING_NO_PATTERN_SYNC" == "1" ]]; then
		return 0
	fi
	if [[ ! -x "$PATTERN_TRACKER" ]]; then
		return 0
	fi

	local category
	category=$(sqlite3 "$SCORING_DB" \
		"SELECT category FROM prompts WHERE prompt_id = ${prompt_id};") || return 0

	local winner_tier
	winner_tier=$(_model_to_tier "$winner_model")

	# Get loser models for this prompt (all non-winner responses) (t1094)
	local loser_args=()
	while IFS='|' read -r loser_model_id _loser_avg; do
		local loser_tier
		loser_tier=$(_model_to_tier "$loser_model_id")
		loser_args+=(--loser "$loser_tier")
	done < <(sqlite3 -separator '|' "$SCORING_DB" "
		SELECT r.model_id, ${WEIGHTED_AVG_SQL} as wavg
		FROM responses r
		WHERE r.prompt_id = ${prompt_id}
		AND r.model_id != '$(echo "$winner_model" | sed "s/'/''/g")'
		ORDER BY wavg DESC;
	" 2>/dev/null || true)

	# Use the unified ab-compare command (t1094)
	"$PATTERN_TRACKER" ab-compare \
		--winner "$winner_tier" \
		"${loser_args[@]}" \
		--task-type "${category:-general}" \
		--winner-score "$winner_avg" \
		--models-compared "$compared_count" \
		--source "response-scoring" \
		>/dev/null 2>&1 || true

	return 0
}

# Map a full model name (e.g., "claude-sonnet-4") to a tier (e.g., "sonnet").
# Falls back to the full name if no tier match is found.
_model_to_tier() {
	local model_id="$1"

	# Order: specific patterns first, then generic fallbacks
	case "$model_id" in
	*haiku*) echo "haiku" ;;
	*opus*) echo "opus" ;;
	*sonnet*) echo "sonnet" ;;
	*gemini*pro*) echo "pro" ;;
	*gemini*flash*) echo "flash" ;;
	*gemini*) echo "sonnet" ;;
	*gpt-4o*) echo "pro" ;;
	*gpt-4*) echo "pro" ;;
	*gpt-3*) echo "flash" ;;
	*o1* | *o3*) echo "pro" ;;
	*pro*) echo "pro" ;;
	*flash*) echo "flash" ;;
	*) echo "$model_id" ;;
	esac
	return 0
}

# =============================================================================
# Scoring
# =============================================================================

cmd_score() {
	local response_id="" scored_by="human"
	local correctness="" completeness="" code_quality="" clarity=""

	ensure_db

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--response)
			response_id="$2"
			shift 2
			;;
		--correctness)
			correctness="$2"
			shift 2
			;;
		--completeness)
			completeness="$2"
			shift 2
			;;
		--code-quality)
			code_quality="$2"
			shift 2
			;;
		--clarity)
			clarity="$2"
			shift 2
			;;
		--scored-by)
			scored_by="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$response_id" ]]; then
		print_error "Usage: response-scoring-helper.sh score --response <id> --correctness <1-5> --completeness <1-5> --code-quality <1-5> --clarity <1-5> [--scored-by <name>]"
		return 1
	fi

	# Verify response exists
	local response_exists
	response_exists=$(log_stderr "score check" sqlite3 "$SCORING_DB" \
		"SELECT COUNT(*) FROM responses WHERE response_id = ${response_id};")
	if [[ "$response_exists" == "0" ]]; then
		print_error "Response #${response_id} not found"
		return 1
	fi

	local escaped_by
	escaped_by=$(echo "$scored_by" | sed "s/'/''/g")

	# Validate and insert each score
	local criteria_scores="correctness:${correctness} completeness:${completeness} code_quality:${code_quality} clarity:${clarity}"
	local any_scored=false

	for pair in $criteria_scores; do
		local criterion="${pair%%:*}"
		local value="${pair#*:}"

		if [[ -z "$value" ]]; then
			continue
		fi

		# Validate score range
		if [[ "$value" -lt 1 || "$value" -gt 5 ]] 2>/dev/null; then
			print_error "Score for ${criterion} must be 1-5, got: ${value}"
			return 1
		fi

		log_stderr "score insert" sqlite3 "$SCORING_DB" \
			"INSERT OR REPLACE INTO scores (response_id, criterion, score, scored_by)
             VALUES (${response_id}, '${criterion}', ${value}, '${escaped_by}');"
		any_scored=true
	done

	if [[ "$any_scored" != "true" ]]; then
		print_error "No scores provided. Use --correctness, --completeness, --code-quality, --clarity (1-5)"
		return 1
	fi

	print_success "Scored response #${response_id}"

	# Show the scores
	_show_response_scores "$response_id"

	# Sync to pattern tracker for model routing (t1099)
	_sync_score_to_patterns "$response_id"

	return 0
}

# Display scores for a single response
_show_response_scores() {
	local response_id="$1"

	local model_id
	model_id=$(sqlite3 "$SCORING_DB" \
		"SELECT model_id FROM responses WHERE response_id = ${response_id};")

	echo ""
	echo "Scores for response #${response_id} (${model_id}):"
	printf "  %-15s %-7s %s\n" "Criterion" "Score" "Rating"
	printf "  %-15s %-7s %s\n" "---------" "-----" "------"

	local weighted_total=0
	local weight_sum=0

	while IFS='|' read -r criterion score; do
		local rating weight
		rating=$(_score_to_rating "$score")
		weight=$(_get_criterion_weight "$criterion")

		printf "  %-15s %-7s %s\n" "$criterion" "${score}/5" "$rating"

		# Accumulate weighted score using awk for float math
		weighted_total=$(awk "BEGIN{printf \"%.4f\", $weighted_total + ($score * $weight)}")
		weight_sum=$(awk "BEGIN{printf \"%.4f\", $weight_sum + $weight}")
	done < <(sqlite3 -separator '|' "$SCORING_DB" \
		"SELECT criterion, score FROM scores
         WHERE response_id = ${response_id}
         ORDER BY criterion;")

	if [[ "$weight_sum" != "0" && "$weight_sum" != "0.0000" ]]; then
		local weighted_avg
		weighted_avg=$(awk "BEGIN{printf \"%.2f\", $weighted_total / $weight_sum}")
		echo ""
		echo "  Weighted average: ${weighted_avg}/5.00"
	fi
	echo ""
	return 0
}

# Convert numeric score to human-readable rating
_score_to_rating() {
	local score="$1"
	case "$score" in
	1) echo "Poor" ;;
	2) echo "Below Average" ;;
	3) echo "Average" ;;
	4) echo "Good" ;;
	5) echo "Excellent" ;;
	*) echo "Unknown" ;;
	esac
	return 0
}

# Get weight for a criterion from SCORING_CRITERIA
_get_criterion_weight() {
	local criterion="$1"
	case "$criterion" in
	correctness) echo "0.30" ;;
	completeness) echo "0.25" ;;
	code_quality) echo "0.25" ;;
	clarity) echo "0.20" ;;
	*) echo "0.25" ;;
	esac
	return 0
}

# =============================================================================
# Side-by-Side Comparison
# =============================================================================

cmd_compare() {
	local prompt_id="" json_flag=false

	ensure_db

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--prompt)
			prompt_id="$2"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$prompt_id" ]]; then
		print_error "Usage: response-scoring-helper.sh compare --prompt <id> [--json]"
		return 1
	fi

	# Get prompt info
	local prompt_title
	prompt_title=$(sqlite3 "$SCORING_DB" \
		"SELECT title FROM prompts WHERE prompt_id = ${prompt_id};" 2>/dev/null)
	if [[ -z "$prompt_title" ]]; then
		print_error "Prompt #${prompt_id} not found"
		return 1
	fi

	# Get all responses for this prompt with their weighted scores
	local responses
	responses=$(sqlite3 -separator '|' "$SCORING_DB" "
        SELECT r.response_id, r.model_id, r.response_time, r.token_count, r.cost_estimate,
               ${WEIGHTED_AVG_SQL} as weighted_avg,
               (SELECT GROUP_CONCAT(s2.criterion || ':' || s2.score, ',')
                FROM scores s2 WHERE s2.response_id = r.response_id) as score_detail
        FROM responses r
        WHERE r.prompt_id = ${prompt_id}
        ORDER BY weighted_avg DESC;
    ")

	if [[ -z "$responses" ]]; then
		print_warning "No responses recorded for prompt #${prompt_id}"
		return 0
	fi

	if [[ "$json_flag" == "true" ]]; then
		_compare_json "$prompt_id" "$prompt_title" "$responses"
	else
		_compare_table "$prompt_id" "$prompt_title" "$responses"
	fi

	# Sync comparison winner to pattern tracker (t1099)
	local winner_line
	winner_line=$(echo "$responses" | head -1)
	if [[ -n "$winner_line" ]]; then
		local winner_model winner_avg compared_count
		winner_model=$(echo "$winner_line" | cut -d'|' -f2)
		winner_avg=$(echo "$winner_line" | cut -d'|' -f6)
		compared_count=$(echo "$responses" | wc -l | tr -d ' ')
		if [[ "$compared_count" -gt 1 ]]; then
			_sync_comparison_to_patterns "$prompt_id" "$winner_model" "$winner_avg" "$compared_count"
		fi
	fi

	return 0
}

_compare_table() {
	local prompt_id="$1"
	local prompt_title="$2"
	local responses="$3"

	echo ""
	echo "Response Comparison: ${prompt_title} (Prompt #${prompt_id})"
	printf '=%.0s' {1..70}
	echo ""
	echo ""

	# Header
	printf "%-4s %-22s %-6s %-6s %-6s %-6s %-8s %-8s\n" \
		"Rank" "Model" "Corr." "Comp." "Code" "Clar." "Avg" "Time(s)"
	printf "%-4s %-22s %-6s %-6s %-6s %-6s %-8s %-8s\n" \
		"----" "-----" "-----" "-----" "----" "-----" "-------" "-------"

	local rank=0
	echo "$responses" | while IFS='|' read -r rid model_id rtime tokens cost wavg score_detail; do
		rank=$((rank + 1))

		# Parse individual scores from score_detail
		local corr="" comp="" code="" clar=""
		if [[ -n "$score_detail" ]]; then
			corr=$(echo "$score_detail" | tr ',' '\n' | grep "^correctness:" | cut -d: -f2)
			comp=$(echo "$score_detail" | tr ',' '\n' | grep "^completeness:" | cut -d: -f2)
			code=$(echo "$score_detail" | tr ',' '\n' | grep "^code_quality:" | cut -d: -f2)
			clar=$(echo "$score_detail" | tr ',' '\n' | grep "^clarity:" | cut -d: -f2)
		fi

		printf "%-4s %-22s %-6s %-6s %-6s %-6s %-8s %-8s\n" \
			"#${rank}" "$model_id" \
			"${corr:-  -}" "${comp:-  -}" "${code:-  -}" "${clar:-  -}" \
			"${wavg:-  -}" "${rtime:-  -}"
	done

	# Show winner
	local winner
	winner=$(echo "$responses" | head -1)
	if [[ -n "$winner" ]]; then
		local winner_model winner_avg
		winner_model=$(echo "$winner" | cut -d'|' -f2)
		winner_avg=$(echo "$winner" | cut -d'|' -f6)
		echo ""
		echo "Winner: ${winner_model} (weighted avg: ${winner_avg}/5.00)"
	fi

	echo ""
	echo "Criteria weights: Correctness 30%, Completeness 25%, Code Quality 25%, Clarity 20%"
	echo ""
	return 0
}

_compare_json() {
	local prompt_id="$1"
	local prompt_title="$2"
	local responses="$3"

	local json_entries=()
	local rank=0

	while IFS='|' read -r rid model_id rtime tokens cost wavg score_detail; do
		rank=$((rank + 1))

		local corr="null" comp="null" code="null" clar="null"
		if [[ -n "$score_detail" ]]; then
			local val
			val=$(echo "$score_detail" | tr ',' '\n' | grep "^correctness:" | cut -d: -f2)
			[[ -n "$val" ]] && corr="$val"
			val=$(echo "$score_detail" | tr ',' '\n' | grep "^completeness:" | cut -d: -f2)
			[[ -n "$val" ]] && comp="$val"
			val=$(echo "$score_detail" | tr ',' '\n' | grep "^code_quality:" | cut -d: -f2)
			[[ -n "$val" ]] && code="$val"
			val=$(echo "$score_detail" | tr ',' '\n' | grep "^clarity:" | cut -d: -f2)
			[[ -n "$val" ]] && clar="$val"
		fi

		json_entries+=("{\"rank\":${rank},\"response_id\":${rid},\"model\":\"${model_id}\",\"scores\":{\"correctness\":${corr},\"completeness\":${comp},\"code_quality\":${code},\"clarity\":${clar}},\"weighted_avg\":${wavg:-0},\"response_time\":${rtime:-0},\"tokens\":${tokens:-0},\"cost\":${cost:-0}}")
	done <<<"$responses"

	local escaped_title
	escaped_title=$(echo "$prompt_title" | sed 's/"/\\"/g')
	echo "{\"prompt_id\":${prompt_id},\"title\":\"${escaped_title}\",\"responses\":[$(
		IFS=,
		echo "${json_entries[*]}"
	)]}"
	return 0
}

# =============================================================================
# Leaderboard
# =============================================================================

cmd_leaderboard() {
	local category="" json_flag=false limit=20

	ensure_db

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--category)
			category="$2"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local where_clause=""
	if [[ -n "$category" ]]; then
		where_clause="WHERE p.category = '${category}'"
	fi

	local results
	results=$(sqlite3 -separator '|' "$SCORING_DB" "
        SELECT r.model_id,
               COUNT(DISTINCT r.response_id) as response_count,
               ROUND(AVG((
                   SELECT SUM(CASE s.criterion
                       WHEN 'correctness' THEN s.score * 0.30
                       WHEN 'completeness' THEN s.score * 0.25
                       WHEN 'code_quality' THEN s.score * 0.25
                       WHEN 'clarity' THEN s.score * 0.20
                       ELSE s.score * 0.25
                   END)
                   / NULLIF(SUM(CASE s.criterion
                       WHEN 'correctness' THEN 0.30
                       WHEN 'completeness' THEN 0.25
                       WHEN 'code_quality' THEN 0.25
                       WHEN 'clarity' THEN 0.20
                       ELSE 0.25
                   END), 0)
                   FROM scores s WHERE s.response_id = r.response_id
               )), 2) as avg_weighted,
               ROUND(AVG(CASE WHEN s2.criterion = 'correctness' THEN s2.score END), 2) as avg_corr,
               ROUND(AVG(CASE WHEN s2.criterion = 'completeness' THEN s2.score END), 2) as avg_comp,
               ROUND(AVG(CASE WHEN s2.criterion = 'code_quality' THEN s2.score END), 2) as avg_code,
               ROUND(AVG(CASE WHEN s2.criterion = 'clarity' THEN s2.score END), 2) as avg_clar,
               ROUND(AVG(r.response_time), 1) as avg_time,
               ROUND(AVG(r.cost_estimate), 4) as avg_cost
        FROM responses r
        JOIN prompts p ON r.prompt_id = p.prompt_id
        LEFT JOIN scores s2 ON r.response_id = s2.response_id
        ${where_clause}
        GROUP BY r.model_id
        HAVING COUNT(DISTINCT s2.score_id) > 0
        ORDER BY avg_weighted DESC
        LIMIT ${limit};
    " 2>/dev/null)

	if [[ -z "$results" ]]; then
		print_warning "No scored responses found"
		return 0
	fi

	if [[ "$json_flag" == "true" ]]; then
		local json_entries=()
		local rank=0
		while IFS='|' read -r model rcount wavg acorr acomp acode aclar atime acost; do
			rank=$((rank + 1))
			json_entries+=("{\"rank\":${rank},\"model\":\"${model}\",\"responses\":${rcount},\"weighted_avg\":${wavg:-0},\"avg_correctness\":${acorr:-0},\"avg_completeness\":${acomp:-0},\"avg_code_quality\":${acode:-0},\"avg_clarity\":${aclar:-0},\"avg_time\":${atime:-0},\"avg_cost\":${acost:-0}}")
		done <<<"$results"
		echo "{\"leaderboard\":[$(
			IFS=,
			echo "${json_entries[*]}"
		)]}"
	else
		echo ""
		echo "Model Leaderboard"
		echo "=================="
		if [[ -n "$category" ]]; then
			echo "Category: ${category}"
		fi
		echo ""
		printf "%-4s %-22s %-5s %-6s %-6s %-6s %-6s %-8s %-8s\n" \
			"Rank" "Model" "N" "Corr." "Comp." "Code" "Clar." "Avg" "Time(s)"
		printf "%-4s %-22s %-5s %-6s %-6s %-6s %-6s %-8s %-8s\n" \
			"----" "-----" "---" "-----" "-----" "----" "-----" "-------" "-------"

		local rank=0
		echo "$results" | while IFS='|' read -r model rcount wavg acorr acomp acode aclar atime acost; do
			rank=$((rank + 1))
			printf "%-4s %-22s %-5s %-6s %-6s %-6s %-6s %-8s %-8s\n" \
				"#${rank}" "$model" "$rcount" \
				"${acorr:- -}" "${acomp:- -}" "${acode:- -}" "${aclar:- -}" \
				"${wavg:- -}" "${atime:- -}"
		done

		echo ""
		echo "Criteria weights: Correctness 30%, Completeness 25%, Code Quality 25%, Clarity 20%"
		echo "N = number of scored responses"
	fi
	echo ""
	return 0
}

# =============================================================================
# Export
# =============================================================================

cmd_export() {
	local format="json" prompt_id=""

	ensure_db

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			format="json"
			shift
			;;
		--csv)
			format="csv"
			shift
			;;
		--prompt)
			prompt_id="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local where_clause=""
	if [[ -n "$prompt_id" ]]; then
		where_clause="WHERE r.prompt_id = ${prompt_id}"
	fi

	if [[ "$format" == "csv" ]]; then
		echo "prompt_id,prompt_title,response_id,model_id,correctness,completeness,code_quality,clarity,weighted_avg,response_time,token_count,cost_estimate"
		sqlite3 -separator ',' "$SCORING_DB" "
            SELECT r.prompt_id, p.title, r.response_id, r.model_id,
                   MAX(CASE WHEN s.criterion = 'correctness' THEN s.score END),
                   MAX(CASE WHEN s.criterion = 'completeness' THEN s.score END),
                   MAX(CASE WHEN s.criterion = 'code_quality' THEN s.score END),
                   MAX(CASE WHEN s.criterion = 'clarity' THEN s.score END),
                   ROUND((
                       COALESCE(MAX(CASE WHEN s.criterion = 'correctness' THEN s.score END), 0) * 0.30 +
                       COALESCE(MAX(CASE WHEN s.criterion = 'completeness' THEN s.score END), 0) * 0.25 +
                       COALESCE(MAX(CASE WHEN s.criterion = 'code_quality' THEN s.score END), 0) * 0.25 +
                       COALESCE(MAX(CASE WHEN s.criterion = 'clarity' THEN s.score END), 0) * 0.20
                   ), 2),
                   r.response_time, r.token_count, r.cost_estimate
            FROM responses r
            JOIN prompts p ON r.prompt_id = p.prompt_id
            LEFT JOIN scores s ON r.response_id = s.response_id
            ${where_clause}
            GROUP BY r.response_id
            ORDER BY r.prompt_id, r.model_id;
        " 2>/dev/null
	else
		# JSON export
		sqlite3 -json "$SCORING_DB" "
            SELECT r.prompt_id, p.title as prompt_title, r.response_id, r.model_id,
                   MAX(CASE WHEN s.criterion = 'correctness' THEN s.score END) as correctness,
                   MAX(CASE WHEN s.criterion = 'completeness' THEN s.score END) as completeness,
                   MAX(CASE WHEN s.criterion = 'code_quality' THEN s.score END) as code_quality,
                   MAX(CASE WHEN s.criterion = 'clarity' THEN s.score END) as clarity,
                   r.response_time, r.token_count, r.cost_estimate, r.recorded_at
            FROM responses r
            JOIN prompts p ON r.prompt_id = p.prompt_id
            LEFT JOIN scores s ON r.response_id = s.response_id
            ${where_clause}
            GROUP BY r.response_id
            ORDER BY r.prompt_id, r.model_id;
        " 2>/dev/null
	fi
	return 0
}

# =============================================================================
# History
# =============================================================================

cmd_history() {
	local prompt_id="${1:-}"

	ensure_db

	if [[ -z "$prompt_id" ]]; then
		print_error "Usage: response-scoring-helper.sh history <prompt_id>"
		return 1
	fi

	local prompt_title
	prompt_title=$(sqlite3 "$SCORING_DB" \
		"SELECT title FROM prompts WHERE prompt_id = ${prompt_id};" 2>/dev/null)
	if [[ -z "$prompt_title" ]]; then
		print_error "Prompt #${prompt_id} not found"
		return 1
	fi

	echo ""
	echo "Scoring History: ${prompt_title} (Prompt #${prompt_id})"
	printf '=%.0s' {1..60}
	echo ""
	echo ""

	sqlite3 -separator '|' "$SCORING_DB" "
        SELECT r.response_id, r.model_id, s.criterion, s.score, s.scored_by, s.scored_at
        FROM responses r
        JOIN scores s ON r.response_id = s.response_id
        WHERE r.prompt_id = ${prompt_id}
        ORDER BY r.response_id, s.criterion;
    " 2>/dev/null | while IFS='|' read -r rid model criterion score scorer scored_at; do
		printf "  Response #%-4s %-20s %-15s %s/5  (by %s, %s)\n" \
			"$rid" "$model" "$criterion" "$score" "$scorer" "${scored_at:0:10}"
	done

	echo ""
	return 0
}

# =============================================================================
# Criteria Reference
# =============================================================================

cmd_criteria() {
	echo ""
	echo "Scoring Criteria Reference"
	echo "=========================="
	echo ""
	echo "All criteria scored on a 1-5 scale. Weighted average determines overall ranking."
	echo ""

	echo "$SCORING_CRITERIA" | while IFS='|' read -r name weight desc rubric1 rubric3 rubric5; do
		local pct
		pct=$(awk "BEGIN{printf \"%.0f\", $weight * 100}")
		echo "  ${name} (weight: ${pct}%)"
		echo "    ${desc}"
		echo "    1 = ${rubric1}"
		echo "    3 = ${rubric3}"
		echo "    5 = ${rubric5}"
		echo ""
	done

	echo "Weighted Average Formula:"
	echo "  (correctness * 0.30 + completeness * 0.25 + code_quality * 0.25 + clarity * 0.20)"
	echo ""
	echo "Scoring Tips:"
	echo "  - Score each criterion independently"
	echo "  - Use the full 1-5 range (avoid clustering at 3-4)"
	echo "  - Consider the prompt difficulty when scoring"
	echo "  - Multiple scorers can score the same response (tracked by scored_by)"
	echo ""
	return 0
}

# =============================================================================
# Pattern Sync (t1099) - Bulk sync existing scores to pattern tracker
# =============================================================================

cmd_sync() {
	local dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		*) shift ;;
		esac
	done

	ensure_db

	if [[ ! -x "$PATTERN_TRACKER" ]]; then
		print_error "Pattern tracker not found at: $PATTERN_TRACKER"
		return 1
	fi

	# Get all scored responses
	local scored_responses
	scored_responses=$(sqlite3 -separator '|' "$SCORING_DB" "
		SELECT DISTINCT r.response_id, r.model_id,
			   ${WEIGHTED_AVG_SQL} as weighted_avg,
			   p.category, p.difficulty
		FROM responses r
		JOIN prompts p ON r.prompt_id = p.prompt_id
		WHERE EXISTS (SELECT 1 FROM scores s WHERE s.response_id = r.response_id)
		ORDER BY r.response_id;
	")

	if [[ -z "$scored_responses" ]]; then
		print_warning "No scored responses to sync"
		return 0
	fi

	local synced=0 skipped=0
	while IFS='|' read -r rid model_id wavg category difficulty; do
		# Skip unscored
		if [[ "$wavg" == "0" || "$wavg" == "0.0" ]]; then
			skipped=$((skipped + 1))
			continue
		fi

		local outcome="success"
		local avg_int
		avg_int=$(awk "BEGIN{printf \"%d\", $wavg * 100}")
		if [[ "$avg_int" -lt "$SUCCESS_THRESHOLD_SCORE_X100" ]]; then
			outcome="failure"
		fi

		local model_tier
		model_tier=$(_model_to_tier "$model_id")

		if [[ "$dry_run" == "true" ]]; then
			echo "  [DRY-RUN] Would sync response #${rid}: ${model_id} (${model_tier}) ${wavg}/5.0 -> ${outcome}"
		else
			"$PATTERN_TRACKER" record \
				--outcome "$outcome" \
				--task-type "$category" \
				--model "$model_tier" \
				--description "Response scoring sync: ${model_id} scored ${wavg}/5.0 on ${difficulty} ${category} task" \
				--tags "response-scoring,scored-avg:${wavg},bulk-sync" \
				>/dev/null 2>&1 || true
		fi
		synced=$((synced + 1))
	done <<<"$scored_responses"

	if [[ "$dry_run" == "true" ]]; then
		echo ""
		print_success "Dry run complete: ${synced} responses would be synced, ${skipped} skipped"
	else
		print_success "Synced ${synced} scored responses to pattern tracker (${skipped} skipped)"
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	echo ""
	echo "Response Scoring Helper - Evaluate AI Model Responses Side-by-Side"
	echo "==================================================================="
	echo ""
	echo "Usage: response-scoring-helper.sh [command] [options]"
	echo ""
	echo "Commands:"
	echo "  init                        Initialize the scoring database"
	echo "  prompt add --title T --text P  Create an evaluation prompt"
	echo "  prompt list                 List all prompts"
	echo "  prompt show <id>            Show prompt details"
	echo "  record --prompt <id> --model <model> --text <response>"
	echo "                              Record a model response"
	echo "  score --response <id> --correctness <1-5> --completeness <1-5>"
	echo "        --code-quality <1-5> --clarity <1-5>"
	echo "                              Score a response on all criteria"
	echo "  compare --prompt <id>       Compare all responses for a prompt"
	echo "  leaderboard                 Show aggregate model rankings"
	echo "  export [--json|--csv]       Export all results"
	echo "  history <prompt_id>         Show scoring history"
	echo "  sync [--dry-run]            Sync all scores to pattern tracker (t1099)"
	echo "  criteria                    Show scoring criteria and rubrics"
	echo "  help                        Show this help"
	echo ""
	echo "Options:"
	echo "  --json          Output in JSON format"
	echo "  --csv           Output in CSV format (export only)"
	echo "  --prompt <id>   Filter by prompt ID"
	echo "  --category <c>  Filter leaderboard by category"
	echo "  --limit <n>     Limit leaderboard results (default: 20)"
	echo ""
	echo "Pattern Tracker Integration (t1099):"
	echo "  Scores are automatically synced to the pattern tracker when recorded."
	echo "  This feeds into model routing via /route and /patterns commands."
	echo "  Disable with: SCORING_NO_PATTERN_SYNC=1"
	echo "  Bulk sync existing data: response-scoring-helper.sh sync"
	echo ""
	echo "Workflow:"
	echo "  1. Create a prompt:  response-scoring-helper.sh prompt add --title \"FizzBuzz\" --text \"Write FizzBuzz in Python\""
	echo "  2. Record responses: response-scoring-helper.sh record --prompt 1 --model claude-sonnet-4 --text \"...\""
	echo "  3. Score responses:  response-scoring-helper.sh score --response 1 --correctness 5 --completeness 4 --code-quality 5 --clarity 4"
	echo "  4. Compare results:  response-scoring-helper.sh compare --prompt 1"
	echo "  5. View rankings:    response-scoring-helper.sh leaderboard"
	echo ""
	echo "Criteria: correctness (30%), completeness (25%), code quality (25%), clarity (20%)"
	echo "Database: ${SCORING_DB}"
	echo ""
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	init)
		init_db
		print_success "Scoring database initialized at ${SCORING_DB}"
		;;
	prompt)
		cmd_prompt "$@"
		;;
	record)
		cmd_record "$@"
		;;
	score)
		cmd_score "$@"
		;;
	compare)
		cmd_compare "$@"
		;;
	leaderboard)
		cmd_leaderboard "$@"
		;;
	export)
		cmd_export "$@"
		;;
	history)
		cmd_history "$@"
		;;
	sync)
		cmd_sync "$@"
		;;
	criteria)
		cmd_criteria
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
