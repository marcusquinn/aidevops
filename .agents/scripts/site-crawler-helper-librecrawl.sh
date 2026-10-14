#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Site Crawler Helper -- LibreCrawl Engine
# =============================================================================
# Drives a self-hosted LibreCrawl server (https://github.com/PhialsBasement/LibreCrawl)
# through its REST API: guest sign-in, settings, start, poll, export. Writes the
# shared site-crawler output layout (crawl-data.csv, broken-links.csv,
# redirects.csv, meta-issues.csv, summary.json) plus LibreCrawl's raw exports
# (librecrawl-urls.json, librecrawl-links.csv, librecrawl-issues.csv).
#
# The helper only connects to a running server; it never starts containers.
# Run LibreCrawl in local mode bound to 127.0.0.1 (see seo/librecrawl.md).
#
# Usage: source "${SCRIPT_DIR}/site-crawler-helper-librecrawl.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, print_warning, print_success, print_error)
#   - site-crawler-helper-crawl4ai.sh (_c4ai_generate_xlsx, optional XLSX output)
#   - curl, jq
#
# API reference: LibreCrawl main.py at commit 05a1372de833.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SITE_CRAWLER_LIBRECRAWL_LIB_LOADED:-}" ]] && return 0
_SITE_CRAWLER_LIBRECRAWL_LIB_LOADED=1

LIBRECRAWL_URL="${LIBRECRAWL_URL:-http://127.0.0.1:5000}"
LIBRECRAWL_URL="${LIBRECRAWL_URL%/}"
LIBRECRAWL_POLL_SECONDS=2
LIBRECRAWL_DEFAULT_TIMEOUT_MIN=60

# Tier reported by the last successful probe (admin = local mode)
LIBRECRAWL_TIER=""

# Options that only the LibreCrawl engine implements (set by librecrawl_store_opt)
LIBRECRAWL_OPT_RENDER_JS=false
LIBRECRAWL_OPT_IGNORE_ROBOTS=false
LIBRECRAWL_OPT_PAGESPEED=false
LIBRECRAWL_OPT_USER_AGENT=""
LIBRECRAWL_OPT_INCLUDE=""
LIBRECRAWL_OPT_EXCLUDE=""
LIBRECRAWL_OPT_TIMEOUT_MIN="$LIBRECRAWL_DEFAULT_TIMEOUT_MIN"
LIBRECRAWL_ONLY_FLAGS=""
_LIBRECRAWL_OPT_SHIFT=1

# Per-crawl state
_LIBRECRAWL_TMP=""
_LIBRECRAWL_JAR=""
_LIBRECRAWL_CRAWL_ACTIVE=false
_LIBRECRAWL_CRAWL_ID=""
_LIBRECRAWL_FINAL_STATUS=""

# URL fields requested from /api/export_stream (identifier-like names only)
readonly LIBRECRAWL_EXPORT_FIELDS="url,status_code,title,meta_description,h1,h2,canonical_url,robots,depth,response_time,size,redirects,redirected_to,word_count,internal_links,external_links,lang,hreflang,json_ld,content_type,is_internal,error_type,link_check_only,images"

readonly LIBRECRAWL_CSV_HEADER="url,status_code,status,title,title_length,meta_description,description_length,h1,h1_count,canonical,meta_robots,word_count,response_time_ms,crawl_depth,internal_links,external_links,images,images_missing_alt"

# --- Option handling ---

# Record one LibreCrawl-only option. Sets _LIBRECRAWL_OPT_SHIFT to the number
# of arguments consumed. Arguments: $1=flag $2=value (when the flag takes one)
librecrawl_store_opt() {
	local flag="$1"
	local value="${2:-}"
	_LIBRECRAWL_OPT_SHIFT=1

	case "$flag" in
	--render-js) LIBRECRAWL_OPT_RENDER_JS=true ;;
	--ignore-robots) LIBRECRAWL_OPT_IGNORE_ROBOTS=true ;;
	--include-pagespeed) LIBRECRAWL_OPT_PAGESPEED=true ;;
	--user-agent | --include | --exclude | --timeout)
		if [[ $# -lt 2 || -z "$value" || "$value" == --* ]]; then
			print_error "$flag needs a value"
			return 1
		fi
		_LIBRECRAWL_OPT_SHIFT=2
		case "$flag" in
		--user-agent) LIBRECRAWL_OPT_USER_AGENT="$value" ;;
		--include) LIBRECRAWL_OPT_INCLUDE="${LIBRECRAWL_OPT_INCLUDE:+${LIBRECRAWL_OPT_INCLUDE},}${value}" ;;
		--exclude) LIBRECRAWL_OPT_EXCLUDE="${LIBRECRAWL_OPT_EXCLUDE:+${LIBRECRAWL_OPT_EXCLUDE},}${value}" ;;
		--timeout)
			if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
				print_error "--timeout must be a whole number of minutes (got: $value)"
				return 1
			fi
			LIBRECRAWL_OPT_TIMEOUT_MIN="$value"
			;;
		esac
		;;
	*)
		print_error "Not a LibreCrawl option: $flag"
		return 1
		;;
	esac

	case " $LIBRECRAWL_ONLY_FLAGS " in
	*" $flag "*) ;;
	*) LIBRECRAWL_ONLY_FLAGS="${LIBRECRAWL_ONLY_FLAGS:+$LIBRECRAWL_ONLY_FLAGS }$flag" ;;
	esac
	return 0
}

# --- HTTP helpers ---

# Call the LibreCrawl API with the per-crawl cookie jar. Prints the body.
# Arguments: $1=method $2=path [$3=json body file] [$4=max seconds]
_librecrawl_api() {
	local method="$1"
	local path="$2"
	local body_file="${3:-}"
	local max_time="${4:-30}"
	local args=(-sS --connect-timeout 5 --max-time "$max_time" -b "$_LIBRECRAWL_JAR" -c "$_LIBRECRAWL_JAR" -X "$method")

	if [[ -n "$body_file" ]]; then
		args+=(-H "Content-Type: application/json" --data-binary "@${body_file}")
	fi
	curl "${args[@]}" "${LIBRECRAWL_URL}${path}"
	return $?
}

# Download an export endpoint to a file; fails on HTTP errors.
# Arguments: $1=path $2=destination file
_librecrawl_download() {
	local path="$1"
	local dest="$2"

	curl -sS -f --connect-timeout 5 --max-time 1800 \
		-b "$_LIBRECRAWL_JAR" -c "$_LIBRECRAWL_JAR" \
		-o "$dest" "${LIBRECRAWL_URL}${path}"
	return $?
}

# Sign in as guest and read the session tier into LIBRECRAWL_TIER.
# In local mode guests get the admin tier. Requires _LIBRECRAWL_JAR.
# Returns 0 when a LibreCrawl server answered, 1 otherwise.
_librecrawl_login() {
	local login_json info_json
	LIBRECRAWL_TIER=""

	# Port 5000 is also macOS AirPlay Receiver: require LibreCrawl's JSON shape
	login_json=$(_librecrawl_api POST "/api/guest-login" "" 5 2>/dev/null) || return 1
	printf '%s' "$login_json" | jq -e 'has("success")' >/dev/null 2>&1 || return 1

	# With guest sign-in disabled, local mode still auto-signs in on this call
	info_json=$(_librecrawl_api GET "/api/user/info" "" 5 2>/dev/null) || return 0
	LIBRECRAWL_TIER=$(printf '%s' "$info_json" | jq -r '.user.tier // empty' 2>/dev/null) || LIBRECRAWL_TIER=""
	return 0
}

# Check whether LibreCrawl answers at LIBRECRAWL_URL; sets LIBRECRAWL_TIER.
check_librecrawl() {
	command -v jq &>/dev/null || return 1

	local probe_dir saved_jar rc=0
	probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/librecrawl-probe-XXXXXX") || return 1
	saved_jar="$_LIBRECRAWL_JAR"
	_LIBRECRAWL_JAR="${probe_dir}/cookies.txt"
	_librecrawl_login || rc=1
	_LIBRECRAWL_JAR="$saved_jar"
	rm -rf "$probe_dir"
	return $rc
}

# True when the last probe saw local mode (guest/auto sign-in has admin tier)
librecrawl_is_local() {
	[[ "$LIBRECRAWL_TIER" == "admin" ]]
	return $?
}

# Print the guidance for a server that is reachable but not in local mode.
_librecrawl_local_mode_help() {
	print_info "  Run LibreCrawl with LOCAL_MODE=true, bound to 127.0.0.1 (docker-compose default)."
	print_info "  Outside local mode a guest gets 3 crawls a day and no JavaScript rendering."
	print_info "  Setup: ~/.aidevops/agents/seo/librecrawl.md"
	return 0
}

# --- Crawl steps ---

# Resolve the Google API key for PageSpeed without putting it on a command line.
# Order: GOOGLE_API_KEY in the environment, then `aidevops secret get`.
_librecrawl_google_key() {
	local value="${GOOGLE_API_KEY:-}"
	if [[ -z "$value" ]] && command -v aidevops &>/dev/null; then
		value=$(aidevops secret get GOOGLE_API_KEY </dev/null 2>/dev/null) || value=""
	fi
	printf '%s' "$value"
	return 0
}

# Write the settings body and apply it. Arguments: $1=max_urls $2=depth
_librecrawl_apply_settings() {
	local max_urls="$1"
	local depth="$2"
	local body="${_LIBRECRAWL_TMP}/settings.json"
	local google_key=""

	if [[ "$LIBRECRAWL_OPT_PAGESPEED" == "true" ]]; then
		google_key=$(_librecrawl_google_key)
		if [[ -z "$google_key" ]]; then
			print_warning "No GOOGLE_API_KEY found; PageSpeed runs on the public quota (store one: aidevops secret set GOOGLE_API_KEY)"
		fi
	fi

	# The key reaches jq through the environment, never argv
	LIBRECRAWL_GOOGLE_API_KEY="$google_key" jq -n \
		--argjson depth "$depth" \
		--argjson max_urls "$max_urls" \
		--argjson render_js "$LIBRECRAWL_OPT_RENDER_JS" \
		--argjson ignore_robots "$LIBRECRAWL_OPT_IGNORE_ROBOTS" \
		--argjson pagespeed "$LIBRECRAWL_OPT_PAGESPEED" \
		--arg user_agent "$LIBRECRAWL_OPT_USER_AGENT" \
		--arg include "$LIBRECRAWL_OPT_INCLUDE" \
		--arg exclude "$LIBRECRAWL_OPT_EXCLUDE" '
		def lines: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | join("\n");
		{
			maxDepth: $depth,
			maxUrls: $max_urls,
			crawlExternalLinks: false,
			respectRobotsTxt: ($ignore_robots | not),
			includePatterns: ($include | lines),
			excludePatterns: ($exclude | lines),
			enableJavaScript: $render_js,
			enablePageSpeed: $pagespeed
		}
		+ (if $user_agent != "" then {userAgent: $user_agent, jsUserAgent: $user_agent} else {} end)
		+ (if $pagespeed and ($ENV.LIBRECRAWL_GOOGLE_API_KEY // "") != ""
			then {googleApiKey: $ENV.LIBRECRAWL_GOOGLE_API_KEY} else {} end)
	' >"$body" || return 1

	local response
	response=$(_librecrawl_api POST "/api/save_settings" "$body") || return 1
	rm -f "$body"
	if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
		print_error "LibreCrawl rejected the settings: $(_librecrawl_api_error "$response")"
		return 1
	fi

	response=$(_librecrawl_api POST "/api/update_crawler_settings") || return 1
	if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
		print_error "LibreCrawl could not apply the settings: $(_librecrawl_api_error "$response")"
		return 1
	fi
	return 0
}

# Print the error message from a LibreCrawl JSON response. Arguments: $1=response
_librecrawl_api_error() {
	local response="$1"
	printf '%s' "$response" | jq -r '.message // .error // "unknown error"' 2>/dev/null || printf 'unknown error'
	return 0
}

# Start the crawl; sets _LIBRECRAWL_CRAWL_ID. Arguments: $1=url
_librecrawl_start() {
	local url="$1"
	local body="${_LIBRECRAWL_TMP}/start.json"
	local response

	_LIBRECRAWL_CRAWL_ID=""
	jq -n --arg url "$url" '{url: $url}' >"$body" || return 1
	response=$(_librecrawl_api POST "/api/start_crawl" "$body") || return 1
	if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
		print_error "LibreCrawl did not start the crawl: $(_librecrawl_api_error "$response")"
		return 1
	fi
	_LIBRECRAWL_CRAWL_ACTIVE=true
	_LIBRECRAWL_CRAWL_ID=$(printf '%s' "$response" | jq -r '.crawl_id // "" | tostring')
	return 0
}

# Stop a running crawl (timeout, Ctrl-C)
_librecrawl_stop() {
	[[ "$_LIBRECRAWL_CRAWL_ACTIVE" == "true" ]] || return 0
	_librecrawl_api POST "/api/stop_crawl" "" 30 >/dev/null 2>&1 || true
	_LIBRECRAWL_CRAWL_ACTIVE=false
	return 0
}

_librecrawl_cleanup() {
	if [[ -n "$_LIBRECRAWL_TMP" && -d "$_LIBRECRAWL_TMP" ]]; then
		rm -rf "$_LIBRECRAWL_TMP"
	fi
	_LIBRECRAWL_TMP=""
	_LIBRECRAWL_JAR=""
	return 0
}

_librecrawl_on_interrupt() {
	trap - INT TERM
	echo ""
	print_warning "Interrupted: stopping the LibreCrawl crawl..."
	_librecrawl_stop
	_librecrawl_cleanup
	exit 130
}

# Poll until the crawl leaves "running". Sets _LIBRECRAWL_FINAL_STATUS.
# Returns 1 on timeout (crawl stopped) or when the server stops answering.
_librecrawl_wait() {
	local timeout_min="$1"
	local deadline last_report now status_json status crawled discovered
	local failures=0
	deadline=$(($(date +%s) + timeout_min * 60))
	last_report=0
	_LIBRECRAWL_FINAL_STATUS=""

	while true; do
		if ! status_json=$(_librecrawl_api GET "/api/crawl_status?stats_only=1" "" 30 2>/dev/null) ||
			! printf '%s' "$status_json" | jq -e '.status' >/dev/null 2>&1; then
			failures=$((failures + 1))
			if [[ $failures -ge 5 ]]; then
				print_error "LibreCrawl stopped answering at ${LIBRECRAWL_URL}"
				return 1
			fi
			sleep "$LIBRECRAWL_POLL_SECONDS"
			continue
		fi
		failures=0

		status=$(printf '%s' "$status_json" | jq -r '.status')
		crawled=$(printf '%s' "$status_json" | jq -r '.stats.crawled // 0')
		discovered=$(printf '%s' "$status_json" | jq -r '.stats.discovered // 0')
		now=$(date +%s)

		if [[ "$status" != "running" ]]; then
			_LIBRECRAWL_FINAL_STATUS="$status"
			_LIBRECRAWL_CRAWL_ACTIVE=false
			print_info "LibreCrawl status: ${status} (crawled ${crawled}, discovered ${discovered})"
			printf '%s' "$status_json" | jq '.stats.pagespeed_results // empty' >"${_LIBRECRAWL_TMP}/pagespeed.json" 2>/dev/null || true
			return 0
		fi

		if [[ $now -ge $deadline ]]; then
			print_warning "Timeout after ${timeout_min} min: stopping the crawl and exporting partial results"
			_librecrawl_stop
			_LIBRECRAWL_FINAL_STATUS="timeout"
			return 1
		fi

		if [[ $((now - last_report)) -ge 10 ]]; then
			print_info "  crawled ${crawled}, discovered ${discovered}"
			last_report=$now
		fi
		sleep "$LIBRECRAWL_POLL_SECONDS"
	done
}

# Download LibreCrawl's raw exports. Arguments: $1=output_dir
_librecrawl_export() {
	local output_dir="$1"
	local fields="$LIBRECRAWL_EXPORT_FIELDS"

	_librecrawl_download "/api/export_stream?type=urls&format=json&fields=${fields}" "${output_dir}/librecrawl-urls.json" || {
		print_error "LibreCrawl returned no URL data to export"
		return 1
	}
	_librecrawl_download "/api/export_stream?type=links&format=csv" "${output_dir}/librecrawl-links.csv" || return 1
	_librecrawl_download "/api/export_stream?type=issues&format=csv" "${output_dir}/librecrawl-issues.csv" || return 1
	_librecrawl_download "/api/export_stream?type=links&format=json" "${_LIBRECRAWL_TMP}/links.json" || return 1
	_librecrawl_download "/api/export_stream?type=issues&format=json" "${_LIBRECRAWL_TMP}/issues.json" || return 1

	local file
	for file in "${output_dir}/librecrawl-urls.json" "${_LIBRECRAWL_TMP}/links.json" "${_LIBRECRAWL_TMP}/issues.json"; do
		if ! jq -e '.data | arrays' "$file" >/dev/null 2>&1; then
			print_error "Unexpected LibreCrawl export format: ${file##*/}"
			return 1
		fi
	done
	print_info "Exported: librecrawl-urls.json, librecrawl-links.csv, librecrawl-issues.csv"
	return 0
}

# jq program mapping LibreCrawl exports to the shared report rows
_librecrawl_report_program() {
	cat <<'JQ'
def num: if type == "number" then . elif type == "string" then (tonumber? // 0) else 0 end;
def str: if . == null then "" elif type == "string" then gsub("[\r\n\t]+"; " ") else tostring end;
def arr: if type == "array" then . else [] end;
def html_page: ((.content_type | str) as $ct | $ct == "" or ($ct | test("html"; "i")));

($urls[0].data | arr) as $pages
| ($links[0].data | arr) as $all_links
| ($issues[0].data | arr) as $all_issues
| [$pages[] | select((.link_check_only // false) != true and (.is_internal // false) == true and html_page)] as $crawled
| ($all_links
	| map(select((.target_status | type) == "number" and (.target_status >= 400 or .target_status == 0))
		| {url: (.target_url | str), status_code: .target_status, source: (.source_url | str)})
	| unique) as $link_broken
| ($link_broken | map({key: .url, value: true}) | from_entries) as $linked
| ($crawled
	| map(select((.status_code | num) as $s | $s >= 400 or $s == 0)
		| select($linked[(.url | str)] | not)
		| {url: (.url | str), status_code: (.status_code | num), source: "direct"})) as $direct_broken
| ($crawled | map(
	(.status_code | num) as $s
	| (.title | str) as $t | (.meta_description | str) as $d | (.h1 | str) as $h
	| (.images | arr) as $imgs
	| [(.url | str), $s,
		(if $s == 0 or $s >= 400 then "Error" elif $s >= 300 then "Redirect" else "OK" end),
		$t, ($t | length), $d, ($d | length), $h, ([$h | length, 1] | min),
		(.canonical_url | str), (.robots | str), (.word_count | num), (.response_time | num),
		(.depth | num), (.internal_links | num), (.external_links | num),
		($imgs | length), ($imgs | map(select(.has_alt != true)) | length)])) as $rows
| ($crawled | map(. as $p | (.redirects | arr)[]
	| [(.url | str), (.status_code | num), (($p.redirected_to // $p.url) | str)])) as $redirects
| ($crawled | map(select((.status_code | num) as $s | $s >= 200 and $s < 300)
	| (.title | str) as $t | (.meta_description | str) as $d | (.h1 | str) as $h
	| [(($t | length) as $n | if $n == 0 then "Missing title" elif $n > 60 then "Title too long" else empty end),
		(($d | length) as $n | if $n == 0 then "Missing description" elif $n > 160 then "Description too long" else empty end),
		(if ($h | length) == 0 then "Missing H1" else empty end)] as $found
	| select($found | length > 0)
	| [(.url | str), $t[0:50], $h[0:50], ($found | join("; "))])) as $meta
| {
	rows: $rows,
	broken: (($link_broken + $direct_broken) | map([.url, .status_code, .source])),
	redirects: $redirects,
	meta: $meta,
	status_codes: ($crawled | map(.status_code | num | tostring) | group_by(.) | map({key: .[0], value: length}) | from_entries),
	issue_types: ($all_issues | group_by(.type | str) | map({key: (.[0].type | str), value: length}) | from_entries),
	librecrawl_issues: ($all_issues | length),
	links: ($all_links | length)
}
JQ
	return 0
}

# Write the shared CSV/JSON layout. Arguments: $1=output_dir $2=url $3=crawl_id $4=status
_librecrawl_write_reports() {
	local output_dir="$1"
	local url="$2"
	local crawl_id="$3"
	local final_status="$4"
	local report="${_LIBRECRAWL_TMP}/report.json"

	if ! jq -n \
		--slurpfile urls "${output_dir}/librecrawl-urls.json" \
		--slurpfile links "${_LIBRECRAWL_TMP}/links.json" \
		--slurpfile issues "${_LIBRECRAWL_TMP}/issues.json" \
		"$(_librecrawl_report_program)" >"$report"; then
		print_error "Could not map the LibreCrawl exports"
		return 1
	fi

	{
		printf '%s\n' "$LIBRECRAWL_CSV_HEADER"
		jq -r '.rows[] | @csv' "$report"
	} >"${output_dir}/crawl-data.csv"
	{
		printf '%s\n' "url,status_code,source"
		jq -r '.broken[] | @csv' "$report"
	} >"${output_dir}/broken-links.csv"
	{
		printf '%s\n' "original_url,status_code,redirect_url"
		jq -r '.redirects[] | @csv' "$report"
	} >"${output_dir}/redirects.csv"
	{
		printf '%s\n' "url,title,h1,issues"
		jq -r '.meta[] | @csv' "$report"
	} >"${output_dir}/meta-issues.csv"

	local pagespeed_file="${_LIBRECRAWL_TMP}/pagespeed.json"
	if [[ -s "$pagespeed_file" ]] && jq -e 'arrays | length > 0' "$pagespeed_file" >/dev/null 2>&1; then
		cp "$pagespeed_file" "${output_dir}/librecrawl-pagespeed.json"
		print_info "Generated: ${output_dir}/librecrawl-pagespeed.json"
	fi

	jq \
		--arg crawl_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg base_url "$url" \
		--arg server "$LIBRECRAWL_URL" \
		--arg crawl_id "$crawl_id" \
		--arg final_status "$final_status" \
		--argjson render_js "$LIBRECRAWL_OPT_RENDER_JS" \
		--argjson pagespeed "$LIBRECRAWL_OPT_PAGESPEED" '
		{
			crawl_date: $crawl_date,
			base_url: $base_url,
			backend: "librecrawl",
			librecrawl: {server: $server, crawl_id: $crawl_id, status: $final_status,
				render_js: $render_js, pagespeed: $pagespeed},
			complete: ($final_status == "completed"),
			pages_crawled: (.rows | length),
			broken_links: (.broken | length),
			redirects: (.redirects | length),
			meta_issues: (.meta | length),
			librecrawl_issues: .librecrawl_issues,
			librecrawl_issue_types: .issue_types,
			links: .links,
			status_codes: .status_codes
		}' "$report" >"${output_dir}/summary.json"

	print_info "Generated: crawl-data.csv, broken-links.csv, redirects.csv, meta-issues.csv, summary.json"

	if declare -F _c4ai_generate_xlsx >/dev/null && [[ "${format:-xlsx}" != "csv" ]]; then
		_c4ai_generate_xlsx "${output_dir}/crawl-data.csv"
	fi

	jq -r '"  Pages: \(.pages_crawled), broken links: \(.broken_links), redirects: \(.redirects), meta issues: \(.meta_issues), LibreCrawl issues: \(.librecrawl_issues)"' \
		"${output_dir}/summary.json"
	return 0
}

# Validate numeric crawl limits against LibreCrawl's accepted ranges.
_librecrawl_validate_limits() {
	local max_urls="$1"
	local depth="$2"

	if [[ ! "$depth" =~ ^[0-9]+$ ]] || [[ "$depth" -lt 1 || "$depth" -gt 10 ]]; then
		print_error "LibreCrawl accepts --depth 1 to 10 (got: $depth)"
		return 1
	fi
	if [[ ! "$max_urls" =~ ^[0-9]+$ ]] || [[ "$max_urls" -lt 1 ]]; then
		print_error "--max-urls must be a positive whole number (got: $max_urls)"
		return 1
	fi
	return 0
}

_librecrawl_run() {
	local url="$1"
	local output_dir="$2"
	local max_urls="$3"
	local depth="$4"

	_librecrawl_validate_limits "$max_urls" "$depth" || return 1

	_LIBRECRAWL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/librecrawl-XXXXXX") || return 1
	_LIBRECRAWL_JAR="${_LIBRECRAWL_TMP}/cookies.txt"

	if ! _librecrawl_login; then
		print_error "LibreCrawl is not answering at ${LIBRECRAWL_URL}"
		_librecrawl_local_mode_help
		return 1
	fi
	if ! librecrawl_is_local; then
		print_error "LibreCrawl at ${LIBRECRAWL_URL} is not in local mode (tier: ${LIBRECRAWL_TIER:-none})"
		_librecrawl_local_mode_help
		return 1
	fi

	_librecrawl_apply_settings "$max_urls" "$depth" || return 1

	_librecrawl_start "$url" || return 1
	local crawl_id="$_LIBRECRAWL_CRAWL_ID"
	print_info "LibreCrawl crawl started (id: ${crawl_id:-n/a}, timeout: ${LIBRECRAWL_OPT_TIMEOUT_MIN} min)"

	local wait_rc=0
	_librecrawl_wait "$LIBRECRAWL_OPT_TIMEOUT_MIN" || wait_rc=1
	if [[ $wait_rc -ne 0 && "$_LIBRECRAWL_FINAL_STATUS" != "timeout" ]]; then
		return 1
	fi
	if [[ "$_LIBRECRAWL_FINAL_STATUS" == "idle" ]]; then
		print_error "LibreCrawl crawled 0 pages: check the URL, robots.txt (--ignore-robots) and --include/--exclude patterns"
		return 1
	fi
	if [[ "$_LIBRECRAWL_FINAL_STATUS" == "demo_stopped" ]]; then
		print_warning "LibreCrawl stopped at its demo-mode memory limit; results are partial"
	fi

	_librecrawl_export "$output_dir" || return 1
	_librecrawl_write_reports "$output_dir" "$url" "$crawl_id" "$_LIBRECRAWL_FINAL_STATUS" || return 1
	return $wait_rc
}

# Crawl with LibreCrawl. Arguments: $1=url $2=output_dir $3=max_urls $4=depth
crawl_with_librecrawl() {
	local url="$1"
	local output_dir="$2"
	local max_urls="$3"
	local depth="$4"

	if ! command -v jq &>/dev/null; then
		print_error "The LibreCrawl engine needs jq (brew install jq)"
		return 1
	fi

	print_info "Using LibreCrawl backend at ${LIBRECRAWL_URL}..."
	_LIBRECRAWL_CRAWL_ACTIVE=false
	trap '_librecrawl_on_interrupt' INT TERM

	local rc=0
	_librecrawl_run "$url" "$output_dir" "$max_urls" "$depth" || rc=$?

	trap - INT TERM
	_librecrawl_stop
	_librecrawl_cleanup
	return $rc
}
