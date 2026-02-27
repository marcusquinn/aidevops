#!/usr/bin/env bash
# Observability Helper — LLM request tracking via JSONL log (t1307, t1337.5)
# Commands: ingest | record | rate-limits | help
# Storage: ~/.aidevops/.agent-workspace/observability/metrics.jsonl

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

readonly OBS_DIR="${HOME}/.aidevops/.agent-workspace/observability"
readonly OBS_METRICS="${OBS_DIR}/metrics.jsonl" OBS_OFFSETS="${OBS_DIR}/parse-offsets.json"
readonly CLAUDE_LOG_DIR="${HOME}/.claude/projects"
readonly RATE_LIMITS_CONFIG_USER="${HOME}/.config/aidevops/rate-limits.json"
readonly RATE_LIMITS_CONFIG_TEMPLATE="${SCRIPT_DIR}/../configs/rate-limits.json.txt"
readonly DEFAULT_WARN_PCT=80 DEFAULT_WINDOW_MINUTES=1

init_storage() {
	mkdir -p "$OBS_DIR" 2>/dev/null || true
	[[ -f "$OBS_METRICS" ]] || touch "$OBS_METRICS"
	[[ -f "$OBS_OFFSETS" ]] || echo '{}' >"$OBS_OFFSETS"
}

get_offset() {
	[[ -f "$OBS_OFFSETS" ]] && command -v jq &>/dev/null || {
		echo "0"
		return 0
	}
	jq -r --arg f "$1" '.[$f] // 0' "$OBS_OFFSETS" 2>/dev/null || echo "0"
}

set_offset() {
	command -v jq &>/dev/null || return 0
	local tmp="${OBS_OFFSETS}.tmp"
	jq --arg f "$1" --argjson o "$2" '.[$f] = $o' "$OBS_OFFSETS" >"$tmp" 2>/dev/null && mv "$tmp" "$OBS_OFFSETS"
}

get_project_from_path() {
	local dir_name
	dir_name=$(basename "$(dirname "$1")")
	local project
	project=$(echo "$dir_name" | sed -E 's/^-Users-[^-]+-Git-//; s/-.*(feature|bugfix|hotfix|chore|refactor|experiment|release)-.*//')
	[[ -z "$project" || "$project" == "-" ]] && project="unknown"
	echo "$project"
}

_calc_costs() {
	local input_tokens="$1" output_tokens="$2" cache_read="$3" cache_write="$4" model="$5"
	local pricing
	pricing=$(get_model_pricing "$model")
	local input_price output_price cr_price cw_price
	IFS='|' read -r input_price output_price cr_price cw_price <<<"$pricing"
	awk "BEGIN {
		ci=$input_tokens/1e6*$input_price; co=$output_tokens/1e6*$output_price
		cr=$cache_read/1e6*$cr_price; cw=$cache_write/1e6*$cw_price
		printf \"%.8f|%.8f|%.8f|%.8f|%.8f\",ci,co,cr,cw,ci+co+cr+cw
	}"
}

# Write a metrics entry to the JSONL log.
_write_metric() {
	local provider="$1" model="$2" session_id="$3" request_id="$4" project="$5"
	local input_tokens="$6" output_tokens="$7" cache_read="$8" cache_write="$9"
	local cost_input="${10}" cost_output="${11}" cost_cache_read="${12}" cost_cache_write="${13}" cost_total="${14}"
	local stop_reason="${15}" service_tier="${16}" git_branch="${17}" log_source="${18}" recorded_at="${19}"
	local error_message="${20:-}"
	jq -c -n \
		--arg pv "$provider" --arg md "$model" --arg si "$session_id" --arg ri "$request_id" \
		--arg pj "$project" --argjson it "$input_tokens" --argjson ot "$output_tokens" \
		--argjson cr "$cache_read" --argjson cw "$cache_write" \
		--arg ci "$cost_input" --arg co "$cost_output" --arg ccr "$cost_cache_read" \
		--arg ccw "$cost_cache_write" --arg ct "$cost_total" \
		--arg sr "$stop_reason" --arg st "$service_tier" --arg gb "$git_branch" \
		--arg ls "$log_source" --arg ra "$recorded_at" --arg em "$error_message" \
		'{provider:$pv, model:$md, session_id:$si, request_id:$ri, project:$pj,
		  input_tokens:$it, output_tokens:$ot, cache_read_tokens:$cr, cache_write_tokens:$cw,
		  cost_input:($ci|tonumber), cost_output:($co|tonumber),
		  cost_cache_read:($ccr|tonumber), cost_cache_write:($ccw|tonumber),
		  cost_total:($ct|tonumber), stop_reason:$sr, service_tier:$st,
		  git_branch:$gb, log_source:$ls, recorded_at:$ra, error_message:$em}' >>"$OBS_METRICS"
	return 0
}

# =============================================================================
# JSONL Log Parsing
# =============================================================================

parse_jsonl_file() {
	local file_path="$1"
	local start_offset="${2:-0}"
	[[ -f "$file_path" ]] || return 0

	local file_size
	file_size=$(wc -c <"$file_path" | tr -d ' ')
	if [[ "$start_offset" -ge "$file_size" ]]; then
		echo "$start_offset"
		return 0
	fi

	local project
	project=$(get_project_from_path "$file_path")

	local parsed_rows
	parsed_rows=$(dd if="$file_path" bs=1 skip="$start_offset" count=$((file_size - start_offset)) 2>/dev/null |
		jq -r 'select(.type == "assistant" and .message.usage != null) |
			[(.message.model // "unknown"), (.sessionId // ""), (.requestId // ""),
			 (.message.usage.input_tokens // 0), (.message.usage.output_tokens // 0),
			 (.message.usage.cache_read_input_tokens // 0),
			 ((.message.usage.cache_creation_input_tokens // 0) +
			  (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) +
			  (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0)),
			 (.message.stop_reason // ""), (.timestamp // ""),
			 (.message.usage.service_tier // ""), (.gitBranch // "")] | join("|")
		' 2>/dev/null) || parsed_rows=""

	if [[ -z "$parsed_rows" ]]; then
		set_offset "$file_path" "$file_size"
		echo "$file_size"
		return 0
	fi

	local insert_count=0
	while IFS='|' read -r model sid rid itok otok crtok cwtok sr ts st gb; do
		[[ -z "$model" ]] && continue
		local total=$((itok + otok + crtok + cwtok))
		[[ "$total" -eq 0 ]] && continue

		local provider costs ci co ccr ccw ct
		provider=$(get_provider_from_model "$model")
		costs=$(_calc_costs "$itok" "$otok" "$crtok" "$cwtok" "$model")
		IFS='|' read -r ci co ccr ccw ct <<<"$costs"

		_write_metric "$provider" "$model" "$sid" "$rid" "$project" \
			"$itok" "$otok" "$crtok" "$cwtok" "$ci" "$co" "$ccr" "$ccw" "$ct" \
			"$sr" "$st" "$gb" "$file_path" "$ts"
		insert_count=$((insert_count + 1))
	done <<<"$parsed_rows"

	set_offset "$file_path" "$file_size"
	[[ "$insert_count" -gt 0 ]] && print_info "Parsed $insert_count requests from $(basename "$file_path")"
	echo "$file_size"
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_ingest() {
	local quiet=false
	while [[ $# -gt 0 ]]; do
		case "$1" in --quiet) quiet=true ;; esac
		shift
	done

	[[ -d "$CLAUDE_LOG_DIR" ]] || {
		print_warning "Claude log directory not found: $CLAUDE_LOG_DIR"
		return 0
	}
	command -v jq &>/dev/null || {
		print_error "jq required. Install: brew install jq"
		return 1
	}

	local files_processed=0
	while IFS= read -r jsonl_file; do
		[[ -z "$jsonl_file" ]] && continue
		local current_offset file_size
		current_offset=$(get_offset "$jsonl_file")
		file_size=$(wc -c <"$jsonl_file" | tr -d ' ')
		[[ "$current_offset" -ge "$file_size" ]] && continue
		parse_jsonl_file "$jsonl_file" "$current_offset" >/dev/null
		files_processed=$((files_processed + 1))
	done < <(find "$CLAUDE_LOG_DIR" -name "*.jsonl" -type f 2>/dev/null)

	[[ "$quiet" != "true" ]] && print_success "Ingestion complete: processed $files_processed files"
	return 0
}

cmd_record() {
	local provider="" model="" input_tokens=0 output_tokens=0 cache_read_tokens=0 cache_write_tokens=0
	local session_id="" project="" stop_reason="" error_message=""
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
		--error)
			error_message="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	[[ -z "$model" ]] && {
		print_error "Usage: observability-helper.sh record --model X [options]"
		return 1
	}
	[[ -z "$provider" ]] && provider=$(get_provider_from_model "$model")

	local costs ci co ccr ccw ct
	costs=$(_calc_costs "$input_tokens" "$output_tokens" "$cache_read_tokens" "$cache_write_tokens" "$model")
	IFS='|' read -r ci co ccr ccw ct <<<"$costs"

	_write_metric "$provider" "$model" "$session_id" "" "$project" \
		"$input_tokens" "$output_tokens" "$cache_read_tokens" "$cache_write_tokens" \
		"$ci" "$co" "$ccr" "$ccw" "$ct" "$stop_reason" "" "" "" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$error_message"
	print_success "Recorded: $model ($provider) - \$${ct}"
}

# Rate Limit Tracking

_get_rate_limits_config() {
	[[ -f "$RATE_LIMITS_CONFIG_USER" ]] && {
		echo "$RATE_LIMITS_CONFIG_USER"
		return 0
	}
	[[ -f "$RATE_LIMITS_CONFIG_TEMPLATE" ]] && {
		echo "$RATE_LIMITS_CONFIG_TEMPLATE"
		return 0
	}
	return 1
}

# Read a field from rate-limits config. Usage: _rl_jq '.providers[$p][$f]' provider field [default]
_rl_jq() {
	local expr="$1" default="${4:-0}"
	local config_file
	config_file=$(_get_rate_limits_config) || {
		echo "$default"
		return 0
	}
	command -v jq &>/dev/null || {
		echo "$default"
		return 0
	}
	local val
	val=$(jq -r --arg p "${2:-}" --arg f "${3:-}" "$expr // empty" "$config_file" 2>/dev/null) || val=""
	echo "${val:-$default}"
}

# shellcheck disable=SC2016 # $p and $f are jq variable references, not shell variables
_get_rl_field() { _rl_jq '.providers[$p][$f]' "$1" "$2" "0"; }
# shellcheck disable=SC2016 # $f is a jq variable reference, not a shell variable
_get_config_val() { _rl_jq '.[$f]' "" "$1" "$2"; }

_count_usage_in_window() {
	local provider="$1" window_minutes="$2"
	[[ -f "$OBS_METRICS" ]] || {
		echo "0|0"
		return 0
	}
	local cutoff
	if date --version &>/dev/null 2>&1; then
		cutoff=$(date -u -d "-${window_minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ")
	else cutoff=$(date -u -v-"${window_minutes}"M +"%Y-%m-%dT%H:%M:%SZ"); fi
	jq -sr --arg p "$provider" --arg c "$cutoff" '
		[.[] | select(.provider == $p and .recorded_at >= $c)] |
		"\(length)|\(map(.input_tokens + .output_tokens + .cache_read_tokens + .cache_write_tokens) | add // 0)"
	' "$OBS_METRICS" 2>/dev/null || echo "0|0"
}

# Public API: called by model-availability-helper.sh. Returns: 0=ok, 1=warn, 2=critical.
check_rate_limit_risk() {
	local provider="$1"
	local wm
	wm=$(_get_config_val "window_minutes" "$DEFAULT_WINDOW_MINUTES")
	local wp
	wp=$(_get_config_val "warn_pct" "$DEFAULT_WARN_PCT")
	[[ "$wm" =~ ^[0-9]+$ && "$wm" -gt 0 ]] || wm="$DEFAULT_WINDOW_MINUTES"
	[[ "$wp" =~ ^[0-9]+$ ]] || wp="$DEFAULT_WARN_PCT"
	local rl
	rl=$(_get_rl_field "$provider" "requests_per_min")
	[[ "$rl" =~ ^[0-9]+$ ]] || rl=0
	local tl
	tl=$(_get_rl_field "$provider" "tokens_per_min")
	[[ "$tl" =~ ^[0-9]+$ ]] || tl=0
	[[ "$rl" -eq 0 && "$tl" -eq 0 ]] && {
		echo "ok"
		return 0
	}

	local usage ar at
	usage=$(_count_usage_in_window "$provider" "$wm")
	IFS='|' read -r ar at <<<"$usage"
	local max_pct
	max_pct=$(awk "BEGIN { rp=($rl>0)?$ar*100/$rl:0; tp=($tl>0)?$at*100/$tl:0; print (rp>tp)?rp:tp }")
	[[ "$max_pct" -ge 95 ]] && {
		echo "critical"
		return 2
	}
	[[ "$max_pct" -ge "$wp" ]] && {
		echo "warn"
		return 1
	}
	echo "ok"
	return 0
}

cmd_rate_limits() {
	local json_flag=false provider_filter="" window_minutes=""
	while [[ $# -gt 0 ]]; do
		case "$1" in --json)
			json_flag=true
			shift
			;;
		--provider)
			provider_filter="${2:-}"
			shift 2
			;;
		--window)
			window_minutes="${2:-}"
			shift 2
			;;
		*) shift ;; esac
	done
	cmd_ingest --quiet >/dev/null 2>&1 || true

	local config_file
	config_file=$(_get_rate_limits_config) || config_file=""
	local ew="${window_minutes:-$(_get_config_val "window_minutes" "$DEFAULT_WINDOW_MINUTES")}"
	local wp
	wp=$(_get_config_val "warn_pct" "$DEFAULT_WARN_PCT")
	[[ "$ew" =~ ^[0-9]+$ && "$ew" -gt 0 ]] || {
		print_error "--window must be a positive integer"
		return 1
	}
	[[ "$wp" =~ ^[0-9]+$ ]] || wp="$DEFAULT_WARN_PCT"

	# Collect providers
	local -a providers=()
	if [[ -n "$provider_filter" ]]; then
		providers=("$provider_filter")
	else
		local seen=""
		if [[ -n "$config_file" ]] && command -v jq &>/dev/null; then
			while IFS= read -r p; do
				[[ -z "$p" || "$seen" == *"|${p}|"* ]] && continue
				providers+=("$p")
				seen="${seen}|${p}|"
			done < <(jq -r '.providers | keys[]' "$config_file" 2>/dev/null)
		fi
		if [[ -f "$OBS_METRICS" ]] && command -v jq &>/dev/null; then
			while IFS= read -r p; do
				[[ -z "$p" || "$seen" == *"|${p}|"* ]] && continue
				providers+=("$p")
				seen="${seen}|${p}|"
			done < <(jq -r '.provider' "$OBS_METRICS" 2>/dev/null | sort -u)
		fi
	fi
	[[ ${#providers[@]} -eq 0 ]] && {
		[[ "$json_flag" == "true" ]] && echo "[]" || print_info "No provider data. Run 'ingest' first."
		return 0
	}

	# Build rows
	local -a rows=()
	for prov in "${providers[@]}"; do
		[[ -z "$prov" ]] && continue
		local rl tl bt usage ar at rp=0 tp=0
		rl=$(_get_rl_field "$prov" "requests_per_min")
		[[ "$rl" =~ ^[0-9]+$ ]] || rl=0
		tl=$(_get_rl_field "$prov" "tokens_per_min")
		[[ "$tl" =~ ^[0-9]+$ ]] || tl=0
		bt=$(_get_rl_field "$prov" "billing_type")
		[[ "$bt" == "0" ]] && bt="unknown"
		usage=$(_count_usage_in_window "$prov" "$ew")
		IFS='|' read -r ar at <<<"$usage"
		[[ "$rl" -gt 0 ]] && rp=$(awk "BEGIN { printf \"%d\", $ar * 100 / $rl }")
		[[ "$tl" -gt 0 ]] && tp=$(awk "BEGIN { printf \"%d\", $at * 100 / $tl }")
		local mp st="ok"
		mp=$(awk "BEGIN { print ($rp > $tp) ? $rp : $tp }")
		[[ "$mp" -ge 95 ]] && st="critical"
		[[ "$mp" -lt 95 && "$mp" -ge "$wp" ]] && st="warn"
		rows+=("${prov}|${ar}|${rl}|${rp}|${at}|${tl}|${tp}|${st}|${bt}")
	done

	if [[ "$json_flag" == "true" ]]; then
		local json_arr="[" first=true
		for row in "${rows[@]}"; do
			IFS='|' read -r pv a r rp2 t l tp2 s _ <<<"$row"
			[[ "$first" == "true" ]] || json_arr="${json_arr},"
			first=false
			json_arr="${json_arr}{\"provider\":\"$pv\",\"requests_used\":${a:-0},\"requests_limit\":${r:-0},\"requests_pct\":${rp2:-0},\"tokens_used\":${t:-0},\"tokens_limit\":${l:-0},\"tokens_pct\":${tp2:-0},\"status\":\"$s\",\"window_minutes\":${ew:-1}}"
		done
		echo "${json_arr}]"
		return 0
	fi

	printf "\nRate Limit Utilisation (%smin window, warn at %s%%)\n" "$ew" "$wp"
	[[ -z "$config_file" ]] && print_warning "No rate-limits.json found"
	printf "  %-12s %6s %10s %5s %8s %10s %5s %s\n" "Provider" "Reqs" "Limit" "Pct" "Tokens" "Limit" "Pct" "Status"
	for row in "${rows[@]}"; do
		IFS='|' read -r pv a r rp2 t l tp2 s _ <<<"$row"
		local sd="$s"
		[[ "$s" == "critical" ]] && sd="${RED}CRITICAL${NC}"
		[[ "$s" == "warn" ]] && sd="${YELLOW}WARN${NC}"
		[[ "$s" == "ok" ]] && sd="${GREEN}ok${NC}"
		printf "  %-12s %6s %10s %4s%% %8s %10s %4s%% %b\n" "$pv" "$a" "${r:-n/a}" "$rp2" "$t" "${l:-n/a}" "$tp2" "$sd"
	done
	echo ""
}

cmd_help() {
	cat <<EOF
Observability Helper — LLM request tracking via JSONL log
Usage: observability-helper.sh [command] [options]
Commands: ingest | record (--model X) | rate-limits (--json, --provider, --window) | help
Metrics: $OBS_METRICS
EOF
}

main() {
	local command="${1:-help}"
	shift || true
	init_storage || return 1
	case "$command" in
	ingest | parse | import) cmd_ingest "$@" ;; record | r) cmd_record "$@" ;;
	rate-limits | rate_limits | ratelimits | rl) cmd_rate_limits "$@" ;;
	help | --help | -h) cmd_help ;; *)
		print_error "Unknown: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
