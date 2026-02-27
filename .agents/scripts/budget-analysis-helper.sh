#!/usr/bin/env bash
# Budget Analysis & Recommendation Engine (t1357.7)
# Analyses likely outcomes for a requested budget (time/money/tokens).
# Recommends budget scales with tiered outcome descriptions.
# Integrates with budget-tracker-helper.sh for historical data and
# shared-constants.sh for model pricing.
#
# Commands: analyse, recommend, estimate, forecast, help
#
# Usage:
#   budget-analysis-helper.sh analyse --budget 50 --hours 8
#   budget-analysis-helper.sh recommend --goal "Build a CRM"
#   budget-analysis-helper.sh estimate --task "Fix auth bug" --tier sonnet
#   budget-analysis-helper.sh forecast --days 7
#   budget-analysis-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

readonly BUDGET_DIR="${HOME}/.aidevops/.agent-workspace"
readonly COST_LOG="${BUDGET_DIR}/cost-log.tsv"
readonly ROUTING_TABLE="${SCRIPT_DIR}/../configs/model-routing-table.json"

# =============================================================================
# Task Complexity Heuristics
# =============================================================================
# Complexity tiers map to estimated token usage per task.
# Based on Factory.ai mission data: median ~2h, 19K tokens/message,
# typical task = 5-20 messages. These are conservative baselines;
# the AI caller should adjust based on actual task description.

# Tokens per task by complexity (input + output combined)
readonly COMPLEXITY_TRIVIAL_TOKENS=50000   # ~5 messages, simple fix
readonly COMPLEXITY_SIMPLE_TOKENS=150000   # ~10 messages, single-file change
readonly COMPLEXITY_MODERATE_TOKENS=400000 # ~20 messages, multi-file feature
readonly COMPLEXITY_COMPLEX_TOKENS=1000000 # ~40 messages, architecture + impl
readonly COMPLEXITY_MISSION_TOKENS=3000000 # ~100+ messages, multi-day mission

# Hours per task by complexity (wall-clock, including AI wait time)
readonly COMPLEXITY_TRIVIAL_HOURS="0.25"
readonly COMPLEXITY_SIMPLE_HOURS="1"
readonly COMPLEXITY_MODERATE_HOURS="3"
readonly COMPLEXITY_COMPLEX_HOURS="8"
readonly COMPLEXITY_MISSION_HOURS="24"

# =============================================================================
# Tier Cost Profiles
# =============================================================================
# Pre-computed cost per 1M tokens (input+output blended) for each tier.
# Uses 3:1 output:input ratio (typical for code generation).
# Formula: (input_price * 0.25 + output_price * 0.75) per 1M tokens

get_tier_blended_cost() {
	local tier="$1"
	local model
	model=$(resolve_model_tier "$tier")
	local pricing
	pricing=$(get_model_pricing "$model")
	local input_price="${pricing%%|*}"
	local output_price
	output_price=$(echo "$pricing" | cut -d'|' -f2)

	# Blended cost: 25% input, 75% output (typical code generation ratio)
	awk "BEGIN { printf \"%.4f\", ($input_price * 0.25 + $output_price * 0.75) }"
	return 0
}

# Calculate cost for a given token count at a tier
calculate_tier_cost() {
	local tokens="$1"
	local tier="$2"
	local blended
	blended=$(get_tier_blended_cost "$tier")
	awk "BEGIN { printf \"%.2f\", ($tokens / 1000000.0) * $blended }"
	return 0
}

# =============================================================================
# Historical Pattern Analysis
# =============================================================================
# Reads cost-log.tsv to derive actual spend patterns for estimation.

get_historical_stats() {
	local json_flag="${1:-false}"

	if [[ ! -f "$COST_LOG" ]]; then
		if [[ "$json_flag" == "true" ]]; then
			echo '{"has_history":false,"avg_daily_cost":0,"avg_task_cost":0,"avg_tokens_per_task":0,"total_tasks":0,"total_days":0}'
		else
			echo "No historical data available."
		fi
		return 0
	fi

	awk -F'\t' -v jf="$json_flag" '
		NR == 1 { next }
		{
			day = substr($1, 1, 10)
			days[day] = 1
			tc += $8; ti += $6; to += $7; ec++
			if ($5 != "" && $5 != "-") {
				task_cost[$5] += $8
				task_tokens[$5] += ($6 + $7)
				task_count[$5] = 1
			}
		}
		END {
			nd = 0; for (d in days) nd++
			nt = 0; ttc = 0; ttt = 0
			for (t in task_count) {
				nt++; ttc += task_cost[t]; ttt += task_tokens[t]
			}
			avg_daily = (nd > 0) ? tc / nd : 0
			avg_task_cost = (nt > 0) ? ttc / nt : 0
			avg_task_tokens = (nt > 0) ? ttt / nt : 0

			if (jf == "true") {
				printf "{\"has_history\":true,\"avg_daily_cost\":%.2f,\"avg_task_cost\":%.2f,\"avg_tokens_per_task\":%d,\"total_tasks\":%d,\"total_days\":%d,\"total_cost\":%.2f,\"total_events\":%d}\n", avg_daily, avg_task_cost, avg_task_tokens, nt, nd, tc, ec
			} else {
				printf "Historical Stats\n"
				printf "  Total days:          %d\n", nd
				printf "  Total tasks:         %d\n", nt
				printf "  Total cost:          $%.2f\n", tc
				printf "  Avg daily cost:      $%.2f\n", avg_daily
				printf "  Avg cost per task:   $%.2f\n", avg_task_cost
				printf "  Avg tokens per task: %d\n", avg_task_tokens
			}
		}
	' "$COST_LOG"
	return 0
}

# Get current burn rate (today's spend extrapolated)
get_current_burn_rate() {
	if [[ ! -f "$COST_LOG" ]]; then
		echo "0.00"
		return 0
	fi

	local today
	today=$(date -u +%Y-%m-%d)
	local hours_elapsed
	hours_elapsed=$(date -u +%H)
	hours_elapsed=$((hours_elapsed == 0 ? 1 : hours_elapsed))

	awk -F'\t' -v today="$today" -v hrs="$hours_elapsed" '
		NR == 1 { next }
		{
			day = substr($1, 1, 10)
			if (day == today) tc += $8
		}
		END {
			printf "%.2f", (hrs > 0) ? tc / hrs : 0
		}
	' "$COST_LOG"
	return 0
}

# =============================================================================
# Complexity Classification
# =============================================================================
# Heuristic classification of task complexity from description keywords.
# Returns: trivial|simple|moderate|complex|mission

classify_complexity() {
	local description="$1"
	local desc_lower
	desc_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')

	# Mission-level indicators
	if echo "$desc_lower" | grep -qE '(multi-day|full system|entire platform|from scratch|complete rewrite|autonomous|mission)'; then
		echo "mission"
		return 0
	fi

	# Complex indicators
	if echo "$desc_lower" | grep -qE '(architecture|design system|multi-service|database migration|security audit|refactor.*entire|integration.*multiple|build.*(app|platform|system|portal|saas|crm|cms|dashboard|api))'; then
		echo "complex"
		return 0
	fi

	# Moderate indicators
	if echo "$desc_lower" | grep -qE '(feature|implement|build|create|add.*with.*tests|crud|api endpoint|component|workflow|pipeline|migrate|deploy|setup.*ci)'; then
		echo "moderate"
		return 0
	fi

	# Simple indicators
	if echo "$desc_lower" | grep -qE '(fix|bug|update|rename|change.*config|add.*field|modify|adjust|tweak)'; then
		echo "simple"
		return 0
	fi

	# Default: trivial for very short descriptions, simple otherwise
	local word_count
	word_count=$(echo "$description" | wc -w | tr -d ' ')
	if [[ "$word_count" -lt 5 ]]; then
		echo "trivial"
	else
		echo "simple"
	fi
	return 0
}

get_complexity_tokens() {
	local complexity="$1"
	case "$complexity" in
	trivial) echo "$COMPLEXITY_TRIVIAL_TOKENS" ;;
	simple) echo "$COMPLEXITY_SIMPLE_TOKENS" ;;
	moderate) echo "$COMPLEXITY_MODERATE_TOKENS" ;;
	complex) echo "$COMPLEXITY_COMPLEX_TOKENS" ;;
	mission) echo "$COMPLEXITY_MISSION_TOKENS" ;;
	*) echo "$COMPLEXITY_MODERATE_TOKENS" ;;
	esac
	return 0
}

get_complexity_hours() {
	local complexity="$1"
	case "$complexity" in
	trivial) echo "$COMPLEXITY_TRIVIAL_HOURS" ;;
	simple) echo "$COMPLEXITY_SIMPLE_HOURS" ;;
	moderate) echo "$COMPLEXITY_MODERATE_HOURS" ;;
	complex) echo "$COMPLEXITY_COMPLEX_HOURS" ;;
	mission) echo "$COMPLEXITY_MISSION_HOURS" ;;
	*) echo "$COMPLEXITY_MODERATE_HOURS" ;;
	esac
	return 0
}

# =============================================================================
# Commands
# =============================================================================

# analyse: Full budget analysis for a given budget (money and/or time)
# Shows what can be accomplished within the budget at different quality tiers.
cmd_analyse() {
	local budget_usd="" budget_hours="" tier="sonnet" json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--budget | --usd)
			budget_usd="${2:-}"
			shift 2
			;;
		--hours | --time)
			budget_hours="${2:-}"
			shift 2
			;;
		--tier)
			tier="${2:-sonnet}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$budget_usd" && -z "$budget_hours" ]]; then
		print_error "Usage: budget-analysis-helper.sh analyse --budget <USD> [--hours <H>] [--tier <tier>] [--json]"
		return 1
	fi

	# Calculate what the budget buys at each tier
	local tiers=("haiku" "sonnet" "opus")
	local tier_labels=("Economy (haiku)" "Standard (sonnet)" "Premium (opus)")

	if [[ "$json_flag" == "true" ]]; then
		printf '{"budget_usd":%s,"budget_hours":%s,"tiers":[' \
			"${budget_usd:-null}" "${budget_hours:-null}"
	else
		printf '\n%sBudget Analysis%s\n' "$WHITE" "$NC"
		printf '================================\n\n'
		if [[ -n "$budget_usd" ]]; then
			printf '  Budget:  $%s\n' "$budget_usd"
		fi
		if [[ -n "$budget_hours" ]]; then
			printf '  Time:    %s hours\n' "$budget_hours"
		fi
		printf '\n'
	fi

	local first=true
	local i=0
	for t in "${tiers[@]}"; do
		local blended_cost
		blended_cost=$(get_tier_blended_cost "$t")
		local tokens_per_dollar
		tokens_per_dollar=$(awk "BEGIN { printf \"%d\", 1000000.0 / $blended_cost }")

		local available_tokens=0
		if [[ -n "$budget_usd" ]]; then
			available_tokens=$(awk "BEGIN { printf \"%d\", $budget_usd / $blended_cost * 1000000 }")
		fi

		# Estimate tasks achievable (using moderate complexity as baseline)
		local tasks_achievable=0
		if [[ "$available_tokens" -gt 0 ]]; then
			tasks_achievable=$(awk "BEGIN { printf \"%d\", $available_tokens / $COMPLEXITY_MODERATE_TOKENS }")
		fi

		# Estimate messages (19K tokens per message from Factory.ai data)
		local messages=0
		if [[ "$available_tokens" -gt 0 ]]; then
			messages=$(awk "BEGIN { printf \"%d\", $available_tokens / 19000 }")
		fi

		if [[ "$json_flag" == "true" ]]; then
			if [[ "$first" != "true" ]]; then printf ','; fi
			printf '{"tier":"%s","blended_cost_per_1m":%.4f,"tokens_per_dollar":%d,"available_tokens":%d,"est_moderate_tasks":%d,"est_messages":%d}' \
				"$t" "$blended_cost" "$tokens_per_dollar" "$available_tokens" "$tasks_achievable" "$messages"
		else
			printf '  %s%s%s\n' "$CYAN" "${tier_labels[$i]}" "$NC"
			printf '    Cost per 1M tokens:  $%.4f\n' "$blended_cost"
			printf '    Tokens per dollar:   %s\n' "$(printf '%d' "$tokens_per_dollar" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"
			if [[ -n "$budget_usd" ]]; then
				printf '    Available tokens:    %s\n' "$(printf '%d' "$available_tokens" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"
				printf '    Est. tasks (moderate): %d\n' "$tasks_achievable"
				printf '    Est. AI messages:    %d\n' "$messages"
			fi
			printf '\n'
		fi

		first=false
		i=$((i + 1))
	done

	if [[ "$json_flag" == "true" ]]; then
		printf ']}\n'
	else
		# Add historical context if available
		if [[ -f "$COST_LOG" ]]; then
			printf '  %sHistorical Context%s\n' "$YELLOW" "$NC"
			local burn_rate
			burn_rate=$(get_current_burn_rate)
			printf '    Current burn rate:   $%s/hr\n' "$burn_rate"
			if [[ -n "$budget_usd" ]] && awk "BEGIN { exit ($burn_rate > 0) ? 0 : 1 }"; then
				local hours_remaining
				hours_remaining=$(awk "BEGIN { printf \"%.1f\", $budget_usd / $burn_rate }")
				printf '    Budget lasts:        %s hours at current rate\n' "$hours_remaining"
			fi
			printf '\n'
		fi
	fi
	return 0
}

# recommend: Generate tiered outcome recommendations for a goal
# Shows what you get at different budget levels.
cmd_recommend() {
	local goal="" json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--goal | --description)
			goal="${2:-}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$goal" ]]; then
		print_error "Usage: budget-analysis-helper.sh recommend --goal \"description of goal\""
		return 1
	fi

	local complexity
	complexity=$(classify_complexity "$goal")
	local base_tokens
	base_tokens=$(get_complexity_tokens "$complexity")
	local base_hours
	base_hours=$(get_complexity_hours "$complexity")

	# Three tiers of outcome: MVP, Production, Polished
	# MVP: haiku-heavy, minimal tests, basic implementation
	# Production: sonnet-heavy, full tests, error handling, docs
	# Polished: opus for design + sonnet for impl, monitoring, CI/CD, docs

	local mvp_tokens
	mvp_tokens=$(awk "BEGIN { printf \"%d\", $base_tokens * 0.6 }")
	local prod_tokens
	prod_tokens=$(awk "BEGIN { printf \"%d\", $base_tokens * 1.5 }")
	local polished_tokens
	polished_tokens=$(awk "BEGIN { printf \"%d\", $base_tokens * 3.0 }")

	local mvp_hours
	mvp_hours=$(awk "BEGIN { printf \"%.1f\", $base_hours * 0.5 }")
	local prod_hours
	prod_hours=$(awk "BEGIN { printf \"%.1f\", $base_hours * 1.5 }")
	local polished_hours
	polished_hours=$(awk "BEGIN { printf \"%.1f\", $base_hours * 3.0 }")

	# Cost calculations (MVP uses haiku, Production uses sonnet, Polished uses opus+sonnet blend)
	local mvp_cost
	mvp_cost=$(calculate_tier_cost "$mvp_tokens" "haiku")
	local prod_cost
	prod_cost=$(calculate_tier_cost "$prod_tokens" "sonnet")
	# Polished: 30% opus (design) + 70% sonnet (implementation)
	local polished_opus_cost
	polished_opus_cost=$(calculate_tier_cost "$(awk "BEGIN { printf \"%d\", $polished_tokens * 0.3 }")" "opus")
	local polished_sonnet_cost
	polished_sonnet_cost=$(calculate_tier_cost "$(awk "BEGIN { printf \"%d\", $polished_tokens * 0.7 }")" "sonnet")
	local polished_cost
	polished_cost=$(awk "BEGIN { printf \"%.2f\", $polished_opus_cost + $polished_sonnet_cost }")

	if [[ "$json_flag" == "true" ]]; then
		printf '{"goal":"%s","complexity":"%s","recommendations":[' \
			"$(echo "$goal" | sed 's/"/\\"/g')" "$complexity"
		printf '{"tier":"mvp","label":"Basic MVP","cost_usd":%.2f,"hours":%.1f,"tokens":%d,"includes":["Basic implementation","Minimal error handling","No tests","No docs"]},' \
			"$mvp_cost" "$mvp_hours" "$mvp_tokens"
		printf '{"tier":"production","label":"Production-Ready","cost_usd":%.2f,"hours":%.1f,"tokens":%d,"includes":["Full implementation","Error handling","Unit tests","Basic docs","CI integration"]},' \
			"$prod_cost" "$prod_hours" "$prod_tokens"
		printf '{"tier":"polished","label":"Polished + Monitored","cost_usd":%.2f,"hours":%.1f,"tokens":%d,"includes":["Architecture review (opus)","Full implementation","Comprehensive tests","Full docs","Monitoring","CI/CD pipeline","Performance optimisation"]}' \
			"$polished_cost" "$polished_hours" "$polished_tokens"
		printf ']}\n'
	else
		printf '\n%sBudget Recommendations%s\n' "$WHITE" "$NC"
		printf '================================\n\n'
		printf '  Goal:       %s\n' "$goal"
		printf '  Complexity: %s%s%s\n\n' "$CYAN" "$complexity" "$NC"

		printf '  %s1. Basic MVP%s\n' "$GREEN" "$NC"
		printf '     Cost:     ~$%.2f  |  Time: ~%sh\n' "$mvp_cost" "$mvp_hours"
		printf '     Model:    haiku-heavy (economy)\n'
		printf '     Includes: Basic implementation, minimal error handling\n'
		printf '     Skips:    Tests, docs, monitoring\n\n'

		printf '  %s2. Production-Ready%s\n' "$YELLOW" "$NC"
		printf '     Cost:     ~$%.2f  |  Time: ~%sh\n' "$prod_cost" "$prod_hours"
		printf '     Model:    sonnet (standard)\n'
		printf '     Includes: Full implementation, error handling, unit tests, basic docs\n'
		printf '     Skips:    Monitoring, performance tuning, comprehensive docs\n\n'

		printf '  %s3. Polished + Monitored%s\n' "$PURPLE" "$NC"
		printf '     Cost:     ~$%.2f  |  Time: ~%sh\n' "$polished_cost" "$polished_hours"
		printf '     Model:    opus (design) + sonnet (implementation)\n'
		printf '     Includes: Architecture review, full implementation, comprehensive tests,\n'
		printf '               full docs, monitoring, CI/CD, performance optimisation\n\n'

		# Add historical calibration note if data exists
		if [[ -f "$COST_LOG" ]]; then
			local stats
			stats=$(get_historical_stats "true")
			local avg_task_cost
			avg_task_cost=$(echo "$stats" | grep -o '"avg_task_cost":[0-9.]*' | cut -d: -f2)
			if [[ -n "$avg_task_cost" ]] && awk "BEGIN { exit ($avg_task_cost > 0) ? 0 : 1 }"; then
				printf '  %sCalibration Note%s\n' "$BLUE" "$NC"
				printf '     Your historical avg cost per task: $%s\n' "$avg_task_cost"
				printf '     Estimates above are heuristic — actual costs may vary based\n'
				printf '     on codebase size, iteration count, and model availability.\n\n'
			fi
		fi
	fi
	return 0
}

# estimate: Estimate cost for a specific task at a given tier
cmd_estimate() {
	local task="" tier="sonnet" complexity="" json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task | --description)
			task="${2:-}"
			shift 2
			;;
		--tier)
			tier="${2:-sonnet}"
			shift 2
			;;
		--complexity)
			complexity="${2:-}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$task" ]]; then
		print_error "Usage: budget-analysis-helper.sh estimate --task \"description\" [--tier <tier>] [--complexity <level>]"
		return 1
	fi

	# Auto-classify if not provided
	if [[ -z "$complexity" ]]; then
		complexity=$(classify_complexity "$task")
	fi

	local tokens
	tokens=$(get_complexity_tokens "$complexity")
	local hours
	hours=$(get_complexity_hours "$complexity")
	local cost
	cost=$(calculate_tier_cost "$tokens" "$tier")
	local blended
	blended=$(get_tier_blended_cost "$tier")

	# Calculate range (0.5x to 2x for uncertainty)
	local cost_low
	cost_low=$(awk "BEGIN { printf \"%.2f\", $cost * 0.5 }")
	local cost_high
	cost_high=$(awk "BEGIN { printf \"%.2f\", $cost * 2.0 }")
	local hours_low
	hours_low=$(awk "BEGIN { printf \"%.1f\", $hours * 0.5 }")
	local hours_high
	hours_high=$(awk "BEGIN { printf \"%.1f\", $hours * 2.0 }")

	if [[ "$json_flag" == "true" ]]; then
		printf '{"task":"%s","complexity":"%s","tier":"%s","est_tokens":%d,"est_cost_usd":%.2f,"cost_range":[%.2f,%.2f],"est_hours":%s,"hours_range":[%s,%s],"blended_cost_per_1m":%.4f}\n' \
			"$(echo "$task" | sed 's/"/\\"/g')" "$complexity" "$tier" \
			"$tokens" "$cost" "$cost_low" "$cost_high" \
			"$hours" "$hours_low" "$hours_high" "$blended"
	else
		printf '\n%sTask Estimate%s\n' "$WHITE" "$NC"
		printf '================================\n\n'
		printf '  Task:       %s\n' "$task"
		printf '  Complexity: %s%s%s\n' "$CYAN" "$complexity" "$NC"
		printf '  Tier:       %s\n\n' "$tier"
		printf '  Est. tokens:  %s\n' "$(printf '%d' "$tokens" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"
		printf '  Est. cost:    $%.2f  (range: $%s - $%s)\n' "$cost" "$cost_low" "$cost_high"
		printf '  Est. time:    %sh  (range: %s - %sh)\n\n' "$hours" "$hours_low" "$hours_high"

		# Show alternative tiers
		printf '  %sAlternative Tiers%s\n' "$YELLOW" "$NC"
		local alt_tiers=("haiku" "sonnet" "opus")
		for at in "${alt_tiers[@]}"; do
			if [[ "$at" == "$tier" ]]; then continue; fi
			local alt_cost
			alt_cost=$(calculate_tier_cost "$tokens" "$at")
			printf '    %-8s  $%.2f\n' "$at" "$alt_cost"
		done
		printf '\n'
	fi
	return 0
}

# forecast: Project future spend based on historical burn rate
cmd_forecast() {
	local days=7 json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="${2:-7}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ ! -f "$COST_LOG" ]]; then
		print_warning "No cost log found. Cannot forecast without historical data."
		print_info "Record spend events with: budget-tracker-helper.sh record --provider X --model Y"
		return 0
	fi

	# Calculate daily averages from historical data
	local forecast_data
	forecast_data=$(awk -F'\t' -v forecast_days="$days" -v jf="$json_flag" '
		NR == 1 { next }
		{
			day = substr($1, 1, 10)
			daily_cost[day] += $8
			daily_tokens[day] += ($6 + $7)
			daily_events[day]++
			total_cost += $8
			total_tokens += ($6 + $7)
			total_events++
		}
		END {
			nd = 0
			for (d in daily_cost) nd++

			if (nd == 0) {
				if (jf == "true") {
					printf "{\"error\":\"no_data\"}\n"
				} else {
					printf "No historical data to forecast from.\n"
				}
				exit
			}

			avg_daily_cost = total_cost / nd
			avg_daily_tokens = total_tokens / nd
			avg_daily_events = total_events / nd

			# Calculate variance for confidence interval
			variance = 0
			for (d in daily_cost) {
				diff = daily_cost[d] - avg_daily_cost
				variance += diff * diff
			}
			variance = (nd > 1) ? variance / (nd - 1) : 0
			stddev = sqrt(variance)

			forecast_cost = avg_daily_cost * forecast_days
			forecast_low = (avg_daily_cost - stddev) * forecast_days
			if (forecast_low < 0) forecast_low = 0
			forecast_high = (avg_daily_cost + stddev) * forecast_days
			forecast_tokens = avg_daily_tokens * forecast_days

			if (jf == "true") {
				printf "{\"forecast_days\":%d,\"historical_days\":%d,\"avg_daily_cost\":%.2f,\"avg_daily_tokens\":%d,\"stddev\":%.2f,\"forecast_cost\":%.2f,\"forecast_range\":[%.2f,%.2f],\"forecast_tokens\":%d}\n", forecast_days, nd, avg_daily_cost, avg_daily_tokens, stddev, forecast_cost, forecast_low, forecast_high, forecast_tokens
			} else {
				printf "\nSpend Forecast (%d days)\n================================\n\n", forecast_days
				printf "  Historical basis:    %d days of data\n", nd
				printf "  Avg daily cost:      $%.2f\n", avg_daily_cost
				printf "  Avg daily tokens:    %d\n", avg_daily_tokens
				printf "  Daily std deviation: $%.2f\n\n", stddev
				printf "  Forecast (%d days):\n", forecast_days
				printf "    Expected cost:     $%.2f\n", forecast_cost
				printf "    Range (1 sigma):   $%.2f - $%.2f\n", forecast_low, forecast_high
				printf "    Expected tokens:   %d\n\n", forecast_tokens

				if (nd < 7) {
					printf "  Note: Only %d days of data. Forecast accuracy improves with\n", nd
					printf "  more historical data (recommend 14+ days).\n\n"
				}
			}
		}
	' "$COST_LOG")

	echo "$forecast_data"
	return 0
}

cmd_help() {
	cat <<'EOF'
Budget Analysis & Recommendation Engine (t1357.7)

Usage: budget-analysis-helper.sh [command] [options]

Commands:
  analyse     Full budget analysis — what a budget buys at each tier
  recommend   Tiered outcome recommendations for a goal
  estimate    Cost estimate for a specific task
  forecast    Project future spend from historical burn rate
  help        Show this help

Analyse options:
  --budget N    Budget in USD
  --hours N     Time budget in hours
  --tier X      Default model tier (default: sonnet)
  --json        Machine-readable output

Recommend options:
  --goal "X"    Description of the goal/project
  --json        Machine-readable output

Estimate options:
  --task "X"       Task description
  --tier X         Model tier (default: sonnet)
  --complexity X   Override: trivial|simple|moderate|complex|mission
  --json           Machine-readable output

Forecast options:
  --days N      Forecast period (default: 7)
  --json        Machine-readable output

Examples:
  budget-analysis-helper.sh analyse --budget 50 --hours 8
  budget-analysis-helper.sh recommend --goal "Build a CRM with contacts and deals"
  budget-analysis-helper.sh estimate --task "Fix authentication bug" --tier sonnet
  budget-analysis-helper.sh forecast --days 30

Integration:
  Reads historical data from budget-tracker-helper.sh cost log.
  Uses model pricing from shared-constants.sh get_model_pricing().
  Designed for use by /mission command during scoping phase.
EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	analyse | analyze) cmd_analyse "$@" ;;
	recommend) cmd_recommend "$@" ;;
	estimate) cmd_estimate "$@" ;;
	forecast) cmd_forecast "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
