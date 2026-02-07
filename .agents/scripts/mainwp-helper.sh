#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155

# MainWP WordPress Management Helper Script
# Comprehensive WordPress site management for AI assistants
# Uses MainWP REST API v1 with query parameter authentication

set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# String literal constants
readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly ERROR_JQ_REQUIRED="jq is required but not installed"
readonly INFO_JQ_INSTALL_MACOS="Install with: brew install jq"
readonly INFO_JQ_INSTALL_UBUNTU="Install with: apt-get install jq"
readonly ERROR_CURL_REQUIRED="curl is required but not installed"
readonly ERROR_SITE_ID_REQUIRED="Site ID is required"
readonly ERROR_AT_LEAST_ONE_SITE_ID="At least one site ID is required"
readonly HELP_SHOW_MESSAGE="Show this help"

# Configuration file location (XDG-compliant user config)
CONFIG_FILE="${HOME}/.config/aidevops/mainwp-config.json"
TEMPLATE_FILE="${HOME}/.aidevops/agents/configs/mainwp-config.json.txt"

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

# Check dependencies
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        print_error "$ERROR_CURL_REQUIRED"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "$ERROR_JQ_REQUIRED"
        echo "$INFO_JQ_INSTALL_MACOS"
        echo "$INFO_JQ_INSTALL_UBUNTU"
        exit 1
    fi
    return 0
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND: $CONFIG_FILE"
        print_info "Copy and customize the template:"
        print_info "  mkdir -p ~/.config/aidevops"
        print_info "  cp $TEMPLATE_FILE $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# Get instance configuration
get_instance_config() {
    local instance_name="$1"
    
    if [[ -z "$instance_name" ]]; then
        print_error "Instance name is required"
        list_instances
        exit 1
    fi
    
    load_config
    
    local instance_config
    instance_config=$(jq -r ".instances.\"$instance_name\"" "$CONFIG_FILE")
    if [[ "$instance_config" == "null" ]]; then
        print_error "Instance '$instance_name' not found in configuration"
        list_instances
        exit 1
    fi
    
    echo "$instance_config"
    return 0
}

# Make API request using query parameter authentication (MainWP REST API v1)
api_request() {
    local instance_name="$1"
    local endpoint="$2"
    local method="${3:-GET}"
    local data="${4:-}"
    
    local config
    config=$(get_instance_config "$instance_name")
    local base_url
    base_url=$(echo "$config" | jq -r '.base_url')
    local consumer_key
    consumer_key=$(echo "$config" | jq -r '.consumer_key')
    local consumer_secret
    consumer_secret=$(echo "$config" | jq -r '.consumer_secret')
    
    if [[ "$base_url" == "null" || "$consumer_key" == "null" || "$consumer_secret" == "null" ]]; then
        print_error "Invalid API credentials for instance '$instance_name'"
        exit 1
    fi
    
    # MainWP REST API uses query parameter authentication
    local auth_params="consumer_key=${consumer_key}&consumer_secret=${consumer_secret}"
    local url="${base_url}/wp-json/mainwp/v1/${endpoint}?${auth_params}"
    
    local curl_opts=(-s -H "Content-Type: application/json")
    
    case "$method" in
        GET)
            curl "${curl_opts[@]}" "$url"
            ;;
        POST)
            if [[ -n "$data" ]]; then
                curl "${curl_opts[@]}" -X POST -d "$data" "$url"
            else
                curl "${curl_opts[@]}" -X POST "$url"
            fi
            ;;
        PUT)
            if [[ -n "$data" ]]; then
                curl "${curl_opts[@]}" -X PUT -d "$data" "$url"
            else
                curl "${curl_opts[@]}" -X PUT "$url"
            fi
            ;;
        DELETE)
            curl "${curl_opts[@]}" -X DELETE "$url"
            ;;
        *)
            print_error "Unknown HTTP method: $method"
            return 1
            ;;
    esac
    return 0
}

# List all configured instances
list_instances() {
    load_config
    print_info "Available MainWP instances:"
    jq -r '.instances | keys[]' "$CONFIG_FILE" | while read -r instance; do
        local description
        description=$(jq -r ".instances.\"$instance\".description" "$CONFIG_FILE")
        local base_url
        base_url=$(jq -r ".instances.\"$instance\".base_url" "$CONFIG_FILE")
        echo "  - $instance ($base_url) - $description"
    done
    return 0
}

# List all managed sites
list_sites() {
    local instance_name="$1"

    print_info "Listing sites for MainWP instance: $instance_name"
    local response
    if response=$(api_request "$instance_name" "sites/all-sites"); then
        echo "$response" | jq -r '.[] | "\(.id): \(.name) - \(.url) (Status: \(.status // "unknown"))"'
        return 0
    else
        print_error "Failed to retrieve sites"
        echo "$response"
        return 1
    fi
}

# Get site details
get_site_details() {
    local instance_name="$1"
    local site_id="$2"
    
    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi

    print_info "Getting details for site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site" "POST" "$data"); then
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to get site details"
        echo "$response"
        return 1
    fi
}

# Get site status (sync status)
get_site_status() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi
    
    print_info "Getting status for site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-sync-data" "POST" "$data"); then
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to get site status"
        echo "$response"
        return 1
    fi
}

# List plugins for a site
list_site_plugins() {
    local instance_name="$1"
    local site_id="$2"
    
    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi
    
    print_info "Listing plugins for site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-installed-plugins" "POST" "$data"); then
        echo "$response" | jq -r '.[] | "\(.name) - Version: \(.version // "unknown") (Status: \(.active // "unknown"))"'
        return 0
    else
        print_error "Failed to retrieve plugins"
        echo "$response"
        return 1
    fi
}

# List themes for a site
list_site_themes() {
    local instance_name="$1"
    local site_id="$2"
    
    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi
    
    print_info "Listing themes for site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-installed-themes" "POST" "$data"); then
        echo "$response" | jq -r '.[] | "\(.name) - Version: \(.version // "unknown") (Status: \(.active // "unknown"))"'
        return 0
    else
        print_error "Failed to retrieve themes"
        echo "$response"
        return 1
    fi
}

# Update WordPress core for a site
update_wordpress_core() {
    local instance_name="$1"
    local site_id="$2"
    
    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi
    
    print_info "Updating WordPress core for site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-update-wordpress" "PUT" "$data"); then
        print_success "WordPress core update initiated"
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to update WordPress core"
        echo "$response"
        return 1
    fi
}

# Update all plugins for a site
update_site_plugins() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi

    print_info "Updating all plugins for site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-update-plugins" "PUT" "$data"); then
        print_success "Plugin updates initiated"
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to update plugins"
        echo "$response"
        return 1
    fi
}

# Update specific plugin
update_specific_plugin() {
    local instance_name="$1"
    local site_id="$2"
    local plugin_slug="$3"

    if [[ -z "$site_id" || -z "$plugin_slug" ]]; then
        print_error "Site ID and plugin slug are required"
        exit 1
    fi

    local data
    data=$(jq -n --argjson site_id "$site_id" --arg plugin "$plugin_slug" '{site_id: $site_id, plugin: $plugin}')

    print_info "Updating plugin '$plugin_slug' for site ID: $site_id"
    local response
    if response=$(api_request "$instance_name" "site/site-update-plugins" "PUT" "$data"); then
        print_success "Plugin update initiated"
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to update plugin"
        echo "$response"
        return 1
    fi
}

# Update all themes for a site
update_site_themes() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi

    print_info "Updating all themes for site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-update-themes" "PUT" "$data"); then
        print_success "Theme updates initiated"
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to update themes"
        echo "$response"
        return 1
    fi
}

# Sync site data
sync_site() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi

    print_info "Syncing site data for site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-sync-data" "POST" "$data"); then
        print_success "Site sync initiated"
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to sync site"
        echo "$response"
        return 1
    fi
}

# Reconnect a disconnected site
reconnect_site() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi

    print_info "Reconnecting site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-reconnect" "POST" "$data"); then
        print_success "Site reconnection initiated"
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to reconnect site"
        echo "$response"
        return 1
    fi
}

# Disconnect a site
disconnect_site() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi

    print_warning "Disconnecting site ID: $site_id"
    local data
    data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
    local response
    if response=$(api_request "$instance_name" "site/site-disconnect" "DELETE" "$data"); then
        print_success "Site disconnected"
        echo "$response" | jq '.'
        return 0
    else
        print_error "Failed to disconnect site"
        echo "$response"
        return 1
    fi
}

# Bulk operations on multiple sites
bulk_update_wordpress() {
    local instance_name="$1"
    shift
    local site_ids=("$@")

    if [[ ${#site_ids[@]} -eq 0 ]]; then
        print_error "$ERROR_AT_LEAST_ONE_SITE_ID"
        exit 1
    fi

    print_info "Performing bulk WordPress core updates on ${#site_ids[@]} sites"

    for site_id in "${site_ids[@]}"; do
        print_info "Updating site ID: $site_id"
        update_wordpress_core "$instance_name" "$site_id"
        sleep 2  # Rate limiting
    done
    return 0
}

# Bulk plugin updates
bulk_update_plugins() {
    local instance_name="$1"
    shift
    local site_ids=("$@")

    if [[ ${#site_ids[@]} -eq 0 ]]; then
        print_error "$ERROR_AT_LEAST_ONE_SITE_ID"
        exit 1
    fi

    print_info "Performing bulk plugin updates on ${#site_ids[@]} sites"

    for site_id in "${site_ids[@]}"; do
        print_info "Updating plugins for site ID: $site_id"
        update_site_plugins "$instance_name" "$site_id"
        sleep 2  # Rate limiting
    done
    return 0
}

# Monitor all sites
monitor_all_sites() {
    local instance_name="$1"

    print_info "Monitoring all sites for MainWP instance: $instance_name"
    echo ""

    print_info "=== SITE STATUS OVERVIEW ==="
    local sites_response
    if sites_response=$(api_request "$instance_name" "sites/all-sites"); then
        echo "$sites_response" | jq -r '.[] | "\(.id): \(.name) - \(.url) (Status: \(.status // "unknown"))"'
    else
        print_error "Failed to retrieve sites overview"
        return 1
    fi

    echo ""
    print_info "=== SITES NEEDING UPDATES ==="

    # Check each site for available updates
    echo "$sites_response" | jq -r '.[].id' | while read -r site_id; do
        local data
        data=$(jq -n --argjson site_id "$site_id" '{site_id: $site_id}')
        local site_status
        site_status=$(api_request "$instance_name" "site/site-sync-data" "POST" "$data")
        local wp_updates
        wp_updates=$(echo "$site_status" | jq -r '.wp_upgrades // 0')
        local plugin_updates
        plugin_updates=$(echo "$site_status" | jq -r '.plugin_upgrades | length // 0')
        local theme_updates
        theme_updates=$(echo "$site_status" | jq -r '.theme_upgrades | length // 0')

        local total_updates=$((wp_updates + plugin_updates + theme_updates))
        if [[ "$total_updates" -gt 0 ]]; then
            local site_name
            site_name=$(echo "$sites_response" | jq -r ".[] | select(.id == $site_id) | .name")
            echo "Site ID $site_id ($site_name): WP: $wp_updates, Plugins: $plugin_updates, Themes: $theme_updates"
        fi
    done
    return 0
}

# Audit site security
audit_site_security() {
    local instance_name="$1"
    local site_id="$2"

    if [[ -z "$site_id" ]]; then
        print_error "$ERROR_SITE_ID_REQUIRED"
        exit 1
    fi

    print_info "Security audit for site ID: $site_id"
    echo ""

    print_info "=== SITE DETAILS ==="
    get_site_details "$instance_name" "$site_id"
    echo ""

    print_info "=== PLUGIN STATUS ==="
    list_site_plugins "$instance_name" "$site_id"
    echo ""

    print_info "=== THEME STATUS ==="
    list_site_themes "$instance_name" "$site_id"
    return 0
}

# Show help
show_help() {
    cat << 'EOF'
MainWP WordPress Management Helper Script

Usage: mainwp-helper.sh [command] [instance] [options]

Commands:
  instances                                   - List all configured MainWP instances
  sites [instance]                            - List all managed sites
  site-details [instance] [site_id]           - Get site details
  site-status [instance] [site_id]            - Get site sync status
  plugins [instance] [site_id]                - List site plugins
  themes [instance] [site_id]                 - List site themes
  update-core [instance] [site_id]            - Update WordPress core
  update-plugins [instance] [site_id]         - Update all plugins
  update-plugin [instance] [site_id] [slug]   - Update specific plugin
  update-themes [instance] [site_id]          - Update all themes
  sync [instance] [site_id]                   - Sync site data
  reconnect [instance] [site_id]              - Reconnect a disconnected site
  disconnect [instance] [site_id]             - Disconnect a site
  bulk-update-wp [instance] [site_ids...]     - Bulk WordPress updates
  bulk-update-plugins [instance] [site_ids...] - Bulk plugin updates
  monitor [instance]                          - Monitor all sites
  audit-security [instance] [site_id]         - Comprehensive security audit
  help                                        - Show this help

Examples:
  mainwp-helper.sh instances
  mainwp-helper.sh sites production
  mainwp-helper.sh site-details production 123
  mainwp-helper.sh update-core production 123
  mainwp-helper.sh update-plugins production 123
  mainwp-helper.sh monitor production
  mainwp-helper.sh bulk-update-wp production 123 124 125

Configuration:
  Config file: ~/.config/aidevops/mainwp-config.json
  Template: ~/.aidevops/agents/configs/mainwp-config.json.txt

Setup:
  mkdir -p ~/.config/aidevops
  cp ~/.aidevops/agents/configs/mainwp-config.json.txt ~/.config/aidevops/mainwp-config.json
  # Edit the file with your MainWP credentials

API Authentication:
  MainWP REST API v1 uses query parameter authentication.
  Configure consumer_key and consumer_secret in the config file.
EOF
    return 0
}

# Main script logic
main() {
    local command="${1:-help}"
    local instance_name="${2:-}"
    local site_id="${3:-}"
    local extra_arg="${4:-}"

    check_dependencies

    case "$command" in
        instances)
            list_instances
            ;;
        sites)
            list_sites "$instance_name"
            ;;
        site-details)
            get_site_details "$instance_name" "$site_id"
            ;;
        site-status)
            get_site_status "$instance_name" "$site_id"
            ;;
        plugins)
            list_site_plugins "$instance_name" "$site_id"
            ;;
        themes)
            list_site_themes "$instance_name" "$site_id"
            ;;
        update-core)
            update_wordpress_core "$instance_name" "$site_id"
            ;;
        update-plugins)
            update_site_plugins "$instance_name" "$site_id"
            ;;
        update-plugin)
            update_specific_plugin "$instance_name" "$site_id" "$extra_arg"
            ;;
        update-themes)
            update_site_themes "$instance_name" "$site_id"
            ;;
        sync)
            sync_site "$instance_name" "$site_id"
            ;;
        reconnect)
            reconnect_site "$instance_name" "$site_id"
            ;;
        disconnect)
            disconnect_site "$instance_name" "$site_id"
            ;;
        bulk-update-wp)
            shift 2
            bulk_update_wordpress "$instance_name" "$@"
            ;;
        bulk-update-plugins)
            shift 2
            bulk_update_plugins "$instance_name" "$@"
            ;;
        monitor)
            monitor_all_sites "$instance_name"
            ;;
        audit-security)
            audit_site_security "$instance_name" "$site_id"
            ;;
        help|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
