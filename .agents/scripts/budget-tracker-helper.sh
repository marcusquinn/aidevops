#!/usr/bin/env bash
# shellcheck disable=SC1091
# Budget Tracker Helper - Append-only cost log (t1337.3)
# Appends spend events to a TSV file. AI reads the log to decide model routing.
# Commands: record, status, burn-rate, help
# Log: ~/.aidevops/.agent-workspace/cost-log.tsv

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

readonly BUDGET_DIR="${HOME}/.aidevops/.agent-workspace"
readonly COST_LOG="${BUDGET_DIR}/cost-log.tsv"
readonly TSV_HEADER="timestamp\tprovider\tmodel\ttier\ttask_id\tinput_tokens\toutput_tokens\tcost_usd"

init_cost_log() {
	mkdir -p "$BUDGET_DIR" 2>/dev/null || true
	if [[ ! -f "$COST_LOG" ]]; then
		printf '%b\n' "$TSV_HEADER" >"$COST_LOG"
	fi
	return 0
}

# Pricing: input|output per 1M tokens
get_model_pricing() {
	local model="$1"
	local model_short="${model#*/}"
	case "$model_short" in
	*opus-4*) echo "15.0|75.0" ;;
	*sonnet-4*) echo "3.0|15.0" ;;
	*haiku-4*) echo "0.80|4.0" ;;
	*haiku-3*) echo "0.25|1.25" ;;
	*gpt-4.1-mini*) echo "0.40|1.60" ;;
	*gpt-4.1*) echo "2.0|8.0" ;;
	*o3*) echo "10.0|40.0" ;;
	*o4-mini*) echo "1.10|4.40" ;;
	*gemini-2.5-pro*) echo "1.25|10.0" ;;
	*gemini-2.5-flash*) echo "0.15|0.60" ;;
	*gemini-3-pro*) echo "1.25|10.0" ;;
	*gemini-3-flash*) echo "0.10|0.40" ;;
	*deepseek-r1*) echo "0.55|2.19" ;;
	*deepseek-v3*) echo "0.27|1.10" ;;
	*) echo "3.0|15.0" ;;
	esac
	return 0
}

calculate_cost() {
	local input_tokens="$1"
	local output_tokens="$2"
	local model="$3"

	local pricing
	pricing=$(get_model_pricing "$model")
	local input_price output_price
	input_price=$(echo "$pricing" | cut -d'|' -f1)
	output_price=$(echo "$pricing" | cut -d'|' -f2)

	awk "BEGIN { printf \"%.6f\", ($input_tokens / 1000000.0 * $input_price) + ($output_tokens / 1000000.0 * $output_price) }"
	return 0
}

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
		--requested-tier | --actual-tier)
			# Accepted for backward compatibility, ignored
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

	local cost_usd
	if [[ -n "$cost_override" ]]; then
		cost_usd="$cost_override"
	else
		cost_usd=$(calculate_cost "$input_tokens" "$output_tokens" "$model")
	fi

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$ts" "$provider" "$model" "$tier" "$task_id" \
		"$input_tokens" "$output_tokens" "$cost_usd" >>"$COST_LOG"

	return 0
}

cmd_status() {
	local json_flag=false days=7 provider_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_flag=true
			shift
			;;
		--days)
			days="${2:-7}"
			shift 2
			;;
		--provider)
			provider_filter="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ ! -f "$COST_LOG" ]]; then
		print_warning "No cost log found. Run 'budget-tracker-helper.sh record' first."
		return 0
	fi

	local cutoff
	cutoff=$(date -u -v-"${days}d" +%Y-%m-%d 2>/dev/null) ||
		cutoff=$(date -u -d "${days} days ago" +%Y-%m-%d 2>/dev/null) ||
		cutoff="2000-01-01"

	local agg
	agg=$(awk -F'\t' -v cutoff="$cutoff" -v pf="$provider_filter" '
		NR == 1 { next }
		{
			day = substr($1, 1, 10); prov = $2
			inp = $6 + 0; outp = $7 + 0; cost = $8 + 0
			if (day < cutoff) next
			if (pf != "" && prov != pf) next
			tc += cost; ti += inp; to += outp; ec++
			pc[prov] += cost; pe[prov]++; dc[day] += cost
		}
		END {
			printf "TOTAL\t%.2f\t%d\t%d\t%d\n", tc, ti, to, ec
			for (p in pc) printf "PROV\t%s\t%.2f\t%d\n", p, pc[p], pe[p]
			for (d in dc) printf "DAY\t%s\t%.2f\n", d, dc[d]
		}
	' "$COST_LOG")

	if [[ -z "$agg" ]]; then
		print_info "No spend events in the last ${days} days."
		return 0
	fi

	# Parse the TOTAL line
	local total_cost total_input total_output event_count
	total_cost=$(echo "$agg" | awk -F'\t' '/^TOTAL/ { print $2 }')
	total_input=$(echo "$agg" | awk -F'\t' '/^TOTAL/ { print $3 }')
	total_output=$(echo "$agg" | awk -F'\t' '/^TOTAL/ { print $4 }')
	event_count=$(echo "$agg" | awk -F'\t' '/^TOTAL/ { print $5 }')

	if [[ "$json_flag" == "true" ]]; then
		# Build provider array
		local prov_json
		prov_json=$(echo "$agg" | awk -F'\t' '
			/^PROV/ {
				if (first) printf ","
				printf "{\"provider\":\"%s\",\"cost_usd\":%.2f,\"events\":%d}", $2, $3, $4
				first = 1
			}
		')
		local day_json
		day_json=$(echo "$agg" | awk -F'\t' '
			/^DAY/ {
				if (first) printf ","
				printf "{\"date\":\"%s\",\"cost_usd\":%.2f}", $2, $3
				first = 1
			}
		')
		printf '{"days":%d,"total_cost_usd":%.2f,"total_input_tokens":%d,"total_output_tokens":%d,"events":%d,"by_provider":[%s],"by_day":[%s]}\n' \
			"$days" "$total_cost" "$total_input" "$total_output" "$event_count" \
			"$prov_json" "$day_json"
		return 0
	fi

	echo ""
	echo "Cost Log Status (last ${days} days)"
	echo "===================================="
	echo ""
	printf "  Total cost:     \$%s\n" "$total_cost"
	printf "  Input tokens:   %s\n" "$total_input"
	printf "  Output tokens:  %s\n" "$total_output"
	printf "  Events:         %s\n" "$event_count"
	echo ""

	echo "  By provider:"
	echo "$agg" | awk -F'\t' '/^PROV/ { printf "    %-14s $%-10s %d events\n", $2, $3, $4 }'
	echo ""

	echo "  By day:"
	echo "$agg" | awk -F'\t' '/^DAY/ { printf "    %s  $%s\n", $2, $3 }' | sort
	echo ""

	return 0
}

cmd_burn_rate() {
	local provider_filter="" json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider_filter="${2:-}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		*)
			if [[ -z "$provider_filter" ]]; then
				provider_filter="$1"
			fi
			shift
			;;
		esac
	done

	if [[ ! -f "$COST_LOG" ]]; then
		print_warning "No cost log found."
		return 0
	fi

	local today
	today=$(date -u +%Y-%m-%d)

	local stats
	stats=$(awk -F'\t' -v today="$today" -v pf="$provider_filter" '
		NR == 1 { next }
		{
			day = substr($1, 1, 10); cost = $8 + 0
			if (pf != "" && $2 != pf) next
			if (day == today) { tc += cost; te++ }
			if (day < today) { wc += cost; wd[day] = 1 }
		}
		END {
			nd = 0; for (d in wd) nd++
			avg = (nd > 0) ? wc / nd : 0
			printf "%.2f\t%d\t%.2f\t%d", tc, te, avg, nd
		}
	' "$COST_LOG")

	local today_spend today_events avg_daily n_days
	today_spend=$(echo "$stats" | cut -f1)
	today_events=$(echo "$stats" | cut -f2)
	avg_daily=$(echo "$stats" | cut -f3)
	n_days=$(echo "$stats" | cut -f4)

	local hours_elapsed
	hours_elapsed=$(date -u +%H)
	hours_elapsed=$((hours_elapsed == 0 ? 1 : hours_elapsed))

	local hourly_rate
	hourly_rate=$(awk "BEGIN { printf \"%.2f\", $today_spend / $hours_elapsed }")

	if [[ "$json_flag" == "true" ]]; then
		printf '{"provider":"%s","today_spend":%.2f,"hourly_rate":%.2f,"avg_daily_7d":%.2f,"today_events":%d}\n' \
			"${provider_filter:-all}" "$today_spend" "$hourly_rate" "$avg_daily" "$today_events"
	else
		echo ""
		echo "Burn Rate: ${provider_filter:-all providers}"
		echo "========================="
		echo ""
		printf "  Today's spend:   \$%s\n" "$today_spend"
		printf "  Hourly rate:     \$%s/hr\n" "$hourly_rate"
		printf "  7-day avg daily: \$%s (%d days with data)\n" "$avg_daily" "$n_days"
		printf "  Events today:    %s\n" "$today_events"
		echo ""
	fi

	return 0
}

cmd_help() {
	cat <<EOF
Budget Tracker Helper - Append-only cost log (t1337.3)

Usage: budget-tracker-helper.sh [command] [options]

Commands:
  record            Append a spend event to the cost log
  status            Summarise spend (--days N, --provider X, --json)
  burn-rate [prov]  Calculate burn rate (--json)
  help              Show this help

Record options:
  --provider X      Provider name    --model X        Model ID
  --tier X          Tier name        --task X         Task ID
  --input-tokens N  Input tokens     --output-tokens N  Output tokens
  --cost N          Override cost (USD)

Log file: $COST_LOG
EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	# Initialize cost log for all commands except help
	if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
		init_cost_log || return 1
	fi

	case "$command" in
	record)
		cmd_record "$@"
		;;
	status)
		cmd_status "$@"
		;;
	burn-rate | burnrate | burn_rate)
		cmd_burn_rate "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	# Backward compatibility: accept old commands gracefully
	check | recommend | configure | configure-period | reset | tier-drift | tier_drift | prune)
		print_warning "Command '$command' removed in v2.0. Use 'status' or 'burn-rate' instead."
		return 0
		;;
	budget-check-tier | budget_check_tier)
		# Old dispatch integration — return the requested tier unchanged
		local _provider="${1:-}"
		local _tier="${2:-sonnet}"
		echo "$_tier"
		return 0
		;;
	budget-preferred-provider | budget_preferred_provider)
		# Old dispatch integration — return empty (no preference)
		echo ""
		return 0
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
