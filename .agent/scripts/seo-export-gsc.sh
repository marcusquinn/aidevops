#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# SEO Export - Google Search Console
# Exports GSC search analytics data to TOON format
#
# Usage: seo-export-gsc.sh <domain> [options]
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
readonly ROW_LIMIT=25000

# Colors
readonly RED="${COLOR_RED:-\033[0;31m}"
readonly GREEN="${COLOR_GREEN:-\033[0;32m}"
readonly BLUE="${COLOR_BLUE:-\033[0;34m}"
readonly YELLOW="${COLOR_YELLOW:-\033[1;33m}"
readonly NC="${COLOR_RESET:-\033[0m}"

# =============================================================================
# Utility Functions
# =============================================================================

print_info() { local msg="$1"; echo -e "${BLUE}[INFO]${NC} $msg"; return 0; }
print_success() { local msg="$1"; echo -e "${GREEN}[SUCCESS]${NC} $msg"; return 0; }
print_warning() { local msg="$1"; echo -e "${YELLOW}[WARNING]${NC} $msg"; return 0; }
print_error() { local msg="$1"; echo -e "${RED}[ERROR]${NC} $msg" >&2; return 0; }

# =============================================================================
# GSC API Functions
# =============================================================================

# Get access token from service account or environment
get_access_token() {
    source "$CONFIG_DIR/mcp-env.sh" 2>/dev/null || true
    
    if [[ -n "${GSC_ACCESS_TOKEN:-}" ]]; then
        echo "$GSC_ACCESS_TOKEN"
        return 0
    fi
    
    if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && [[ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
        local token
        token=$(gcloud auth application-default print-access-token 2>/dev/null || echo "")
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
    fi
    
    print_error "GSC credentials not configured"
    print_error "Set GOOGLE_APPLICATION_CREDENTIALS or GSC_ACCESS_TOKEN in ~/.config/aidevops/mcp-env.sh"
    return 1
}

# Make GSC API request
gsc_request() {
    local endpoint="$1"
    local data="$2"
    local token
    
    token=$(get_access_token) || return 1
    
    curl -s -X POST \
        "https://searchconsole.googleapis.com/webmasters/v3/$endpoint" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$data"
    return 0
}

# Get search analytics with query and page dimensions
gsc_search_analytics() {
    local site_url="$1"
    local start_date="$2"
    local end_date="$3"
    local row_limit="${4:-$ROW_LIMIT}"
    
    local encoded_url
    encoded_url=$(echo -n "$site_url" | jq -sRr @uri)
    
    local data
    data=$(cat << EOF
{
    "startDate": "$start_date",
    "endDate": "$end_date",
    "dimensions": ["query", "page"],
    "rowLimit": $row_limit,
    "startRow": 0
}
EOF
)
    
    gsc_request "sites/$encoded_url/searchAnalytics/query" "$data"
    return 0
}

# =============================================================================
# TOON Conversion
# =============================================================================

# Convert GSC JSON response to TOON format
json_to_toon() {
    local json="$1"
    local domain="$2"
    local start_date="$3"
    local end_date="$4"
    local exported
    
    exported=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Header section
    cat << EOF
domain	$domain
source	gsc
exported	$exported
start_date	$start_date
end_date	$end_date
---
query	page	clicks	impressions	ctr	position
EOF
    
    # Data rows - parse JSON and output tab-separated
    echo "$json" | jq -r '.rows[]? | [.keys[0], .keys[1], .clicks, .impressions, .ctr, .position] | @tsv' 2>/dev/null || true
    
    return 0
}

# =============================================================================
# Main Export Function
# =============================================================================

export_gsc() {
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
    
    # Determine site URL format (try both sc-domain and https)
    local site_url="sc-domain:$domain"
    
    print_info "Fetching GSC data for $domain ($start_date to $end_date)..."
    
    # Make API request
    local response
    response=$(gsc_search_analytics "$site_url" "$start_date" "$end_date") || {
        # Try https:// format if sc-domain fails
        print_warning "sc-domain format failed, trying https:// format..."
        site_url="https://$domain/"
        response=$(gsc_search_analytics "$site_url" "$start_date" "$end_date") || {
            print_error "Failed to fetch GSC data"
            return 1
        }
    }
    
    # Check for errors in response
    if echo "$response" | jq -e '.error' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"')
        print_error "GSC API error: $error_msg"
        return 1
    fi
    
    # Count rows
    local row_count
    row_count=$(echo "$response" | jq '.rows | length' 2>/dev/null || echo "0")
    
    if [[ "$row_count" == "0" ]] || [[ "$row_count" == "null" ]]; then
        print_warning "No data returned from GSC"
        print_warning "Ensure the service account has access to this property"
        return 1
    fi
    
    print_info "Retrieved $row_count rows"
    
    # Create output directory
    local domain_dir="$SEO_DATA_DIR/$domain"
    mkdir -p "$domain_dir"
    
    # Generate output filename
    local output_file="$domain_dir/gsc-${start_date}-${end_date}.toon"
    
    # Convert to TOON and save
    json_to_toon "$response" "$domain" "$start_date" "$end_date" > "$output_file"
    
    print_success "Exported to: $output_file"
    print_info "Rows: $row_count"
    
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << 'EOF'
SEO Export - Google Search Console

Export GSC search analytics data to TOON format.

Usage:
    seo-export-gsc.sh <domain> [options]

Options:
    --days N       Number of days to export (default: 90)
    --help, -h     Show this help message

Examples:
    # Export last 90 days
    seo-export-gsc.sh example.com

    # Export last 30 days
    seo-export-gsc.sh example.com --days 30

Output:
    ~/.aidevops/.agent-workspace/work/seo-data/{domain}/gsc-{start}-{end}.toon

Requirements:
    - GOOGLE_APPLICATION_CREDENTIALS pointing to service account JSON
    - Or GSC_ACCESS_TOKEN set in ~/.config/aidevops/mcp-env.sh
    - Service account must have access to the GSC property

EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local domain=""
    local days="$DEFAULT_DAYS"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                days="${2:-$DEFAULT_DAYS}"
                shift 2
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            -*)
                print_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$domain" ]]; then
                    domain="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$domain" ]]; then
        print_error "Domain is required"
        echo "Usage: seo-export-gsc.sh <domain> [--days N]"
        return 1
    fi
    
    # Check dependencies
    if ! command -v jq &>/dev/null; then
        print_error "jq is required but not installed"
        return 1
    fi
    
    export_gsc "$domain" "$days"
    return $?
}

main "$@"
