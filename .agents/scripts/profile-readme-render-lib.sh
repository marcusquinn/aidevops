#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Profile README Render Library — Content Generation and Markdown Rendering
# =============================================================================
# Functions for rendering profile stats sections into markdown:
#   1. Apps     — macOS/Linux app name mapping and screen time section
#   2. Tables   — model usage table rendering with savings calculations
#   3. Generate — high-level section generators and cmd_generate entry point
#
# Usage: source "${SCRIPT_DIR}/profile-readme-render-lib.sh"
#        (Sourced automatically by profile-readme-helper.sh)
#
# Dependencies:
#   - profile-readme-data-lib.sh (format_*, cost_*, token_*, model usage)
#   - SCRIPT_DIR — set by orchestrator; this file provides a fallback
#   - sqlite3 (optional), jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PROFILE_README_RENDER_LIB_LOADED:-}" ]] && return 0
_PROFILE_README_RENDER_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback — needed when sourced from test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Apps — App Name Mapping and Screen Time Section
# =============================================================================

# --- Map bundle ID to friendly app name ---
_friendly_app_name() {
	local bundle="$1"
	case "$bundle" in
	# System apps
	com.apple.mail) echo "Mail" ;;
	com.apple.finder) echo "Finder" ;;
	com.apple.MobileSMS) echo "Messages" ;;
	com.apple.Photos) echo "Photos" ;;
	com.apple.Preview) echo "Preview" ;;
	com.apple.Safari) echo "Safari" ;;
	com.apple.iCal) echo "Calendar" ;;
	com.apple.systempreferences) echo "System Settings" ;;
	com.apple.AddressBook) echo "Contacts" ;;
	com.apple.Terminal) echo "Terminal" ;;
	com.apple.dt.Xcode) echo "Xcode" ;;
	com.apple.Notes) echo "Notes" ;;
	# Third-party apps
	org.tabby) echo "Tabby" ;;
	com.brave.Browser) echo "Brave Browser" ;;
	com.tinyspeck.slackmacgap) echo "Slack" ;;
	net.whatsapp.WhatsApp) echo "WhatsApp" ;;
	org.whispersystems.signal-desktop) echo "Signal" ;;
	com.spotify.client) echo "Spotify" ;;
	org.mozilla.firefox) echo "Firefox" ;;
	com.google.Chrome) echo "Chrome" ;;
	com.microsoft.VSCode) echo "VS Code" ;;
	com.canva.affinity) echo "Affinity" ;;
	org.libreoffice.script) echo "LibreOffice" ;;
	com.webcatalog.juli.facebook) echo "Facebook" ;;
	# Brave PWAs — extract from known mappings
	com.brave.Browser.app.mjoklplbddabcmpepnokjaffbmgbkkgg) echo "GitHub" ;;
	com.brave.Browser.app.lodlkdfmihgonocnmddehnfgiljnadcf) echo "X" ;;
	com.brave.Browser.app.agimnkijcaahngcdmfeangaknmldooml) echo "YouTube" ;;
	com.brave.Browser.app.imdajkchfecmmahjodnfnpihejhejdgo) echo "Amazon" ;;
	com.brave.Browser.app.ggjocahimgaohmigbfhghnlfcnjemagj) echo "Grok" ;;
	com.brave.Browser.app.mmkpebkcahljniimmcipdlmdonpnlild) echo "Nextcloud Talk" ;;
	com.brave.Browser.app.bkmlmojhimpoiaopgajnfcgdknkaklcc) echo "Nextcloud Talk 2" ;;
	com.brave.Browser.app.ohghonlafcimfigiajnmhdklcbjlbfda) echo "LinkedIn" ;;
	com.brave.Browser.app.akpamiohjfcnimfljfndmaldlcfphjmp) echo "Instagram" ;;
	com.brave.Browser.app.fmpnliohjhemenmnlpbfagaolkdacoja) echo "Claude" ;;
	com.brave.Browser.app.cadlkienfkclaiaibeoongdcgmdikeeg) echo "ChatGPT" ;;
	com.brave.Browser.app.gogeloecmlhfmifbfchpldmjclnfoiho) echo "Search Console" ;;
	com.brave.Browser.app.fbamlndehdinmdbhpcihcihhmjmmpgjn) echo "TradingView" ;;
	com.brave.Browser.app.fbjnhnmfhfifmkmokgjddadhphahbkpp) echo "Spaceship" ;;
	com.brave.Browser.app.mnhkaebcjjhencmpkapnbdaogjamfbcj) echo "Google Maps" ;;
	com.brave.Browser.app.kpmdbogdmbfckbgdfdffkleoleokbhod) echo "Perplexity" ;;
	com.brave.Browser.app.allndljdpmepdafjbbilonjhdgmlohlh) echo "X Pro" ;;
	com.brave.Browser.app.*)
		# Unknown Brave PWA — try to extract a readable suffix
		echo "Brave PWA"
		;;
	*)
		# Unknown — use last component of bundle ID
		local short
		short="${bundle##*.}"
		echo "$short"
		;;
	esac
	return 0
}

# --- Get top apps by screen time percentage (macOS only) ---
# Returns JSON array: [{"app":"Name","today_pct":N,"week_pct":N,"month_pct":N}, ...]
_get_top_apps() {
	local knowledge_db="${HOME}/Library/Application Support/Knowledge/knowledgeC.db"

	if [[ "$(uname -s)" != "Darwin" ]] || [[ ! -f "$knowledge_db" ]]; then
		echo "[]"
		return 0
	fi

	# Query per-app seconds for each period, output as TSV: bundle\ttoday\tweek\tmonth
	local app_data
	app_data=$(sqlite3 "$knowledge_db" "
		SELECT
			ZVALUESTRING,
			COALESCE(SUM(CASE WHEN ZSTARTDATE > (strftime('%s', 'now') - 978307200
				- (CAST(strftime('%H', 'now', 'localtime') AS INTEGER) * 3600
				+ CAST(strftime('%M', 'now', 'localtime') AS INTEGER) * 60
				+ CAST(strftime('%S', 'now', 'localtime') AS INTEGER)))
				THEN ZENDDATE - ZSTARTDATE ELSE 0 END), 0) as today_secs,
			COALESCE(SUM(CASE WHEN ZSTARTDATE > (strftime('%s', 'now') - 978307200 - 86400*7)
				THEN ZENDDATE - ZSTARTDATE ELSE 0 END), 0) as week_secs,
			COALESCE(SUM(ZENDDATE - ZSTARTDATE), 0) as month_secs
		FROM ZOBJECT
		WHERE ZSTREAMNAME = '/app/usage'
			AND ZSTARTDATE > (strftime('%s', 'now') - 978307200 - 86400*28)
		GROUP BY ZVALUESTRING
		HAVING month_secs > 0;
	" 2>/dev/null) || {
		echo "[]"
		return 0
	}

	if [[ -z "$app_data" ]]; then
		echo "[]"
		return 0
	fi

	# Validate and sum totals for each period (reject non-integer values)
	local total_today=0 total_week=0 total_month=0
	while IFS='|' read -r _bundle today_s week_s month_s; do
		# Skip rows with non-integer values (prevents arithmetic injection)
		[[ "$today_s" =~ ^[0-9]+$ ]] || continue
		[[ "$week_s" =~ ^[0-9]+$ ]] || continue
		[[ "$month_s" =~ ^[0-9]+$ ]] || continue
		total_today=$((total_today + today_s))
		total_week=$((total_week + week_s))
		total_month=$((total_month + month_s))
	done <<<"$app_data"

	# Build JSON array sorted by month_secs descending, top 10
	# Uses jq for safe JSON construction (prevents injection from special chars)
	local json_arr="[]"
	local count=0
	while IFS='|' read -r bundle today_s week_s month_s; do
		if [[ $count -ge 10 ]]; then
			break
		fi

		# Validate numeric fields
		[[ "$today_s" =~ ^[0-9]+$ ]] || continue
		[[ "$week_s" =~ ^[0-9]+$ ]] || continue
		[[ "$month_s" =~ ^[0-9]+$ ]] || continue

		local name
		name=$(_friendly_app_name "$bundle")

		# Calculate percentages (integer, rounded)
		local today_pct=0 week_pct=0 month_pct=0
		if [[ $total_today -gt 0 ]]; then
			today_pct=$(((today_s * 100 + total_today / 2) / total_today))
		fi
		if [[ $total_week -gt 0 ]]; then
			week_pct=$(((week_s * 100 + total_week / 2) / total_week))
		fi
		if [[ $total_month -gt 0 ]]; then
			month_pct=$(((month_s * 100 + total_month / 2) / total_month))
		fi

		# Use jq for safe JSON construction (handles special chars in app names)
		json_arr=$(echo "$json_arr" | jq --arg app "$name" \
			--argjson tp "$today_pct" --argjson wp "$week_pct" --argjson mp "$month_pct" \
			'. + [{app: $app, today_pct: $tp, week_pct: $wp, month_pct: $mp}]')
		count=$((count + 1))
	done < <(echo "$app_data" | sort -t'|' -k4 -rn)

	echo "$json_arr"
	return 0
}

# =============================================================================
# Tables — Model Usage Table Rendering
# =============================================================================

# --- Render a model usage table ---
# Usage: _render_model_usage_table <heading> <model_json> <token_totals_json>
# Outputs a markdown table with model usage stats, savings calculations, and footer.
_render_model_usage_table() {
	local heading="$1"
	local model_json="$2"
	local token_totals="$3"

	# Skip entirely if no model data
	local model_count
	model_count=$(echo "$model_json" | jq -r 'if type == "array" then [.[] | select(.cost_total >= 0.05)] | length else 0 end' 2>/dev/null)
	if [[ "${model_count:-0}" == "0" ]]; then
		return 0
	fi

	local total_requests=0 total_input=0 total_output=0 total_cache=0 total_cost=0
	local total_cache_savings="0" total_model_savings="0"
	local model_rows=""

	while IFS= read -r row; do
		local model requests input output cache cost
		model=$(echo "$row" | jq -r '.model')
		requests=$(echo "$row" | jq -r '.requests')
		input=$(echo "$row" | jq -r '.input_tokens')
		output=$(echo "$row" | jq -r '.output_tokens')
		cache=$(echo "$row" | jq -r '.cache_read_tokens')
		cost=$(echo "$row" | jq -r '.cost_total')

		total_requests=$((total_requests + requests))
		total_input=$((total_input + input))
		total_output=$((total_output + output))
		total_cache=$((total_cache + cache))
		total_cost=$(echo "$total_cost + $cost" | bc)

		# Compute per-row savings (cache + model routing vs all-Opus baseline)
		local savings row_cache_savings row_model_savings
		savings=$(_compute_model_row_savings "$model" "$input" "$output" "$cache")
		row_cache_savings=$(echo "$savings" | cut -d'|' -f1)
		row_model_savings=$(echo "$savings" | cut -d'|' -f2)
		total_cache_savings=$(echo "$total_cache_savings + $row_cache_savings" | bc)
		total_model_savings=$(echo "$total_model_savings + $row_model_savings" | bc)

		local clean_model
		clean_model=$(_clean_model_name "$model")
		local f_requests f_input f_output f_cache
		f_requests=$(_format_number "$requests")
		f_input=$(_format_tokens "$input")
		f_output=$(_format_tokens "$output")
		f_cache=$(_format_tokens "$cache")

		# Format cost and both savings with commas and 2 decimal places
		local f_cost f_csavings f_msavings
		f_cost=$(_format_cost "$cost")
		f_csavings=$(_format_cost "$row_cache_savings")
		f_msavings=$(_format_cost "$row_model_savings")

		model_rows="${model_rows}| ${clean_model} | ${f_requests} | ${f_input} | ${f_output} | ${f_cache} | \$${f_cost} | \$${f_csavings} | \$${f_msavings} |
"
	done < <(echo "$model_json" | jq -c '.[] | select(.cost_total >= 0.05)')

	# Format totals
	local f_total_req f_total_in f_total_out f_total_cache
	local f_total_csavings f_total_msavings
	f_total_req=$(_format_number "$total_requests")
	f_total_in=$(_format_tokens "$total_input")
	f_total_out=$(_format_tokens "$total_output")
	f_total_cache=$(_format_tokens "$total_cache")
	local f_total_cost
	f_total_cost=$(_format_cost "$total_cost")
	f_total_csavings=$(_format_cost "$total_cache_savings")
	f_total_msavings=$(_format_cost "$total_model_savings")

	# Combined savings for footer
	local combined_savings f_combined_savings
	combined_savings=$(echo "$total_cache_savings + $total_model_savings" | bc)
	f_combined_savings=$(_format_cost "$combined_savings")

	# Token totals for footer
	local all_tokens cache_pct
	all_tokens=$(echo "$token_totals" | jq -r '.total_all')
	cache_pct=$(echo "$token_totals" | jq -r '.cache_hit_pct')
	local f_all_tokens
	f_all_tokens=$(_format_tokens "$all_tokens")

	cat <<EOF

## ${heading}

| Model | Requests | Input | Output | Cache read | API Cost | Cache savings | Model savings |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
${model_rows}| **Total** | **${f_total_req}** | **${f_total_in}** | **${f_total_out}** | **${f_total_cache}** | **\$${f_total_cost}** | **\$${f_total_csavings}** | **\$${f_total_msavings}** |

_${f_all_tokens} total tokens processed. ${cache_pct}% cache hit rate._

_\$${f_combined_savings} total saved (\$${f_total_csavings} caching + \$${f_total_msavings} model routing vs all-Opus)._

_Model savings are modest because ~${cache_pct}% of tokens are cache reads, where price differences between models are small._
EOF

	return 0
}

# =============================================================================
# Generate — Section Generators and cmd_generate Entry Point
# =============================================================================

# --- Extract and format session time variables for all periods ---
# Populates variables in the caller's scope via stdout as shell assignments.
# Usage: eval "$(_generate_session_time_vars <day_json> <week_json> <month_json> <year_json>)"
_generate_session_time_vars() {
	local day_json="$1"
	local week_json="$2"
	local month_json="$3"
	local year_json="$4"

	local day_human day_worker day_total day_interactive day_workers
	day_human=$(_format_hours "$(echo "$day_json" | jq -r '.interactive_human_hours')")
	day_worker=$(_format_hours "$(echo "$day_json" | jq -r '.worker_human_hours + .worker_machine_hours')")
	day_total=$(_format_hours "$(echo "$day_json" | jq -r '.total_human_hours + .total_machine_hours')")
	day_interactive=$(echo "$day_json" | jq -r '.interactive_sessions')
	day_workers=$(echo "$day_json" | jq -r '.worker_sessions')

	local week_human week_worker week_total week_interactive week_workers
	week_human=$(_format_hours "$(echo "$week_json" | jq -r '.interactive_human_hours')")
	week_worker=$(_format_hours "$(echo "$week_json" | jq -r '.worker_human_hours + .worker_machine_hours')")
	week_total=$(_format_hours "$(echo "$week_json" | jq -r '.total_human_hours + .total_machine_hours')")
	week_interactive=$(echo "$week_json" | jq -r '.interactive_sessions')
	week_workers=$(echo "$week_json" | jq -r '.worker_sessions')

	local month_human month_worker month_total month_interactive month_workers
	month_human=$(_format_hours "$(echo "$month_json" | jq -r '.interactive_human_hours')")
	month_worker=$(_format_hours "$(echo "$month_json" | jq -r '.worker_human_hours + .worker_machine_hours')")
	month_total=$(_format_hours "$(echo "$month_json" | jq -r '.total_human_hours + .total_machine_hours')")
	month_interactive=$(echo "$month_json" | jq -r '.interactive_sessions')
	month_workers=$(echo "$month_json" | jq -r '.worker_sessions')

	local year_human year_worker year_total year_interactive year_workers
	year_human=$(_format_hours "$(echo "$year_json" | jq -r '.interactive_human_hours')")
	year_worker=$(_format_hours "$(echo "$year_json" | jq -r '.worker_human_hours + .worker_machine_hours')")
	year_total=$(_format_hours "$(echo "$year_json" | jq -r '.total_human_hours + .total_machine_hours')")
	year_interactive=$(echo "$year_json" | jq -r '.interactive_sessions')
	year_workers=$(echo "$year_json" | jq -r '.worker_sessions')

	# Emit as shell variable assignments for eval
	printf 'day_human=%q day_worker=%q day_total=%q day_interactive=%q day_workers=%q\n' \
		"$day_human" "$day_worker" "$day_total" "$day_interactive" "$day_workers"
	printf 'week_human=%q week_worker=%q week_total=%q week_interactive=%q week_workers=%q\n' \
		"$week_human" "$week_worker" "$week_total" "$week_interactive" "$week_workers"
	printf 'month_human=%q month_worker=%q month_total=%q month_interactive=%q month_workers=%q\n' \
		"$month_human" "$month_worker" "$month_total" "$month_interactive" "$month_workers"
	printf 'year_human=%q year_worker=%q year_total=%q year_interactive=%q year_workers=%q\n' \
		"$year_human" "$year_worker" "$year_total" "$year_interactive" "$year_workers"
	return 0
}

# --- Generate the Top Apps by Screen Time markdown section ---
# Outputs the full markdown block, or nothing if no app data available.
_generate_top_apps_section() {
	local top_apps_json
	top_apps_json=$(_get_top_apps)

	local app_count
	app_count=$(echo "$top_apps_json" | jq 'length')
	if [[ "$app_count" -eq 0 ]]; then
		return 0
	fi

	local app_rows=""
	while IFS= read -r row; do
		local app today_pct week_pct month_pct
		app=$(echo "$row" | jq -r '.app')
		today_pct=$(echo "$row" | jq -r '.today_pct')
		week_pct=$(echo "$row" | jq -r '.week_pct')
		month_pct=$(echo "$row" | jq -r '.month_pct')

		local today_str week_str month_str
		if [[ "$today_pct" -eq 0 ]]; then today_str="--"; else today_str="${today_pct}%"; fi
		if [[ "$week_pct" -eq 0 ]]; then week_str="--"; else week_str="${week_pct}%"; fi
		if [[ "$month_pct" -eq 0 ]]; then month_str="--"; else month_str="${month_pct}%"; fi

		app_rows="${app_rows}| ${app} | ${today_str} | ${week_str} | ${month_str} |
"
	done < <(echo "$top_apps_json" | jq -c '.[]')

	cat <<EOF

## Top Apps by Screen Time

| App | 24h | 7 Days | 28 Days |
| --- | ---: | ---: | ---: |
${app_rows}
_Top 10 apps by foreground time share. Mac only._
EOF
	return 0
}

# --- Generate the Work with AI markdown table ---
# Usage: _generate_work_with_ai_table <screen_json> <day_json> <week_json> <month_json> <year_json>
_generate_work_with_ai_table() {
	local screen_json="$1"
	local day_json="$2"
	local week_json="$3"
	local month_json="$4"
	local year_json="$5"

	# Extract screen time values
	local screen_today screen_week screen_month screen_year
	screen_today=$(echo "$screen_json" | jq -r '.today_hours | . * 10 | round / 10')
	screen_week=$(echo "$screen_json" | jq -r '.week_hours | . * 10 | round / 10')
	screen_month=$(echo "$screen_json" | jq -r '.month_hours | . * 10 | round / 10')
	screen_year=$(echo "$screen_json" | jq -r '.year_hours | round')

	# Check if year is extrapolated (history file has < 365 days)
	local history_file="${HOME}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	local year_prefix="" year_suffix=""
	if [[ -f "$history_file" ]]; then
		local history_days
		history_days=$(wc -l <"$history_file" | tr -d ' ')
		if [[ "$history_days" -lt 365 ]]; then
			year_prefix="~"
			year_suffix="*"
		fi
	else
		year_prefix="~"
		year_suffix="*"
	fi

	# Extract and format session time variables for all periods
	local day_human day_worker day_total day_interactive day_workers
	local week_human week_worker week_total week_interactive week_workers
	local month_human month_worker month_total month_interactive month_workers
	local year_human year_worker year_total year_interactive year_workers
	eval "$(_generate_session_time_vars "$day_json" "$week_json" "$month_json" "$year_json")"

	# Format screen time and session counts with commas
	local f_screen_month f_screen_year
	f_screen_month=$(_format_number "$screen_month")
	f_screen_year=$(_format_number "$screen_year")

	local f_day_int f_week_int f_month_int f_year_int
	f_day_int=$(_format_number "$day_interactive")
	f_week_int=$(_format_number "$week_interactive")
	f_month_int=$(_format_number "$month_interactive")
	f_year_int=$(_format_number "$year_interactive")

	local f_day_wrk f_week_wrk f_month_wrk f_year_wrk
	f_day_wrk=$(_format_number "$day_workers")
	f_week_wrk=$(_format_number "$week_workers")
	f_month_wrk=$(_format_number "$month_workers")
	f_year_wrk=$(_format_number "$year_workers")

	local f_month_total f_year_total
	f_month_total=$(_format_number "$month_total")
	f_year_total=$(_format_number "$year_total")

	# Determine platform label for screen time row
	local os_type screen_label screen_source
	os_type="$(uname -s)"
	case "$os_type" in
	Darwin)
		screen_label="Screen time (Mac)"
		screen_source="macOS display events"
		;;
	Linux)
		screen_label="Screen time (Linux)"
		screen_source="systemd-logind session events"
		;;
	*)
		screen_label="Screen time"
		screen_source="system events"
		;;
	esac

	cat <<EOF
## Work with AI

| Metric | 24h | 7 Days | 28 Days | 365 Days |
| --- | ---: | ---: | ---: | ---: |
| ${screen_label} | ${screen_today}h | ${screen_week}h | ${f_screen_month}h | ${year_prefix}${f_screen_year}h${year_suffix} |
| User AI session hours | ${day_human}h | ${week_human}h | ${month_human}h | ${year_human}h |
| AI worker hours | ${day_worker}h | ${week_worker}h | ${month_worker}h | ${year_worker}h |
| AI concurrency hours | ${day_total}h | ${week_total}h | ${f_month_total}h | ${f_year_total}h |
| Interactive sessions | ${f_day_int} | ${f_week_int} | ${f_month_int} | ${f_year_int} |
| Worker sessions | ${f_day_wrk} | ${f_week_wrk} | ${f_month_wrk} | ${f_year_wrk} |

_Screen time from ${screen_source}, snapshotted daily.$([ -n "$year_suffix" ] && echo " *365-day extrapolated (accumulating real data).")_

_User AI session hours measured from AI message timestamps (reading, thinking, typing between responses)._
EOF
	return 0
}

# --- Generate the stats markdown ---
cmd_generate() {
	# Gather all data
	local screen_json
	screen_json=$(_get_screen_time)

	local day_json week_json month_json year_json
	day_json=$(_get_session_time day)
	week_json=$(_get_session_time week)
	month_json=$(_get_session_time month)
	year_json=$(_get_session_time year)

	local model_json_30d model_json_all
	model_json_30d=$(_get_model_usage "30d")
	model_json_all=$(_get_model_usage "all")

	local token_totals_30d token_totals_all
	token_totals_30d=$(_get_token_totals "30d")
	token_totals_all=$(_get_token_totals "all")

	# Detect if there's any meaningful data to display.
	local has_data=false
	local has_session_time has_model_usage has_screen_time
	has_session_time=$(echo "$month_json" | jq -r '((.total_human_hours + .total_machine_hours) // 0) > 0')
	has_model_usage=$(echo "$model_json_all" | jq -r '((if type == "array" then length else 0 end) // 0) > 0')
	has_screen_time=$(echo "$screen_json" | jq -r '(.month_hours // 0) > 0')

	if [[ "$has_session_time" == "true" ]] ||
		[[ "$has_model_usage" == "true" ]] ||
		[[ "$has_screen_time" == "true" ]]; then
		has_data=true
	fi

	if [[ "$has_data" == "false" ]]; then
		cat <<'EOF'
## Work with AI

_Stats will appear here automatically once [aidevops](https://aidevops.sh) has been running locally. Includes AI session hours, model usage, token costs, and screen time._
EOF
		return 0
	fi

	_generate_work_with_ai_table "$screen_json" "$day_json" "$week_json" "$month_json" "$year_json"
	_render_model_usage_table "AI Model Usage (last 30 days)" "$model_json_30d" "$token_totals_30d"
	_render_model_usage_table "AI Model Usage (all time)" "$model_json_all" "$token_totals_all"
	_generate_top_apps_section

	return 0
}
