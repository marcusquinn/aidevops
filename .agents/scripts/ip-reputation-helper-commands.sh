#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# IP Reputation Commands -- all user-facing command implementations
# =============================================================================
# Contains cmd_check, cmd_batch, cmd_report, cmd_providers, cmd_cache_stats,
# cmd_cache_clear, cmd_rate_limit_status, and their supporting parse/process
# helper functions.
#
# Usage: source "${SCRIPT_DIR}/ip-reputation-helper-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success, safe_grep_count)
#   - ip-reputation-helper-cache.sh (cache_init, sanitize_provider, cache_get, cache_put, ...)
#   - ip-reputation-helper-providers.sh (is_provider_available, get_available_providers,
#     run_provider, provider_script, provider_display_name)
#   - ip-reputation-helper-merge.sh (merge_results, output_results, format_markdown,
#     risk_color, dnsbl_overlap_check)
#   - Color accessors (c_red, c_green, c_yellow, c_cyan, c_nc, c_bold) from orchestrator
#   - ALL_PROVIDERS, PROVIDERS_DIR, IP_REP_DEFAULT_TIMEOUT, IP_REP_DEFAULT_FORMAT,
#     IP_REP_CACHE_DB, IP_REP_CACHE_DIR (from orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_IP_REP_COMMANDS_LIB_LOADED:-}" ]] && return 0
_IP_REP_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

# =============================================================================
# Cache & Rate Limit Commands
# =============================================================================

# Show rate limit status for all providers
cmd_rate_limit_status() {
	if ! command -v sqlite3 &>/dev/null; then
		log_warn "sqlite3 not available — rate limit tracking disabled"
		return 0
	fi
	if [[ ! -f "$IP_REP_CACHE_DB" ]]; then
		log_info "No rate limit data (no queries run yet)"
		return 0
	fi
	local now
	now=$(date +%s)
	echo ""
	echo -e "$(c_bold)$(c_cyan)=== Rate Limit Status ===$(c_nc)"
	echo ""
	printf "  %-18s %-12s %-14s %-10s %s\n" "Provider" "Status" "Retry After" "Hits" "Last Hit"
	printf "  %-18s %-12s %-14s %-10s %s\n" "--------" "------" "-----------" "----" "--------"

	local has_data=false
	local provider
	for provider in $ALL_PROVIDERS; do
		local row
		row=$(sqlite3 "$IP_REP_CACHE_DB" \
			"SELECT hit_at, retry_after, hit_count FROM rate_limits
			 WHERE provider='${provider}' LIMIT 1;" \
			2>/dev/null || true)
		[[ -z "$row" ]] && continue
		has_data=true
		local hit_at retry_after hit_count
		IFS='|' read -r hit_at retry_after hit_count <<<"$row"
		local expires=$((hit_at + retry_after))
		local status status_color
		if [[ "$expires" -gt "$now" ]]; then
			local remaining=$((expires - now))
			status="LIMITED (${remaining}s)"
			status_color=$(c_red)
		else
			status="OK"
			status_color=$(c_green)
		fi
		local last_hit_fmt
		last_hit_fmt=$(date -r "$hit_at" +"%Y-%m-%d %H:%M" 2>/dev/null || date -d "@${hit_at}" +"%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")
		local display_name
		display_name=$(provider_display_name "$provider")
		printf "  %-18s " "$display_name"
		echo -e "${status_color}${status}$(c_nc)  ${retry_after}s           ${hit_count}         ${last_hit_fmt}"
	done

	if [[ "$has_data" == "false" ]]; then
		echo "  No rate limit events recorded."
	fi
	echo ""
	return 0
}

# Show cache statistics
cmd_cache_stats() {
	if ! command -v sqlite3 &>/dev/null; then
		log_warn "sqlite3 not available — caching disabled"
		return 0
	fi
	if [[ ! -f "$IP_REP_CACHE_DB" ]]; then
		log_info "Cache database not yet initialised (no queries run yet)"
		return 0
	fi
	local now
	now=$(date +%s)
	echo ""
	echo -e "$(c_bold)$(c_cyan)=== IP Reputation Cache Statistics ===$(c_nc)"
	echo -e "Database: ${IP_REP_CACHE_DB}"
	echo ""
	sqlite3 "$IP_REP_CACHE_DB" <<SQL 2>/dev/null || true
.mode column
.headers on
SELECT
    provider,
    COUNT(*) AS total_entries,
    SUM(CASE WHEN (cached_at + ttl) > ${now} THEN 1 ELSE 0 END) AS valid,
    SUM(CASE WHEN (cached_at + ttl) <= ${now} THEN 1 ELSE 0 END) AS expired,
    MIN(datetime(cached_at, 'unixepoch')) AS oldest,
    MAX(datetime(cached_at, 'unixepoch')) AS newest
FROM ip_cache
GROUP BY provider
ORDER BY provider;
SQL
	echo ""
	return 0
}

# Clear cache entries
cmd_cache_clear() {
	local specific_provider=""
	local specific_ip=""
	local _arg _val

	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
		--help | -h)
			print_usage_cache_clear
			return 0
			;;
		--provider | -p)
			_val="$2"
			specific_provider="$_val"
			shift 2
			;;
		--ip)
			_val="$2"
			specific_ip="$_val"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if ! command -v sqlite3 &>/dev/null; then
		log_warn "sqlite3 not available — caching disabled"
		return 0
	fi
	if [[ ! -f "$IP_REP_CACHE_DB" ]]; then
		log_info "Cache database not found — nothing to clear"
		return 0
	fi

	# Validate inputs before use in SQL to prevent injection
	if [[ -n "$specific_provider" ]] && ! sanitize_provider "$specific_provider"; then
		log_error "Invalid provider name: ${specific_provider}"
		return 1
	fi
	if [[ -n "$specific_ip" ]] && ! [[ "$specific_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		log_error "Invalid IP address: ${specific_ip}"
		return 1
	fi

	local deleted
	if [[ -n "$specific_provider" && -n "$specific_ip" ]]; then
		deleted=$(sqlite3 "$IP_REP_CACHE_DB" \
			"DELETE FROM ip_cache WHERE provider=? AND ip=?; SELECT changes();" \
			"$specific_provider" "$specific_ip" \
			2>/dev/null || echo "0")
	elif [[ -n "$specific_provider" ]]; then
		deleted=$(sqlite3 "$IP_REP_CACHE_DB" \
			"DELETE FROM ip_cache WHERE provider=?; SELECT changes();" \
			"$specific_provider" \
			2>/dev/null || echo "0")
	elif [[ -n "$specific_ip" ]]; then
		deleted=$(sqlite3 "$IP_REP_CACHE_DB" \
			"DELETE FROM ip_cache WHERE ip=?; SELECT changes();" \
			"$specific_ip" \
			2>/dev/null || echo "0")
	else
		deleted=$(sqlite3 "$IP_REP_CACHE_DB" \
			"DELETE FROM ip_cache; SELECT changes();" \
			2>/dev/null || echo "0")
	fi
	log_success "Cleared ${deleted} cache entries"
	return 0
}

# =============================================================================
# Core Commands
# =============================================================================

# Parse cmd_check arguments. Outputs: ip<TAB>specific_provider<TAB>run_parallel<TAB>timeout_secs<TAB>output_format<TAB>use_cache
# Returns 1 if --help was requested (caller should return 0) or on error.
_check_parse_args() {
	local ip=""
	local specific_provider=""
	local run_parallel=true
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local output_format="$IP_REP_DEFAULT_FORMAT"
	local use_cache="true"
	local _arg _val

	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
		--help | -h)
			print_usage_check
			return 1
			;;
		--provider | -p)
			_val="$2"
			specific_provider="$_val"
			shift 2
			;;
		--timeout | -t)
			_val="$2"
			timeout_secs="$_val"
			shift 2
			;;
		--format | -f)
			_val="$2"
			output_format="$_val"
			shift 2
			;;
		--parallel)
			run_parallel=true
			shift
			;;
		--sequential)
			run_parallel=false
			shift
			;;
		--no-cache)
			use_cache="false"
			shift
			;;
		--no-color)
			IP_REP_NO_COLOR="true"
			disable_colors
			shift
			;;
		# Batch-mode passthrough flags (ignored in single-check context)
		--rate-limit | --dnsbl-overlap)
			[[ "$_arg" == "--rate-limit" ]] && shift
			shift
			;;
		-*)
			log_warn "Unknown option: $_arg"
			shift
			;;
		*)
			if [[ -z "$ip" ]]; then
				ip="$_arg"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$ip" ]]; then
		log_error "IP address required"
		echo "Usage: $(basename "$0") check <ip> [options]" >&2
		return 2
	fi

	if ! echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
		log_error "Invalid IPv4 address: ${ip}"
		return 2
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$ip" "$specific_provider" "$run_parallel" "$timeout_secs" "$output_format" "$use_cache"
	return 0
}

# Run providers (parallel or sequential) and populate result_files array.
# Writes JSON results to files under tmp_dir; caller passes result_files by name.
# Usage: _check_run_providers ip timeout_secs use_cache run_parallel tmp_dir providers...
_check_run_providers() {
	local ip="$1"
	local timeout_secs="$2"
	local use_cache="$3"
	local run_parallel="$4"
	local tmp_dir="$5"
	shift 5
	local providers_to_run=("$@")

	local -a result_files=()
	local -a pids=()

	if [[ "$run_parallel" == "true" && ${#providers_to_run[@]} -gt 1 ]]; then
		local provider
		for provider in "${providers_to_run[@]}"; do
			local result_file="${tmp_dir}/${provider}.json"
			result_files+=("$result_file")
			(
				local result
				result=$(run_provider "$provider" "$ip" "$timeout_secs" "$use_cache")
				echo "$result" >"$result_file"
			) &
			pids+=($!)
		done
		local pid
		for pid in "${pids[@]}"; do
			wait "$pid" 2>/dev/null || true
		done
	else
		local provider
		for provider in "${providers_to_run[@]}"; do
			local result_file="${tmp_dir}/${provider}.json"
			result_files+=("$result_file")
			local result
			result=$(run_provider "$provider" "$ip" "$timeout_secs" "$use_cache")
			echo "$result" >"$result_file"
		done
	fi

	# Output result file paths (one per line) for caller to collect
	local f
	for f in "${result_files[@]}"; do
		echo "$f"
	done
	return 0
}

# Check a single IP address
cmd_check() {
	local parsed_row
	parsed_row=$(_check_parse_args "$@") || {
		local rc=$?
		# rc=1 means --help was shown; rc=2 means validation error
		[[ "$rc" -eq 1 ]] && return 0
		return 1
	}

	local ip specific_provider run_parallel timeout_secs output_format use_cache
	IFS=$'\t' read -r ip specific_provider run_parallel timeout_secs output_format use_cache \
		<<<"$parsed_row"

	log_info "Checking IP reputation for: ${ip}"
	cache_init

	# Determine providers to use
	local -a providers_to_run=()
	if [[ -n "$specific_provider" ]]; then
		if is_provider_available "$specific_provider"; then
			providers_to_run+=("$specific_provider")
		else
			log_error "Provider '${specific_provider}' not available"
			cmd_providers
			return 1
		fi
	else
		local available
		available=$(get_available_providers) || return 1
		read -ra providers_to_run <<<"$available"
	fi

	log_info "Using providers: ${providers_to_run[*]}"

	local tmp_dir
	tmp_dir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '${tmp_dir}'" RETURN

	local -a result_files=()
	while IFS= read -r rf; do
		result_files+=("$rf")
	done < <(_check_run_providers "$ip" "$timeout_secs" "$use_cache" "$run_parallel" \
		"$tmp_dir" "${providers_to_run[@]}")

	local merged
	merged=$(merge_results "$ip" "${result_files[@]}") || {
		log_error "Failed to merge provider results"
		return 1
	}

	output_results "$merged" "$output_format"
	return 0
}

# DNSBL overlap check — performs standalone DNS lookups against common blacklists.
# Returns JSON array of blacklists the IP appears on.
# Uses the same DNSBL zones as email-health-check-helper.sh for cross-tool consistency.
dnsbl_overlap_check() {
	local ip="$1"

	if ! command -v dig &>/dev/null; then
		echo "[]"
		return 0
	fi

	# Reverse IP for DNSBL lookup
	local reversed_ip
	reversed_ip=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')

	# Common DNSBL zones (same set used by email-health-check-helper.sh)
	local blacklists="zen.spamhaus.org bl.spamcop.net b.barracudacentral.org"
	local listed_on="[]"

	local bl
	for bl in $blacklists; do
		local result
		result=$(dig A "${reversed_ip}.${bl}" +short 2>/dev/null || true)
		if [[ -n "$result" && "$result" != *"NXDOMAIN"* ]]; then
			listed_on=$(echo "$listed_on" | jq --arg bl "$bl" '. + [$bl]')
		fi
	done

	echo "$listed_on"
	return 0
}

# Parse cmd_batch arguments. Outputs: file<TAB>output_format<TAB>timeout_secs<TAB>specific_provider<TAB>use_cache<TAB>rate_limit<TAB>dnsbl_overlap
# Returns 1 if --help was shown; 2 on validation error.
_batch_parse_args() {
	local file=""
	local output_format="$IP_REP_DEFAULT_FORMAT"
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local specific_provider=""
	local use_cache="true"
	local rate_limit="${IP_REP_RATE_LIMIT:-2}"
	local dnsbl_overlap=false
	local _arg _val

	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
		--help | -h)
			print_usage_batch
			return 1
			;;
		--format | -f)
			_val="$2"
			output_format="$_val"
			shift 2
			;;
		--timeout | -t)
			_val="$2"
			timeout_secs="$_val"
			shift 2
			;;
		--provider | -p)
			_val="$2"
			specific_provider="$_val"
			shift 2
			;;
		--no-cache)
			use_cache="false"
			shift
			;;
		--no-color)
			IP_REP_NO_COLOR="true"
			disable_colors
			shift
			;;
		--rate-limit)
			_val="$2"
			rate_limit="$_val"
			shift 2
			;;
		--dnsbl-overlap)
			dnsbl_overlap=true
			shift
			;;
		-*)
			log_warn "Unknown option: $_arg"
			shift
			;;
		*)
			if [[ -z "$file" ]]; then
				file="$_arg"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$file" ]]; then
		log_error "File path required"
		echo "Usage: $(basename "$0") batch <file> [options]" >&2
		return 2
	fi

	if [[ ! -f "$file" ]]; then
		log_error "File not found: ${file}"
		return 2
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$file" "$output_format" "$timeout_secs" "$specific_provider" \
		"$use_cache" "$rate_limit" "$dnsbl_overlap"
	return 0
}

# Process a single IP in batch mode: check + optional DNSBL overlap.
# Outputs updated batch_results JSON array to stdout.
# Returns 0 on success, 1 if check failed (caller should skip).
_batch_process_ip() {
	local line="$1"
	local timeout_secs="$2"
	local specific_provider="$3"
	local use_cache="$4"
	local dnsbl_overlap="$5"
	local batch_results="$6"

	local check_args=("$line" "--format" "json" "--timeout" "$timeout_secs")
	[[ -n "$specific_provider" ]] && check_args+=("--provider" "$specific_provider")
	[[ "$use_cache" == "false" ]] && check_args+=("--no-cache")

	local result
	result=$(cmd_check "${check_args[@]}" 2>/dev/null) || return 1

	if [[ "$dnsbl_overlap" == "true" ]]; then
		local dnsbl_hits dnsbl_count
		dnsbl_hits=$(dnsbl_overlap_check "$line")
		dnsbl_count=$(echo "$dnsbl_hits" | jq 'length')
		result=$(echo "$result" | jq \
			--argjson dnsbl_hits "$dnsbl_hits" \
			--argjson dnsbl_count "$dnsbl_count" \
			'. + {dnsbl_overlap: {listed_on: $dnsbl_hits, count: $dnsbl_count}}')
	fi

	echo "$batch_results" | jq --argjson r "$result" '. + [$r]'
	return 0
}

# Print batch summary header and flagged IP list.
_batch_print_summary() {
	local file="$1"
	local processed="$2"
	local clean="$3"
	local flagged="$4"
	local dnsbl_overlap="$5"
	local batch_results="$6"
	local output_format="$7"

	echo ""
	echo -e "$(c_bold)$(c_cyan)=== Batch Results ===$(c_nc)"
	echo -e "File:     ${file}"
	echo -e "Total:    ${processed} IPs processed"
	echo -e "Clean:    $(c_green)${clean}$(c_nc)"
	echo -e "Flagged:  $(c_red)${flagged}$(c_nc)"
	[[ "$dnsbl_overlap" == "true" ]] && echo -e "DNSBL:    overlap check enabled"
	echo ""

	if [[ "$flagged" -gt 0 ]]; then
		echo -e "$(c_bold)Flagged IPs:$(c_nc)"
		local _nc_batch
		_nc_batch=$(c_nc)
		echo "$batch_results" | jq -r \
			'.[] | select(.risk_level != "clean") | "\(.ip)\t\(.risk_level)\t\(.unified_score)\t\(.recommendation)"' \
			2>/dev/null |
			while IFS=$'\t' read -r batch_ip risk score rec; do
				# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
				local color risk_upper _saved_ifs="$IFS"
				IFS=$' \t\n'
				color=$(risk_color "$risk")
				IFS="$_saved_ifs"
				# Use tr for case conversion — safe as external command with IFS reset via prefix
				risk_upper=$(IFS=$' \t\n' tr '[:lower:]' '[:upper:]' <<<"$risk")
				echo -e "  ${batch_ip}  ${color}${risk_upper}${_nc_batch} (${score})  ${rec}"
			done
		echo ""
	fi

	if [[ "$output_format" == "json" ]]; then
		jq -n \
			--arg file "$file" \
			--argjson total "$processed" \
			--argjson clean "$clean" \
			--argjson flagged "$flagged" \
			--argjson results "$batch_results" \
			'{file: $file, total: $total, clean: $clean, flagged: $flagged, results: $results}'
	fi
	return 0
}

# Batch check IPs from a file (one IP per line)
# Supports rate limiting across providers and optional DNSBL overlap
cmd_batch() {
	local parsed_row
	parsed_row=$(_batch_parse_args "$@") || {
		local rc=$?
		[[ "$rc" -eq 1 ]] && return 0
		return 1
	}

	local file output_format timeout_secs specific_provider use_cache rate_limit dnsbl_overlap
	IFS=$'\t' read -r file output_format timeout_secs specific_provider \
		use_cache rate_limit dnsbl_overlap <<<"$parsed_row"

	cache_init

	local total=0
	local processed=0
	local clean=0
	local flagged=0

	total=$(safe_grep_count -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' "$file")
	log_info "Processing ${total} IPs from ${file} (rate limit: ${rate_limit} req/s per provider)"

	local batch_results="[]"

	# Validate rate_limit is a positive integer
	if ! [[ "$rate_limit" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid --rate-limit value '${rate_limit}' — must be a positive integer; defaulting to 2"
		rate_limit=2
	fi

	# Rate limiting: sleep a fixed interval between IPs
	# rate_limit=2 means 2 IPs/second → sleep 0.5s between IPs
	# Uses awk for portable float division (bash doesn't do floats)
	local sleep_between
	if [[ "$rate_limit" -gt 0 ]]; then
		sleep_between=$(awk "BEGIN {printf \"%.3f\", 1/$rate_limit}")
	else
		sleep_between="0"
	fi

	local first_ip=true

	while IFS= read -r line; do
		[[ -z "$line" || "$line" =~ ^# ]] && continue

		if ! echo "$line" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
			log_warn "Skipping invalid IP: ${line}"
			continue
		fi

		if [[ "$sleep_between" != "0" && "$first_ip" == "false" ]]; then
			sleep "$sleep_between" 2>/dev/null || true
		fi
		first_ip=false

		processed=$((processed + 1))
		log_info "[${processed}/${total}] Checking ${line}..."

		local updated_results
		updated_results=$(_batch_process_ip "$line" "$timeout_secs" "$specific_provider" \
			"$use_cache" "$dnsbl_overlap" "$batch_results") || {
			log_warn "Failed to check ${line}"
			continue
		}
		batch_results="$updated_results"

		local risk_level
		risk_level=$(echo "$batch_results" | jq -r '.[-1].risk_level // "unknown"')
		if [[ "$risk_level" == "clean" ]]; then
			clean=$((clean + 1))
		else
			flagged=$((flagged + 1))
		fi

	done <"$file"

	_batch_print_summary "$file" "$processed" "$clean" "$flagged" \
		"$dnsbl_overlap" "$batch_results" "$output_format"
	return 0
}

# Generate detailed markdown report for an IP
cmd_report() {
	local ip=""
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local specific_provider=""
	local _arg _val

	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
		--help | -h)
			print_usage_report
			return 0
			;;
		--timeout | -t)
			_val="$2"
			timeout_secs="$_val"
			shift 2
			;;
		--provider | -p)
			_val="$2"
			specific_provider="$_val"
			shift 2
			;;
		-*)
			log_warn "Unknown option: $_arg"
			shift
			;;
		*)
			if [[ -z "$ip" ]]; then
				ip="$_arg"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$ip" ]]; then
		log_error "IP address required"
		echo "Usage: $(basename "$0") report <ip> [options]" >&2
		return 1
	fi

	local check_args=("$ip" "--format" "json" "--timeout" "$timeout_secs")
	[[ -n "$specific_provider" ]] && check_args+=("--provider" "$specific_provider")

	local result
	result=$(cmd_check "${check_args[@]}") || return 1

	format_markdown "$result"
	return 0
}

# List all providers and their status
cmd_providers() {
	echo ""
	echo -e "$(c_bold)$(c_cyan)=== IP Reputation Providers ===$(c_nc)"
	echo ""
	printf "  %-18s %-20s %-10s %-12s %s\n" "Provider" "Display Name" "Status" "Key Req." "Free Tier"
	printf "  %-18s %-20s %-10s %-12s %s\n" "--------" "------------" "------" "--------" "---------"

	local provider
	for provider in $ALL_PROVIDERS; do
		local script
		script=$(provider_script "$provider")
		local script_path="${PROVIDERS_DIR}/${script}"
		local display_name
		display_name=$(provider_display_name "$provider")

		local status key_req free_tier
		if [[ -x "$script_path" ]]; then
			# Get info from provider
			local info
			info=$("$script_path" info 2>/dev/null || echo '{}')
			key_req=$(echo "$info" | jq -r '.requires_key // false | if . then "yes" else "no" end')
			free_tier=$(echo "$info" | jq -r '.free_tier // "unknown"')
			status="$(c_green)available$(c_nc)"
		else
			status="$(c_red)missing$(c_nc)"
			key_req="-"
			free_tier="-"
		fi

		printf "  %-18s %-20s " "$provider" "$display_name"
		echo -e "${status}  ${key_req}          ${free_tier}"
	done

	echo ""
	echo -e "Provider scripts location: ${PROVIDERS_DIR}/"
	echo -e "Each provider implements: check <ip> [--api-key <key>] [--timeout <s>]"
	echo ""
	return 0
}
