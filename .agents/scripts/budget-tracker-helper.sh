#!/usr/bin/env bash
# shellcheck disable=SC1091
# Budget Tracker Helper - Append-only cost log (t1337.3)
# Appends spend events to a TSV file. AI reads the log to decide model routing.
# Commands: record, status, burn-rate, tail, help
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

# get_model_pricing() is in shared-constants.sh (consolidated in t1337.2)
# Returns: input|output|cache_read|cache_write — budget-tracker uses first two.

calculate_cost() {
	local input_tokens="$1" output_tokens="$2" model="$3"
	local pricing
	pricing=$(get_model_pricing "$model")
	local input_price="${pricing%%|*}"
	local output_price
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
		--requested-tier | --actual-tier) shift 2 ;; # backward compat, ignored
		*) shift ;;
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

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$provider" "$model" "$tier" "$task_id" \
		"$input_tokens" "$output_tokens" "$cost_usd" >>"$COST_LOG"
	return 0
}

# Summarise spend from the log. AI can also just read the TSV directly.
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
		*) shift ;;
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

	# Single awk pass: aggregate totals, by-provider, and by-day
	awk -F'\t' -v cutoff="$cutoff" -v pf="$provider_filter" -v jf="$json_flag" '
		NR == 1 { next }
		{
			day = substr($1, 1, 10)
			if (day < cutoff) next
			if (pf != "" && $2 != pf) next
			tc += $8; ti += $6; to += $7; ec++
			pc[$2] += $8; pe[$2]++; dc[day] += $8
		}
		END {
			if (ec == 0) { print "No spend events in period."; exit }
			if (jf == "true") {
				printf "{\"days\":%d,\"total_cost_usd\":%.2f,\"input_tokens\":%d,\"output_tokens\":%d,\"events\":%d,\"by_provider\":[", NR-1, tc, ti, to, ec
				f = 0; for (p in pc) { if (f) printf ","; printf "{\"provider\":\"%s\",\"cost\":%.2f,\"n\":%d}", p, pc[p], pe[p]; f = 1 }
				printf "],\"by_day\":["; f = 0
				for (d in dc) { if (f) printf ","; printf "{\"date\":\"%s\",\"cost\":%.2f}", d, dc[d]; f = 1 }
				printf "]}\n"
			} else {
				printf "\nCost Log Status (last %d days)\n====================================\n\n", NR-1
				printf "  Total cost:     $%.2f\n  Input tokens:   %d\n  Output tokens:  %d\n  Events:         %d\n\n", tc, ti, to, ec
				printf "  By provider:\n"
				for (p in pc) printf "    %-14s $%-10.2f %d events\n", p, pc[p], pe[p]
				printf "\n  By day:\n"
				for (d in dc) printf "    %s  $%.2f\n", d, dc[d]
				printf "\n"
			}
		}
	' "$COST_LOG"
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
			if [[ -z "$provider_filter" ]]; then provider_filter="$1"; fi
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
	local hours_elapsed
	hours_elapsed=$(date -u +%H)
	hours_elapsed=$((hours_elapsed == 0 ? 1 : hours_elapsed))

	awk -F'\t' -v today="$today" -v pf="$provider_filter" -v jf="$json_flag" -v hrs="$hours_elapsed" '
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
			hr = tc / hrs
			label = (pf != "") ? pf : "all providers"
			if (jf == "true") {
				printf "{\"provider\":\"%s\",\"today_spend\":%.2f,\"hourly_rate\":%.2f,\"avg_daily\":%.2f,\"today_events\":%d}\n", label, tc, hr, avg, te
			} else {
				printf "\nBurn Rate: %s\n=========================\n\n", label
				printf "  Today'\''s spend:   $%.2f\n  Hourly rate:     $%.2f/hr\n  Avg daily:       $%.2f (%d days)\n  Events today:    %d\n\n", tc, hr, avg, nd, te
			}
		}
	' "$COST_LOG"
	return 0
}

# Show recent log entries (for AI to read directly)
cmd_tail() {
	local n=20
	if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
		n="$1"
	fi
	if [[ ! -f "$COST_LOG" ]]; then
		print_warning "No cost log found."
		return 0
	fi
	head -1 "$COST_LOG"
	tail -n "$n" "$COST_LOG"
	return 0
}

cmd_help() {
	cat <<'EOF'
Budget Tracker Helper - Append-only cost log (t1337.3)

Usage: budget-tracker-helper.sh [command] [options]

Commands:
  record            Append a spend event to the cost log
  status            Summarise spend (--days N, --provider X, --json)
  burn-rate [prov]  Calculate burn rate (--json)
  tail [N]          Show last N log entries (default: 20)
  help              Show this help

Record options:
  --provider X      Provider name    --model X        Model ID
  --tier X          Tier name        --task X         Task ID
  --input-tokens N  Input tokens     --output-tokens N  Output tokens
  --cost N          Override cost (USD)
EOF
	printf '\nLog file: %s\n' "$COST_LOG"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
		init_cost_log || return 1
	fi

	case "$command" in
	record) cmd_record "$@" ;;
	status) cmd_status "$@" ;;
	burn-rate | burnrate | burn_rate) cmd_burn_rate "$@" ;;
	tail) cmd_tail "$@" ;;
	help | --help | -h) cmd_help ;;
	# Backward compat: old commands return gracefully
	check | recommend | configure | configure-period | reset | tier-drift | tier_drift | prune)
		print_warning "Command '$command' removed in t1337.3. Use 'status' or 'burn-rate'."
		return 0
		;;
	budget-check-tier | budget_check_tier)
		echo "${2:-sonnet}" # Return requested tier unchanged
		return 0
		;;
	budget-preferred-provider | budget_preferred_provider)
		echo "" # No preference
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
