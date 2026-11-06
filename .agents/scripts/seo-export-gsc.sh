#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2086

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
# shellcheck source=./gsc-auth-lib.sh
source "$SCRIPT_DIR/gsc-auth-lib.sh"

# =============================================================================
# Configuration
# =============================================================================

readonly SEO_DATA_DIR="$HOME/.aidevops/.agent-workspace/work/seo-data"
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly DEFAULT_DAYS=90
readonly ROW_LIMIT=25000

# =============================================================================
# Utility Functions
# =============================================================================

# =============================================================================
# GSC API Functions
# =============================================================================

# Credential resolution and scoped ADC tokens are shared with the
# keyword-research GSC path (gsc-auth-lib.sh, GH#36898).
_gsc_credential_file() {
    gsc_adc_credential_file
    return 0
}

# Get access token from GSC_ACCESS_TOKEN or Application Default Credentials
get_access_token() {
    source "$CONFIG_DIR/credentials.sh" 2>/dev/null || true

    if [[ -n "${GSC_ACCESS_TOKEN:-}" ]]; then
        echo "$GSC_ACCESS_TOKEN"
        return 0
    fi

    local cred_file
    cred_file=$(_gsc_credential_file)
    if [[ -n "$cred_file" && -f "$cred_file" ]]; then
        local token
        if token=$(gsc_adc_access_token "$cred_file"); then
            echo "$token"
            return 0
        fi
        print_error "GSC credentials found at $cred_file, but the access token request failed"
        print_error "Re-authenticate: gcloud auth application-default login (keyless: add --impersonate-service-account=<sa>)"
        return 1
    fi

    print_error "GSC credentials not configured"
    print_error "Use GSC_ACCESS_TOKEN in ~/.config/aidevops/credentials.sh, GOOGLE_APPLICATION_CREDENTIALS, ~/.config/aidevops/gsc-credentials.json, or gcloud auth application-default login"
    return 1
}

# Resolve the quota project required by user Application Default Credentials.
# Static tokens take precedence over ADC unless an explicit override is set.
resolve_quota_project() {
    source "$CONFIG_DIR/credentials.sh" 2>/dev/null || true

    local quota_project="${GSC_QUOTA_PROJECT:-}"
    if [[ -n "$quota_project" ]]; then
        if [[ "$quota_project" == *$'\r'* ]] || [[ "$quota_project" == *$'\n'* ]]; then
            print_error "GSC_QUOTA_PROJECT contains invalid newline characters"
            return 1
        fi
        printf '%s\n' "$quota_project"
        return 0
    fi

    if [[ -n "${GSC_ACCESS_TOKEN:-}" ]]; then
        return 0
    fi

    local cred_file
    cred_file=$(_gsc_credential_file)
    if [[ -z "$cred_file" || ! -f "$cred_file" ]]; then
        return 0
    fi

    local credential_type
    credential_type=$(jq -r '.type // empty' "$cred_file" 2>/dev/null) || {
        print_error "Unable to read GOOGLE_APPLICATION_CREDENTIALS as JSON"
        return 1
    }

    if [[ "$credential_type" != "authorized_user" ]]; then
        return 0
    fi

    quota_project=$(jq -r '.quota_project_id // empty' "$cred_file" 2>/dev/null) || {
        print_error "Unable to read quota_project_id from GOOGLE_APPLICATION_CREDENTIALS"
        return 1
    }

    if [[ -z "$quota_project" ]]; then
        print_error "User ADC is missing a quota project"
        print_error "Run: gcloud auth application-default set-quota-project <project>"
        print_error "Or set GSC_QUOTA_PROJECT in ~/.config/aidevops/credentials.sh"
        return 1
    fi

    if [[ "$quota_project" == *$'\r'* ]] || [[ "$quota_project" == *$'\n'* ]]; then
        print_error "ADC quota_project_id contains invalid newline characters"
        return 1
    fi

    printf '%s\n' "$quota_project"
    return 0
}

# Make GSC API request
gsc_request() {
    local endpoint="$1"
    local data="$2"
    local token
    local quota_project
    local -a curl_args
    
    token=$(get_access_token) || return 1
    quota_project=$(resolve_quota_project) || return 1

    curl_args=(
        -sS
        -X POST
        "https://searchconsole.googleapis.com/webmasters/v3/$endpoint"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -d "$data"
    )
    if [[ -n "$quota_project" ]]; then
        curl_args+=(-H "x-goog-user-project: $quota_project")
    fi

    if ! curl "${curl_args[@]}"; then
        return 1
    fi
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
    
    if ! gsc_request "sites/$encoded_url/searchAnalytics/query" "$data"; then
        return 1
    fi
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
    
    # Check credentials first
    local token
    token=$(get_access_token) || return 1
    
    # Make API request
    local response
    if ! response=$(gsc_search_analytics "$site_url" "$start_date" "$end_date"); then
        return 1
    fi
    
    # If empty or error, try https:// format
    if [[ -z "$response" ]] || echo "$response" | jq -e '.error' &>/dev/null; then
        print_warning "sc-domain format failed, trying https:// format..."
        site_url="https://$domain/"
        if ! response=$(gsc_search_analytics "$site_url" "$start_date" "$end_date"); then
            return 1
        fi
    fi
    
    if [[ -z "$response" ]]; then
        print_error "Failed to fetch GSC data"
        return 1
    fi
    
    # Check for errors in response
    if echo "$response" | jq -e '.error' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$response" | jq -r 'if .error | type == "string" then .error else (.error.message // "Unknown error") end')
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
    - Application Default Credentials, first found of:
        GOOGLE_APPLICATION_CREDENTIALS, ~/.config/aidevops/gsc-credentials.json,
        or gcloud's default ADC (gcloud auth application-default login, including
        keyless --impersonate-service-account=<sa>)
    - User ADC must contain quota_project_id, or set GSC_QUOTA_PROJECT
    - Or GSC_ACCESS_TOKEN set in ~/.config/aidevops/credentials.sh
    - The authenticated account must have access to the GSC property

EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local domain=""
    local days="$DEFAULT_DAYS"
    local next_arg=""
    local arg
    
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --days)
                next_arg="${2:-}"
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
