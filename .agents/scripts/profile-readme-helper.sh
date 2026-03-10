#!/usr/bin/env bash
# profile-readme-helper.sh — Auto-update GitHub profile README with live stats
#
# Usage:
#   profile-readme-helper.sh init                  # Create profile repo, seed README, register
#   profile-readme-helper.sh update [--dry-run]    # Update README with live data
#   profile-readme-helper.sh generate              # Print generated stats section to stdout
#   profile-readme-helper.sh help
#
# Requires:
#   - screen-time-helper.sh (macOS screen time)
#   - contributor-activity-helper.sh (AI session time)
#   - jq, bc, git
#
# The profile repo README must contain marker comments:
#   <!-- STATS-START --> ... <!-- STATS-END -->
#   <!-- UPDATED-START --> ... <!-- UPDATED-END -->

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS_FILE="${HOME}/.aidevops/.agent-workspace/observability/metrics.jsonl"

# --- Resolve profile repo path from repos.json ---
_resolve_profile_repo() {
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_json" ]]; then
		echo "Error: repos.json not found at $repos_json" >&2
		return 1
	fi

	# Find repo with priority "profile" — supports both flat and nested repos.json formats
	local profile_path
	profile_path=$(jq -r '
		if .initialized_repos then
			.initialized_repos[] | select(.priority == "profile") | .path
		else
			to_entries[] | select(.value.priority == "profile") | .value.path
		end
	' "$repos_json" 2>/dev/null | head -1)

	if [[ -z "$profile_path" || "$profile_path" == "null" ]]; then
		echo "Error: no profile repo found in repos.json (set priority: \"profile\")" >&2
		return 1
	fi

	echo "$profile_path"
	return 0
}

# --- Format number with commas (bash 3.2 compatible) ---
_format_number() {
	local num="$1"
	# Handle decimals: split on dot
	local integer_part decimal_part
	integer_part="${num%%.*}"
	if [[ "$num" == *"."* ]]; then
		decimal_part=".${num#*.}"
	else
		decimal_part=""
	fi

	# Add commas to integer part using printf + sed
	local formatted
	formatted=$(echo "$integer_part" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta')
	echo "${formatted}${decimal_part}"
	return 0
}

# --- Format hours with 1 decimal place ---
_format_hours() {
	local val="$1"
	printf "%.1f" "$val"
	return 0
}

# --- Format token count (K/M suffix) ---
_format_tokens() {
	local tokens="$1"
	if [[ "$tokens" -ge 1000000 ]]; then
		local m
		m=$(echo "scale=1; $tokens / 1000000" | bc)
		echo "${m}M"
	elif [[ "$tokens" -ge 1000 ]]; then
		local k
		k=$(echo "scale=0; $tokens / 1000" | bc)
		echo "${k}K"
	else
		echo "$tokens"
	fi
	return 0
}

# --- Gather screen time data ---
_get_screen_time() {
	local screen_json
	screen_json=$("${SCRIPT_DIR}/screen-time-helper.sh" profile-stats) || screen_json="{}"
	echo "$screen_json"
	return 0
}

# --- Gather AI session time for a period ---
_get_session_time() {
	local period="$1"
	local session_json
	# Use a single repo path (aidevops) as the DB is global, not per-repo
	session_json=$("${SCRIPT_DIR}/contributor-activity-helper.sh" session-time \
		"${HOME}/Git/aidevops" --period "$period" --format json 2>/dev/null) || session_json="{}"
	echo "$session_json"
	return 0
}

# --- Gather model usage stats ---
_get_model_usage() {
	if [[ ! -f "$METRICS_FILE" ]]; then
		echo "[]"
		return 0
	fi

	local cutoff
	cutoff=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo "1970-01-01")

	jq -s --arg cutoff "$cutoff" '
		[.[] | select(.recorded_at >= $cutoff)]
		| group_by(.model)
		| map({
			model: .[0].model,
			requests: length,
			input_tokens: ([.[].input_tokens // 0] | add),
			output_tokens: ([.[].output_tokens // 0] | add),
			cache_read_tokens: ([.[].cache_read_tokens // 0] | add),
			cache_write_tokens: ([.[].cache_write_tokens // 0] | add),
			cost_total: ([.[].cost_total // 0] | add | . * 100 | round / 100)
		})
		| sort_by(-.cost_total)
	' "$METRICS_FILE" 2>/dev/null || echo "[]"

	return 0
}

# --- Get total token stats for footer ---
_get_token_totals() {
	if [[ ! -f "$METRICS_FILE" ]]; then
		echo '{"total_all":0,"cache_hit_pct":0}'
		return 0
	fi

	local cutoff
	cutoff=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo "1970-01-01")

	jq -s --arg cutoff "$cutoff" '
		[.[] | select(.recorded_at >= $cutoff)]
		| {
			total_input: ([.[].input_tokens // 0] | add),
			total_output: ([.[].output_tokens // 0] | add),
			total_cache_read: ([.[].cache_read_tokens // 0] | add),
			total_cache_write: ([.[].cache_write_tokens // 0] | add)
		}
		| . + {total_all: (.total_input + .total_output + .total_cache_read + .total_cache_write)}
		| . + {cache_hit_pct: (if .total_all > 0 then ((.total_cache_read / .total_all * 1000 | round) / 10) else 0 end)}
	' "$METRICS_FILE" 2>/dev/null || echo '{"total_all":0,"cache_hit_pct":0}'

	return 0
}

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

# --- Get cache savings rate per million tokens for a model ---
# Returns: (input_price - cache_read_price) per million tokens
# --- Get model pricing rates (input|output|cache_read per M tokens) ---
# Mirrors shared-constants.sh get_model_pricing() hardcoded fallback.
# Returns: input_price|output_price|cache_read_price
_model_cost_rates() {
	local model="$1"
	local ms="${model#*/}"
	ms="${ms%%-202*}"
	case "$ms" in
	*opus-4* | *claude-opus*) echo "15.0|75.0|1.50" ;;
	*sonnet-4* | *claude-sonnet*) echo "3.0|15.0|0.30" ;;
	*haiku-4* | *haiku-3* | *claude-haiku*) echo "0.80|4.0|0.08" ;;
	*gpt-4.1-mini*) echo "0.40|1.60|0.10" ;;
	*gpt-4.1*) echo "2.0|8.0|0.50" ;;
	*o3*) echo "10.0|40.0|2.50" ;;
	*o4-mini*) echo "1.10|4.40|0.275" ;;
	*gemini-2.5-pro* | *gemini-3-pro*) echo "1.25|10.0|0.3125" ;;
	*gemini-2.5-flash* | *gemini-3-flash*) echo "0.15|0.60|0.0375" ;;
	*deepseek-r1*) echo "0.55|2.19|0.14" ;;
	*deepseek-v3*) echo "0.27|1.10|0.07" ;;
	*) echo "3.0|15.0|0.30" ;;
	esac
	return 0
}

# --- Clean model name for display ---
_clean_model_name() {
	local model="$1"
	# Remove date suffixes like -20251101, -20250929
	local cleaned
	cleaned=$(echo "$model" | sed -E 's/-[0-9]{8}$//')
	echo "$cleaned"
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

	local model_json
	model_json=$(_get_model_usage)

	local token_totals
	token_totals=$(_get_token_totals)

	# Extract screen time values (round to 1 decimal, strip .0 for large numbers)
	local screen_today screen_week screen_month screen_year
	screen_today=$(echo "$screen_json" | jq -r '.today_hours | . * 10 | round / 10')
	screen_week=$(echo "$screen_json" | jq -r '.week_hours | . * 10 | round / 10')
	screen_month=$(echo "$screen_json" | jq -r '.month_hours | . * 10 | round / 10')
	screen_year=$(echo "$screen_json" | jq -r '.year_hours | round')

	# Check if year is extrapolated (history file has < 365 days)
	local history_file="${HOME}/.aidevops/.agent-workspace/observability/screen-time.jsonl"
	local year_prefix=""
	local year_suffix=""
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

	# Extract session time values per period (1 decimal place for hours)
	# Worker hours = worker_human + worker_machine (from worker sessions)
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

	# Format screen time with commas
	local f_screen_month f_screen_year
	f_screen_month=$(_format_number "$screen_month")
	f_screen_year=$(_format_number "$screen_year")

	# Format session counts with commas
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

	# Format totals with commas
	local f_month_total f_year_total
	f_month_total=$(_format_number "$month_total")
	f_year_total=$(_format_number "$year_total")

	# Determine platform label for screen time row
	local os_type
	os_type="$(uname -s)"
	local screen_label screen_source
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

	# Build Work with AI table
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

	# Build model usage table
	# Opus rates used as baseline for model routing savings
	local opus_input_rate="15.0" opus_output_rate="75.0" opus_cache_rate="1.50"
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

		# Get this model's rates: input|output|cache_read
		local rates m_input_rate m_output_rate m_cache_rate
		rates=$(_model_cost_rates "$model")
		m_input_rate=$(echo "$rates" | cut -d'|' -f1)
		m_output_rate=$(echo "$rates" | cut -d'|' -f2)
		m_cache_rate=$(echo "$rates" | cut -d'|' -f3)

		# Cache savings: what caching saved vs re-sending as full input
		# cache_read_tokens / 1M * (input_price - cache_read_price)
		# Use scale=6 in loop to avoid rounding error accumulation; round at display
		local row_cache_savings
		row_cache_savings=$(echo "scale=6; $cache / 1000000 * ($m_input_rate - $m_cache_rate)" | bc)
		total_cache_savings=$(echo "$total_cache_savings + $row_cache_savings" | bc)

		# Model routing savings: what using this model saved vs Opus
		# For each token type: (opus_rate - model_rate) * tokens / 1M
		# Opus rows produce $0 (same rates). Sonnet/Haiku produce large savings.
		local row_model_savings
		row_model_savings=$(echo "scale=6; ($opus_input_rate - $m_input_rate) * $input / 1000000 + ($opus_output_rate - $m_output_rate) * $output / 1000000 + ($opus_cache_rate - $m_cache_rate) * $cache / 1000000" | bc)
		total_model_savings=$(echo "$total_model_savings + $row_model_savings" | bc)

		local clean_model
		clean_model=$(_clean_model_name "$model")
		local f_requests f_input f_output f_cache
		f_requests=$(_format_number "$requests")
		f_input=$(_format_tokens "$input")
		f_output=$(_format_tokens "$output")
		f_cache=$(_format_tokens "$cache")

		# Format cost and both savings with 2 decimal places
		local f_cost f_csavings f_msavings
		f_cost=$(printf "%.2f" "$cost")
		f_csavings=$(printf "%.2f" "$row_cache_savings")
		f_msavings=$(printf "%.2f" "$row_model_savings")

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
	# Round costs and savings to 2 decimal places
	total_cost=$(printf "%.2f" "$total_cost")
	f_total_csavings=$(printf "%.2f" "$total_cache_savings")
	f_total_msavings=$(printf "%.2f" "$total_model_savings")

	# Combined savings for footer
	local combined_savings
	combined_savings=$(echo "$total_cache_savings + $total_model_savings" | bc)
	combined_savings=$(printf "%.2f" "$combined_savings")

	# Token totals for footer
	local all_tokens cache_pct
	all_tokens=$(echo "$token_totals" | jq -r '.total_all')
	cache_pct=$(echo "$token_totals" | jq -r '.cache_hit_pct')
	local f_all_tokens
	f_all_tokens=$(_format_tokens "$all_tokens")

	cat <<EOF

## AI Model Usage (last 30 days)

| Model | Requests | Input | Output | Cache read | Cost | Cache savings | Model savings |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
${model_rows}| **Total** | **${f_total_req}** | **${f_total_in}** | **${f_total_out}** | **${f_total_cache}** | **\$${total_cost}** | **\$${f_total_csavings}** | **\$${f_total_msavings}** |

_${f_all_tokens} total tokens processed. ${cache_pct}% cache hit rate. \$${combined_savings} total saved (\$${f_total_csavings} caching + \$${f_total_msavings} model routing vs all-Opus).
Model savings are modest because ~${cache_pct}% of tokens are cache reads, where price differences between models are small._
EOF

	# Build top apps table (macOS only — requires Knowledge DB)
	local top_apps_json
	top_apps_json=$(_get_top_apps)

	local app_count
	app_count=$(echo "$top_apps_json" | jq 'length')

	if [[ "$app_count" -gt 0 ]]; then
		local app_rows=""
		while IFS= read -r row; do
			local app today_pct week_pct month_pct
			app=$(echo "$row" | jq -r '.app')
			today_pct=$(echo "$row" | jq -r '.today_pct')
			week_pct=$(echo "$row" | jq -r '.week_pct')
			month_pct=$(echo "$row" | jq -r '.month_pct')

			# Show "--" for 0% (app not used in that period)
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
	fi

	return 0
}

# --- Map language name to shields.io badge ---
_lang_badge() {
	local lang="$1"
	case "$lang" in
	Shell) echo '![Shell](https://img.shields.io/badge/-Shell-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)' ;;
	TypeScript) echo '![TypeScript](https://img.shields.io/badge/-TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white)' ;;
	JavaScript) echo '![JavaScript](https://img.shields.io/badge/-JavaScript-F7DF1E?style=flat-square&logo=javascript&logoColor=black)' ;;
	Python) echo '![Python](https://img.shields.io/badge/-Python-3776AB?style=flat-square&logo=python&logoColor=white)' ;;
	Ruby) echo '![Ruby](https://img.shields.io/badge/-Ruby-CC342D?style=flat-square&logo=ruby&logoColor=white)' ;;
	Go) echo '![Go](https://img.shields.io/badge/-Go-00ADD8?style=flat-square&logo=go&logoColor=white)' ;;
	Rust) echo '![Rust](https://img.shields.io/badge/-Rust-000000?style=flat-square&logo=rust&logoColor=white)' ;;
	Java) echo '![Java](https://img.shields.io/badge/-Java-007396?style=flat-square&logo=openjdk&logoColor=white)' ;;
	PHP) echo '![PHP](https://img.shields.io/badge/-PHP-777BB4?style=flat-square&logo=php&logoColor=white)' ;;
	C) echo '![C](https://img.shields.io/badge/-C-A8B9CC?style=flat-square&logo=c&logoColor=black)' ;;
	"C++") echo '![C++](https://img.shields.io/badge/-C++-00599C?style=flat-square&logo=cplusplus&logoColor=white)' ;;
	"C#") echo '![C#](https://img.shields.io/badge/-C%23-239120?style=flat-square&logo=csharp&logoColor=white)' ;;
	Swift) echo '![Swift](https://img.shields.io/badge/-Swift-FA7343?style=flat-square&logo=swift&logoColor=white)' ;;
	Kotlin) echo '![Kotlin](https://img.shields.io/badge/-Kotlin-7F52FF?style=flat-square&logo=kotlin&logoColor=white)' ;;
	Dart) echo '![Dart](https://img.shields.io/badge/-Dart-0175C2?style=flat-square&logo=dart&logoColor=white)' ;;
	HTML) echo '![HTML](https://img.shields.io/badge/-HTML-E34F26?style=flat-square&logo=html5&logoColor=white)' ;;
	CSS) echo '![CSS](https://img.shields.io/badge/-CSS-1572B6?style=flat-square&logo=css3&logoColor=white)' ;;
	Lua) echo '![Lua](https://img.shields.io/badge/-Lua-2C2D72?style=flat-square&logo=lua&logoColor=white)' ;;
	Elixir) echo '![Elixir](https://img.shields.io/badge/-Elixir-4B275F?style=flat-square&logo=elixir&logoColor=white)' ;;
	Scala) echo '![Scala](https://img.shields.io/badge/-Scala-DC322F?style=flat-square&logo=scala&logoColor=white)' ;;
	Haskell) echo '![Haskell](https://img.shields.io/badge/-Haskell-5D4F85?style=flat-square&logo=haskell&logoColor=white)' ;;
	Vue) echo '![Vue](https://img.shields.io/badge/-Vue-4FC08D?style=flat-square&logo=vuedotjs&logoColor=white)' ;;
	Svelte) echo '![Svelte](https://img.shields.io/badge/-Svelte-FF3E00?style=flat-square&logo=svelte&logoColor=white)' ;;
	*) echo "![${lang}](https://img.shields.io/badge/-${lang// /%20}-555555?style=flat-square)" ;;
	esac
	return 0
}

# --- Sanitize a string for safe use in markdown ---
# Strips characters that could break markdown link/image syntax
_sanitize_md() {
	local input="$1"
	# Remove markdown-breaking characters: [ ] ( ) and backticks
	local sanitized
	sanitized="${input//[\[\]()]/}"
	sanitized="${sanitized//\`/}"
	echo "$sanitized"
	return 0
}

# --- Validate a URL for safe embedding in markdown ---
# Rejects javascript: URIs, non-http(s) schemes, and markdown-breaking chars
_sanitize_url() {
	local url="$1"
	# Must start with http:// or https:// (case-insensitive)
	local url_lower
	url_lower=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
	if [[ "$url_lower" != http://* && "$url_lower" != https://* ]]; then
		echo ""
		return 0
	fi
	# Reject URLs containing markdown-breaking characters or whitespace
	if [[ "$url" == *'('* || "$url" == *')'* || "$url" == *'['* || "$url" == *']'* || "$url" == *' '* ]]; then
		echo ""
		return 0
	fi
	echo "$url"
	return 0
}

# --- Generate rich profile README from GitHub data ---
_generate_rich_readme() {
	local gh_user="$1"
	local readme_path="$2"

	# Fetch user profile — single jq pass for all fields
	local user_json
	user_json=$(gh api "users/${gh_user}") || user_json="{}"
	local display_name bio blog twitter
	IFS=$'\t' read -r display_name bio blog twitter < <(
		echo "$user_json" | jq -r '[
			((.name // "") | gsub("[\\t\\n]"; " ")),
			((.bio // "") | gsub("[\\t\\n]"; " ")),
			(if .blog != null and .blog != "" then (.blog | gsub("[\\t\\n]"; "")) else "" end),
			(if .twitter_username != null and .twitter_username != "" then (.twitter_username | gsub("[\\t\\n]"; "")) else "" end)
		] | join("\t")' || printf '\t\t\t\n'
	)
	display_name="${display_name:-$gh_user}"

	# Sanitize user-controlled fields
	display_name=$(_sanitize_md "$display_name")
	bio=$(_sanitize_md "$bio")
	blog=$(_sanitize_url "$blog")
	# twitter is used as a path component, strip non-alphanumeric/underscore
	twitter="${twitter//[^a-zA-Z0-9_]/}"

	# Fetch repos and detect languages
	local repos_json
	repos_json=$(gh api "users/${gh_user}/repos?per_page=100&sort=updated" --paginate) || repos_json="[]"

	# Unique languages from all repos (sorted)
	local languages
	languages=$(echo "$repos_json" | jq -r '[.[].language | select(. != null)] | unique | .[]')

	# Build badge line
	local badges=""
	while IFS= read -r lang; do
		[[ -z "$lang" ]] && continue
		local badge
		badge=$(_lang_badge "$lang")
		badges="${badges}${badge}"$'\n'
	done <<<"$languages"
	# Always add common tooling badges
	badges="${badges}"'![Docker](https://img.shields.io/badge/-Docker-2496ED?style=flat-square&logo=docker&logoColor=white)'$'\n'
	badges="${badges}"'![Linux](https://img.shields.io/badge/-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)'$'\n'
	badges="${badges}"'![Git](https://img.shields.io/badge/-Git-F05032?style=flat-square&logo=git&logoColor=white)'$'\n'

	# Build own repos section — single jq pass (no loop)
	local own_repos
	own_repos=$(echo "$repos_json" | jq -r --arg user "$gh_user" '
		[.[] | select(.fork == false and .name != $user)] |
		map("- **[\(.name | gsub("[\\[\\]()`]"; ""))](\(.html_url))** -- \((.description // "No description") | gsub("[\\[\\]()`]"; ""))") |
		.[]
	')

	# Build contributions section — batch-fetch parent URLs for forks
	local fork_names
	fork_names=$(echo "$repos_json" | jq -r '.[] | select(.fork == true) | .name')
	local contrib_repos=""
	if [[ -n "$fork_names" ]]; then
		# Fetch all fork details in parallel (up to 6 concurrent) to get parent URLs
		local fork_details
		# Backticks in jq gsub pattern are literal, not shell expansion
		# shellcheck disable=SC2016
		fork_details=$(echo "$fork_names" | xargs -P 6 -I{} gh api "repos/${gh_user}/{}" --jq '
			"\(.name | gsub("[\\[\\]()`]"; ""))\t\((.description // "No description") | gsub("[\\t\\n]"; " ") | gsub("[\\[\\]()`]"; ""))\t\(.parent.html_url // .html_url)"
		' || true)
		while IFS=$'\t' read -r rname rdesc rurl; do
			[[ -z "$rname" ]] && continue
			# Names and descriptions already sanitized in jq above;
			# apply _sanitize_md as defense-in-depth for any residual chars
			rname=$(_sanitize_md "$rname")
			rdesc=$(_sanitize_md "$rdesc")
			# Validate fork URL before embedding in markdown
			rurl=$(_sanitize_url "$rurl")
			[[ -z "$rurl" ]] && continue
			contrib_repos="${contrib_repos}- **[${rname}](${rurl})** -- ${rdesc}"$'\n'
		done <<<"$fork_details"
	fi

	# Build connect section
	local connect=""
	if [[ -n "$blog" ]]; then
		local blog_display
		blog_display="${blog##*//}"
		blog_display=$(_sanitize_md "$blog_display")
		connect="${connect}[![Website](https://img.shields.io/badge/-${blog_display}-FF5722?style=flat-square&logo=hugo&logoColor=white)](${blog})"$'\n'
	fi
	if [[ -n "$twitter" ]]; then
		connect="${connect}[![X](https://img.shields.io/badge/-@${twitter}-000000?style=flat-square&logo=x&logoColor=white)](https://twitter.com/${twitter})"$'\n'
	fi
	connect="${connect}[![GitHub](https://img.shields.io/badge/-Follow-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/${gh_user})"$'\n'

	# Compose the README
	{
		echo "# ${display_name}"
		echo ""
		if [[ -n "$bio" ]]; then
			echo "**${bio}**"
			echo ""
		fi
		# Badges
		printf '%s' "$badges"
		echo ""
		echo "> Shipping with AI agents around the clock -- human hours for thinking, machine hours for doing."
		echo "> Stats auto-updated by [aidevops](https://aidevops.sh)."
		echo ""
		echo "<!-- STATS-START -->"
		echo "<!-- Stats will be populated on first update -->"
		echo "<!-- STATS-END -->"
		echo ""
		# Own repos
		if [[ -n "$own_repos" ]]; then
			echo "## Projects"
			echo ""
			printf '%s' "$own_repos"
			echo ""
		fi
		# Contributions
		if [[ -n "$contrib_repos" ]]; then
			echo "## Contributions"
			echo ""
			printf '%s' "$contrib_repos"
			echo ""
		fi
		# Connect
		echo "## Connect"
		echo ""
		printf '%s' "$connect"
		echo ""
		echo "---"
		echo ""
		echo "<!-- UPDATED-START -->"
		echo "<!-- UPDATED-END -->"
	} >"$readme_path"

	return 0
}

# --- Initialize profile README repo ---
# Creates the username/username GitHub repo if it doesn't exist, clones it,
# seeds a starter README with stat markers, and registers it in repos.json.
cmd_init() {
	# Require gh CLI
	if ! command -v gh &>/dev/null; then
		echo "Error: gh CLI required. Install from https://cli.github.com" >&2
		return 1
	fi

	# Get GitHub username
	local gh_user
	gh_user=$(gh api user --jq '.login' 2>/dev/null) || {
		echo "Error: not authenticated with gh CLI. Run 'gh auth login' first." >&2
		return 1
	}

	local repo_slug="${gh_user}/${gh_user}"
	local repo_dir="${HOME}/Git/${gh_user}"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Check if already initialized
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local existing_profile
		existing_profile=$(jq -r '
			if .initialized_repos then
				.initialized_repos[] | select(.priority == "profile") | .path
			else
				to_entries[] | select(.value.priority == "profile") | .value.path
			end
		' "$repos_json" 2>/dev/null | head -1)
		if [[ -n "$existing_profile" && "$existing_profile" != "null" ]]; then
			if [[ -d "$existing_profile" ]]; then
				echo "Profile repo already initialized at $existing_profile"
				return 0
			fi
		fi
	fi

	# Create the repo on GitHub if it doesn't exist
	if ! gh repo view "$repo_slug" &>/dev/null; then
		echo "Creating GitHub profile repo: $repo_slug"
		gh repo create "$repo_slug" --public --add-readme --description "GitHub profile README" || {
			echo "Error: failed to create repo $repo_slug" >&2
			return 1
		}
	else
		echo "GitHub repo $repo_slug already exists"
	fi

	# Clone if not already local
	if [[ ! -d "$repo_dir" ]]; then
		echo "Cloning $repo_slug to $repo_dir"
		git clone "git@github.com:${repo_slug}.git" "$repo_dir" 2>/dev/null ||
			git clone "https://github.com/${repo_slug}.git" "$repo_dir" || {
			echo "Error: failed to clone $repo_slug" >&2
			return 1
		}
	else
		echo "Local repo already exists at $repo_dir"
	fi

	# Seed README.md if it doesn't have stat markers
	local readme_path="${repo_dir}/README.md"
	if [[ ! -f "$readme_path" ]] || ! grep -q '<!-- STATS-START -->' "$readme_path"; then
		echo "Creating rich profile README..."
		_generate_rich_readme "$gh_user" "$readme_path"

		git -C "$repo_dir" add README.md
		git -C "$repo_dir" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
		git -C "$repo_dir" push origin main 2>/dev/null || git -C "$repo_dir" push origin master 2>/dev/null || {
			echo "Warning: failed to push initial README — push manually" >&2
		}
	fi

	# Register in repos.json
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Check if already registered
		local already_registered
		already_registered=$(jq -r --arg path "$repo_dir" '
			if .initialized_repos then
				[.initialized_repos[] | select(.path == $path)] | length
			else
				[to_entries[] | select(.value.path == $path)] | length
			end
		' "$repos_json" 2>/dev/null)

		if [[ "$already_registered" == "0" ]]; then
			echo "Registering profile repo in repos.json"
			local tmp_json
			tmp_json=$(mktemp)
			jq --arg path "$repo_dir" --arg slug "$repo_slug" '
				.initialized_repos += [{
					"path": $path,
					"slug": $slug,
					"priority": "profile",
					"pulse": false,
					"maintainer": ($slug | split("/")[0])
				}]
			' "$repos_json" >"$tmp_json" && mv "$tmp_json" "$repos_json"
		else
			# Ensure priority is set to "profile"
			local tmp_json
			tmp_json=$(mktemp)
			jq --arg path "$repo_dir" '
				.initialized_repos |= map(
					if .path == $path then .priority = "profile" else . end
				)
			' "$repos_json" >"$tmp_json" && mv "$tmp_json" "$repos_json"
		fi
	fi

	# Run first update
	echo "Running first stats update..."
	cmd_update

	echo ""
	echo "Profile README initialized at: https://github.com/${gh_user}"
	echo ""
	echo "IMPORTANT: To show this on your GitHub profile, visit:"
	echo "  https://github.com/${repo_slug}"
	echo "and click the 'Show on profile' button if prompted."
	echo ""
	echo "Stats will auto-update daily at 06:00 (configured by setup.sh)."

	return 0
}

# --- Update the profile README ---
cmd_update() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
	fi

	# Resolve profile repo
	local profile_repo
	profile_repo=$(_resolve_profile_repo) || return 1
	local readme_path="${profile_repo}/README.md"

	if [[ ! -f "$readme_path" ]]; then
		echo "Error: README.md not found at $readme_path" >&2
		return 1
	fi

	# Check for markers
	if ! grep -q '<!-- STATS-START -->' "$readme_path"; then
		echo "Error: <!-- STATS-START --> marker not found in $readme_path" >&2
		return 1
	fi
	if ! grep -q '<!-- STATS-END -->' "$readme_path"; then
		echo "Error: <!-- STATS-END --> marker not found in $readme_path" >&2
		return 1
	fi

	# Generate new stats
	local new_stats
	new_stats=$(cmd_generate)

	# Replace content between markers
	local tmp_file
	tmp_file=$(mktemp)

	# Use awk to replace between markers (bash 3.2 compatible)
	awk '
		/<!-- STATS-START -->/ {
			print "<!-- STATS-START -->"
			skip = 1
			next
		}
		/<!-- STATS-END -->/ {
			skip = 0
			# Print the new stats (will be injected via variable)
			print ENVIRON["NEW_STATS"]
			print "<!-- STATS-END -->"
			next
		}
		!skip { print }
	' "$readme_path" >"$tmp_file"

	# Inject the stats via env var and re-run
	NEW_STATS="$new_stats" awk '
		/<!-- STATS-START -->/ {
			print "<!-- STATS-START -->"
			skip = 1
			next
		}
		/<!-- STATS-END -->/ {
			skip = 0
			printf "%s\n", ENVIRON["NEW_STATS"]
			print "<!-- STATS-END -->"
			next
		}
		!skip { print }
	' "$readme_path" >"$tmp_file"

	# Update timestamp if markers exist
	if grep -q '<!-- UPDATED-START -->' "$readme_path"; then
		local updated_at
		updated_at=$(date -u +"%Y-%m-%d %H:%M UTC")
		local updated_tmp
		updated_tmp=$(mktemp)
		awk -v ts="$updated_at" '
			/<!-- UPDATED-START -->/ {
				print "<!-- UPDATED-START -->"
				skip = 1
				next
			}
			/<!-- UPDATED-END -->/ {
				skip = 0
				printf "_Stats auto-updated %s by [aidevops](https://aidevops.sh) pulse._\n", ts
				print "<!-- UPDATED-END -->"
				next
			}
			!skip { print }
		' "$tmp_file" >"$updated_tmp"
		mv "$updated_tmp" "$tmp_file"
	fi

	if [[ "$dry_run" == true ]]; then
		echo "--- DRY RUN: would write to $readme_path ---"
		diff "$readme_path" "$tmp_file" || true
		rm -f "$tmp_file"
		return 0
	fi

	# Check if content actually changed (ignore timestamp-only changes)
	local old_stats new_stats_check
	old_stats=$(awk '/<!-- STATS-START -->/{f=1;next}/<!-- STATS-END -->/{f=0}f' "$readme_path")
	new_stats_check=$(awk '/<!-- STATS-START -->/{f=1;next}/<!-- STATS-END -->/{f=0}f' "$tmp_file")

	if [[ "$old_stats" == "$new_stats_check" ]]; then
		echo "No changes to stats — skipping commit"
		rm -f "$tmp_file"
		return 0
	fi

	# Apply changes
	mv "$tmp_file" "$readme_path"

	# Commit and push
	local commit_msg
	commit_msg="chore: update profile stats ($(date -u +%Y-%m-%d))"
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "$commit_msg" --no-verify 2>/dev/null || {
		echo "No changes to commit"
		return 0
	}
	git -C "$profile_repo" push origin main 2>/dev/null || {
		echo "Warning: push failed — changes committed locally" >&2
		return 0
	}

	echo "Profile README updated and pushed"
	return 0
}

# --- Main dispatch ---
case "${1:-help}" in
init) cmd_init ;;
generate) cmd_generate ;;
update)
	shift
	cmd_update "$@"
	;;
help | *)
	echo "Usage: profile-readme-helper.sh {init|update [--dry-run]|generate|help}"
	echo ""
	echo "Commands:"
	echo "  init                Create profile repo, seed README, register in repos.json"
	echo "  update [--dry-run]  Update profile README with live stats and push"
	echo "  generate            Print generated stats section to stdout"
	echo "  help                Show this help"
	;;
esac
