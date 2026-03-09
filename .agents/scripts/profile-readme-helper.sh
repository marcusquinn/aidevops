#!/usr/bin/env bash
# profile-readme-helper.sh — Auto-update GitHub profile README with live stats
#
# Usage:
#   profile-readme-helper.sh update [--dry-run]   # Update README with live data
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
	screen_json=$("${SCRIPT_DIR}/screen-time-helper.sh" profile-stats 2>/dev/null) || screen_json="{}"
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

| Metric | Today | 7 Days | 28 Days | 365 Days |
| --- | ---: | ---: | ---: | ---: |
| ${screen_label} | ${screen_today}h | ${screen_week}h | ${f_screen_month}h | ${year_prefix}${f_screen_year}h${year_suffix} |
| User AI session hours | ${day_human}h | ${week_human}h | ${month_human}h | ${year_human}h |
| AI worker hours | ${day_worker}h | ${week_worker}h | ${month_worker}h | ${year_worker}h |
| Total AI work | ${day_total}h | ${week_total}h | ${f_month_total}h | ${f_year_total}h |
| Interactive sessions | ${f_day_int} | ${f_week_int} | ${f_month_int} | ${f_year_int} |
| Worker sessions | ${f_day_wrk} | ${f_week_wrk} | ${f_month_wrk} | ${f_year_wrk} |

_Screen time from ${screen_source}, snapshotted daily.$([ -n "$year_suffix" ] && echo " *365-day extrapolated (accumulating real data).")_
_User AI session hours measured from AI message timestamps (reading, thinking, typing between responses)._
EOF

	# Build model usage table
	local total_requests=0 total_input=0 total_output=0 total_cache=0 total_cost=0
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

		local clean_model
		clean_model=$(_clean_model_name "$model")
		local f_requests f_input f_output f_cache
		f_requests=$(_format_number "$requests")
		f_input=$(_format_tokens "$input")
		f_output=$(_format_tokens "$output")
		f_cache=$(_format_tokens "$cache")

		# Format cost with 2 decimal places
		local f_cost
		f_cost=$(printf "%.2f" "$cost")

		model_rows="${model_rows}| ${clean_model} | ${f_requests} | ${f_input} | ${f_output} | ${f_cache} | \$${f_cost} |
"
	done < <(echo "$model_json" | jq -c '.[] | select(.cost_total >= 0.05)')

	# Format totals
	local f_total_req f_total_in f_total_out f_total_cache
	f_total_req=$(_format_number "$total_requests")
	f_total_in=$(_format_tokens "$total_input")
	f_total_out=$(_format_tokens "$total_output")
	f_total_cache=$(_format_tokens "$total_cache")
	# Round total_cost to 2 decimal places
	total_cost=$(printf "%.2f" "$total_cost")

	# Token totals for footer
	local all_tokens cache_pct
	all_tokens=$(echo "$token_totals" | jq -r '.total_all')
	cache_pct=$(echo "$token_totals" | jq -r '.cache_hit_pct')
	local f_all_tokens
	f_all_tokens=$(_format_tokens "$all_tokens")

	# Calculate cost reduction percentage
	local cost_reduction
	if command -v bc >/dev/null 2>&1; then
		cost_reduction=$(echo "scale=0; 100 - (100 * (100 - $cache_pct) / 100)" | bc 2>/dev/null || echo "$cache_pct")
	else
		cost_reduction="$cache_pct"
	fi

	cat <<EOF

## AI Model Usage (last 30 days)

| Model | Requests | Input | Output | Cache read | Cost |
| --- | ---: | ---: | ---: | ---: | ---: |
${model_rows}| **Total** | **${f_total_req}** | **${f_total_in}** | **${f_total_out}** | **${f_total_cache}** | **\$${total_cost}** |

_${f_all_tokens} total tokens processed. Cache hit rate: ${cache_pct}% -- prompt caching reduces cost by ~${cost_reduction}% vs uncached._
EOF

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
				printf "_Stats auto-updated %s by [aidevops](https://github.com/marcusquinn/aidevops) pulse._\n", ts
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
generate) cmd_generate ;;
update)
	shift
	cmd_update "$@"
	;;
help | *)
	echo "Usage: profile-readme-helper.sh {update [--dry-run]|generate|help}"
	echo ""
	echo "Commands:"
	echo "  update [--dry-run]  Update profile README with live stats and push"
	echo "  generate            Print generated stats section to stdout"
	echo "  help                Show this help"
	;;
esac
