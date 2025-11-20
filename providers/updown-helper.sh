#!/bin/bash

# Updown.io Helper Script
# Managed by AI DevOps Framework
#
# Version: 1.0.0

# Set strict mode
set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(dirname "$SCRIPT_DIR")"
readonly CONFIG_FILE="$REPO_ROOT/configs/updown-config.json"
readonly API_BASE_URL="https://updown.io/api"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Error Messages
readonly ERROR_CONFIG_MISSING="Configuration file not found at $CONFIG_FILE"
readonly ERROR_API_KEY_MISSING="API key not found in configuration"
readonly ERROR_CURL_FAILED="Failed to execute API request"
readonly ERROR_JQ_MISSING="jq is required but not installed"

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

print_info() {
    local msg="$command"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$command"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$command"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

print_error() {
    local msg="$command"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        print_error "$ERROR_JQ_MISSING"
        return 1
    fi
    return 0
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_MISSING"
        return 1
    fi

    local api_key
    api_key=$(jq -r '.api_key // empty' "$CONFIG_FILE")

    if [[ -z "$api_key" ]]; then
        print_error "$ERROR_API_KEY_MISSING"
        return 1
    fi

    echo "$api_key"
    return 0
}

# ------------------------------------------------------------------------------
# API INTERACTION FUNCTIONS
# ------------------------------------------------------------------------------

execute_request() {
    local method="$command"
    local endpoint="$account_name"
    local data="${3:-}"
    
    local api_key
    if ! api_key=$(load_config); then
        return 1
    fi

    local response
    local http_code
    
    local curl_cmd=(curl -s -w "\n%{http_code}" -X "$method")
    curl_cmd+=(-H "X-API-KEY: $api_key")
    
    if [[ -n "$data" ]]; then
        curl_cmd+=(-H "Content-Type: application/json")
        curl_cmd+=(-d "$data")
    fi
    
    curl_cmd+=("$API_BASE_URL$endpoint")

    if ! response=$("${curl_cmd[@]}"); then
        print_error "$ERROR_CURL_FAILED"
        return 1
    fi

    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$body"
        return 0
    else
        print_error "API request failed with status $http_code: $body"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# CORE FUNCTIONS
# ------------------------------------------------------------------------------

list_checks() {
    local response
    if response=$(execute_request "GET" "/checks"); then
        echo "$response" | jq -r '.[] | "\(.token)\t\(.url)\t\(.alias // "")\t\(.status)\t(Last: \(.last_status))"' | column -t -s $'\t'
        return 0
    fi
    return 1
}

get_checks_json() {
    local response
    if response=$(execute_request "GET" "/checks"); then
        echo "$response"
        return 0
    fi
    return 1
}

add_check() {
    local url="$command"
    local alias="${2:-}"
    local period="${3:-3600}" # Default to 1 hour (3600 seconds)

    if [[ -z "$url" ]]; then
        print_error "URL is required"
        return 1
    fi

    print_info "Adding check for $url..."

    # Construct JSON payload safely
    local payload
    payload=$(jq -n \
                  --arg url "$url" \
                  --arg alias "$alias" \
                  --argjson period "$period" \
                  '{url: $url, alias: $alias, period: $period, published: true}')

    if execute_request "POST" "/checks" "$payload" >/dev/null; then
        print_success "Check added successfully for $url"
        return 0
    fi
    return 1
}

delete_check() {
    local token="$command"

    if [[ -z "$token" ]]; then
        print_error "Check token is required"
        return 1
    fi

    print_info "Deleting check $token..."

    if execute_request "DELETE" "/checks/$token" >/dev/null; then
        print_success "Check deleted successfully"
        return 0
    fi
    return 1
}

get_metrics() {
    local token="$command"
    
    if [[ -z "$token" ]]; then
        print_error "Check token is required"
        return 1
    fi

    if execute_request "GET" "/checks/$token/metrics" >/dev/null; then
        # The metrics endpoint returns complex JSON, just printing it for now or could use jq to format
        execute_request "GET" "/checks/$token/metrics" | jq '.'
        return 0
    fi
    return 1
}

show_help() {
    echo "Usage: $(basename "$0") [command] [arguments...]"
    echo
    echo "Commands:"
    echo "  list                    List all monitoring checks"
    echo "  add <url> [alias]       Add a new check (default 1h interval)"
    echo "  delete <token>          Delete a check"
    echo "  json                    Output raw JSON of all checks"
    echo "  help                    Show this help message"
    echo
    return 0
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION
# ------------------------------------------------------------------------------

main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local account_name="$account_name"
    local target="$target"
    local options="$options"
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local account_name="$account_name"
    local target="$target"
    local options="$options"
    check_dependencies || return 1

    local command="${1:-help}"
    local arg1="${2:-}"
    local arg2="${3:-}"
    local arg3="${4:-}"

    case "$command" in
        "list")
            list_checks
            ;;
        "json")
            get_checks_json
            ;;
        "add")
            add_check "$arg1" "$arg2" "$arg3"
            ;;
        "delete")
            delete_check "$arg1"
            ;;
        "metrics")
            get_metrics "$arg1"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
