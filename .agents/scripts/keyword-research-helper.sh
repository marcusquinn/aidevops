#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2162

# Keyword Research Helper Script
# Comprehensive keyword research with SERP weakness detection and opportunity scoring
# Providers: DataForSEO (primary), Serper (alternative), Ahrefs (optional)
# Webmaster Tools: Google Search Console, Bing Webmaster Tools (for owned sites)

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
        *) echo "2840" ;;  # Default to US
    esac
    return 0
}

get_language_code() {
    local locale="$1"
    case "$locale" in
        "us-en"|"uk-en"|"ca-en"|"au-en") echo "en" ;;
        "de-de") echo "de" ;;
        "fr-fr") echo "fr" ;;
        "es-es") echo "es" ;;
        custom-*) echo "en" ;;  # Default to English for custom
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

print_header() { local msg="$1"; echo -e "${PURPLE}═══ $msg ═══${NC}"; return 0; }
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
    
    cat > "$CONFIG_FILE" << EOF
{
  "default_locale": "$locale",
  "default_provider": "$provider",
  "default_limit": $limit,
  "include_ahrefs": false,
  "csv_directory": "$DOWNLOADS_DIR"
}
EOF
    print_success "Configuration saved to $CONFIG_FILE"
    return 0
}

show_config() {
    print_header "Current Configuration"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE" | jq .
    else
        print_info "No configuration file found. Using defaults."
        echo "  Locale: $DEFAULT_LOCALE"
        echo "  Provider: $DEFAULT_PROVIDER"
        echo "  Limit: $DEFAULT_LIMIT"
    fi
    return 0
}

# =============================================================================
# Credential Checking
# =============================================================================

check_credentials() {
    local provider="$1"
    local has_creds=false
    
    # Source credentials
    if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
        source "$HOME/.config/aidevops/credentials.sh"
    fi
    
    case "$provider" in
        "dataforseo")
            if [[ -n "${DATAFORSEO_USERNAME:-}" ]] && [[ -n "${DATAFORSEO_PASSWORD:-}" ]]; then
                has_creds=true
            fi
            ;;
        "serper")
            if [[ -n "${SERPER_API_KEY:-}" ]]; then
                has_creds=true
            fi
            ;;
        "ahrefs")
            if [[ -n "${AHREFS_API_KEY:-}" ]]; then
                has_creds=true
            fi
            ;;
        "both")
            if [[ -n "${DATAFORSEO_USERNAME:-}" ]] && [[ -n "${SERPER_API_KEY:-}" ]]; then
                has_creds=true
            fi
            ;;
        *)
            print_error "Unknown provider: $provider"
            return 1
            ;;
    esac
    
    if [[ "$has_creds" == "false" ]]; then
        print_error "Missing credentials for provider: $provider"
        print_info "Run '/list-keys' to check your API keys"
        print_info "Configure in ~/.config/aidevops/credentials.sh"
        return 1
    fi
    
    return 0
}

# =============================================================================
# Locale Selection
# =============================================================================

prompt_locale() {
    print_header "Select Location/Language"
    echo ""
    echo "  1) US/English (default)"
    echo "  2) UK/English"
    echo "  3) Canada/English"
    echo "  4) Australia/English"
    echo "  5) Germany/German"
    echo "  6) France/French"
    echo "  7) Spain/Spanish"
    echo "  8) Custom (enter location code)"
    echo ""
    read -p "Select option [1]: " choice
    
    case "${choice:-1}" in
        1) echo "us-en" ;;
        2) echo "uk-en" ;;
        3) echo "ca-en" ;;
        4) echo "au-en" ;;
        5) echo "de-de" ;;
        6) echo "fr-fr" ;;
        7) echo "es-es" ;;
        8) 
            read -p "Enter DataForSEO location code: " custom_code
            echo "custom-$custom_code"
            ;;
        *) echo "us-en" ;;
    esac
    return 0
}

# =============================================================================
# DataForSEO API Functions
# =============================================================================

dataforseo_request() {
    local endpoint="$1"
    local data="$2"
    
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    local auth
    auth=$(echo -n "${DATAFORSEO_USERNAME}:${DATAFORSEO_PASSWORD}" | base64)
    
    curl -s -X POST \
        "https://api.dataforseo.com/v3/$endpoint" \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$data"
    return 0
}

# Keyword suggestions (seed keyword expansion)
dataforseo_keyword_suggestions() {
    local keyword="$1"
    local location_code="$2"
    local language_code="$3"
    local limit="$4"
    
    local data
    data=$(cat << EOF
[{
    "keyword": "$keyword",
    "location_code": $location_code,
    "language_code": "$language_code",
    "limit": $limit,
    "include_seed_keyword": true,
    "include_serp_info": true
}]
EOF
)
    
    dataforseo_request "dataforseo_labs/google/keyword_suggestions/live" "$data"
    return 0
}

# Google autocomplete (uses keyword_suggestions for richer data)
dataforseo_autocomplete() {
    local keyword="$1"
    local location_code="$2"
    local language_code="$3"
    
    local data
    data=$(cat << EOF
[{
    "keyword": "$keyword",
    "location_code": $location_code,
    "language_code": "$language_code",
    "limit": 50,
    "include_seed_keyword": true
}]
EOF
)
    
    dataforseo_request "dataforseo_labs/google/keyword_suggestions/live" "$data"
    return 0
}

# Ranked keywords (competitor research)
dataforseo_ranked_keywords() {
    local domain="$1"
    local location_code="$2"
    local language_code="$3"
    local limit="$4"
    
    local data
    data=$(cat << EOF
[{
    "target": "$domain",
    "location_code": $location_code,
    "language_code": "$language_code",
    "limit": $limit,
    "order_by": ["keyword_data.keyword_info.search_volume,desc"]
}]
EOF
)
    
    dataforseo_request "dataforseo_labs/google/ranked_keywords/live" "$data"
    return 0
}

# Domain intersection (keyword gap)
dataforseo_keyword_gap() {
    local your_domain="$1"
    local competitor_domain="$2"
    local location_code="$3"
    local language_code="$4"
    local limit="$5"
    
    local data
    data=$(cat << EOF
[{
    "target1": "$competitor_domain",
    "target2": "$your_domain",
    "location_code": $location_code,
    "language_code": "$language_code",
    "limit": $limit,
    "intersections": false,
    "order_by": ["first_domain_serp_element.etv,desc"]
}]
EOF
)
    
    dataforseo_request "dataforseo_labs/google/domain_intersection/live" "$data"
    return 0
}

# Backlinks summary (domain/page scores)
dataforseo_backlinks_summary() {
    local target="$1"
    
    local data
    data=$(cat << EOF
[{
    "target": "$target",
    "include_subdomains": true
}]
EOF
)
    
    dataforseo_request "backlinks/summary/live" "$data"
    return 0
}

# SERP organic results
dataforseo_serp_organic() {
    local keyword="$1"
    local location_code="$2"
    local language_code="$3"
    
    local data
    data=$(cat << EOF
[{
    "keyword": "$keyword",
    "location_code": $location_code,
    "language_code": "$language_code",
    "device": "desktop",
    "os": "windows",
    "depth": 10
}]
EOF
)
    
    dataforseo_request "serp/google/organic/live/regular" "$data"
    return 0
}

# On-page instant (page speed, technical analysis)
dataforseo_onpage_instant() {
    local url="$1"
    
    local data
    data=$(cat << EOF
[{
    "url": "$url",
    "enable_javascript": true,
    "load_resources": true
}]
EOF
)
    
    dataforseo_request "on_page/instant_pages" "$data"
    return 0
}

# =============================================================================
# Serper API Functions
# =============================================================================

serper_request() {
    local endpoint="$1"
    local data="$2"
    
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    curl -s -X POST \
        "https://google.serper.dev/$endpoint" \
        -H "X-API-KEY: ${SERPER_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$data"
    return 0
}

serper_search() {
    local query="$1"
    local location="$2"
    local num="$3"
    
    local data
    data=$(cat << EOF
{
    "q": "$query",
    "gl": "$location",
    "num": $num
}
EOF
)
    
    serper_request "search" "$data"
    return 0
}

serper_autocomplete() {
    local query="$1"
    local location="$2"
    
    local data
    data=$(cat << EOF
{
    "q": "$query",
    "gl": "$location"
}
EOF
)
    
    serper_request "autocomplete" "$data"
    return 0
}

# =============================================================================
# Ahrefs API Functions
# =============================================================================

ahrefs_request() {
    local endpoint="$1"
    local params="$2"
    
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    curl -s -X GET \
        "https://api.ahrefs.com/v3/$endpoint?$params" \
        -H "Authorization: Bearer ${AHREFS_API_KEY}"
    return 0
}

ahrefs_domain_rating() {
    local domain="$1"
    local today
    today=$(date +%Y-%m-%d)
    
    ahrefs_request "site-explorer/domain-rating" "target=$domain&date=$today"
    return 0
}

ahrefs_url_rating() {
    local url="$1"
    local today
    today=$(date +%Y-%m-%d)
    
    ahrefs_request "site-explorer/url-rating" "target=$url&date=$today"
    return 0
}

# =============================================================================
# Google Search Console API Functions
# =============================================================================

gsc_request() {
    local endpoint="$1"
    local data="$2"
    
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    # Check for service account credentials
    if [[ -z "${GSC_ACCESS_TOKEN:-}" ]]; then
        # Try to get access token from service account
        if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && [[ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
            # Use gcloud or manual JWT flow
            local token
            token=$(gcloud auth application-default print-access-token 2>/dev/null || echo "")
            if [[ -z "$token" ]]; then
                print_error "Failed to get GSC access token. Run: gcloud auth application-default login"
                return 1
            fi
            GSC_ACCESS_TOKEN="$token"
        else
            print_error "GSC credentials not configured. Set GOOGLE_APPLICATION_CREDENTIALS or GSC_ACCESS_TOKEN"
            return 1
        fi
    fi
    
    curl -s -X POST \
        "https://searchconsole.googleapis.com/webmasters/v3/$endpoint" \
        -H "Authorization: Bearer $GSC_ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$data"
    return 0
}

# Get search analytics (queries, pages, clicks, impressions, CTR, position)
gsc_search_analytics() {
    local site_url="$1"
    local start_date="$2"
    local end_date="$3"
    local limit="${4:-1000}"
    local dimensions="${5:-query}"  # query, page, country, device, searchAppearance
    
    # URL encode the site URL
    local encoded_url
    encoded_url=$(echo -n "$site_url" | jq -sRr @uri)
    
    local data
    data=$(cat << EOF
{
    "startDate": "$start_date",
    "endDate": "$end_date",
    "dimensions": ["$dimensions"],
    "rowLimit": $limit,
    "startRow": 0
}
EOF
)
    
    gsc_request "sites/$encoded_url/searchAnalytics/query" "$data"
    return 0
}

# Get top queries for a site
gsc_top_queries() {
    local site_url="$1"
    local days="${2:-30}"
    local limit="${3:-100}"
    
    local end_date
    local start_date
    end_date=$(date +%Y-%m-%d)
    start_date=$(date -v-${days}d +%Y-%m-%d 2>/dev/null || date -d "$days days ago" +%Y-%m-%d)
    
    gsc_search_analytics "$site_url" "$start_date" "$end_date" "$limit" "query"
    return 0
}

# Get queries for a specific page
gsc_page_queries() {
    local site_url="$1"
    local page_url="$2"
    local days="${3:-30}"
    local limit="${4:-100}"
    
    local end_date
    local start_date
    end_date=$(date +%Y-%m-%d)
    start_date=$(date -v-${days}d +%Y-%m-%d 2>/dev/null || date -d "$days days ago" +%Y-%m-%d)
    
    local encoded_site
    encoded_site=$(echo -n "$site_url" | jq -sRr @uri)
    
    local data
    data=$(cat << EOF
{
    "startDate": "$start_date",
    "endDate": "$end_date",
    "dimensions": ["query"],
    "dimensionFilterGroups": [{
        "filters": [{
            "dimension": "page",
            "operator": "equals",
            "expression": "$page_url"
        }]
    }],
    "rowLimit": $limit
}
EOF
)
    
    gsc_request "sites/$encoded_site/searchAnalytics/query" "$data"
    return 0
}

# List verified sites
gsc_list_sites() {
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    if [[ -z "${GSC_ACCESS_TOKEN:-}" ]]; then
        if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && [[ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
            local token
            token=$(gcloud auth application-default print-access-token 2>/dev/null || echo "")
            if [[ -z "$token" ]]; then
                print_error "Failed to get GSC access token"
                return 1
            fi
            GSC_ACCESS_TOKEN="$token"
        else
            print_error "GSC credentials not configured"
            return 1
        fi
    fi
    
    curl -s -X GET \
        "https://searchconsole.googleapis.com/webmasters/v3/sites" \
        -H "Authorization: Bearer $GSC_ACCESS_TOKEN"
    return 0
}

# =============================================================================
# Bing Webmaster Tools API Functions
# =============================================================================

bing_request() {
    local endpoint="$1"
    local site_url="$2"
    
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
        print_error "BING_WEBMASTER_API_KEY not configured in ~/.config/aidevops/credentials.sh"
        return 1
    fi
    
    # URL encode the site URL
    local encoded_url
    encoded_url=$(echo -n "$site_url" | jq -sRr @uri)
    
    curl -s -X GET \
        "https://ssl.bing.com/webmaster/api.svc/json/$endpoint?siteUrl=$encoded_url&apikey=$BING_WEBMASTER_API_KEY"
    return 0
}

# Get query statistics (top queries with impressions/clicks)
bing_query_stats() {
    local site_url="$1"
    
    bing_request "GetQueryStats" "$site_url"
    return 0
}

# Get keyword details for a specific query
bing_keyword() {
    local site_url="$1"
    local query="$2"
    local start_date="$3"
    local end_date="$4"
    
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
        print_error "BING_WEBMASTER_API_KEY not configured"
        return 1
    fi
    
    local encoded_url
    encoded_url=$(echo -n "$site_url" | jq -sRr @uri)
    local encoded_query
    encoded_query=$(echo -n "$query" | jq -sRr @uri)
    
    curl -s -X GET \
        "https://ssl.bing.com/webmaster/api.svc/json/GetKeyword?siteUrl=$encoded_url&query=$encoded_query&startDate=$start_date&endDate=$end_date&apikey=$BING_WEBMASTER_API_KEY"
    return 0
}

# Get related keywords
bing_related_keywords() {
    local site_url="$1"
    local query="$2"
    local start_date="$3"
    local end_date="$4"
    
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
        print_error "BING_WEBMASTER_API_KEY not configured"
        return 1
    fi
    
    local encoded_url
    encoded_url=$(echo -n "$site_url" | jq -sRr @uri)
    local encoded_query
    encoded_query=$(echo -n "$query" | jq -sRr @uri)
    
    curl -s -X GET \
        "https://ssl.bing.com/webmaster/api.svc/json/GetRelatedKeywords?siteUrl=$encoded_url&query=$encoded_query&startDate=$start_date&endDate=$end_date&apikey=$BING_WEBMASTER_API_KEY"
    return 0
}

# Get page query stats (queries for a specific page)
bing_page_query_stats() {
    local site_url="$1"
    local page_url="$2"
    
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
        print_error "BING_WEBMASTER_API_KEY not configured"
        return 1
    fi
    
    local encoded_site
    encoded_site=$(echo -n "$site_url" | jq -sRr @uri)
    local encoded_page
    encoded_page=$(echo -n "$page_url" | jq -sRr @uri)
    
    curl -s -X GET \
        "https://ssl.bing.com/webmaster/api.svc/json/GetPageQueryStats?siteUrl=$encoded_site&page=$encoded_page&apikey=$BING_WEBMASTER_API_KEY"
    return 0
}

# Get rank and traffic stats
bing_rank_traffic() {
    local site_url="$1"
    
    bing_request "GetRankAndTrafficStats" "$site_url"
    return 0
}

# List user sites
bing_list_sites() {
    source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
    
    if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
        print_error "BING_WEBMASTER_API_KEY not configured"
        return 1
    fi
    
    curl -s -X GET \
        "https://ssl.bing.com/webmaster/api.svc/json/GetUserSites?apikey=$BING_WEBMASTER_API_KEY"
    return 0
}

# =============================================================================
# Webmaster Tools Research (GSC + Bing combined)
# =============================================================================

do_webmaster_research() {
    local site_url="$1"
    local days="${2:-30}"
    local limit="${3:-100}"
    local csv_export="${4:-false}"
    local enrich="${5:-true}"
    
    print_header "Webmaster Tools Keyword Research"
    print_info "Site: $site_url"
    print_info "Period: Last $days days"
    print_info "Enrichment: $enrich"
    
    local gsc_data=""
    local bing_data=""
    
    # Fetch from Google Search Console
    print_info "Fetching from Google Search Console..."
    gsc_data=$(gsc_top_queries "$site_url" "$days" "$limit" 2>/dev/null || echo "")
    
    if [[ -n "$gsc_data" ]] && echo "$gsc_data" | jq -e '.rows' >/dev/null 2>&1; then
        local gsc_count
        gsc_count=$(echo "$gsc_data" | jq '.rows | length')
        print_success "GSC: Found $gsc_count queries"
    else
        print_warning "GSC: No data or not configured"
        gsc_data=""
    fi
    
    # Fetch from Bing Webmaster Tools
    print_info "Fetching from Bing Webmaster Tools..."
    bing_data=$(bing_query_stats "$site_url" 2>/dev/null || echo "")
    
    if [[ -n "$bing_data" ]] && echo "$bing_data" | jq -e '.d' >/dev/null 2>&1; then
        local bing_count
        bing_count=$(echo "$bing_data" | jq '.d | length')
        print_success "Bing: Found $bing_count queries"
    else
        print_warning "Bing: No data or not configured"
        bing_data=""
    fi
    
    # Combine and deduplicate keywords
    local combined_keywords
    combined_keywords=$(mktemp)
    trap 'rm -f "${combined_keywords:-}"' RETURN
    
    # Process GSC data
    if [[ -n "$gsc_data" ]]; then
        echo "$gsc_data" | jq -r '.rows[]? | [.keys[0], .clicks, .impressions, .ctr, .position, "gsc"] | @tsv' >> "$combined_keywords"
    fi
    
    # Process Bing data
    if [[ -n "$bing_data" ]]; then
        echo "$bing_data" | jq -r '.d[]? | [.Query, .Clicks, .Impressions, (.Clicks / (.Impressions + 0.001)), .AvgPosition, "bing"] | @tsv' >> "$combined_keywords"
    fi
    
    # Aggregate by keyword (combine GSC + Bing data)
    local aggregated
    aggregated=$(sort -t$'\t' -k1,1 "$combined_keywords" | awk -F'\t' '
    {
        kw = $1
        clicks[kw] += $2
        impressions[kw] += $3
        ctr_sum[kw] += $4
        pos_sum[kw] += $5
        count[kw]++
        if ($6 == "gsc") gsc[kw] = 1
        if ($6 == "bing") bing[kw] = 1
    }
    END {
        for (kw in clicks) {
            sources = ""
            if (gsc[kw]) sources = "GSC"
            if (bing[kw]) sources = sources (sources ? "+" : "") "Bing"
            printf "%s\t%d\t%d\t%.4f\t%.1f\t%s\n", kw, clicks[kw], impressions[kw], ctr_sum[kw]/count[kw], pos_sum[kw]/count[kw], sources
        }
    }' | sort -t$'\t' -k3 -rn | head -n "$limit")
    
    rm -f "$combined_keywords"
    
    if [[ -z "$aggregated" ]]; then
        print_warning "No keyword data found from webmaster tools"
        return 0
    fi
    
    # Enrich with DataForSEO volume/difficulty data if requested
    if [[ "$enrich" == "true" ]]; then
        print_info "Enriching with search volume and difficulty data..."
        
        # Get unique keywords for enrichment (top 50 to avoid API limits)
        local keywords_to_enrich
        keywords_to_enrich=$(echo "$aggregated" | head -50 | cut -f1 | tr '\n' ',' | sed 's/,$//')
        
        if [[ -n "$keywords_to_enrich" ]]; then
            local location_code
            local language_code
            location_code=$(get_location_code "$DEFAULT_LOCALE")
            language_code=$(get_language_code "$DEFAULT_LOCALE")
            
            # Fetch volume data from DataForSEO
            local volume_data
            volume_data=$(dataforseo_keyword_suggestions "${keywords_to_enrich%%,*}" "$location_code" "$language_code" 50 2>/dev/null || echo "")
            
            # Build lookup table for volume/difficulty
            local volume_lookup
            volume_lookup=$(echo "$volume_data" | jq -r '
                [.tasks[]?.result[]?.items[]? | {
                    keyword: .keyword,
                    volume: (.keyword_info.search_volume // 0),
                    difficulty: (.keyword_properties.keyword_difficulty // 0),
                    cpc: (.keyword_info.cpc // 0),
                    intent: (.search_intent_info.main_intent // "unknown")
                }] | INDEX(.keyword)
            ' 2>/dev/null || echo "{}")
        fi
    fi
    
    # Format output
    echo ""
    printf "| %-40s | %10s | %12s | %6s | %8s | %8s | %6s | %8s | %-10s |\n" \
        "Keyword" "Clicks" "Impressions" "CTR" "Position" "Volume" "KD" "CPC" "Sources"
    printf "|%-42s|%12s|%14s|%8s|%10s|%10s|%8s|%10s|%-12s|\n" \
        "$(printf '%0.s-' {1..42})" "$(printf '%0.s-' {1..12})" "$(printf '%0.s-' {1..14})" \
        "$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..10})" \
        "$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..12})"
    
    local count=0
    while IFS=$'\t' read -r keyword clicks impressions ctr position sources; do
        # Get enrichment data if available
        local volume="-"
        local kd="-"
        local cpc="-"
        
        if [[ -n "${volume_lookup:-}" ]]; then
            local enriched
            enriched=$(echo "$volume_lookup" | jq -r --arg kw "$keyword" '.[$kw] // empty')
            if [[ -n "$enriched" ]]; then
                volume=$(echo "$enriched" | jq -r '.volume // "-"')
                kd=$(echo "$enriched" | jq -r '.difficulty // "-"')
                cpc=$(echo "$enriched" | jq -r '.cpc // "-"')
            fi
        fi
        
        # Format CTR as percentage
        local ctr_pct
        ctr_pct=$(echo "scale=2; $ctr * 100" | bc 2>/dev/null || echo "$ctr")
        
        printf "| %-40s | %10s | %12s | %5s%% | %8.1f | %8s | %6s | %8s | %-10s |\n" \
            "${keyword:0:40}" "$clicks" "$impressions" "$ctr_pct" "$position" "$volume" "$kd" "$cpc" "$sources"
        
        count=$((count + 1))
    done <<< "$aggregated"
    
    echo ""
    print_success "Found $count keywords from webmaster tools"
    
    # CSV export
    if [[ "$csv_export" == "true" ]]; then
        local csv_file="$DOWNLOADS_DIR/webmaster-keywords-$(date +%Y%m%d-%H%M%S).csv"
        echo "Keyword,Clicks,Impressions,CTR,Position,Volume,KD,CPC,Sources" > "$csv_file"
        echo "$aggregated" | while IFS=$'\t' read -r keyword clicks impressions ctr position sources; do
            echo "\"$keyword\",$clicks,$impressions,$ctr,$position,,,\"$sources\"" >> "$csv_file"
        done
        print_success "Exported to: $csv_file"
    fi
    
    return 0
}

# List all verified sites from both GSC and Bing
do_list_sites() {
    print_header "Verified Webmaster Sites"
    
    echo ""
    echo "Google Search Console:"
    echo "----------------------"
    local gsc_sites
    gsc_sites=$(gsc_list_sites 2>/dev/null || echo "")
    if [[ -n "$gsc_sites" ]] && echo "$gsc_sites" | jq -e '.siteEntry' >/dev/null 2>&1; then
        echo "$gsc_sites" | jq -r '.siteEntry[]? | "  \(.siteUrl) [\(.permissionLevel)]"'
    else
        echo "  (Not configured or no sites)"
    fi
    
    echo ""
    echo "Bing Webmaster Tools:"
    echo "---------------------"
    local bing_sites
    bing_sites=$(bing_list_sites 2>/dev/null || echo "")
    if [[ -n "$bing_sites" ]] && echo "$bing_sites" | jq -e '.d' >/dev/null 2>&1; then
        echo "$bing_sites" | jq -r '.d[]? | "  \(.Url)"'
    else
        echo "  (Not configured or no sites)"
    fi
    
    echo ""
    return 0
}

# =============================================================================
# SERP Weakness Detection
# =============================================================================

detect_weaknesses() {
    local serp_data="$1"
    local weaknesses=()
    local weakness_count=0
    
    # Parse SERP results and detect weaknesses
    # This is a simplified version - full implementation would analyze each result
    
    # Check for low domain scores
    local low_ds_count
    low_ds_count=$(echo "$serp_data" | jq "[.items[]? | select(.main_domain_rank <= $THRESHOLD_LOW_DS)] | length" 2>/dev/null || echo "0")
    if [[ "$low_ds_count" -gt 0 ]]; then
        weaknesses+=("Low DS ($low_ds_count)")
        weakness_count=$((weakness_count + low_ds_count))
    fi
    
    # Check for no backlinks
    local no_backlinks_count
    no_backlinks_count=$(echo "$serp_data" | jq '[.items[]? | select(.backlinks_count == 0)] | length' 2>/dev/null || echo "0")
    if [[ "$no_backlinks_count" -gt 0 ]]; then
        weaknesses+=("No Backlinks ($no_backlinks_count)")
        weakness_count=$((weakness_count + no_backlinks_count))
    fi
    
    # Check for non-HTTPS
    # SONAR: Detecting insecure URLs for security audit, not using them
    local non_https_count
    non_https_count=$(echo "$serp_data" | jq '[.items[]? | select(.url | startswith("http://"))] | length' 2>/dev/null || echo "0")
    if [[ "$non_https_count" -gt 0 ]]; then
        weaknesses+=("Non-HTTPS ($non_https_count)")
        weakness_count=$((weakness_count + non_https_count))
    fi
    
    # Check for UGC-heavy results
    local ugc_count
    ugc_count=$(echo "$serp_data" | jq '[.items[]? | select(.domain | test("reddit|quora|stackoverflow|forum"; "i"))] | length' 2>/dev/null || echo "0")
    if [[ "$ugc_count" -ge "$THRESHOLD_UGC_HEAVY" ]]; then
        weaknesses+=("UGC-Heavy ($ugc_count)")
        weakness_count=$((weakness_count + 1))
    fi
    
    # Output results
    echo "$weakness_count|${weaknesses[*]:-None}"
    return 0
}

calculate_keyword_score() {
    local weakness_count="$1"
    local volume="$2"
    local difficulty="$3"
    local serp_features="$4"
    
    local score=0
    
    # Base score from weaknesses (1 point each, max 13)
    score=$((score + weakness_count))
    
    # Volume bonus
    if [[ "$volume" -gt 5000 ]]; then
        score=$((score + 3))
    elif [[ "$volume" -gt 1000 ]]; then
        score=$((score + 2))
    elif [[ "$volume" -gt 100 ]]; then
        score=$((score + 1))
    fi
    
    # Difficulty bonus
    if [[ "$difficulty" -eq 0 ]]; then
        score=$((score + 3))
    elif [[ "$difficulty" -le 15 ]]; then
        score=$((score + 2))
    elif [[ "$difficulty" -le 30 ]]; then
        score=$((score + 1))
    fi
    
    # SERP features penalty (max -3)
    local feature_penalty
    feature_penalty=$(echo "$serp_features" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$feature_penalty" -gt 3 ]]; then
        feature_penalty=3
    fi
    score=$((score - feature_penalty))
    
    # Normalize to 0-100 scale (exponential scaling)
    # Max raw score ~20, scale to 100
    local normalized
    normalized=$(echo "scale=0; ($score * 5)" | bc)
    if [[ "$normalized" -gt 100 ]]; then
        normalized=100
    fi
    if [[ "$normalized" -lt 0 ]]; then
        normalized=0
    fi
    
    echo "$normalized"
    return 0
}

# =============================================================================
# Output Formatting
# =============================================================================

format_volume() {
    local volume="$1"
    
    if [[ "$volume" -ge 1000000 ]]; then
        echo "$(echo "scale=1; $volume / 1000000" | bc)M"
    elif [[ "$volume" -ge 1000 ]]; then
        echo "$(echo "scale=1; $volume / 1000" | bc)K"
    else
        echo "$volume"
    fi
    return 0
}

format_cpc() {
    local cpc="$1"
    printf "\$%.2f" "$cpc"
    return 0
}

# Print markdown table with space-padded columns
print_research_table() {
    local json_data="$1"
    local mode="$2"
    
    case "$mode" in
        "basic")
            echo ""
            printf "| %-40s | %8s | %7s | %4s | %-14s |\n" "Keyword" "Volume" "CPC" "KD" "Intent"
            printf "|%-42s|%10s|%9s|%6s|%16s|\n" "$(printf '%0.s-' {1..42})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..9})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..16})"
            
            echo "$json_data" | jq -r '.[] | "\(.keyword)|\(.volume)|\(.cpc)|\(.difficulty)|\(.intent)"' 2>/dev/null | while IFS='|' read -r kw vol cpc kd intent; do
                local vol_fmt
                vol_fmt=$(format_volume "$vol")
                local cpc_fmt
                cpc_fmt=$(format_cpc "$cpc")
                printf "| %-40s | %8s | %7s | %4s | %-14s |\n" "${kw:0:40}" "$vol_fmt" "$cpc_fmt" "$kd" "${intent:0:14}"
            done
            ;;
        "extended")
            echo ""
            printf "| %-30s | %7s | %4s | %4s | %10s | %-30s | %4s | %4s |\n" "Keyword" "Vol" "KD" "KS" "Weaknesses" "Weakness Types" "DS" "PS"
            printf "|%-32s|%9s|%6s|%6s|%12s|%32s|%6s|%6s|\n" "$(printf '%0.s-' {1..32})" "$(printf '%0.s-' {1..9})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..12})" "$(printf '%0.s-' {1..32})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})"
            
            echo "$json_data" | jq -r '.[] | "\(.keyword)|\(.volume)|\(.difficulty)|\(.keyword_score)|\(.weakness_count)|\(.weaknesses)|\(.domain_score)|\(.page_score)"' 2>/dev/null | while IFS='|' read -r kw vol kd ks wc wt ds ps; do
                local vol_fmt
                vol_fmt=$(format_volume "$vol")
                printf "| %-30s | %7s | %4s | %4s | %10s | %-30s | %4s | %4s |\n" "${kw:0:30}" "$vol_fmt" "$kd" "$ks" "$wc" "${wt:0:30}" "$ds" "$ps"
            done
            ;;
        "competitor")
            echo ""
            printf "| %-30s | %7s | %4s | %8s | %11s | %-35s |\n" "Keyword" "Vol" "KD" "Position" "Est Traffic" "Ranking URL"
            printf "|%-32s|%9s|%6s|%10s|%13s|%37s|\n" "$(printf '%0.s-' {1..32})" "$(printf '%0.s-' {1..9})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..13})" "$(printf '%0.s-' {1..37})"
            
            echo "$json_data" | jq -r '.[] | "\(.keyword)|\(.volume)|\(.difficulty)|\(.position)|\(.est_traffic)|\(.ranking_url)"' 2>/dev/null | while IFS='|' read -r kw vol kd pos traffic url; do
                local vol_fmt
                vol_fmt=$(format_volume "$vol")
                printf "| %-30s | %7s | %4s | %8s | %11s | %-35s |\n" "${kw:0:30}" "$vol_fmt" "$kd" "$pos" "$traffic" "${url:0:35}"
            done
            ;;
        *)
            print_error "Unknown mode: $mode"
            ;;
    esac
    echo ""
    return 0
}

# =============================================================================
# CSV Export
# =============================================================================

export_csv() {
    local json_data="$1"
    local mode="$2"
    local filename="$3"
    
    local filepath="$DOWNLOADS_DIR/$filename"
    
    case "$mode" in
        "basic")
            echo "Keyword,Volume,CPC,Difficulty,Intent" > "$filepath"
            echo "$json_data" | jq -r '.[] | "\"\(.keyword)\",\(.volume),\(.cpc),\(.difficulty),\"\(.intent)\""' >> "$filepath"
            ;;
        "extended")
            echo "Keyword,Volume,CPC,Difficulty,Intent,KeywordScore,DomainScore,PageScore,WeaknessCount,Weaknesses" > "$filepath"
            echo "$json_data" | jq -r '.[] | "\"\(.keyword)\",\(.volume),\(.cpc),\(.difficulty),\"\(.intent)\",\(.keyword_score),\(.domain_score),\(.page_score),\(.weakness_count),\"\(.weaknesses)\""' >> "$filepath"
            ;;
        "competitor")
            echo "Keyword,Volume,CPC,Difficulty,Intent,Position,EstTraffic,RankingURL" > "$filepath"
            echo "$json_data" | jq -r '.[] | "\"\(.keyword)\",\(.volume),\(.cpc),\(.difficulty),\"\(.intent)\",\(.position),\(.est_traffic),\"\(.ranking_url)\""' >> "$filepath"
            ;;
        *)
            print_error "Unknown export mode: $mode"
            return 1
            ;;
    esac
    
    print_success "Exported to: $filepath"
    return 0
}

# =============================================================================
# Main Research Functions
# =============================================================================

do_keyword_research() {
    local keywords="$1"
    local provider="$2"
    local locale="$3"
    local limit="$4"
    local csv_export="$5"
    local filters="$6"
    
    print_header "Keyword Research"
    print_info "Keywords: $keywords"
    print_info "Provider: $provider"
    print_info "Locale: $locale"
    print_info "Limit: $limit"
    
    check_credentials "$provider" || return 1
    
    local location_code
    location_code=$(get_location_code "$locale")
    local language_code
    language_code=$(get_language_code "$locale")
    
    local results="[]"
    
    # Split keywords by comma and process each
    IFS=',' read -ra keyword_array <<< "$keywords"
    
    for keyword in "${keyword_array[@]}"; do
        keyword=$(echo "$keyword" | xargs)  # Trim whitespace
        print_info "Researching: $keyword"
        
        if [[ "$provider" == "dataforseo" ]] || [[ "$provider" == "both" ]]; then
            local response
            response=$(dataforseo_keyword_suggestions "$keyword" "$location_code" "$language_code" "$limit")
            
            # Parse and add to results
            local parsed
            parsed=$(echo "$response" | jq '[.tasks[0].result[0].items[]? | {
                keyword: .keyword,
                volume: (.keyword_info.search_volume // 0),
                cpc: (.keyword_info.cpc // 0),
                difficulty: (.keyword_info.keyword_difficulty // 0),
                intent: (.search_intent_info.main_intent // "unknown")
            }]' 2>/dev/null || echo "[]")
            
            results=$(echo "$results $parsed" | jq -s 'add')
        fi
        
        if [[ "$provider" == "serper" ]] || [[ "$provider" == "both" ]]; then
            # Serper doesn't have keyword suggestions, use search instead
            print_warning "Serper doesn't support keyword suggestions. Use DataForSEO for this feature."
        fi
    done
    
    # Apply filters if provided
    if [[ -n "$filters" ]]; then
        results=$(apply_filters "$results" "$filters")
    fi
    
    # Count results
    local count
    count=$(echo "$results" | jq 'length')
    print_success "Found $count keywords"
    
    # Print table
    print_research_table "$results" "basic"
    
    # Export CSV if requested
    if [[ "$csv_export" == "true" ]]; then
        local timestamp
        timestamp=$(date +"%Y%m%d-%H%M%S")
        export_csv "$results" "basic" "keyword-research-$timestamp.csv"
    fi
    
    # Prompt for more results
    if [[ "$count" -ge "$limit" ]]; then
        echo ""
        read -p "Retrieved $count keywords. Need more? Enter number (max $MAX_LIMIT) or press Enter to continue: " more_count
        if [[ -n "$more_count" ]] && [[ "$more_count" =~ ^[0-9]+$ ]]; then
            if [[ "$more_count" -le "$MAX_LIMIT" ]]; then
                do_keyword_research "$keywords" "$provider" "$locale" "$more_count" "$csv_export" "$filters"
            else
                print_warning "Maximum limit is $MAX_LIMIT"
            fi
        fi
    fi
    
    return 0
}

do_autocomplete_research() {
    local keyword="$1"
    local provider="$2"
    local locale="$3"
    local csv_export="$4"
    
    print_header "Autocomplete Research"
    print_info "Keyword: $keyword"
    print_info "Provider: $provider"
    print_info "Locale: $locale"
    
    check_credentials "$provider" || return 1
    
    local location_code
    location_code=$(get_location_code "$locale")
    local language_code
    language_code=$(get_language_code "$locale")
    
    local results="[]"
    
    if [[ "$provider" == "dataforseo" ]] || [[ "$provider" == "both" ]]; then
        local response
        response=$(dataforseo_autocomplete "$keyword" "$location_code" "$language_code")
        
        local parsed
        # Parse keyword_suggestions response format (same as keyword research)
        parsed=$(echo "$response" | jq '[.tasks[0].result[0].items[]? | {
            keyword: .keyword,
            volume: (.keyword_info.search_volume // 0),
            cpc: (.keyword_info.cpc // 0),
            difficulty: (.keyword_properties.keyword_difficulty // 0),
            intent: (.search_intent_info.main_intent // "unknown")
        }]' 2>/dev/null || echo "[]")
        
        results=$(echo "$results $parsed" | jq -s 'add')
    fi
    
    if [[ "$provider" == "serper" ]] || [[ "$provider" == "both" ]]; then
        local gl_code="${locale%-*}"
        local response
        response=$(serper_autocomplete "$keyword" "$gl_code")
        
        local parsed
        # Serper returns suggestions[].value
        parsed=$(echo "$response" | jq '[.suggestions[]? | {
            keyword: .value,
            volume: 0,
            cpc: 0,
            difficulty: 0,
            intent: "unknown"
        }]' 2>/dev/null || echo "[]")
        
        results=$(echo "$results $parsed" | jq -s 'add | unique_by(.keyword)')
    fi
    
    local count
    count=$(echo "$results" | jq 'length')
    print_success "Found $count autocomplete suggestions"
    
    print_research_table "$results" "basic"
    
    if [[ "$csv_export" == "true" ]]; then
        local timestamp
        timestamp=$(date +"%Y%m%d-%H%M%S")
        export_csv "$results" "basic" "autocomplete-research-$timestamp.csv"
    fi
    
    return 0
}

do_extended_research() {
    local keywords="$1"
    local provider="$2"
    local locale="$3"
    local limit="$4"
    local csv_export="$5"
    local quick_mode="$6"
    local include_ahrefs="$7"
    local mode="$8"  # domain, competitor, gap, or empty for keyword
    local target="$9"
    
    print_header "Extended Keyword Research"
    print_info "Mode: ${mode:-keyword}"
    print_info "Provider: $provider"
    print_info "Locale: $locale"
    print_info "Quick mode: $quick_mode"
    print_info "Include Ahrefs: $include_ahrefs"
    
    check_credentials "$provider" || return 1
    
    if [[ "$include_ahrefs" == "true" ]]; then
        check_credentials "ahrefs" || print_warning "Ahrefs credentials not found. Skipping DR/UR metrics."
    fi
    
    local location_code
    location_code=$(get_location_code "$locale")
    local language_code
    language_code=$(get_language_code "$locale")
    
    local results="[]"
    
    case "$mode" in
        "domain")
            print_info "Domain research for: $target"
            # Use ranked keywords for domain research
            local response
            response=$(dataforseo_ranked_keywords "$target" "$location_code" "$language_code" "$limit")
            
            results=$(echo "$response" | jq '[.tasks[0].result[0].items[]? | {
                keyword: .keyword_data.keyword,
                volume: (.keyword_data.keyword_info.search_volume // 0),
                cpc: (.keyword_data.keyword_info.cpc // 0),
                difficulty: (.keyword_data.keyword_info.keyword_difficulty // 0),
                intent: (.keyword_data.search_intent_info.main_intent // "unknown"),
                position: .ranked_serp_element.serp_item.rank_absolute,
                est_traffic: (.ranked_serp_element.serp_item.etv // 0),
                ranking_url: .ranked_serp_element.serp_item.url
            }]' 2>/dev/null || echo "[]")
            ;;
        "competitor")
            print_info "Competitor research for: $target"
            local response
            response=$(dataforseo_ranked_keywords "$target" "$location_code" "$language_code" "$limit")
            
            results=$(echo "$response" | jq '[.tasks[0].result[0].items[]? | {
                keyword: .keyword_data.keyword,
                volume: (.keyword_data.keyword_info.search_volume // 0),
                cpc: (.keyword_data.keyword_info.cpc // 0),
                difficulty: (.keyword_data.keyword_info.keyword_difficulty // 0),
                intent: (.keyword_data.search_intent_info.main_intent // "unknown"),
                position: .ranked_serp_element.serp_item.rank_absolute,
                est_traffic: (.ranked_serp_element.serp_item.etv // 0),
                ranking_url: .ranked_serp_element.serp_item.url
            }]' 2>/dev/null || echo "[]")
            ;;
        "gap")
            IFS=',' read -ra domains <<< "$target"
            local your_domain="${domains[0]}"
            local competitor_domain="${domains[1]}"
            print_info "Keyword gap: $your_domain vs $competitor_domain"
            
            local response
            response=$(dataforseo_keyword_gap "$your_domain" "$competitor_domain" "$location_code" "$language_code" "$limit")
            
            results=$(echo "$response" | jq '[.tasks[0].result[0].items[]? | {
                keyword: .keyword_data.keyword,
                volume: (.keyword_data.keyword_info.search_volume // 0),
                cpc: (.keyword_data.keyword_info.cpc // 0),
                difficulty: (.keyword_data.keyword_info.keyword_difficulty // 0),
                intent: (.keyword_data.search_intent_info.main_intent // "unknown"),
                position: .first_domain_serp_element.serp_item.rank_absolute,
                est_traffic: (.first_domain_serp_element.serp_item.etv // 0),
                ranking_url: .first_domain_serp_element.serp_item.url
            }]' 2>/dev/null || echo "[]")
            ;;
        *)
            # Standard keyword research with SERP analysis
            IFS=',' read -ra keyword_array <<< "$keywords"
            
            # For quick mode, just use keyword suggestions directly
            if [[ "$quick_mode" == "true" ]]; then
                for keyword in "${keyword_array[@]}"; do
                    keyword=$(echo "$keyword" | xargs)
                    print_info "Researching: $keyword"
                    
                    local suggestions
                    suggestions=$(dataforseo_keyword_suggestions "$keyword" "$location_code" "$language_code" "$limit")
                    
                    local parsed
                    parsed=$(echo "$suggestions" | jq '[.tasks[0].result[0].items[]? | {
                        keyword: .keyword,
                        volume: (.keyword_info.search_volume // 0),
                        cpc: (.keyword_info.cpc // 0),
                        difficulty: (.keyword_properties.keyword_difficulty // 0),
                        intent: (.search_intent_info.main_intent // "unknown"),
                        keyword_score: 0,
                        domain_score: 0,
                        page_score: 0,
                        weakness_count: 0,
                        weaknesses: "N/A (quick mode)"
                    }]' 2>/dev/null || echo "[]")
                    
                    results=$(echo "$results $parsed" | jq -s 'add')
                done
            else
                # Full SERP analysis mode - process each keyword individually
                for keyword in "${keyword_array[@]}"; do
                    keyword=$(echo "$keyword" | xargs)
                    print_info "Analyzing SERP for: $keyword"
                    
                    # Get keyword suggestions first
                    local suggestions
                    suggestions=$(dataforseo_keyword_suggestions "$keyword" "$location_code" "$language_code" "$limit")
                    
                    # Get list of keywords
                    local kw_list
                    kw_list=$(echo "$suggestions" | jq -r '.tasks[0].result[0].items[]?.keyword' 2>/dev/null | head -n "$limit")
                    
                    # Process each keyword
                    while IFS= read -r kw; do
                        if [[ -z "$kw" ]]; then
                            continue
                        fi
                        
                        local kw_data
                        kw_data=$(echo "$suggestions" | jq --arg k "$kw" '.tasks[0].result[0].items[] | select(.keyword == $k)' 2>/dev/null)
                        
                        local volume
                        volume=$(echo "$kw_data" | jq -r '.keyword_info.search_volume // 0')
                        local cpc
                        cpc=$(echo "$kw_data" | jq -r '.keyword_info.cpc // 0')
                        local difficulty
                        difficulty=$(echo "$kw_data" | jq -r '.keyword_properties.keyword_difficulty // 0')
                        local intent
                        intent=$(echo "$kw_data" | jq -r '.search_intent_info.main_intent // "unknown"')
                        
                        # Get SERP data for weakness detection
                        local serp_data
                        serp_data=$(dataforseo_serp_organic "$kw" "$location_code" "$language_code")
                        
                        # Detect weaknesses
                        local weakness_result
                        weakness_result=$(detect_weaknesses "$serp_data")
                        local weakness_count
                        weakness_count=$(echo "$weakness_result" | cut -d'|' -f1)
                        local weakness_list
                        weakness_list=$(echo "$weakness_result" | cut -d'|' -f2)
                        
                        # Get domain score from first result
                        local domain_score
                        domain_score=$(echo "$serp_data" | jq -r '.tasks[0].result[0].items[0].main_domain_rank // 0' 2>/dev/null || echo "0")
                        local page_score
                        page_score=$(echo "$serp_data" | jq -r '.tasks[0].result[0].items[0].page_rank // 0' 2>/dev/null || echo "0")
                        
                        # Normalize scores to 0-100
                        domain_score=$(echo "scale=0; $domain_score / 10" | bc 2>/dev/null || echo "0")
                        page_score=$(echo "scale=0; $page_score / 10" | bc 2>/dev/null || echo "0")
                        
                        # Calculate keyword score
                        local serp_features
                        serp_features=$(echo "$serp_data" | jq '.tasks[0].result[0].item_types // []' 2>/dev/null || echo "[]")
                        local keyword_score
                        keyword_score=$(calculate_keyword_score "$weakness_count" "$volume" "$difficulty" "$serp_features")
                        
                        # Build result object and add to results
                        local result_obj
                        result_obj="{\"keyword\":\"$kw\",\"volume\":$volume,\"cpc\":$cpc,\"difficulty\":$difficulty,\"intent\":\"$intent\",\"keyword_score\":$keyword_score,\"domain_score\":$domain_score,\"page_score\":$page_score,\"weakness_count\":$weakness_count,\"weaknesses\":\"$weakness_list\"}"
                        results=$(echo "$results [$result_obj]" | jq -s 'add')
                    done <<< "$kw_list"
                done
            fi
            ;;
    esac
    
    local count
    count=$(echo "$results" | jq 'length')
    print_success "Found $count keywords"
    
    # Print appropriate table
    if [[ "$mode" == "competitor" ]] || [[ "$mode" == "gap" ]] || [[ "$mode" == "domain" ]]; then
        print_research_table "$results" "competitor"
    else
        print_research_table "$results" "extended"
    fi
    
    # Export CSV if requested
    if [[ "$csv_export" == "true" ]]; then
        local timestamp
        timestamp=$(date +"%Y%m%d-%H%M%S")
        if [[ "$mode" == "competitor" ]] || [[ "$mode" == "gap" ]] || [[ "$mode" == "domain" ]]; then
            export_csv "$results" "competitor" "keyword-research-extended-$timestamp.csv"
        else
            export_csv "$results" "extended" "keyword-research-extended-$timestamp.csv"
        fi
    fi
    
    return 0
}

apply_filters() {
    local json_data="$1"
    local filters="$2"
    
    local result="$json_data"
    
    # Parse filters (format: min-volume:1000,max-difficulty:40,intent:commercial,contains:term,excludes:term)
    IFS=',' read -ra filter_array <<< "$filters"
    
    for filter in "${filter_array[@]}"; do
        local key="${filter%%:*}"
        local value="${filter#*:}"
        
        case "$key" in
            "min-volume")
                result=$(echo "$result" | jq --argjson v "$value" '[.[] | select(.volume >= $v)]')
                ;;
            "max-volume")
                result=$(echo "$result" | jq --argjson v "$value" '[.[] | select(.volume <= $v)]')
                ;;
            "min-difficulty")
                result=$(echo "$result" | jq --argjson v "$value" '[.[] | select(.difficulty >= $v)]')
                ;;
            "max-difficulty")
                result=$(echo "$result" | jq --argjson v "$value" '[.[] | select(.difficulty <= $v)]')
                ;;
            "intent")
                result=$(echo "$result" | jq --arg v "$value" '[.[] | select(.intent == $v)]')
                ;;
            "contains")
                result=$(echo "$result" | jq --arg v "$value" '[.[] | select(.keyword | contains($v))]')
                ;;
            "excludes")
                result=$(echo "$result" | jq --arg v "$value" '[.[] | select(.keyword | contains($v) | not)]')
                ;;
            *)
                print_warning "Unknown filter: $key"
                ;;
        esac
    done
    
    echo "$result"
    return 0
}

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

main() {
    local command="${1:-help}"
    shift || true
    
    # Load configuration
    load_config
    
    # Parse options
    local keywords=""
    local provider="$DEFAULT_PROVIDER"
    local locale="$DEFAULT_LOCALE"
    local limit="$DEFAULT_LIMIT"
    local days="30"
    local csv_export="false"
    local quick_mode="false"
    local include_ahrefs="false"
    local enrich="true"
    local mode=""
    local target=""
    local filters=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider)
                provider="$2"
                shift 2
                ;;
            --locale)
                locale="$2"
                shift 2
                ;;
            --limit)
                limit="$2"
                shift 2
                ;;
            --days)
                days="$2"
                shift 2
                ;;
            --csv)
                csv_export="true"
                shift
                ;;
            --quick)
                quick_mode="true"
                shift
                ;;
            --no-enrich)
                enrich="false"
                shift
                ;;
            --ahrefs)
                include_ahrefs="true"
                shift
                ;;
            --domain)
                mode="domain"
                target="$2"
                shift 2
                ;;
            --competitor)
                mode="competitor"
                target="$2"
                shift 2
                ;;
            --gap)
                mode="gap"
                target="$2"
                shift 2
                ;;
            --min-volume)
                filters="${filters:+$filters,}min-volume:$2"
                shift 2
                ;;
            --max-volume)
                filters="${filters:+$filters,}max-volume:$2"
                shift 2
                ;;
            --min-difficulty)
                filters="${filters:+$filters,}min-difficulty:$2"
                shift 2
                ;;
            --max-difficulty)
                filters="${filters:+$filters,}max-difficulty:$2"
                shift 2
                ;;
            --intent)
                filters="${filters:+$filters,}intent:$2"
                shift 2
                ;;
            --contains)
                filters="${filters:+$filters,}contains:$2"
                shift 2
                ;;
            --excludes)
                filters="${filters:+$filters,}excludes:$2"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                show_help
                return 1
                ;;
            *)
                keywords="$1"
                shift
                ;;
        esac
    done
    
    case "$command" in
        "research")
            if [[ -z "$keywords" ]]; then
                print_error "Keywords required"
                show_help
                return 1
            fi
            do_keyword_research "$keywords" "$provider" "$locale" "$limit" "$csv_export" "$filters"
            ;;
        "autocomplete")
            if [[ -z "$keywords" ]]; then
                print_error "Keyword required"
                show_help
                return 1
            fi
            do_autocomplete_research "$keywords" "$provider" "$locale" "$csv_export"
            ;;
        "extended")
            if [[ -z "$keywords" ]] && [[ -z "$mode" ]]; then
                print_error "Keywords or mode (--domain, --competitor, --gap) required"
                show_help
                return 1
            fi
            do_extended_research "$keywords" "$provider" "$locale" "$limit" "$csv_export" "$quick_mode" "$include_ahrefs" "$mode" "$target"
            ;;
        "webmaster")
            if [[ -z "$keywords" ]]; then
                print_error "Site URL required (e.g., https://example.com)"
                show_help
                return 1
            fi
            do_webmaster_research "$keywords" "$days" "$limit" "$csv_export" "$enrich"
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
            read -p "Default provider [dataforseo/serper/both] ($DEFAULT_PROVIDER): " new_provider
            new_provider="${new_provider:-$DEFAULT_PROVIDER}"
            read -p "Default limit ($DEFAULT_LIMIT): " new_limit
            new_limit="${new_limit:-$DEFAULT_LIMIT}"
            save_config "$new_locale" "$new_provider" "$new_limit"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    
    return 0
}

main "$@"
