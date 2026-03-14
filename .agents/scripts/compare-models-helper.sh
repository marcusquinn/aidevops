#!/usr/bin/env bash
# shellcheck disable=SC2034

# Compare Models Helper - AI Model Capability Comparison
# Compare pricing, context windows, and capabilities across AI model providers.
#
# Usage: compare-models-helper.sh [command] [options]
#
# Commands:
#   list          List all tracked models
#   compare       Compare specific models side-by-side
#   recommend     Recommend models for a task type
#   pricing       Show pricing table
#   context       Show context window comparison
#   capabilities  Show capability matrix
#   providers     List supported providers
#   discover      Detect available providers and models from local config
#   cross-review  Dispatch same prompt to multiple models, diff results (t132.8)
#   bench         Live benchmark: send same prompt to N models, compare outputs (t1393)
#   help          Show this help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Pattern Tracker Integration (t1098)
# =============================================================================
# Reads live success/failure data from the pattern tracker memory DB.
# Same DB as pattern-tracker-helper.sh — no duplication of storage.

readonly PATTERN_DB="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"
readonly -a PATTERN_VALID_MODELS=(haiku flash sonnet pro opus)

# Check if pattern data is available
has_pattern_data() {
	[[ -f "$PATTERN_DB" ]] || return 1
	local count
	count=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN','FAILURE_PATTERN','WORKING_SOLUTION','FAILED_APPROACH','ERROR_FIX');" 2>/dev/null || echo "0")
	[[ "$count" -gt 0 ]] && return 0
	return 1
}

# Internal helper: get raw success/failure counts for a tier
# Usage: _get_tier_pattern_counts "sonnet" [task_type]
# Output: "successes|failures" (e.g. "12|3") or "0|0" if no data
_get_tier_pattern_counts() {
	local tier="$1"
	local task_type="${2:-}"
	[[ -f "$PATTERN_DB" ]] || {
		echo "0|0"
		return 0
	}

	local filter=""
	if [[ -n "$task_type" ]]; then
		filter="AND (tags LIKE '%${task_type}%' OR content LIKE '%task:${task_type}%')"
	fi

	local model_filter="AND (tags LIKE '%model:${tier}%' OR content LIKE '%model:${tier}%')"

	local successes failures
	successes=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter $filter;" 2>/dev/null || echo "0")
	failures=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter $filter;" 2>/dev/null || echo "0")

	echo "${successes}|${failures}"
	return 0
}

# Get success rate for a model tier
# Usage: get_tier_success_rate "sonnet" [task_type]
# Output: "85|47" (rate|sample_count) or "" if no data
get_tier_success_rate() {
	local tier="$1"
	local task_type="${2:-}"
	[[ -f "$PATTERN_DB" ]] || return 0

	local counts successes failures
	counts=$(_get_tier_pattern_counts "$tier" "$task_type")
	IFS='|' read -r successes failures <<<"$counts"

	local total=$((successes + failures))
	if [[ "$total" -gt 0 ]]; then
		local rate=$(((successes * 100) / total))
		echo "${rate}|${total}"
	fi
	return 0
}

# Map a model_id to its aidevops tier for pattern lookup
# Usage: model_id_to_tier "claude-sonnet-4-6" -> "sonnet"
model_id_to_tier() {
	local model_id="$1"
	case "$model_id" in
	*opus*) echo "opus" ;;
	*sonnet*) echo "sonnet" ;;
	*haiku*) echo "haiku" ;;
	*flash* | gemini-2.0*) echo "flash" ;;
	*pro* | gpt-4.1 | o3) echo "pro" ;;
	o4-mini | gpt-4.1-mini | gpt-4o-mini | deepseek* | llama* | gpt-4.1-nano) echo "haiku" ;;
	gpt-4o) echo "sonnet" ;;
	*) echo "" ;;
	esac
	return 0
}

# Format pattern data for display in tables
# Usage: format_pattern_badge "sonnet"
# Output: "85% (n=47)" or "" if no data
format_pattern_badge() {
	local tier="$1"
	local task_type="${2:-}"
	local data
	data=$(get_tier_success_rate "$tier" "$task_type")
	if [[ -n "$data" ]]; then
		local rate sample
		IFS='|' read -r rate sample <<<"$data"
		echo "${rate}% (n=${sample})"
	fi
	return 0
}

# Get all tier pattern data as a summary block
# Output: multi-line "tier|rate|samples" for tiers with data
get_all_tier_patterns() {
	local task_type="${1:-}"
	[[ -f "$PATTERN_DB" ]] || return 0

	for tier in "${PATTERN_VALID_MODELS[@]}"; do
		local data
		data=$(get_tier_success_rate "$tier" "$task_type")
		if [[ -n "$data" ]]; then
			echo "${tier}|${data}"
		fi
	done
	return 0
}

# =============================================================================
# Model Database (embedded reference data)
# =============================================================================
# Format: model_id|provider|display_name|context_window|input_price_per_1m|output_price_per_1m|tier|capabilities|best_for
# Prices in USD per 1M tokens. Last updated: 2026-02-18.
# Sources: Anthropic, OpenAI, Google official pricing pages.

readonly MODEL_DATA="claude-opus-4-6|Anthropic|Claude Opus 4.6|200000|5.00|25.00|high|code,reasoning,architecture,vision,tools|Architecture decisions, novel problems, complex multi-step reasoning
claude-sonnet-4-6|Anthropic|Claude Sonnet 4.6|200000|3.00|15.00|medium|code,reasoning,vision,tools|Code implementation, review, most development tasks
claude-haiku-4-5|Anthropic|Claude Haiku 4.5|200000|1.00|5.00|low|code,reasoning,vision,tools|Triage, classification, simple transforms, formatting
gpt-4.1|OpenAI|GPT-4.1|1048576|2.00|8.00|medium|code,reasoning,vision,tools,search|Coding, instruction following, long context
gpt-4.1-mini|OpenAI|GPT-4.1 Mini|1048576|0.40|1.60|low|code,reasoning,vision,tools|Cost-efficient coding and general tasks
gpt-4.1-nano|OpenAI|GPT-4.1 Nano|1048576|0.10|0.40|low|code,reasoning,tools|Fast classification, simple transforms
gpt-4o|OpenAI|GPT-4o|128000|2.50|10.00|medium|code,reasoning,vision,tools,search|General purpose, multimodal
gpt-4o-mini|OpenAI|GPT-4o Mini|128000|0.15|0.60|low|code,reasoning,vision,tools|Budget general purpose
o3|OpenAI|o3|200000|10.00|40.00|high|code,reasoning,math,science,tools|Complex reasoning, math, science
o4-mini|OpenAI|o4-mini|200000|1.10|4.40|medium|code,reasoning,math,tools|Cost-efficient reasoning
gemini-2.5-pro|Google|Gemini 2.5 Pro|1048576|1.25|10.00|medium|code,reasoning,vision,tools|Large context analysis, complex reasoning
gemini-2.5-flash|Google|Gemini 2.5 Flash|1048576|0.15|0.60|low|code,reasoning,vision,tools|Fast, cheap, large context
gemini-2.0-flash|Google|Gemini 2.0 Flash|1048576|0.10|0.40|low|code,reasoning,vision,tools|Budget large context processing
deepseek-r1|DeepSeek|DeepSeek R1|131072|0.55|2.19|low|code,reasoning,math|Deep reasoning, math, open-source
deepseek-v3|DeepSeek|DeepSeek V3|131072|0.27|1.10|low|code,reasoning|General purpose, cost-efficient
llama-4-maverick|Meta|Llama 4 Maverick|1048576|0.20|0.60|low|code,reasoning,vision,tools|Open-source, large context
llama-4-scout|Meta|Llama 4 Scout|512000|0.15|0.40|low|code,reasoning,vision,tools|Open-source, efficient"

# =============================================================================
# aidevops Tier Mapping
# =============================================================================
# Maps aidevops internal tiers to recommended models

readonly TIER_MAP="haiku|claude-haiku-4-5|Triage, classification, simple transforms
flash|gemini-2.5-flash|Large context reads, summarization, bulk processing
sonnet|claude-sonnet-4-6|Code implementation, review, most development tasks
pro|gemini-2.5-pro|Large codebase analysis, complex reasoning with big context
opus|claude-opus-4-6|Architecture decisions, complex multi-step reasoning"

# =============================================================================
# Task-to-Model Recommendations
# =============================================================================

readonly TASK_RECOMMENDATIONS="code review|claude-sonnet-4-6|o4-mini|gemini-2.5-flash
code implementation|claude-sonnet-4-6|gpt-4.1|gemini-2.5-pro
architecture design|claude-opus-4-6|o3|gemini-2.5-pro
bug fixing|claude-sonnet-4-6|gpt-4.1|o4-mini
refactoring|claude-sonnet-4-6|gpt-4.1|gemini-2.5-pro
documentation|claude-sonnet-4-6|gpt-4o|gemini-2.5-flash
testing|claude-sonnet-4-6|gpt-4.1|o4-mini
classification|claude-haiku-4-5|gpt-4.1-nano|gemini-2.5-flash
summarization|gemini-2.5-flash|gpt-4o-mini|claude-haiku-4-5
large codebase analysis|gemini-2.5-pro|gpt-4.1|claude-sonnet-4-6
math reasoning|o3|deepseek-r1|gemini-2.5-pro
security audit|claude-opus-4-6|o3|claude-sonnet-4-6
data extraction|gemini-2.5-flash|gpt-4o-mini|claude-haiku-4-5
commit messages|claude-haiku-4-5|gpt-4.1-nano|gemini-2.5-flash
pr description|claude-sonnet-4-6|gpt-4o|gemini-2.5-flash"

# =============================================================================
# Helper Functions
# =============================================================================

# Get a field from a model data line
# Usage: get_field "model_line" field_number
get_field() {
	local line="$1"
	local field="$2"
	echo "$line" | cut -d'|' -f"$field"
	return 0
}

# Find model by partial name match
find_model() {
	local query="$1"
	local lower_query
	lower_query=$(echo "$query" | tr '[:upper:]' '[:lower:]')
	echo "$MODEL_DATA" | while IFS= read -r line; do
		local model_id
		model_id=$(get_field "$line" 1)
		local display_name
		display_name=$(get_field "$line" 3)
		local lower_id
		lower_id=$(echo "$model_id" | tr '[:upper:]' '[:lower:]')
		local lower_name
		lower_name=$(echo "$display_name" | tr '[:upper:]' '[:lower:]')
		if [[ "$lower_id" == *"$lower_query"* ]] || [[ "$lower_name" == *"$lower_query"* ]]; then
			echo "$line"
		fi
	done
	return 0
}

# Format number with padding
pad_right() {
	local str="$1"
	local width="$2"
	printf "%-${width}s" "$str"
	return 0
}

# Format price for display
format_price() {
	local price="$1"
	printf "\$%s" "$price"
	return 0
}

# Format context window for display
format_context() {
	local ctx="$1"
	if [[ "$ctx" -ge 1000000 ]]; then
		echo "1M"
	elif [[ "$ctx" -ge 500000 ]]; then
		echo "512K"
	elif [[ "$ctx" -ge 200000 ]]; then
		echo "200K"
	elif [[ "$ctx" -ge 131072 ]]; then
		echo "131K"
	elif [[ "$ctx" -ge 128000 ]]; then
		echo "128K"
	else
		echo "${ctx}"
	fi
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
	echo ""
	echo "Tracked AI Models"
	echo "================="
	echo ""
	printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
		"Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier" "Best For"
	printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
		"-----" "--------" "-------" "--------" "---------" "----" "--------"

	echo "$MODEL_DATA" | while IFS= read -r line; do
		local model_id provider ctx input output tier best
		model_id=$(get_field "$line" 1)
		provider=$(get_field "$line" 2)
		ctx=$(get_field "$line" 4)
		input=$(get_field "$line" 5)
		output=$(get_field "$line" 6)
		tier=$(get_field "$line" 7)
		best=$(get_field "$line" 9)
		local ctx_fmt
		ctx_fmt=$(format_context "$ctx")
		# Truncate best_for for table display
		local best_short="${best:0:40}"
		printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
			"$model_id" "$provider" "$ctx_fmt" "\$$input" "\$$output" "$tier" "$best_short"
	done

	echo ""
	echo "Prices: USD per 1M tokens. Last updated: 2025-02-08."

	# Pattern data integration (t1098)
	if has_pattern_data; then
		echo ""
		echo "Live Success Rates (from pattern tracker):"
		local pattern_found=false
		for ptier in "${PATTERN_VALID_MODELS[@]}"; do
			local badge
			badge=$(format_pattern_badge "$ptier")
			if [[ -n "$badge" ]]; then
				printf "  %-10s %s\n" "$ptier:" "$badge"
				pattern_found=true
			fi
		done
		if [[ "$pattern_found" != "true" ]]; then
			echo "  (no model-tagged patterns recorded yet)"
		fi
	fi

	echo ""
	echo "Run 'compare-models-helper.sh help' for more commands."
	return 0
}

cmd_compare() {
	local models=("$@")
	if [[ ${#models[@]} -lt 1 ]]; then
		print_error "Usage: compare-models-helper.sh compare <model1> [model2] ..."
		return 1
	fi

	echo ""
	echo "Model Comparison"
	echo "================"
	echo ""

	local found_any=false
	local results=()

	for query in "${models[@]}"; do
		local matches
		matches=$(find_model "$query")
		if [[ -z "$matches" ]]; then
			print_warning "No model found matching: $query"
		else
			while IFS= read -r match; do
				results+=("$match")
				found_any=true
			done <<<"$matches"
		fi
	done

	if [[ "$found_any" != "true" ]]; then
		print_error "No models found. Run 'compare-models-helper.sh list' to see available models."
		return 1
	fi

	printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
		"Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier"
	printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
		"-----" "--------" "-------" "--------" "---------" "----"

	for line in "${results[@]}"; do
		local model_id provider ctx input output tier
		model_id=$(get_field "$line" 1)
		provider=$(get_field "$line" 2)
		ctx=$(get_field "$line" 4)
		input=$(get_field "$line" 5)
		output=$(get_field "$line" 6)
		tier=$(get_field "$line" 7)
		local ctx_fmt
		ctx_fmt=$(format_context "$ctx")
		printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
			"$model_id" "$provider" "$ctx_fmt" "\$$input" "\$$output" "$tier"
	done

	echo ""
	echo "Capabilities:"
	for line in "${results[@]}"; do
		local model_id caps best
		model_id=$(get_field "$line" 1)
		caps=$(get_field "$line" 8)
		best=$(get_field "$line" 9)
		echo "  $model_id: $caps"
		echo "    Best for: $best"
		# Pattern data badge (t1098)
		local mapped_tier
		mapped_tier=$(model_id_to_tier "$model_id")
		if [[ -n "$mapped_tier" ]]; then
			local badge
			badge=$(format_pattern_badge "$mapped_tier")
			if [[ -n "$badge" ]]; then
				echo "    Success rate: $badge (tier: $mapped_tier)"
			fi
		fi
	done

	# Cost comparison
	if [[ ${#results[@]} -ge 2 ]]; then
		echo ""
		echo "Cost Analysis (per 1M tokens):"
		local cheapest_input="" cheapest_input_price=999999
		local cheapest_output="" cheapest_output_price=999999
		for line in "${results[@]}"; do
			local model_id input output
			model_id=$(get_field "$line" 1)
			input=$(get_field "$line" 5)
			output=$(get_field "$line" 6)
			# Use awk for float comparison
			if awk "BEGIN{exit !($input < $cheapest_input_price)}"; then
				cheapest_input="$model_id"
				cheapest_input_price="$input"
			fi
			if awk "BEGIN{exit !($output < $cheapest_output_price)}"; then
				cheapest_output="$model_id"
				cheapest_output_price="$output"
			fi
		done
		echo "  Cheapest input:  $cheapest_input (\$$cheapest_input_price/1M)"
		echo "  Cheapest output: $cheapest_output (\$$cheapest_output_price/1M)"
	fi

	return 0
}

cmd_recommend() {
	local task_desc="$1"
	if [[ -z "$task_desc" ]]; then
		print_error "Usage: compare-models-helper.sh recommend <task description>"
		return 1
	fi

	local lower_task
	lower_task=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]')

	echo ""
	echo "Model Recommendation"
	echo "===================="
	echo "Task: $task_desc"
	echo ""

	local found=false
	while IFS= read -r line; do
		local task_pattern recommended runner_up budget
		task_pattern=$(echo "$line" | cut -d'|' -f1)
		recommended=$(echo "$line" | cut -d'|' -f2)
		runner_up=$(echo "$line" | cut -d'|' -f3)
		budget=$(echo "$line" | cut -d'|' -f4)

		if [[ "$lower_task" == *"$task_pattern"* ]] || [[ "$task_pattern" == *"$lower_task"* ]]; then
			echo "  Recommended: $recommended"
			echo "  Runner-up:   $runner_up"
			echo "  Budget:      $budget"
			echo ""

			# Show pricing for recommended models
			for model in "$recommended" "$runner_up" "$budget"; do
				local match
				match=$(find_model "$model" | head -1)
				if [[ -n "$match" ]]; then
					local input output ctx
					input=$(get_field "$match" 5)
					output=$(get_field "$match" 6)
					ctx=$(get_field "$match" 4)
					local ctx_fmt
					ctx_fmt=$(format_context "$ctx")
					# Pattern data badge (t1098)
					local mapped_tier badge price_line
					mapped_tier=$(model_id_to_tier "$model")
					badge=$(format_pattern_badge "$mapped_tier")
					price_line="  $model: \$$input/\$$output per 1M tokens, ${ctx_fmt} context"
					if [[ -n "$badge" ]]; then
						price_line="$price_line — ${badge} success"
					fi
					echo "$price_line"
				fi
			done
			found=true
		fi
	done <<<"$TASK_RECOMMENDATIONS"

	if [[ "$found" != "true" ]]; then
		echo "No exact task match. Showing general recommendations:"
		echo ""
		echo "  High capability: claude-opus-4-6 or o3"
		echo "  Balanced:        claude-sonnet-4-6 or gpt-4.1"
		echo "  Budget:          gemini-2.5-flash or gpt-4.1-nano"
		echo "  Large context:   gemini-2.5-pro or gpt-4.1 (1M tokens)"
		echo ""
		echo "Available task types:"
		echo "$TASK_RECOMMENDATIONS" | cut -d'|' -f1 | while IFS= read -r t; do
			echo "  - $t"
		done
	fi

	# Pattern-based insights (t1098)
	if has_pattern_data; then
		echo ""
		echo "Pattern Tracker Insights:"
		local pattern_lines
		pattern_lines=$(get_all_tier_patterns "")
		if [[ -n "$pattern_lines" ]]; then
			while IFS='|' read -r ptier prate psample; do
				printf "  %-10s %d%% success (n=%d)\n" "$ptier:" "$prate" "$psample"
			done <<<"$pattern_lines"
		else
			echo "  (no model-tagged patterns — record with pattern-tracker-helper.sh)"
		fi
	fi

	return 0
}

cmd_pricing() {
	echo ""
	echo "AI Model Pricing (USD per 1M tokens)"
	echo "====================================="
	echo ""
	echo "Sorted by input price (cheapest first):"
	echo ""
	printf "%-22s %-10s %-12s %-12s %-7s\n" \
		"Model" "Provider" "Input/1M" "Output/1M" "Tier"
	printf "%-22s %-10s %-12s %-12s %-7s\n" \
		"-----" "--------" "--------" "---------" "----"

	echo "$MODEL_DATA" | sort -t'|' -k5 -n | while IFS= read -r line; do
		local model_id provider input output tier
		model_id=$(get_field "$line" 1)
		provider=$(get_field "$line" 2)
		input=$(get_field "$line" 5)
		output=$(get_field "$line" 6)
		tier=$(get_field "$line" 7)
		printf "%-22s %-10s %-12s %-12s %-7s\n" \
			"$model_id" "$provider" "\$$input" "\$$output" "$tier"
	done

	echo ""
	echo "Last updated: 2025-02-08. Run /compare-models for live pricing check."
	return 0
}

cmd_context() {
	echo ""
	echo "Context Window Comparison"
	echo "========================="
	echo ""
	echo "Sorted by context window (largest first):"
	echo ""
	printf "%-22s %-10s %-12s %-12s\n" \
		"Model" "Provider" "Context" "Tokens"
	printf "%-22s %-10s %-12s %-12s\n" \
		"-----" "--------" "-------" "------"

	echo "$MODEL_DATA" | sort -t'|' -k4 -rn | while IFS= read -r line; do
		local model_id provider ctx
		model_id=$(get_field "$line" 1)
		provider=$(get_field "$line" 2)
		ctx=$(get_field "$line" 4)
		local ctx_fmt
		ctx_fmt=$(format_context "$ctx")
		printf "%-22s %-10s %-12s %-12s\n" \
			"$model_id" "$provider" "$ctx_fmt" "$ctx"
	done

	return 0
}

cmd_capabilities() {
	echo ""
	echo "Model Capability Matrix"
	echo "======================="
	echo ""
	printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
		"Model" "Code" "Reas." "Vis." "Tools" "Math" "Srch." "Arch."
	printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
		"-----" "----" "-----" "----" "-----" "----" "-----" "-----"

	echo "$MODEL_DATA" | while IFS= read -r line; do
		local model_id caps tier
		model_id=$(get_field "$line" 1)
		caps=$(get_field "$line" 8)
		tier=$(get_field "$line" 7)

		local has_code="--" has_reason="--" has_vision="--" has_tools="--"
		local has_math="--" has_search="--" has_arch="--"

		[[ "$caps" == *"code"* ]] && has_code="Y"
		[[ "$caps" == *"reasoning"* ]] && has_reason="Y"
		[[ "$caps" == *"vision"* ]] && has_vision="Y"
		[[ "$caps" == *"tools"* ]] && has_tools="Y"
		[[ "$caps" == *"math"* ]] && has_math="Y"
		[[ "$caps" == *"search"* ]] && has_search="Y"
		[[ "$caps" == *"architecture"* ]] && has_arch="Y"

		printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
			"$model_id" "$has_code" "$has_reason" "$has_vision" "$has_tools" \
			"$has_math" "$has_search" "$has_arch"
	done

	echo ""
	echo "Y = supported, -- = not listed"
	echo ""
	echo "aidevops Tier Mapping:"
	echo "$TIER_MAP" | while IFS= read -r line; do
		local tier model purpose
		tier=$(echo "$line" | cut -d'|' -f1)
		model=$(echo "$line" | cut -d'|' -f2)
		purpose=$(echo "$line" | cut -d'|' -f3)
		# Pattern data badge (t1098)
		local badge
		badge=$(format_pattern_badge "$tier")
		if [[ -n "$badge" ]]; then
			printf "  %-8s -> %-22s (%s) [%s success]\n" "$tier" "$model" "$purpose" "$badge"
		else
			printf "  %-8s -> %-22s (%s)\n" "$tier" "$model" "$purpose"
		fi
	done

	return 0
}

cmd_providers() {
	echo ""
	echo "Supported Providers"
	echo "==================="
	echo ""

	local providers
	providers=$(echo "$MODEL_DATA" | cut -d'|' -f2 | sort -u)

	echo "$providers" | while IFS= read -r provider; do
		local count
		count=$(echo "$MODEL_DATA" | grep -c "|${provider}|")
		echo "  $provider ($count models)"
		echo "$MODEL_DATA" | grep "|${provider}|" | while IFS= read -r line; do
			local model_id tier
			model_id=$(get_field "$line" 1)
			tier=$(get_field "$line" 7)
			echo "    - $model_id ($tier)"
		done
		echo ""
	done

	return 0
}

# =============================================================================
# Cross-Model Review (t132.8)
# Dispatch the same review prompt to multiple models, collect results, diff.
# =============================================================================

# Judge scoring for cross-review (t1329)
# Dispatches all model outputs to a judge model, parses structured JSON scores,
# records results via cmd_score, and feeds into the pattern tracker.
# Defined before cmd_cross_review (its caller) for readability.
#
# Args:
#   $1 - original prompt
#   $2 - models_str (comma-separated)
#   $3 - output_dir
#   $4 - judge_model tier
#   $5 - prompt_version (may be empty)
#   $6 - prompt_file (may be empty)
#   $7+ - model_names array
_cross_review_judge_score() {
	local original_prompt="$1"
	local models_str="$2"
	local output_dir="$3"
	local judge_model="$4"
	local prompt_version="$5"
	local prompt_file="$6"
	shift 6
	local -a model_names=("$@")

	# Validate judge_model identifier (used in filenames and runner names)
	if [[ ! "$judge_model" =~ ^[A-Za-z0-9._-]+$ ]]; then
		print_error "Invalid judge model identifier: $judge_model"
		return 1
	fi

	local runner_helper="${SCRIPT_DIR}/runner-helper.sh"
	if [[ ! -x "$runner_helper" ]]; then
		print_warning "runner-helper.sh not found — skipping judge scoring"
		return 0
	fi

	echo "=== JUDGE SCORING (${judge_model}) ==="
	echo ""

	# Build judge prompt: include original prompt + all model responses
	local judge_prompt
	judge_prompt="You are a neutral judge evaluating AI model responses. Score each response on a 1-10 scale.

ORIGINAL PROMPT:
${original_prompt}

MODEL RESPONSES:
"
	# Bound per-model response size to keep judge payload within token limits
	local max_chars_per_model=20000
	local models_with_output=()
	for model_tier in "${model_names[@]}"; do
		local result_file="${output_dir}/${model_tier}.txt"
		if [[ -f "$result_file" && -s "$result_file" ]]; then
			local response_text
			response_text=$(head -c "$max_chars_per_model" "$result_file")
			local file_size
			file_size=$(wc -c <"$result_file" | tr -d ' ')
			local truncated_marker=""
			if [[ "$file_size" -gt "$max_chars_per_model" ]]; then
				truncated_marker="
[TRUNCATED — original ${file_size} chars, showing first ${max_chars_per_model}]"
			fi
			judge_prompt+="
=== MODEL: ${model_tier} ===
${response_text}${truncated_marker}
"
			models_with_output+=("$model_tier")
		fi
	done

	if [[ ${#models_with_output[@]} -lt 2 ]]; then
		print_warning "Not enough model outputs for judge scoring (need 2+)"
		return 0
	fi

	judge_prompt+="
SCORING INSTRUCTIONS:
Score each model on these criteria (1-10 scale):
- correctness: Factual accuracy and technical correctness
- completeness: Coverage of all requirements and edge cases
- quality: Code quality, best practices, maintainability
- clarity: Clear explanation, good formatting, readability
- adherence: Following the original prompt instructions precisely

Respond with ONLY a valid JSON object in this exact format (no markdown, no explanation):
{
  \"task_type\": \"general\",
  \"winner\": \"<model_tier_of_best_response>\",
  \"reasoning\": \"<one sentence explaining the winner>\",
  \"scores\": {
    \"<model_tier>\": {
      \"correctness\": <1-10>,
      \"completeness\": <1-10>,
      \"quality\": <1-10>,
      \"clarity\": <1-10>,
      \"adherence\": <1-10>
    }
  }
}"

	# Sanitize judge_model before using in filenames/runner names
	if [[ ! "$judge_model" =~ ^[A-Za-z0-9._-]+$ ]]; then
		print_warning "Invalid judge model identifier: $judge_model — skipping scoring"
		return 0
	fi

	# Dispatch to judge model
	local judge_runner="cross-review-judge-$$"
	local judge_output_file="${output_dir}/judge-${judge_model}.json"

	echo "  Dispatching to judge (${judge_model})..."

	local judge_err_log="${output_dir}/judge-errors.log"

	"$runner_helper" create "$judge_runner" \
		--model "$judge_model" \
		--description "Cross-review judge" \
		--workdir "$(pwd)" 2>>"$judge_err_log" || true

	"$runner_helper" run "$judge_runner" "$judge_prompt" \
		--model "$judge_model" \
		--timeout "120" \
		--format text >"$judge_output_file" 2>>"$judge_err_log" || true

	"$runner_helper" destroy "$judge_runner" --force 2>>"$judge_err_log" || true

	if [[ ! -f "$judge_output_file" || ! -s "$judge_output_file" ]]; then
		print_warning "Judge model returned no output — skipping scoring"
		return 0
	fi

	# Extract JSON from judge output (strip any surrounding text)
	local judge_json
	judge_json=$(grep -o '{.*}' "$judge_output_file" 2>>"$judge_err_log" | head -1 || true)
	if [[ -z "$judge_json" ]]; then
		# Try multiline JSON extraction via stdin (safe for paths with special chars)
		judge_json=$(python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    try:
        obj = json.loads(m.group())
        print(json.dumps(obj))
    except Exception:
        pass
" <"$judge_output_file" 2>>"$judge_err_log" || true)
	fi

	if [[ -z "$judge_json" ]]; then
		print_warning "Could not parse judge JSON output. Raw output saved to: $judge_output_file"
		return 0
	fi

	# Parse winner, task_type, and reasoning in a single Python call
	local parsed_fields
	parsed_fields=$(echo "$judge_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Truncate reasoning to 500 chars and strip control characters
r = d.get('reasoning', '')[:500]
r = ''.join(c for c in r if c.isprintable() or c in (' ', '\t'))
print(d.get('winner', ''))
print(d.get('task_type', 'general'))
print(r)
" 2>>"$judge_err_log" || true)

	local winner task_type reasoning
	if [[ -n "$parsed_fields" ]]; then
		winner=$(echo "$parsed_fields" | head -1)
		task_type=$(echo "$parsed_fields" | sed -n '2p')
		reasoning=$(echo "$parsed_fields" | sed -n '3p')
	else
		winner=""
		task_type="general"
		reasoning=""
	fi

	# Sanitize task_type: restrict to known allowlist
	local -a valid_task_types=(general code review analysis debug refactor test docs security)
	local task_type_valid=false
	for vt in "${valid_task_types[@]}"; do
		if [[ "$task_type" == "$vt" ]]; then
			task_type_valid=true
			break
		fi
	done
	if [[ "$task_type_valid" != "true" ]]; then
		task_type="general"
	fi

	# Sanitize winner: must be one of the models with output
	local winner_valid=false
	if [[ -n "$winner" ]]; then
		for m in "${models_with_output[@]}"; do
			if [[ "$winner" == "$m" ]]; then
				winner_valid=true
				break
			fi
		done
		if [[ "$winner_valid" != "true" ]]; then
			print_warning "Judge returned unknown winner '${winner}' — ignoring"
			winner=""
		fi
	fi

	echo "  Judge winner: ${winner:-unknown}"
	[[ -n "$reasoning" ]] && echo "  Reasoning: ${reasoning}"
	echo ""

	# Helper: clamp a numeric value to integer in range 0-10
	# Handles decimals correctly (e.g. 8.5 → 9 via rounding, not 85)
	_clamp_score() {
		local val="$1"
		# Accept only valid numeric format (digits with optional single decimal point)
		if [[ ! "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
			echo "0"
			return 0
		fi
		# Round to nearest integer and clamp to 0-10
		local int_val
		int_val=$(printf '%.0f' "$val" 2>/dev/null || echo "0")
		if [[ "$int_val" -gt 10 ]]; then
			echo "10"
		elif [[ "$int_val" -lt 0 ]]; then
			echo "0"
		else
			echo "$int_val"
		fi
		return 0
	}

	# Build cmd_score arguments from judge JSON
	local -a score_args=(
		--task "$original_prompt"
		--type "$task_type"
		--evaluator "$judge_model"
	)
	[[ -n "$winner" ]] && score_args+=(--winner "$winner")
	[[ -n "$prompt_version" ]] && score_args+=(--prompt-version "$prompt_version")
	[[ -n "$prompt_file" ]] && score_args+=(--prompt-file "$prompt_file")

	for model_tier in "${models_with_output[@]}"; do
		# Extract all scores in a single Python call (avoids 5 subprocesses per model)
		local scores_line
		scores_line=$(echo "$judge_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('scores', {}).get('${model_tier}', {})
print(s.get('correctness', 0), s.get('completeness', 0), s.get('quality', 0), s.get('clarity', 0), s.get('adherence', 0))
" 2>>"$judge_err_log" || echo "0 0 0 0 0")
		local corr comp qual clar adhr
		read -r corr comp qual clar adhr <<<"$scores_line"

		# Clamp all scores to valid integer range 0-10
		corr=$(_clamp_score "$corr")
		comp=$(_clamp_score "$comp")
		qual=$(_clamp_score "$qual")
		clar=$(_clamp_score "$clar")
		adhr=$(_clamp_score "$adhr")

		score_args+=(
			--model "$model_tier"
			--correctness "$corr"
			--completeness "$comp"
			--quality "$qual"
			--clarity "$clar"
			--adherence "$adhr"
		)
	done

	# Record scores via cmd_score (also syncs to pattern tracker)
	cmd_score "${score_args[@]}"

	echo "Judge scores recorded. Judge output: $judge_output_file"
	echo ""

	return 0
}

#######################################
# Cross-model review: dispatch same prompt to multiple models (t132.8, t1329)
# Usage: compare-models-helper.sh cross-review --prompt "review this code" \
#          --models "sonnet,opus,pro" [--workdir path] [--timeout N] [--output dir]
#          [--score] [--judge <model>]
# Dispatches via runner-helper.sh in parallel, collects outputs, produces summary.
# With --score: feeds outputs to a judge model (default: opus) for structured scoring
# and records results in the model-comparisons DB + pattern tracker.
#######################################
cmd_cross_review() {
	local prompt="" models_str="" workdir="" review_timeout="600" output_dir=""
	local score_flag=false judge_model="opus"
	local prompt_version="" prompt_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--prompt)
			[[ $# -lt 2 ]] && {
				print_error "--prompt requires a value"
				return 1
			}
			prompt="$2"
			shift 2
			;;
		--models)
			[[ $# -lt 2 ]] && {
				print_error "--models requires a value"
				return 1
			}
			models_str="$2"
			shift 2
			;;
		--workdir)
			[[ $# -lt 2 ]] && {
				print_error "--workdir requires a value"
				return 1
			}
			workdir="$2"
			shift 2
			;;
		--timeout)
			[[ $# -lt 2 ]] && {
				print_error "--timeout requires a value"
				return 1
			}
			review_timeout="$2"
			shift 2
			;;
		--output)
			[[ $# -lt 2 ]] && {
				print_error "--output requires a value"
				return 1
			}
			output_dir="$2"
			shift 2
			;;
		--score)
			score_flag=true
			shift
			;;
		--judge)
			[[ $# -lt 2 ]] && {
				print_error "--judge requires a value"
				return 1
			}
			judge_model="$2"
			# Validate judge model identifier (used in filenames)
			if [[ ! "$judge_model" =~ ^[A-Za-z0-9._-]+$ ]]; then
				print_error "Invalid judge model identifier: $judge_model (only alphanumeric, dots, hyphens, underscores)"
				return 1
			fi
			shift 2
			;;
		--prompt-version)
			[[ $# -lt 2 ]] && {
				print_error "--prompt-version requires a value"
				return 1
			}
			prompt_version="$2"
			shift 2
			;;
		--prompt-file)
			[[ $# -lt 2 ]] && {
				print_error "--prompt-file requires a value"
				return 1
			}
			prompt_file="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$prompt" ]]; then
		print_error "--prompt is required"
		echo "Usage: compare-models-helper.sh cross-review --prompt \"review this code\" --models \"sonnet,opus,pro\""
		return 1
	fi

	# Default models: sonnet + opus (Anthropic second opinion)
	if [[ -z "$models_str" ]]; then
		models_str="sonnet,opus"
	fi

	# Set up output directory
	if [[ -z "$output_dir" ]]; then
		output_dir="${HOME}/.aidevops/.agent-workspace/tmp/cross-review-$(date +%Y%m%d%H%M%S)"
	fi
	mkdir -p "$output_dir"

	# Set workdir
	if [[ -z "$workdir" ]]; then
		workdir="$(pwd)"
	fi

	local runner_helper="${SCRIPT_DIR}/runner-helper.sh"
	if [[ ! -x "$runner_helper" ]]; then
		print_error "runner-helper.sh not found at $runner_helper"
		return 1
	fi

	# Parse models list
	local -a model_array=()
	IFS=',' read -ra model_array <<<"$models_str"

	if [[ ${#model_array[@]} -lt 2 ]]; then
		print_error "At least 2 models required for cross-review (got ${#model_array[@]})"
		return 1
	fi

	echo ""
	echo "Cross-Model Review"
	echo "==================="
	echo "Models: ${models_str}"
	echo "Output: ${output_dir}"
	echo "Timeout: ${review_timeout}s per model"
	echo ""

	# Create temporary runners for each model and dispatch in parallel
	local -a pids=()
	local -a runner_names=()
	local -a model_names=()

	for model_tier in "${model_array[@]}"; do
		model_tier="${model_tier// /}"
		[[ -z "$model_tier" ]] && continue

		# Sanitize model identifier to prevent path traversal (reject chars outside safe set)
		if [[ ! "$model_tier" =~ ^[A-Za-z0-9._-]+$ ]]; then
			print_warning "Skipping invalid model identifier: $model_tier"
			continue
		fi

		local runner_name="cross-review-${model_tier}-$$"
		runner_names+=("$runner_name")
		model_names+=("$model_tier")

		# Resolve tier to full model string for display
		local resolved_model
		resolved_model=$(resolve_model_tier "$model_tier")

		echo "  Dispatching to ${model_tier} (${resolved_model})..."

		# Create runner, dispatch, capture output (errors logged per-model for debugging)
		local model_err_log="${output_dir}/${model_tier}-errors.log"
		(
			local model_failed=0

			"$runner_helper" create "$runner_name" \
				--model "$model_tier" \
				--description "Cross-review: $model_tier" \
				--workdir "$workdir" 2>>"$model_err_log" || model_failed=1

			local result_file="${output_dir}/${model_tier}.txt"
			"$runner_helper" run "$runner_name" "$prompt" \
				--model "$model_tier" \
				--timeout "$review_timeout" \
				--format json 2>>"$model_err_log" >"${output_dir}/${model_tier}.json" || model_failed=1

			# Extract text response from JSON
			if [[ -f "${output_dir}/${model_tier}.json" ]]; then
				jq -r '.parts[]? | select(.type == "text") | .text' \
					"${output_dir}/${model_tier}.json" 2>>"$model_err_log" >"$result_file" || model_failed=1
			fi

			# Clean up runner (always attempt cleanup, even on failure)
			"$runner_helper" destroy "$runner_name" --force 2>>"$model_err_log" || true

			# Fail if no usable output was produced
			[[ -s "$result_file" ]] || model_failed=1
			exit "$model_failed"
		) &
		pids+=($!)
	done

	# Wait for all dispatches to complete
	echo ""
	echo "Waiting for ${#pids[@]} models to respond..."
	local failed=0
	for i in "${!pids[@]}"; do
		if ! wait "${pids[$i]}" 2>/dev/null; then
			local err_log="${output_dir}/${model_names[$i]}-errors.log"
			echo "  ${model_names[$i]}: failed (see ${err_log})"
			failed=$((failed + 1))
		else
			echo "  ${model_names[$i]}: done"
		fi
	done

	echo ""

	# Collect and display results
	local results_found=0
	for model_tier in "${model_names[@]}"; do
		local result_file="${output_dir}/${model_tier}.txt"
		if [[ -f "$result_file" && -s "$result_file" ]]; then
			results_found=$((results_found + 1))
			echo "=== ${model_tier} ==="
			echo ""
			cat "$result_file"
			echo ""
			echo "---"
			echo ""
		fi
	done

	if [[ "$results_found" -lt 2 ]]; then
		print_warning "Only $results_found model(s) returned results. Need at least 2 for comparison."
		echo "Check output directory: $output_dir"
		return 1
	fi

	# Generate diff summary if we have 2+ results
	echo "=== DIFF SUMMARY ==="
	echo ""
	echo "Models compared: ${models_str}"
	echo "Results: ${results_found}/${#model_names[@]} successful"
	echo ""

	# Word count comparison
	echo "Response sizes:"
	for model_tier in "${model_names[@]}"; do
		local result_file="${output_dir}/${model_tier}.txt"
		if [[ -f "$result_file" && -s "$result_file" ]]; then
			local wc_result
			wc_result=$(wc -w <"$result_file" | tr -d ' ')
			echo "  ${model_tier}: ${wc_result} words"
		fi
	done
	echo ""

	# If exactly 2 models, show a simple diff
	if [[ ${#model_names[@]} -eq 2 ]]; then
		local file_a="${output_dir}/${model_names[0]}.txt"
		local file_b="${output_dir}/${model_names[1]}.txt"
		if [[ -f "$file_a" && -f "$file_b" ]]; then
			echo "Diff (${model_names[0]} vs ${model_names[1]}):"
			# diff exits 1 when files differ — capture separately to avoid pipefail
			local diff_output diff_status
			diff_output=$(diff --unified=3 "$file_a" "$file_b" 2>/dev/null) && diff_status=$? || diff_status=$?
			if [[ "$diff_status" -le 1 && -n "$diff_output" ]]; then
				echo "$diff_output" | head -100
			else
				echo "  (files are identical or diff unavailable)"
			fi
			echo ""
		fi
	fi

	echo "Full results saved to: $output_dir"
	echo ""

	# Judge scoring pipeline (t1329)
	# When --score is set, dispatch all outputs to a judge model for structured scoring.
	if [[ "$score_flag" == "true" ]]; then
		_cross_review_judge_score \
			"$prompt" "$models_str" "$output_dir" "$judge_model" \
			"$prompt_version" "$prompt_file" "${model_names[@]}"
	fi

	return 0
}

# =============================================================================
# Pattern Data Command (t1098)
# =============================================================================
# Focused view of live pattern tracker data alongside model specs.

cmd_patterns() {
	local task_type=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task-type)
			task_type="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	echo ""
	echo "Model Performance (Live Pattern Data)"
	echo "======================================"
	echo ""

	if ! has_pattern_data; then
		echo "No pattern data available."
		echo ""
		echo "Record patterns to populate this view:"
		echo "  pattern-tracker-helper.sh record --outcome success --model sonnet --task-type code-review \\"
		echo "    --description \"Completed code review successfully\""
		echo ""
		echo "The supervisor also records patterns automatically after each task."
		return 0
	fi

	if [[ -n "$task_type" ]]; then
		echo "Task type filter: $task_type"
		echo ""
	fi

	# Header
	printf "  %-10s %-22s %8s %8s %10s %-12s %-12s\n" \
		"Tier" "Primary Model" "Success" "Failure" "Rate" "Input/1M" "Output/1M"
	printf "  %-10s %-22s %8s %8s %10s %-12s %-12s\n" \
		"----" "-------------" "-------" "-------" "----" "--------" "---------"

	# Iterate tiers from TIER_MAP to get primary model + pricing
	echo "$TIER_MAP" | while IFS= read -r tier_line; do
		local tier primary_model
		tier=$(echo "$tier_line" | cut -d'|' -f1)
		primary_model=$(echo "$tier_line" | cut -d'|' -f2)

		# Get pricing from MODEL_DATA
		local model_match input_price output_price
		model_match=$(echo "$MODEL_DATA" | grep "^${primary_model}|" || true)
		if [[ -n "$model_match" ]]; then
			input_price=$(get_field "$model_match" 5)
			output_price=$(get_field "$model_match" 6)
		else
			input_price="-"
			output_price="-"
		fi

		# Get pattern data via shared helper
		local counts successes failures
		counts=$(_get_tier_pattern_counts "$tier" "$task_type")
		IFS='|' read -r successes failures <<<"$counts"

		local total=$((successes + failures))
		if [[ "$total" -gt 0 ]]; then
			local rate=$(((successes * 100) / total))
			printf "  %-10s %-22s %8d %8d %9d%% %-12s %-12s\n" \
				"$tier" "$primary_model" "$successes" "$failures" "$rate" "\$$input_price" "\$$output_price"
		else
			printf "  %-10s %-22s %8s %8s %10s %-12s %-12s\n" \
				"$tier" "$primary_model" "-" "-" "no data" "\$$input_price" "\$$output_price"
		fi
	done

	echo ""

	# Overall stats
	local total_success total_failure total_all
	total_success=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION');" 2>/dev/null || echo "0")
	total_failure=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX');" 2>/dev/null || echo "0")
	total_all=$((total_success + total_failure))

	if [[ "$total_all" -gt 0 ]]; then
		local overall_rate=$(((total_success * 100) / total_all))
		echo "  Overall: ${overall_rate}% success rate ($total_success/$total_all patterns)"
	fi

	echo ""
	echo "Data source: pattern-tracker-helper.sh (memory.db)"
	echo "Record more: pattern-tracker-helper.sh record --outcome success --model <tier> ..."
	echo ""
	return 0
}

cmd_help() {
	echo ""
	echo "Compare Models Helper - AI Model Capability Comparison"
	echo "======================================================="
	echo ""
	echo "Usage: compare-models-helper.sh [command] [options]"
	echo ""
	echo "Commands:"
	echo "  list          List all tracked models with pricing"
	echo "  compare       Compare specific models side-by-side"
	echo "  recommend     Recommend models for a task type"
	echo "  pricing       Show pricing table (sorted by cost)"
	echo "  context       Show context window comparison"
	echo "  capabilities  Show capability matrix"
	echo "  patterns      Show live success rates from pattern tracker (t1098)"
	echo "  providers     List supported providers and their models"
	echo "  discover      Detect available providers from local config"
	echo "  score         Record model comparison scores (from evaluation)"
	echo "  results       View past comparison results and rankings"
	echo "  cross-review  Dispatch same prompt to multiple models, diff results"
	echo "  bench         Live benchmark: send same prompt to N models, compare outputs (t1393)"
	echo "  help          Show this help"
	echo ""
	echo "Examples:"
	echo "  compare-models-helper.sh list"
	echo "  compare-models-helper.sh compare sonnet gpt-4o gemini-pro"
	echo "  compare-models-helper.sh recommend \"code review\""
	echo "  compare-models-helper.sh pricing"
	echo "  compare-models-helper.sh capabilities"
	echo "  compare-models-helper.sh discover"
	echo "  compare-models-helper.sh discover --probe"
	echo "  compare-models-helper.sh discover --list-models"
	echo "  compare-models-helper.sh discover --json"
	echo ""
	echo "Pattern examples:"
	echo "  compare-models-helper.sh patterns"
	echo "  compare-models-helper.sh patterns --task-type code-review"
	echo ""
	echo "Scoring examples:"
	echo "  compare-models-helper.sh score --task 'fix React bug' --type code \\"
	echo "    --model claude-sonnet-4-6 --correctness 9 --completeness 8 --quality 8 --clarity 9 --adherence 9 \\"
	echo "    --model gpt-4.1 --correctness 8 --completeness 7 --quality 7 --clarity 8 --adherence 8 \\"
	echo "    --winner claude-sonnet-4-6"
	echo "  compare-models-helper.sh score --task 'review code' --prompt-file prompts/build.txt \\"
	echo "    --model sonnet --correctness 9 --completeness 8 --quality 8 --clarity 9 --adherence 9"
	echo "  compare-models-helper.sh results"
	echo "  compare-models-helper.sh results --model sonnet --limit 5"
	echo "  compare-models-helper.sh results --prompt-version a1b2c3d"
	echo ""
	echo "Discover options:"
	echo "  --probe        Verify API keys by calling provider endpoints"
	echo "  --list-models  List live models from each verified provider"
	echo "  --json         Output discovery results as JSON"
	echo ""
	echo "Cross-review examples:"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this code for security issues: ...' \\"
	echo "    --models 'sonnet,opus,pro'"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Audit the architecture of this project' \\"
	echo "    --models 'opus,pro' --timeout 900"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this PR diff' --models 'sonnet,gemini-pro' \\"
	echo "    --score                          # auto-score via judge model (default: opus)"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this PR diff' --models 'sonnet,gemini-pro' \\"
	echo "    --score --judge sonnet            # use sonnet as judge instead"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this code' --models 'sonnet,opus' \\"
	echo "    --prompt-file prompts/build.txt   # track prompt version in results"
	echo ""
	echo "Bench examples (t1393):"
	echo "  compare-models-helper.sh bench 'What is 2+2?' claude-sonnet-4-6 gpt-4o"
	echo "  compare-models-helper.sh bench 'Explain quicksort' claude-sonnet-4-6 gpt-4.1 gemini-2.5-pro --judge"
	echo "  compare-models-helper.sh bench --dataset prompts.jsonl claude-sonnet-4-6 gpt-4o --judge"
	echo "  compare-models-helper.sh bench 'What is 2+2?' claude-sonnet-4-6 --dry-run"
	echo "  compare-models-helper.sh bench --history --limit 10"
	echo ""
	echo "Data is embedded in this script. Last updated: 2025-02-08."
	echo "For live pricing, use /compare-models (with web fetch)."
	return 0
}

# =============================================================================
# Provider API Key Detection
# =============================================================================
# Maps provider names to their environment variable names.
# NEVER prints actual key values — only checks existence.

readonly PROVIDER_ENV_KEYS="Anthropic|ANTHROPIC_API_KEY
OpenAI|OPENAI_API_KEY
Google|GOOGLE_API_KEY,GEMINI_API_KEY
OpenRouter|OPENROUTER_API_KEY
Groq|GROQ_API_KEY
DeepSeek|DEEPSEEK_API_KEY
Together|TOGETHER_API_KEY
Fireworks|FIREWORKS_API_KEY"

# Check if a provider API key is available from any source
# Returns 0 if found, 1 if not. Sets FOUND_SOURCE to the source name.
# Usage: check_provider_key "ANTHROPIC_API_KEY"
check_provider_key() {
	local key_name="$1"
	FOUND_SOURCE=""

	# 1. Check environment variable
	if [[ -n "${!key_name:-}" ]]; then
		FOUND_SOURCE="env"
		return 0
	fi

	# 2. Check gopass (encrypted secrets)
	if command -v gopass &>/dev/null && gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
		FOUND_SOURCE="gopass"
		return 0
	fi

	# 3. Check credentials.sh (plaintext fallback)
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]] &&
		(grep -q "^export ${key_name}=" "$creds_file" 2>/dev/null ||
			grep -q "^${key_name}=" "$creds_file" 2>/dev/null); then
		FOUND_SOURCE="credentials.sh"
		return 0
	fi

	return 1
}

# Probe a provider API to verify the key works
# Returns 0 if API responds successfully, 1 otherwise
# Usage: probe_provider "Anthropic" "ANTHROPIC_API_KEY"
probe_provider() {
	local provider="$1"
	local key_name="$2"

	# Get the key value from the appropriate source
	local key_value=""
	if [[ -n "${!key_name:-}" ]]; then
		key_value="${!key_name}"
	elif command -v gopass &>/dev/null && gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
		key_value=$(gopass show "aidevops/${key_name}" 2>/dev/null) || return 1
	else
		return 1
	fi

	[[ -z "$key_value" ]] && return 1

	local http_code=""
	case "$provider" in
	Anthropic)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "x-api-key: ${key_value}" \
			-H "anthropic-version: 2023-06-01" \
			"https://api.anthropic.com/v1/models" 2>/dev/null) || return 1
		;;
	OpenAI)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.openai.com/v1/models" 2>/dev/null) || return 1
		;;
	Google)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			"https://generativelanguage.googleapis.com/v1beta/models?key=${key_value}" 2>/dev/null) || return 1
		;;
	OpenRouter)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${key_value}" \
			"https://openrouter.ai/api/v1/models" 2>/dev/null) || return 1
		;;
	Groq)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.groq.com/openai/v1/models" 2>/dev/null) || return 1
		;;
	DeepSeek)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.deepseek.com/v1/models" 2>/dev/null) || return 1
		;;
	*)
		return 1
		;;
	esac

	[[ "$http_code" == "200" ]] && return 0
	return 1
}

# List models available from a provider API
# Outputs model IDs, one per line
# Usage: list_provider_models "Anthropic" "ANTHROPIC_API_KEY"
list_provider_models() {
	local provider="$1"
	local key_name="$2"

	local key_value=""
	if [[ -n "${!key_name:-}" ]]; then
		key_value="${!key_name}"
	elif command -v gopass &>/dev/null && gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
		key_value=$(gopass show "aidevops/${key_name}" 2>/dev/null) || return 1
	else
		return 1
	fi

	[[ -z "$key_value" ]] && return 1

	case "$provider" in
	Anthropic)
		curl -s -H "x-api-key: ${key_value}" \
			-H "anthropic-version: 2023-06-01" \
			"https://api.anthropic.com/v1/models" 2>/dev/null |
			jq -r '.data[].id // empty' 2>/dev/null | sort
		;;
	OpenAI)
		curl -s -H "Authorization: Bearer ${key_value}" \
			"https://api.openai.com/v1/models" 2>/dev/null |
			jq -r '.data[].id // empty' 2>/dev/null | sort
		;;
	Google)
		curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=${key_value}" 2>/dev/null |
			jq -r '.models[].name // empty' 2>/dev/null | sed 's|^models/||' | sort
		;;
	OpenRouter)
		curl -s -H "Authorization: Bearer ${key_value}" \
			"https://openrouter.ai/api/v1/models" 2>/dev/null |
			jq -r '.data[].id // empty' 2>/dev/null | sort
		;;
	Groq)
		curl -s -H "Authorization: Bearer ${key_value}" \
			"https://api.groq.com/openai/v1/models" 2>/dev/null |
			jq -r '.data[].id // empty' 2>/dev/null | sort
		;;
	*)
		return 1
		;;
	esac
	return 0
}

cmd_discover() {
	local probe_flag=false
	local list_flag=false
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--probe)
			probe_flag=true
			shift
			;;
		--list-models)
			list_flag=true
			probe_flag=true
			shift
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	echo ""
	echo "Model Provider Discovery"
	echo "========================"
	echo ""

	local total_providers=0
	local available_providers=0
	local available_models=0
	local json_entries=()

	while IFS= read -r line; do
		local provider key_names
		provider=$(echo "$line" | cut -d'|' -f1)
		key_names=$(echo "$line" | cut -d'|' -f2)

		total_providers=$((total_providers + 1))
		local found=false
		local source=""
		local active_key=""

		# Check each possible key name for this provider
		local -a keys
		IFS=',' read -ra keys <<<"$key_names"
		for key_name in "${keys[@]}"; do
			if check_provider_key "$key_name"; then
				found=true
				source="$FOUND_SOURCE"
				active_key="$key_name"
				break
			fi
		done

		if [[ "$found" == "true" ]]; then
			available_providers=$((available_providers + 1))
			local status="configured"
			local status_icon="Y"

			# Optionally probe the API
			if [[ "$probe_flag" == "true" ]]; then
				if probe_provider "$provider" "$active_key"; then
					status="verified"
					status_icon="V"
				else
					status="key-invalid"
					status_icon="!"
				fi
			fi

			# Count models from embedded database for this provider
			local model_count
			model_count=$(echo "$MODEL_DATA" | grep -c "|${provider}|" || true)
			available_models=$((available_models + model_count))

			if [[ "$json_flag" == "true" ]]; then
				json_entries+=("{\"provider\":\"${provider}\",\"status\":\"${status}\",\"source\":\"${source}\",\"models\":${model_count}}")
			else
				printf "  %s %-12s  %-12s  (source: %s, %d tracked models)\n" \
					"$status_icon" "$provider" "$status" "$source" "$model_count"
			fi

			# Optionally list live models from API
			if [[ "$list_flag" == "true" && "$status" == "verified" ]]; then
				local live_models
				live_models=$(list_provider_models "$provider" "$active_key" 2>/dev/null)
				if [[ -n "$live_models" ]]; then
					local live_count
					live_count=$(echo "$live_models" | wc -l | tr -d ' ')
					echo "    Live models ($live_count):"
					echo "$live_models" | head -20 | while IFS= read -r m; do
						echo "      - $m"
					done
					local remaining=$((live_count - 20))
					if [[ "$remaining" -gt 0 ]]; then
						echo "      ... and $remaining more"
					fi
				fi
			fi
		else
			if [[ "$json_flag" == "true" ]]; then
				json_entries+=("{\"provider\":\"${provider}\",\"status\":\"not-configured\",\"source\":null,\"models\":0}")
			else
				printf "  - %-12s  not configured\n" "$provider"
			fi
		fi
	done <<<"$PROVIDER_ENV_KEYS"

	if [[ "$json_flag" == "true" ]]; then
		echo "[$(
			IFS=,
			echo "${json_entries[*]}"
		)]"
	else
		echo ""
		echo "Summary: $available_providers/$total_providers providers configured, $available_models tracked models available"
		echo ""

		if [[ "$probe_flag" != "true" ]]; then
			echo "Tip: Use --probe to verify API keys are valid"
			echo "     Use --list-models to enumerate live models from each provider"
		fi

		# Show models grouped by availability
		echo ""
		echo "Available Models (from configured providers):"
		echo ""
		printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
			"Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier"
		printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
			"-----" "--------" "-------" "--------" "---------" "----"

		echo "$MODEL_DATA" | while IFS= read -r model_line; do
			local model_provider
			model_provider=$(get_field "$model_line" 2)

			# Check if this provider is available
			local provider_available=false
			while IFS= read -r pline; do
				local pname pkeys
				pname=$(echo "$pline" | cut -d'|' -f1)
				pkeys=$(echo "$pline" | cut -d'|' -f2)
				if [[ "$pname" == "$model_provider" ]]; then
					local -a pkey_arr
					IFS=',' read -ra pkey_arr <<<"$pkeys"
					for pk in "${pkey_arr[@]}"; do
						if check_provider_key "$pk"; then
							provider_available=true
							break
						fi
					done
					break
				fi
			done <<<"$PROVIDER_ENV_KEYS"

			if [[ "$provider_available" == "true" ]]; then
				local mid mctx minput moutput mtier
				mid=$(get_field "$model_line" 1)
				mctx=$(get_field "$model_line" 4)
				minput=$(get_field "$model_line" 5)
				moutput=$(get_field "$model_line" 6)
				mtier=$(get_field "$model_line" 7)
				local ctx_fmt
				ctx_fmt=$(format_context "$mctx")
				printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
					"$mid" "$model_provider" "$ctx_fmt" "\$$minput" "\$$moutput" "$mtier"
			fi
		done

		echo ""
		echo "Unavailable Models (provider not configured):"
		echo ""

		echo "$MODEL_DATA" | while IFS= read -r model_line; do
			local model_provider
			model_provider=$(get_field "$model_line" 2)

			local provider_available=false pname pkeys
			while IFS= read -r pline; do
				pname=$(echo "$pline" | cut -d'|' -f1)
				pkeys=$(echo "$pline" | cut -d'|' -f2)
				if [[ "$pname" == "$model_provider" ]]; then
					local -a pkey_arr
					IFS=',' read -ra pkey_arr <<<"$pkeys"
					for pk in "${pkey_arr[@]}"; do
						if check_provider_key "$pk"; then
							provider_available=true
							break
						fi
					done
					break
				fi
			done <<<"$PROVIDER_ENV_KEYS"

			if [[ "$provider_available" != "true" ]]; then
				local mid
				mid=$(get_field "$model_line" 1)
				echo "  - $mid ($model_provider)"
			fi
		done
	fi

	echo ""
	return 0
}

# =============================================================================
# Comparison Scoring Framework
# =============================================================================
# Stores and retrieves model comparison results for cross-session insights.
# Results are stored in SQLite alongside the model registry.

RESULTS_DB="${AIDEVOPS_WORKSPACE_DIR:-$HOME/.aidevops/.agent-workspace}/memory/model-comparisons.db"

init_results_db() {
	local db_dir
	db_dir="$(dirname "$RESULTS_DB")"
	mkdir -p "$db_dir"

	sqlite3 "$RESULTS_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS comparisons (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_description TEXT NOT NULL,
    task_type TEXT DEFAULT 'general',
    created_at TEXT DEFAULT (datetime('now')),
    evaluator_model TEXT,
    winner_model TEXT,
    prompt_version TEXT DEFAULT '',
    prompt_file TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS comparison_scores (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    comparison_id INTEGER NOT NULL,
    model_id TEXT NOT NULL,
    correctness INTEGER DEFAULT 0,
    completeness INTEGER DEFAULT 0,
    code_quality INTEGER DEFAULT 0,
    clarity INTEGER DEFAULT 0,
    adherence INTEGER DEFAULT 0,
    overall INTEGER DEFAULT 0,
    latency_ms INTEGER DEFAULT 0,
    tokens_used INTEGER DEFAULT 0,
    strengths TEXT DEFAULT '',
    weaknesses TEXT DEFAULT '',
    response_file TEXT DEFAULT '',
    FOREIGN KEY (comparison_id) REFERENCES comparisons(id)
);

CREATE INDEX IF NOT EXISTS idx_comparisons_task ON comparisons(task_type);
CREATE INDEX IF NOT EXISTS idx_comparisons_winner ON comparisons(winner_model);
CREATE INDEX IF NOT EXISTS idx_scores_model ON comparison_scores(model_id);
CREATE INDEX IF NOT EXISTS idx_comparisons_prompt ON comparisons(prompt_version);
SQL

	# Migrate existing DBs: add prompt_version and prompt_file columns if missing (t1396)
	sqlite3 "$RESULTS_DB" "ALTER TABLE comparisons ADD COLUMN prompt_version TEXT DEFAULT '';" 2>/dev/null || true
	sqlite3 "$RESULTS_DB" "ALTER TABLE comparisons ADD COLUMN prompt_file TEXT DEFAULT '';" 2>/dev/null || true

	return 0
}

# Record a comparison result
# Usage: cmd_score --task "description" --type "code" --evaluator "claude-opus-4-6" \
#        --model "claude-sonnet-4-6" --correctness 9 --completeness 8 --quality 7 \
#        --clarity 8 --adherence 9 --latency 1200 --tokens 500 \
#        --strengths "Fast, accurate" --weaknesses "Verbose" \
#        [--model "gpt-4.1" --correctness 8 ...]
cmd_score() {
	init_results_db || return 1

	local task="" task_type="general" evaluator="" winner=""
	local prompt_version="" prompt_file=""
	local -a model_entries=()
	local current_model="" current_correct=0 current_complete=0 current_quality=0
	local current_clarity=0 current_adherence=0 current_latency=0 current_tokens=0
	local current_strengths="" current_weaknesses="" current_response=""

	flush_model() {
		if [[ -n "$current_model" ]]; then
			local overall=$(((current_correct + current_complete + current_quality + current_clarity + current_adherence) / 5))
			model_entries+=("${current_model}|${current_correct}|${current_complete}|${current_quality}|${current_clarity}|${current_adherence}|${overall}|${current_latency}|${current_tokens}|${current_strengths}|${current_weaknesses}|${current_response}")
		fi
		current_model="" current_correct=0 current_complete=0 current_quality=0
		current_clarity=0 current_adherence=0 current_latency=0 current_tokens=0
		current_strengths="" current_weaknesses="" current_response=""
	}

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task="$2"
			shift 2
			;;
		--type)
			task_type="$2"
			shift 2
			;;
		--evaluator)
			evaluator="$2"
			shift 2
			;;
		--winner)
			winner="$2"
			shift 2
			;;
		--prompt-version)
			prompt_version="$2"
			shift 2
			;;
		--prompt-file)
			prompt_file="$2"
			shift 2
			;;
		--model)
			flush_model
			current_model="$2"
			shift 2
			;;
		--correctness)
			current_correct="$2"
			shift 2
			;;
		--completeness)
			current_complete="$2"
			shift 2
			;;
		--quality)
			current_quality="$2"
			shift 2
			;;
		--clarity)
			current_clarity="$2"
			shift 2
			;;
		--adherence)
			current_adherence="$2"
			shift 2
			;;
		--latency)
			current_latency="$2"
			shift 2
			;;
		--tokens)
			current_tokens="$2"
			shift 2
			;;
		--strengths)
			current_strengths="$2"
			shift 2
			;;
		--weaknesses)
			current_weaknesses="$2"
			shift 2
			;;
		--response)
			current_response="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	flush_model

	if [[ -z "$task" ]]; then
		echo "Usage: compare-models-helper.sh score --task 'description' --model 'model-id' --correctness N ..."
		echo ""
		echo "Score criteria (1-10 scale):"
		echo "  --correctness   Factual accuracy and correctness"
		echo "  --completeness  Coverage of all requirements"
		echo "  --quality       Code quality (if code task)"
		echo "  --clarity       Response clarity and readability"
		echo "  --adherence     Following instructions precisely"
		echo ""
		echo "Metadata:"
		echo "  --task <desc>       Task description (required)"
		echo "  --type <type>       Task type: code, text, analysis, design (default: general)"
		echo "  --evaluator <model> Model that performed the evaluation"
		echo "  --winner <model>    Overall winner model"
		echo "  --model <id>        Start scoring for a model (repeat for each model)"
		echo "  --latency <ms>      Response latency in milliseconds"
		echo "  --tokens <n>        Tokens used"
		echo "  --strengths <text>  Model strengths for this task"
		echo "  --weaknesses <text> Model weaknesses for this task"
		echo "  --response <file>   Path to response file"
		return 1
	fi

	if [[ ${#model_entries[@]} -eq 0 ]]; then
		print_error "No model scores provided. Use --model <id> --correctness N ..."
		return 1
	fi

	# Resolve prompt_version from git if prompt_file is provided and no explicit version
	if [[ -z "$prompt_version" && -n "$prompt_file" ]] && command -v git &>/dev/null; then
		prompt_version=$(git log -1 --format='%h' -- "$prompt_file" 2>/dev/null) || prompt_version=""
	fi

	# Insert comparison record (escape all string values for SQL safety)
	local comp_id safe_task safe_type safe_eval safe_winner safe_pv safe_pf
	safe_task="${task//\'/\'\'}"
	safe_type="${task_type//\'/\'\'}"
	safe_eval="${evaluator//\'/\'\'}"
	safe_winner="${winner//\'/\'\'}"
	safe_pv="${prompt_version//\'/\'\'}"
	safe_pf="${prompt_file//\'/\'\'}"
	comp_id=$(sqlite3 "$RESULTS_DB" "INSERT INTO comparisons (task_description, task_type, evaluator_model, winner_model, prompt_version, prompt_file) VALUES ('${safe_task}', '${safe_type}', '${safe_eval}', '${safe_winner}', '${safe_pv}', '${safe_pf}'); SELECT last_insert_rowid();")

	# Insert scores for each model (escape strings, validate numerics)
	for entry in "${model_entries[@]}"; do
		IFS='|' read -r m_id m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok m_str m_wea m_res <<<"$entry"

		# Validate all numeric fields — reject non-integer values to prevent SQL injection
		for n in m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok; do
			if ! [[ "${!n}" =~ ^[0-9]+$ ]]; then
				print_error "Invalid numeric value for ${n}: ${!n}"
				return 1
			fi
		done
		# Clamp score fields to valid 0-10 range
		for s in m_cor m_com m_qua m_cla m_adh m_ove; do
			if ((${!s} > 10)); then
				printf -v "$s" "10"
			fi
		done

		local safe_id="${m_id//\'/\'\'}"
		local safe_str="${m_str//\'/\'\'}"
		local safe_wea="${m_wea//\'/\'\'}"
		local safe_res="${m_res//\'/\'\'}"
		sqlite3 "$RESULTS_DB" "INSERT INTO comparison_scores (comparison_id, model_id, correctness, completeness, code_quality, clarity, adherence, overall, latency_ms, tokens_used, strengths, weaknesses, response_file) VALUES ($comp_id, '${safe_id}', $m_cor, $m_com, $m_qua, $m_cla, $m_adh, $m_ove, $m_lat, $m_tok, '${safe_str}', '${safe_wea}', '${safe_res}');"
	done

	print_success "Comparison #$comp_id recorded ($task_type: ${#model_entries[@]} models scored)"

	# Display summary table
	echo ""
	printf "%-22s %5s %5s %5s %5s %5s %7s %8s %6s\n" \
		"Model" "Corr" "Comp" "Qual" "Clar" "Adhr" "Overall" "Latency" "Tokens"
	printf "%-22s %5s %5s %5s %5s %5s %7s %8s %6s\n" \
		"-----" "----" "----" "----" "----" "----" "-------" "-------" "------"

	for entry in "${model_entries[@]}"; do
		IFS='|' read -r m_id m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok _ _ _ <<<"$entry"
		local lat_fmt="${m_lat}ms"
		[[ "$m_lat" -eq 0 ]] && lat_fmt="-"
		[[ "$m_tok" -eq 0 ]] && m_tok="-"
		printf "%-22s %5d %5d %5d %5d %5d %7d %8s %6s\n" \
			"$m_id" "$m_cor" "$m_com" "$m_qua" "$m_cla" "$m_adh" "$m_ove" "$lat_fmt" "$m_tok"
	done

	if [[ -n "$winner" ]]; then
		echo ""
		echo "  Winner: $winner"
	fi
	echo ""

	# Sync to unified pattern tracker backbone (t1094)
	# Scores are 1-10 here; normalize to 1-5 for pattern tracker compatibility.
	local pt_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	if [[ -x "$pt_helper" ]]; then
		local winner_tier=""
		local loser_args=()
		local winner_overall=0

		for entry in "${model_entries[@]}"; do
			IFS='|' read -r m_id m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok _ _ _ <<<"$entry"
			local m_tier
			m_tier=$(model_id_to_tier "$m_id")
			[[ -z "$m_tier" ]] && m_tier="$m_id"

			# Normalize 1-10 scores to 1-5 (halve, round)
			local norm_cor norm_com norm_qua norm_cla norm_tok_arg=()
			norm_cor=$(awk "BEGIN{v=int($m_cor/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
			norm_com=$(awk "BEGIN{v=int($m_com/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
			norm_qua=$(awk "BEGIN{v=int($m_qua/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
			norm_cla=$(awk "BEGIN{v=int($m_cla/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
			if [[ "$m_tok" =~ ^[0-9]+$ ]] && [[ "$m_tok" -gt 0 ]]; then
				norm_tok_arg=(--tokens-out "$m_tok")
			fi

			"$pt_helper" score \
				--model "$m_tier" \
				--task-type "$task_type" \
				--correctness "$norm_cor" \
				--completeness "$norm_com" \
				--code-quality "$norm_qua" \
				--clarity "$norm_cla" \
				"${norm_tok_arg[@]}" \
				--source "compare-models" \
				>/dev/null 2>&1 || true

			# Track winner for ab-compare
			if [[ -n "$winner" && "$m_id" == "$winner" ]]; then
				winner_tier="$m_tier"
				winner_overall="$m_ove"
			elif [[ -n "$winner" && "$m_id" != "$winner" ]]; then
				loser_args+=(--loser "$m_tier")
			fi
		done

		# Record A/B comparison if a winner was declared
		if [[ -n "$winner_tier" && "${#loser_args[@]}" -gt 0 ]]; then
			local winner_avg_norm
			winner_avg_norm=$(awk "BEGIN{printf \"%.1f\", $winner_overall / 2}")
			"$pt_helper" ab-compare \
				--winner "$winner_tier" \
				"${loser_args[@]}" \
				--task-type "$task_type" \
				--winner-score "$winner_avg_norm" \
				--models-compared "${#model_entries[@]}" \
				--source "compare-models" \
				>/dev/null 2>&1 || true
		fi
	fi

	return 0
}

# View past comparison results
cmd_results() {
	init_results_db || return 1

	local limit=10
	local model_filter="" type_filter="" pv_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit)
			limit="$2"
			shift 2
			;;
		--model)
			model_filter="$2"
			shift 2
			;;
		--type)
			type_filter="$2"
			shift 2
			;;
		--prompt-version)
			pv_filter="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate limit is numeric (used in SQL LIMIT clause)
	if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --limit value: $limit (must be a positive integer)"
		return 1
	fi

	# Escape string values for SQL safety (prevent injection via --model/--type/--prompt-version args)
	local safe_model_filter="${model_filter//\'/\'\'}"
	local safe_type_filter="${type_filter//\'/\'\'}"
	local safe_pv_filter="${pv_filter//\'/\'\'}"

	local where_clause=""
	if [[ -n "$safe_model_filter" ]]; then
		where_clause="WHERE cs.model_id LIKE '%${safe_model_filter}%'"
	fi
	if [[ -n "$safe_type_filter" ]]; then
		if [[ -n "$where_clause" ]]; then
			where_clause="$where_clause AND c.task_type = '${safe_type_filter}'"
		else
			where_clause="WHERE c.task_type = '${safe_type_filter}'"
		fi
	fi
	if [[ -n "$safe_pv_filter" ]]; then
		if [[ -n "$where_clause" ]]; then
			where_clause="$where_clause AND c.prompt_version = '${safe_pv_filter}'"
		else
			where_clause="WHERE c.prompt_version = '${safe_pv_filter}'"
		fi
	fi

	echo ""
	echo "Model Comparison Results (last $limit)"
	echo "======================================="
	echo ""

	local count
	count=$(sqlite3 "$RESULTS_DB" "SELECT COUNT(DISTINCT c.id) FROM comparisons c LEFT JOIN comparison_scores cs ON c.id = cs.comparison_id $where_clause;" 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		echo "No comparison results found."
		echo "Run a comparison first: compare-models-helper.sh score --task '...' --model '...' ..."
		echo ""
		return 0
	fi

	# Show recent comparisons
	sqlite3 -separator '|' "$RESULTS_DB" "
        SELECT c.id, c.created_at, c.task_type, c.task_description, c.winner_model,
               COALESCE(c.prompt_version, ''), COALESCE(c.prompt_file, '')
        FROM comparisons c
        ORDER BY c.created_at DESC
        LIMIT $limit;
    " 2>/dev/null | while IFS='|' read -r cid cdate ctype cdesc cwinner cpv cpf; do
		echo "  #$cid [$ctype] $(echo "$cdesc" | head -c 60) ($cdate)"
		if [[ -n "$cwinner" ]]; then
			echo "    Winner: $cwinner"
		fi
		if [[ -n "$cpv" ]]; then
			local pv_display="$cpv"
			[[ -n "$cpf" ]] && pv_display="${cpv} (${cpf})"
			echo "    Prompt version: $pv_display"
		fi

		# Show scores for this comparison
		sqlite3 -separator '|' "$RESULTS_DB" "
            SELECT model_id, overall, correctness, completeness, code_quality, clarity, adherence
            FROM comparison_scores
            WHERE comparison_id = $cid
            ORDER BY overall DESC;
        " 2>/dev/null | while IFS='|' read -r mid ov co cm cq cl ca; do
			printf "    %-20s overall:%d (corr:%d comp:%d qual:%d clar:%d adhr:%d)\n" \
				"$mid" "$ov" "$co" "$cm" "$cq" "$cl" "$ca"
		done
		echo ""
	done

	# Show aggregate model rankings
	echo "Aggregate Model Rankings"
	echo "------------------------"
	sqlite3 -separator '|' "$RESULTS_DB" "
        SELECT model_id,
               COUNT(*) as comparisons,
               ROUND(AVG(overall), 1) as avg_overall,
               SUM(CASE WHEN c.winner_model = cs.model_id THEN 1 ELSE 0 END) as wins
        FROM comparison_scores cs
        JOIN comparisons c ON c.id = cs.comparison_id
        $where_clause
        GROUP BY model_id
        ORDER BY avg_overall DESC;
    " 2>/dev/null | while IFS='|' read -r mid cnt avg wins; do
		printf "  %-22s  avg:%s  wins:%s/%s\n" "$mid" "$avg" "$wins" "$cnt"
	done
	echo ""

	return 0
}

# =============================================================================
# Live Model Benchmarking (t1393)
# =============================================================================
# Sends the same prompt (or JSONL dataset) to N models and compares actual
# outputs with latency, tokens, cost, and optional LLM-as-judge quality score.
#
# Storage: ~/.aidevops/.agent-workspace/observability/bench-results.jsonl

readonly BENCH_RESULTS_DIR="${HOME}/.aidevops/.agent-workspace/observability"
readonly BENCH_RESULTS_FILE="${BENCH_RESULTS_DIR}/bench-results.jsonl"

# Resolve a provider API key value for use in curl calls.
# Uses the same resolution chain as check_provider_key but returns the value.
# Arguments: $1 — env var name (e.g. ANTHROPIC_API_KEY)
# Output: key value on stdout
# Returns: 0 if found, 1 if not
_resolve_key_value() {
	local key_name="$1"

	# 1. Environment variable
	if [[ -n "${!key_name:-}" ]]; then
		echo "${!key_name}"
		return 0
	fi

	# 2. gopass
	if command -v gopass &>/dev/null; then
		local val
		val=$(gopass show -o "aidevops/${key_name}" 2>/dev/null) || true
		if [[ -n "$val" ]]; then
			echo "$val"
			return 0
		fi
	fi

	# 3. credentials.sh
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		local val
		val=$(grep -E "^(export )?${key_name}=" "$creds_file" 2>/dev/null | head -1 | sed "s/^export //" | cut -d= -f2- | tr -d '"'"'" || true)
		if [[ -n "$val" ]]; then
			echo "$val"
			return 0
		fi
	fi

	return 1
}

# Determine which provider a model_id belongs to and its API key env var.
# Output: "provider|key_env_var" or empty if unknown
_model_provider_info() {
	local model_id="$1"
	local match
	match=$(echo "$MODEL_DATA" | grep "^${model_id}|" || true)
	if [[ -z "$match" ]]; then
		# Try partial match
		match=$(find_model "$model_id" | head -1)
	fi
	if [[ -z "$match" ]]; then
		echo ""
		return 0
	fi

	local provider
	provider=$(get_field "$match" 2)
	local actual_model_id
	actual_model_id=$(get_field "$match" 1)

	local key_var=""
	case "$provider" in
	Anthropic) key_var="ANTHROPIC_API_KEY" ;;
	OpenAI) key_var="OPENAI_API_KEY" ;;
	Google) key_var="GOOGLE_API_KEY" ;;
	DeepSeek) key_var="DEEPSEEK_API_KEY" ;;
	*) key_var="" ;;
	esac

	echo "${provider}|${key_var}|${actual_model_id}"
	return 0
}

# Map model_id to the API model string each provider expects
_api_model_string() {
	local model_id="$1"
	case "$model_id" in
	claude-opus-4-6) echo "claude-opus-4-20250514" ;;
	claude-sonnet-4-6) echo "claude-sonnet-4-20250514" ;;
	claude-haiku-4-5) echo "claude-haiku-4-20250414" ;;
	gpt-4.1) echo "gpt-4.1" ;;
	gpt-4.1-mini) echo "gpt-4.1-mini" ;;
	gpt-4.1-nano) echo "gpt-4.1-nano" ;;
	gpt-4o) echo "gpt-4o" ;;
	gpt-4o-mini) echo "gpt-4o-mini" ;;
	o3) echo "o3" ;;
	o4-mini) echo "o4-mini" ;;
	gemini-2.5-pro) echo "gemini-2.5-pro" ;;
	gemini-2.5-flash) echo "gemini-2.5-flash" ;;
	gemini-2.0-flash) echo "gemini-2.0-flash" ;;
	deepseek-r1) echo "deepseek-reasoner" ;;
	deepseek-v3) echo "deepseek-chat" ;;
	*) echo "$model_id" ;;
	esac
	return 0
}

# Call a single model API and capture response + metrics.
# Arguments:
#   $1 — model_id (from MODEL_DATA)
#   $2 — prompt text
#   $3 — max_tokens
#   $4 — output directory for result files
# Output: writes result JSON to $4/$model_id.json
# Returns: 0 on success, 1 on failure
_bench_call_model() {
	local model_id="$1"
	local prompt="$2"
	local max_tokens="$3"
	local out_dir="$4"

	local info
	info=$(_model_provider_info "$model_id")
	if [[ -z "$info" ]]; then
		echo "{\"error\":\"unknown model: ${model_id}\"}" >"${out_dir}/${model_id}.json"
		return 1
	fi

	local provider key_var actual_id
	IFS='|' read -r provider key_var actual_id <<<"$info"

	if [[ -z "$key_var" ]]; then
		echo "{\"error\":\"no API key mapping for provider: ${provider}\"}" >"${out_dir}/${actual_id}.json"
		return 1
	fi

	local api_key
	api_key=$(_resolve_key_value "$key_var") || {
		echo "{\"error\":\"API key not found: ${key_var}\"}" >"${out_dir}/${actual_id}.json"
		return 1
	}

	local api_model
	api_model=$(_api_model_string "$actual_id")

	# Escape prompt for JSON
	local escaped_prompt
	if command -v python3 &>/dev/null; then
		escaped_prompt=$(printf '%s' "$prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
	else
		escaped_prompt="\"$(printf '%s' "$prompt" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\t/\\t/g')\""
	fi

	local start_ms response http_code end_ms latency_ms
	start_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)

	local result_file="${out_dir}/${actual_id}.json"
	local raw_file="${out_dir}/${actual_id}-raw.json"

	case "$provider" in
	Anthropic)
		http_code=$(curl -sS -o "$raw_file" -w "%{http_code}" --max-time 120 \
			-H "x-api-key: ${api_key}" \
			-H "anthropic-version: 2023-06-01" \
			-H "${CONTENT_TYPE_JSON}" \
			-d "{
				\"model\": \"${api_model}\",
				\"max_tokens\": ${max_tokens},
				\"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}]
			}" \
			"https://api.anthropic.com/v1/messages" 2>/dev/null) || http_code="000"
		;;
	OpenAI)
		http_code=$(curl -sS -o "$raw_file" -w "%{http_code}" --max-time 120 \
			-H "Authorization: Bearer ${api_key}" \
			-H "${CONTENT_TYPE_JSON}" \
			-d "{
				\"model\": \"${api_model}\",
				\"max_tokens\": ${max_tokens},
				\"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}]
			}" \
			"https://api.openai.com/v1/chat/completions" 2>/dev/null) || http_code="000"
		;;
	Google)
		# Google uses a different API format
		http_code=$(curl -sS -o "$raw_file" -w "%{http_code}" --max-time 120 \
			-H "${CONTENT_TYPE_JSON}" \
			-d "{
				\"contents\": [{\"parts\": [{\"text\": ${escaped_prompt}}]}],
				\"generationConfig\": {\"maxOutputTokens\": ${max_tokens}}
			}" \
			"https://generativelanguage.googleapis.com/v1beta/models/${api_model}:generateContent?key=${api_key}" \
			2>/dev/null) || http_code="000"
		;;
	DeepSeek)
		http_code=$(curl -sS -o "$raw_file" -w "%{http_code}" --max-time 120 \
			-H "Authorization: Bearer ${api_key}" \
			-H "${CONTENT_TYPE_JSON}" \
			-d "{
				\"model\": \"${api_model}\",
				\"max_tokens\": ${max_tokens},
				\"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}]
			}" \
			"https://api.deepseek.com/v1/chat/completions" 2>/dev/null) || http_code="000"
		;;
	*)
		echo "{\"error\":\"unsupported provider: ${provider}\"}" >"$result_file"
		return 1
		;;
	esac

	end_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)
	latency_ms=$((end_ms - start_ms))

	# Parse response into normalized format using python3
	if [[ ! -f "$raw_file" ]] || [[ ! -s "$raw_file" ]]; then
		echo "{\"error\":\"empty response\",\"http_code\":\"${http_code}\",\"latency_ms\":${latency_ms}}" >"$result_file"
		return 1
	fi

	python3 -c "
import json, sys

provider = '${provider}'
model_id = '${actual_id}'
latency_ms = ${latency_ms}
http_code = '${http_code}'

try:
    with open('${raw_file}', 'r') as f:
        raw = json.load(f)
except Exception as e:
    json.dump({'error': str(e), 'http_code': http_code, 'latency_ms': latency_ms, 'model': model_id}, sys.stdout)
    sys.exit(0)

result = {
    'model': model_id,
    'provider': provider,
    'latency_ms': latency_ms,
    'http_code': http_code,
    'tokens_in': 0,
    'tokens_out': 0,
    'output': '',
    'error': ''
}

if provider == 'Anthropic':
    result['output'] = ''.join(b.get('text', '') for b in raw.get('content', []))
    usage = raw.get('usage', {})
    result['tokens_in'] = usage.get('input_tokens', 0)
    result['tokens_out'] = usage.get('output_tokens', 0)
    if raw.get('error'):
        result['error'] = raw['error'].get('message', str(raw['error']))
elif provider in ('OpenAI', 'DeepSeek'):
    choices = raw.get('choices', [])
    if choices:
        result['output'] = choices[0].get('message', {}).get('content', '')
    usage = raw.get('usage', {})
    result['tokens_in'] = usage.get('prompt_tokens', 0)
    result['tokens_out'] = usage.get('completion_tokens', 0)
    if raw.get('error'):
        result['error'] = raw['error'].get('message', str(raw['error']))
elif provider == 'Google':
    candidates = raw.get('candidates', [])
    if candidates:
        parts = candidates[0].get('content', {}).get('parts', [])
        result['output'] = ''.join(p.get('text', '') for p in parts)
    usage = raw.get('usageMetadata', {})
    result['tokens_in'] = usage.get('promptTokenCount', 0)
    result['tokens_out'] = usage.get('candidatesTokenCount', 0)
    if raw.get('error'):
        result['error'] = raw['error'].get('message', str(raw['error']))

json.dump(result, sys.stdout)
" >"$result_file" 2>/dev/null || {
		echo "{\"error\":\"parse failure\",\"latency_ms\":${latency_ms},\"model\":\"${actual_id}\"}" >"$result_file"
		return 1
	}

	# Clean up raw file
	rm -f "$raw_file"
	return 0
}

# Calculate cost from token counts and model pricing
# Arguments: $1=model_id $2=tokens_in $3=tokens_out
# Output: cost as decimal string
_calc_bench_cost() {
	local model_id="$1"
	local tokens_in="$2"
	local tokens_out="$3"

	local match
	match=$(echo "$MODEL_DATA" | grep "^${model_id}|" | head -1 || true)
	if [[ -z "$match" ]]; then
		echo "0.0000"
		return 0
	fi

	local input_price output_price
	input_price=$(get_field "$match" 5)
	output_price=$(get_field "$match" 6)

	# Cost = (tokens / 1M) * price_per_1M
	awk "BEGIN{printf \"%.6f\", (${tokens_in}/1000000.0)*${input_price} + (${tokens_out}/1000000.0)*${output_price}}"
	return 0
}

# Store bench result as JSONL
_store_bench_result() {
	local model_id="$1"
	local prompt_text="$2"
	local latency_ms="$3"
	local tokens_in="$4"
	local tokens_out="$5"
	local cost="$6"
	local judge_score="${7:-}"
	local prompt_version="${8:-}"

	mkdir -p "$BENCH_RESULTS_DIR"

	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	local prompt_hash
	prompt_hash=$(printf '%s' "$prompt_text" | sha256sum | cut -c1-12)

	local output_hash
	output_hash=$(printf '%s' "${model_id}:${ts}" | sha256sum | cut -c1-12)

	local judge_field=""
	if [[ -n "$judge_score" ]]; then
		judge_field=",\"judge_score\":${judge_score}"
	fi

	local version_field=""
	if [[ -n "$prompt_version" ]]; then
		version_field=",\"prompt_version\":\"${prompt_version}\""
	fi

	printf '{"ts":"%s","prompt_hash":"%s","model":"%s","latency_ms":%d,"tokens_in":%d,"tokens_out":%d,"cost":%s%s%s,"output_hash":"%s"}\n' \
		"$ts" "$prompt_hash" "$model_id" "$latency_ms" "$tokens_in" "$tokens_out" "$cost" \
		"$judge_field" "$version_field" "$output_hash" >>"$BENCH_RESULTS_FILE"
	return 0
}

# LLM-as-judge scoring for bench results
# Arguments: $1=prompt $2=output_dir (contains model result files)
# Output: model_id|score lines on stdout
_bench_judge_score() {
	local original_prompt="$1"
	local out_dir="$2"

	local ai_helper="${SCRIPT_DIR}/ai-research-helper.sh"
	if [[ ! -x "$ai_helper" ]]; then
		print_warning "ai-research-helper.sh not found — skipping judge scoring"
		return 0
	fi

	# Build judge prompt with all model outputs
	local judge_prompt="You are evaluating AI model responses to the same prompt. Rate each response on a 0.0-1.0 scale for overall quality (accuracy, completeness, clarity, relevance).

ORIGINAL PROMPT:
${original_prompt}

MODEL RESPONSES:
"
	local -a models_with_output=()
	for result_file in "${out_dir}"/*.json; do
		[[ -f "$result_file" ]] || continue
		local basename_file
		basename_file=$(basename "$result_file" .json)
		# Skip non-model files
		[[ "$basename_file" == *"-raw"* ]] && continue
		[[ "$basename_file" == "judge"* ]] && continue

		local output error
		output=$(jq -r '.output // ""' "$result_file" 2>/dev/null || echo "")
		error=$(jq -r '.error // ""' "$result_file" 2>/dev/null || echo "")

		if [[ -n "$output" && -z "$error" ]]; then
			# Truncate to 2000 chars per model for judge prompt
			local truncated="${output:0:2000}"
			judge_prompt+="
=== MODEL: ${basename_file} ===
${truncated}
"
			models_with_output+=("$basename_file")
		fi
	done

	if [[ ${#models_with_output[@]} -lt 1 ]]; then
		return 0
	fi

	judge_prompt+="
Respond with ONLY a valid JSON object mapping model names to scores:
{\"model_name\": 0.85, \"other_model\": 0.72}
No explanation, no markdown, just the JSON object."

	local judge_result
	judge_result=$("$ai_helper" --prompt "$judge_prompt" --model haiku --max-tokens 200 2>/dev/null || echo "")

	if [[ -z "$judge_result" ]]; then
		print_warning "Judge returned no output"
		return 0
	fi

	# Parse judge JSON and output model|score lines
	echo "$judge_result" | python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{[^}]+\}', text)
if m:
    try:
        scores = json.loads(m.group())
        for model, score in scores.items():
            s = float(score)
            if s < 0: s = 0.0
            if s > 1: s = 1.0
            print(f'{model}|{s:.2f}')
    except Exception:
        pass
" 2>/dev/null || true
	return 0
}

#######################################
# Live model benchmarking (t1393)
# Usage: compare-models-helper.sh bench "prompt text" model1 model2 [model3...]
#        compare-models-helper.sh bench --dataset path/to/dataset.jsonl model1 model2
#        compare-models-helper.sh bench --history [--limit N]
#
# Options:
#   --judge           Enable LLM-as-judge scoring (haiku-tier, ~$0.001/call)
#   --dataset FILE    Read prompts from JSONL file (each line: {"input":"..."} or {"prompt":"..."})
#   --max-tokens N    Max output tokens per model (default: 1024)
#   --dry-run         Show what would happen without making API calls
#   --history         Show historical bench results
#   --limit N         Limit history output (default: 20)
#   --version TAG     Tag results with a prompt version (e.g. git short hash)
#######################################
cmd_bench() {
	local prompt="" dataset_file="" max_tokens=1024 dry_run=false
	local judge_flag=false history_flag=false history_limit=20
	local prompt_version=""
	local -a model_args=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dataset)
			[[ $# -lt 2 ]] && {
				print_error "--dataset requires a file path"
				return 1
			}
			dataset_file="$2"
			shift 2
			;;
		--judge)
			judge_flag=true
			shift
			;;
		--max-tokens)
			[[ $# -lt 2 ]] && {
				print_error "--max-tokens requires a value"
				return 1
			}
			max_tokens="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--history)
			history_flag=true
			shift
			;;
		--limit)
			[[ $# -lt 2 ]] && {
				print_error "--limit requires a value"
				return 1
			}
			history_limit="$2"
			shift 2
			;;
		--version)
			[[ $# -lt 2 ]] && {
				print_error "--version requires a value"
				return 1
			}
			prompt_version="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			# First non-option arg without --dataset is the prompt, rest are models
			if [[ -z "$prompt" && -z "$dataset_file" ]]; then
				prompt="$1"
			else
				model_args+=("$1")
			fi
			shift
			;;
		esac
	done

	# Handle --history subcommand
	if [[ "$history_flag" == true ]]; then
		_bench_show_history "$history_limit"
		return $?
	fi

	# Validate inputs
	if [[ -z "$prompt" && -z "$dataset_file" ]]; then
		print_error "Usage: compare-models-helper.sh bench \"prompt\" model1 model2 [model3...]"
		echo "       compare-models-helper.sh bench --dataset file.jsonl model1 model2"
		echo "       compare-models-helper.sh bench --history [--limit N]"
		echo ""
		echo "Options:"
		echo "  --judge           Enable LLM-as-judge quality scoring"
		echo "  --dataset FILE    Read prompts from JSONL (each line: {\"input\":\"...\"} or {\"prompt\":\"...\"})"
		echo "  --max-tokens N    Max output tokens per model (default: 1024)"
		echo "  --dry-run         Show plan without making API calls"
		echo "  --history         Show historical bench results"
		echo "  --version TAG     Tag results with prompt version"
		return 1
	fi

	if [[ ${#model_args[@]} -lt 1 ]]; then
		print_error "At least 1 model required for benchmarking"
		return 1
	fi

	# Validate dataset file exists
	if [[ -n "$dataset_file" && ! -f "$dataset_file" ]]; then
		print_error "Dataset file not found: $dataset_file"
		return 1
	fi

	# Validate max_tokens is numeric
	if ! [[ "$max_tokens" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --max-tokens value: $max_tokens"
		return 1
	fi

	# Build prompts list
	local -a prompts=()
	if [[ -n "$dataset_file" ]]; then
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local p
			# Support both dataset convention (.input) and legacy (.prompt)
			p=$(echo "$line" | jq -r '(.input // .prompt) // empty' 2>/dev/null || echo "")
			if [[ -n "$p" ]]; then
				prompts+=("$p")
			fi
		done <"$dataset_file"
		if [[ ${#prompts[@]} -eq 0 ]]; then
			print_error "No valid prompts found in dataset (expected JSONL with {\"input\":\"...\"} or {\"prompt\":\"...\"})"
			return 1
		fi
	else
		prompts+=("$prompt")
	fi

	# Validate models exist in MODEL_DATA
	local -a valid_models=()
	for m in "${model_args[@]}"; do
		local info
		info=$(_model_provider_info "$m")
		if [[ -z "$info" ]]; then
			print_warning "Unknown model: $m (skipping)"
		else
			local actual_id
			actual_id=$(echo "$info" | cut -d'|' -f3)
			valid_models+=("$actual_id")
		fi
	done

	if [[ ${#valid_models[@]} -lt 1 ]]; then
		print_error "No valid models found"
		return 1
	fi

	# Dry-run mode
	if [[ "$dry_run" == true ]]; then
		echo ""
		echo "Bench Plan (dry-run)"
		echo "===================="
		echo ""
		echo "Prompts: ${#prompts[@]}"
		echo "Models:  ${valid_models[*]}"
		echo "Max tokens: $max_tokens"
		echo "Judge: $judge_flag"
		echo "Total API calls: $((${#prompts[@]} * ${#valid_models[@]}))"
		echo ""

		# Estimate cost
		echo "| Model                  | Est. Cost/prompt | Provider |"
		echo "|------------------------|------------------|----------|"
		for m in "${valid_models[@]}"; do
			local match
			match=$(echo "$MODEL_DATA" | grep "^${m}|" | head -1 || true)
			if [[ -n "$match" ]]; then
				local prov input_p output_p
				prov=$(get_field "$match" 2)
				input_p=$(get_field "$match" 5)
				output_p=$(get_field "$match" 6)
				# Estimate: ~200 input tokens, ~max_tokens output tokens
				local est_cost
				est_cost=$(awk "BEGIN{printf \"%.4f\", (200/1000000.0)*${input_p} + (${max_tokens}/1000000.0)*${output_p}}")
				printf "| %-22s | \$%-15s | %-8s |\n" "$m" "$est_cost" "$prov"
			fi
		done
		echo ""

		if [[ "$judge_flag" == true ]]; then
			echo "Judge cost: ~\$0.001 per prompt (haiku-tier)"
		fi
		echo ""
		echo "Run without --dry-run to execute."
		return 0
	fi

	# Execute benchmarks
	echo ""
	echo "Live Model Benchmark"
	echo "===================="
	echo ""
	echo "Models: ${valid_models[*]}"
	echo "Prompts: ${#prompts[@]}"
	echo "Max tokens: $max_tokens"
	[[ "$judge_flag" == true ]] && echo "Judge: enabled (haiku)"
	echo ""

	local prompt_idx=0
	for p in "${prompts[@]}"; do
		prompt_idx=$((prompt_idx + 1))
		local prompt_label="Prompt"
		if [[ ${#prompts[@]} -gt 1 ]]; then
			prompt_label="Prompt ${prompt_idx}/${#prompts[@]}"
		fi

		# Truncate prompt for display
		local display_prompt="${p:0:80}"
		[[ ${#p} -gt 80 ]] && display_prompt="${display_prompt}..."
		echo "${prompt_label}: ${display_prompt}"
		echo ""

		# Create temp directory for this prompt's results
		local bench_dir
		bench_dir=$(mktemp -d "${TMPDIR:-/tmp}/bench-XXXXXX")

		# Run models in parallel
		local -a pids=()
		for m in "${valid_models[@]}"; do
			echo "  Calling ${m}..."
			_bench_call_model "$m" "$p" "$max_tokens" "$bench_dir" &
			pids+=($!)
		done

		# Wait for all
		for pid in "${pids[@]}"; do
			wait "$pid" 2>/dev/null || true
		done

		# Collect judge scores if enabled
		local judge_models=()
		local judge_scores_vals=()
		if [[ "$judge_flag" == true ]]; then
			echo "  Scoring with judge (haiku)..."
			local judge_output
			judge_output=$(_bench_judge_score "$p" "$bench_dir")
			while IFS='|' read -r jm js; do
				[[ -z "$jm" ]] && continue
				judge_models+=("$jm")
				judge_scores_vals+=("$js")
			done <<<"$judge_output"
		fi

		# Build and display results table
		echo ""
		if [[ "$judge_flag" == true ]]; then
			printf "| %-22s | %7s | %15s | %9s | %11s |\n" \
				"Model" "Latency" "Tokens (in/out)" "Cost" "Judge Score"
			printf "| %-22s | %7s | %15s | %9s | %11s |\n" \
				"----------------------" "-------" "---------------" "---------" "-----------"
		else
			printf "| %-22s | %7s | %15s | %9s |\n" \
				"Model" "Latency" "Tokens (in/out)" "Cost"
			printf "| %-22s | %7s | %15s | %9s |\n" \
				"----------------------" "-------" "---------------" "---------"
		fi

		for m in "${valid_models[@]}"; do
			local result_file="${bench_dir}/${m}.json"
			if [[ ! -f "$result_file" ]]; then
				if [[ "$judge_flag" == true ]]; then
					printf "| %-22s | %7s | %15s | %9s | %11s |\n" "$m" "ERROR" "-" "-" "-"
				else
					printf "| %-22s | %7s | %15s | %9s |\n" "$m" "ERROR" "-" "-"
				fi
				continue
			fi

			local latency tokens_in tokens_out error_msg
			latency=$(jq -r '.latency_ms // 0' "$result_file" 2>/dev/null || echo "0")
			tokens_in=$(jq -r '.tokens_in // 0' "$result_file" 2>/dev/null || echo "0")
			tokens_out=$(jq -r '.tokens_out // 0' "$result_file" 2>/dev/null || echo "0")
			error_msg=$(jq -r '.error // ""' "$result_file" 2>/dev/null || echo "")

			if [[ -n "$error_msg" ]]; then
				if [[ "$judge_flag" == true ]]; then
					printf "| %-22s | %7s | %15s | %9s | %11s |\n" "$m" "FAIL" "$error_msg" "-" "-"
				else
					printf "| %-22s | %7s | %15s | %9s |\n" "$m" "FAIL" "$error_msg" "-"
				fi
				continue
			fi

			local latency_fmt
			if [[ "$latency" -ge 1000 ]]; then
				latency_fmt=$(awk "BEGIN{printf \"%.1fs\", ${latency}/1000.0}")
			else
				latency_fmt="${latency}ms"
			fi

			local tokens_fmt="${tokens_in}/${tokens_out}"
			local cost
			cost=$(_calc_bench_cost "$m" "$tokens_in" "$tokens_out")
			local cost_fmt
			cost_fmt=$(printf "\$%.4f" "$cost")

			# Look up judge score from parallel arrays
			local judge_score=""
			for i in "${!judge_models[@]}"; do
				if [[ "${judge_models[$i]}" == "$m" ]]; then
					judge_score="${judge_scores_vals[$i]}"
					break
				fi
			done

			# Store result
			_store_bench_result "$m" "$p" "$latency" "$tokens_in" "$tokens_out" "$cost" \
				"$judge_score" "$prompt_version"

			if [[ "$judge_flag" == true ]]; then
				local judge_fmt="${judge_score:-  -  }"
				printf "| %-22s | %7s | %15s | %9s | %11s |\n" \
					"$m" "$latency_fmt" "$tokens_fmt" "$cost_fmt" "$judge_fmt"
			else
				printf "| %-22s | %7s | %15s | %9s |\n" \
					"$m" "$latency_fmt" "$tokens_fmt" "$cost_fmt"
			fi
		done

		echo ""

		# Clean up temp dir
		rm -rf "$bench_dir"
	done

	echo "Results stored: $BENCH_RESULTS_FILE"
	echo ""
	return 0
}

# Show historical bench results
_bench_show_history() {
	local limit="${1:-20}"

	if [[ ! -f "$BENCH_RESULTS_FILE" ]]; then
		echo "No bench history found."
		echo "Run a benchmark first: compare-models-helper.sh bench \"prompt\" model1 model2"
		return 0
	fi

	# Validate limit is numeric
	if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --limit value: $limit"
		return 1
	fi

	echo ""
	echo "Bench History (last $limit results)"
	echo "===================================="
	echo ""

	printf "| %-20s | %-22s | %7s | %7s | %9s | %5s |\n" \
		"Timestamp" "Model" "Latency" "Tok Out" "Cost" "Judge"
	printf "| %-20s | %-22s | %7s | %7s | %9s | %5s |\n" \
		"--------------------" "----------------------" "-------" "-------" "---------" "-----"

	tail -n "$limit" "$BENCH_RESULTS_FILE" | while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local ts model lat tok_out cost judge
		ts=$(echo "$line" | jq -r '.ts // "-"' 2>/dev/null || echo "-")
		model=$(echo "$line" | jq -r '.model // "-"' 2>/dev/null || echo "-")
		lat=$(echo "$line" | jq -r '.latency_ms // 0' 2>/dev/null || echo "0")
		tok_out=$(echo "$line" | jq -r '.tokens_out // 0' 2>/dev/null || echo "0")
		cost=$(echo "$line" | jq -r '.cost // 0' 2>/dev/null || echo "0")
		judge=$(echo "$line" | jq -r '.judge_score // "-"' 2>/dev/null || echo "-")

		# Format timestamp (trim seconds)
		local ts_short="${ts:0:16}"

		local lat_fmt
		if [[ "$lat" -ge 1000 ]]; then
			lat_fmt=$(awk "BEGIN{printf \"%.1fs\", ${lat}/1000.0}")
		else
			lat_fmt="${lat}ms"
		fi

		local cost_fmt
		cost_fmt=$(printf "\$%.4f" "$cost")

		printf "| %-20s | %-22s | %7s | %7s | %9s | %5s |\n" \
			"$ts_short" "$model" "$lat_fmt" "$tok_out" "$cost_fmt" "$judge"
	done

	echo ""

	# Show aggregate stats
	local total_entries
	total_entries=$(wc -l <"$BENCH_RESULTS_FILE" | tr -d ' ')
	echo "Total entries: $total_entries"
	echo "File: $BENCH_RESULTS_FILE"
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
	list)
		cmd_list
		;;
	compare)
		cmd_compare "$@"
		;;
	recommend)
		cmd_recommend "${*:-}"
		;;
	pricing)
		cmd_pricing
		;;
	context)
		cmd_context
		;;
	capabilities)
		cmd_capabilities
		;;
	patterns)
		cmd_patterns "$@"
		;;
	providers)
		cmd_providers
		;;
	discover)
		cmd_discover "$@"
		;;
	score)
		cmd_score "$@"
		;;
	results)
		cmd_results "$@"
		;;
	cross-review)
		cmd_cross_review "$@"
		;;
	bench)
		cmd_bench "$@"
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
