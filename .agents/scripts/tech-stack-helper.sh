#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Tech Stack Helper — orchestrates multiple tech detection providers
# to replicate BuiltWith.com capabilities for single-site lookup,
# reverse lookup, reporting, and cached results.
#
# Usage:
#   tech-stack-helper.sh lookup <url>                  Detect tech stack of a URL
#   tech-stack-helper.sh reverse <technology>           Find sites using a technology
#   tech-stack-helper.sh report <url>                   Generate full markdown report
#   tech-stack-helper.sh cache [stats|clear|get <url>]  Manage SQLite cache
#   tech-stack-helper.sh providers                      List available providers
#   tech-stack-helper.sh categories                     List technology categories (BigQuery)
#   tech-stack-helper.sh trending                       Show trending technologies (BigQuery)
#   tech-stack-helper.sh info <technology>              Get technology metadata (BigQuery)
#   tech-stack-helper.sh help                           Show this help
#
# Options:
#   --json          Output raw JSON
#   --markdown      Output markdown report
#   --no-cache      Skip cache for this request
#   --provider <p>  Use only specified provider (unbuilt|crft|openexplorer|wappalyzer)
#   --parallel      Run providers in parallel (default)
#   --sequential    Run providers sequentially
#   --timeout <s>   Per-provider timeout in seconds (default: 60)
#   --cache-ttl <h> Cache TTL in hours (default: 168 = 7 days)
#
# Providers (t1064-t1067):
#   unbuilt       — Unbuilt.app CLI (frontend/JS detection)
#   crft          — CRFT Lookup (Wappalyzer-fork, Lighthouse scores)
#   openexplorer  — Open Tech Explorer (general detection)
#   wappalyzer    — Wappalyzer OSS fork (self-hosted fallback)
#
# Environment:
#   TECH_STACK_CACHE_DIR   Override cache directory
#   TECH_STACK_CACHE_TTL   Cache TTL in hours (default: 168)
#   TECH_STACK_TIMEOUT     Per-provider timeout in seconds (default: 60)

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck disable=SC2034
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true
init_log_file

# =============================================================================
# Configuration
# =============================================================================

# shellcheck disable=SC2034 # VERSION used in format_markdown/format_reverse_markdown output
readonly VERSION="1.0.0"
readonly CACHE_DIR="${TECH_STACK_CACHE_DIR:-${HOME}/.aidevops/.agent-workspace/work/tech-stack}"
readonly CACHE_DB="${CACHE_DIR}/cache.db"
readonly TS_DEFAULT_CACHE_TTL="${TECH_STACK_CACHE_TTL:-168}" # hours
readonly TS_DEFAULT_TIMEOUT="${TECH_STACK_TIMEOUT:-60}"      # seconds

# Provider list (bash 3.2 compatible — no associative arrays)
readonly PROVIDERS="unbuilt crft openexplorer wappalyzer"

# File-based cache for BigQuery results
readonly BQ_CACHE_DIR="${CACHE_DIR}/bq"
CACHE_TTL_DAYS=30
readonly DEFAULT_LIMIT=25
readonly MAX_LIMIT=1000
readonly DEFAULT_CLIENT="desktop"
readonly REPORTS_DIR="${HOME}/.aidevops/.agent-workspace/work/tech-stack/reports"
readonly UNBUILT_TIMEOUT="${UNBUILT_TIMEOUT:-120}"

# BigQuery configuration
readonly BQ_PROJECT_HTTPARCHIVE="httparchive"
readonly BQ_DATASET_CRAWL="crawl"
readonly BQ_TABLE_PAGES="pages"
readonly BQ_DATASET_WAPPALYZER="wappalyzer"
readonly BQ_TABLE_TECH_DETECTIONS="tech_detections"
readonly BQ_TABLE_TECHNOLOGIES="technologies"
readonly BQ_TABLE_CATEGORIES="categories"

# BuiltWith configuration
readonly BUILTWITH_API_BASE="https://api.builtwith.com"

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"

# Technology categories for structured output (referenced by provider helpers)
# shellcheck disable=SC2034 # exported for provider helper scripts
readonly TECH_CATEGORIES="frameworks,cms,analytics,cdn,hosting,bundlers,ui-libs,state-management,styling,languages,databases,monitoring,security,seo,performance"

# Ensure directories exist
mkdir -p "$CACHE_DIR" "$BQ_CACHE_DIR" "$REPORTS_DIR" 2>/dev/null || true

# =============================================================================
# Sub-libraries
# =============================================================================

# shellcheck source=./tech-stack-cache-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-cache-lib.sh"

# shellcheck source=./tech-stack-bq-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-bq-lib.sh"

# shellcheck source=./tech-stack-providers-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-providers-lib.sh"

# shellcheck source=./tech-stack-merge-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-merge-lib.sh"

# shellcheck source=./tech-stack-format-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-format-lib.sh"

# shellcheck source=./tech-stack-lookup-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-lookup-lib.sh"

# shellcheck source=./tech-stack-commands-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-commands-lib.sh"

# =============================================================================
# Help
# =============================================================================

print_usage() {
	cat <<'EOF'
Tech Stack Helper — Open-source BuiltWith alternative

USAGE:
    tech-stack-helper.sh <command> [options]

COMMANDS:
    lookup <url>                  Detect the full tech stack of a URL
    reverse <technology>          Find sites using a specific technology
    report <url>                  Generate a full markdown report
    cache [stats|clear|get <url>] Manage the SQLite result cache
    providers                     List available detection providers
    categories                    List technology categories (BigQuery)
    trending                      Show trending technologies (BigQuery)
    info <technology>             Get technology metadata (BigQuery)
    help                          Show this help message

OPTIONS:
    --json              Output raw JSON
    --markdown          Output markdown report
    --no-cache          Skip cache for this request
    --provider <name>   Use only the specified provider
    --parallel          Run providers in parallel (default)
    --sequential        Run providers sequentially
    --timeout <secs>    Per-provider timeout (default: 60)
    --cache-ttl <hours> Cache TTL in hours (default: 168 = 7 days)

PROVIDERS:
    unbuilt       Unbuilt.app — frontend/JS detection (t1064)
    crft          CRFT Lookup — Wappalyzer-fork + Lighthouse (t1065)
    openexplorer  Open Tech Explorer — general detection (t1066)
    wappalyzer    Wappalyzer OSS — self-hosted fallback (t1067)

EXAMPLES:
    tech-stack-helper.sh lookup example.com
    tech-stack-helper.sh lookup https://github.com --json
    tech-stack-helper.sh lookup example.com --provider unbuilt
    tech-stack-helper.sh reverse "React" --json
    tech-stack-helper.sh reverse WordPress --limit 50 --traffic top10k
    tech-stack-helper.sh reverse React --region uk --format table
    tech-stack-helper.sh report example.com > report.md
    tech-stack-helper.sh cache stats
    tech-stack-helper.sh cache clear expired
    tech-stack-helper.sh cache get example.com
    tech-stack-helper.sh providers
    tech-stack-helper.sh categories --format table
    tech-stack-helper.sh trending --direction adopted --limit 30
    tech-stack-helper.sh info WordPress --detections

PROVIDER INTERFACE:
    Each provider helper must implement:
      <provider>-provider-helper.sh lookup <url> --json
    
    Expected JSON output schema:
      {
        "provider": "<name>",
        "url": "<scanned-url>",
        "technologies": [
          {
            "name": "React",
            "category": "ui-libs",
            "version": "18.2",
            "confidence": 0.9
          }
        ],
        "meta": { ... }
      }

    Categories: frameworks, cms, analytics, cdn, hosting, bundlers,
    ui-libs, state-management, styling, languages, databases,
    monitoring, security, seo, performance

CACHE:
    Results are cached in SQLite at:
      ~/.aidevops/.agent-workspace/work/tech-stack/cache.db
    Default TTL: 7 days. Override with --cache-ttl or TECH_STACK_CACHE_TTL.

DATA SOURCES (reverse lookup):
    Primary:  HTTP Archive via BigQuery (crawl.pages + Wappalyzer detection)
    Fallback: BuiltWith API (requires API key)
    Prerequisites for BigQuery:
      - Google Cloud SDK (brew install google-cloud-sdk)
      - GCP project with BigQuery API enabled (free tier: 1TB/month)
      - gcloud auth login && gcloud config set project YOUR_PROJECT
EOF

	return 0
}

usage() {
	print_usage
	return 0
}

# =============================================================================
# Main Command Router
# =============================================================================

# Parse global options from main()'s argument list.
# Writes parsed values to out_file as shell variable assignments.
# Remaining positional args are written one-per-line to positional_file.
_main_parse_global_opts() {
	local out_file="$1"
	local positional_file="$2"
	shift 2

	local output_format="table" use_cache="true" specific_provider=""
	local run_parallel="true"
	local timeout_secs="$TS_DEFAULT_TIMEOUT"
	local cache_ttl="$TS_DEFAULT_CACHE_TTL"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			output_format="json"
			shift
			;;
		--markdown)
			output_format="markdown"
			shift
			;;
		--no-cache)
			use_cache="false"
			shift
			;;
		--provider)
			specific_provider="${2:-}"
			shift 2
			;;
		--parallel)
			run_parallel="true"
			shift
			;;
		--sequential)
			run_parallel="false"
			shift
			;;
		--timeout)
			timeout_secs="${2:-$TS_DEFAULT_TIMEOUT}"
			shift 2
			;;
		--cache-ttl)
			cache_ttl="${2:-$TS_DEFAULT_CACHE_TTL}"
			shift 2
			;;
		-h | --help)
			print_usage
			printf 'HELP\n' >"$out_file"
			return 1
			;;
		*)
			printf '%s\n' "$1" >>"$positional_file"
			shift
			;;
		esac
	done

	cat >"$out_file" <<ENDVARS
output_format=$output_format
use_cache=$use_cache
specific_provider=$specific_provider
run_parallel=$run_parallel
timeout_secs=$timeout_secs
cache_ttl=$cache_ttl
ENDVARS
	return 0
}

# Route a parsed command to the appropriate cmd_* function.
_main_route_command() {
	local command="$1"
	local use_cache="$2"
	local output_format="$3"
	local specific_provider="$4"
	local run_parallel="$5"
	local timeout_secs="$6"
	local cache_ttl="$7"
	shift 7
	local -a positional=("$@")

	case "$command" in
	lookup)
		local url="${positional[0]:-}"
		if [[ -z "$url" ]]; then
			log_error "URL is required. Usage: tech-stack-helper.sh lookup <url>"
			return 1
		fi
		cmd_lookup "$url" "$use_cache" "$output_format" "$specific_provider" "$run_parallel" "$timeout_secs" "$cache_ttl"
		;;
	reverse)
		local technology="${positional[0]:-}"
		if [[ -z "$technology" ]]; then
			log_error "Technology name is required. Usage: tech-stack-helper.sh reverse <technology>"
			return 1
		fi
		local -a filters=()
		if [[ ${#positional[@]} -gt 1 ]]; then
			filters=("${positional[@]:1}")
		fi
		cmd_reverse "$technology" ${filters[@]+"${filters[@]}"}
		;;
	report)
		local url="${positional[0]:-}"
		if [[ -z "$url" ]]; then
			log_error "URL is required. Usage: tech-stack-helper.sh report <url>"
			return 1
		fi
		cmd_report "$url" "$use_cache" "$specific_provider" "$timeout_secs" "$cache_ttl"
		;;
	cache)
		local subcmd="${positional[0]:-stats}"
		case "$subcmd" in
		stats) cache_stats ;;
		clear) cache_clear "${positional[1]:-expired}" ;;
		get)
			local url="${positional[1]:-}"
			if [[ -z "$url" ]]; then
				log_error "URL is required. Usage: tech-stack-helper.sh cache get <url>"
				return 1
			fi
			cache_get "$url"
			;;
		*)
			log_error "Unknown cache command: ${subcmd}. Use: stats, clear, get"
			return 1
			;;
		esac
		;;
	providers) list_providers ;;
	categories) cmd_categories ${positional[@]+"${positional[@]}"} ;;
	trending) cmd_trending ${positional[@]+"${positional[@]}"} ;;
	info)
		local technology="${positional[0]:-}"
		if [[ -z "$technology" ]]; then
			log_error "Technology name is required. Usage: tech-stack-helper.sh info <technology>"
			return 1
		fi
		cmd_info "$technology" "${positional[@]:1}"
		;;
	help | -h | --help) print_usage ;;
	version) echo "tech-stack-helper.sh v${VERSION}" ;;
	*)
		log_error "Unknown command: ${command}"
		print_usage
		return 1
		;;
	esac
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	local opts_file positional_file
	opts_file=$(mktemp)
	positional_file=$(mktemp)
	trap 'rm -f "${opts_file:-}" "${positional_file:-}"' RETURN

	if ! _main_parse_global_opts "$opts_file" "$positional_file" "$@"; then
		local sentinel
		sentinel=$(cat "$opts_file" 2>/dev/null || echo "ERROR")
		[[ "$sentinel" == "HELP" ]] && return 0
		return 1
	fi

	# shellcheck disable=SC1090
	source "$opts_file"

	local -a positional=()
	if [[ -s "$positional_file" ]]; then
		while IFS= read -r pos; do
			positional+=("$pos")
		done <"$positional_file"
	fi

	check_dependencies || return 1
	init_cache_db || true

	_main_route_command "$command" "$use_cache" "$output_format" \
		"$specific_provider" "$run_parallel" "$timeout_secs" "$cache_ttl" \
		"${positional[@]+"${positional[@]}"}"
	return $?
}

main "$@"
