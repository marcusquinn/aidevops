#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2154,SC2155
set -euo pipefail

# Spaceship Domain Registrar Helper Script
# Comprehensive domain and DNS management for AI assistants

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# String literal constants
readonly DOMAINS_ENDPOINT="domains"


# HTTP Constants
# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 <command> [options]"

# Common constants

# Optional JSON fallback, resolved from the script directory (not the caller's cwd)
# Default: repository-root configs/ (documented); falls back to .agents/configs/.
CONFIG_FILE="${SPACESHIP_CONFIG_FILE:-${SCRIPT_DIR}/../../configs/spaceship-config.json}"
if [[ -z "${SPACESHIP_CONFIG_FILE:-}" && ! -f "$CONFIG_FILE" && -f "${SCRIPT_DIR}/../configs/spaceship-config.json" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/../configs/spaceship-config.json"
fi
# Official docs: https://docs.spaceship.dev/ (auth: X-API-Key + X-API-Secret headers)
API_BASE_URL="${SPACESHIP_API_BASE_URL:-https://spaceship.dev/api/v1}"

# jq filters for the availability response (result + premiumPricing)
readonly JQ_IS_AVAILABLE='if .result == "available" then "true" else "false" end'
readonly JQ_REGISTER_PRICE='(.premiumPricing // []) | map(select(.operation == "register")) | .[0] | if . then "\(.price) \(.currency)" else "N/A" end'

# Endpoint path builders: domain_endpoint <domain> [suffix], dns_endpoint <domain>
domain_endpoint() {
    local domain="$1"
    local suffix="${2:-}"
    printf '%s/%s%s' "$DOMAINS_ENDPOINT" "$domain" "$suffix"
    return 0
}

dns_endpoint() {
    local domain="$1"
    printf 'dns/records/%s' "$domain"
    return 0
}

# Check dependencies
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        print_error "$ERROR_CURL_REQUIRED"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "$ERROR_JQ_REQUIRED"
        echo "$INFO_JQ_INSTALL_MACOS" >&2
        echo "$INFO_JQ_INSTALL_UBUNTU" >&2
        exit 1
    fi

    return 0
}

# Normalise an account name to an env-var segment (e.g. my-acct -> MY_ACCT)
account_env_segment() {
    local account_name="$1"
    printf '%s' "$account_name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_'
    return 0
}

# Resolve credentials for an account into SPACESHIP_RESOLVED_KEY / _SECRET.
# Order: env (aidevops secret injection) SPACESHIP_<ACCOUNT>_API_KEY/_API_SECRET,
# then SPACESHIP_API_KEY/_API_SECRET, then the JSON config file fallback.
# Values are never printed.
resolve_credentials() {
    local account_name="$1"
    local seg key_var secret_var
    seg=$(account_env_segment "$account_name")
    key_var="SPACESHIP_${seg}_API_KEY"
    secret_var="SPACESHIP_${seg}_API_SECRET"

    SPACESHIP_RESOLVED_KEY="${!key_var:-${SPACESHIP_API_KEY:-}}"
    SPACESHIP_RESOLVED_SECRET="${!secret_var:-${SPACESHIP_API_SECRET:-}}"

    if [[ -z "$SPACESHIP_RESOLVED_KEY" || -z "$SPACESHIP_RESOLVED_SECRET" ]] && [[ -f "$CONFIG_FILE" ]]; then
        local cfg
        cfg=$(jq -c ".accounts.\"$account_name\" // empty" "$CONFIG_FILE" 2>/dev/null || true)
        if [[ -n "$cfg" ]]; then
            [[ -n "$SPACESHIP_RESOLVED_KEY" ]] || SPACESHIP_RESOLVED_KEY=$(printf '%s' "$cfg" | jq -r '.api_key // empty')
            [[ -n "$SPACESHIP_RESOLVED_SECRET" ]] || SPACESHIP_RESOLVED_SECRET=$(printf '%s' "$cfg" | jq -r '.api_secret // empty')
        fi
    fi

    if [[ -z "$SPACESHIP_RESOLVED_KEY" || -z "$SPACESHIP_RESOLVED_SECRET" ]]; then
        print_error "No Spaceship credentials for account '$account_name'" >&2
        print_info "Run via: aidevops secret ${key_var} ${secret_var} -- $0 <command> ..." >&2
        print_info "Or provide the JSON config fallback: $CONFIG_FILE" >&2
        return 1
    fi
    return 0
}

# Make API request. Sends X-API-Key / X-API-Secret via curl stdin config so
# credentials never appear in argv or output. Prints the response body;
# returns 1 on non-2xx. Set SPACESHIP_DRY_RUN=1 to print non-GET requests only.
api_request() {
    local account_name="$1"
    local method="$2"
    local endpoint="$3"
    local data="${4:-}"
    local url="$API_BASE_URL/$endpoint"

    if [[ "${SPACESHIP_DRY_RUN:-0}" == "1" && "$method" != "GET" ]]; then
        print_info "[dry-run] $method $url" >&2
        if [[ -n "$data" ]]; then
            printf '%s\n' "$data" | jq '.' >&2
        fi
        return 0
    fi

    resolve_credentials "$account_name" || return 1

    local body_file
    body_file=$(mktemp) || return 1
    local header_file
    header_file=$(mktemp) || return 1
    local -a args=(-s -S -D "$header_file" -o "$body_file" -w '%{http_code}' -X "$method" -K - -H "$CONTENT_TYPE_JSON")
    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi
    args+=("$url")

    local http_code
    http_code=$(printf 'header = "X-API-Key: %s"\nheader = "X-API-Secret: %s"\n' \
        "$SPACESHIP_RESOLVED_KEY" "$SPACESHIP_RESOLVED_SECRET" | curl "${args[@]}") || http_code="000"

    # Async operations (HTTP 202) return an operation ID header; hand it to callers
    # via SPACESHIP_OPERATION_FILE (api_request runs in a subshell, so no globals).
    if [[ -n "${SPACESHIP_OPERATION_FILE:-}" ]]; then
        tr -d '\r' <"$header_file" | awk -F': ' 'tolower($1)=="spaceship-async-operationid"{print $2; exit}' >"$SPACESHIP_OPERATION_FILE"
    fi
    cat "$body_file"
    rm -f "$body_file" "$header_file"

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    fi
    print_error "Spaceship API returned HTTP $http_code" >&2
    return 1
}

# List all configured accounts (config file and SPACESHIP_<ACCOUNT>_API_KEY env vars)
list_accounts() {
    print_info "Available Spaceship accounts:"
    local found=0
    if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" 2>/dev/null; then
        local account
        while read -r account; do
            [[ -n "$account" ]] || continue
            local description email
            description=$(jq -r ".accounts.\"$account\".description // \"\"" "$CONFIG_FILE")
            email=$(jq -r ".accounts.\"$account\".email // \"\"" "$CONFIG_FILE")
            echo "  - $account ($email) - $description"
            found=1
        done < <(jq -r '.accounts // {} | keys[]' "$CONFIG_FILE")
    fi
    local var
    while read -r var; do
        [[ -n "$var" ]] || continue
        echo "  - env: ${var%_API_KEY} (names only; values hidden)"
        found=1
    done < <(compgen -e | grep -E '^SPACESHIP_.+_API_KEY$' || true)
    if [[ "$found" -eq 0 ]]; then
        print_info "None found. Store SPACESHIP_<ACCOUNT>_API_KEY and SPACESHIP_<ACCOUNT>_API_SECRET with 'aidevops secret set'."
    fi
    return 0
}

# List domains (paginated, 100 per page)
list_domains() {
    local account_name="$1"
    print_info "Listing domains for account: $account_name"
    local skip=0 total=1 response
    while [[ "$skip" -lt "$total" ]]; do
        if ! response=$(api_request "$account_name" "GET" "${DOMAINS_ENDPOINT}?take=100&skip=${skip}"); then
            print_error "Failed to retrieve domains"
            echo "$response"
            return 1
        fi
        echo "$response" | jq -r '.items[] | "\(.name) - Status: \(.lifecycleStatus) - Expires: \(.expirationDate)"'
        total=$(echo "$response" | jq -r '.total // 0')
        skip=$((skip + 100))
    done
    return 0
}

# Check domain availability
check_domain_availability() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi

    print_info "Checking availability for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "$(domain_endpoint "$domain" /available)"); then
        local available
        available=$(echo "$response" | jq -r "$JQ_IS_AVAILABLE")
        local price
        price=$(echo "$response" | jq -r "$JQ_REGISTER_PRICE")

        if [[ "$available" == "true" ]]; then
            print_success "Domain $domain is available for registration"
            echo "Price: $price"
        else
            print_warning "Domain $domain is not available"
        fi

        echo "$response" | jq '.'
    else
        print_error "Failed to check domain availability"
        echo "$response"
    fi
    return 0
}

# Purchase domain
purchase_domain() {
    local account_name="$1"
    local domain="$2"
    local years="${3:-1}"
    local auto_renew="${4:-false}"

    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi

    # First check availability
    print_info "Checking availability before purchase..."
    local availability
    availability=$(api_request "$account_name" "GET" "$(domain_endpoint "$domain" /available)") || return 1
    local available
    available=$(echo "$availability" | jq -r "$JQ_IS_AVAILABLE")

    if [[ "$available" != "true" ]]; then
        print_error "Domain $domain is not available for registration"
        return 1
    fi

    local price
    price=$(echo "$availability" | jq -r "$JQ_REGISTER_PRICE")
    print_warning "Domain $domain will be purchased for $price for $years year(s)"
    print_warning "This action will charge your account. Continue? (y/N)"

    read -r confirmation
    if [[ "$confirmation" != "y" && "$confirmation" != "Y" ]]; then
        print_info "Domain purchase cancelled"
        return 0
    fi

    local contact_id="${SPACESHIP_CONTACT_ID:-}"
    if [[ -z "$contact_id" ]]; then
        print_error "Set SPACESHIP_CONTACT_ID to an existing Spaceship contact ID (see 'contacts' on an owned domain)"
        return 1
    fi

    local data
    data=$(jq -n \
        --argjson years "$years" \
        --argjson auto_renew "$auto_renew" \
        --arg contact "$contact_id" \
        '{autoRenew: $auto_renew, years: $years, privacyProtection: {level: "high", userConsent: true},
          contacts: {registrant: $contact, admin: $contact, tech: $contact, billing: $contact}}')

    print_info "Purchasing domain: $domain"
    local response op_file operation_id
    op_file=$(mktemp) || return 1
    if response=$(SPACESHIP_OPERATION_FILE="$op_file" api_request "$account_name" "POST" "$DOMAINS_ENDPOINT/$domain" "$data"); then
        operation_id=$(cat "$op_file")
        rm -f "$op_file"
        print_success "Domain registration accepted (pending; not yet complete)"
        if [[ -n "$operation_id" ]]; then
            print_info "Operation ID: $operation_id"
            print_info "Check final status: $0 operation-status $account_name $operation_id"
        fi
        [[ -z "$response" ]] || echo "$response" | jq '.'
    else
        rm -f "$op_file"
        print_error "Failed to purchase domain"
        echo "$response"
        return 1
    fi
    return 0
}

# Check status of an asynchronous operation (e.g. domain registration)
get_operation_status() {
    local account_name="$1"
    local operation_id="${2:-}"

    if [[ -z "$operation_id" ]]; then
        print_error "Operation ID is required"
        return 1
    fi

    local response
    if response=$(api_request "$account_name" "GET" "async-operations/$operation_id"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get operation status"
        echo "$response"
        return 1
    fi
    return 0
}

# Bulk domain availability check
bulk_check_domains() {
    local account_name="$1"
    shift
    local domains=("$@")

    if [[ ${#domains[@]} -eq 0 ]]; then
        print_error "At least one domain is required"
        exit 1
    fi

    print_info "Checking availability for ${#domains[@]} domains"
    echo ""

    for domain in "${domains[@]}"; do
        echo "Checking: $domain"
        check_domain_availability "$account_name" "$domain"
        echo ""
        sleep 1  # Rate limiting
    done
    return 0
}

# Get domain details
get_domain_details() {
    local account_name="$1"
    local domain="$2"
    
    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi
    
    print_info "Getting details for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "$(domain_endpoint "$domain")"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get domain details"
        echo "$response"
    fi
    return 0
}

# List DNS records
list_dns_records() {
    local account_name="$1"
    local domain="$2"
    
    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi
    
    print_info "Listing DNS records for domain: $domain"
    local response skip=0 total=1
    while [[ "$skip" -lt "$total" ]]; do
        if ! response=$(api_request "$account_name" "GET" "$(dns_endpoint "$domain")?take=100&skip=${skip}"); then
            print_error "Failed to retrieve DNS records"
            echo "$response"
            return 1
        fi
        echo "$response" | jq -r '.items[] | "\(.name) \(.type) \(.address // .cname // .nameserver // .value // .exchange // .target // "") (TTL: \(.ttl))"'
        total=$(echo "$response" | jq -r '.total // 0')
        skip=$((skip + 100))
    done
    return 0
}

# Build a Spaceship resource-record object (value field depends on record type)
dns_record_payload() {
    local name="$1"
    local type="$2"
    local content="$3"
    local ttl="$4"
    jq -n --arg name "$name" --arg type "$type" --arg content "$content" --arg ttl "$ttl" '
        ($type | ascii_upcase) as $t
        | {type: $t, name: $name, ttl: ($ttl | tonumber)}
        + (if ($t == "A" or $t == "AAAA") then {address: $content}
           elif $t == "CNAME" then {cname: $content}
           elif $t == "MX" then {exchange: ($content | split(" ") | .[1] // .[0]), preference: (($content | split(" ") | if length > 1 then .[0] else "10" end) | tonumber)}
           elif $t == "NS" then {nameserver: $content}
           else {value: $content} end)'
    return 0
}

# Add DNS record
add_dns_record() {
    local account_name="$1"
    local domain="$2"
    local name="$3"
    local type="$4"
    local content="$5"
    local ttl="${6:-3600}"
    
    if [[ -z "$domain" || -z "$name" || -z "$type" || -z "$content" ]]; then
        print_error "Domain, name, type, and content are required"
        exit 1
    fi
    
    local data
    data=$(dns_record_payload "$name" "$type" "$content" "$ttl" | jq -c '{items: [.]}')
    
    print_info "Adding DNS record: $name $type $content"
    local response
    if response=$(api_request "$account_name" "PUT" "$(dns_endpoint "$domain")" "$data"); then
        print_success "DNS record added successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to add DNS record"
        echo "$response"
    fi
    return 0
}

# Update DNS record
update_dns_record() {
    local account_name="$1"
    local domain="$2"
    # Spaceship has no record IDs and matches records by type+name+value, so the
    # old record's value is required to remove it before adding the new one.
    local old_content="$3"
    local name="$4"
    local type="$5"
    local content="$6"
    local ttl="${7:-3600}"
    
    if [[ -z "$domain" || -z "$old_content" || -z "$name" || -z "$type" || -z "$content" ]]; then
        print_error "Domain, old content, name, type, and new content are required"
        exit 1
    fi
    
    local del_data add_data
    del_data=$(dns_record_payload "$name" "$type" "$old_content" "3600" | jq -c '[del(.ttl)]')
    add_data=$(dns_record_payload "$name" "$type" "$content" "$ttl" | jq -c '{force: true, items: [.]}')
    
    print_info "Replacing DNS record: $name $type ($old_content -> $content)"
    local response
    if ! response=$(api_request "$account_name" "DELETE" "$(dns_endpoint "$domain")" "$del_data"); then
        print_error "Failed to remove old DNS record; nothing was changed"
        echo "$response"
        return 1
    fi
    if response=$(api_request "$account_name" "PUT" "$(dns_endpoint "$domain")" "$add_data"); then
        print_success "DNS record replaced successfully"
        echo "$response" | jq '.'
    else
        print_error "Old record removed but adding the new record failed; re-add it manually"
        echo "$response"
        return 1
    fi
    return 0
}

# Delete DNS record
delete_dns_record() {
    local account_name="$1"
    local domain="$2"
    local name="${3:-}"
    local type="${4:-}"
    local content="${5:-}"

    if [[ -z "$domain" || -z "$name" || -z "$type" || -z "$content" ]]; then
        print_error "Domain, name, type, and content are required (records are matched by value)"
        exit 1
    fi

    local data
    data=$(dns_record_payload "$name" "$type" "$content" "3600" | jq -c '[del(.ttl)]')

    print_warning "Deleting DNS record: $name $type"
    local response
    if response=$(api_request "$account_name" "DELETE" "$(dns_endpoint "$domain")" "$data"); then
        print_success "DNS record deleted successfully"
    else
        print_error "Failed to delete DNS record"
        echo "$response"
    fi
    return 0
}

# Get domain nameservers
get_nameservers() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi

    print_info "Getting nameservers for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "$(domain_endpoint "$domain")"); then
        echo "$response" | jq -r '.nameservers | "provider: \(.provider)", (.hosts // [])[]'
    else
        print_error "Failed to get nameservers"
        echo "$response"
    fi
    return 0
}

# Update nameservers
update_nameservers() {
    local account_name="$1"
    local domain="$2"
    shift 2
    local nameservers=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--dry-run" ]]; then
            export SPACESHIP_DRY_RUN=1
        else
            nameservers+=("$arg")
        fi
    done

    if [[ -z "$domain" || ${#nameservers[@]} -eq 0 ]]; then
        print_error "Domain and at least one nameserver (or 'basic') are required"
        exit 1
    fi

    local data
    if [[ ${#nameservers[@]} -eq 1 && "${nameservers[0]}" == "basic" ]]; then
        # Spaceship's own DNS: provider "basic", hosts omitted
        data=$(jq -cn '{provider: "basic"}')
    else
        local ns_json
        ns_json=$(printf '%s\n' "${nameservers[@]}" | jq -R . | jq -s .)
        data=$(jq -cn --argjson hosts "$ns_json" '{provider: "custom", hosts: $hosts}')
    fi

    print_info "Updating nameservers for domain: $domain"
    local response
    if response=$(api_request "$account_name" "PUT" "$(domain_endpoint "$domain" /nameservers)" "$data"); then
        if [[ "${SPACESHIP_DRY_RUN:-0}" == "1" ]]; then
            print_info "Dry run: no request sent"
        else
            print_success "Nameservers updated successfully"
            echo "$response" | jq '.'
        fi
    else
        print_error "Failed to update nameservers"
        echo "$response"
    fi
    return 0
}

# Check domain availability
check_availability() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi

    print_info "Checking availability for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "$(domain_endpoint "$domain" /available)"); then
        local available
        available=$(echo "$response" | jq -r "$JQ_IS_AVAILABLE")
        local price
        price=$(echo "$response" | jq -r "$JQ_REGISTER_PRICE")

        if [[ "$available" == "true" ]]; then
            print_success "Domain $domain is available for $price"
        else
            print_warning "Domain $domain is not available"
        fi
        echo "$response" | jq '.'
    else
        print_error "Failed to check domain availability"
        echo "$response"
    fi
    return 0
}

# Get domain contacts
get_domain_contacts() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi

    print_info "Getting contacts for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "$(domain_endpoint "$domain")"); then
        echo "$response" | jq '.contacts'
    else
        print_error "Failed to get domain contacts"
        echo "$response"
    fi
    return 0
}

# Enable/disable domain lock
toggle_domain_lock() {
    local account_name="$1"
    local domain="$2"
    local action="$3"  # "lock" or "unlock"

    if [[ -z "$domain" || -z "$action" ]]; then
        print_error "Domain and action (lock/unlock) are required"
        exit 1
    fi

    local locked="true"
    if [[ "$action" == "unlock" ]]; then
        locked="false"
    fi

    local data
    data=$(jq -cn --arg locked "$locked" '{isLocked: ($locked == "true")}')

    # Bash 3.2 compat: ${var^} requires Bash 4+
    local action_cap
    action_cap="$(printf '%s' "${action:0:1}" | tr '[:lower:]' '[:upper:]')${action:1}"
    print_info "${action_cap}ing domain: $domain"
    local response
    if response=$(api_request "$account_name" "PUT" "$(domain_endpoint "$domain" /transfer/lock)" "$data"); then
        print_success "Domain ${action}ed successfully"
        echo "$response" | jq '.'
    else
        print_error "Failed to $action domain"
        echo "$response"
    fi
    return 0
}

# Get domain transfer status
get_transfer_status() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi

    print_info "Getting transfer status for domain: $domain"
    local response
    if response=$(api_request "$account_name" "GET" "$(domain_endpoint "$domain" /transfer)"); then
        echo "$response" | jq '.'
    else
        print_error "Failed to get transfer status"
        echo "$response"
    fi
    return 0
}

# Audit domain configuration
audit_domain() {
    local account_name="$1"
    local domain="$2"

    if [[ -z "$domain" ]]; then
        print_error "$ERROR_DOMAIN_NAME_REQUIRED"
        exit 1
    fi

    print_info "Auditing domain configuration: $domain"
    echo ""

    print_info "=== DOMAIN DETAILS ==="
    get_domain_details "$account_name" "$domain"
    echo ""

    print_info "=== NAMESERVERS ==="
    get_nameservers "$account_name" "$domain"
    echo ""

    print_info "=== DNS RECORDS ==="
    list_dns_records "$account_name" "$domain"
    echo ""

    print_info "=== DOMAIN CONTACTS ==="
    get_domain_contacts "$account_name" "$domain"
    return 0
}

# Monitor domain expiration
monitor_expiration() {
    local account_name="$1"
    local days_threshold="${2:-30}"

    print_info "Monitoring domain expiration (threshold: $days_threshold days)"
    local response skip=0 total=1
    while [[ "$skip" -lt "$total" ]]; do
        if ! response=$(api_request "$account_name" "GET" "${DOMAINS_ENDPOINT}?take=100&skip=${skip}"); then
            print_error "Failed to retrieve domain expiration data"
            echo "$response"
            return 1
        fi
        echo "$response" | jq -r --arg threshold "$days_threshold" '
            def days: ((.expirationDate | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - now) / 86400;
            .items[] |
            select(.expirationDate != null) |
            select(days < ($threshold | tonumber)) |
            "\(.name) expires on \(.expirationDate) (\(days | floor) days)"
        '
        total=$(echo "$response" | jq -r '.total // 0')
        skip=$((skip + 100))
    done
    return 0
}

# Show help
show_help() {
    echo "Spaceship Domain Registrar Helper Script"
    echo "Usage: $0 [command] [account] [options]"
    echo ""
    echo "Commands:"
    echo "  accounts                                    - List all configured accounts"
    echo "  domains [account]                           - List all domains"
    echo "  domain-details [account] [domain]           - Get domain details"
    echo "  dns-records [account] [domain]              - List DNS records"
    echo "  add-dns [account] [domain] [name] [type] [content] [ttl] - Add DNS record"
    echo "  update-dns [account] [domain] [old_content] [name] [type] [new_content] [ttl] - Replace DNS record (delete old value, add new)"
    echo "  delete-dns [account] [domain] [name] [type] [content] - Delete DNS record"
    echo "  nameservers [account] [domain]              - Get nameservers"
    echo "  update-ns [account] [domain] [ns1] [ns2...|basic] [--dry-run] - Update nameservers"
    echo "  check-availability [account] [domain]       - Check domain availability"
    echo "  purchase [account] [domain] [years] [auto_renew] - Purchase domain"
    echo "  operation-status [account] [operation_id]   - Check async operation (e.g. purchase) status"
    echo "  bulk-check [account] [domain1] [domain2...] - Bulk check domain availability"
    echo "  contacts [account] [domain]                 - Get domain contacts"
    echo "  lock [account] [domain]                     - Lock domain"
    echo "  unlock [account] [domain]                   - Unlock domain"
    echo "  transfer-status [account] [domain]          - Get transfer status"
    echo "  audit [account] [domain]                    - Audit domain configuration"
    echo "  monitor-expiration [account] [days]         - Monitor domain expiration"
    echo "  help                 - $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 accounts"
    echo "  $0 domains personal"
    echo "  $0 dns-records personal example.com"
    echo "  $0 add-dns personal example.com www A 192.168.1.100"
    echo "  $0 audit personal example.com"
    echo "  $0 monitor-expiration personal 30"
    return 0
}

# Main script logic
main() {
    local subcommand="${1:-help}"
    local account_name="${2:-}"
    local domain="${3:-}"
    local param4="${4:-}"
    local param5="${5:-}"
    local param6="${6:-}"
    local param7="${7:-}"
    local param8="${8:-}"

    if [[ "$subcommand" == "help" ]]; then
        show_help
        return 0
    fi

    check_dependencies

    case "$subcommand" in
        "accounts")
            list_accounts
            ;;
        "domains")
            list_domains "$account_name"
            ;;
        "domain-details")
            get_domain_details "$account_name" "$domain"
            ;;
        "dns-records")
            list_dns_records "$account_name" "$domain"
            ;;
        "add-dns")
            add_dns_record "$account_name" "$domain" "$param4" "$param5" "$param6" "$param7"
            ;;
        "update-dns")
            update_dns_record "$account_name" "$domain" "$param4" "$param5" "$param6" "$param7" "$param8"
            ;;
        "delete-dns")
            delete_dns_record "$account_name" "$domain" "$param4" "$param5" "$param6"
            ;;
        "nameservers")
            get_nameservers "$account_name" "$domain"
            ;;
        "update-ns")
            shift 3
            update_nameservers "$account_name" "$domain" "$@"
            ;;
        "check-availability")
            check_domain_availability "$account_name" "$domain"
            ;;
        "purchase")
            purchase_domain "$account_name" "$domain" "$param4" "$param5"
            ;;
        "operation-status")
            get_operation_status "$account_name" "$domain"
            ;;
        "bulk-check")
            shift 2
            bulk_check_domains "$account_name" "$@"
            ;;
        "contacts")
            get_domain_contacts "$account_name" "$domain"
            ;;
        "lock")
            toggle_domain_lock "$account_name" "$domain" "lock"
            ;;
        "unlock")
            toggle_domain_lock "$account_name" "$domain" "unlock"
            ;;
        "transfer-status")
            get_transfer_status "$account_name" "$domain"
            ;;
        "audit")
            audit_domain "$account_name" "$domain"
            ;;
        "monitor-expiration")
            monitor_expiration "$account_name" "$domain"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
