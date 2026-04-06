#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
OBS_DB_FILE="${HOME}/.aidevops/.agent-workspace/observability/llm-requests.db"
OPENCODE_DB_FILE="${HOME}/.local/share/opencode/opencode.db"
OPENCODE_ARCHIVE_DB_FILE="${HOME}/.local/share/opencode/opencode-archive.db"

# --- Resolve profile repo path from repos.json ---
_resolve_profile_repo() {
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Try repos.json first (primary lookup)
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local profile_path
		profile_path=$(jq -r '
			(.initialized_repos // (to_entries | map(.value)))[]
			| select(.priority == "profile")
			| .path // empty
		' "$repos_json" | head -1)

		if [[ -n "$profile_path" && -d "$profile_path" ]]; then
			echo "$profile_path"
			return 0
		fi
	fi

	# Self-healing fallback: find profile repo by convention (~/Git/$username).
	# This handles the case where cmd_init created the repo but repos.json
	# registration failed or was lost. The hourly update job would otherwise
	# silently fail forever.
	local gh_user=""
	if command -v gh &>/dev/null; then
		gh_user=$(gh api user --jq '.login' 2>/dev/null) || true
	fi
	if [[ -z "$gh_user" ]]; then
		echo "Error: no profile repo in repos.json and gh CLI unavailable for fallback" >&2
		return 1
	fi

	local convention_path="${HOME}/Git/${gh_user}"
	if [[ -d "$convention_path" ]] && [[ -f "${convention_path}/README.md" ]]; then
		# Found it — auto-register in repos.json so future lookups are fast.
		# Don't require markers — cmd_init/cmd_update will inject them if missing.
		echo "Auto-registering profile repo at $convention_path" >&2
		if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
			local tmp_json
			tmp_json=$(mktemp)
			if jq --arg path "$convention_path" --arg slug "${gh_user}/${gh_user}" '
				.initialized_repos += [{
					"path": $path,
					"slug": $slug,
					"priority": "profile",
					"pulse": false,
					"maintainer": ($slug | split("/")[0])
				}]
			' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
				mv "$tmp_json" "$repos_json"
			else
				echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
				rm -f "$tmp_json"
			fi
		fi
		echo "$convention_path"
		return 0
	fi

	# Last resort: try cmd_init to create/clone/register everything
	if command -v gh &>/dev/null && gh auth status &>/dev/null; then
		echo "No profile repo found — running init to create one" >&2
		if cmd_init >&2; then
			# Re-resolve after init
			local init_path="${HOME}/Git/${gh_user}"
			if [[ -d "$init_path" ]]; then
				echo "$init_path"
				return 0
			fi
		fi
	fi

	echo "Error: no profile repo found and could not auto-create one" >&2
	return 1
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

# --- Format dollar amount with commas and 2 decimal places ---
_format_cost() {
	local val="$1"
	local rounded
	rounded=$(printf "%.2f" "$val")
	_format_number "$rounded"
	return 0
}

# --- Format token count (K/M suffix, with comma thousands separators) ---
_format_tokens() {
	local tokens="$1"
	if [[ "$tokens" -ge 1000000 ]]; then
		local m
		m=$(echo "scale=1; $tokens / 1000000" | bc)
		local formatted
		formatted=$(_format_number "$m")
		echo "${formatted}M"
	elif [[ "$tokens" -ge 1000 ]]; then
		local k
		k=$(echo "scale=0; $tokens / 1000" | bc)
		local formatted
		formatted=$(_format_number "$k")
		echo "${formatted}K"
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
	# GH#17550: Use --all-dirs to aggregate sessions across all repos/directories.
	# The profile README is a user-level summary — not per-repo.
	# The DB is global; filtering by a single repo path missed 99%+ of sessions.
	session_json=$("${SCRIPT_DIR}/contributor-activity-helper.sh" session-time \
		--all-dirs --period "$period" --format json 2>/dev/null) || session_json="{}"
	echo "$session_json"
	return 0
}

# --- Compute cost from token counts using _model_cost_rates ---
# Takes JSON array with model/input_tokens/output_tokens/cache_read_tokens,
# adds cost_total field computed from pricing table, sorts by cost desc.
_compute_costs_from_tokens() {
	local raw_json="$1"
	local result="[]"

	while IFS= read -r row; do
		local model input output cache
		model=$(echo "$row" | jq -r '.model')
		input=$(echo "$row" | jq -r '.input_tokens')
		output=$(echo "$row" | jq -r '.output_tokens')
		cache=$(echo "$row" | jq -r '.cache_read_tokens')

		local rates m_input_rate m_output_rate m_cache_rate
		rates=$(_model_cost_rates "$model")
		m_input_rate=$(echo "$rates" | cut -d'|' -f1)
		m_output_rate=$(echo "$rates" | cut -d'|' -f2)
		m_cache_rate=$(echo "$rates" | cut -d'|' -f3)

		local cost
		cost=$(echo "scale=2; $m_input_rate * $input / 1000000 + $m_output_rate * $output / 1000000 + $m_cache_rate * $cache / 1000000" | bc)

		result=$(echo "$result" | jq --argjson row "$row" --argjson cost "$cost" \
			'. + [$row + {cost_total: $cost}]')
	done < <(echo "$raw_json" | jq -c '.[]')

	echo "$result" | jq -c 'sort_by(-.cost_total)'
	return 0
}

# --- Gather model usage from OpenCode session DB (full history) ---
# Returns JSON array with cost_total computed, or empty string if unavailable.
_get_model_usage_from_opencode() {
	if ! command -v sqlite3 &>/dev/null || [[ ! -f "$OPENCODE_DB_FILE" ]]; then
		echo ""
		return 0
	fi

	local raw_json
	# GH#17549: Query both active and archive DBs for all-time stats.
	# The archive DB contains sessions >14 days old, moved by opencode-db-archive.sh.
	local attach_clause=""
	local union_clause=""
	if [[ -f "$OPENCODE_ARCHIVE_DB_FILE" ]]; then
		attach_clause="ATTACH DATABASE '${OPENCODE_ARCHIVE_DB_FILE}' AS archive;"
		union_clause="UNION ALL
			SELECT
				json_extract(data, '\$.modelID') AS model,
				COUNT(*) AS requests,
				COALESCE(SUM(json_extract(data, '\$.tokens.input')), 0) AS input_tokens,
				COALESCE(SUM(json_extract(data, '\$.tokens.output')), 0) AS output_tokens,
				COALESCE(SUM(json_extract(data, '\$.tokens.cache.read')), 0) AS cache_read_tokens,
				COALESCE(SUM(json_extract(data, '\$.tokens.cache.write')), 0) AS cache_write_tokens
			FROM archive.message
			WHERE json_extract(data, '\$.role') = 'assistant'
			  AND json_extract(data, '\$.modelID') IS NOT NULL
			  AND json_extract(data, '\$.modelID') != ''
			GROUP BY model"
	fi
	raw_json=$(sqlite3 "$OPENCODE_DB_FILE" "
		${attach_clause}
		SELECT COALESCE(
			json_group_array(
				json_object(
					'model', model,
					'requests', requests,
					'input_tokens', input_tokens,
					'output_tokens', output_tokens,
					'cache_read_tokens', cache_read_tokens,
					'cache_write_tokens', cache_write_tokens
				)
			),
			'[]'
		)
		FROM (
			SELECT model, SUM(requests) AS requests,
				SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
				SUM(cache_read_tokens) AS cache_read_tokens, SUM(cache_write_tokens) AS cache_write_tokens
			FROM (
				SELECT
					json_extract(data, '\$.modelID') AS model,
					COUNT(*) AS requests,
					COALESCE(SUM(json_extract(data, '\$.tokens.input')), 0) AS input_tokens,
					COALESCE(SUM(json_extract(data, '\$.tokens.output')), 0) AS output_tokens,
					COALESCE(SUM(json_extract(data, '\$.tokens.cache.read')), 0) AS cache_read_tokens,
					COALESCE(SUM(json_extract(data, '\$.tokens.cache.write')), 0) AS cache_write_tokens
				FROM message
				WHERE json_extract(data, '\$.role') = 'assistant'
				  AND json_extract(data, '\$.modelID') IS NOT NULL
				  AND json_extract(data, '\$.modelID') != ''
				GROUP BY model
				${union_clause}
			)
			GROUP BY model
		);
	" 2>/dev/null || true)

	if [[ -z "$raw_json" ]] || [[ "$raw_json" == "[]" ]]; then
		echo ""
		return 0
	fi

	# Merge model variants (e.g., claude-opus-4-5-20251101 -> claude-opus-4-5)
	local merged_json
	merged_json=$(echo "$raw_json" | jq -c '
		[.[] | .model = (.model | gsub("-[0-9]{8}$"; ""))]
		| group_by(.model)
		| map({
			model: .[0].model,
			requests: ([.[].requests] | add),
			input_tokens: ([.[].input_tokens] | add),
			output_tokens: ([.[].output_tokens] | add),
			cache_read_tokens: ([.[].cache_read_tokens] | add),
			cache_write_tokens: ([.[].cache_write_tokens] | add)
		})
	')
	_compute_costs_from_tokens "$merged_json"
	return 0
}

# --- Gather model usage from observability DB (accurate cost data) ---
# date_filter: optional SQL WHERE clause fragment (e.g. "AND timestamp >= ...")
# Returns JSON array or empty string if unavailable.
_get_model_usage_from_obs_db() {
	local date_filter="${1:-}"

	if ! command -v sqlite3 &>/dev/null || [[ ! -f "$OBS_DB_FILE" ]]; then
		echo ""
		return 0
	fi

	local sqlite_json
	sqlite_json=$(sqlite3 "$OBS_DB_FILE" "
		SELECT COALESCE(
			json_group_array(
				json_object(
					'model', model_id,
					'requests', requests,
					'input_tokens', input_tokens,
					'output_tokens', output_tokens,
					'cache_read_tokens', cache_read_tokens,
					'cache_write_tokens', cache_write_tokens,
					'cost_total', ROUND(cost_total, 2)
				)
			),
			'[]'
		)
		FROM (
			SELECT
				model_id,
				COUNT(*) AS requests,
				COALESCE(SUM(tokens_input), 0) AS input_tokens,
				COALESCE(SUM(tokens_output), 0) AS output_tokens,
				COALESCE(SUM(tokens_cache_read), 0) AS cache_read_tokens,
				COALESCE(SUM(tokens_cache_write), 0) AS cache_write_tokens,
				COALESCE(SUM(cost), 0.0) AS cost_total
			FROM llm_requests
			WHERE model_id IS NOT NULL
			  AND model_id != ''
			  ${date_filter}
			GROUP BY model_id
			ORDER BY cost_total DESC
		);
	" 2>/dev/null || true)

	if [[ -n "$sqlite_json" ]]; then
		echo "$sqlite_json" | jq -c '.' 2>/dev/null || echo "[]"
	else
		echo ""
	fi
	return 0
}

# --- Gather model usage stats ---
# Usage: _get_model_usage [period]
#   period: "30d" (default) or "all" (no date filter)
_get_model_usage() {
	local period="${1:-30d}"

	# For "all" period, use OpenCode session DB (has full history back to first use).
	# The observability DB (llm-requests.db) only has data from when it was created.
	if [[ "$period" == "all" ]]; then
		local oc_result
		oc_result=$(_get_model_usage_from_opencode)
		if [[ -n "$oc_result" ]]; then
			echo "$oc_result"
			return 0
		fi
	fi

	# For 30d or fallback: use observability DB (has accurate cost data).
	local date_filter=""
	if [[ "$period" != "all" ]]; then
		date_filter="AND timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')"
	fi

	local obs_result
	obs_result=$(_get_model_usage_from_obs_db "$date_filter")
	if [[ -n "$obs_result" ]]; then
		echo "$obs_result"
		return 0
	fi

	# Legacy fallback: JSONL metrics file.
	if [[ ! -f "$METRICS_FILE" ]]; then
		echo "[]"
		return 0
	fi

	if [[ "$period" == "all" ]]; then
		jq -s '
			group_by(.model)
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
	else
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
	fi

	return 0
}

# --- Get total token stats for footer ---
# Usage: _get_token_totals [period]
#   period: "30d" (default) or "all" (no date filter)
_get_token_totals() {
	local period="${1:-30d}"

	local jq_totals='
		. + {total_all: (.total_input + .total_output + .total_cache_read + .total_cache_write)}
		| . + {cache_hit_pct: (if .total_all > 0 then ((.total_cache_read / .total_all * 1000 | round) / 10) else 0 end)}
	'

	# For "all" period, use OpenCode session DB (full history).
	# GH#17549: Query both active and archive DBs for complete totals.
	if [[ "$period" == "all" ]] && command -v sqlite3 &>/dev/null && [[ -f "$OPENCODE_DB_FILE" ]]; then
		local oc_totals _totals_attach="" _totals_union=""
		if [[ -f "$OPENCODE_ARCHIVE_DB_FILE" ]]; then
			_totals_attach="ATTACH DATABASE '${OPENCODE_ARCHIVE_DB_FILE}' AS archive;"
			_totals_union="UNION ALL
				SELECT json_extract(data, '\$.tokens.input'),
					json_extract(data, '\$.tokens.output'),
					json_extract(data, '\$.tokens.cache.read'),
					json_extract(data, '\$.tokens.cache.write')
				FROM archive.message
				WHERE json_extract(data, '\$.role') = 'assistant'"
		fi
		oc_totals=$(sqlite3 "$OPENCODE_DB_FILE" "
			${_totals_attach}
			SELECT json_object(
				'total_input', COALESCE(SUM(ti), 0),
				'total_output', COALESCE(SUM(to2), 0),
				'total_cache_read', COALESCE(SUM(cr), 0),
				'total_cache_write', COALESCE(SUM(cw), 0)
			)
			FROM (
				SELECT json_extract(data, '\$.tokens.input') AS ti,
					json_extract(data, '\$.tokens.output') AS to2,
					json_extract(data, '\$.tokens.cache.read') AS cr,
					json_extract(data, '\$.tokens.cache.write') AS cw
				FROM message
				WHERE json_extract(data, '\$.role') = 'assistant'
				${_totals_union}
			);
		" 2>/dev/null || true)

		if [[ -n "$oc_totals" ]]; then
			echo "$oc_totals" | jq -c "$jq_totals" 2>/dev/null || echo '{"total_all":0,"cache_hit_pct":0}'
			return 0
		fi
	fi

	# For 30d or fallback: use observability DB.
	local date_filter=""
	if [[ "$period" != "all" ]]; then
		date_filter="WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')"
	fi

	if command -v sqlite3 &>/dev/null && [[ -f "$OBS_DB_FILE" ]]; then
		local sqlite_totals
		sqlite_totals=$(sqlite3 "$OBS_DB_FILE" "
			SELECT json_object(
				'total_input', COALESCE(SUM(tokens_input), 0),
				'total_output', COALESCE(SUM(tokens_output), 0),
				'total_cache_read', COALESCE(SUM(tokens_cache_read), 0),
				'total_cache_write', COALESCE(SUM(tokens_cache_write), 0)
			)
			FROM llm_requests
			${date_filter};
		" 2>/dev/null || true)

		if [[ -n "$sqlite_totals" ]]; then
			echo "$sqlite_totals" | jq -c "$jq_totals" 2>/dev/null || echo '{"total_all":0,"cache_hit_pct":0}'
			return 0
		fi
	fi

	# Legacy fallback: JSONL metrics file.
	if [[ ! -f "$METRICS_FILE" ]]; then
		echo '{"total_all":0,"cache_hit_pct":0}'
		return 0
	fi

	if [[ "$period" == "all" ]]; then
		jq -s '
			{
				total_input: ([.[].input_tokens // 0] | add),
				total_output: ([.[].output_tokens // 0] | add),
				total_cache_read: ([.[].cache_read_tokens // 0] | add),
				total_cache_write: ([.[].cache_write_tokens // 0] | add)
			}
			| . + {total_all: (.total_input + .total_output + .total_cache_read + .total_cache_write)}
			| . + {cache_hit_pct: (if .total_all > 0 then ((.total_cache_read / .total_all * 1000 | round) / 10) else 0 end)}
		' "$METRICS_FILE" 2>/dev/null || echo '{"total_all":0,"cache_hit_pct":0}'
	else
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
	fi

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
	*gpt-5.4*) echo "2.50|10.0|0.625" ;;
	*gpt-5.3-codex*) echo "2.50|10.0|0.625" ;;
	*gpt-5.2-codex* | *gpt-5.2*) echo "2.50|10.0|0.625" ;;
	*gpt-5.1-codex*) echo "2.50|10.0|0.625" ;;
	*gpt-5.1-chat*) echo "2.50|10.0|0.625" ;;
	*gpt-4.1-mini*) echo "0.40|1.60|0.10" ;;
	*gpt-4.1*) echo "2.0|8.0|0.50" ;;
	*o3*) echo "10.0|40.0|2.50" ;;
	*o4-mini*) echo "1.10|4.40|0.275" ;;
	*gemini-2.5-pro* | *gemini-3-pro*) echo "1.25|10.0|0.3125" ;;
	*gemini-2.5-flash* | *gemini-3-flash*) echo "0.15|0.60|0.0375" ;;
	*deepseek-r1*) echo "0.55|2.19|0.14" ;;
	*deepseek-v3*) echo "0.27|1.10|0.07" ;;
	*grok*) echo "3.0|15.0|0.30" ;;
	*kimi* | *minimax* | *big-pickle*) echo "0.0|0.0|0.0" ;;
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

# --- Compute per-row cache and model-routing savings ---
# Usage: _compute_model_row_savings <model> <input_tokens> <output_tokens> <cache_tokens>
# Prints: cache_savings|model_savings  (scale=6 for accumulation accuracy)
_compute_model_row_savings() {
	local model="$1"
	local input="$2"
	local output="$3"
	local cache="$4"

	# Opus rates used as baseline for model routing savings
	local opus_input_rate="15.0" opus_output_rate="75.0" opus_cache_rate="1.50"

	local rates m_input_rate m_output_rate m_cache_rate
	rates=$(_model_cost_rates "$model")
	m_input_rate=$(echo "$rates" | cut -d'|' -f1)
	m_output_rate=$(echo "$rates" | cut -d'|' -f2)
	m_cache_rate=$(echo "$rates" | cut -d'|' -f3)

	local row_cache_savings row_model_savings
	row_cache_savings=$(echo "scale=6; $cache / 1000000 * ($m_input_rate - $m_cache_rate)" | bc)
	row_model_savings=$(echo "scale=6; ($opus_input_rate - $m_input_rate) * $input / 1000000 + ($opus_output_rate - $m_output_rate) * $output / 1000000 + ($opus_cache_rate - $m_cache_rate) * $cache / 1000000" | bc)

	echo "${row_cache_savings}|${row_model_savings}"
	return 0
}

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

# --- Resolve GitHub username for profile repo ---
_resolve_profile_user() {
	local profile_repo="$1"

	# Try origin remote first (owner/repo)
	local origin_url
	origin_url=$(git -C "$profile_repo" remote get-url origin 2>/dev/null || true)
	if [[ -n "$origin_url" ]]; then
		local slug
		slug=$(echo "$origin_url" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
		local owner repo
		owner="${slug%%/*}"
		repo="${slug##*/}"
		if [[ -n "$owner" && "$owner" == "$repo" ]]; then
			echo "$owner"
			return 0
		fi
	fi

	# Fallback to directory basename
	local base
	base=$(basename "$profile_repo")
	if [[ -n "$base" ]]; then
		echo "$base"
		return 0
	fi

	echo ""
	return 0
}

# --- Normalize README for no-op comparison ---
# Strips UPDATED and CONTRIBUTIONS blocks so timestamp/contribution changes
# don't suppress real stats diffs (and vice versa).
_normalize_readme_for_compare() {
	local file="$1"
	awk '
		/<!-- UPDATED-START -->/ { print; skip = 1; next }
		/<!-- UPDATED-END -->/ { skip = 0; print; next }
		/<!-- CONTRIBUTIONS-START -->/ { print; skip = 1; next }
		/<!-- CONTRIBUTIONS-END -->/ { skip = 0; print; next }
		!skip { print }
	' "$file"
	return 0
}

# --- Generate contributions list from forks + repos.json contributed entries ---
# Outputs markdown lines (one per contributed repo), or empty string if none.
# Uses core API only (no search API) — ~11 calls per run.
# Deduplicates across all sources using a newline-delimited "seen" list with
# exact matching (bash 3.2 compatible — no associative arrays).
_generate_contributions() {
	local gh_user="$1"
	local contrib_repos=""
	# Newline-delimited list of repo names already added (for O(1)-ish dedup).
	# Each entry is stored as a full line for exact grep -x matching, avoiding
	# false positives from partial name matches (e.g., "app" vs "webapp").
	local seen_repos=""

	# Source 1: forks — resolve parent URLs
	local repos_json
	repos_json=$(gh api "users/${gh_user}/repos?per_page=100&sort=updated" --paginate 2>/dev/null) || repos_json="[]"

	local fork_names
	fork_names=$(echo "$repos_json" | jq -r '.[] | select(.fork == true) | .name')
	if [[ -n "$fork_names" ]]; then
		local fork_details
		# shellcheck disable=SC2016
		fork_details=$(echo "$fork_names" | xargs -P 6 -I{} gh api "repos/${gh_user}/{}" --jq '
			"\(.name | gsub("[\\[\\]()`]"; ""))\t\((.description // "No description") | gsub("[\\t\\n]"; " ") | gsub("[\\[\\]()`]"; ""))\t\(.parent.html_url // .html_url)"
		' 2>/dev/null || true)
		while IFS=$'\t' read -r rname rdesc rurl; do
			[[ -z "$rname" ]] && continue
			# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
			local _saved_ifs="$IFS"
			IFS=$' \t\n'
			# Deduplicate within forks (xargs -P can return duplicates)
			if [[ -n "$seen_repos" ]] && grep -qxF "$rname" <<<"$seen_repos" 2>/dev/null; then
				IFS="$_saved_ifs"
				continue
			fi
			rname=$(_sanitize_md "$rname")
			rdesc=$(_sanitize_md "$rdesc")
			rurl=$(_sanitize_url "$rurl")
			IFS="$_saved_ifs"
			[[ -z "$rurl" ]] && continue
			seen_repos="${seen_repos}${rname}"$'\n'
			contrib_repos="${contrib_repos}- **[${rname}](${rurl})** -- ${rdesc}"$'\n'
		done <<<"$fork_details"
	fi

	# Source 2: repos.json "contributed: true" entries (non-fork contributions)
	local repos_config="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_config" ]] && command -v jq &>/dev/null; then
		local contributed_slugs
		contributed_slugs=$(jq -r '
			(.initialized_repos // (to_entries | map(.value)))[]
			| select(.contributed == true)
			| .slug // empty
		' "$repos_config" 2>/dev/null || true)

		while IFS= read -r slug; do
			[[ -z "$slug" ]] && continue
			local repo_name
			repo_name="${slug##*/}"
			# Deduplicate against all previously seen repos (forks + earlier entries)
			if [[ -n "$seen_repos" ]] && grep -qxF "$repo_name" <<<"$seen_repos" 2>/dev/null; then
				continue
			fi
			# Fetch description from GitHub API (1 call per contributed repo)
			local desc
			desc=$(gh api "repos/${slug}" --jq '.description // "No description"' 2>/dev/null || echo "No description")
			desc=$(_sanitize_md "$desc")
			local url="https://github.com/${slug}"
			repo_name=$(_sanitize_md "$repo_name")
			seen_repos="${seen_repos}${repo_name}"$'\n'
			contrib_repos="${contrib_repos}- **[${repo_name}](${url})** -- ${desc}"$'\n'
		done <<<"$contributed_slugs"
	fi

	# Sort alphabetically for deterministic output (prevents unnecessary commits
	# when the API returns results in a different order)
	if [[ -n "$contrib_repos" ]]; then
		contrib_repos=$(printf '%s' "$contrib_repos" | sort -f)
		# Ensure trailing newline
		contrib_repos="${contrib_repos}"$'\n'
	fi

	printf '%s' "$contrib_repos"
	return 0
}

# --- Detect if a README is the default GitHub profile template ---
# Returns 0 (true) if the file matches the default template pattern.
# The default template contains "## Hi there" and the commented-out suggestions
# block that GitHub auto-generates for new username/username repos.
_is_default_github_template() {
	local readme_path="$1"
	if [[ ! -f "$readme_path" ]]; then
		return 1
	fi
	# Check for the distinctive GitHub default template markers:
	# 1. The "Hi there" heading (with or without emoji)
	# 2. The commented-out "is a special repository" block
	if grep -q 'Hi there' "$readme_path" 2>/dev/null &&
		grep -q 'is a.*special.*repository' "$readme_path" 2>/dev/null; then
		return 0
	fi
	# Also match minimal default READMEs that just have "# username" and nothing else
	local line_count
	line_count=$(wc -l <"$readme_path" | tr -d ' ')
	if [[ "$line_count" -le 3 ]] && ! grep -q '<!-- STATS-START -->' "$readme_path" 2>/dev/null; then
		return 0
	fi
	return 1
}

# --- Inject aidevops markers into an existing README that lacks them ---
# Preserves all existing content and appends marker blocks at the end.
# This handles the case where a user has manually written their README
# (or GitHub created the default template) and we need to add our stats.
_inject_markers_into_readme() {
	local readme_path="$1"
	local tmp_file
	tmp_file=$(mktemp)

	# Copy existing content
	cat "$readme_path" >"$tmp_file"

	# Ensure trailing newline before appending
	if [[ -s "$tmp_file" ]] && [[ "$(tail -c 1 "$tmp_file" | wc -l)" -eq 0 ]]; then
		echo "" >>"$tmp_file"
	fi

	# Append marker blocks
	{
		echo ""
		echo "<!-- STATS-START -->"
		echo "<!-- Stats will be populated on next update -->"
		echo "<!-- STATS-END -->"
		echo ""
		echo "<!-- CONTRIBUTIONS-START -->"
		echo "<!-- CONTRIBUTIONS-END -->"
		echo ""
		echo "---"
		echo ""
		echo "<!-- UPDATED-START -->"
		echo "<!-- UPDATED-END -->"
	} >>"$tmp_file"

	mv "$tmp_file" "$readme_path"
	return 0
}

# --- Recover from diverged git history on the profile repo ---
# When the remote repo was deleted and recreated, the local clone has a
# different history. This function re-clones the repo and re-seeds the README.
_recover_diverged_profile() {
	local repo_dir="$1"
	local repo_slug="$2"
	local default_branch="$3"
	local gh_user="$4"

	echo "Recovering profile repo from diverged history..." >&2

	# Back up the local directory and re-clone
	local backup_dir="${repo_dir}.bak.$$"
	mv "$repo_dir" "$backup_dir"

	if git clone "git@github.com:${repo_slug}.git" "$repo_dir" 2>/dev/null ||
		git clone "https://github.com/${repo_slug}.git" "$repo_dir" 2>/dev/null; then
		# Re-seed the README with markers
		local readme_path="${repo_dir}/README.md"
		if [[ -f "$readme_path" ]] && grep -q '<!-- STATS-START -->' "$readme_path" 2>/dev/null; then
			echo "Remote README already has markers — no seeding needed"
		elif [[ ! -f "$readme_path" ]] || _is_default_github_template "$readme_path"; then
			echo "Creating rich profile README..."
			_generate_rich_readme "$gh_user" "$readme_path"
		elif [[ -f "$readme_path" ]]; then
			echo "Injecting markers into remote README..."
			_inject_markers_into_readme "$readme_path"
		fi

		# Commit and push the seeded README
		if [[ -n "$(git -C "$repo_dir" status --porcelain README.md 2>/dev/null)" ]]; then
			git -C "$repo_dir" add README.md
			git -C "$repo_dir" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
			git -C "$repo_dir" push origin "$default_branch" 2>/dev/null || {
				echo "Warning: push failed after re-clone — push manually" >&2
			}
		fi

		# Clean up backup
		rm -rf "$backup_dir"
		echo "Profile repo recovered successfully"
	else
		# Re-clone failed — restore backup
		echo "Error: re-clone failed — restoring backup" >&2
		rm -rf "$repo_dir"
		mv "$backup_dir" "$repo_dir"
	fi

	return 0
}

# --- Build language + tooling badge line for a user's repos ---
# Usage: _build_readme_badges <repos_json>
# Outputs badge markdown lines (one per badge).
_build_readme_badges() {
	local repos_json="$1"

	local languages
	languages=$(echo "$repos_json" | jq -r '[.[].language | select(. != null)] | unique | .[]')

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

	printf '%s' "$badges"
	return 0
}

# --- Build the Connect section badges for a user ---
# Usage: _build_readme_connect <gh_user> <blog> <twitter>
# Outputs badge markdown lines.
_build_readme_connect() {
	local gh_user="$1"
	local blog="$2"
	local twitter="$3"

	local connect=""
	if [[ -n "$blog" ]]; then
		local blog_display
		blog_display="${blog##*//}"
		blog_display=$(_sanitize_md "$blog_display")
		connect="${connect}[![Website](https://img.shields.io/badge/-${blog_display}-FF5722?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0id2hpdGUiIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0tMSAxNy45M2MtMy45NS0uNDktNy0zLjg1LTctNy45MyAwLS42Mi4wOC0xLjIxLjIxLTEuNzlMOSAxNXY1YzAgLjU1LjQ1IDEgMSAxdjEuOTN6bTYuOS0yLjU0Yy0uMjYtLjgxLTEtMS4zOS0xLjktMS4zOWgtMXYtM2MwLS41NS0uNDUtMS0xLTFIOHYtMmgyYy41NSAwIDEtLjQ1IDEtMVY3aDJjMS4xIDAgMi0uOSAyLTJ2LS40MWMyLjkzIDEuMTkgNSA0LjA2IDUgNy40MSAwIDIuMDgtLjggMy45Ny0yLjEgNS4zOXoiLz48L3N2Zz4=&logoColor=white)](${blog})"$'\n'
	fi
	if [[ -n "$twitter" ]]; then
		connect="${connect}[![X](https://img.shields.io/badge/-@${twitter}-000000?style=flat-square&logo=x&logoColor=white)](https://twitter.com/${twitter})"$'\n'
	fi
	connect="${connect}[![GitHub](https://img.shields.io/badge/-Follow-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/${gh_user})"$'\n'

	printf '%s' "$connect"
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

	# Build badge line and connect section via helpers
	local badges
	badges=$(_build_readme_badges "$repos_json")

	# Build own repos section — single jq pass (no loop)
	local own_repos
	own_repos=$(echo "$repos_json" | jq -r --arg user "$gh_user" '
		[.[] | select(.fork == false and .name != $user)] |
		map("- **[\(.name | gsub("[\\[\\]()`]"; ""))](\(.html_url))** -- \((.description // "No description") | gsub("[\\[\\]()`]"; ""))") |
		.[]
	')

	# Build contributions section using shared helper
	local contrib_repos
	contrib_repos=$(_generate_contributions "$gh_user")

	# Build connect section
	local connect
	connect=$(_build_readme_connect "$gh_user" "$blog" "$twitter")

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
		echo ">"
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
		# Contributions (auto-updated daily)
		echo "<!-- CONTRIBUTIONS-START -->"
		if [[ -n "$contrib_repos" ]]; then
			echo "## Contributions"
			echo ""
			printf '%s' "$contrib_repos"
		fi
		echo "<!-- CONTRIBUTIONS-END -->"
		echo ""
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

# --- Clone or pull the profile repo to a local directory ---
# Usage: _init_clone_or_pull <repo_slug> <repo_dir>
# Returns 0 on success, 1 on failure.
_init_clone_or_pull() {
	local repo_slug="$1"
	local repo_dir="$2"

	if [[ ! -d "$repo_dir" ]]; then
		echo "Cloning $repo_slug to $repo_dir"
		git clone "git@github.com:${repo_slug}.git" "$repo_dir" 2>/dev/null ||
			git clone "https://github.com/${repo_slug}.git" "$repo_dir" || {
			echo "Error: failed to clone $repo_slug" >&2
			return 1
		}
	else
		echo "Local repo already exists at $repo_dir"
		local init_branch
		init_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
		if [[ -z "$init_branch" ]]; then
			init_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
		fi
		init_branch="${init_branch:-main}"
		git -C "$repo_dir" pull --ff-only origin "$init_branch" 2>/dev/null || true
	fi
	return 0
}

# --- Register or update the profile repo entry in repos.json ---
# Usage: _init_register_repos_json <repos_json> <repo_dir> <repo_slug>
_init_register_repos_json() {
	local repos_json="$1"
	local repo_dir="$2"
	local repo_slug="$3"

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		return 0
	fi

	local already_registered
	already_registered=$(jq -r --arg path "$repo_dir" '
		if .initialized_repos then
			[.initialized_repos[] | select(.path == $path)] | length
		else
			[to_entries[] | select(.value.path == $path)] | length
		end
	' "$repos_json" 2>/dev/null)

	local tmp_json
	tmp_json=$(mktemp)
	if [[ "$already_registered" == "0" ]]; then
		echo "Registering profile repo in repos.json"
		if jq --arg path "$repo_dir" --arg slug "$repo_slug" '
			.initialized_repos += [{
				"path": $path,
				"slug": $slug,
				"priority": "profile",
				"pulse": false,
				"maintainer": ($slug | split("/")[0])
			}]
		' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
			mv "$tmp_json" "$repos_json"
		else
			echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
			rm -f "$tmp_json"
		fi
	else
		# Ensure priority is set to "profile"
		if jq --arg path "$repo_dir" '
			.initialized_repos |= map(
				if .path == $path then .priority = "profile" else . end
			)
		' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
			mv "$tmp_json" "$repos_json"
		else
			echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
			rm -f "$tmp_json"
		fi
	fi
	return 0
}

# --- Check if profile repo is already fully initialized ---
# Usage: _init_check_already_initialized <repos_json> <repo_slug> <gh_user> <default_repo_dir>
# Prints the effective repo_dir to stdout (may differ from default if repos.json has a path).
# Exit codes: 0 = already done (caller should return 0), 1 = not done (caller should continue),
#             2 = recovered from diverged history (caller should return 0).
_init_check_already_initialized() {
	local repos_json="$1"
	local repo_slug="$2"
	local gh_user="$3"
	local default_repo_dir="$4"

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "$default_repo_dir"
		return 1
	fi

	local existing_profile
	existing_profile=$(jq -r '
		if .initialized_repos then
			.initialized_repos[] | select(.priority == "profile") | .path // empty
		else
			to_entries[] | select(.value.priority == "profile") | .value.path // empty
		end
	' "$repos_json" | head -1)

	if [[ -z "$existing_profile" ]]; then
		echo "$default_repo_dir"
		return 1
	fi

	if [[ -d "$existing_profile" ]] &&
		[[ -f "${existing_profile}/README.md" ]] &&
		grep -q '<!-- STATS-START -->' "${existing_profile}/README.md" 2>/dev/null; then
		# Local looks good — verify we can still push (catches diverged history)
		if git -C "$existing_profile" fetch origin 2>/dev/null; then
			local local_head remote_head merge_base
			local_head=$(git -C "$existing_profile" rev-parse HEAD 2>/dev/null || true)
			remote_head=$(git -C "$existing_profile" rev-parse FETCH_HEAD 2>/dev/null || true)
			if [[ -n "$local_head" && -n "$remote_head" ]]; then
				merge_base=$(git -C "$existing_profile" merge-base "$local_head" "$remote_head" 2>/dev/null || true)
				if [[ -z "$merge_base" ]]; then
					echo "Diverged history detected — re-initializing profile repo..." >&2
					_recover_diverged_profile "$existing_profile" "$repo_slug" "main" "$gh_user"
					echo "Profile repo recovered at $existing_profile" >&2
					echo "$existing_profile"
					return 2
				fi
			fi
		fi
		echo "Profile repo already initialized at $existing_profile" >&2
		echo "$existing_profile"
		return 0
	fi

	# Use existing path if directory exists (may just need README seeding)
	if [[ -d "$existing_profile" ]]; then
		echo "$existing_profile"
	else
		echo "$default_repo_dir"
	fi
	return 1
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
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Check if already fully initialized
	local repo_dir
	repo_dir=$(_init_check_already_initialized "$repos_json" "$repo_slug" "$gh_user" "${HOME}/Git/${gh_user}")
	local check_rc=$?
	if [[ "$check_rc" -eq 0 || "$check_rc" -eq 2 ]]; then
		return 0
	fi

	# Create the repo on GitHub if it doesn't exist
	if ! gh repo view "$repo_slug" &>/dev/null; then
		echo "Creating GitHub profile repo: $repo_slug"
		gh repo create "$repo_slug" --public --add-readme --description "GitHub profile README" || {
			echo "Error: failed to create repo $repo_slug" >&2
			return 1
		}
		sleep 2
	else
		echo "GitHub repo $repo_slug already exists"
	fi

	# Clone or pull the local copy
	_init_clone_or_pull "$repo_slug" "$repo_dir" || return 1

	# Detect default branch for push operations
	local default_branch
	default_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
	fi
	default_branch="${default_branch:-main}"

	# Seed README.md with stat markers.
	local readme_path="${repo_dir}/README.md"
	if [[ ! -f "$readme_path" ]]; then
		echo "Creating rich profile README..."
		_generate_rich_readme "$gh_user" "$readme_path"
	elif _is_default_github_template "$readme_path"; then
		echo "Default GitHub template detected — replacing with rich profile README..."
		_generate_rich_readme "$gh_user" "$readme_path"
	elif ! grep -q '<!-- STATS-START -->' "$readme_path"; then
		echo "Injecting stat markers into existing README..."
		_inject_markers_into_readme "$readme_path"
	fi

	# Commit and push if there are changes
	if [[ -n "$(git -C "$repo_dir" status --porcelain README.md 2>/dev/null)" ]]; then
		git -C "$repo_dir" add README.md
		git -C "$repo_dir" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
		if ! git -C "$repo_dir" push origin "$default_branch" 2>/dev/null; then
			echo "Push failed — attempting recovery from diverged history..." >&2
			_recover_diverged_profile "$repo_dir" "$repo_slug" "$default_branch" "$gh_user"
		fi
	fi

	# Register in repos.json
	_init_register_repos_json "$repos_json" "$repo_dir" "$repo_slug"

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
	echo "Stats will auto-update hourly (configured by setup.sh)."

	return 0
}

# --- Inject the UPDATED timestamp into a README file in-place ---
# Usage: _update_inject_timestamp <file>
# Replaces content between <!-- UPDATED-START --> and <!-- UPDATED-END --> markers.
_update_inject_timestamp() {
	local file="$1"
	if ! grep -q '<!-- UPDATED-START -->' "$file"; then
		return 0
	fi
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
	' "$file" >"$updated_tmp"
	mv "$updated_tmp" "$file"
	return 0
}

# --- Ensure STATS markers exist in a README, injecting or regenerating as needed ---
# Usage: _update_inject_markers_if_needed <profile_repo> <readme_path>
# Commits the injection to the profile repo if changes were made.
_update_inject_markers_if_needed() {
	local profile_repo="$1"
	local readme_path="$2"

	# Even if markers exist, check if the content outside them is the default
	# GitHub template. This handles the case where v3.1.87 injected markers into
	# the default template but didn't replace the template content itself.
	if _is_default_github_template "$readme_path"; then
		echo "Default GitHub template detected — replacing with rich profile README..."
		local gh_user
		gh_user=$(_resolve_profile_user "$profile_repo")
		if [[ -n "$gh_user" ]]; then
			_generate_rich_readme "$gh_user" "$readme_path"
		else
			echo "Could not resolve username — injecting markers only..."
			_inject_markers_into_readme "$readme_path"
		fi
		git -C "$profile_repo" add README.md
		git -C "$profile_repo" commit -m "feat: replace default GitHub template with rich profile README" --no-verify 2>/dev/null || true
		return 0
	fi

	if grep -q '<!-- STATS-START -->' "$readme_path" && grep -q '<!-- STATS-END -->' "$readme_path"; then
		return 0
	fi

	echo "Markers missing from README — injecting them..."
	_inject_markers_into_readme "$readme_path"
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
	return 0
}

# --- Push a profile repo commit, recovering from diverged history if needed ---
# Usage: _update_push_with_recovery <profile_repo> <commit_msg> [extra_args...]
# Returns 0 always (recovery is attempted on push failure).
_update_push_with_recovery() {
	local profile_repo="$1"
	local commit_msg="$2"
	shift 2
	local extra_args=("$@")

	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "$commit_msg" --no-verify 2>/dev/null || {
		echo "No changes to commit"
		return 0
	}

	local default_branch
	default_branch=$(git -C "$profile_repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$profile_repo" branch --show-current 2>/dev/null || true)
	fi
	default_branch="${default_branch:-main}"

	if ! git -C "$profile_repo" push origin "$default_branch" 2>/dev/null; then
		echo "Push failed — attempting recovery from diverged history..." >&2
		local gh_user
		gh_user=$(_resolve_profile_user "$profile_repo")
		if [[ -n "$gh_user" ]]; then
			local repo_slug="${gh_user}/${gh_user}"
			_recover_diverged_profile "$profile_repo" "$repo_slug" "$default_branch" "$gh_user"
			echo "Running fresh stats update after recovery..."
			cmd_update "${extra_args[@]}"
		else
			echo "Warning: push failed and could not resolve username for recovery" >&2
		fi
	fi
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

	# Generate new stats section
	local new_stats
	new_stats=$(cmd_generate)

	# Daily contributions refresh — piggyback on the hourly stats job.
	# Only runs once per day to keep API costs low (~11 core API calls/run).
	local cache_dir="${HOME}/.aidevops/cache"
	local last_contrib_file="${cache_dir}/contributions-last-update"
	local today
	today=$(date -u +"%Y-%m-%d")
	local last_contrib_date=""
	if [[ -f "$last_contrib_file" ]]; then
		last_contrib_date=$(cat "$last_contrib_file" 2>/dev/null || true)
	fi
	if [[ "$last_contrib_date" != "$today" ]] && grep -q '<!-- CONTRIBUTIONS-START -->' "$readme_path" 2>/dev/null; then
		echo "Daily contributions refresh triggered..."
		if [[ "$dry_run" == true ]]; then
			cmd_update_contributions "--dry-run" || echo "Warning: contributions update failed — continuing with stats" >&2
		else
			cmd_update_contributions || echo "Warning: contributions update failed — continuing with stats" >&2
		fi
		if [[ "$dry_run" != true ]]; then
			git -C "$profile_repo" pull --rebase --quiet 2>/dev/null || true
		fi
	fi

	# Ensure markers exist — inject or regenerate if missing
	_update_inject_markers_if_needed "$profile_repo" "$readme_path"

	# Replace content between markers
	local tmp_file
	tmp_file=$(mktemp)
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

	# Check if content changed, ignoring UPDATED marker block
	local old_normalized new_normalized
	old_normalized=$(_normalize_readme_for_compare "$readme_path")
	new_normalized=$(_normalize_readme_for_compare "$tmp_file")
	if [[ "$old_normalized" == "$new_normalized" ]]; then
		echo "No changes to profile content — skipping commit"
		rm -f "$tmp_file"
		return 0
	fi

	# Update timestamp
	_update_inject_timestamp "$tmp_file"

	if [[ "$dry_run" == true ]]; then
		echo "--- DRY RUN: would write to $readme_path ---"
		diff "$readme_path" "$tmp_file" || true
		rm -f "$tmp_file"
		return 0
	fi

	# Apply changes and push
	mv "$tmp_file" "$readme_path"
	_update_push_with_recovery "$profile_repo" "chore: update profile stats ($(date -u +%Y-%m-%d))" "$@"

	echo "Profile README updated and pushed"
	return 0
}

# --- Migrate static Contributions section to auto-updated markers ---
# Usage: _update_contributions_migrate_markers <readme_path> <dry_run>
# Returns 0 on success, 1 if END marker still missing after migration.
_update_contributions_migrate_markers() {
	local readme_path="$1"
	local dry_run="$2"

	if grep -q '<!-- CONTRIBUTIONS-START -->' "$readme_path"; then
		# Markers already present — check for END marker
		if ! grep -q '<!-- CONTRIBUTIONS-END -->' "$readme_path"; then
			if [[ "$dry_run" == true ]]; then
				echo "Note: markers would be injected on actual run"
				return 1
			fi
			echo "Error: <!-- CONTRIBUTIONS-END --> marker not found" >&2
			return 1
		fi
		return 0
	fi

	if [[ "$dry_run" == true ]]; then
		echo "Note: CONTRIBUTIONS markers not found — would migrate static section"
		return 1
	fi

	echo "Migrating static Contributions section to auto-updated markers..."
	local inject_tmp
	inject_tmp=$(mktemp)
	awk '
		/^## Contributions/ { in_old_contrib = 1; next }
		in_old_contrib && /^## / {
			in_old_contrib = 0
			print "<!-- CONTRIBUTIONS-START -->"
			print "<!-- CONTRIBUTIONS-END -->"
			print ""
			print $0
			next
		}
		in_old_contrib { next }
		{ print }
	' "$readme_path" >"$inject_tmp"
	# If EOF reached while still in old section, append markers
	if ! grep -q '<!-- CONTRIBUTIONS-START -->' "$inject_tmp"; then
		{
			echo "<!-- CONTRIBUTIONS-START -->"
			echo "<!-- CONTRIBUTIONS-END -->"
		} >>"$inject_tmp"
	fi
	mv "$inject_tmp" "$readme_path"

	if ! grep -q '<!-- CONTRIBUTIONS-END -->' "$readme_path"; then
		echo "Error: <!-- CONTRIBUTIONS-END --> marker not found after migration" >&2
		return 1
	fi
	return 0
}

# --- Commit and push contributions update, recording daily throttle timestamp ---
# Usage: _update_contributions_push <profile_repo>
_update_contributions_push() {
	local profile_repo="$1"
	local readme_path="${profile_repo}/README.md"

	# Update timestamp
	_update_inject_timestamp "$readme_path"

	local commit_msg
	commit_msg="chore: update profile contributions ($(date -u +%Y-%m-%d))"
	git -C "$profile_repo" add README.md
	git -C "$profile_repo" commit -m "$commit_msg" --no-verify 2>/dev/null || {
		echo "No changes to commit"
		return 0
	}

	local default_branch
	default_branch=$(git -C "$profile_repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$profile_repo" branch --show-current 2>/dev/null || true)
	fi
	default_branch="${default_branch:-main}"
	git -C "$profile_repo" push origin "$default_branch" 2>/dev/null || {
		echo "Warning: push failed — contributions committed locally" >&2
		return 0
	}

	# Record last-run timestamp for daily throttle
	local cache_dir="${HOME}/.aidevops/cache"
	mkdir -p "$cache_dir"
	date -u +"%Y-%m-%d" >"${cache_dir}/contributions-last-update"

	echo "Profile contributions updated and pushed"
	return 0
}

# --- Update contributions section between markers ---
# Can be called standalone or from cmd_update with daily throttle.
# Uses _generate_contributions() to fetch fork parent URLs + repos.json entries.
cmd_update_contributions() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
	fi

	# Resolve profile repo and user
	local profile_repo
	profile_repo=$(_resolve_profile_repo) || return 1
	local readme_path="${profile_repo}/README.md"

	if [[ ! -f "$readme_path" ]]; then
		echo "Error: README.md not found at $readme_path" >&2
		return 1
	fi

	# Ensure CONTRIBUTIONS markers exist (migrate from static section if needed)
	_update_contributions_migrate_markers "$readme_path" "$dry_run" || return 0

	# Resolve GitHub username
	local gh_user
	gh_user=$(_resolve_profile_user "$profile_repo")
	if [[ -z "$gh_user" ]]; then
		echo "Error: could not resolve GitHub username for profile repo" >&2
		return 1
	fi

	# Generate new contributions content
	local new_contribs
	new_contribs=$(_generate_contributions "$gh_user")

	# Build the replacement block
	local contribs_block=""
	if [[ -n "$new_contribs" ]]; then
		contribs_block="## Contributions"$'\n'$'\n'"${new_contribs}"
	fi

	# Replace content between markers
	local tmp_file
	tmp_file=$(mktemp)
	CONTRIBS_BLOCK="$contribs_block" awk '
		/<!-- CONTRIBUTIONS-START -->/ {
			print "<!-- CONTRIBUTIONS-START -->"
			skip = 1
			next
		}
		/<!-- CONTRIBUTIONS-END -->/ {
			skip = 0
			block = ENVIRON["CONTRIBS_BLOCK"]
			if (block != "") {
				printf "%s", block
			}
			print "<!-- CONTRIBUTIONS-END -->"
			next
		}
		!skip { print }
	' "$readme_path" >"$tmp_file"

	# Check if content actually changed
	if diff -q "$readme_path" "$tmp_file" >/dev/null 2>&1; then
		echo "Contributions unchanged — skipping"
		rm -f "$tmp_file"
		return 0
	fi

	if [[ "$dry_run" == true ]]; then
		echo "--- DRY RUN: contributions changes ---"
		diff "$readme_path" "$tmp_file" || true
		rm -f "$tmp_file"
		return 0
	fi

	# Apply changes and push
	mv "$tmp_file" "$readme_path"
	_update_contributions_push "$profile_repo"
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
update-contributions)
	shift
	cmd_update_contributions "$@"
	;;
help | *)
	echo "Usage: profile-readme-helper.sh {init|update|update-contributions|generate|help}"
	echo ""
	echo "Commands:"
	echo "  init                          Create profile repo, seed README, register in repos.json"
	echo "  update [--dry-run]            Update profile README with live stats and push"
	echo "  update-contributions [--dry-run]  Refresh contributions list from forks + repos.json"
	echo "  generate                      Print generated stats section to stdout"
	echo "  help                          Show this help"
	echo ""
	echo "The 'update' command automatically refreshes contributions once per day."
	echo "Use 'update-contributions' to force an immediate refresh."
	;;
esac
