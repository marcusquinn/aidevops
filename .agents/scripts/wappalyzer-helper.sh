#!/usr/bin/env bash
# shellcheck disable=SC1091

# Wappalyzer OSS Provider Helper
# Local/offline technology stack detection using Wappalyzer's detection engine
# Part of tech-stack-helper.sh orchestrator (t1063)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# Configuration
readonly WAPPALYZER_CACHE_DIR="$HOME/.aidevops/cache/wappalyzer"
readonly WAPPALYZER_MAX_WAIT="${WAPPALYZER_MAX_WAIT:-5000}"
readonly WAPPALYZER_TIMEOUT="${WAPPALYZER_TIMEOUT:-30}"

# Ensure cache directory exists
mkdir -p "$WAPPALYZER_CACHE_DIR"

# ============================================================================
# Dependency Management
# ============================================================================

check_wappalyzer() {
	if ! command -v wappalyzer &>/dev/null; then
		print_warning "Wappalyzer CLI not found"
		print_info "Install: npm install -g wappalyzer"
		return 1
	fi
	return 0
}

check_jq() {
	if ! command -v jq &>/dev/null; then
		print_error "jq is required for JSON parsing"
		print_info "Install: brew install jq"
		return 1
	fi
	return 0
}

install_deps() {
	print_info "Installing Wappalyzer dependencies..."

	if ! command -v jq &>/dev/null; then
		if command -v brew &>/dev/null; then
			brew install jq
		else
			print_error "Please install jq manually"
			return 1
		fi
	fi

	if ! command -v wappalyzer &>/dev/null; then
		if command -v npm &>/dev/null; then
			print_info "Installing Wappalyzer CLI..."
			npm install -g wappalyzer
		else
			print_error "npm required to install Wappalyzer"
			return 1
		fi
	fi

	print_success "Dependencies installed"
	return 0
}

# ============================================================================
# Detection Functions
# ============================================================================

wappalyzer_detect() {
	local url="$1"
	local output_file="${2:-}"

	if ! check_wappalyzer; then
		print_error "Wappalyzer not installed. Run: $0 install"
		return 1
	fi

	print_info "Analyzing $url with Wappalyzer..."

	# Run Wappalyzer with JSON output
	local temp_output
	temp_output=$(mktemp)

	if timeout "$WAPPALYZER_TIMEOUT" wappalyzer "$url" \
		--format=json \
		--max-wait="$WAPPALYZER_MAX_WAIT" \
		--probe \
		>"$temp_output" 2>/dev/null; then

		if [[ -n "$output_file" ]]; then
			cp "$temp_output" "$output_file"
		else
			cat "$temp_output"
		fi

		rm -f "$temp_output"
		print_success "Detection complete"
		return 0
	else
		local exit_code=$?
		rm -f "$temp_output"
		print_error "Wappalyzer detection failed (exit code: $exit_code)"
		return 1
	fi
}

wappalyzer_normalize() {
	local input_file="$1"

	if ! check_jq; then
		print_error "jq not installed"
		return 1
	fi

	if [[ ! -f "$input_file" ]]; then
		print_error "Input file not found: $input_file"
		return 1
	fi

	# Transform Wappalyzer output to common schema
	jq '{
        provider: "wappalyzer",
        url: (.urls | keys[0]),
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        technologies: [
            (.urls | to_entries[0].value.technologies[] | {
                name: .name,
                slug: .slug,
                version: (.version // null),
                category: (.categories[0].name // "Unknown"),
                confidence: .confidence,
                description: (.description // null),
                website: (.website // null),
                source: "wappalyzer"
            })
        ]
    }' "$input_file"
}

wappalyzer_detect_and_normalize() {
	local url="$1"

	local temp_raw
	temp_raw=$(mktemp)

	if wappalyzer_detect "$url" "$temp_raw"; then
		wappalyzer_normalize "$temp_raw"
		local result=$?
		rm -f "$temp_raw"
		return $result
	else
		rm -f "$temp_raw"
		return 1
	fi
}

# ============================================================================
# Cache Management
# ============================================================================

cache_key() {
	local url="$1"
	echo -n "$url" | shasum -a 256 | cut -d' ' -f1
}

cache_get() {
	local url="$1"
	local key
	key=$(cache_key "$url")
	local cache_file="$WAPPALYZER_CACHE_DIR/$key.json"

	if [[ -f "$cache_file" ]]; then
		# Check if cache is less than 7 days old
		local cache_age
		cache_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)))

		if [[ $cache_age -lt 604800 ]]; then
			cat "$cache_file"
			return 0
		else
			print_info "Cache expired for $url"
			rm -f "$cache_file"
		fi
	fi

	return 1
}

cache_set() {
	local url="$1"
	local data="$2"
	local key
	key=$(cache_key "$url")
	local cache_file="$WAPPALYZER_CACHE_DIR/$key.json"

	echo "$data" >"$cache_file"
}

# ============================================================================
# CLI Commands
# ============================================================================

cmd_detect() {
	local url="${1:-}"

	if [[ -z "$url" ]]; then
		print_error "Usage: $0 detect <url>"
		return 1
	fi

	wappalyzer_detect_and_normalize "$url"
}

cmd_detect_cached() {
	local url="${1:-}"

	if [[ -z "$url" ]]; then
		print_error "Usage: $0 detect-cached <url>"
		return 1
	fi

	# Try cache first
	if cache_get "$url"; then
		print_info "Using cached result for $url" >&2
		return 0
	fi

	# Detect and cache
	local result
	if result=$(wappalyzer_detect_and_normalize "$url"); then
		cache_set "$url" "$result"
		echo "$result"
		return 0
	else
		return 1
	fi
}

cmd_install() {
	install_deps
}

cmd_status() {
	print_info "Wappalyzer Provider Status"
	echo ""

	if check_wappalyzer; then
		local version
		version=$(wappalyzer --version 2>/dev/null || echo "unknown")
		print_success "Wappalyzer CLI: installed (version: $version)"
	else
		print_error "Wappalyzer CLI: not installed"
	fi

	if check_jq; then
		print_success "jq: installed"
	else
		print_error "jq: not installed"
	fi

	echo ""
	print_info "Cache directory: $WAPPALYZER_CACHE_DIR"

	local cache_count
	cache_count=$(find "$WAPPALYZER_CACHE_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
	print_info "Cached results: $cache_count"
}

cmd_cache_clear() {
	print_info "Clearing Wappalyzer cache..."
	rm -rf "${WAPPALYZER_CACHE_DIR:?}"/*
	print_success "Cache cleared"
}

cmd_help() {
	cat <<EOF
Wappalyzer OSS Provider Helper

Usage: $0 <command> [options]

Commands:
  detect <url>          Detect technologies for a URL (no cache)
  detect-cached <url>   Detect with 7-day cache
  install               Install Wappalyzer CLI and dependencies
  status                Show installation and cache status
  cache-clear           Clear cached results
  help                  Show this help message

Examples:
  $0 detect https://example.com
  $0 detect-cached https://example.com
  $0 install
  $0 status

Environment Variables:
  WAPPALYZER_MAX_WAIT   Max wait time in ms (default: 5000)
  WAPPALYZER_TIMEOUT    Command timeout in seconds (default: 30)

Output Format:
  JSON with common schema:
  {
    "provider": "wappalyzer",
    "url": "https://example.com",
    "timestamp": "2026-02-16T21:30:00Z",
    "technologies": [
      {
        "name": "React",
        "slug": "react",
        "version": "18.2.0",
        "category": "JavaScript frameworks",
        "confidence": 100,
        "source": "wappalyzer"
      }
    ]
  }

Related:
  - Subagent: .agents/tools/research/providers/wappalyzer.md
  - Orchestrator: tech-stack-helper.sh (t1063)
  - Task: t1067

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	detect)
		cmd_detect "$@"
		;;
	detect-cached)
		cmd_detect_cached "$@"
		;;
	install)
		cmd_install
		;;
	status)
		cmd_status
		;;
	cache-clear)
		cmd_cache_clear
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
