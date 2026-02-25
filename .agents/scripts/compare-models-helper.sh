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
#   cross-review  Dispatch same prompt to multiple models, diff results, optionally score via judge (t132.8, t1329)
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
# Usage: model_id_to_tier "claude-sonnet-4" -> "sonnet"
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
		pattern_lines=$(get_all_tier_patterns)
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
# Cross-Model Review (t132.8, t1329)
# Dispatch the same review prompt to multiple models, collect results, diff.
# Optional --score flag dispatches outputs to a judge model for structured scoring.
# =============================================================================

#######################################
# Resolve Anthropic API auth header (API key or OAuth)
# Outputs: header string on stdout (e.g. "x-api-key: sk-...")
# Returns: 0 on success, 1 if no auth available
#######################################
_resolve_cross_review_auth() {
	local auth_file="${HOME}/.local/share/opencode/auth.json"

	# Priority 1: environment variable
	if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
		echo "x-api-key: ${ANTHROPIC_API_KEY}"
		return 0
	fi

	# Priority 2: OAuth token from OpenCode auth.json
	if [[ -f "$auth_file" ]] && command -v jq &>/dev/null; then
		local auth_type
		auth_type=$(jq -r '.anthropic.type // empty' "$auth_file" 2>/dev/null)

		if [[ "$auth_type" == "oauth" ]]; then
			local access_token expires_at now_ms
			access_token=$(jq -r '.anthropic.access // empty' "$auth_file" 2>/dev/null)
			expires_at=$(jq -r '.anthropic.expires // 0' "$auth_file" 2>/dev/null)
			now_ms=$(($(date +%s) * 1000))
			if [[ -n "$access_token" && "$expires_at" -gt "$now_ms" ]]; then
				echo "Authorization: Bearer ${access_token}"
				return 0
			fi
		elif [[ "$auth_type" == "api" ]]; then
			local api_key
			api_key=$(jq -r '.anthropic.key // empty' "$auth_file" 2>/dev/null)
			if [[ -n "$api_key" ]]; then
				echo "x-api-key: ${api_key}"
				return 0
			fi
		fi
	fi

	return 1
}

#######################################
# Judge cross-review outputs via a judge model (t1329)
# Reads model output files from output_dir, calls judge model API,
# returns structured JSON scores to stdout.
# Usage: _judge_cross_review <output_dir> <models_csv> <prompt> <judge_model> <task_type>
# Returns: 0 on success (JSON on stdout), 1 on failure
#######################################
_judge_cross_review() {
	local output_dir="$1"
	local models_csv="$2"
	local original_prompt="$3"
	local judge_model="$4"
	local task_type="${5:-general}"

	# Require curl and jq
	if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
		print_error "Judge scoring requires curl and jq"
		return 1
	fi

	# Resolve auth
	local auth_header
	auth_header=$(_resolve_cross_review_auth) || {
		print_error "Judge scoring requires Anthropic API key (ANTHROPIC_API_KEY or OpenCode OAuth)"
		return 1
	}

	# Build model outputs section for the judge prompt
	local outputs_text=""
	local -a model_array=()
	IFS=',' read -ra model_array <<<"$models_csv"

	for model_tier in "${model_array[@]}"; do
		model_tier=$(echo "$model_tier" | tr -d ' ')
		local result_file="${output_dir}/${model_tier}.txt"
		if [[ -f "$result_file" && -s "$result_file" ]]; then
			local response_text
			response_text=$(cat "$result_file")
			outputs_text="${outputs_text}

=== MODEL: ${model_tier} ===
${response_text}"
		fi
	done

	if [[ -z "$outputs_text" ]]; then
		print_error "No model outputs found to judge in $output_dir"
		return 1
	fi

	# Build judge system prompt
	local system_prompt
	system_prompt='You are an expert AI model evaluator. You will be given a prompt and responses from multiple AI models. Score each model on five criteria (1-10 scale) and declare a winner.

Scoring criteria:
- correctness (1-10): Factual accuracy and technical correctness
- completeness (1-10): Coverage of all requirements and edge cases
- quality (1-10): Code quality, best practices, structure (or writing quality for non-code)
- clarity (1-10): Clear explanation, good formatting, readability
- adherence (1-10): Following instructions precisely, staying on-task

Respond with ONLY a valid JSON object in this exact format (no markdown, no explanation):
{
  "scores": {
    "<model_name>": {
      "correctness": <1-10>,
      "completeness": <1-10>,
      "quality": <1-10>,
      "clarity": <1-10>,
      "adherence": <1-10>,
      "overall": <1-10>,
      "strengths": "<brief strengths>",
      "weaknesses": "<brief weaknesses>"
    }
  },
  "winner": "<model_name>",
  "winner_reasoning": "<1-2 sentence rationale for winner>",
  "task_type": "<code|analysis|text|review|general>"
}'

	local user_prompt
	user_prompt="ORIGINAL PROMPT:
${original_prompt}

MODEL RESPONSES:
${outputs_text}

Score each model and declare a winner."

	# Resolve judge model to full model ID
	local judge_model_id
	judge_model_id=$(resolve_model_tier "$judge_model" 2>/dev/null || echo "$judge_model")

	# Anthropic Messages API expects raw model IDs without provider prefix
	if [[ "$judge_model_id" == anthropic/* ]]; then
		judge_model_id="${judge_model_id#anthropic/}"
	elif [[ "$judge_model_id" == */* ]]; then
		print_error "--judge must resolve to an Anthropic model when using Anthropic judge API (got: $judge_model_id)"
		return 1
	fi

	# Build API request body
	local request_body
	request_body=$(jq -n \
		--arg model "$judge_model_id" \
		--arg system "$system_prompt" \
		--arg user "$user_prompt" \
		'{model: $model, max_tokens: 1024, system: $system, messages: [{role: "user", content: $user}]}')

	# Determine if OAuth (needs beta header)
	local header_name curl_extra_args=()
	header_name="${auth_header%%:*}"
	if [[ "$header_name" == "Authorization" ]]; then
		curl_extra_args+=(-H "anthropic-beta: oauth-2025-04-20")
	fi

	# Pass auth header via curl config file to avoid exposing secrets in process list
	local curl_config
	curl_config=$(mktemp)
	printf 'header = "%s"\n' "$auth_header" >"$curl_config"
	trap 'rm -f "$curl_config"' RETURN

	# Call judge model API
	local response
	response=$(curl -s --max-time 120 \
		-H "Content-Type: application/json" \
		-H "anthropic-version: 2023-06-01" \
		-K "$curl_config" \
		"${curl_extra_args[@]}" \
		-d "$request_body" \
		"https://api.anthropic.com/v1/messages") || {
		print_error "Judge API call failed (curl error)"
		return 1
	}

	# Extract text content from response
	local ai_text
	ai_text=$(echo "$response" | jq -r '.content[]? | select(.type == "text") | .text')

	if [[ -z "$ai_text" ]]; then
		local api_error
		api_error=$(echo "$response" | jq -r '.error.message // empty')
		print_error "Judge API returned no content (error: ${api_error:-unknown})"
		return 1
	fi

	# Strip markdown code fences if present — extract full JSON object without truncation
	local clean_json
	clean_json=$(echo "$ai_text" | sed -n '/^{/,/^}/p')
	if [[ -z "$clean_json" ]]; then
		clean_json="$ai_text"
	fi

	# Validate it's parseable JSON
	if ! echo "$clean_json" | jq . &>/dev/null; then
		print_error "Judge returned invalid JSON"
		return 1
	fi

	echo "$clean_json"
	return 0
}

#######################################
# Cross-model review: dispatch same prompt to multiple models (t132.8, t1329)
# Usage: compare-models-helper.sh cross-review --prompt "review this code" \
#          --models "sonnet,opus,pro" [--workdir path] [--timeout N] [--output dir]
#          [--score] [--judge opus] [--task-type code]
# Dispatches via runner-helper.sh in parallel, collects outputs, produces summary.
# With --score: dispatches outputs to judge model for structured scoring and DB recording.
#######################################
cmd_cross_review() {
	local prompt="" models_str="" workdir="" review_timeout="600" output_dir=""
	local do_score=0 judge_model="opus" task_type="general"

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
			do_score=1
			shift
			;;
		--judge)
			[[ $# -lt 2 ]] && {
				print_error "--judge requires a value"
				return 1
			}
			judge_model="$2"
			shift 2
			;;
		--task-type)
			[[ $# -lt 2 ]] && {
				print_error "--task-type requires a value"
				return 1
			}
			task_type="$2"
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
		model_tier=$(echo "$model_tier" | tr -d ' ')
		[[ -z "$model_tier" ]] && continue

		local runner_name="cross-review-${model_tier}-$$"
		runner_names+=("$runner_name")
		model_names+=("$model_tier")

		# Resolve tier to full model string for display
		local resolved_model
		resolved_model=$(resolve_model_tier "$model_tier")

		echo "  Dispatching to ${model_tier} (${resolved_model})..."

		# Create runner, dispatch, capture output
		(
			"$runner_helper" create "$runner_name" \
				--model "$model_tier" \
				--description "Cross-review: $model_tier" \
				--workdir "$workdir" 2>/dev/null || true

			local result_file="${output_dir}/${model_tier}.txt"
			"$runner_helper" run "$runner_name" "$prompt" \
				--model "$model_tier" \
				--timeout "$review_timeout" \
				--format json 2>/dev/null >"${output_dir}/${model_tier}.json" || true

			# Extract text response from JSON
			if [[ -f "${output_dir}/${model_tier}.json" ]]; then
				jq -r '.parts[]? | select(.type == "text") | .text' \
					"${output_dir}/${model_tier}.json" 2>/dev/null >"$result_file" || true
			fi

			# Clean up runner
			"$runner_helper" destroy "$runner_name" --force 2>/dev/null || true
		) &
		pids+=($!)
	done

	# Wait for all dispatches to complete
	echo ""
	echo "Waiting for ${#pids[@]} models to respond..."
	local failed=0
	for i in "${!pids[@]}"; do
		if ! wait "${pids[$i]}" 2>/dev/null; then
			echo "  ${model_names[$i]}: failed"
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
			diff --unified=3 "$file_a" "$file_b" 2>/dev/null | head -100 || echo "  (files are identical or diff unavailable)"
			echo ""
		fi
	fi

	echo "Full results saved to: $output_dir"
	echo ""

	# ==========================================================================
	# Judge scoring pipeline (t1329) — activated by --score flag
	# ==========================================================================
	if [[ "$do_score" -eq 1 ]]; then
		echo "=== JUDGE SCORING ==="
		echo ""
		echo "Judge model: ${judge_model}"
		echo "Task type:   ${task_type}"
		echo ""
		echo "Dispatching outputs to judge model..."

		local judge_json
		if ! judge_json=$(_judge_cross_review "$output_dir" "$models_str" "$prompt" "$judge_model" "$task_type"); then
			print_error "Judge scoring failed — raw outputs still saved to $output_dir"
			return 1
		fi

		# Save judge output
		local judge_file="${output_dir}/judge-scores.json"
		echo "$judge_json" >"$judge_file"

		# Display structured scores
		echo ""
		echo "Judge Scores:"
		echo "-------------"
		printf "%-22s %6s %6s %6s %6s %7s\n" "Model" "Corr" "Comp" "Qual" "Clar" "Overall"
		printf "%-22s %6s %6s %6s %6s %7s\n" "-----" "----" "----" "----" "----" "-------"

		local winner=""
		winner=$(echo "$judge_json" | jq -r '.winner // empty')
		local winner_reasoning=""
		winner_reasoning=$(echo "$judge_json" | jq -r '.winner_reasoning // empty')
		local judge_task_type=""
		judge_task_type=$(echo "$judge_json" | jq -r '.task_type // empty')
		[[ -n "$judge_task_type" ]] && task_type="$judge_task_type"

		# Build cmd_score args from judge JSON
		local score_args=(--task "$prompt" --type "$task_type" --evaluator "$judge_model" --winner "$winner")

		local -a scored_models=()
		while IFS= read -r model_name; do
			scored_models+=("$model_name")
		done < <(echo "$judge_json" | jq -r '.scores | keys[]')

		for model_name in "${scored_models[@]}"; do
			# Consolidate jq calls into a single pass using --arg for safe variable passing
			local m_corr m_comp m_qual m_clar m_adh m_overall m_str m_wea
			read -r m_corr m_comp m_qual m_clar m_adh m_overall m_str m_wea <<<"$(echo "$judge_json" | jq -r --arg mn "$model_name" '
				.scores[$mn] |
				[
					(.correctness // 0),
					(.completeness // 0),
					(.quality // 0),
					(.clarity // 0),
					(.adherence // 0),
					(.overall // 0),
					(.strengths // ""),
					(.weaknesses // "")
				] | @tsv
			')"

			local result_file="${output_dir}/${model_name}.txt"
			printf "%-22s %6s %6s %6s %6s %7s\n" \
				"$model_name" "$m_corr" "$m_comp" "$m_qual" "$m_clar" "$m_overall"

			# Accumulate args for cmd_score (1-10 scale matches model-comparisons DB)
			score_args+=(
				--model "$model_name"
				--correctness "$m_corr"
				--completeness "$m_comp"
				--quality "$m_qual"
				--clarity "$m_clar"
				--adherence "$m_adh"
				--strengths "$m_str"
				--weaknesses "$m_wea"
				--response "${result_file:-}"
			)
		done

		echo ""
		if [[ -n "$winner" ]]; then
			echo "  Winner: ${winner}"
		fi
		if [[ -n "$winner_reasoning" ]]; then
			echo "  Reasoning: ${winner_reasoning}"
		fi
		echo ""

		# Record scores in model-comparisons DB via cmd_score
		echo "Recording scores in model-comparisons DB..."
		if cmd_score "${score_args[@]}"; then
			print_success "Scores recorded in model-comparisons DB"
		else
			print_warning "cmd_score recording failed (scores still in $judge_file)"
		fi

		# Feed winner/loser data into pattern tracker
		local pt_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
		if [[ -x "$pt_helper" && -n "$winner" ]]; then
			echo "Syncing results to pattern tracker..."
			local winner_tier loser_args=() winner_overall_score=0
			winner_tier=$(model_id_to_tier "$winner")
			[[ -z "$winner_tier" ]] && winner_tier="$winner"

			for model_name in "${scored_models[@]}"; do
				# Extract scores in a single jq pass using --arg for safe variable passing
				local m_ove raw_corr raw_comp raw_qual raw_clar
				read -r m_ove raw_corr raw_comp raw_qual raw_clar <<<"$(echo "$judge_json" | jq -r --arg mn "$model_name" '
					.scores[$mn] | [(.overall // 0), (.correctness // 0), (.completeness // 0), (.quality // 0), (.clarity // 0)] | @tsv
				')"
				local m_tier
				m_tier=$(model_id_to_tier "$model_name")
				[[ -z "$m_tier" ]] && m_tier="$model_name"

				# Normalize 1-10 to 1-5 for pattern tracker
				local norm_corr norm_comp norm_qual norm_clar
				norm_corr=$(awk "BEGIN{v=int($raw_corr/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
				norm_comp=$(awk "BEGIN{v=int($raw_comp/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
				norm_qual=$(awk "BEGIN{v=int($raw_qual/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
				norm_clar=$(awk "BEGIN{v=int($raw_clar/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")

				"$pt_helper" score \
					--model "$m_tier" \
					--task-type "$task_type" \
					--correctness "$norm_corr" \
					--completeness "$norm_comp" \
					--code-quality "$norm_qual" \
					--clarity "$norm_clar" \
					--source "cross-review-judge" \
					>/dev/null 2>&1 || true

				if [[ "$model_name" == "$winner" ]]; then
					winner_overall_score="$m_ove"
				elif [[ "$model_name" != "$winner" ]]; then
					loser_args+=(--loser "$m_tier")
				fi
			done

			# Record A/B comparison in pattern tracker
			if [[ -n "$winner_tier" && "${#loser_args[@]}" -gt 0 ]]; then
				local winner_avg_norm
				winner_avg_norm=$(awk "BEGIN{printf \"%.1f\", $winner_overall_score / 2}")
				"$pt_helper" ab-compare \
					--winner "$winner_tier" \
					"${loser_args[@]}" \
					--task-type "$task_type" \
					--winner-score "$winner_avg_norm" \
					--models-compared "${#scored_models[@]}" \
					--source "cross-review-judge" \
					>/dev/null 2>&1 || true
			fi

			print_success "Pattern tracker updated"
		fi

		echo ""
		echo "Judge output saved to: $judge_file"
		echo ""
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
	echo "  compare-models-helper.sh results"
	echo "  compare-models-helper.sh results --model sonnet --limit 5"
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
	echo "    --prompt 'Review this PR diff for bugs' \\"
	echo "    --models 'sonnet,opus' --score"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this PR diff for bugs' \\"
	echo "    --models 'sonnet,opus,pro' --score --judge opus --task-type review"
	echo ""
	echo "Cross-review options:"
	echo "  --score          Auto-score outputs via judge model (default: opus)"
	echo "  --judge <model>  Judge model tier (default: opus)"
	echo "  --task-type <t>  Task type for scoring: code|review|analysis|text|general"
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
    winner_model TEXT
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
SQL
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

	# Insert comparison record
	local comp_id
	comp_id=$(sqlite3 "$RESULTS_DB" "INSERT INTO comparisons (task_description, task_type, evaluator_model, winner_model) VALUES ('$(echo "$task" | sed "s/'/''/g")', '$task_type', '$evaluator', '$winner'); SELECT last_insert_rowid();")

	# Insert scores for each model
	for entry in "${model_entries[@]}"; do
		IFS='|' read -r m_id m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok m_str m_wea m_res <<<"$entry"
		sqlite3 "$RESULTS_DB" "INSERT INTO comparison_scores (comparison_id, model_id, correctness, completeness, code_quality, clarity, adherence, overall, latency_ms, tokens_used, strengths, weaknesses, response_file) VALUES ($comp_id, '$m_id', $m_cor, $m_com, $m_qua, $m_cla, $m_adh, $m_ove, $m_lat, $m_tok, '$(echo "$m_str" | sed "s/'/''/g")', '$(echo "$m_wea" | sed "s/'/''/g")', '$(echo "$m_res" | sed "s/'/''/g")');"
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
	local model_filter="" type_filter=""

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
		*) shift ;;
		esac
	done

	local where_clause=""
	if [[ -n "$model_filter" ]]; then
		where_clause="WHERE cs.model_id LIKE '%${model_filter}%'"
	fi
	if [[ -n "$type_filter" ]]; then
		if [[ -n "$where_clause" ]]; then
			where_clause="$where_clause AND c.task_type = '$type_filter'"
		else
			where_clause="WHERE c.task_type = '$type_filter'"
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
        SELECT c.id, c.created_at, c.task_type, c.task_description, c.winner_model
        FROM comparisons c
        ORDER BY c.created_at DESC
        LIMIT $limit;
    " 2>/dev/null | while IFS='|' read -r cid cdate ctype cdesc cwinner; do
		echo "  #$cid [$ctype] $(echo "$cdesc" | head -c 60) ($cdate)"
		if [[ -n "$cwinner" ]]; then
			echo "    Winner: $cwinner"
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
