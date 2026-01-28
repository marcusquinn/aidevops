#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# SEO Export - Ahrefs
# Exports Ahrefs organic keywords data to TOON format
#
# Usage: seo-export-ahrefs.sh <domain> [options]
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
readonly AHREFS_API_BASE="https://api.ahrefs.com/v3"

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
# Ahrefs API Functions
# =============================================================================

# Get API key from environment
get_api_key() {
    source "$CONFIG_DIR/mcp-env.sh" 2>/dev/null || true
    
    if [[ -z "${AHREFS_API_KEY:-}" ]]; then
        print_error "AHREFS_API_KEY not configured"
        print_error "Set it in ~/.config/aidevops/mcp-env.sh"
        return 1
    fi
    
    echo "$AHREFS_API_KEY"
    return 0
}

# Make Ahrefs API request
ahrefs_request() {
    local endpoint="$1"
    local params="$2"
    local api_key
    
    api_key=$(get_api_key) || return 1
    
    curl -s -X GET \
        "$AHREFS_API_BASE/$endpoint?$params" \
        -H "Authorization: Bearer $api_key" \
        -H "Accept: application/json"
    return 0
}

# Get organic keywords for a domain
ahrefs_organic_keywords() {
    local domain="$1"
    local date="$2"
    local limit="${3:-$ROW_LIMIT}"
    local country="${4:-us}"
    
    local params="target=$domain&mode=domain&country=$country&date=$date&limit=$limit"
    params="$params&select=keyword,position,volume,traffic,url,difficulty,cpc"
    
    ahrefs_request "site-explorer/organic-keywords" "$params"
    return 0
}

# =============================================================================
# TOON Conversion
# =============================================================================

# Convert Ahrefs JSON response to TOON format
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
source	ahrefs
exported	$exported
start_date	$start_date
end_date	$end_date
---
query	page	clicks	impressions	ctr	position	volume	difficulty
EOF
    
    # Data rows - Ahrefs provides: keyword, position, volume, traffic, url, difficulty, cpc
    # Map to common format: query=keyword, page=url, clicks=traffic, impressions=volume*10 (estimate)
    echo "$json" | jq -r '.keywords[]? | [
        .keyword,
        .url,
        .traffic,
        (.volume * 10),
        (if .volume > 0 then (.traffic / (.volume * 10)) else 0 end),
        .position,
        .volume,
        .difficulty
    ] | @tsv' 2>/dev/null || true
    
    return 0
}

# =============================================================================
# Main Export Function
# =============================================================================

export_ahrefs() {
    local domain="$1"
    local days="$2"
    local country="${3:-us}"
    
    # Calculate date range
    # Ahrefs uses a single date for snapshot, not a range
    local end_date
    local start_date
    end_date=$(date +%Y-%m-%d)
    if date -v-1d &>/dev/null; then
        start_date=$(date -v-${days}d +%Y-%m-%d)
    else
        start_date=$(date -d "$days days ago" +%Y-%m-%d)
    fi
    
    print_info "Fetching Ahrefs data for $domain (snapshot: $end_date)..."
    
    # Check credentials first
    local api_key
    api_key=$(get_api_key) || return 1
    
    # Make API request
    local response
    response=$(ahrefs_organic_keywords "$domain" "$end_date" "$ROW_LIMIT" "$country")
    
    if [[ -z "$response" ]]; then
        print_error "Failed to fetch Ahrefs data"
        return 1
    fi
    
    # Check for errors
    if echo "$response" | jq -e '.error' &>/dev/null; then
        local error_msg
        # Handle both string and object error formats
        error_msg=$(echo "$response" | jq -r 'if .error | type == "string" then .error else (.error.message // "Unknown error") end')
        print_error "Ahrefs API error: $error_msg"
        return 1
    fi
    
    # Count rows
    local row_count
    row_count=$(echo "$response" | jq '.keywords | length' 2>/dev/null || echo "0")
    
    if [[ "$row_count" == "0" ]] || [[ "$row_count" == "null" ]]; then
        print_warning "No data returned from Ahrefs"
        print_warning "Domain may not have organic rankings or API access issue"
        return 1
    fi
    
    print_info "Retrieved $row_count rows"
    
    # Create output directory
    local domain_dir="$SEO_DATA_DIR/$domain"
    mkdir -p "$domain_dir"
    
    # Generate output filename
    local output_file="$domain_dir/ahrefs-${start_date}-${end_date}.toon"
    
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
SEO Export - Ahrefs

Export Ahrefs organic keywords data to TOON format.

Usage:
    seo-export-ahrefs.sh <domain> [options]

Options:
    --days N         Number of days for date range label (default: 90)
    --country CODE   Country code for organic data (default: us)
    --help, -h       Show this help message

Examples:
    # Export organic keywords (US)
    seo-export-ahrefs.sh example.com

    # Export for UK market
    seo-export-ahrefs.sh example.com --country gb

Output:
    ~/.aidevops/.agent-workspace/work/seo-data/{domain}/ahrefs-{start}-{end}.toon

Data Fields:
    - query: Keyword
    - page: Ranking URL
    - clicks: Estimated traffic
    - impressions: Estimated (volume * 10)
    - ctr: Calculated from traffic/impressions
    - position: Current ranking position
    - volume: Monthly search volume
    - difficulty: Keyword difficulty (0-100)

Requirements:
    - AHREFS_API_KEY set in ~/.config/aidevops/mcp-env.sh

API Key Setup:
    1. Go to https://app.ahrefs.com/user/api
    2. Generate API key
    3. Add to mcp-env.sh: export AHREFS_API_KEY="your_key"

EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local domain=""
    local days="$DEFAULT_DAYS"
    local country="us"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                if [[ -z "${2:-}" ]] || [[ "$2" == -* ]]; then
                    print_error "--days requires a numeric value"
                    return 1
                fi
                days="$2"
                shift 2
                ;;
            --country)
                if [[ -z "${2:-}" ]] || [[ "$2" == -* ]]; then
                    print_error "--country requires a value"
                    return 1
                fi
                country="$2"
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
        echo "Usage: seo-export-ahrefs.sh <domain> [--days N] [--country CODE]"
        return 1
    fi
    
    # Check dependencies
    if ! command -v jq &>/dev/null; then
        print_error "jq is required but not installed"
        return 1
    fi
    
    export_ahrefs "$domain" "$days" "$country"
    return $?
}

main "$@"
