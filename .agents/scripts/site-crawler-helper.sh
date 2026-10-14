#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2034

# Site Crawler Helper Script -- Orchestrator
# SEO site auditing with Screaming Frog-like capabilities
# Uses Crawl4AI when available, falls back to lightweight Python crawler
#
# Sub-libraries:
#   site-crawler-helper-markdown.sh   -- metadata extraction & markdown saving
#   site-crawler-helper-crawl4ai.sh   -- Crawl4AI API engine & report generation
#   site-crawler-helper-librecrawl.sh -- LibreCrawl REST API engine & export mapping
#   site-crawler-helper-fallback.sh   -- fallback Python crawler generator
#
# Usage: ./site-crawler-helper.sh [command] [url] [options]
# Commands:
#   crawl           - Full site crawl with SEO data extraction
#   audit-links     - Check for broken links (4XX/5XX)
#   audit-meta      - Audit page titles and meta descriptions
#   audit-redirects - Analyze redirects and chains
#   generate-sitemap - Generate XML sitemap from crawl
#   compare         - Compare two crawls
#   status          - Check crawler dependencies
#   help            - Show this help message
#
# Author: AI DevOps Framework
# Version: 2.0.0
# License: MIT

set -euo pipefail

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly CONFIG_DIR="${HOME}/.config/aidevops"
readonly CONFIG_FILE="${CONFIG_DIR}/site-crawler.json"
readonly DEFAULT_OUTPUT_DIR="${HOME}/Downloads"
readonly CRAWL4AI_PORT="11235"
readonly CRAWL4AI_URL="http://localhost:${CRAWL4AI_PORT}"
readonly ENGINE_AUTO="auto"
readonly ENGINE_LIBRECRAWL="librecrawl"
readonly ENGINE_CRAWL4AI="crawl4ai"
readonly ENGINE_FALLBACK="fallback"

# Default configuration
DEFAULT_DEPTH=3
DEFAULT_MAX_URLS=100
DEFAULT_DELAY=100
DEFAULT_FORMAT="xlsx"
RESPECT_ROBOTS=true
USE_CRAWL4AI=false

# Detect Python with required packages
PYTHON_CMD=""

# --- Source sub-libraries ---

# shellcheck source=./site-crawler-helper-markdown.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/site-crawler-helper-markdown.sh"

# shellcheck source=./site-crawler-helper-crawl4ai.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/site-crawler-helper-crawl4ai.sh"

# shellcheck source=./site-crawler-helper-librecrawl.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/site-crawler-helper-librecrawl.sh"

# shellcheck source=./site-crawler-helper-seoprostats.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/site-crawler-helper-seoprostats.sh"

# shellcheck source=./site-crawler-helper-fallback.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/site-crawler-helper-fallback.sh"

# --- Utility functions ---

# Print functions
print_header() {
	echo -e "${PURPLE}=== $1 ===${NC}"
	return 0
}

# Check if Crawl4AI is available
check_crawl4ai() {
	if curl -s --connect-timeout 2 "${CRAWL4AI_URL}/health" &>/dev/null; then
		USE_CRAWL4AI=true
		return 0
	fi
	return 1
}

# Find working Python with dependencies
find_python() {
	local pythons=("python3.11" "python3.12" "python3.10" "python3")
	local user_site="${HOME}/Library/Python/3.11/lib/python/site-packages"

	for py in "${pythons[@]}"; do
		# Check if python exists and has the required modules
		if command -v "$py" &>/dev/null &&
			PYTHONPATH="${user_site}:${PYTHONPATH:-}" "$py" -c "import aiohttp, bs4" 2>/dev/null; then
			PYTHON_CMD="$py"
			export PYTHONPATH="${user_site}:${PYTHONPATH:-}"
			return 0
		fi
	done
	return 1
}

# Install Python dependencies
install_python_deps() {
	local pythons=("python3.11" "python3.12" "python3.10" "python3")

	for py in "${pythons[@]}"; do
		if command -v "$py" &>/dev/null; then
			print_info "Installing dependencies with $py..."
			"$py" -m pip install --user aiohttp beautifulsoup4 openpyxl 2>/dev/null && {
				PYTHON_CMD="$py"
				export PYTHONPATH="${HOME}/Library/Python/3.11/lib/python/site-packages:${PYTHONPATH:-}"
				return 0
			}
		fi
	done
	return 1
}

# Extract domain from URL
get_domain() {
	local url="$1"
	echo "$url" | sed -E 's|^https?://||' | sed -E 's|/.*||' | sed -E 's|:.*||'
}

# Create output directory structure
create_output_dir() {
	local domain="$1"
	local output_base="${2:-$DEFAULT_OUTPUT_DIR}"
	local timestamp
	timestamp=$(date +%Y-%m-%d_%H%M%S)

	local output_dir="${output_base}/${domain}/${timestamp}"
	mkdir -p "$output_dir"

	# Update _latest symlink
	local latest_link="${output_base}/${domain}/_latest"
	rm -f "$latest_link"
	ln -sf "$timestamp" "$latest_link"

	echo "$output_dir"
	return 0
}

# --- Crawl execution ---

# Parse do_crawl options into caller-local variables.
# Sets: depth, max_urls, format, output_base, engine
# LibreCrawl-only flags are recorded by librecrawl_store_opt.
_do_crawl_parse_opts() {
	depth="$DEFAULT_DEPTH"
	max_urls="$DEFAULT_MAX_URLS"
	format="$DEFAULT_FORMAT"
	output_base="$DEFAULT_OUTPUT_DIR"
	engine="$ENGINE_AUTO"
	push_site=""
	local value

	while [[ $# -gt 0 ]]; do
		local value="${2:-}"
		case "$1" in
		--depth | --max-urls | --format | --output | --engine | --push-seoprostats)
			if [[ $# -lt 2 ]]; then
				print_error "$1 needs a value"
				return 1
			fi
			case "$1" in
			--depth) depth="$2" ;;
			--max-urls) max_urls="$2" ;;
			--format) format="$2" ;;
			--output) output_base="$2" ;;
			--engine) engine="$2" ;;
			--push-seoprostats) push_site="$value" ;;
			esac
			shift 2
			;;
		--fallback)
			engine="$ENGINE_FALLBACK"
			shift
			;;
		--render-js | --ignore-robots | --include-pagespeed | --user-agent | --include | --exclude | --timeout)
			librecrawl_store_opt "$@" || return 1
			shift "$_LIBRECRAWL_OPT_SHIFT"
			;;
		--*)
			print_warning "Ignoring unknown option: $1"
			shift
			;;
		*) shift ;;
		esac
	done
	return 0
}

# Resolve the requested engine to librecrawl, crawl4ai or fallback.
# Sets caller-local: engine. Fails before any output directory is created.
_do_crawl_select_engine() {
	case "$engine" in
	auto | librecrawl | crawl4ai | fallback) ;;
	*)
		print_error "Unknown --engine: $engine (use auto, librecrawl, crawl4ai or fallback)"
		return 1
		;;
	esac

	local wants_librecrawl=false
	[[ "$engine" == "$ENGINE_LIBRECRAWL" ]] && wants_librecrawl=true

	if [[ -n "$LIBRECRAWL_ONLY_FLAGS" && "$engine" != "$ENGINE_AUTO" && "$wants_librecrawl" == false ]]; then
		print_error "${LIBRECRAWL_ONLY_FLAGS}: needs --engine librecrawl (the ${engine} engine does not implement it)"
		return 1
	fi

	if [[ "$engine" == "$ENGINE_AUTO" || "$wants_librecrawl" == true ]]; then
		if check_librecrawl && librecrawl_is_usable; then
			engine="$ENGINE_LIBRECRAWL"
			return 0
		fi
		if [[ "$wants_librecrawl" == true || -n "$LIBRECRAWL_ONLY_FLAGS" || "$_LIBRECRAWL_ACCOUNT_CONFIGURED" == true ]]; then
			[[ -n "$LIBRECRAWL_ONLY_FLAGS" ]] && print_error "${LIBRECRAWL_ONLY_FLAGS}: needs the LibreCrawl engine"
			print_error "No usable LibreCrawl session at ${LIBRECRAWL_URL}${LIBRECRAWL_TIER:+ (tier: ${LIBRECRAWL_TIER})} (use local mode or an account)"
			_librecrawl_local_mode_help
			return 1
		fi
		[[ -n "$LIBRECRAWL_TIER" ]] && print_warning "LibreCrawl answers at ${LIBRECRAWL_URL} but is not in local mode; skipping it"
		engine="$ENGINE_FALLBACK"
		check_crawl4ai && engine="$ENGINE_CRAWL4AI"
		return 0
	fi

	if [[ "$engine" == "$ENGINE_CRAWL4AI" ]] && ! check_crawl4ai; then
		print_error "Crawl4AI is not running at ${CRAWL4AI_URL} (setup: crawl4ai-helper.sh)"
		return 1
	fi
	return 0
}

# Report a finished crawl.
# Arguments: $1=output_dir $2=output_base $3=domain
_do_crawl_print_done() {
	local output_dir="$1"
	local output_base="$2"
	local domain="$3"
	print_success "Crawl complete!"
	print_info "Results: $output_dir"
	print_info "Latest: ${output_base}/${domain}/_latest"
	return 0
}

# Run the Python fallback crawler for do_crawl.
# Arguments: $1=url $2=output_dir $3=max_urls $4=depth $5=format $6=output_base $7=domain
_do_crawl_run_python() {
	local url="$1"
	local output_dir="$2"
	local max_urls="$3"
	local depth="$4"
	local format="$5"
	local output_base="$6"
	local domain="$7"

	print_info "Using lightweight Python crawler..."

	if ! find_python; then
		print_warning "Installing Python dependencies..."
		if ! install_python_deps; then
			print_error "Could not find or install Python with required packages"
			print_info "Install manually: pip3 install aiohttp beautifulsoup4 openpyxl"
			return 1
		fi
	fi

	print_info "Using: $PYTHON_CMD"

	local crawler_script
	# t2997: drop .py — XXXXXX must be at end for BSD mktemp.
	crawler_script=$(mktemp /tmp/site_crawler-XXXXXX)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${crawler_script}'"
	generate_fallback_crawler >"$crawler_script"

	"$PYTHON_CMD" "$crawler_script" "$url" "$output_dir" "$max_urls" "$depth" "$format"
	local exit_code=$?

	rm -f "$crawler_script"

	if [[ $exit_code -eq 0 ]]; then
		_do_crawl_print_done "$output_dir" "$output_base" "$domain"
	else
		print_error "Crawl failed with exit code $exit_code"
	fi

	return $exit_code
}

# Run crawl
do_crawl() {
	local url="$1"
	shift

	local depth max_urls format output_base engine push_site
	_do_crawl_parse_opts "$@" || return 1
	_do_crawl_select_engine || return 1
	# Validate before create_output_dir moves _latest to an empty directory
	if [[ "$engine" == "$ENGINE_LIBRECRAWL" ]]; then
		_librecrawl_validate_limits "$max_urls" "$depth" || return 1
	fi

	local domain
	domain=$(get_domain "$url")

	local output_dir
	output_dir=$(create_output_dir "$domain" "$output_base")

	print_header "Site Crawler - SEO Audit"
	print_info "URL: $url"
	print_info "Output: $output_dir"
	print_info "Depth: $depth, Max URLs: $max_urls, Engine: $engine"

	if [[ "$engine" == "$ENGINE_LIBRECRAWL" ]]; then
		if ! crawl_with_librecrawl "$url" "$output_dir" "$max_urls" "$depth"; then
			print_error "LibreCrawl crawl failed or was incomplete"
			print_info "Results so far: $output_dir"
			return 1
		fi
		_do_crawl_print_done "$output_dir" "$output_base" "$domain"
		[[ -z "$push_site" ]] || push_seoprostats "$output_dir" --site "$push_site" || return 1
		return 0
	fi

	if [[ "$engine" == "$ENGINE_CRAWL4AI" ]]; then
		print_success "Crawl4AI detected at ${CRAWL4AI_URL}"
		crawl_with_crawl4ai "$url" "$output_dir" "$max_urls" "$depth" || return 1
		_do_crawl_print_done "$output_dir" "$output_base" "$domain"
		[[ -z "$push_site" ]] || push_seoprostats "$output_dir" --site "$push_site" || return 1
		return 0
	fi

	_do_crawl_run_python "$url" "$output_dir" "$max_urls" "$depth" "$format" "$output_base" "$domain" || return 1
	[[ -z "$push_site" ]] || push_seoprostats "$output_dir" --site "$push_site" || return 1
	return 0
}

# --- Audit commands ---

# Audit broken links
audit_links() {
	local url="$1"
	shift
	print_info "Running broken link audit..."
	do_crawl "$url" --max-urls 200 "$@"
	return 0
}

# Audit meta data
audit_meta() {
	local url="$1"
	shift
	print_info "Running meta data audit..."
	do_crawl "$url" --max-urls 200 "$@"
	return 0
}

# Audit redirects
audit_redirects() {
	local url="$1"
	shift
	print_info "Running redirect audit..."
	do_crawl "$url" --max-urls 200 "$@"
	return 0
}

# Generate XML sitemap
generate_sitemap() {
	local url="$1"
	local domain
	domain=$(get_domain "$url")
	local output_dir="${DEFAULT_OUTPUT_DIR}/${domain}/_latest"

	if [[ ! -d "$output_dir" ]]; then
		print_error "No crawl data found. Run 'crawl' first."
		return 1
	fi

	local crawl_data="${output_dir}/crawl-data.csv"
	if [[ ! -f "$crawl_data" ]]; then
		print_error "Crawl data not found: $crawl_data"
		return 1
	fi

	print_header "Generating XML Sitemap"

	local sitemap="${output_dir}/sitemap.xml"

	{
		echo '<?xml version="1.0" encoding="UTF-8"?>'
		echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'

		tail -n +2 "$crawl_data" | while IFS=, read -r page_url status_code rest; do
			if [[ "$status_code" == "200" ]]; then
				page_url="${page_url//\"/}"
				echo "  <url>"
				echo "    <loc>$page_url</loc>"
				echo "    <changefreq>weekly</changefreq>"
				echo "    <priority>0.5</priority>"
				echo "  </url>"
			fi
		done

		echo '</urlset>'
	} >"$sitemap"

	print_success "Sitemap generated: $sitemap"
	return 0
}

# Compare crawls
compare_crawls() {
	local arg1="${1:-}"
	local arg2="${2:-}"

	print_header "Comparing Crawls"

	if [[ -z "$arg2" ]] && [[ -n "$arg1" ]]; then
		local domain
		domain=$(get_domain "$arg1")
		local domain_dir="${DEFAULT_OUTPUT_DIR}/${domain}"

		if [[ ! -d "$domain_dir" ]]; then
			print_error "No crawl data found for domain"
			return 1
		fi

		local crawls
		crawls=$(find "$domain_dir" -maxdepth 1 -type d -name "20*" | sort -r | head -2)
		local count
		count=$(echo "$crawls" | wc -l | tr -d ' ')

		if [[ $count -lt 2 ]]; then
			print_error "Need at least 2 crawls to compare"
			return 1
		fi

		arg1=$(echo "$crawls" | head -1)
		arg2=$(echo "$crawls" | tail -1)
	fi

	print_info "Crawl 1: $arg1"
	print_info "Crawl 2: $arg2"

	if [[ -f "${arg1}/crawl-data.csv" ]] && [[ -f "${arg2}/crawl-data.csv" ]]; then
		local urls1 urls2
		urls1=$(cut -d, -f1 "${arg1}/crawl-data.csv" | tail -n +2 | sort -u | wc -l | tr -d ' ')
		urls2=$(cut -d, -f1 "${arg2}/crawl-data.csv" | tail -n +2 | sort -u | wc -l | tr -d ' ')

		print_info "Crawl 1 URLs: $urls1"
		print_info "Crawl 2 URLs: $urls2"
	fi

	return 0
}

# Check status
check_status() {
	print_header "Site Crawler Status"

	# Check LibreCrawl
	print_info "Checking LibreCrawl..."
	if check_librecrawl; then
		if librecrawl_is_local; then
			print_success "LibreCrawl: running at ${LIBRECRAWL_URL} (local mode)"
		else
			print_info "LibreCrawl: running at ${LIBRECRAWL_URL} (tier: ${LIBRECRAWL_TIER:-none})"
		fi
	else
		print_warning "LibreCrawl: not reachable at ${LIBRECRAWL_URL} (optional; see seo/librecrawl.md)"
	fi

	# Check Crawl4AI
	print_info "Checking Crawl4AI..."
	if check_crawl4ai; then
		print_success "Crawl4AI: Running at ${CRAWL4AI_URL}"
	else
		print_warning "Crawl4AI: Not running (will use fallback crawler)"
	fi

	# Check Python
	print_info "Checking Python..."
	if find_python; then
		print_success "Python: $PYTHON_CMD with required packages"
	else
		print_warning "Python: Dependencies not installed"
		print_info "  Install with: pip3 install aiohttp beautifulsoup4 openpyxl"
	fi

	# Check dependencies
	if command -v jq &>/dev/null; then
		print_success "jq: installed"
	else
		print_warning "jq: not installed (optional, for JSON processing)"
	fi

	if command -v curl &>/dev/null; then
		print_success "curl: installed"
	else
		print_error "curl: not installed (required)"
	fi

	return 0
}

# --- CLI ---

# Show help
show_help() {
	cat <<'EOF'
Site Crawler Helper - SEO Spider Tool

Usage: site-crawler-helper.sh [command] [url] [options]

Commands:
  crawl <url>           Full site crawl with SEO data extraction
  audit-links <url>     Check for broken links (4XX/5XX errors)
  audit-meta <url>      Audit page titles and meta descriptions
  audit-redirects <url> Analyze redirects and chains
  generate-sitemap <url> Generate XML sitemap from crawl
  compare [url|dir1] [dir2] Compare two crawls
  push-seoprostats <dir> --site <hostname> [--transport auto|ssh|rest] [--timeout <seconds>]
                        Import a saved crawl into SEO Pro Stats 1.11.0+
  status                Check crawler dependencies
  help                  Show this help message

Options:
  --depth <n>           Max crawl depth (default: 3; LibreCrawl accepts 1-10)
  --max-urls <n>        Max URLs to crawl (default: 100)
  --format <fmt>        Output format: csv, xlsx, all (default: xlsx)
  --output <dir>        Output directory (default: ~/Downloads)
  --engine <name>       auto (default), librecrawl, crawl4ai or fallback
  --fallback            Same as --engine fallback
  --push-seoprostats <hostname>  Import after a successful crawl (SSH if ready, else REST)

LibreCrawl-only options (other engines reject them):
  --render-js           Render JavaScript in Chromium (SPAs)
  --user-agent <ua>     Custom user agent
  --ignore-robots       Do not obey robots.txt
  --include <regex,..>  Only crawl URLs matching a regex (repeatable)
  --exclude <regex,..>  Skip URLs matching a regex (repeatable)
  --include-pagespeed   PageSpeed for the home page and 2 section pages
                        (key: GOOGLE_API_KEY env or aidevops secret)
  --timeout <min>       Stop and export partial results after N minutes (default: 60)

Engine selection (auto):
  LibreCrawl when it answers in local mode or with configured account credentials at LIBRECRAWL_URL
  (default http://127.0.0.1:5000), else Crawl4AI, else the fallback crawler.

Examples:
  # Full site crawl
  site-crawler-helper.sh crawl https://example.com

  # Limited crawl
  site-crawler-helper.sh crawl https://example.com --depth 2 --max-urls 50

  # LibreCrawl with JavaScript rendering, skipping admin paths
  site-crawler-helper.sh crawl https://example.com --engine librecrawl \
    --render-js --exclude '/wp-admin/,/wp-json/'

  # Quick broken link check
  site-crawler-helper.sh audit-links https://example.com

  # Generate sitemap from existing crawl
  site-crawler-helper.sh generate-sitemap https://example.com

  # Check status
  site-crawler-helper.sh status

Output Structure:
  ~/Downloads/{domain}/{timestamp}/
    - crawl-data.xlsx      Full crawl data
    - crawl-data.csv       Full crawl data (CSV)
    - broken-links.csv     4XX/5XX errors
    - redirects.csv        Redirect chains
    - meta-issues.csv      Title/description issues
    - summary.json         Crawl statistics
    - librecrawl-urls.json, librecrawl-links.csv, librecrawl-issues.csv
                           Raw LibreCrawl exports (LibreCrawl engine only)

  ~/Downloads/{domain}/_latest -> symlink to latest crawl

Backends:
  - LibreCrawl: self-hosted SEO crawler (seo/librecrawl.md); used when it answers
  - Crawl4AI: Docker-based Crawl4AI when available
  - Fallback: Lightweight async Python crawler

Related:
  - E-E-A-T scoring: eeat-score-helper.sh
  - Crawl4AI setup: crawl4ai-helper.sh
  - PageSpeed: pagespeed-helper.sh
EOF
	return 0
}

# Main function
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	crawl)
		do_crawl "$@"
		;;
	audit-links)
		audit_links "$@"
		;;
	audit-meta)
		audit_meta "$@"
		;;
	audit-redirects)
		audit_redirects "$@"
		;;
	generate-sitemap)
		generate_sitemap "$@"
		;;
	compare)
		compare_crawls "$@"
		;;
	status)
		check_status
		;;
	push-seoprostats)
		push_seoprostats "$@"
		;;
	help | -h | --help | "")
		show_help
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac

	return 0
}

main "$@"
