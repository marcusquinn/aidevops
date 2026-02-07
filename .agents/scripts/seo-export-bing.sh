#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# SEO Export - Bing Webmaster Tools
# Exports Bing search analytics data to TOON format
#
# Usage: seo-export-bing.sh <domain> [options]
#
# Author: AI DevOps Framework
# Version: 1.0.0

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
    source "$SCRIPT_DIR/shared-constants.sh"
fi

# =============================================================================
# Configuration
# =============================================================================

readonly SEO_DATA_DIR="$HOME/.aidevops/.agent-workspace/work/seo-data"
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly DEFAULT_DAYS=90

# =============================================================================
# Utility Functions
# =============================================================================

# =============================================================================
# Bing API Functions
# =============================================================================

# Get API key from environment
get_api_key() {
    source "$CONFIG_DIR/credentials.sh" 2>/dev/null || true
    
    if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
        print_error "BING_WEBMASTER_API_KEY not configured"
        print_error "Set it in ~/.config/aidevops/credentials.sh"
        return 1
    fi
    
    echo "$BING_WEBMASTER_API_KEY"
    return 0
}

# Make Bing API request
bing_request() {
    local endpoint="$1"
    local site_url="$2"
    local api_key
    
    api_key=$(get_api_key) || return 1
    
    local encoded_url
    encoded_url=$(echo -n "$site_url" | jq -sRr @uri)
    
    curl -s -X GET \
        "https://ssl.bing.com/webmaster/api.svc/json/$endpoint?siteUrl=$encoded_url&apikey=$api_key"
    return 0
}

# Get query statistics
bing_query_stats() {
    local site_url="$1"
    bing_request "GetQueryStats" "$site_url"
    return 0
}

# Get page stats for ranking URLs
bing_page_stats() {
    local site_url="$1"
    bing_request "GetPageStats" "$site_url"
    return 0
}

# =============================================================================
# TOON Conversion
# =============================================================================

# Convert Bing JSON response to TOON format
json_to_toon() {
    local query_json="$1"
    local _page_json="$2"  # Reserved for future page-level stats integration
    local domain="$3"
    local start_date="$4"
    local end_date="$5"
    local exported
    
    exported=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Header section
    cat << EOF
domain	$domain
source	bing
exported	$exported
start_date	$start_date
end_date	$end_date
---
query	page	clicks	impressions	ctr	position
EOF
    
    # Bing returns query stats and page stats separately
    # We need to combine them - for now, output query stats with empty page
    # The API returns: Query, Impressions, Clicks, AvgPosition, AvgCTR
    echo "$query_json" | jq -r '.d[]? | [.Query, "", .Clicks, .Impressions, .AvgCTR, .AvgPosition] | @tsv' 2>/dev/null || true
    
    return 0
}

# =============================================================================
# Main Export Function
# =============================================================================

export_bing() {
    local domain="$1"
    local days="$2"
    
    # Calculate date range
    local end_date
    local start_date
    end_date=$(date +%Y-%m-%d)
    if date -v-1d &>/dev/null; then
        start_date=$(date -v-${days}d +%Y-%m-%d)
    else
        start_date=$(date -d "$days days ago" +%Y-%m-%d)
    fi
    
    # Site URL format for Bing
    local site_url="https://$domain/"
    
    print_info "Fetching Bing data for $domain ($start_date to $end_date)..."
    
    # Check credentials first
    local api_key
    api_key=$(get_api_key) || return 1
    
    # Get query stats
    local query_response
    query_response=$(bing_query_stats "$site_url")
    
    if [[ -z "$query_response" ]]; then
        print_error "Failed to fetch Bing query stats"
        return 1
    fi
    
    # Check for errors
    if echo "$query_response" | jq -e '.ErrorCode' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$query_response" | jq -r '.Message // "Unknown error"')
        print_error "Bing API error: $error_msg"
        return 1
    fi
    
    # Get page stats (optional, for URL data)
    local page_response
    page_response=$(bing_page_stats "$site_url") || page_response="{}"
    
    # Count rows
    local row_count
    row_count=$(echo "$query_response" | jq '.d | length' 2>/dev/null || echo "0")
    
    if [[ "$row_count" == "0" ]] || [[ "$row_count" == "null" ]]; then
        print_warning "No data returned from Bing"
        print_warning "Ensure the site is verified in Bing Webmaster Tools"
        return 1
    fi
    
    print_info "Retrieved $row_count rows"
    
    # Create output directory
    local domain_dir="$SEO_DATA_DIR/$domain"
    mkdir -p "$domain_dir"
    
    # Generate output filename
    local output_file="$domain_dir/bing-${start_date}-${end_date}.toon"
    
    # Convert to TOON and save
    json_to_toon "$query_response" "$page_response" "$domain" "$start_date" "$end_date" > "$output_file"
    
    print_success "Exported to: $output_file"
    print_info "Rows: $row_count"
    
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << 'EOF'
SEO Export - Bing Webmaster Tools

Export Bing search analytics data to TOON format.

Usage:
    seo-export-bing.sh <domain> [options]

Options:
    --days N       Number of days to export (default: 90)
    --help, -h     Show this help message

Examples:
    # Export last 90 days
    seo-export-bing.sh example.com

    # Export last 30 days
    seo-export-bing.sh example.com --days 30

Output:
    ~/.aidevops/.agent-workspace/work/seo-data/{domain}/bing-{start}-{end}.toon

Requirements:
    - BING_WEBMASTER_API_KEY set in ~/.config/aidevops/credentials.sh
    - Site must be verified in Bing Webmaster Tools

API Key Setup:
    1. Go to https://www.bing.com/webmasters
    2. Sign in and verify your site
    3. Go to Settings > API Access
    4. Generate API Key
    5. Add to credentials.sh: export BING_WEBMASTER_API_KEY="your_key"

EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local domain=""
    local days="$DEFAULT_DAYS"
    local arg
    
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --days)
                local next_arg="${2:-}"
                if [[ -z "$next_arg" ]] || [[ "$next_arg" == -* ]]; then
                    print_error "--days requires a numeric value"
                    return 1
                fi
                days="$next_arg"
                shift 2
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            -*)
                print_error "Unknown option: $arg"
                return 1
                ;;
            *)
                if [[ -z "$domain" ]]; then
                    domain="$arg"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$domain" ]]; then
        print_error "Domain is required"
        echo "Usage: seo-export-bing.sh <domain> [--days N]"
        return 1
    fi
    
    # Check dependencies
    if ! command -v jq &>/dev/null; then
        print_error "jq is required but not installed"
        return 1
    fi
    
    export_bing "$domain" "$days"
    return $?
}

main "$@"
