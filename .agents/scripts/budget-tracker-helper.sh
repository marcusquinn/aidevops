#!/usr/bin/env bash
# shellcheck disable=SC1091

# Budget Tracker Helper - Budget-aware model routing (t1100)
#
# Two billing strategies:
#   1. Token-billed APIs (Anthropic direct, OpenRouter): Track daily spend per
#      provider, proactively degrade to cheaper tier when approaching budget cap
#      (e.g., 80% of daily opus budget spent -> route remaining to sonnet).
#   2. Subscription APIs (OAuth with periodic allowances): Maximise utilisation
#      within period, prefer subscription providers when allowance is available
#      to avoid token costs, alert when approaching period limit.
#
# Usage: budget-tracker-helper.sh [command] [options]
#
# Commands:
#   record          Record a spend event (tokens used, cost incurred)
#   check           Check budget state for a provider/tier (exit 0=ok, 1=degraded, 2=exhausted)
#   recommend       Recommend best provider for a tier considering budget
#   status          Show current budget state across all providers
#   configure       Set budget limits for a provider
#   reset           Reset daily/period counters
#   burn-rate       Calculate current burn rate and time-to-exhaustion
#   help            Show this help
#
# Options:
#   --json          Output in JSON format
#   --quiet         Suppress informational output
#   --provider X    Filter by provider
#   --tier X        Filter by tier
#
# Integration:
#   - Called by dispatch.sh resolve_task_model() before model selection
#   - Reads pricing from model-registry.db (compare-models-helper.sh MODEL_DATA)
#   - Reads token usage from pattern-tracker via memory-helper.sh
#   - Storage: ~/.aidevops/.agent-workspace/budget-tracker.db
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

readonly BUDGET_DIR="${HOME}/.aidevops/.agent-workspace"
readonly BUDGET_DB="${BUDGET_DIR}/budget-tracker.db"

# Default budget thresholds (can be overridden per-provider via configure)
readonly DEFAULT_DAILY_BUDGET=50.00 # USD per day for token-billed providers
readonly DEFAULT_DEGRADATION_PCT=80 # Degrade at 80% of daily budget
readonly DEFAULT_EXHAUSTION_PCT=95  # Block at 95% of daily budget
readonly DEFAULT_PERIOD_WARN_PCT=85 # Warn at 85% of subscription period usage

# Billing types
readonly BILLING_TOKEN="token"               # Pay-per-token (Anthropic direct, OpenRouter)
readonly BILLING_SUBSCRIPTION="subscription" # Periodic allowance (OAuth, Max plans)

# =============================================================================
# Database Setup
# =============================================================================

init_db() {
	mkdir -p "$BUDGET_DIR" 2>/dev/null || true

	sqlite3 "$BUDGET_DB" "
		PRAGMA journal_mode=WAL;
		PRAGMA busy_timeout=5000;

		-- Provider budget configuration
		CREATE TABLE IF NOT EXISTS provider_budgets (
			provider       TEXT PRIMARY KEY,
			billing_type   TEXT NOT NULL DEFAULT '$BILLING_TOKEN',
			daily_budget   REAL DEFAULT $DEFAULT_DAILY_BUDGET,
			degradation_pct INTEGER DEFAULT $DEFAULT_DEGRADATION_PCT,
			exhaustion_pct INTEGER DEFAULT $DEFAULT_EXHAUSTION_PCT,
			period_type    TEXT DEFAULT 'daily',
			period_budget  REAL DEFAULT 0.0,
			period_start   TEXT DEFAULT '',
			period_end     TEXT DEFAULT '',
			period_warn_pct INTEGER DEFAULT $DEFAULT_PERIOD_WARN_PCT,
			priority       INTEGER DEFAULT 50,
			notes          TEXT DEFAULT '',
			updated_at     TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		);

		-- Spend events (individual API calls)
		CREATE TABLE IF NOT EXISTS spend_events (
			id             INTEGER PRIMARY KEY AUTOINCREMENT,
			provider       TEXT NOT NULL,
			model          TEXT NOT NULL,
			tier           TEXT DEFAULT '',
			task_id        TEXT DEFAULT '',
			input_tokens   INTEGER DEFAULT 0,
			output_tokens  INTEGER DEFAULT 0,
			cost_usd       REAL DEFAULT 0.0,
			recorded_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		);

		-- Daily spend aggregates (materialised for fast lookups)
		CREATE TABLE IF NOT EXISTS daily_spend (
			provider       TEXT NOT NULL,
			date           TEXT NOT NULL,
			total_cost     REAL DEFAULT 0.0,
			total_input    INTEGER DEFAULT 0,
			total_output   INTEGER DEFAULT 0,
			event_count    INTEGER DEFAULT 0,
			updated_at     TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			PRIMARY KEY (provider, date)
		);

		-- Tier-level daily spend (for per-tier budget tracking)
		CREATE TABLE IF NOT EXISTS tier_daily_spend (
			provider       TEXT NOT NULL,
			tier           TEXT NOT NULL,
			date           TEXT NOT NULL,
			total_cost     REAL DEFAULT 0.0,
			event_count    INTEGER DEFAULT 0,
			updated_at     TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			PRIMARY KEY (provider, tier, date)
		);

		-- Subscription period tracking
		CREATE TABLE IF NOT EXISTS subscription_periods (
			provider       TEXT NOT NULL,
			period_start   TEXT NOT NULL,
			period_end     TEXT NOT NULL,
			allowance      REAL DEFAULT 0.0,
			used           REAL DEFAULT 0.0,
			unit           TEXT DEFAULT 'usd',
			updated_at     TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			PRIMARY KEY (provider, period_start)
		);

		-- Budget alerts log
		CREATE TABLE IF NOT EXISTS budget_alerts (
			id             INTEGER PRIMARY KEY AUTOINCREMENT,
			provider       TEXT NOT NULL,
			alert_type     TEXT NOT NULL,
			message        TEXT NOT NULL,
			threshold_pct  INTEGER DEFAULT 0,
			current_pct    INTEGER DEFAULT 0,
			created_at     TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		);

		CREATE INDEX IF NOT EXISTS idx_spend_events_provider_date
			ON spend_events(provider, recorded_at);
		CREATE INDEX IF NOT EXISTS idx_spend_events_task
			ON spend_events(task_id);
		CREATE INDEX IF NOT EXISTS idx_daily_spend_date
			ON daily_spend(date);
		CREATE INDEX IF NOT EXISTS idx_budget_alerts_provider
			ON budget_alerts(provider, created_at);
	" >/dev/null 2>/dev/null || {
		print_error "Failed to initialize budget tracker database"
		return 1
	}
	return 0
}

db_query() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" "$BUDGET_DB" "$query" 2>/dev/null
	return $?
}

db_query_json() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" -json "$BUDGET_DB" "$query" 2>/dev/null
	return $?
}

sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

# =============================================================================
# Pricing Lookup
# =============================================================================
# Resolves input/output price per 1M tokens for a model.
# Sources: 1) model-registry.db, 2) embedded MODEL_DATA from compare-models-helper.sh

get_model_pricing() {
	local model="$1"
	local model_short="${model#*/}"

	# Try model-registry.db first
	local registry_db="${BUDGET_DIR}/model-registry.db"
	if [[ -f "$registry_db" ]]; then
		local pricing
		pricing=$(sqlite3 -cmd ".timeout 5000" "$registry_db" "
			SELECT input_price, output_price FROM models
			WHERE model_id LIKE '%$(sql_escape "$model_short")%'
			AND input_price > 0
			ORDER BY last_seen DESC LIMIT 1;
		" 2>/dev/null) || true
		if [[ -n "$pricing" ]]; then
			echo "$pricing"
			return 0
		fi
	fi

	# Fallback: hardcoded pricing for common models (updated 2026-02)
	case "$model_short" in
	*opus-4*) echo "15.0|75.0" ;;
	*sonnet-4*) echo "3.0|15.0" ;;
	*haiku-4*) echo "0.80|4.0" ;;
	*haiku-3*) echo "0.25|1.25" ;;
	*gpt-4.1*) echo "2.0|8.0" ;;
	*gpt-4.1-mini*) echo "0.40|1.60" ;;
	*o3*) echo "10.0|40.0" ;;
	*o4-mini*) echo "1.10|4.40" ;;
	*gemini-2.5-pro*) echo "1.25|10.0" ;;
	*gemini-2.5-flash*) echo "0.15|0.60" ;;
	*gemini-3-pro*) echo "1.25|10.0" ;;
	*gemini-3-flash*) echo "0.10|0.40" ;;
	*deepseek-r1*) echo "0.55|2.19" ;;
	*deepseek-v3*) echo "0.27|1.10" ;;
	*) echo "3.0|15.0" ;; # Default to sonnet-tier pricing
	esac
	return 0
}

# Calculate cost from token counts and model pricing
calculate_cost() {
	local input_tokens="$1"
	local output_tokens="$2"
	local model="$3"

	local pricing
	pricing=$(get_model_pricing "$model")
	local input_price output_price
	input_price=$(echo "$pricing" | cut -d'|' -f1)
	output_price=$(echo "$pricing" | cut -d'|' -f2)

	# Cost = (input_tokens / 1M * input_price) + (output_tokens / 1M * output_price)
	awk "BEGIN { printf \"%.6f\", ($input_tokens / 1000000.0 * $input_price) + ($output_tokens / 1000000.0 * $output_price) }"
	return 0
}

# =============================================================================
# Provider Classification
# =============================================================================
# Determines billing type for a provider. Override via provider_budgets table.

get_billing_type() {
	local provider="$1"

	# Check configured billing type first
	local configured
	configured=$(db_query "
		SELECT billing_type FROM provider_budgets
		WHERE provider = '$(sql_escape "$provider")';
	") || true
	if [[ -n "$configured" ]]; then
		echo "$configured"
		return 0
	fi

	# Default classification
	case "$provider" in
	anthropic | openrouter | openai | google | groq | deepseek)
		echo "$BILLING_TOKEN"
		;;
	opencode)
		# OpenCode uses OAuth with periodic allowances (Max plan)
		echo "$BILLING_SUBSCRIPTION"
		;;
	*)
		echo "$BILLING_TOKEN"
		;;
	esac
	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Record a spend event
cmd_record() {
	local provider="" model="" tier="" task_id=""
	local input_tokens=0 output_tokens=0 cost_override=""

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
		--tier)
			tier="${2:-}"
			shift 2
			;;
		--task)
			task_id="${2:-}"
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
		--cost)
			cost_override="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$provider" || -z "$model" ]]; then
		print_error "Usage: budget-tracker-helper.sh record --provider X --model Y [--input-tokens N] [--output-tokens N] [--cost N]"
		return 1
	fi

	# Infer provider from model if not specified
	if [[ -z "$provider" && "$model" == *"/"* ]]; then
		provider="${model%%/*}"
	fi

	# Calculate cost if not overridden
	local cost_usd
	if [[ -n "$cost_override" ]]; then
		cost_usd="$cost_override"
	else
		cost_usd=$(calculate_cost "$input_tokens" "$output_tokens" "$model")
	fi

	local today
	today=$(date -u +%Y-%m-%d)

	# Insert spend event
	db_query "
		INSERT INTO spend_events (provider, model, tier, task_id, input_tokens, output_tokens, cost_usd)
		VALUES (
			'$(sql_escape "$provider")',
			'$(sql_escape "$model")',
			'$(sql_escape "$tier")',
			'$(sql_escape "$task_id")',
			$input_tokens,
			$output_tokens,
			$cost_usd
		);
	"

	# Update daily aggregate
	db_query "
		INSERT INTO daily_spend (provider, date, total_cost, total_input, total_output, event_count)
		VALUES (
			'$(sql_escape "$provider")',
			'$today',
			$cost_usd,
			$input_tokens,
			$output_tokens,
			1
		)
		ON CONFLICT(provider, date) DO UPDATE SET
			total_cost = total_cost + $cost_usd,
			total_input = total_input + $input_tokens,
			total_output = total_output + $output_tokens,
			event_count = event_count + 1,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
	"

	# Update tier-level daily aggregate
	if [[ -n "$tier" ]]; then
		db_query "
			INSERT INTO tier_daily_spend (provider, tier, date, total_cost, event_count)
			VALUES (
				'$(sql_escape "$provider")',
				'$(sql_escape "$tier")',
				'$today',
				$cost_usd,
				1
			)
			ON CONFLICT(provider, tier, date) DO UPDATE SET
				total_cost = total_cost + $cost_usd,
				event_count = event_count + 1,
				updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
		"
	fi

	# Update subscription period if applicable
	local billing_type
	billing_type=$(get_billing_type "$provider")
	if [[ "$billing_type" == "$BILLING_SUBSCRIPTION" ]]; then
		_update_subscription_usage "$provider" "$cost_usd"
	fi

	# Check if we need to fire alerts
	_check_budget_alerts "$provider"

	return 0
}

# Check budget state for a provider/tier
# Exit codes: 0=within budget, 1=degraded (should use cheaper tier), 2=exhausted
cmd_check() {
	local provider="" tier="" quiet=false json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="${2:-}"
			shift 2
			;;
		--tier)
			tier="${2:-}"
			shift 2
			;;
		--quiet)
			quiet=true
			shift
			;;
		--json)
			json_flag=true
			shift
			;;
		*)
			# First positional arg is provider
			if [[ -z "$provider" ]]; then
				provider="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$provider" ]]; then
		print_error "Usage: budget-tracker-helper.sh check <provider> [--tier X]"
		return 1
	fi

	local billing_type
	billing_type=$(get_billing_type "$provider")

	if [[ "$billing_type" == "$BILLING_SUBSCRIPTION" ]]; then
		_check_subscription_budget "$provider" "$quiet" "$json_flag"
		return $?
	fi

	# Token-billed: check daily spend against budget
	local today
	today=$(date -u +%Y-%m-%d)

	local daily_budget degradation_pct exhaustion_pct
	daily_budget=$(db_query "
		SELECT COALESCE(daily_budget, $DEFAULT_DAILY_BUDGET) FROM provider_budgets
		WHERE provider = '$(sql_escape "$provider")';
	") || true
	daily_budget="${daily_budget:-$DEFAULT_DAILY_BUDGET}"

	degradation_pct=$(db_query "
		SELECT COALESCE(degradation_pct, $DEFAULT_DEGRADATION_PCT) FROM provider_budgets
		WHERE provider = '$(sql_escape "$provider")';
	") || true
	degradation_pct="${degradation_pct:-$DEFAULT_DEGRADATION_PCT}"

	exhaustion_pct=$(db_query "
		SELECT COALESCE(exhaustion_pct, $DEFAULT_EXHAUSTION_PCT) FROM provider_budgets
		WHERE provider = '$(sql_escape "$provider")';
	") || true
	exhaustion_pct="${exhaustion_pct:-$DEFAULT_EXHAUSTION_PCT}"

	local today_spend
	today_spend=$(db_query "
		SELECT COALESCE(total_cost, 0) FROM daily_spend
		WHERE provider = '$(sql_escape "$provider")' AND date = '$today';
	") || true
	today_spend="${today_spend:-0}"

	# Calculate percentage used
	local pct_used
	pct_used=$(awk "BEGIN { if ($daily_budget > 0) printf \"%d\", ($today_spend / $daily_budget * 100); else print 0 }")

	local status="ok"
	local exit_code=0
	local recommended_action=""

	if [[ "$pct_used" -ge "$exhaustion_pct" ]]; then
		status="exhausted"
		exit_code=2
		recommended_action="block_dispatch"
	elif [[ "$pct_used" -ge "$degradation_pct" ]]; then
		status="degraded"
		exit_code=1
		recommended_action="use_cheaper_tier"
	fi

	if [[ "$json_flag" == "true" ]]; then
		printf '{"provider":"%s","billing_type":"%s","status":"%s","daily_budget":%.2f,"today_spend":%.2f,"pct_used":%d,"degradation_pct":%d,"exhaustion_pct":%d,"recommended_action":"%s"}\n' \
			"$provider" "$billing_type" "$status" "$daily_budget" "$today_spend" "$pct_used" "$degradation_pct" "$exhaustion_pct" "$recommended_action"
	elif [[ "$quiet" != "true" ]]; then
		echo "$provider: $status (${pct_used}% of \$${daily_budget}/day used, \$${today_spend} spent today)"
		if [[ -n "$recommended_action" ]]; then
			echo "  Action: $recommended_action"
		fi
	fi

	return "$exit_code"
}

# Recommend the best provider for a tier considering budget constraints
cmd_recommend() {
	local tier="" quiet=false json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tier)
			tier="${2:-}"
			shift 2
			;;
		--quiet)
			quiet=true
			shift
			;;
		--json)
			json_flag=true
			shift
			;;
		*)
			if [[ -z "$tier" ]]; then
				tier="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$tier" ]]; then
		print_error "Usage: budget-tracker-helper.sh recommend <tier>"
		return 1
	fi

	local today
	today=$(date -u +%Y-%m-%d)

	# Strategy: prefer subscription providers with available allowance,
	# then token-billed providers within budget, then degraded alternatives

	# 1. Check subscription providers first (free if within allowance)
	local sub_providers
	sub_providers=$(db_query "
		SELECT provider FROM provider_budgets
		WHERE billing_type = '$BILLING_SUBSCRIPTION'
		ORDER BY priority ASC;
	") || true

	local provider
	while IFS= read -r provider; do
		[[ -z "$provider" ]] && continue
		local sub_exit=0
		_check_subscription_budget "$provider" "true" "false" || sub_exit=$?
		if [[ "$sub_exit" -eq 0 ]]; then
			# Subscription provider has allowance — prefer it
			if [[ "$json_flag" == "true" ]]; then
				printf '{"recommended_provider":"%s","reason":"subscription_allowance_available","tier":"%s","cost":"included"}\n' \
					"$provider" "$tier"
			elif [[ "$quiet" != "true" ]]; then
				echo "$provider (subscription allowance available — zero marginal cost)"
			else
				echo "$provider"
			fi
			return 0
		fi
	done <<<"$sub_providers"

	# 2. Check token-billed providers within budget
	local token_providers
	token_providers=$(db_query "
		SELECT provider FROM provider_budgets
		WHERE billing_type = '$BILLING_TOKEN'
		ORDER BY priority ASC;
	") || true

	# If no configured providers, use defaults
	if [[ -z "$token_providers" ]]; then
		token_providers="anthropic
openai
google
openrouter"
	fi

	while IFS= read -r provider; do
		[[ -z "$provider" ]] && continue
		local check_exit=0
		cmd_check "$provider" --quiet || check_exit=$?
		if [[ "$check_exit" -eq 0 ]]; then
			if [[ "$json_flag" == "true" ]]; then
				printf '{"recommended_provider":"%s","reason":"within_budget","tier":"%s"}\n' \
					"$provider" "$tier"
			elif [[ "$quiet" != "true" ]]; then
				echo "$provider (within daily budget)"
			else
				echo "$provider"
			fi
			return 0
		fi
	done <<<"$token_providers"

	# 3. All providers degraded or exhausted — recommend cheapest available
	local cheapest_provider="anthropic"
	if [[ "$json_flag" == "true" ]]; then
		printf '{"recommended_provider":"%s","reason":"all_budgets_exceeded","tier":"%s","degraded":true}\n' \
			"$cheapest_provider" "$tier"
	elif [[ "$quiet" != "true" ]]; then
		print_warning "All provider budgets exceeded — defaulting to $cheapest_provider with degraded tier"
	else
		echo "$cheapest_provider"
	fi
	return 1
}

# Show current budget status across all providers
cmd_status() {
	local json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		*)
			shift
			;;
		esac
	done

	if [[ ! -f "$BUDGET_DB" ]]; then
		print_warning "No budget data. Run 'budget-tracker-helper.sh configure' first."
		return 0
	fi

	local today
	today=$(date -u +%Y-%m-%d)

	if [[ "$json_flag" == "true" ]]; then
		echo "{"
		echo "  \"date\": \"$today\","
		echo "  \"providers\":"
		db_query_json "
			SELECT
				pb.provider,
				pb.billing_type,
				pb.daily_budget,
				pb.degradation_pct,
				pb.exhaustion_pct,
				COALESCE(ds.total_cost, 0) as today_spend,
				COALESCE(ds.event_count, 0) as today_events,
				COALESCE(ds.total_input, 0) as today_input_tokens,
				COALESCE(ds.total_output, 0) as today_output_tokens,
				CASE WHEN pb.daily_budget > 0
					THEN CAST(COALESCE(ds.total_cost, 0) / pb.daily_budget * 100 AS INTEGER)
					ELSE 0
				END as pct_used
			FROM provider_budgets pb
			LEFT JOIN daily_spend ds ON pb.provider = ds.provider AND ds.date = '$today'
			ORDER BY pb.provider;
		"
		echo "}"
		return 0
	fi

	echo ""
	echo "Budget Tracker Status"
	echo "====================="
	echo "Date: $today"
	echo ""

	# Token-billed providers
	echo "Token-Billed Providers:"
	echo ""
	printf "  %-12s %-10s %-10s %-8s %-8s %-8s %-10s\n" \
		"Provider" "Budget" "Spent" "Used%" "Degrade" "Exhaust" "Status"
	printf "  %-12s %-10s %-10s %-8s %-8s %-8s %-10s\n" \
		"--------" "------" "-----" "-----" "-------" "-------" "------"

	db_query "
		SELECT
			pb.provider,
			pb.daily_budget,
			COALESCE(ds.total_cost, 0),
			pb.degradation_pct,
			pb.exhaustion_pct
		FROM provider_budgets pb
		LEFT JOIN daily_spend ds ON pb.provider = ds.provider AND ds.date = '$today'
		WHERE pb.billing_type = '$BILLING_TOKEN'
		ORDER BY pb.provider;
	" | while IFS='|' read -r prov budget spent deg_pct exh_pct; do
		local pct_used
		pct_used=$(awk "BEGIN { if ($budget > 0) printf \"%d\", ($spent / $budget * 100); else print 0 }")
		local status="ok"
		if [[ "$pct_used" -ge "$exh_pct" ]]; then
			status="EXHAUSTED"
		elif [[ "$pct_used" -ge "$deg_pct" ]]; then
			status="DEGRADED"
		fi
		printf "  %-12s \$%-9s \$%-9s %-8s %-8s %-8s %-10s\n" \
			"$prov" "$budget" "$spent" "${pct_used}%" "${deg_pct}%" "${exh_pct}%" "$status"
	done

	echo ""

	# Subscription providers
	local sub_count
	sub_count=$(db_query "SELECT COUNT(*) FROM provider_budgets WHERE billing_type = '$BILLING_SUBSCRIPTION';") || sub_count=0
	if [[ "$sub_count" -gt 0 ]]; then
		echo "Subscription Providers:"
		echo ""
		printf "  %-12s %-12s %-12s %-8s %-20s %-10s\n" \
			"Provider" "Allowance" "Used" "Used%" "Period End" "Status"
		printf "  %-12s %-12s %-12s %-8s %-20s %-10s\n" \
			"--------" "---------" "----" "-----" "----------" "------"

		db_query "
			SELECT
				sp.provider,
				sp.allowance,
				sp.used,
				sp.period_end,
				sp.unit
			FROM subscription_periods sp
			WHERE sp.period_end >= '$today'
			ORDER BY sp.provider;
		" | while IFS='|' read -r prov allowance used period_end unit; do
			local pct_used
			pct_used=$(awk "BEGIN { if ($allowance > 0) printf \"%d\", ($used / $allowance * 100); else print 0 }")
			local status="ok"
			if [[ "$pct_used" -ge 95 ]]; then
				status="EXHAUSTED"
			elif [[ "$pct_used" -ge "$DEFAULT_PERIOD_WARN_PCT" ]]; then
				status="WARNING"
			fi
			printf "  %-12s %-12s %-12s %-8s %-20s %-10s\n" \
				"$prov" "${allowance} ${unit}" "${used} ${unit}" "${pct_used}%" "$period_end" "$status"
		done
		echo ""
	fi

	# Recent spend by tier (last 7 days)
	echo "Spend by Tier (last 7 days):"
	echo ""
	printf "  %-8s %-12s %-10s %-8s\n" "Tier" "Provider" "Cost" "Events"
	printf "  %-8s %-12s %-10s %-8s\n" "----" "--------" "----" "------"

	db_query "
		SELECT tier, provider, SUM(total_cost), SUM(event_count)
		FROM tier_daily_spend
		WHERE date >= date('now', '-7 days')
		AND tier != ''
		GROUP BY tier, provider
		ORDER BY SUM(total_cost) DESC;
	" | while IFS='|' read -r t_tier t_prov t_cost t_events; do
		printf "  %-8s %-12s \$%-9s %-8s\n" "$t_tier" "$t_prov" "$t_cost" "$t_events"
	done

	echo ""

	# Recent alerts
	local alert_count
	alert_count=$(db_query "SELECT COUNT(*) FROM budget_alerts WHERE created_at >= datetime('now', '-24 hours');") || alert_count=0
	if [[ "$alert_count" -gt 0 ]]; then
		echo "Recent Alerts (24h):"
		echo ""
		db_query "
			SELECT created_at, provider, alert_type, message
			FROM budget_alerts
			WHERE created_at >= datetime('now', '-24 hours')
			ORDER BY created_at DESC
			LIMIT 10;
		" | while IFS='|' read -r ts prov atype msg; do
			echo "  $ts [$prov] $atype: $msg"
		done
		echo ""
	fi

	return 0
}

# Configure budget limits for a provider
cmd_configure() {
	local provider="" billing_type="" daily_budget="" degradation_pct=""
	local exhaustion_pct="" priority="" period_budget="" period_warn_pct=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="${2:-}"
			shift 2
			;;
		--billing-type)
			billing_type="${2:-}"
			shift 2
			;;
		--daily-budget)
			daily_budget="${2:-}"
			shift 2
			;;
		--degradation-pct)
			degradation_pct="${2:-}"
			shift 2
			;;
		--exhaustion-pct)
			exhaustion_pct="${2:-}"
			shift 2
			;;
		--priority)
			priority="${2:-}"
			shift 2
			;;
		--period-budget)
			period_budget="${2:-}"
			shift 2
			;;
		--period-warn-pct)
			period_warn_pct="${2:-}"
			shift 2
			;;
		*)
			if [[ -z "$provider" ]]; then
				provider="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$provider" ]]; then
		print_error "Usage: budget-tracker-helper.sh configure <provider> [--billing-type token|subscription] [--daily-budget N] ..."
		return 1
	fi

	# Build upsert with only specified fields
	local set_clauses=""
	[[ -n "$billing_type" ]] && set_clauses="${set_clauses}, billing_type = '$(sql_escape "$billing_type")'"
	[[ -n "$daily_budget" ]] && set_clauses="${set_clauses}, daily_budget = $daily_budget"
	[[ -n "$degradation_pct" ]] && set_clauses="${set_clauses}, degradation_pct = $degradation_pct"
	[[ -n "$exhaustion_pct" ]] && set_clauses="${set_clauses}, exhaustion_pct = $exhaustion_pct"
	[[ -n "$priority" ]] && set_clauses="${set_clauses}, priority = $priority"
	[[ -n "$period_budget" ]] && set_clauses="${set_clauses}, period_budget = $period_budget"
	[[ -n "$period_warn_pct" ]] && set_clauses="${set_clauses}, period_warn_pct = $period_warn_pct"

	# Remove leading comma
	set_clauses="${set_clauses#, }"

	if [[ -z "$set_clauses" ]]; then
		# Insert with defaults only
		db_query "
			INSERT INTO provider_budgets (provider)
			VALUES ('$(sql_escape "$provider")')
			ON CONFLICT(provider) DO NOTHING;
		"
	else
		db_query "
			INSERT INTO provider_budgets (provider, ${set_clauses//= */})
			VALUES ('$(sql_escape "$provider")')
			ON CONFLICT(provider) DO UPDATE SET
				$set_clauses,
				updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
		" 2>/dev/null || {
			# Simpler approach: upsert with explicit columns
			db_query "
				INSERT OR REPLACE INTO provider_budgets (provider)
				VALUES ('$(sql_escape "$provider")');
			"
			if [[ -n "$set_clauses" ]]; then
				db_query "
					UPDATE provider_budgets SET
						$set_clauses,
						updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
					WHERE provider = '$(sql_escape "$provider")';
				"
			fi
		}
	fi

	print_success "Configured budget for $provider"
	return 0
}

# Configure a subscription period
cmd_configure_period() {
	local provider="" period_start="" period_end="" allowance="" unit="usd"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="${2:-}"
			shift 2
			;;
		--start)
			period_start="${2:-}"
			shift 2
			;;
		--end)
			period_end="${2:-}"
			shift 2
			;;
		--allowance)
			allowance="${2:-}"
			shift 2
			;;
		--unit)
			unit="${2:-}"
			shift 2
			;;
		*)
			if [[ -z "$provider" ]]; then
				provider="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$provider" || -z "$period_start" || -z "$period_end" || -z "$allowance" ]]; then
		print_error "Usage: budget-tracker-helper.sh configure-period <provider> --start YYYY-MM-DD --end YYYY-MM-DD --allowance N [--unit usd|requests]"
		return 1
	fi

	db_query "
		INSERT INTO subscription_periods (provider, period_start, period_end, allowance, unit)
		VALUES (
			'$(sql_escape "$provider")',
			'$(sql_escape "$period_start")',
			'$(sql_escape "$period_end")',
			$allowance,
			'$(sql_escape "$unit")'
		)
		ON CONFLICT(provider, period_start) DO UPDATE SET
			period_end = excluded.period_end,
			allowance = excluded.allowance,
			unit = excluded.unit,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
	"

	print_success "Configured subscription period for $provider: $allowance $unit ($period_start to $period_end)"
	return 0
}

# Reset daily counters (called at midnight or manually)
cmd_reset() {
	local provider="${1:-}"

	if [[ -n "$provider" ]]; then
		local today
		today=$(date -u +%Y-%m-%d)
		db_query "
			DELETE FROM daily_spend WHERE provider = '$(sql_escape "$provider")' AND date = '$today';
			DELETE FROM tier_daily_spend WHERE provider = '$(sql_escape "$provider")' AND date = '$today';
		"
		print_info "Reset daily counters for $provider"
	else
		print_info "Daily counters auto-reset by date partitioning — no manual reset needed"
	fi
	return 0
}

# Calculate burn rate and time-to-exhaustion
cmd_burn_rate() {
	local provider="" json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="${2:-}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		*)
			if [[ -z "$provider" ]]; then
				provider="$1"
			fi
			shift
			;;
		esac
	done

	local today
	today=$(date -u +%Y-%m-%d)

	# Get today's spend and hourly rate
	local today_spend today_events
	if [[ -n "$provider" ]]; then
		today_spend=$(db_query "
			SELECT COALESCE(total_cost, 0) FROM daily_spend
			WHERE provider = '$(sql_escape "$provider")' AND date = '$today';
		") || today_spend=0
		today_events=$(db_query "
			SELECT COALESCE(event_count, 0) FROM daily_spend
			WHERE provider = '$(sql_escape "$provider")' AND date = '$today';
		") || today_events=0
	else
		today_spend=$(db_query "
			SELECT COALESCE(SUM(total_cost), 0) FROM daily_spend WHERE date = '$today';
		") || today_spend=0
		today_events=$(db_query "
			SELECT COALESCE(SUM(event_count), 0) FROM daily_spend WHERE date = '$today';
		") || today_events=0
	fi

	# Calculate hours elapsed today (UTC)
	local hours_elapsed
	hours_elapsed=$(date -u +%H)
	hours_elapsed=$((hours_elapsed == 0 ? 1 : hours_elapsed))

	local hourly_rate
	hourly_rate=$(awk "BEGIN { printf \"%.2f\", $today_spend / $hours_elapsed }")

	# Get daily budget
	local daily_budget
	if [[ -n "$provider" ]]; then
		daily_budget=$(db_query "
			SELECT COALESCE(daily_budget, $DEFAULT_DAILY_BUDGET) FROM provider_budgets
			WHERE provider = '$(sql_escape "$provider")';
		") || daily_budget="$DEFAULT_DAILY_BUDGET"
	else
		daily_budget=$(db_query "
			SELECT COALESCE(SUM(daily_budget), $DEFAULT_DAILY_BUDGET) FROM provider_budgets;
		") || daily_budget="$DEFAULT_DAILY_BUDGET"
	fi
	daily_budget="${daily_budget:-$DEFAULT_DAILY_BUDGET}"

	local remaining
	remaining=$(awk "BEGIN { printf \"%.2f\", $daily_budget - $today_spend }")

	local hours_to_exhaustion="inf"
	if awk "BEGIN { exit !($hourly_rate > 0.01) }"; then
		hours_to_exhaustion=$(awk "BEGIN { printf \"%.1f\", $remaining / $hourly_rate }")
	fi

	# 7-day average for comparison
	local avg_daily_spend
	if [[ -n "$provider" ]]; then
		avg_daily_spend=$(db_query "
			SELECT COALESCE(AVG(total_cost), 0) FROM daily_spend
			WHERE provider = '$(sql_escape "$provider")'
			AND date >= date('now', '-7 days') AND date < '$today';
		") || avg_daily_spend=0
	else
		avg_daily_spend=$(db_query "
			SELECT COALESCE(SUM(total_cost) / 7.0, 0) FROM daily_spend
			WHERE date >= date('now', '-7 days') AND date < '$today';
		") || avg_daily_spend=0
	fi

	if [[ "$json_flag" == "true" ]]; then
		printf '{"provider":"%s","today_spend":%.2f,"hourly_rate":%.2f,"daily_budget":%.2f,"remaining":%.2f,"hours_to_exhaustion":"%s","avg_daily_spend_7d":%.2f,"today_events":%d}\n' \
			"${provider:-all}" "$today_spend" "$hourly_rate" "$daily_budget" "$remaining" "$hours_to_exhaustion" "$avg_daily_spend" "$today_events"
	else
		echo ""
		echo "Burn Rate: ${provider:-all providers}"
		echo "========================="
		echo ""
		echo "  Today's spend:       \$${today_spend}"
		echo "  Hourly rate:         \$${hourly_rate}/hr"
		echo "  Daily budget:        \$${daily_budget}"
		echo "  Remaining:           \$${remaining}"
		echo "  Hours to exhaustion: ${hours_to_exhaustion}h"
		echo "  7-day avg daily:     \$${avg_daily_spend}"
		echo "  Events today:        ${today_events}"
		echo ""
	fi

	return 0
}

# =============================================================================
# Internal Helpers
# =============================================================================

_check_subscription_budget() {
	local provider="$1"
	local quiet="${2:-false}"
	local json_flag="${3:-false}"

	local today
	today=$(date -u +%Y-%m-%d)

	local period_row
	period_row=$(db_query "
		SELECT allowance, used, period_end, unit FROM subscription_periods
		WHERE provider = '$(sql_escape "$provider")'
		AND period_end >= '$today'
		ORDER BY period_start DESC LIMIT 1;
	") || true

	if [[ -z "$period_row" ]]; then
		# No active subscription period — treat as unavailable
		[[ "$quiet" != "true" ]] && print_warning "$provider: no active subscription period"
		return 2
	fi

	local allowance used period_end unit
	IFS='|' read -r allowance used period_end unit <<<"$period_row"

	local pct_used
	pct_used=$(awk "BEGIN { if ($allowance > 0) printf \"%d\", ($used / $allowance * 100); else print 0 }")

	local warn_pct
	warn_pct=$(db_query "
		SELECT COALESCE(period_warn_pct, $DEFAULT_PERIOD_WARN_PCT) FROM provider_budgets
		WHERE provider = '$(sql_escape "$provider")';
	") || warn_pct="$DEFAULT_PERIOD_WARN_PCT"
	warn_pct="${warn_pct:-$DEFAULT_PERIOD_WARN_PCT}"

	local status="ok"
	local exit_code=0
	if [[ "$pct_used" -ge 95 ]]; then
		status="exhausted"
		exit_code=2
	elif [[ "$pct_used" -ge "$warn_pct" ]]; then
		status="warning"
		exit_code=1
	fi

	if [[ "$json_flag" == "true" ]]; then
		printf '{"provider":"%s","billing_type":"subscription","status":"%s","allowance":%.2f,"used":%.2f,"pct_used":%d,"period_end":"%s","unit":"%s"}\n' \
			"$provider" "$status" "$allowance" "$used" "$pct_used" "$period_end" "$unit"
	elif [[ "$quiet" != "true" ]]; then
		echo "$provider: $status (${pct_used}% of ${allowance} ${unit} used, period ends $period_end)"
	fi

	return "$exit_code"
}

_update_subscription_usage() {
	local provider="$1"
	local cost="$2"

	local today
	today=$(date -u +%Y-%m-%d)

	db_query "
		UPDATE subscription_periods SET
			used = used + $cost,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE provider = '$(sql_escape "$provider")'
		AND period_end >= '$today'
		AND period_start <= '$today';
	" || true
	return 0
}

_check_budget_alerts() {
	local provider="$1"

	local billing_type
	billing_type=$(get_billing_type "$provider")

	local today
	today=$(date -u +%Y-%m-%d)

	if [[ "$billing_type" == "$BILLING_TOKEN" ]]; then
		local daily_budget today_spend degradation_pct exhaustion_pct
		daily_budget=$(db_query "
			SELECT COALESCE(daily_budget, $DEFAULT_DAILY_BUDGET) FROM provider_budgets
			WHERE provider = '$(sql_escape "$provider")';
		") || daily_budget="$DEFAULT_DAILY_BUDGET"
		daily_budget="${daily_budget:-$DEFAULT_DAILY_BUDGET}"

		today_spend=$(db_query "
			SELECT COALESCE(total_cost, 0) FROM daily_spend
			WHERE provider = '$(sql_escape "$provider")' AND date = '$today';
		") || today_spend=0
		today_spend="${today_spend:-0}"

		degradation_pct=$(db_query "
			SELECT COALESCE(degradation_pct, $DEFAULT_DEGRADATION_PCT) FROM provider_budgets
			WHERE provider = '$(sql_escape "$provider")';
		") || degradation_pct="$DEFAULT_DEGRADATION_PCT"
		degradation_pct="${degradation_pct:-$DEFAULT_DEGRADATION_PCT}"

		exhaustion_pct=$(db_query "
			SELECT COALESCE(exhaustion_pct, $DEFAULT_EXHAUSTION_PCT) FROM provider_budgets
			WHERE provider = '$(sql_escape "$provider")';
		") || exhaustion_pct="$DEFAULT_EXHAUSTION_PCT"
		exhaustion_pct="${exhaustion_pct:-$DEFAULT_EXHAUSTION_PCT}"

		local pct_used
		pct_used=$(awk "BEGIN { if ($daily_budget > 0) printf \"%d\", ($today_spend / $daily_budget * 100); else print 0 }")

		# Check if we already alerted at this level today
		local already_alerted
		already_alerted=$(db_query "
			SELECT COUNT(*) FROM budget_alerts
			WHERE provider = '$(sql_escape "$provider")'
			AND threshold_pct = $pct_used
			AND created_at >= datetime('now', '-1 hour');
		") || already_alerted=0

		if [[ "$already_alerted" -eq 0 ]]; then
			if [[ "$pct_used" -ge "$exhaustion_pct" ]]; then
				db_query "
					INSERT INTO budget_alerts (provider, alert_type, message, threshold_pct, current_pct)
					VALUES ('$(sql_escape "$provider")', 'exhaustion',
						'Daily budget exhausted: \$${today_spend}/\$${daily_budget} (${pct_used}%)',
						$exhaustion_pct, $pct_used);
				"
				print_warning "BUDGET ALERT: $provider daily budget exhausted (${pct_used}%)"
			elif [[ "$pct_used" -ge "$degradation_pct" ]]; then
				db_query "
					INSERT INTO budget_alerts (provider, alert_type, message, threshold_pct, current_pct)
					VALUES ('$(sql_escape "$provider")', 'degradation',
						'Approaching daily budget: \$${today_spend}/\$${daily_budget} (${pct_used}%)',
						$degradation_pct, $pct_used);
				"
				print_warning "BUDGET ALERT: $provider approaching daily budget (${pct_used}%)"
			fi
		fi
	fi
	return 0
}

# Prune old spend events (keep last 30 days)
_prune_old_data() {
	db_query "
		DELETE FROM spend_events WHERE recorded_at < datetime('now', '-30 days');
		DELETE FROM daily_spend WHERE date < date('now', '-30 days');
		DELETE FROM tier_daily_spend WHERE date < date('now', '-30 days');
		DELETE FROM budget_alerts WHERE created_at < datetime('now', '-7 days');
		DELETE FROM subscription_periods WHERE period_end < date('now', '-30 days');
	" || true
	return 0
}

# =============================================================================
# Dispatch Integration API
# =============================================================================
# These functions are designed to be called from dispatch.sh

# Check if a tier should be degraded for a provider based on budget state.
# Returns: the tier to actually use (may be downgraded).
# Called by dispatch.sh resolve_task_model() before final model resolution.
budget_check_tier() {
	local provider="$1"
	local requested_tier="$2"

	# Quick check: if DB doesn't exist, no budget tracking configured
	if [[ ! -f "$BUDGET_DB" ]]; then
		echo "$requested_tier"
		return 0
	fi

	local check_exit=0
	cmd_check "$provider" --quiet || check_exit=$?

	case "$check_exit" in
	0)
		# Within budget — use requested tier
		echo "$requested_tier"
		;;
	1)
		# Degraded — downgrade expensive tiers
		case "$requested_tier" in
		opus | coding)
			echo "sonnet"
			;;
		sonnet)
			echo "sonnet" # Already at sonnet, don't degrade further for code tasks
			;;
		pro)
			echo "sonnet"
			;;
		*)
			echo "$requested_tier"
			;;
		esac
		;;
	2)
		# Exhausted — use cheapest viable tier
		case "$requested_tier" in
		opus | coding | pro | sonnet)
			echo "haiku"
			;;
		*)
			echo "$requested_tier"
			;;
		esac
		;;
	*)
		echo "$requested_tier"
		;;
	esac
	return 0
}

# Get the preferred provider for a tier, considering budget and subscription state.
# Returns: provider name on stdout, or empty if no preference.
budget_preferred_provider() {
	local tier="$1"

	if [[ ! -f "$BUDGET_DB" ]]; then
		echo ""
		return 0
	fi

	cmd_recommend "$tier" --quiet 2>/dev/null || echo ""
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	echo ""
	echo "Budget Tracker Helper - Budget-aware model routing (t1100)"
	echo "=========================================================="
	echo ""
	echo "Usage: budget-tracker-helper.sh [command] [options]"
	echo ""
	echo "Commands:"
	echo "  record              Record a spend event"
	echo "  check <provider>    Check budget state (exit 0=ok, 1=degraded, 2=exhausted)"
	echo "  recommend <tier>    Recommend best provider for tier considering budget"
	echo "  status              Show budget status across all providers"
	echo "  configure <prov>    Set budget limits for a provider"
	echo "  configure-period    Set subscription period for a provider"
	echo "  reset [provider]    Reset daily counters"
	echo "  burn-rate [prov]    Calculate burn rate and time-to-exhaustion"
	echo "  help                Show this help"
	echo ""
	echo "Record options:"
	echo "  --provider X        Provider name (anthropic, openai, etc.)"
	echo "  --model X           Model ID (anthropic/claude-opus-4-6)"
	echo "  --tier X            Tier name (opus, sonnet, haiku)"
	echo "  --task X            Task ID for attribution"
	echo "  --input-tokens N    Input token count"
	echo "  --output-tokens N   Output token count"
	echo "  --cost N            Override calculated cost (USD)"
	echo ""
	echo "Configure options:"
	echo "  --billing-type X    token or subscription"
	echo "  --daily-budget N    Daily budget in USD (token-billed)"
	echo "  --degradation-pct N Degrade tier at N% of budget (default: 80)"
	echo "  --exhaustion-pct N  Block at N% of budget (default: 95)"
	echo "  --priority N        Provider priority (lower = preferred)"
	echo ""
	echo "Configure-period options:"
	echo "  --start YYYY-MM-DD  Period start date"
	echo "  --end YYYY-MM-DD    Period end date"
	echo "  --allowance N       Period allowance amount"
	echo "  --unit X            Unit: usd or requests (default: usd)"
	echo ""
	echo "Examples:"
	echo "  # Configure Anthropic with \$50/day budget"
	echo "  budget-tracker-helper.sh configure anthropic --billing-type token --daily-budget 50"
	echo ""
	echo "  # Configure OpenCode as subscription"
	echo "  budget-tracker-helper.sh configure opencode --billing-type subscription"
	echo "  budget-tracker-helper.sh configure-period opencode --start 2026-02-01 --end 2026-03-01 --allowance 200"
	echo ""
	echo "  # Record a spend event"
	echo "  budget-tracker-helper.sh record --provider anthropic --model anthropic/claude-opus-4-6 --tier opus --input-tokens 50000 --output-tokens 10000"
	echo ""
	echo "  # Check if provider is within budget"
	echo "  budget-tracker-helper.sh check anthropic"
	echo ""
	echo "  # Get recommended provider for opus tier"
	echo "  budget-tracker-helper.sh recommend opus"
	echo ""
	echo "  # Show burn rate"
	echo "  budget-tracker-helper.sh burn-rate anthropic"
	echo ""
	echo "Dispatch integration:"
	echo "  # In dispatch.sh, before model resolution:"
	echo "  adjusted_tier=\$(budget-tracker-helper.sh budget-check-tier anthropic opus)"
	echo "  preferred=\$(budget-tracker-helper.sh budget-preferred-provider opus)"
	echo ""
	echo "Storage: $BUDGET_DB"
	echo ""
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Initialize DB for all commands except help
	if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
		init_db || return 1
	fi

	case "$command" in
	record)
		cmd_record "$@"
		;;
	check)
		cmd_check "$@"
		;;
	recommend)
		cmd_recommend "$@"
		;;
	status)
		cmd_status "$@"
		;;
	configure)
		cmd_configure "$@"
		;;
	configure-period)
		cmd_configure_period "$@"
		;;
	reset)
		cmd_reset "$@"
		;;
	burn-rate | burnrate | burn_rate)
		cmd_burn_rate "$@"
		;;
	budget-check-tier | budget_check_tier)
		budget_check_tier "$@"
		;;
	budget-preferred-provider | budget_preferred_provider)
		budget_preferred_provider "$@"
		;;
	prune)
		_prune_old_data
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
