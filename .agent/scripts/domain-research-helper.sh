#!/bin/bash
# shellcheck disable=SC2034,SC2155

# Domain Research Helper Script
# DNS intelligence using THC IP database (https://ip.thc.org/) and Reconeer (https://reconeer.com/)
# Provides reverse DNS, subdomain enumeration, and CNAME discovery

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# THC API Configuration
readonly THC_API_BASE="https://ip.thc.org"
readonly THC_API_V1="${THC_API_BASE}/api/v1"
readonly API_BASE="$THC_API_BASE"  # Alias for backward compatibility
readonly API_V1="$THC_API_V1"      # Alias for backward compatibility
readonly MAX_LIMIT=100
readonly MAX_EXPORT_LIMIT=50000
readonly DEFAULT_LIMIT=50

# Reconeer API Configuration
readonly RECONEER_API_BASE="https://reconeer.com"
readonly RECONEER_API="${RECONEER_API_BASE}/api"

# Load API key from environment or config
load_reconeer_api_key() {
    # Check environment variable first
    if [[ -n "${RECONEER_API_KEY:-}" ]]; then
        echo "$RECONEER_API_KEY"
        return 0
    fi
    
    # Check config file
    local config_file="$HOME/.config/aidevops/mcp-env.sh"
    if [[ -f "$config_file" ]]; then
        local key
        key=$(grep -E "^export RECONEER_API_KEY=" "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [[ -n "$key" ]]; then
            echo "$key"
            return 0
        fi
    fi
    
    # No key found
    echo ""
    return 0
}

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

print_header() {
    local msg="$1"
    echo -e "${CYAN}=== $msg ===${NC}"
    return 0
}

# Check for required tools
check_dependencies() {
    local missing=()
    
    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required tools: ${missing[*]}"
        print_info "Install with: brew install ${missing[*]}"
        return 1
    fi
    
    return 0
}

# Simple reverse DNS lookup (CLI-friendly)
rdns_simple() {
    local ip="$1"
    local filter="${2:-}"
    local limit="${3:-$DEFAULT_LIMIT}"
    local nocolor="${4:-0}"
    local noheader="${5:-0}"
    
    local url="${API_BASE}/${ip}?l=${limit}&nocolor=${nocolor}&noheader=${noheader}"
    
    if [[ -n "$filter" ]]; then
        url="${url}&f=${filter}"
    fi
    
    print_info "Looking up domains for IP: $ip"
    curl -s "$url"
    
    return 0
}

# Reverse DNS lookup with JSON output
rdns_json() {
    local ip="$1"
    local limit="${2:-$DEFAULT_LIMIT}"
    local tld_filter="${3:-}"
    local apex_filter="${4:-}"
    local page_state="${5:-}"
    
    local payload="{\"ip_address\":\"$ip\", \"limit\": $limit"
    
    if [[ -n "$tld_filter" ]]; then
        # Convert comma-separated to JSON array
        local tld_array
        tld_array=$(echo "$tld_filter" | tr ',' '\n' | jq -R . | jq -s .)
        payload="${payload}, \"tld\": $tld_array"
    fi
    
    if [[ -n "$apex_filter" ]]; then
        payload="${payload}, \"apex_domain\": \"$apex_filter\""
    fi
    
    if [[ -n "$page_state" ]]; then
        payload="${payload}, \"page_state\": \"$page_state\""
    fi
    
    payload="${payload}}"
    
    print_info "Querying rDNS API for: $ip"
    curl -s -X POST "${API_V1}/lookup" \
        -H "Content-Type: application/json" \
        -d "$payload" | jq .
    
    return 0
}

# IP block lookup (/24, /16, /8)
rdns_block() {
    local ip_block="$1"
    local limit="${2:-$DEFAULT_LIMIT}"
    local tld_filter="${3:-}"
    
    # Validate CIDR notation
    if [[ ! "$ip_block" =~ /[0-9]+$ ]]; then
        print_error "Invalid IP block format. Use CIDR notation (e.g., 1.1.1.0/24)"
        return 1
    fi
    
    local payload="{\"ip_address\":\"$ip_block\", \"limit\": $limit"
    
    if [[ -n "$tld_filter" ]]; then
        local tld_array
        tld_array=$(echo "$tld_filter" | tr ',' '\n' | jq -R . | jq -s .)
        payload="${payload}, \"tld\": $tld_array"
    fi
    
    payload="${payload}}"
    
    print_info "Querying IP block: $ip_block"
    print_warning "Note: TLD filters cannot be used with IP block lookups"
    
    curl -s -X POST "${API_V1}/lookup" \
        -H "Content-Type: application/json" \
        -d "$payload" | jq .
    
    return 0
}

# Simple subdomain lookup (CLI-friendly)
subdomains_simple() {
    local domain="$1"
    local limit="${2:-$DEFAULT_LIMIT}"
    local nocolor="${3:-0}"
    local noheader="${4:-0}"
    
    local url="${API_BASE}/sb/${domain}?l=${limit}&nocolor=${nocolor}&noheader=${noheader}"
    
    print_info "Enumerating subdomains for: $domain"
    curl -s "$url"
    
    return 0
}

# Subdomain lookup with JSON output and pagination
subdomains_json() {
    local domain="$1"
    local limit="${2:-$DEFAULT_LIMIT}"
    local page_state="${3:-}"
    
    local payload="{\"domain\":\"$domain\", \"limit\": $limit"
    
    if [[ -n "$page_state" ]]; then
        payload="${payload}, \"page_state\": \"$page_state\""
    fi
    
    payload="${payload}}"
    
    print_info "Querying subdomains API for: $domain"
    curl -s -X POST "${API_V1}/lookup/subdomains" \
        -H "Content-Type: application/json" \
        -d "$payload" | jq .
    
    return 0
}

# Fetch all subdomains with pagination
subdomains_all() {
    local domain="$1"
    local output_file="${2:-}"
    local limit=100
    local page_state=""
    local total=0
    
    print_info "Fetching all subdomains for: $domain"
    print_info "This may take a while for large domains..."
    
    while true; do
        local payload="{\"domain\":\"$domain\", \"limit\": $limit"
        
        if [[ -n "$page_state" ]]; then
            payload="${payload}, \"page_state\": \"$page_state\""
        fi
        
        payload="${payload}}"
        
        local response
        response=$(curl -s -X POST "${API_V1}/lookup/subdomains" \
            -H "Content-Type: application/json" \
            -d "$payload")
        
        # Extract domains
        local domains
        domains=$(echo "$response" | jq -r '.domains[]?' 2>/dev/null)
        
        if [[ -z "$domains" ]]; then
            break
        fi
        
        local count
        count=$(echo "$domains" | wc -l | tr -d ' ')
        total=$((total + count))
        
        if [[ -n "$output_file" ]]; then
            echo "$domains" >> "$output_file"
        else
            echo "$domains"
        fi
        
        # Get next page state
        page_state=$(echo "$response" | jq -r '.page_state // empty' 2>/dev/null)
        
        if [[ -z "$page_state" ]]; then
            break
        fi
        
        print_info "Fetched $total subdomains so far..."
        sleep 0.5  # Rate limiting
    done
    
    print_success "Total subdomains found: $total"
    
    if [[ -n "$output_file" ]]; then
        print_success "Results saved to: $output_file"
    fi
    
    return 0
}

# Simple CNAME lookup (CLI-friendly)
cnames_simple() {
    local target_domain="$1"
    local limit="${2:-$DEFAULT_LIMIT}"
    local nocolor="${3:-0}"
    local noheader="${4:-0}"
    
    local url="${API_BASE}/cn/${target_domain}?l=${limit}&nocolor=${nocolor}&noheader=${noheader}"
    
    print_info "Finding domains pointing to: $target_domain"
    curl -s "$url"
    
    return 0
}

# CNAME lookup with JSON output and pagination
cnames_json() {
    local target_domain="$1"
    local limit="${2:-$DEFAULT_LIMIT}"
    local apex_filter="${3:-}"
    local page_state="${4:-}"
    
    local payload="{\"target_domain\":\"$target_domain\", \"limit\": $limit"
    
    if [[ -n "$apex_filter" ]]; then
        payload="${payload}, \"apex_domain\": \"$apex_filter\""
    fi
    
    if [[ -n "$page_state" ]]; then
        payload="${payload}, \"page_state\": \"$page_state\""
    fi
    
    payload="${payload}}"
    
    print_info "Querying CNAME API for: $target_domain"
    curl -s -X POST "${API_V1}/lookup/cnames" \
        -H "Content-Type: application/json" \
        -d "$payload" | jq .
    
    return 0
}

# Export rDNS to CSV
export_rdns() {
    local ip="$1"
    local output="${2:-rdns-${ip}.csv}"
    local limit="${3:-$MAX_EXPORT_LIMIT}"
    local hide_header="${4:-false}"
    local apex_filter="${5:-}"
    local tld_filter="${6:-}"
    
    local url="${API_V1}/download?ip_address=${ip}&limit=${limit}"
    
    if [[ "$hide_header" == "true" ]]; then
        url="${url}&hide_header=true"
    fi
    
    if [[ -n "$apex_filter" ]]; then
        url="${url}&apex_domain=${apex_filter}"
    fi
    
    if [[ -n "$tld_filter" ]]; then
        url="${url}&tld=${tld_filter}"
    fi
    
    print_info "Exporting rDNS data for: $ip"
    print_info "Output: $output (limit: $limit)"
    
    curl -s "$url" -o "$output"
    
    if [[ -f "$output" ]]; then
        local lines
        lines=$(wc -l < "$output" | tr -d ' ')
        print_success "Exported $lines records to: $output"
    else
        print_error "Export failed"
        return 1
    fi
    
    return 0
}

# Export subdomains to CSV
export_subdomains() {
    local domain="$1"
    local output="${2:-subdomains-${domain}.csv}"
    local limit="${3:-$MAX_EXPORT_LIMIT}"
    local hide_header="${4:-false}"
    
    local url="${API_V1}/subdomains/download?domain=${domain}&limit=${limit}"
    
    if [[ "$hide_header" == "true" ]]; then
        url="${url}&hide_header=true"
    fi
    
    print_info "Exporting subdomains for: $domain"
    print_info "Output: $output (limit: $limit)"
    
    curl -s "$url" -o "$output"
    
    if [[ -f "$output" ]]; then
        local lines
        lines=$(wc -l < "$output" | tr -d ' ')
        print_success "Exported $lines records to: $output"
    else
        print_error "Export failed"
        return 1
    fi
    
    return 0
}

# Export CNAMEs to CSV
export_cnames() {
    local target_domain="$1"
    local output="${2:-cnames-${target_domain}.csv}"
    local limit="${3:-$MAX_EXPORT_LIMIT}"
    local hide_header="${4:-false}"
    
    local url="${API_V1}/cnames/download?target_domain=${target_domain}&limit=${limit}"
    
    if [[ "$hide_header" == "true" ]]; then
        url="${url}&hide_header=true"
    fi
    
    print_info "Exporting CNAMEs pointing to: $target_domain"
    print_info "Output: $output (limit: $limit)"
    
    curl -s "$url" -o "$output"
    
    if [[ -f "$output" ]]; then
        local lines
        lines=$(wc -l < "$output" | tr -d ' ')
        print_success "Exported $lines records to: $output"
    else
        print_error "Export failed"
        return 1
    fi
    
    return 0
}

# =============================================================================
# RECONEER API FUNCTIONS
# =============================================================================

# Reconeer domain lookup (subdomains with IPs)
reconeer_domain() {
    local domain="$1"
    local api_key="${2:-}"
    local json_output="${3:-false}"
    
    # Load API key if not provided
    if [[ -z "$api_key" ]]; then
        api_key=$(load_reconeer_api_key)
    fi
    
    print_info "[Reconeer] Looking up domain: $domain"
    
    local curl_opts=(-s -L)  # -L follows redirects
    if [[ -n "$api_key" ]]; then
        curl_opts+=(-H "Authorization: Bearer $api_key")
        print_info "Using API key for unlimited access"
    else
        print_warning "No API key - limited to 10 queries/day"
    fi
    
    local response
    response=$(curl "${curl_opts[@]}" "${RECONEER_API}/domain/${domain}")
    
    if [[ "$json_output" == "true" ]]; then
        echo "$response" | jq . 2>/dev/null || echo "$response"
    else
        # Pretty print the response
        if command -v jq &>/dev/null; then
            local count
            count=$(echo "$response" | jq -r '.count // 0' 2>/dev/null)
            print_success "Found $count subdomains for $domain"
            echo ""
            echo "$response" | jq -r '.subdomains[]? | "\(.name)\t\(.ip // "N/A")"' 2>/dev/null | column -t
        else
            echo "$response"
        fi
    fi
    
    return 0
}

# Reconeer IP lookup (hostnames for an IP)
reconeer_ip() {
    local ip="$1"
    local api_key="${2:-}"
    local json_output="${3:-false}"
    
    # Load API key if not provided
    if [[ -z "$api_key" ]]; then
        api_key=$(load_reconeer_api_key)
    fi
    
    print_info "[Reconeer] Looking up IP: $ip"
    
    local curl_opts=(-s -L)  # -L follows redirects
    if [[ -n "$api_key" ]]; then
        curl_opts+=(-H "Authorization: Bearer $api_key")
        print_info "Using API key for unlimited access"
    else
        print_warning "No API key - limited to 10 queries/day"
    fi
    
    local response
    response=$(curl "${curl_opts[@]}" "${RECONEER_API}/ip/${ip}")
    
    if [[ "$json_output" == "true" ]]; then
        echo "$response" | jq . 2>/dev/null || echo "$response"
    else
        # Pretty print the response
        if command -v jq &>/dev/null; then
            echo "$response" | jq -r '.hostnames[]?' 2>/dev/null || echo "$response"
        else
            echo "$response"
        fi
    fi
    
    return 0
}

# Reconeer subdomain details
reconeer_subdomain() {
    local subdomain="$1"
    local api_key="${2:-}"
    local json_output="${3:-false}"
    
    # Load API key if not provided
    if [[ -z "$api_key" ]]; then
        api_key=$(load_reconeer_api_key)
    fi
    
    print_info "[Reconeer] Looking up subdomain: $subdomain"
    
    local curl_opts=(-s -L)  # -L follows redirects
    if [[ -n "$api_key" ]]; then
        curl_opts+=(-H "Authorization: Bearer $api_key")
        print_info "Using API key for unlimited access"
    else
        print_warning "No API key - limited to 10 queries/day"
    fi
    
    local response
    response=$(curl "${curl_opts[@]}" "${RECONEER_API}/subdomain/${subdomain}")
    
    if [[ "$json_output" == "true" ]]; then
        echo "$response" | jq . 2>/dev/null || echo "$response"
    else
        echo "$response" | jq . 2>/dev/null || echo "$response"
    fi
    
    return 0
}

# Reconeer command dispatcher
reconeer_cmd() {
    local subcommand="${1:-help}"
    local target="${2:-}"
    local api_key="${3:-}"
    local json_output="${4:-false}"
    
    case "$subcommand" in
        "domain"|"d")
            if [[ -z "$target" ]]; then
                print_error "Domain required"
                print_info "Usage: $0 reconeer domain <domain> [--api-key KEY]"
                return 1
            fi
            reconeer_domain "$target" "$api_key" "$json_output"
            ;;
        "ip"|"i")
            if [[ -z "$target" ]]; then
                print_error "IP address required"
                print_info "Usage: $0 reconeer ip <ip> [--api-key KEY]"
                return 1
            fi
            reconeer_ip "$target" "$api_key" "$json_output"
            ;;
        "subdomain"|"sub"|"s")
            if [[ -z "$target" ]]; then
                print_error "Subdomain required"
                print_info "Usage: $0 reconeer subdomain <subdomain> [--api-key KEY]"
                return 1
            fi
            reconeer_subdomain "$target" "$api_key" "$json_output"
            ;;
        "help"|"-h"|"--help")
            echo ""
            print_header "Reconeer Commands"
            echo "  reconeer domain <domain>       - Get subdomains with IPs"
            echo "  reconeer ip <ip>               - Get hostnames for IP"
            echo "  reconeer subdomain <subdomain> - Get subdomain details"
            echo ""
            echo "Options:"
            echo "  --api-key <key>   Use API key for unlimited access"
            echo "  --json            Output raw JSON"
            echo ""
            echo "Rate Limits:"
            echo "  Free:    10 queries/day (no key required)"
            echo "  Premium: Unlimited (\$49/mo with API key)"
            echo ""
            echo "API Key Setup:"
            echo "  export RECONEER_API_KEY=\"your-key\" in ~/.config/aidevops/mcp-env.sh"
            echo ""
            ;;
        *)
            print_error "Unknown Reconeer command: $subcommand"
            print_info "Use '$0 reconeer help' for usage"
            return 1
            ;;
    esac
    
    return 0
}

# =============================================================================
# THC API FUNCTIONS (continued)
# =============================================================================

# Lookup current IP
my_ip() {
    print_info "Looking up domains for your current IP..."
    curl -s "${API_BASE}/me"
    return 0
}

# Show rate limit status
rate_limit() {
    print_info "Checking rate limit status..."
    local response
    response=$(curl -s "${API_BASE}/me" 2>/dev/null | head -20)
    
    # Extract rate limit info from response
    echo "$response" | grep -E "Rate Limit|requests"
    
    return 0
}

# Show help
show_help() {
    echo "Domain Research Helper Script"
    echo "DNS intelligence using THC (ip.thc.org) and Reconeer (reconeer.com)"
    echo ""
    echo "$USAGE_COMMAND_OPTIONS"
    echo ""
    echo "Data Sources:"
    echo "  THC:      4.51B records, rDNS/CNAMEs/exports, 250 req (0.5/sec replenish)"
    echo "  Reconeer: Enriched subdomains, 10/day free, \$49/mo unlimited"
    echo ""
    print_header "THC: Reverse DNS (IP to Domains)"
    echo "  rdns <ip>                      - Simple rDNS lookup"
    echo "  rdns <ip> --filter <domain>    - Filter by apex domain"
    echo "  rdns <ip> --limit <n>          - Limit results (max 100)"
    echo "  rdns <ip> --json               - JSON output with metadata"
    echo "  rdns-block <ip/cidr>           - IP block lookup (/24, /16, /8)"
    echo ""
    print_header "THC: Subdomain Enumeration"
    echo "  subdomains <domain>            - Simple subdomain lookup"
    echo "  subdomains <domain> --all      - Fetch all with pagination"
    echo "  subdomains <domain> --json     - JSON output with metadata"
    echo "  subdomains <domain> --limit <n> - Limit results (max 100)"
    echo ""
    print_header "THC: CNAME Discovery"
    echo "  cnames <target>                - Find domains pointing to target"
    echo "  cnames <target> --filter <apex> - Filter by apex domain"
    echo "  cnames <target> --json         - JSON output with metadata"
    echo ""
    print_header "THC: CSV Exports (up to 50,000 records)"
    echo "  export-rdns <ip> [--output file.csv]"
    echo "  export-subdomains <domain> [--output file.csv]"
    echo "  export-cnames <target> [--output file.csv]"
    echo ""
    print_header "Reconeer: Enriched Subdomain Enumeration"
    echo "  reconeer domain <domain>       - Get subdomains with IPs"
    echo "  reconeer ip <ip>               - Get hostnames for IP"
    echo "  reconeer subdomain <sub>       - Get subdomain details"
    echo "  reconeer help                  - Reconeer-specific help"
    echo ""
    print_header "Utilities"
    echo "  my-ip                          - Lookup your current IP (THC)"
    echo "  rate-limit                     - Check THC rate limit status"
    echo "  help                           - $HELP_SHOW_MESSAGE"
    echo ""
    echo "Options:"
    echo "  --filter <domain>   Filter results by apex domain"
    echo "  --limit <n>         Limit results (default: 50, max: 100)"
    echo "  --tld <tld1,tld2>   Filter by TLDs (comma-separated)"
    echo "  --json              Output in JSON format"
    echo "  --all               Fetch all results with pagination"
    echo "  --output <file>     Output file for exports"
    echo "  --no-header         Hide CSV headers in exports"
    echo "  --api-key <key>     Reconeer API key for unlimited access"
    echo ""
    echo "Examples:"
    echo "  # THC examples"
    echo "  $0 rdns 1.1.1.1"
    echo "  $0 rdns 8.8.8.8 --json --limit 20"
    echo "  $0 rdns-block 1.1.1.0/24 --tld com,org"
    echo "  $0 subdomains github.com --all"
    echo "  $0 cnames github.io --limit 50"
    echo "  $0 export-subdomains example.com --output subs.csv"
    echo ""
    echo "  # Reconeer examples"
    echo "  $0 reconeer domain github.com"
    echo "  $0 reconeer ip 140.82.121.4"
    echo "  $0 reconeer domain example.com --api-key YOUR_KEY"
    echo ""
    echo "Rate Limits:"
    echo "  THC:      250 requests, replenishes at 0.50/sec (~8 min recovery)"
    echo "  Reconeer: 10/day free, unlimited with \$49/mo premium"
    echo ""
    echo "API Key Setup (Reconeer):"
    echo "  Add to ~/.config/aidevops/mcp-env.sh:"
    echo "    export RECONEER_API_KEY=\"your-api-key-here\""
    echo ""
    echo "Database Info (THC):"
    echo "  - 4.51 billion records (updated monthly)"
    echo "  - Powered by Segfault, Domainsproject, CertStream-Domains"
    echo "  - Full database downloads: https://cs2.ip.thc.org/RDNS/readme.txt"
    
    return 0
}

# Main function
main() {
    if ! check_dependencies; then
        return 1
    fi
    
    local command="${1:-help}"
    shift || true
    
    # Parse arguments
    local target=""
    local filter=""
    local limit="$DEFAULT_LIMIT"
    local tld=""
    local json_output=false
    local all_pages=false
    local output=""
    local no_header=false
    local api_key=""
    local reconeer_subcommand=""
    
    # For reconeer command, capture subcommand first
    if [[ "$command" == "reconeer" ]]; then
        reconeer_subcommand="${1:-help}"
        shift || true
    fi
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filter|-f)
                filter="$2"
                shift 2
                ;;
            --limit|-l)
                limit="$2"
                shift 2
                ;;
            --tld|-t)
                tld="$2"
                shift 2
                ;;
            --json|-j)
                json_output=true
                shift
                ;;
            --all|-a)
                all_pages=true
                shift
                ;;
            --output|-o)
                output="$2"
                shift 2
                ;;
            --no-header)
                no_header=true
                shift
                ;;
            --api-key|-k)
                api_key="$2"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                fi
                shift
                ;;
        esac
    done
    
    case "$command" in
        "rdns")
            if [[ -z "$target" ]]; then
                print_error "IP address required"
                print_info "Usage: $0 rdns <ip> [options]"
                return 1
            fi
            
            if [[ "$json_output" == true ]]; then
                rdns_json "$target" "$limit" "$tld" "$filter"
            else
                rdns_simple "$target" "$filter" "$limit" "1" "0"
            fi
            ;;
        "rdns-block")
            if [[ -z "$target" ]]; then
                print_error "IP block required (CIDR notation)"
                print_info "Usage: $0 rdns-block <ip/cidr> [options]"
                return 1
            fi
            rdns_block "$target" "$limit" "$tld"
            ;;
        "subdomains"|"subs"|"sb")
            if [[ -z "$target" ]]; then
                print_error "Domain required"
                print_info "Usage: $0 subdomains <domain> [options]"
                return 1
            fi
            
            if [[ "$all_pages" == true ]]; then
                subdomains_all "$target" "$output"
            elif [[ "$json_output" == true ]]; then
                subdomains_json "$target" "$limit"
            else
                subdomains_simple "$target" "$limit" "1" "0"
            fi
            ;;
        "cnames"|"cn")
            if [[ -z "$target" ]]; then
                print_error "Target domain required"
                print_info "Usage: $0 cnames <target> [options]"
                return 1
            fi
            
            if [[ "$json_output" == true ]]; then
                cnames_json "$target" "$limit" "$filter"
            else
                cnames_simple "$target" "$limit" "1" "0"
            fi
            ;;
        "export-rdns")
            if [[ -z "$target" ]]; then
                print_error "IP address required"
                print_info "Usage: $0 export-rdns <ip> [--output file.csv]"
                return 1
            fi
            
            local hide_header_str="false"
            if [[ "$no_header" == true ]]; then
                hide_header_str="true"
            fi
            
            export_rdns "$target" "$output" "$limit" "$hide_header_str" "$filter" "$tld"
            ;;
        "export-subdomains"|"export-subs")
            if [[ -z "$target" ]]; then
                print_error "Domain required"
                print_info "Usage: $0 export-subdomains <domain> [--output file.csv]"
                return 1
            fi
            
            local hide_header_str="false"
            if [[ "$no_header" == true ]]; then
                hide_header_str="true"
            fi
            
            export_subdomains "$target" "$output" "$limit" "$hide_header_str"
            ;;
        "export-cnames"|"export-cn")
            if [[ -z "$target" ]]; then
                print_error "Target domain required"
                print_info "Usage: $0 export-cnames <target> [--output file.csv]"
                return 1
            fi
            
            local hide_header_str="false"
            if [[ "$no_header" == true ]]; then
                hide_header_str="true"
            fi
            
            export_cnames "$target" "$output" "$limit" "$hide_header_str"
            ;;
        "my-ip"|"me")
            my_ip
            ;;
        "rate-limit"|"rate"|"limit")
            rate_limit
            ;;
        "reconeer"|"rn")
            reconeer_cmd "$reconeer_subcommand" "$target" "$api_key" "$json_output"
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            print_info "$HELP_USAGE_INFO"
            return 1
            ;;
    esac
    
    return 0
}

# Run main function
main "$@"
