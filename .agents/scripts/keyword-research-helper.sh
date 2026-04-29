#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2086,SC2155,SC2162

# Keyword Research Helper Script -- Orchestrator
# Comprehensive keyword research with SERP weakness detection and opportunity scoring
# Providers: DataForSEO (primary), Serper (alternative), Ahrefs (optional)
# Webmaster Tools: Google Search Console, Bing Webmaster Tools (for owned sites)
#
# Sub-libraries:
#   - keyword-research-helper-providers.sh  (DataForSEO, Serper, Ahrefs API)
#   - keyword-research-helper-webmaster.sh  (GSC, Bing, combined webmaster research)
#   - keyword-research-helper-analysis.sh   (SERP detection, scoring, formatting, research)

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	source "$SCRIPT_DIR/shared-constants.sh"
fi

# =============================================================================
# Configuration
# =============================================================================

readonly CONFIG_FILE="$HOME/.config/aidevops/keyword-research.json"
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly DOWNLOADS_DIR="$HOME/Downloads"
readonly CACHE_DIR="$HOME/.cache/aidevops/keyword-research"

# Default settings
DEFAULT_LOCALE="us-en"
DEFAULT_PROVIDER="dataforseo"
DEFAULT_LIMIT=100
MAX_LIMIT=10000

# Location codes for DataForSEO (bash 3.2 compatible - no associative arrays)
get_location_code() {
	local locale="$1"
	case "$locale" in
	"us-en") echo "2840" ;;
	"uk-en") echo "2826" ;;
	"ca-en") echo "2124" ;;
	"au-en") echo "2036" ;;
	"de-de") echo "2276" ;;
	"fr-fr") echo "2250" ;;
	"es-es") echo "2724" ;;
	custom-*) echo "${locale#custom-}" ;;
	*) echo "2840" ;; # Default to US
	esac
	return 0
}

get_language_code() {
	local locale="$1"
	case "$locale" in
	"us-en" | "uk-en" | "ca-en" | "au-en") echo "en" ;;
	"de-de") echo "de" ;;
	"fr-fr") echo "fr" ;;
	"es-es") echo "es" ;;
	custom-*) echo "en" ;; # Default to English for custom
	*) echo "en" ;;
	esac
	return 0
}

# SERP Weakness thresholds
readonly THRESHOLD_LOW_DS=10
readonly THRESHOLD_LOW_PS=0
readonly THRESHOLD_SLOW_PAGE=3000
readonly THRESHOLD_HIGH_SPAM=50
readonly THRESHOLD_OLD_CONTENT_YEARS=2
readonly THRESHOLD_UGC_HEAVY=3

# =============================================================================
# Utility Functions
# =============================================================================

print_header() {
	local msg="$1"
	echo -e "${PURPLE}═══ $msg ═══${NC}"
	return 0
}
# Ensure directories exist
ensure_directories() {
	mkdir -p "$CONFIG_DIR"
	mkdir -p "$CACHE_DIR"
	return 0
}

# =============================================================================
# Configuration Management
# =============================================================================

load_config() {
	ensure_directories

	if [[ -f "$CONFIG_FILE" ]]; then
		# Load existing config
		DEFAULT_LOCALE=$(jq -r '.default_locale // "us-en"' "$CONFIG_FILE" 2>/dev/null || echo "us-en")
		DEFAULT_PROVIDER=$(jq -r '.default_provider // "dataforseo"' "$CONFIG_FILE" 2>/dev/null || echo "dataforseo")
		DEFAULT_LIMIT=$(jq -r '.default_limit // 100' "$CONFIG_FILE" 2>/dev/null || echo "100")
	fi

	return 0
}

save_config() {
	local locale="$1"
	local provider="$2"
	local limit="$3"

	ensure_directories

	cat >"$CONFIG_FILE" <<EOF
{
    "default_locale": "$locale",
    "default_provider": "$provider",
    "default_limit": $limit
}
EOF

	print_success "Configuration saved to $CONFIG_FILE"
	return 0
}

show_config() {
	print_header "Current Configuration"
	echo ""
	echo "  Locale:   $DEFAULT_LOCALE"
	echo "  Provider: $DEFAULT_PROVIDER"
	echo "  Limit:    $DEFAULT_LIMIT"
	echo ""
	echo "Config file: $CONFIG_FILE"
	echo ""
	return 0
}

# =============================================================================
# Credential Checking
# =============================================================================

check_credentials() {
	local provider="$1"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	case "$provider" in
	"dataforseo" | "both")
		if [[ -z "${DATAFORSEO_USERNAME:-}" ]] || [[ -z "${DATAFORSEO_PASSWORD:-}" ]]; then
			print_error "DataForSEO credentials not found."
			echo "  Set via: aidevops secret set DATAFORSEO_USERNAME <username>"
			echo "  Set via: aidevops secret set DATAFORSEO_PASSWORD <password>"
			echo "  Or add to ~/.config/aidevops/credentials.sh"
			return 1
		fi
		;;
	"serper")
		if [[ -z "${SERPER_API_KEY:-}" ]]; then
			print_error "Serper API key not found."
			echo "  Set via: aidevops secret set SERPER_API_KEY <key>"
			echo "  Or add to ~/.config/aidevops/credentials.sh"
			return 1
		fi
		;;
	"ahrefs")
		if [[ -z "${AHREFS_API_KEY:-}" ]]; then
			print_error "Ahrefs API key not found."
			echo "  Set via: aidevops secret set AHREFS_API_KEY <key>"
			echo "  Or add to ~/.config/aidevops/credentials.sh"
			return 1
		fi
		;;
	esac

	return 0
}

# =============================================================================
# Locale Selection
# =============================================================================

prompt_locale() {
	echo ""
	echo "Available locales:"
	echo "  1) us-en  (United States)"
	echo "  2) uk-en  (United Kingdom)"
	echo "  3) ca-en  (Canada)"
	echo "  4) au-en  (Australia)"
	echo "  5) de-de  (Germany)"
	echo "  6) fr-fr  (France)"
	echo "  7) es-es  (Spain)"
	echo "  8) Custom location code"
	echo ""
	read -p "Select locale [1-8] (default: 1): " choice

	case "${choice:-1}" in
	1) echo "us-en" ;;
	2) echo "uk-en" ;;
	3) echo "ca-en" ;;
	4) echo "au-en" ;;
	5) echo "de-de" ;;
	6) echo "fr-fr" ;;
	7) echo "es-es" ;;
	8)
		read -p "Enter custom location code: " custom_code
		echo "custom-$custom_code"
		;;
	*) echo "us-en" ;;
	esac
	return 0
}

# =============================================================================
# Source sub-libraries
# =============================================================================

# shellcheck source=./keyword-research-helper-providers.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/keyword-research-helper-providers.sh"

# shellcheck source=./keyword-research-helper-webmaster.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/keyword-research-helper-webmaster.sh"

# shellcheck source=./keyword-research-helper-analysis.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/keyword-research-helper-analysis.sh"

# =============================================================================
# Help
# =============================================================================

show_help() {
	print_header "Keyword Research Helper"
	echo ""
	echo "Usage: $0 <command> [options]"
	echo ""
	echo "Commands:"
	echo "  research <keywords>       Basic keyword expansion"
	echo "  autocomplete <keyword>    Google autocomplete suggestions"
	echo "  extended <keywords>       Full SERP analysis with weakness detection"
	echo "  webmaster <site-url>      Keywords from GSC + Bing for your verified sites"
	echo "  sites                     List verified sites in GSC and Bing"
	echo "  config                    Show current configuration"
	echo "  set-config                Set default preferences"
	echo "  help                      Show this help"
	echo ""
	echo "Options:"
	echo "  --provider <name>         dataforseo, serper, or both (default: dataforseo)"
	echo "  --locale <code>           us-en, uk-en, ca-en, au-en, de-de, fr-fr, es-es"
	echo "  --limit <n>               Number of results (default: 100, max: 10000)"
	echo "  --days <n>                Days of data for webmaster tools (default: 30)"
	echo "  --csv                     Export results to CSV"
	echo "  --quick                   Skip weakness detection (extended only)"
	echo "  --no-enrich               Skip DataForSEO enrichment (webmaster only)"
	echo "  --ahrefs                  Include Ahrefs DR/UR metrics"
	echo "  --domain <domain>         Domain research mode"
	echo "  --competitor <domain>     Competitor research mode"
	echo "  --gap <your,competitor>   Keyword gap analysis"
	echo ""
	echo "Filters:"
	echo "  --min-volume <n>          Minimum search volume"
	echo "  --max-volume <n>          Maximum search volume"
	echo "  --min-difficulty <n>      Minimum keyword difficulty"
	echo "  --max-difficulty <n>      Maximum keyword difficulty"
	echo "  --intent <type>           Filter by intent (informational, commercial, etc.)"
	echo "  --contains <term>         Include keywords containing term"
	echo "  --excludes <term>         Exclude keywords containing term"
	echo ""
	echo "Examples:"
	echo "  $0 research \"best seo tools, keyword research\""
	echo "  $0 autocomplete \"how to lose weight\""
	echo "  $0 extended \"dog training\" --ahrefs"
	echo "  $0 extended --competitor petco.com --limit 500"
	echo "  $0 extended --gap mysite.com,competitor.com"
	echo "  $0 research \"seo\" --min-volume 1000 --max-difficulty 40 --csv"
	echo ""
	echo "Webmaster Tools (for your verified sites):"
	echo "  $0 sites                                    # List verified sites"
	echo "  $0 webmaster https://example.com           # Get keywords from GSC + Bing"
	echo "  $0 webmaster https://example.com --days 90 # Last 90 days"
	echo "  $0 webmaster https://example.com --no-enrich --csv"
	echo ""
	return 0
}

# =============================================================================
# Main
# =============================================================================

# Parse a single filter option (--min-volume, --max-volume, etc.) into _OPT_FILTERS.
# Arguments: $1=flag_name $2=value
# Returns 1 if the flag is not a filter option (caller should handle it).
_parse_filter_option() {
	local flag="$1"
	local value="$2"
	case "$flag" in
	--min-volume)
		_OPT_FILTERS="${_OPT_FILTERS:+$_OPT_FILTERS,}min-volume:$value"
		;;
	--max-volume)
		_OPT_FILTERS="${_OPT_FILTERS:+$_OPT_FILTERS,}max-volume:$value"
		;;
	--min-difficulty)
		_OPT_FILTERS="${_OPT_FILTERS:+$_OPT_FILTERS,}min-difficulty:$value"
		;;
	--max-difficulty)
		_OPT_FILTERS="${_OPT_FILTERS:+$_OPT_FILTERS,}max-difficulty:$value"
		;;
	--intent)
		_OPT_FILTERS="${_OPT_FILTERS:+$_OPT_FILTERS,}intent:$value"
		;;
	--contains)
		_OPT_FILTERS="${_OPT_FILTERS:+$_OPT_FILTERS,}contains:$value"
		;;
	--excludes)
		_OPT_FILTERS="${_OPT_FILTERS:+$_OPT_FILTERS,}excludes:$value"
		;;
	*)
		return 1
		;;
	esac
	return 0
}

# Parse CLI options into global variables for main() dispatch
# Sets: _OPT_KEYWORDS, _OPT_PROVIDER, _OPT_LOCALE, _OPT_LIMIT, _OPT_DAYS,
#       _OPT_CSV, _OPT_QUICK, _OPT_AHREFS, _OPT_ENRICH, _OPT_MODE,
#       _OPT_TARGET, _OPT_FILTERS
_parse_options() {
	_OPT_KEYWORDS=""
	_OPT_PROVIDER="$DEFAULT_PROVIDER"
	_OPT_LOCALE="$DEFAULT_LOCALE"
	_OPT_LIMIT="$DEFAULT_LIMIT"
	_OPT_DAYS="30"
	_OPT_CSV="false"
	_OPT_QUICK="false"
	_OPT_AHREFS="false"
	_OPT_ENRICH="true"
	_OPT_MODE=""
	_OPT_TARGET=""
	_OPT_FILTERS=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			_OPT_PROVIDER="$2"
			shift 2
			;;
		--locale)
			_OPT_LOCALE="$2"
			shift 2
			;;
		--limit)
			_OPT_LIMIT="$2"
			shift 2
			;;
		--days)
			_OPT_DAYS="$2"
			shift 2
			;;
		--csv)
			_OPT_CSV="true"
			shift
			;;
		--quick)
			_OPT_QUICK="true"
			shift
			;;
		--no-enrich)
			_OPT_ENRICH="false"
			shift
			;;
		--ahrefs)
			_OPT_AHREFS="true"
			shift
			;;
		--domain)
			_OPT_MODE="domain"
			_OPT_TARGET="$2"
			shift 2
			;;
		--competitor)
			_OPT_MODE="competitor"
			_OPT_TARGET="$2"
			shift 2
			;;
		--gap)
			_OPT_MODE="gap"
			_OPT_TARGET="$2"
			shift 2
			;;
		--min-volume | --max-volume | --min-difficulty | --max-difficulty | --intent | --contains | --excludes)
			_parse_filter_option "$1" "$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			show_help
			return 1
			;;
		*)
			_OPT_KEYWORDS="$1"
			shift
			;;
		esac
	done

	return 0
}

# Dispatch the parsed command to the appropriate research function
_dispatch_command() {
	local command="$1"

	case "$command" in
	"research")
		if [[ -z "$_OPT_KEYWORDS" ]]; then
			print_error "Keywords required"
			show_help
			return 1
		fi
		do_keyword_research "$_OPT_KEYWORDS" "$_OPT_PROVIDER" "$_OPT_LOCALE" "$_OPT_LIMIT" "$_OPT_CSV" "$_OPT_FILTERS"
		;;
	"autocomplete")
		if [[ -z "$_OPT_KEYWORDS" ]]; then
			print_error "Keyword required"
			show_help
			return 1
		fi
		do_autocomplete_research "$_OPT_KEYWORDS" "$_OPT_PROVIDER" "$_OPT_LOCALE" "$_OPT_CSV"
		;;
	"extended")
		if [[ -z "$_OPT_KEYWORDS" ]] && [[ -z "$_OPT_MODE" ]]; then
			print_error "Keywords or mode (--domain, --competitor, --gap) required"
			show_help
			return 1
		fi
		do_extended_research "$_OPT_KEYWORDS" "$_OPT_PROVIDER" "$_OPT_LOCALE" "$_OPT_LIMIT" "$_OPT_CSV" "$_OPT_QUICK" "$_OPT_AHREFS" "$_OPT_MODE" "$_OPT_TARGET"
		;;
	"webmaster")
		if [[ -z "$_OPT_KEYWORDS" ]]; then
			print_error "Site URL required (e.g., https://example.com)"
			show_help
			return 1
		fi
		do_webmaster_research "$_OPT_KEYWORDS" "$_OPT_DAYS" "$_OPT_LIMIT" "$_OPT_CSV" "$_OPT_ENRICH"
		;;
	"sites")
		do_list_sites
		;;
	"config")
		show_config
		;;
	"set-config")
		local new_locale
		new_locale=$(prompt_locale)
		local new_provider new_limit
		read -p "Default provider [dataforseo/serper/both] ($DEFAULT_PROVIDER): " new_provider
		new_provider="${new_provider:-$DEFAULT_PROVIDER}"
		read -p "Default limit ($DEFAULT_LIMIT): " new_limit
		new_limit="${new_limit:-$DEFAULT_LIMIT}"
		save_config "$new_locale" "$new_provider" "$new_limit"
		;;
	"help" | *)
		show_help
		;;
	esac

	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	# Load configuration
	load_config

	# Parse options
	_parse_options "$@" || return 1

	# Dispatch command
	_dispatch_command "$command"

	return 0
}

# Run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
