#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# SEO Export - DataForSEO
# Exports DataForSEO ranked keywords data to TOON format
#
# Usage: seo-export-dataforseo.sh <domain> [options]
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
readonly ROW_LIMIT=1000
readonly DFS_API_BASE="https://api.dataforseo.com/v3"

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
# DataForSEO API Functions
# =============================================================================

# Get auth header from environment
get_auth_header() {
    source "$CONFIG_DIR/mcp-env.sh" 2>/dev/null || true
    
    if [[ -z "${DATAFORSEO_USERNAME:-}" ]] || [[ -z "${DATAFORSEO_PASSWORD:-}" ]]; then
        print_error "DataForSEO credentials not configured"
        print_error "Set DATAFORSEO_USERNAME and DATAFORSEO_PASSWORD in ~/.config/aidevops/mcp-env.sh"
        return 1
    fi
    
    # Use -w0 on GNU base64 to prevent line wrapping, fall back to no flag on macOS
    echo -n "$DATAFORSEO_USERNAME:$DATAFORSEO_PASSWORD" | base64 -w0 2>/dev/null || echo -n "$DATAFORSEO_USERNAME:$DATAFORSEO_PASSWORD" | base64
    return 0
}

# Make DataForSEO API request
dfs_request() {
    local endpoint="$1"
    local data="$2"
    local auth
    
    auth=$(get_auth_header) || return 1
    
    curl -s -X POST \
        "$DFS_API_BASE/$endpoint" \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$data"
    return 0
}

# Get ranked keywords for a domain
dfs_ranked_keywords() {
    local domain="$1"
    local limit="${2:-$ROW_LIMIT}"
    local location="${3:-2840}"  # US by default
    local language="${4:-en}"
    
    local data
    data=$(cat << EOF
[{
    "target": "$domain",
    "location_code": $location,
    "language_code": "$language",
    "limit": $limit,
    "order_by": ["keyword_data.keyword_info.search_volume,desc"]
}]
EOF
)
    
    dfs_request "dataforseo_labs/google/ranked_keywords/live" "$data"
    return 0
}

# =============================================================================
# TOON Conversion
# =============================================================================

# Convert DataForSEO JSON response to TOON format
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
source	dataforseo
exported	$exported
start_date	$start_date
end_date	$end_date
---
query	page	clicks	impressions	ctr	position	volume	difficulty
EOF
    
    # Data rows - DataForSEO ranked_keywords structure:
    # tasks[0].result[0].items[] contains: keyword_data, ranked_serp_element
    echo "$json" | jq -r '
        .tasks[0].result[0].items[]? | 
        [
            .keyword_data.keyword,
            .ranked_serp_element.url,
            (.ranked_serp_element.etv // 0),
            ((.keyword_data.keyword_info.search_volume // 0) * 10),
            (if (.keyword_data.keyword_info.search_volume // 0) > 0 
             then ((.ranked_serp_element.etv // 0) / ((.keyword_data.keyword_info.search_volume // 0) * 10)) 
             else 0 end),
            .ranked_serp_element.rank_absolute,
            (.keyword_data.keyword_info.search_volume // 0),
            (.keyword_data.keyword_info.competition_level // "")
        ] | @tsv
    ' 2>/dev/null || true
    
    return 0
}

# =============================================================================
# Main Export Function
# =============================================================================

export_dataforseo() {
    local domain="$1"
    local days="$2"
    local location="${3:-2840}"
    local language="${4:-en}"
    
    # Calculate date range (for filename, DataForSEO uses current data)
    local end_date
    local start_date
    end_date=$(date +%Y-%m-%d)
    if date -v-1d &>/dev/null; then
        start_date=$(date -v-${days}d +%Y-%m-%d)
    else
        start_date=$(date -d "$days days ago" +%Y-%m-%d)
    fi
    
    print_info "Fetching DataForSEO data for $domain..."
    
    # Check credentials first
    local auth
    auth=$(get_auth_header) || return 1
    
    # Make API request
    local response
    response=$(dfs_ranked_keywords "$domain" "$ROW_LIMIT" "$location" "$language")
    
    if [[ -z "$response" ]]; then
        print_error "Failed to fetch DataForSEO data"
        return 1
    fi
    
    # Check for errors
    local status_code
    status_code=$(echo "$response" | jq -r '.tasks[0].status_code // 0' 2>/dev/null)
    
    if [[ "$status_code" != "20000" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.tasks[0].status_message // "Unknown error"' 2>/dev/null)
        print_error "DataForSEO API error: $error_msg"
        return 1
    fi
    
    # Count rows
    local row_count
    row_count=$(echo "$response" | jq '.tasks[0].result[0].items | length' 2>/dev/null || echo "0")
    
    if [[ "$row_count" == "0" ]] || [[ "$row_count" == "null" ]]; then
        print_warning "No data returned from DataForSEO"
        print_warning "Domain may not have organic rankings"
        return 1
    fi
    
    print_info "Retrieved $row_count rows"
    
    # Create output directory
    local domain_dir="$SEO_DATA_DIR/$domain"
    mkdir -p "$domain_dir"
    
    # Generate output filename
    local output_file="$domain_dir/dataforseo-${start_date}-${end_date}.toon"
    
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
SEO Export - DataForSEO

Export DataForSEO ranked keywords data to TOON format.

Usage:
    seo-export-dataforseo.sh <domain> [options]

Options:
    --days N           Number of days for date range label (default: 90)
    --location CODE    Location code (default: 2840 for US)
    --language CODE    Language code (default: en)
    --help, -h         Show this help message

Location Codes:
    2840  United States
    2826  United Kingdom
    2276  Germany
    2250  France
    2724  Spain
    2036  Australia
    2124  Canada

Examples:
    # Export ranked keywords (US)
    seo-export-dataforseo.sh example.com

    # Export for UK market
    seo-export-dataforseo.sh example.com --location 2826

Output:
    ~/.aidevops/.agent-workspace/work/seo-data/{domain}/dataforseo-{start}-{end}.toon

Data Fields:
    - query: Keyword
    - page: Ranking URL
    - clicks: Estimated traffic value (ETV)
    - impressions: Estimated (volume * 10)
    - ctr: Calculated
    - position: Ranking position
    - volume: Monthly search volume
    - difficulty: Competition level

Requirements:
    - DATAFORSEO_USERNAME and DATAFORSEO_PASSWORD in ~/.config/aidevops/mcp-env.sh

Setup:
    1. Sign up at https://app.dataforseo.com/
    2. Get API credentials from dashboard
    3. Add to mcp-env.sh:
       export DATAFORSEO_USERNAME="your_username"
       export DATAFORSEO_PASSWORD="your_password"

EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local domain=""
    local days="$DEFAULT_DAYS"
    local location="2840"
    local language="en"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                days="${2:-$DEFAULT_DAYS}"
                shift 2
                ;;
            --location)
                location="${2:-2840}"
                shift 2
                ;;
            --language)
                language="${2:-en}"
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
        echo "Usage: seo-export-dataforseo.sh <domain> [--days N] [--location CODE]"
        return 1
    fi
    
    # Check dependencies
    if ! command -v jq &>/dev/null; then
        print_error "jq is required but not installed"
        return 1
    fi
    
    export_dataforseo "$domain" "$days" "$location" "$language"
    return $?
}

main "$@"
