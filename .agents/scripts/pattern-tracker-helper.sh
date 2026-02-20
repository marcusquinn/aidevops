#!/usr/bin/env bash
# pattern-tracker-helper.sh - Track and analyze success/failure patterns
# Extends memory-helper.sh with pattern-specific analysis and routing decisions
#
# Usage:
#   pattern-tracker-helper.sh record --outcome success --task-type "code-review" \
#       --model sonnet --description "Used structured review checklist"
#   pattern-tracker-helper.sh record --outcome failure --task-type "refactor" \
#       --model haiku --description "Haiku missed edge cases in complex refactor"
#   pattern-tracker-helper.sh analyze [--task-type TYPE] [--model MODEL]
#   pattern-tracker-helper.sh suggest "task description"
#   pattern-tracker-helper.sh recommend --task-type "bugfix"
#   pattern-tracker-helper.sh stats
#   pattern-tracker-helper.sh export [--format json|csv]
#   pattern-tracker-helper.sh report
#   pattern-tracker-helper.sh help

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

readonly SCRIPT_DIR
readonly MEMORY_HELPER="$SCRIPT_DIR/memory-helper.sh"
readonly MEMORY_DB="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"

# Model tier pricing (USD per 1M tokens) — input/output rates (t1114)
# Sources: Anthropic, OpenAI, Google official pricing pages (Feb 2026)
# Format: tier:input_per_1m:output_per_1m
readonly TIER_PRICING="haiku:0.80:4.00 flash:0.15:0.60 sonnet:3.00:15.00 pro:3.50:10.50 opus:15.00:75.00"

#######################################
# Calculate estimated cost in USD from token counts and model tier (t1114)
# $1: model_tier (haiku|flash|sonnet|pro|opus)
# $2: tokens_in (integer)
# $3: tokens_out (integer)
# Outputs: cost as decimal string (e.g. "0.012345") or empty if unknown
#######################################
calc_estimated_cost() {
	local tier="$1"
	local tokens_in="${2:-0}"
	local tokens_out="${3:-0}"

	if [[ -z "$tier" || "$tokens_in" -eq 0 && "$tokens_out" -eq 0 ]]; then
		return 0
	fi

	local pricing_entry=""
	local t
	for t in $TIER_PRICING; do
		if [[ "$t" == "${tier}:"* ]]; then
			pricing_entry="$t"
			break
		fi
	done

	if [[ -z "$pricing_entry" ]]; then
		return 0
	fi

	# Parse input_rate and output_rate from "tier:in:out"
	local input_rate output_rate
	input_rate=$(echo "$pricing_entry" | cut -d: -f2)
	output_rate=$(echo "$pricing_entry" | cut -d: -f3)

	# Calculate: (tokens_in * input_rate + tokens_out * output_rate) / 1_000_000
	awk -v ti="$tokens_in" -v to="$tokens_out" -v ir="$input_rate" -v outr="$output_rate" \
		'BEGIN { printf "%.6f", (ti * ir + to * outr) / 1000000 }'
	return 0
}

# All pattern-related memory types — sourced from shared-constants.sh
# Use via: local types_sql="$PATTERN_TYPES" then sqlite3 ... "$types_sql" ...
# Or inline in single-line sqlite3 calls where variable expansion works correctly
PATTERN_TYPES="$PATTERN_TYPES_SQL"
readonly PATTERN_TYPES

log_info() {
	echo -e "${BLUE}[INFO]${NC} $*"
	return 0
}
log_success() {
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

# Valid task types for pattern tracking
readonly VALID_TASK_TYPES="code-review refactor bugfix feature docs testing deployment security architecture planning research content seo"

# Valid model tiers
readonly VALID_MODELS="haiku flash sonnet pro opus"

#######################################
# Ensure memory database exists
# Returns 0 if DB exists, 1 if not
#######################################
ensure_db() {
	if [[ ! -f "$MEMORY_DB" ]]; then
		log_warn "No memory database found at: $MEMORY_DB"
		log_info "Run 'memory-helper.sh store' to initialize the database."
		return 1
	fi
	return 0
}

#######################################
# SQL-escape a value (double single quotes)
#######################################
sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
}

#######################################
# Record a success or failure pattern
#######################################
cmd_record() {
	local outcome=""
	local task_type=""
	local model=""
	local description=""
	local tags=""
	local task_id=""
	local duration=""
	local retries=""
	local strategy=""
	local quality=""
	local failure_mode=""
	local tokens_in=""
	local tokens_out=""
	local estimated_cost=""
	local quality_score=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--outcome)
			outcome="$2"
			shift 2
			;;
		--task-type)
			task_type="$2"
			shift 2
			;;
		--model)
			model="$2"
			shift 2
			;;
		--description | --desc)
			description="$2"
			shift 2
			;;
		--tags)
			tags="$2"
			shift 2
			;;
		--task-id)
			task_id="$2"
			shift 2
			;;
		--duration)
			duration="$2"
			shift 2
			;;
		--retries)
			retries="$2"
			shift 2
			;;
		--strategy)
			strategy="$2"
			shift 2
			;;
		--quality)
			quality="$2"
			shift 2
			;;
		--failure-mode)
			failure_mode="$2"
			shift 2
			;;
		--tokens-in)
			tokens_in="$2"
			shift 2
			;;
		--tokens-out)
			tokens_out="$2"
			shift 2
			;;
		--estimated-cost)
			estimated_cost="$2"
			shift 2
			;; # t1114: explicit cost override (USD)
		--quality-score)
			quality_score="$2"
			shift 2
			;; # t1096: 0|1|2
		*)
			if [[ -z "$description" ]]; then
				description="$1"
			fi
			shift
			;;
		esac
	done

	# Validate required fields
	if [[ -z "$outcome" ]]; then
		log_error "Outcome required: --outcome success|failure"
		return 1
	fi

	if [[ "$outcome" != "success" && "$outcome" != "failure" ]]; then
		log_error "Outcome must be 'success' or 'failure'"
		return 1
	fi

	if [[ -z "$description" ]]; then
		log_error "Description required: --description \"what happened\""
		return 1
	fi

	# Validate task type if provided
	if [[ -n "$task_type" ]]; then
		local type_check=" $task_type "
		if [[ ! " $VALID_TASK_TYPES " =~ $type_check ]]; then
			log_warn "Non-standard task type: $task_type (standard: $VALID_TASK_TYPES)"
		fi
	fi

	# Validate model if provided
	if [[ -n "$model" ]]; then
		local model_check=" $model "
		if [[ ! " $VALID_MODELS " =~ $model_check ]]; then
			log_warn "Non-standard model: $model (standard: $VALID_MODELS)"
		fi
	fi

	# Validate strategy if provided (t1095)
	if [[ -n "$strategy" ]]; then
		case "$strategy" in
		normal | prompt-repeat | escalated) ;;
		*)
			log_error "Invalid strategy: $strategy (use normal, prompt-repeat, or escalated)"
			return 1
			;;
		esac
	fi

	# Validate quality if provided (t1095)
	if [[ -n "$quality" ]]; then
		case "$quality" in
		ci-pass-first-try | ci-pass-after-fix | needs-human) ;;
		*)
			log_error "Invalid quality: $quality (use ci-pass-first-try, ci-pass-after-fix, or needs-human)"
			return 1
			;;
		esac
	fi

	# Build memory type
	local memory_type
	if [[ "$outcome" == "success" ]]; then
		memory_type="SUCCESS_PATTERN"
	else
		memory_type="FAILURE_PATTERN"
	fi

	# Validate failure_mode if provided (t1095/t1096)
	if [[ -n "$failure_mode" ]]; then
		case "$failure_mode" in
		hallucination | context-miss | incomplete | wrong-file | timeout | TRANSIENT | RESOURCE | LOGIC | BLOCKED | AMBIGUOUS | NONE) ;;
		*)
			log_warn "Non-standard failure_mode: $failure_mode (standard: hallucination, context-miss, incomplete, wrong-file, timeout, TRANSIENT, RESOURCE, LOGIC, BLOCKED, AMBIGUOUS, NONE)"
			;;
		esac
	fi

	# Validate quality_score if provided (t1096)
	if [[ -n "$quality_score" ]]; then
		case "$quality_score" in
		0 | 1 | 2) ;;
		*)
			log_warn "Non-standard quality_score: $quality_score (standard: 0=no_output 1=partial 2=complete)"
			;;
		esac
	fi

	# Validate token counts if provided (t1095)
	if [[ -n "$tokens_in" ]] && ! [[ "$tokens_in" =~ ^[0-9]+$ ]]; then
		log_error "tokens_in must be a positive integer"
		return 1
	fi
	if [[ -n "$tokens_out" ]] && ! [[ "$tokens_out" =~ ^[0-9]+$ ]]; then
		log_error "tokens_out must be a positive integer"
		return 1
	fi

	# Auto-calculate estimated_cost from token counts + model tier if not provided (t1114)
	if [[ -z "$estimated_cost" && -n "$model" && (-n "$tokens_in" || -n "$tokens_out") ]]; then
		estimated_cost=$(calc_estimated_cost "$model" "${tokens_in:-0}" "${tokens_out:-0}" 2>/dev/null || true)
	fi

	# Validate estimated_cost if provided
	if [[ -n "$estimated_cost" ]] && ! echo "$estimated_cost" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
		log_warn "estimated_cost must be a non-negative number — ignoring: $estimated_cost"
		estimated_cost=""
	fi

	# Build tags
	local all_tags="pattern"
	[[ -n "$task_type" ]] && all_tags="$all_tags,$task_type"
	[[ -n "$model" ]] && all_tags="$all_tags,model:$model"
	[[ -n "$task_id" ]] && all_tags="$all_tags,$task_id"
	[[ -n "$duration" ]] && all_tags="$all_tags,duration:$duration"
	[[ -n "$retries" ]] && all_tags="$all_tags,retries:$retries"
	[[ -n "$strategy" ]] && all_tags="$all_tags,strategy:$strategy"
	# t1096: include failure mode and quality score in tags for filtering
	[[ -n "$failure_mode" ]] && all_tags="$all_tags,failure_mode:$failure_mode"
	[[ -n "$quality_score" ]] && all_tags="$all_tags,quality:$quality_score"
	[[ -n "$tags" ]] && all_tags="$all_tags,$tags"

	# Build content with structured metadata
	local content="$description"
	[[ -n "$task_type" ]] && content="[task:$task_type] $content"
	[[ -n "$model" ]] && content="$content [model:$model]"
	[[ -n "$task_id" ]] && content="$content [id:$task_id]"
	[[ -n "$duration" ]] && content="$content [duration:${duration}s]"
	[[ -n "$retries" && "$retries" != "0" ]] && content="$content [retries:$retries]"
	# t1096: append failure mode and quality score to content
	[[ -n "$failure_mode" ]] && content="$content [fmode:$failure_mode]"
	[[ -n "$quality_score" ]] && content="$content [quality:$quality_score]"

	# Store via memory-helper.sh and capture the returned ID
	# The last line of store output is the bare mem_YYYYMMDDHHMMSS_hex ID.
	# Use grep to match the known ID format for robustness against output changes.
	local store_output mem_id
	store_output=$("$MEMORY_HELPER" store \
		--content "$content" \
		--type "$memory_type" \
		--tags "$all_tags" \
		--confidence "high" 2>/dev/null) || true
	mem_id=$(echo "$store_output" | grep -oE '^mem_[0-9]{14}_[0-9a-f]+$' | tail -1)

	# Store extended metadata in pattern_metadata table (t1095, t1114)
	if [[ -n "$mem_id" ]] && [[ "$mem_id" == mem_* ]]; then
		local sql_strategy="${strategy:-normal}"
		local sql_quality="NULL"
		local sql_failure_mode="NULL"
		local sql_tokens_in="NULL"
		local sql_tokens_out="NULL"
		local sql_estimated_cost="NULL"
		[[ -n "$quality" ]] && sql_quality="'$quality'"
		[[ -n "$failure_mode" ]] && sql_failure_mode="'$failure_mode'"
		[[ -n "$tokens_in" ]] && sql_tokens_in="$tokens_in"
		[[ -n "$tokens_out" ]] && sql_tokens_out="$tokens_out"
		[[ -n "$estimated_cost" ]] && sql_estimated_cost="$estimated_cost"

		sqlite3 "$MEMORY_DB" "INSERT OR REPLACE INTO pattern_metadata (id, strategy, quality, failure_mode, tokens_in, tokens_out, estimated_cost) VALUES ('$mem_id', '$sql_strategy', $sql_quality, $sql_failure_mode, $sql_tokens_in, $sql_tokens_out, $sql_estimated_cost);" 2>/dev/null || log_warn "Failed to store pattern metadata for $mem_id"
	fi

	log_success "Recorded $outcome pattern: $description"
	return 0
}

#######################################
# Analyze patterns from memory
# Uses direct SQLite for reliability
#######################################
cmd_analyze() {
	local task_type=""
	local model=""
	local limit=20

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task-type)
			task_type="$2"
			shift 2
			;;
		--model)
			model="$2"
			shift 2
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	ensure_db || return 0

	echo ""
	echo -e "${CYAN}=== Pattern Analysis ===${NC}"
	echo ""

	# Build WHERE clause for filtering
	local where_success="type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION')"
	local where_failure="type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX')"

	if [[ -n "$task_type" ]]; then
		local escaped_type
		escaped_type=$(sql_escape "$task_type")
		where_success="$where_success AND (tags LIKE '%${escaped_type}%' OR content LIKE '%task:${escaped_type}%')"
		where_failure="$where_failure AND (tags LIKE '%${escaped_type}%' OR content LIKE '%task:${escaped_type}%')"
	fi

	if [[ -n "$model" ]]; then
		local escaped_model
		escaped_model=$(sql_escape "$model")
		where_success="$where_success AND (tags LIKE '%model:${escaped_model}%' OR content LIKE '%model:${escaped_model}%')"
		where_failure="$where_failure AND (tags LIKE '%model:${escaped_model}%' OR content LIKE '%model:${escaped_model}%')"
	fi

	# Success patterns
	echo -e "${GREEN}Success Patterns:${NC}"
	local success_results
	success_results=$(sqlite3 "$MEMORY_DB" "SELECT content FROM learnings WHERE $where_success ORDER BY created_at DESC LIMIT $limit;" 2>/dev/null || echo "")

	if [[ -n "$success_results" ]]; then
		while IFS= read -r line; do
			echo "  + $line"
		done <<<"$success_results"
	else
		echo "  (none recorded)"
	fi

	echo ""

	# Failure patterns
	echo -e "${RED}Failure Patterns:${NC}"
	local failure_results
	failure_results=$(sqlite3 "$MEMORY_DB" "SELECT content FROM learnings WHERE $where_failure ORDER BY created_at DESC LIMIT $limit;" 2>/dev/null || echo "")

	if [[ -n "$failure_results" ]]; then
		while IFS= read -r line; do
			echo "  - $line"
		done <<<"$failure_results"
	else
		echo "  (none recorded)"
	fi

	echo ""

	# Summary counts
	local success_count failure_count
	success_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE $where_success;" 2>/dev/null || echo "0")
	failure_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE $where_failure;" 2>/dev/null || echo "0")

	echo -e "${CYAN}Summary:${NC}"
	echo "  Successes: $success_count"
	echo "  Failures: $failure_count"
	[[ -n "$task_type" ]] && echo "  Task type: $task_type"
	[[ -n "$model" ]] && echo "  Model: $model"
	echo ""
	return 0
}

#######################################
# Suggest approach based on patterns
#######################################
cmd_suggest() {
	local task_desc="$*"

	if [[ -z "$task_desc" ]]; then
		log_error "Task description required: pattern-tracker-helper.sh suggest \"description\""
		return 1
	fi

	echo ""
	echo -e "${CYAN}=== Pattern Suggestions for: \"$task_desc\" ===${NC}"
	echo ""

	# Search for relevant success patterns via FTS5
	echo -e "${GREEN}What has worked before:${NC}"
	local success_results
	success_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type SUCCESS_PATTERN --limit 5 --json 2>/dev/null || echo "[]")

	# Also search WORKING_SOLUTION (supervisor-generated)
	local working_results
	working_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type WORKING_SOLUTION --limit 3 --json 2>/dev/null || echo "[]")

	local found_success=false
	if command -v jq &>/dev/null; then
		local count
		count=$(echo "$success_results" | jq 'length' 2>/dev/null || echo "0")
		if [[ "$count" -gt 0 ]]; then
			echo "$success_results" | jq -r '.[] | "  + \(.content)"' 2>/dev/null
			found_success=true
		fi
		count=$(echo "$working_results" | jq 'length' 2>/dev/null || echo "0")
		if [[ "$count" -gt 0 ]]; then
			echo "$working_results" | jq -r '.[] | "  + \(.content)"' 2>/dev/null
			found_success=true
		fi
	fi
	if [[ "$found_success" == false ]]; then
		echo "  (no matching success patterns)"
	fi

	echo ""

	# Search for relevant failure patterns
	echo -e "${RED}What to avoid:${NC}"
	local failure_results
	failure_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type FAILURE_PATTERN --limit 5 --json 2>/dev/null || echo "[]")

	local failed_results
	failed_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type FAILED_APPROACH --limit 3 --json 2>/dev/null || echo "[]")

	local found_failure=false
	if command -v jq &>/dev/null; then
		local count
		count=$(echo "$failure_results" | jq 'length' 2>/dev/null || echo "0")
		if [[ "$count" -gt 0 ]]; then
			echo "$failure_results" | jq -r '.[] | "  - \(.content)"' 2>/dev/null
			found_failure=true
		fi
		count=$(echo "$failed_results" | jq 'length' 2>/dev/null || echo "0")
		if [[ "$count" -gt 0 ]]; then
			echo "$failed_results" | jq -r '.[] | "  - \(.content)"' 2>/dev/null
			found_failure=true
		fi
	fi
	if [[ "$found_failure" == false ]]; then
		echo "  (no matching failure patterns)"
	fi

	echo ""

	# Model recommendation based on patterns
	_show_model_hint "$task_desc"

	return 0
}

#######################################
# Recommend model tier based on pattern history
# Queries patterns tagged with model info and calculates success rates
#######################################
cmd_recommend() {
	local task_type=""
	local task_desc=""
	local json_mode=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task-type)
			task_type="$2"
			shift 2
			;;
		--json)
			json_mode=true
			shift
			;;
		*)
			if [[ -z "$task_desc" ]]; then
				task_desc="$1"
			else
				task_desc="$task_desc $1"
			fi
			shift
			;;
		esac
	done

	ensure_db || {
		if [[ "$json_mode" == true ]]; then
			echo "{}"
		else
			echo ""
			echo -e "${CYAN}=== Model Recommendation ===${NC}"
			echo ""
			echo "  No pattern data available. Default recommendation: sonnet"
			echo "  Record patterns to enable data-driven routing."
			echo ""
		fi
		return 0
	}

	# Build filter clause
	local filter=""
	if [[ -n "$task_type" ]]; then
		local escaped_type
		escaped_type=$(sql_escape "$task_type")
		filter="AND (tags LIKE '%${escaped_type}%' OR content LIKE '%task:${escaped_type}%')"
	fi

	# Query success/failure counts per model tier
	local best_model="" best_rate=0 has_data=false
	# Collect per-tier data for JSON output
	local tier_json_entries=""

	for model_tier in $VALID_MODELS; do
		local model_filter="AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%')"

		local successes failures
		successes=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter $filter;" 2>/dev/null || echo "0")
		failures=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter $filter;" 2>/dev/null || echo "0")

		local total=$((successes + failures))
		if [[ "$total" -gt 0 ]]; then
			has_data=true
			local rate
			rate=$(((successes * 100) / total))

			# Track best model (prefer higher success rate, break ties with more data)
			if [[ "$rate" -gt "$best_rate" ]] || { [[ "$rate" -eq "$best_rate" ]] && [[ "$total" -gt 0 ]]; }; then
				best_rate=$rate
				best_model=$model_tier
			fi

			if [[ "$json_mode" == true ]]; then
				[[ -n "$tier_json_entries" ]] && tier_json_entries="${tier_json_entries},"
				tier_json_entries="${tier_json_entries}\"${model_tier}\":{\"successes\":${successes},\"failures\":${failures},\"rate\":${rate},\"total\":${total}}"
			fi
		fi
	done

	if [[ "$json_mode" == true ]]; then
		if [[ "$has_data" == true && -n "$best_model" ]]; then
			local total_samples
			total_samples=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION', 'FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $filter;" 2>/dev/null || echo "0")
			echo "{\"recommended_tier\":\"${best_model}\",\"success_rate\":${best_rate},\"total_samples\":${total_samples},\"tiers\":{${tier_json_entries}}}"
		else
			echo "{}"
		fi
		return 0
	fi

	echo ""
	echo -e "${CYAN}=== Model Recommendation ===${NC}"
	echo ""

	if [[ -n "$task_type" ]]; then
		echo -e "  Task type: ${WHITE}$task_type${NC}"
	fi
	if [[ -n "$task_desc" ]]; then
		echo -e "  Description: ${WHITE}$task_desc${NC}"
	fi
	echo ""

	echo -e "${CYAN}Model Performance (from pattern history):${NC}"
	echo ""
	printf "  %-10s %8s %8s %10s\n" "Model" "Success" "Failure" "Rate"
	printf "  %-10s %8s %8s %10s\n" "-----" "-------" "-------" "----"

	for model_tier in $VALID_MODELS; do
		local model_filter="AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%')"

		local successes failures
		successes=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter $filter;" 2>/dev/null || echo "0")
		failures=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter $filter;" 2>/dev/null || echo "0")

		local total=$((successes + failures))
		if [[ "$total" -gt 0 ]]; then
			local rate
			rate=$(((successes * 100) / total))
			printf "  %-10s %8d %8d %9d%%\n" "$model_tier" "$successes" "$failures" "$rate"
		else
			printf "  %-10s %8s %8s %10s\n" "$model_tier" "-" "-" "no data"
		fi
	done

	echo ""

	# Recommendation
	if [[ "$has_data" == true && -n "$best_model" ]]; then
		echo -e "  ${GREEN}Recommended: ${WHITE}$best_model${GREEN} (${best_rate}% success rate)${NC}"

		# Add context about the recommendation
		if [[ "$best_rate" -lt 50 ]]; then
			echo -e "  ${YELLOW}Warning: Low success rate across all models. Consider reviewing task approach.${NC}"
		elif [[ "$best_rate" -lt 75 ]]; then
			echo -e "  ${YELLOW}Note: Moderate success rate. Consider using a higher-tier model for complex tasks.${NC}"
		fi
	else
		echo -e "  ${YELLOW}No pattern data for model comparison. Default: sonnet${NC}"
		echo "  Record patterns with --model flag to enable data-driven routing."
	fi

	echo ""
	return 0
}

#######################################
# Show pattern statistics
#######################################
cmd_stats() {
	echo ""
	echo -e "${CYAN}=== Pattern Statistics ===${NC}"
	echo ""

	ensure_db || return 0

	# Count by dedicated pattern types
	local success_count failure_count
	success_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'SUCCESS_PATTERN';" 2>/dev/null || echo "0")
	failure_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'FAILURE_PATTERN';" 2>/dev/null || echo "0")

	# Count supervisor-generated patterns
	local working_count failed_count error_count
	working_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'WORKING_SOLUTION' AND tags LIKE '%supervisor%';" 2>/dev/null || echo "0")
	failed_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'FAILED_APPROACH' AND tags LIKE '%supervisor%';" 2>/dev/null || echo "0")
	error_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'ERROR_FIX' AND tags LIKE '%supervisor%';" 2>/dev/null || echo "0")

	echo "  Dedicated patterns:"
	echo "    SUCCESS_PATTERN: $success_count"
	echo "    FAILURE_PATTERN: $failure_count"
	echo ""
	echo "  Supervisor-generated:"
	echo "    WORKING_SOLUTION: $working_count"
	echo "    FAILED_APPROACH: $failed_count"
	echo "    ERROR_FIX: $error_count"
	echo ""

	local total=$((success_count + failure_count + working_count + failed_count + error_count))
	echo "  Total trackable patterns: $total"
	echo ""

	# Show task type breakdown
	echo "  Task types with patterns:"
	local found_any=false
	for task_type in $VALID_TASK_TYPES; do
		local type_count
		type_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES) AND (tags LIKE '%${task_type}%' OR content LIKE '%task:${task_type}%');" 2>/dev/null || echo "0")
		if [[ "$type_count" -gt 0 ]]; then
			echo "    $task_type: $type_count"
			found_any=true
		fi
	done
	if [[ "$found_any" == false ]]; then
		echo "    (none recorded with task types)"
	fi
	echo ""

	# Show model tier breakdown
	echo "  Model tiers with patterns:"
	local found_model=false
	for model_tier in $VALID_MODELS; do
		local model_count
		model_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES) AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%');" 2>/dev/null || echo "0")
		if [[ "$model_count" -gt 0 ]]; then
			echo "    $model_tier: $model_count"
			found_model=true
		fi
	done
	if [[ "$found_model" == false ]]; then
		echo "    (none recorded with model tiers)"
	fi
	echo ""

	# Success rate
	local total_success=$((success_count + working_count))
	local total_failure=$((failure_count + failed_count + error_count))
	local total_all=$((total_success + total_failure))
	if [[ "$total_all" -gt 0 ]]; then
		local overall_rate=$(((total_success * 100) / total_all))
		echo "  Overall success rate: ${overall_rate}% ($total_success/$total_all)"
	fi
	echo ""

	# Extended metadata stats (t1095)
	local has_pm_table
	has_pm_table=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pattern_metadata';" 2>/dev/null || echo "0")
	if [[ "$has_pm_table" -gt 0 ]]; then
		local pm_count
		pm_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM pattern_metadata;" 2>/dev/null || echo "0")
		if [[ "$pm_count" -gt 0 ]]; then
			echo "  Extended metadata ($pm_count records):"

			# Strategy breakdown
			echo "    Strategy:"
			local strategy_data
			strategy_data=$(sqlite3 -separator '|' "$MEMORY_DB" "SELECT strategy, COUNT(*) FROM pattern_metadata GROUP BY strategy ORDER BY COUNT(*) DESC;" 2>/dev/null || echo "")
			if [[ -n "$strategy_data" ]]; then
				while IFS='|' read -r strat cnt; do
					printf "      %-20s %d\n" "$strat" "$cnt"
				done <<<"$strategy_data"
			fi

			# Quality breakdown
			echo "    Quality:"
			local quality_data
			quality_data=$(sqlite3 -separator '|' "$MEMORY_DB" "SELECT COALESCE(quality, '(unset)'), COUNT(*) FROM pattern_metadata GROUP BY quality ORDER BY COUNT(*) DESC;" 2>/dev/null || echo "")
			if [[ -n "$quality_data" ]]; then
				while IFS='|' read -r qual cnt; do
					printf "      %-20s %d\n" "$qual" "$cnt"
				done <<<"$quality_data"
			fi

			# Failure mode breakdown
			echo "    Failure modes:"
			local fm_data
			fm_data=$(sqlite3 -separator '|' "$MEMORY_DB" "SELECT failure_mode, COUNT(*) FROM pattern_metadata WHERE failure_mode IS NOT NULL GROUP BY failure_mode ORDER BY COUNT(*) DESC;" 2>/dev/null || echo "")
			if [[ -n "$fm_data" ]]; then
				while IFS='|' read -r fm cnt; do
					printf "      %-20s %d\n" "$fm" "$cnt"
				done <<<"$fm_data"
			else
				echo "      (none recorded)"
			fi

			# Token usage and cost summary (t1114)
			local token_stats
			token_stats=$(sqlite3 -separator '|' "$MEMORY_DB" "SELECT COUNT(*), COALESCE(SUM(tokens_in),0), COALESCE(SUM(tokens_out),0), COALESCE(AVG(tokens_in),0), COALESCE(AVG(tokens_out),0), COALESCE(SUM(estimated_cost),0), COALESCE(AVG(estimated_cost),0) FROM pattern_metadata WHERE tokens_in IS NOT NULL OR tokens_out IS NOT NULL;" 2>/dev/null || echo "")
			if [[ -n "$token_stats" ]]; then
				local tk_count tk_in_sum tk_out_sum tk_in_avg tk_out_avg tk_cost_sum tk_cost_avg
				IFS='|' read -r tk_count tk_in_sum tk_out_sum tk_in_avg tk_out_avg tk_cost_sum tk_cost_avg <<<"$token_stats"
				if [[ "$tk_count" -gt 0 ]]; then
					echo "    Token usage ($tk_count records with data):"
					printf "      Total in:  %d  |  Total out: %d\n" "$tk_in_sum" "$tk_out_sum"
					printf "      Avg in:    %.0f  |  Avg out:   %.0f\n" "$tk_in_avg" "$tk_out_avg"
					if awk "BEGIN{exit !($tk_cost_sum > 0)}" 2>/dev/null; then
						printf "      Total cost: \$%.4f  |  Avg cost: \$%.4f\n" "$tk_cost_sum" "$tk_cost_avg"
					fi
				fi
			fi
			echo ""
		fi
	fi

	return 0
}

#######################################
# Export patterns as JSON or CSV
#######################################
cmd_export() {
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format | -f)
			format="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	ensure_db || return 1

	# SQL for pattern types (used in queries below)
	local types_sql="'SUCCESS_PATTERN','FAILURE_PATTERN','WORKING_SOLUTION','FAILED_APPROACH','ERROR_FIX'"

	# Check if pattern_metadata table exists for extended export (t1095)
	local has_pm_table
	has_pm_table=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pattern_metadata';" 2>/dev/null || echo "0")

	case "$format" in
	json)
		local query
		if [[ "$has_pm_table" -gt 0 ]]; then
			query="SELECT l.id, l.type, l.content, l.tags, l.confidence, l.created_at, COALESCE(a.access_count, 0) as access_count, pm.strategy, pm.quality, pm.failure_mode, pm.tokens_in, pm.tokens_out, pm.estimated_cost FROM learnings l LEFT JOIN learning_access a ON l.id = a.id LEFT JOIN pattern_metadata pm ON l.id = pm.id WHERE l.type IN ($types_sql) ORDER BY l.created_at DESC;"
		else
			query="SELECT l.id, l.type, l.content, l.tags, l.confidence, l.created_at, COALESCE(a.access_count, 0) as access_count FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.type IN ($types_sql) ORDER BY l.created_at DESC;"
		fi
		sqlite3 -json "$MEMORY_DB" "$query" 2>/dev/null || echo "[]"
		;;
	csv)
		local csv_query
		if [[ "$has_pm_table" -gt 0 ]]; then
			echo "id,type,content,tags,confidence,created_at,access_count,strategy,quality,failure_mode,tokens_in,tokens_out,estimated_cost"
			csv_query="SELECT l.id, l.type, l.content, l.tags, l.confidence, l.created_at, COALESCE(a.access_count, 0), pm.strategy, pm.quality, pm.failure_mode, pm.tokens_in, pm.tokens_out, pm.estimated_cost FROM learnings l LEFT JOIN learning_access a ON l.id = a.id LEFT JOIN pattern_metadata pm ON l.id = pm.id WHERE l.type IN ($types_sql) ORDER BY l.created_at DESC;"
		else
			echo "id,type,content,tags,confidence,created_at,access_count"
			csv_query="SELECT l.id, l.type, l.content, l.tags, l.confidence, l.created_at, COALESCE(a.access_count, 0) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.type IN ($types_sql) ORDER BY l.created_at DESC;"
		fi
		sqlite3 -csv "$MEMORY_DB" "$csv_query" 2>/dev/null
		;;
	*)
		log_error "Unknown format: $format (use json or csv)"
		return 1
		;;
	esac
	return 0
}

#######################################
# Generate a summary report of patterns
#######################################
cmd_report() {
	ensure_db || return 0

	echo ""
	echo -e "${CYAN}=== Pattern Tracking Report ===${NC}"
	echo -e "  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
	echo ""

	# Overall counts
	local total_patterns
	total_patterns=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES);" 2>/dev/null || echo "0")
	echo "  Total patterns tracked: $total_patterns"

	if [[ "$total_patterns" -eq 0 ]]; then
		echo ""
		echo "  No patterns recorded yet. Patterns are captured:"
		echo "    - Automatically by the supervisor after task completion"
		echo "    - Manually via: pattern-tracker-helper.sh record ..."
		echo ""
		return 0
	fi

	# Date range
	local oldest newest
	oldest=$(sqlite3 "$MEMORY_DB" "SELECT MIN(created_at) FROM learnings WHERE type IN ($PATTERN_TYPES);" 2>/dev/null || echo "unknown")
	newest=$(sqlite3 "$MEMORY_DB" "SELECT MAX(created_at) FROM learnings WHERE type IN ($PATTERN_TYPES);" 2>/dev/null || echo "unknown")
	echo "  Date range: $oldest to $newest"
	echo ""

	# Success vs failure breakdown
	local success_total failure_total
	success_total=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION');" 2>/dev/null || echo "0")
	failure_total=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX');" 2>/dev/null || echo "0")

	echo -e "  ${GREEN}Successes: $success_total${NC}"
	echo -e "  ${RED}Failures: $failure_total${NC}"

	local total_sf=$((success_total + failure_total))
	if [[ "$total_sf" -gt 0 ]]; then
		local rate=$(((success_total * 100) / total_sf))
		echo "  Success rate: ${rate}%"
	fi
	echo ""

	# Top failure reasons (most common failure content patterns)
	echo -e "${RED}Most Common Failure Patterns:${NC}"
	local top_failures
	top_failures=$(sqlite3 "$MEMORY_DB" "
        SELECT content, COUNT(*) as cnt
        FROM learnings
        WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX')
        GROUP BY content
        ORDER BY cnt DESC
        LIMIT 5;
    " 2>/dev/null || echo "")

	if [[ -n "$top_failures" ]]; then
		while IFS='|' read -r content cnt; do
			# Truncate long content
			if [[ ${#content} -gt 80 ]]; then
				content="${content:0:77}..."
			fi
			echo "  ($cnt) $content"
		done <<<"$top_failures"
	else
		echo "  (none)"
	fi
	echo ""

	# Model tier performance
	echo -e "${CYAN}Model Tier Performance:${NC}"
	printf "  %-10s %8s %8s %10s\n" "Model" "Success" "Failure" "Rate"
	printf "  %-10s %8s %8s %10s\n" "-----" "-------" "-------" "----"

	for model_tier in $VALID_MODELS; do
		local model_filter="AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%')"
		local m_success m_failure
		m_success=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter;" 2>/dev/null || echo "0")
		m_failure=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter;" 2>/dev/null || echo "0")

		local m_total=$((m_success + m_failure))
		if [[ "$m_total" -gt 0 ]]; then
			local m_rate=$(((m_success * 100) / m_total))
			printf "  %-10s %8d %8d %9d%%\n" "$model_tier" "$m_success" "$m_failure" "$m_rate"
		fi
	done
	echo ""

	# Extended metadata report (t1095)
	local has_pm_table
	has_pm_table=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pattern_metadata';" 2>/dev/null || echo "0")
	if [[ "$has_pm_table" -gt 0 ]]; then
		local pm_with_data
		pm_with_data=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM pattern_metadata WHERE strategy != 'normal' OR quality IS NOT NULL OR failure_mode IS NOT NULL OR tokens_in IS NOT NULL;" 2>/dev/null || echo "0")
		if [[ "$pm_with_data" -gt 0 ]]; then
			echo -e "${CYAN}Extended Metadata:${NC}"

			# Strategy distribution
			local strat_data
			strat_data=$(sqlite3 -separator '|' "$MEMORY_DB" "SELECT strategy, COUNT(*) FROM pattern_metadata GROUP BY strategy ORDER BY COUNT(*) DESC;" 2>/dev/null || echo "")
			if [[ -n "$strat_data" ]]; then
				echo "  Strategy distribution:"
				while IFS='|' read -r strat cnt; do
					printf "    %-20s %d\n" "$strat" "$cnt"
				done <<<"$strat_data"
			fi

			# Quality distribution
			local qual_data
			qual_data=$(sqlite3 -separator '|' "$MEMORY_DB" "SELECT quality, COUNT(*) FROM pattern_metadata WHERE quality IS NOT NULL GROUP BY quality ORDER BY COUNT(*) DESC;" 2>/dev/null || echo "")
			if [[ -n "$qual_data" ]]; then
				echo "  Quality distribution:"
				while IFS='|' read -r qual cnt; do
					printf "    %-20s %d\n" "$qual" "$cnt"
				done <<<"$qual_data"
			fi

			# Top failure modes
			local fm_data
			fm_data=$(sqlite3 -separator '|' "$MEMORY_DB" "SELECT failure_mode, COUNT(*) FROM pattern_metadata WHERE failure_mode IS NOT NULL GROUP BY failure_mode ORDER BY COUNT(*) DESC;" 2>/dev/null || echo "")
			if [[ -n "$fm_data" ]]; then
				echo "  Failure modes:"
				while IFS='|' read -r fm cnt; do
					printf "    %-20s %d\n" "$fm" "$cnt"
				done <<<"$fm_data"
			fi

			echo ""
		fi
	fi

	# Recent patterns (last 5)
	echo -e "${CYAN}Recent Patterns (last 5):${NC}"
	local recent
	recent=$(sqlite3 -separator '|' "$MEMORY_DB" "
        SELECT type, content, created_at
        FROM learnings
        WHERE type IN ($PATTERN_TYPES)
        ORDER BY created_at DESC
        LIMIT 5;
    " 2>/dev/null || echo "")

	if [[ -n "$recent" ]]; then
		while IFS='|' read -r type content created_at; do
			local icon="?"
			case "$type" in
			SUCCESS_PATTERN | WORKING_SOLUTION) icon="${GREEN}+${NC}" ;;
			FAILURE_PATTERN | FAILED_APPROACH | ERROR_FIX) icon="${RED}-${NC}" ;;
			esac
			# Truncate long content
			if [[ ${#content} -gt 70 ]]; then
				content="${content:0:67}..."
			fi
			echo -e "  $icon $content"
			echo "    ($created_at)"
		done <<<"$recent"
	else
		echo "  (none)"
	fi
	echo ""
	return 0
}

#######################################
# Internal: Show model hint based on pattern data
# Used by suggest command to add routing context
#######################################
_show_model_hint() {
	if ! ensure_db 2>/dev/null; then
		return 0
	fi

	# Check if any patterns have model data
	local model_patterns
	model_patterns=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES) AND (tags LIKE '%model:%' OR content LIKE '%model:%');" 2>/dev/null || echo "0")

	if [[ "$model_patterns" -gt 0 ]]; then
		echo -e "${CYAN}Model Routing Hint:${NC}"

		local best_model="" best_rate=0
		for model_tier in $VALID_MODELS; do
			local model_filter="AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%')"
			local m_success m_failure
			m_success=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter;" 2>/dev/null || echo "0")
			m_failure=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter;" 2>/dev/null || echo "0")

			local m_total=$((m_success + m_failure))
			if [[ "$m_total" -gt 2 ]]; then
				local m_rate=$(((m_success * 100) / m_total))
				if [[ "$m_rate" -gt "$best_rate" ]]; then
					best_rate=$m_rate
					best_model=$model_tier
				fi
			fi
		done

		if [[ -n "$best_model" ]]; then
			echo "  Based on pattern history, $best_model has the highest success rate (${best_rate}%)"
		else
			echo "  Not enough model-tagged patterns for a recommendation yet."
		fi
		echo ""
	fi
	return 0
}

#######################################
# Query model usage from GitHub issue labels (t1010)
# Correlates label data with memory patterns for richer analysis.
# Delegates to supervisor-helper.sh labels for the actual GitHub query,
# then enriches with success rates from the pattern database.
#######################################
cmd_label_stats() {
	local repo_slug="" action_filter="" model_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo_slug="$2"
			shift 2
			;;
		--action)
			action_filter="$2"
			shift 2
			;;
		--model)
			model_filter="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local supervisor_helper="${SCRIPT_DIR}/supervisor-helper.sh"
	if [[ ! -x "$supervisor_helper" ]]; then
		log_error "supervisor-helper.sh not found at: $supervisor_helper"
		return 1
	fi

	echo -e "${BOLD}Model Usage Analysis${NC} (labels + patterns)"
	echo "════════════════════════════════════════"

	# Get label data from supervisor as JSON
	local label_args=("labels" "--json")
	[[ -n "$repo_slug" ]] && label_args+=("--repo" "$repo_slug")
	[[ -n "$action_filter" ]] && label_args+=("--action" "$action_filter")
	[[ -n "$model_filter" ]] && label_args+=("--model" "$model_filter")

	local label_json
	label_json=$("$supervisor_helper" "${label_args[@]}" 2>/dev/null || echo "[]")

	if [[ "$label_json" == "[]" ]]; then
		echo ""
		echo "No model usage labels found on GitHub issues."
		echo "Labels are added automatically during supervisor dispatch and evaluation."
		echo ""
		echo "Showing memory-based pattern data instead:"
		echo ""
		cmd_report
		return 0
	fi

	# Display label summary
	echo ""
	echo -e "${BOLD}GitHub Issue Labels:${NC}"

	# Parse JSON entries (simple line-by-line since format is known)
	echo "$label_json" | tr ',' '\n' | tr -d '[]{}' | while IFS= read -r line; do
		local label count
		label=$(echo "$line" | grep -o '"label":"[^"]*"' | cut -d'"' -f4 || true)
		count=$(echo "$line" | grep -o '"count":[0-9]*' | cut -d: -f2 || true)
		if [[ -n "$label" && -n "$count" ]]; then
			printf "  %-25s %d issues\n" "$label" "$count"
		fi
	done

	# Enrich with pattern-tracker success rates
	echo ""
	echo -e "${BOLD}Memory Pattern Success Rates:${NC}"

	if ! ensure_db; then
		echo "  (no memory database — pattern data unavailable)"
		return 0
	fi

	for tier in haiku flash sonnet pro opus; do
		if [[ -n "$model_filter" && "$tier" != "$model_filter" ]]; then
			continue
		fi

		local success_count failure_count total rate
		success_count=$(sqlite3 "$MEMORY_DB" \
			"SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN','WORKING_SOLUTION') AND (tags LIKE '%model:${tier}%' OR content LIKE '%[model:${tier}]%');" \
			2>/dev/null || echo "0")
		failure_count=$(sqlite3 "$MEMORY_DB" \
			"SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN','FAILED_APPROACH','ERROR_FIX') AND (tags LIKE '%model:${tier}%' OR content LIKE '%[model:${tier}]%');" \
			2>/dev/null || echo "0")
		total=$((success_count + failure_count))

		if [[ "$total" -gt 0 ]]; then
			rate=$((success_count * 100 / total))
			printf "  %-10s %d/%d (%d%% success)\n" "$tier" "$success_count" "$total" "$rate"
		fi
	done

	echo ""
	return 0
}

#######################################
# ROI analysis: cost-per-task-type and tier comparison (t1114)
# Answers: does opus's higher success rate justify 10-15x cost for chore tasks?
#######################################
cmd_roi() {
	local task_type=""
	local min_samples=3

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task-type)
			task_type="$2"
			shift 2
			;;
		--min-samples)
			min_samples="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	ensure_db || {
		echo ""
		echo -e "${CYAN}=== ROI Analysis ===${NC}"
		echo ""
		echo "  No pattern data available. Record patterns with --tokens-in/--tokens-out to enable ROI analysis."
		echo ""
		return 0
	}

	# Check if estimated_cost column exists
	local has_cost_col
	has_cost_col=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM pragma_table_info('pattern_metadata') WHERE name='estimated_cost';" 2>/dev/null || echo "0")
	if [[ "$has_cost_col" == "0" ]]; then
		echo ""
		echo -e "${YELLOW}[WARN]${NC} estimated_cost column not yet in pattern_metadata. Run 'memory-helper.sh store' to trigger migration."
		echo ""
		return 0
	fi

	echo ""
	echo -e "${CYAN}=== ROI Analysis: Cost vs Success Rate by Model Tier ===${NC}"
	[[ -n "$task_type" ]] && echo -e "  Task type: ${WHITE}$task_type${NC}"
	echo ""

	# Build task type filter
	local type_filter=""
	if [[ -n "$task_type" ]]; then
		local escaped_type
		escaped_type=$(sql_escape "$task_type")
		type_filter="AND (l.tags LIKE '%${escaped_type}%' OR l.content LIKE '%task:${escaped_type}%')"
	fi

	# Per-tier ROI table
	printf "  %-10s %8s %8s %8s %10s %12s %14s\n" \
		"Tier" "Success" "Failure" "Rate%" "Avg Cost" "Total Cost" "Cost/Success"
	printf "  %-10s %8s %8s %8s %10s %12s %14s\n" \
		"----" "-------" "-------" "-----" "--------" "----------" "------------"

	local has_any_data=false

	for tier in $VALID_MODELS; do
		local tier_filter="AND (l.tags LIKE '%model:${tier}%' OR l.content LIKE '%model:${tier}%')"

		local successes failures avg_cost total_cost
		successes=$(sqlite3 "$MEMORY_DB" "
			SELECT COUNT(*) FROM learnings l
			WHERE l.type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION')
			$tier_filter $type_filter;" 2>/dev/null || echo "0")
		failures=$(sqlite3 "$MEMORY_DB" "
			SELECT COUNT(*) FROM learnings l
			WHERE l.type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX')
			$tier_filter $type_filter;" 2>/dev/null || echo "0")
		avg_cost=$(sqlite3 "$MEMORY_DB" "
			SELECT COALESCE(AVG(pm.estimated_cost), 0)
			FROM learnings l
			LEFT JOIN pattern_metadata pm ON l.id = pm.id
			WHERE l.type IN ('SUCCESS_PATTERN','WORKING_SOLUTION','FAILURE_PATTERN','FAILED_APPROACH','ERROR_FIX')
			AND pm.estimated_cost IS NOT NULL
			$tier_filter $type_filter;" 2>/dev/null || echo "0")
		total_cost=$(sqlite3 "$MEMORY_DB" "
			SELECT COALESCE(SUM(pm.estimated_cost), 0)
			FROM learnings l
			LEFT JOIN pattern_metadata pm ON l.id = pm.id
			WHERE l.type IN ('SUCCESS_PATTERN','WORKING_SOLUTION','FAILURE_PATTERN','FAILED_APPROACH','ERROR_FIX')
			AND pm.estimated_cost IS NOT NULL
			$tier_filter $type_filter;" 2>/dev/null || echo "0")

		local total=$((successes + failures))
		if [[ "$total" -lt "$min_samples" ]]; then
			continue
		fi

		has_any_data=true
		local rate
		rate=$(((successes * 100) / total))

		# Cost per successful task (avoid division by zero)
		local cost_per_success="N/A"
		if [[ "$successes" -gt 0 ]] && awk "BEGIN{exit !($total_cost > 0)}" 2>/dev/null; then
			cost_per_success=$(awk -v tc="$total_cost" -v s="$successes" 'BEGIN{printf "$%.4f", tc/s}')
		fi

		local avg_cost_fmt="N/A"
		if awk "BEGIN{exit !($avg_cost > 0)}" 2>/dev/null; then
			avg_cost_fmt=$(awk -v c="$avg_cost" 'BEGIN{printf "$%.4f", c}')
		fi

		local total_cost_fmt="N/A"
		if awk "BEGIN{exit !($total_cost > 0)}" 2>/dev/null; then
			total_cost_fmt=$(awk -v c="$total_cost" 'BEGIN{printf "$%.4f", c}')
		fi

		printf "  %-10s %8d %8d %7d%% %10s %12s %14s\n" \
			"$tier" "$successes" "$failures" "$rate" \
			"$avg_cost_fmt" "$total_cost_fmt" "$cost_per_success"
	done

	if [[ "$has_any_data" == false ]]; then
		echo "  No data with cost information yet (min $min_samples samples per tier required)."
		echo ""
		echo "  Cost data is populated when patterns are recorded with:"
		echo "    --tokens-in N --tokens-out N --model <tier>"
		echo "  or explicitly with --estimated-cost N.NNNN"
		echo ""
		echo "  The supervisor auto-populates this from worker evaluation logs."
		echo ""
		return 0
	fi

	echo ""

	# Tier pricing reference table
	echo -e "${CYAN}Model Tier Pricing Reference (USD per 1M tokens):${NC}"
	printf "  %-10s %12s %13s\n" "Tier" "Input/1M" "Output/1M"
	printf "  %-10s %12s %13s\n" "----" "--------" "---------"
	for t in $TIER_PRICING; do
		local t_name t_in t_out
		t_name=$(echo "$t" | cut -d: -f1)
		t_in=$(echo "$t" | cut -d: -f2)
		t_out=$(echo "$t" | cut -d: -f3)
		printf "  %-10s %12s %13s\n" "$t_name" "\$$t_in" "\$$t_out"
	done
	echo ""

	# ROI verdict: compare sonnet vs opus cost-per-success
	local sonnet_cps opus_cps
	sonnet_cps=$(sqlite3 "$MEMORY_DB" "
		SELECT CASE WHEN COUNT(*) > 0 AND SUM(pm.estimated_cost) > 0
			THEN SUM(pm.estimated_cost) / COUNT(*)
			ELSE 0 END
		FROM learnings l
		LEFT JOIN pattern_metadata pm ON l.id = pm.id
		WHERE l.type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION')
		AND pm.estimated_cost IS NOT NULL
		AND (l.tags LIKE '%model:sonnet%' OR l.content LIKE '%model:sonnet%')
		$type_filter;" 2>/dev/null || echo "0")
	opus_cps=$(sqlite3 "$MEMORY_DB" "
		SELECT CASE WHEN COUNT(*) > 0 AND SUM(pm.estimated_cost) > 0
			THEN SUM(pm.estimated_cost) / COUNT(*)
			ELSE 0 END
		FROM learnings l
		LEFT JOIN pattern_metadata pm ON l.id = pm.id
		WHERE l.type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION')
		AND pm.estimated_cost IS NOT NULL
		AND (l.tags LIKE '%model:opus%' OR l.content LIKE '%model:opus%')
		$type_filter;" 2>/dev/null || echo "0")

	if awk "BEGIN{exit !($sonnet_cps > 0 && $opus_cps > 0)}" 2>/dev/null; then
		echo -e "${CYAN}Sonnet vs Opus ROI Verdict:${NC}"
		local ratio
		ratio=$(awk -v o="$opus_cps" -v s="$sonnet_cps" 'BEGIN{printf "%.1f", o/s}')
		local sonnet_fmt opus_fmt
		sonnet_fmt=$(awk -v c="$sonnet_cps" 'BEGIN{printf "$%.4f", c}')
		opus_fmt=$(awk -v c="$opus_cps" 'BEGIN{printf "$%.4f", c}')
		echo "  Sonnet cost/success: $sonnet_fmt"
		echo "  Opus cost/success:   $opus_fmt"
		echo "  Opus is ${ratio}x more expensive per successful task"
		if awk "BEGIN{exit !($ratio > 5)}" 2>/dev/null; then
			echo -e "  ${YELLOW}Verdict: Opus costs ${ratio}x more per success — use sonnet for routine tasks${NC}"
		else
			echo -e "  ${GREEN}Verdict: Opus premium is ${ratio}x — may be justified for complex tasks${NC}"
		fi
		echo ""
	fi

	return 0
}

#######################################
# Tier drift analysis (t1191)
# Queries pattern data for tier_delta tags to show escalation frequency,
# cost impact, and trends. Helps detect when tasks requested at cheaper
# tiers are consistently executed at more expensive ones.
#
# Options:
#   --days <n>     Look back N days (default: 30)
#   --json         Output as JSON
#   --summary      One-line summary for pulse cycle integration
#######################################
cmd_tier_drift() {
	local days=30
	local json_output=false
	local summary_only=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-30}"
			shift 2
			;;
		--json)
			json_output=true
			shift
			;;
		--summary)
			summary_only=true
			shift
			;;
		*)
			shift
			;;
		esac
	done

	ensure_db || return 1

	local cutoff_date
	cutoff_date=$(date -u -v-"${days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
		cutoff_date=$(date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
		cutoff_date="2000-01-01T00:00:00Z"

	# Count total dispatches with tier tracking data
	local total_dispatches
	total_dispatches=$(sqlite3 "$MEMORY_DB" "
		SELECT COUNT(*) FROM learnings
		WHERE tags LIKE '%actual_tier:%'
		AND created_at >= '$cutoff_date';
	" 2>/dev/null || echo "0")

	# Count dispatches where tier escalated (requested != actual)
	local escalated_count
	escalated_count=$(sqlite3 "$MEMORY_DB" "
		SELECT COUNT(*) FROM learnings
		WHERE tags LIKE '%tier_delta:%'
		AND created_at >= '$cutoff_date';
	" 2>/dev/null || echo "0")

	# Get breakdown of tier_delta patterns (e.g., sonnet->opus: 5, haiku->sonnet: 2)
	local drift_breakdown
	drift_breakdown=$(sqlite3 -separator '|' "$MEMORY_DB" "
		SELECT
			SUBSTR(tags,
				INSTR(tags, 'tier_delta:') + 11,
				CASE
					WHEN INSTR(SUBSTR(tags, INSTR(tags, 'tier_delta:') + 11), ',') > 0
					THEN INSTR(SUBSTR(tags, INSTR(tags, 'tier_delta:') + 11), ',') - 1
					ELSE LENGTH(SUBSTR(tags, INSTR(tags, 'tier_delta:') + 11))
				END
			) AS delta,
			COUNT(*) AS cnt
		FROM learnings
		WHERE tags LIKE '%tier_delta:%'
		AND created_at >= '$cutoff_date'
		GROUP BY delta
		ORDER BY cnt DESC;
	" 2>/dev/null || echo "")

	# Calculate cost impact: for each escalation, estimate the cost difference
	# between requested and actual tiers using TIER_PRICING
	local cost_waste
	cost_waste=$(sqlite3 "$MEMORY_DB" "
		SELECT COALESCE(SUM(
			CASE
				WHEN pm.estimated_cost IS NOT NULL AND pm.estimated_cost > 0
				THEN pm.estimated_cost
				ELSE 0
			END
		), 0)
		FROM learnings l
		LEFT JOIN pattern_metadata pm ON l.id = pm.id
		WHERE l.tags LIKE '%tier_delta:%'
		AND l.created_at >= '$cutoff_date';
	" 2>/dev/null || echo "0")

	# Get success rate for escalated vs non-escalated tasks
	local escalated_success
	escalated_success=$(sqlite3 "$MEMORY_DB" "
		SELECT COALESCE(
			ROUND(100.0 * SUM(CASE WHEN type = 'SUCCESS_PATTERN' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0)),
			0
		)
		FROM learnings
		WHERE tags LIKE '%tier_delta:%'
		AND created_at >= '$cutoff_date';
	" 2>/dev/null || echo "0")

	local non_escalated_success
	non_escalated_success=$(sqlite3 "$MEMORY_DB" "
		SELECT COALESCE(
			ROUND(100.0 * SUM(CASE WHEN type = 'SUCCESS_PATTERN' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0)),
			0
		)
		FROM learnings
		WHERE tags LIKE '%actual_tier:%'
		AND tags NOT LIKE '%tier_delta:%'
		AND created_at >= '$cutoff_date';
	" 2>/dev/null || echo "0")

	# Calculate escalation rate
	local escalation_pct=0
	if [[ "$total_dispatches" -gt 0 ]]; then
		escalation_pct=$(awk -v e="$escalated_count" -v t="$total_dispatches" 'BEGIN { printf "%.0f", (e / t) * 100 }')
	fi

	# Summary mode: single line for pulse cycle
	if [[ "$summary_only" == true ]]; then
		echo "tier_drift: ${escalated_count}/${total_dispatches} escalated (${escalation_pct}%) in ${days}d, cost_at_higher_tier=\$${cost_waste}"
		return 0
	fi

	# JSON output
	if [[ "$json_output" == true ]]; then
		local drift_json="[]"
		if [[ -n "$drift_breakdown" ]]; then
			drift_json="["
			local first=true
			while IFS='|' read -r delta cnt; do
				[[ -z "$delta" ]] && continue
				[[ "$first" == true ]] && first=false || drift_json="${drift_json},"
				drift_json="${drift_json}{\"delta\":\"${delta}\",\"count\":${cnt}}"
			done <<<"$drift_breakdown"
			drift_json="${drift_json}]"
		fi

		cat <<ENDJSON
{
  "period_days": $days,
  "total_dispatches": $total_dispatches,
  "escalated_count": $escalated_count,
  "escalation_pct": $escalation_pct,
  "cost_at_higher_tier": $cost_waste,
  "escalated_success_pct": $escalated_success,
  "non_escalated_success_pct": $non_escalated_success,
  "drift_breakdown": $drift_json
}
ENDJSON
		return 0
	fi

	# Human-readable output
	echo "=== Tier Drift Analysis (last ${days} days) ==="
	echo ""
	echo "Total dispatches with tier tracking: $total_dispatches"
	echo "Escalated (requested != actual):     $escalated_count (${escalation_pct}%)"
	echo "Cost at higher tier:                 \$${cost_waste}"
	echo ""

	if [[ -n "$drift_breakdown" ]]; then
		echo "Escalation breakdown:"
		while IFS='|' read -r delta cnt; do
			[[ -z "$delta" ]] && continue
			echo "  ${delta}: ${cnt} times"
		done <<<"$drift_breakdown"
		echo ""
	fi

	echo "Success rates:"
	echo "  Escalated tasks:     ${escalated_success}%"
	echo "  Non-escalated tasks: ${non_escalated_success}%"
	echo ""

	# Actionable insights
	if [[ "$escalation_pct" -gt 50 ]]; then
		echo "WARNING: >50% of dispatches are escalating tier."
		echo "  Likely cause: dispatch is defaulting to a higher tier than requested."
		echo "  Action: Check resolve_task_model() priority chain and SUPERVISOR_MODEL env var."
	elif [[ "$escalation_pct" -gt 25 ]]; then
		echo "NOTICE: >25% of dispatches are escalating tier."
		echo "  This may indicate the requested tier is insufficient for task complexity."
		echo "  Action: Review pattern data for the escalated task types."
	else
		echo "Tier drift is within normal range (<25%)."
	fi

	return 0
}

#######################################
# Unified scoring backbone: record structured quality scores for a model response
# Acts as the shared entry point for compare-models, response-scoring, build-agent,
# evaluate.sh, and dispatch.sh to record A/B comparison data (t1094).
#
# Options:
#   --model <tier>          Model tier (haiku|flash|sonnet|pro|opus)
#   --task-type <type>      Task category
#   --task-id <id>          Task identifier
#   --correctness <1-5>     Factual accuracy score
#   --completeness <1-5>    Coverage score
#   --code-quality <1-5>    Code quality score
#   --clarity <1-5>         Clarity/readability score
#   --weighted-avg <float>  Pre-computed weighted average (overrides per-criterion)
#   --outcome <success|failure>  Explicit outcome (auto-derived from avg if omitted)
#   --strategy <type>       Prompt strategy: normal|prompt-repeat|escalated
#   --quality <level>       CI quality: ci-pass-first-try|ci-pass-after-fix|needs-human
#   --failure-mode <mode>   Failure classification
#   --tokens-in <n>         Input token count
#   --tokens-out <n>        Output token count
#   --description <text>    Free-text description (auto-generated if omitted)
#   --tags <tags>           Additional comma-separated tags
#   --source <name>         Source tool (response-scoring|compare-models|build-agent|evaluate|dispatch)
#######################################
cmd_score() {
	local model="" task_type="" task_id="" description="" tags="" source=""
	local correctness="" completeness="" code_quality="" clarity="" weighted_avg=""
	local outcome="" strategy="" quality="" failure_mode=""
	local tokens_in="" tokens_out=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		--task-type)
			task_type="$2"
			shift 2
			;;
		--task-id)
			task_id="$2"
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
		--weighted-avg)
			weighted_avg="$2"
			shift 2
			;;
		--outcome)
			outcome="$2"
			shift 2
			;;
		--strategy)
			strategy="$2"
			shift 2
			;;
		--quality)
			quality="$2"
			shift 2
			;;
		--failure-mode)
			failure_mode="$2"
			shift 2
			;;
		--tokens-in)
			tokens_in="$2"
			shift 2
			;;
		--tokens-out)
			tokens_out="$2"
			shift 2
			;;
		--description | --desc)
			description="$2"
			shift 2
			;;
		--tags)
			tags="$2"
			shift 2
			;;
		--source)
			source="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate per-criterion scores if provided
	local score_val
	for score_val in "$correctness" "$completeness" "$code_quality" "$clarity"; do
		if [[ -n "$score_val" ]] && ! [[ "$score_val" =~ ^[1-5]$ ]]; then
			log_error "Scores must be integers 1-5, got: $score_val"
			return 1
		fi
	done

	# Compute weighted average from per-criterion scores if not provided
	if [[ -z "$weighted_avg" ]]; then
		local has_scores=false
		local wsum=0 wdenom=0
		if [[ -n "$correctness" ]]; then
			wsum=$(awk "BEGIN{printf \"%.4f\", $wsum + ($correctness * 0.30)}")
			wdenom=$(awk "BEGIN{printf \"%.4f\", $wdenom + 0.30}")
			has_scores=true
		fi
		if [[ -n "$completeness" ]]; then
			wsum=$(awk "BEGIN{printf \"%.4f\", $wsum + ($completeness * 0.25)}")
			wdenom=$(awk "BEGIN{printf \"%.4f\", $wdenom + 0.25}")
			has_scores=true
		fi
		if [[ -n "$code_quality" ]]; then
			wsum=$(awk "BEGIN{printf \"%.4f\", $wsum + ($code_quality * 0.25)}")
			wdenom=$(awk "BEGIN{printf \"%.4f\", $wdenom + 0.25}")
			has_scores=true
		fi
		if [[ -n "$clarity" ]]; then
			wsum=$(awk "BEGIN{printf \"%.4f\", $wsum + ($clarity * 0.20)}")
			wdenom=$(awk "BEGIN{printf \"%.4f\", $wdenom + 0.20}")
			has_scores=true
		fi
		if [[ "$has_scores" == true ]] && awk "BEGIN{exit !($wdenom > 0)}" 2>/dev/null; then
			weighted_avg=$(awk "BEGIN{printf \"%.2f\", $wsum / $wdenom}")
		fi
	fi

	# Validate weighted_avg if provided or computed
	if [[ -n "$weighted_avg" ]] && ! echo "$weighted_avg" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
		log_error "weighted-avg must be a non-negative number"
		return 1
	fi

	# Derive outcome from weighted average if not explicitly set
	if [[ -z "$outcome" && -n "$weighted_avg" ]]; then
		local avg_int
		avg_int=$(awk "BEGIN{printf \"%d\", $weighted_avg * 100}")
		if [[ "$avg_int" -ge 350 ]]; then
			outcome="success"
		else
			outcome="failure"
		fi
	fi

	# Default outcome to success if still unset
	outcome="${outcome:-success}"

	# Build description if not provided
	if [[ -z "$description" ]]; then
		local desc_parts=""
		[[ -n "$source" ]] && desc_parts="${source}: "
		[[ -n "$model" ]] && desc_parts="${desc_parts}${model}"
		[[ -n "$weighted_avg" ]] && desc_parts="${desc_parts} scored ${weighted_avg}/5.0"
		[[ -n "$task_type" ]] && desc_parts="${desc_parts} on ${task_type}"
		[[ -n "$task_id" ]] && desc_parts="${desc_parts} (${task_id})"
		description="${desc_parts:-Unified score record}"
	fi

	# Build extra tags for scoring metadata
	local score_tags="unified-score"
	[[ -n "$source" ]] && score_tags="${score_tags},source:${source}"
	[[ -n "$weighted_avg" ]] && score_tags="${score_tags},scored-avg:${weighted_avg}"
	[[ -n "$correctness" ]] && score_tags="${score_tags},score-correctness:${correctness}"
	[[ -n "$completeness" ]] && score_tags="${score_tags},score-completeness:${completeness}"
	[[ -n "$code_quality" ]] && score_tags="${score_tags},score-code-quality:${code_quality}"
	[[ -n "$clarity" ]] && score_tags="${score_tags},score-clarity:${clarity}"
	[[ -n "$tags" ]] && score_tags="${score_tags},${tags}"

	# Delegate to cmd_record with all structured metadata
	local record_args=(
		--outcome "$outcome"
		--description "$description"
		--tags "$score_tags"
	)
	[[ -n "$model" ]] && record_args+=(--model "$model")
	[[ -n "$task_type" ]] && record_args+=(--task-type "$task_type")
	[[ -n "$task_id" ]] && record_args+=(--task-id "$task_id")
	[[ -n "$strategy" ]] && record_args+=(--strategy "$strategy")
	[[ -n "$quality" ]] && record_args+=(--quality "$quality")
	[[ -n "$failure_mode" ]] && record_args+=(--failure-mode "$failure_mode")
	[[ -n "$tokens_in" ]] && record_args+=(--tokens-in "$tokens_in")
	[[ -n "$tokens_out" ]] && record_args+=(--tokens-out "$tokens_out")

	cmd_record "${record_args[@]}"
	return 0
}

#######################################
# A/B comparison: record head-to-head model comparison results (t1094)
# Enables data-driven model selection by tracking which model wins comparisons.
#
# Options:
#   --winner <tier>         Winning model tier
#   --loser <tier>          Losing model tier (can repeat for multi-model)
#   --task-type <type>      Task category
#   --task-id <id>          Task identifier
#   --winner-score <float>  Winner's weighted average score
#   --loser-score <float>   Loser's weighted average score (optional)
#   --margin <float>        Score margin (winner - loser)
#   --models-compared <n>   Total number of models compared
#   --description <text>    Free-text description
#   --tags <tags>           Additional comma-separated tags
#   --source <name>         Source tool
#######################################
cmd_ab_compare() {
	local winner="" task_type="" task_id="" description="" tags="" source=""
	local winner_score="" loser_score="" margin="" models_compared=""
	local losers=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--winner)
			winner="$2"
			shift 2
			;;
		--loser)
			losers+=("$2")
			shift 2
			;;
		--task-type)
			task_type="$2"
			shift 2
			;;
		--task-id)
			task_id="$2"
			shift 2
			;;
		--winner-score)
			winner_score="$2"
			shift 2
			;;
		--loser-score)
			loser_score="$2"
			shift 2
			;;
		--margin)
			margin="$2"
			shift 2
			;;
		--models-compared)
			models_compared="$2"
			shift 2
			;;
		--description | --desc)
			description="$2"
			shift 2
			;;
		--tags)
			tags="$2"
			shift 2
			;;
		--source)
			source="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$winner" ]]; then
		log_error "Winner model required: --winner <tier>"
		return 1
	fi

	# Build description if not provided
	if [[ -z "$description" ]]; then
		local loser_str=""
		if [[ "${#losers[@]}" -gt 0 ]]; then
			loser_str=" beat ${losers[*]}"
		fi
		description="A/B comparison: ${winner}${loser_str}"
		[[ -n "$winner_score" ]] && description="${description} (${winner_score}/5.0)"
		[[ -n "$task_type" ]] && description="${description} on ${task_type}"
		[[ -n "$task_id" ]] && description="${description} (${task_id})"
	fi

	# Build tags
	local ab_tags="ab-comparison,comparison-winner"
	[[ -n "$source" ]] && ab_tags="${ab_tags},source:${source}"
	[[ -n "$winner_score" ]] && ab_tags="${ab_tags},winner-score:${winner_score}"
	[[ -n "$loser_score" ]] && ab_tags="${ab_tags},loser-score:${loser_score}"
	[[ -n "$margin" ]] && ab_tags="${ab_tags},margin:${margin}"
	[[ -n "$models_compared" ]] && ab_tags="${ab_tags},models-compared:${models_compared}"
	for loser in "${losers[@]}"; do
		ab_tags="${ab_tags},loser:${loser}"
	done
	[[ -n "$tags" ]] && ab_tags="${ab_tags},${tags}"

	# Record winner as success
	local winner_args=(
		--outcome "success"
		--description "$description"
		--model "$winner"
		--tags "$ab_tags"
	)
	[[ -n "$task_type" ]] && winner_args+=(--task-type "$task_type")
	[[ -n "$task_id" ]] && winner_args+=(--task-id "$task_id")

	cmd_record "${winner_args[@]}"

	# Record each loser as failure (for accurate success rate tracking)
	for loser in "${losers[@]}"; do
		local loser_desc="A/B comparison: ${loser} lost to ${winner}"
		[[ -n "$task_type" ]] && loser_desc="${loser_desc} on ${task_type}"
		local loser_tags="ab-comparison,comparison-loser,winner:${winner}"
		[[ -n "$source" ]] && loser_tags="${loser_tags},source:${source}"
		[[ -n "$loser_score" ]] && loser_tags="${loser_tags},loser-score:${loser_score}"
		[[ -n "$models_compared" ]] && loser_tags="${loser_tags},models-compared:${models_compared}"
		[[ -n "$tags" ]] && loser_tags="${loser_tags},${tags}"

		local loser_args=(
			--outcome "failure"
			--description "$loser_desc"
			--model "$loser"
			--tags "$loser_tags"
		)
		[[ -n "$task_type" ]] && loser_args+=(--task-type "$task_type")
		[[ -n "$task_id" ]] && loser_args+=(--task-id "$task_id")

		cmd_record "${loser_args[@]}"
	done

	log_success "Recorded A/B comparison: ${winner} wins"
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
pattern-tracker-helper.sh - Track and analyze success/failure patterns

USAGE:
    pattern-tracker-helper.sh <command> [options]

COMMANDS:
    record      Record a success or failure pattern
    score       Record structured quality scores (unified backbone for all tools) (t1094)
    ab-compare  Record A/B head-to-head model comparison results (t1094)
    analyze     Analyze patterns by task type or model
    suggest     Get suggestions based on past patterns for a task
    recommend   Recommend model tier based on historical success rates
    stats       Show pattern statistics (includes supervisor patterns)
    export      Export patterns as JSON or CSV
    report      Generate a comprehensive pattern report
    roi         Cost-per-task-type and tier ROI analysis (t1114)
    label-stats Correlate GitHub issue labels with pattern data (t1010)
    tier-drift  Analyze tier escalation frequency and cost impact (t1191)
    help        Show this help

RECORD OPTIONS:
    --outcome <success|failure>   Required: was this a success or failure?
    --task-type <type>            Task category (code-review, refactor, bugfix, etc.)
    --model <tier>                Model used (haiku, flash, sonnet, pro, opus)
    --description <text>          What happened (required)
    --task-id <id>                Task identifier (e.g., t102.3)
    --duration <seconds>          How long the task took
    --retries <count>             Number of retries before completion
    --tags <tags>                 Additional comma-separated tags
    --strategy <type>             Dispatch strategy: normal, prompt-repeat, escalated (t1095)
    --quality <level>             CI quality: ci-pass-first-try, ci-pass-after-fix, needs-human (t1095)
    --quality-score <n>           Output quality rating (t1096): 0=no_output 1=partial 2=complete
    --failure-mode <mode>         Failure classification: hallucination, context-miss,
                                  incomplete, wrong-file, timeout (t1095) or
                                  TRANSIENT, RESOURCE, LOGIC, BLOCKED, AMBIGUOUS, NONE (t1096)
    --tokens-in <count>           Input token count (t1095)
    --tokens-out <count>          Output token count (t1095)
    --estimated-cost <usd>        Explicit cost in USD (t1114; auto-calculated from tokens+model if omitted)

SCORE OPTIONS (t1094 — unified backbone):
    --model <tier>                Model tier (haiku|flash|sonnet|pro|opus)
    --task-type <type>            Task category
    --task-id <id>                Task identifier
    --correctness <1-5>           Factual accuracy score
    --completeness <1-5>          Coverage score
    --code-quality <1-5>          Code quality score
    --clarity <1-5>               Clarity/readability score
    --weighted-avg <float>        Pre-computed weighted average (overrides per-criterion)
    --outcome <success|failure>   Explicit outcome (auto-derived from avg if omitted)
    --strategy <type>             Prompt strategy: normal|prompt-repeat|escalated
    --quality <level>             CI quality: ci-pass-first-try|ci-pass-after-fix|needs-human
    --failure-mode <mode>         Failure classification
    --tokens-in <n>               Input token count
    --tokens-out <n>              Output token count
    --description <text>          Free-text description (auto-generated if omitted)
    --tags <tags>                 Additional comma-separated tags
    --source <name>               Source tool (response-scoring|compare-models|build-agent|evaluate|dispatch)

AB-COMPARE OPTIONS (t1094 — A/B comparison data):
    --winner <tier>               Winning model tier (required)
    --loser <tier>                Losing model tier (repeatable for multi-model)
    --task-type <type>            Task category
    --task-id <id>                Task identifier
    --winner-score <float>        Winner's weighted average score
    --loser-score <float>         Loser's weighted average score
    --margin <float>              Score margin (winner - loser)
    --models-compared <n>         Total number of models compared
    --description <text>          Free-text description
    --tags <tags>                 Additional comma-separated tags
    --source <name>               Source tool

ANALYZE OPTIONS:
    --task-type <type>            Filter by task type
    --model <tier>                Filter by model tier
    --limit <n>                   Max results per category (default: 20)

RECOMMEND OPTIONS:
    --task-type <type>            Filter recommendation by task type

ROI OPTIONS:
    --task-type <type>            Filter ROI analysis by task type
    --min-samples <n>             Minimum samples per tier to include (default: 3)

TIER-DRIFT OPTIONS (t1191):
    --days <n>                    Look back N days (default: 30)
    --json                        Output as JSON
    --summary                     One-line summary for pulse cycle integration

EXPORT OPTIONS:
    --format <json|csv>           Output format (default: json)

VALID TASK TYPES:
    code-review, refactor, bugfix, feature, docs, testing, deployment,
    security, architecture, planning, research, content, seo

EXAMPLES:
    # Unified score: record structured quality scores (t1094)
    pattern-tracker-helper.sh score \
        --model sonnet --task-type code-review --task-id t102.3 \
        --correctness 5 --completeness 4 --code-quality 5 --clarity 4 \
        --strategy normal --quality ci-pass-first-try \
        --tokens-in 12000 --tokens-out 5000 \
        --source response-scoring

    # A/B comparison: record which model won (t1094)
    pattern-tracker-helper.sh ab-compare \
        --winner sonnet --loser haiku --loser opus \
        --task-type code-review --winner-score 4.5 --loser-score 3.2 \
        --models-compared 3 --source compare-models

    # Record a success with full metadata
    pattern-tracker-helper.sh record --outcome success \
        --task-type code-review --model sonnet --task-id t102.3 \
        --duration 120 --description "Structured checklist caught 3 bugs"

    # Record a success with extended metadata (t1095)
    pattern-tracker-helper.sh record --outcome success \
        --task-type feature --model sonnet --task-id t200 \
        --strategy normal --quality ci-pass-first-try \
        --tokens-in 15000 --tokens-out 8000 \
        --description "Clean implementation, CI passed on first push"

    # Record a failure with failure mode classification
    pattern-tracker-helper.sh record --outcome failure \
        --task-type refactor --model haiku \
        --failure-mode context-miss --strategy escalated \
        --quality needs-human \
        --description "Haiku missed edge cases in complex refactor"

    # Record a failure
    pattern-tracker-helper.sh record --outcome failure \
        --task-type refactor --model haiku \
        --description "Haiku missed edge cases in complex refactor"

    # Get model recommendation for a task type
    pattern-tracker-helper.sh recommend --task-type bugfix

    # Analyze patterns for a task type
    pattern-tracker-helper.sh analyze --task-type bugfix

    # Get suggestions for a new task
    pattern-tracker-helper.sh suggest "refactor the auth middleware"

    # Export patterns as JSON
    pattern-tracker-helper.sh export --format json > patterns.json

    # Generate a report
    pattern-tracker-helper.sh report

    # View statistics
    pattern-tracker-helper.sh stats

    # ROI analysis: cost vs success rate across model tiers (t1114)
    pattern-tracker-helper.sh roi
    pattern-tracker-helper.sh roi --task-type feature
    pattern-tracker-helper.sh roi --task-type chore --min-samples 5

    # Record with cost data (auto-calculated from tokens + model tier)
    pattern-tracker-helper.sh record --outcome success \
        --task-type feature --model sonnet --task-id t200 \
        --tokens-in 15000 --tokens-out 8000 \
        --description "Clean implementation, CI passed on first push"

    # Tier drift analysis: detect sonnet->opus escalation patterns (t1191)
    pattern-tracker-helper.sh tier-drift
    pattern-tracker-helper.sh tier-drift --days 7 --json
    pattern-tracker-helper.sh tier-drift --summary  # one-line for pulse cycle
EOF
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	record) cmd_record "$@" ;;
	score) cmd_score "$@" ;;
	ab-compare) cmd_ab_compare "$@" ;;
	analyze) cmd_analyze "$@" ;;
	suggest) cmd_suggest "$@" ;;
	recommend) cmd_recommend "$@" ;;
	stats) cmd_stats ;;
	export) cmd_export "$@" ;;
	report) cmd_report ;;
	roi) cmd_roi "$@" ;;
	label-stats) cmd_label_stats "$@" ;;
	tier-drift) cmd_tier_drift "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
exit $?
