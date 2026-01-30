#!/bin/bash
# shellcheck disable=SC2155

# WordPress CLI Helper Script
# Runs WP-CLI commands on sites configured in wordpress-sites.json
# Supports multiple hosting types: LocalWP, Hostinger, Hetzner, Cloudways, Closte

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
readonly ERROR_SITE_NOT_FOUND="Site not found in configuration"
readonly ERROR_SITE_REQUIRED="Site identifier is required"
readonly ERROR_COMMAND_REQUIRED="WP-CLI command is required"

# Configuration file location
CONFIG_FILE="${HOME}/.config/aidevops/wordpress-sites.json"
TEMPLATE_FILE="${HOME}/.aidevops/agents/configs/wordpress-sites.json.txt"

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
    if ! command -v jq &> /dev/null; then
        print_error "$ERROR_JQ_REQUIRED"
        echo "$INFO_JQ_INSTALL_MACOS"
        echo "$INFO_JQ_INSTALL_UBUNTU"
        exit 1
    fi
    
    if ! command -v ssh &> /dev/null; then
        print_error "ssh is required but not installed"
        exit 1
    fi
    return 0
}

# Check sshpass for password-based SSH (called only when needed)
check_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        print_error "sshpass is required for Hostinger/Closte sites but not installed"
        print_info "Install with: brew install hudochenkov/sshpass/sshpass (macOS)"
        print_info "Install with: apt-get install sshpass (Ubuntu)"
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

# Get site configuration
get_site_config() {
    local site_key="$1"
    
    load_config
    
    local site_config
    site_config=$(jq -r --arg key "$site_key" '.sites[$key]' "$CONFIG_FILE")
    if [[ "$site_config" == "null" ]]; then
        print_error "$ERROR_SITE_NOT_FOUND: $site_key"
        list_sites
        exit 1
    fi
    
    echo "$site_config"
    return 0
}

# List all configured sites
list_sites() {
    load_config
    print_info "Configured WordPress sites:"
    echo ""
    jq -r '.sites | to_entries[] | "\(.key)|\(.value.name)|\(.value.type)|\(.value.url // .value.path)|\(.value.category // "uncategorized")"' "$CONFIG_FILE" | \
    while IFS='|' read -r key name type url category; do
        printf "  %-20s %-25s %-12s %-40s [%s]\n" "$key" "$name" "$type" "$url" "$category"
    done
    return 0
}

# List sites by category
list_sites_by_category() {
    local category="$1"
    
    load_config
    print_info "Sites in category: $category"
    echo ""
    jq -r --arg cat "$category" '.sites | to_entries[] | select(.value.category == $cat) | "\(.key)|\(.value.name)|\(.value.type)|\(.value.url // .value.path)"' "$CONFIG_FILE" | \
    while IFS='|' read -r key name type url; do
        printf "  %-20s %-25s %-12s %s\n" "$key" "$name" "$type" "$url"
    done
    return 0
}

# Build SSH command based on hosting type
build_ssh_command() {
    local site_config="$1"
    local wp_command="$2"
    
    local site_type
    site_type=$(echo "$site_config" | jq -r '.type')
    local ssh_host
    ssh_host=$(echo "$site_config" | jq -r '.ssh_host // empty')
    local ssh_port
    ssh_port=$(echo "$site_config" | jq -r '.ssh_port // 22')
    local ssh_user
    ssh_user=$(echo "$site_config" | jq -r '.ssh_user // empty')
    local wp_path
    wp_path=$(echo "$site_config" | jq -r '.wp_path // empty')
    local local_path
    local_path=$(echo "$site_config" | jq -r '.path // empty')
    local password_file
    password_file=$(echo "$site_config" | jq -r '.password_file // empty')
    
    # Quote wp_command for safe execution
    local quoted_wp_command
    quoted_wp_command=$(printf %q "$wp_command")
    
    case "$site_type" in
        localwp)
            # LocalWP - direct local access
            # Expand ~ safely without eval
            local expanded_path="${local_path/#\~/$HOME}"
            # Quote path for safe execution
            local quoted_local_path
            quoted_local_path=$(printf %q "$expanded_path")
            echo "cd $quoted_local_path && wp $quoted_wp_command"
            ;;
        hostinger|closte)
            # Hostinger/Closte - sshpass with password file
            # Note: sshpass is required due to hosting provider limitations
            # SSH key auth is preferred when available
            check_sshpass
            local expanded_password_file
            if [[ -n "$password_file" ]]; then
                # Expand ~ safely without eval
                expanded_password_file="${password_file/#\~/$HOME}"
            else
                # Default password file locations
                if [[ "$site_type" == "hostinger" ]]; then
                    expanded_password_file="${HOME}/.ssh/hostinger_password"
                else
                    expanded_password_file="${HOME}/.ssh/closte_password"
                fi
            fi
            
            if [[ ! -f "$expanded_password_file" ]]; then
                print_error "Password file not found: $expanded_password_file"
                print_info "Create the password file with your SSH password (chmod 600)"
                exit 1
            fi
            
            # Quote wp_path for safe remote execution
            local quoted_wp_path
            quoted_wp_path=$(printf %q "$wp_path")
            echo "sshpass -f \"$expanded_password_file\" ssh -p $ssh_port $ssh_user@$ssh_host \"cd $quoted_wp_path && wp $quoted_wp_command\""
            ;;
        hetzner|cloudways|cloudron)
            # SSH key-based authentication (preferred)
            # Quote wp_path for safe remote execution
            local quoted_wp_path
            quoted_wp_path=$(printf %q "$wp_path")
            echo "ssh -p $ssh_port $ssh_user@$ssh_host \"cd $quoted_wp_path && wp $quoted_wp_command\""
            ;;
        *)
            print_error "Unknown hosting type: $site_type"
            exit 1
            ;;
    esac
    return 0
}

# Run WP-CLI command on a site
run_wp_command() {
    local site_key="$1"
    shift
    local wp_command="$*"
    
    if [[ -z "$wp_command" ]]; then
        print_error "$ERROR_COMMAND_REQUIRED"
        exit 1
    fi
    
    local site_config
    site_config=$(get_site_config "$site_key")
    
    local site_name
    site_name=$(echo "$site_config" | jq -r '.name')
    local site_type
    site_type=$(echo "$site_config" | jq -r '.type')
    
    print_info "Running on $site_name ($site_type): wp $wp_command"
    
    local ssh_command
    ssh_command=$(build_ssh_command "$site_config" "$wp_command")
    
    # Execute the command
    eval "$ssh_command"
    return $?
}

# Run WP-CLI command on all sites in a category
run_on_category() {
    local category="$1"
    shift
    local wp_command="$*"
    
    if [[ -z "$wp_command" ]]; then
        print_error "$ERROR_COMMAND_REQUIRED"
        exit 1
    fi
    
    load_config
    
    print_info "Running on all sites in category: $category"
    print_info "Command: wp $wp_command"
    echo ""
    
    local site_keys
    site_keys=$(jq -r --arg cat "$category" '.sites | to_entries[] | select(.value.category == $cat) | .key' "$CONFIG_FILE")
    
    if [[ -z "$site_keys" ]]; then
        print_warning "No sites found in category: $category"
        return 0
    fi
    
    local success_count=0
    local fail_count=0
    
    while IFS= read -r site_key; do
        echo "----------------------------------------"
        print_info "Site: $site_key"
        if run_wp_command "$site_key" "$wp_command"; then
            ((++success_count))
        else
            ((++fail_count))
            print_error "Failed on site: $site_key"
        fi
        echo ""
    done <<< "$site_keys"
    
    echo "========================================"
    print_info "Summary: $success_count succeeded, $fail_count failed"
    return 0
}

# Run WP-CLI command on all sites
run_on_all() {
    local wp_command="$*"
    
    if [[ -z "$wp_command" ]]; then
        print_error "$ERROR_COMMAND_REQUIRED"
        exit 1
    fi
    
    load_config
    
    print_info "Running on ALL sites"
    print_info "Command: wp $wp_command"
    echo ""
    
    local site_keys
    site_keys=$(jq -r '.sites | keys[]' "$CONFIG_FILE")
    
    local success_count=0
    local fail_count=0
    
    while IFS= read -r site_key; do
        echo "----------------------------------------"
        print_info "Site: $site_key"
        if run_wp_command "$site_key" "$wp_command"; then
            ((++success_count))
        else
            ((++fail_count))
            print_error "Failed on site: $site_key"
        fi
        echo ""
    done <<< "$site_keys"
    
    echo "========================================"
    print_info "Summary: $success_count succeeded, $fail_count failed"
    return 0
}

# Get site info
get_site_info() {
    local site_key="$1"
    
    local site_config
    site_config=$(get_site_config "$site_key")
    
    print_info "Site: $site_key"
    echo "$site_config" | jq '.'
    return 0
}

# List available categories
list_categories() {
    load_config
    print_info "Available categories:"
    jq -r '.sites[].category // "uncategorized"' "$CONFIG_FILE" | sort -u | while read -r cat; do
        local count
        if [[ "$cat" == "uncategorized" ]]; then
            # Count sites with null/missing category
            count=$(jq -r '[.sites[] | select(.category == null or .category == "")] | length' "$CONFIG_FILE")
        else
            count=$(jq -r --arg c "$cat" '[.sites[] | select(.category == $c)] | length' "$CONFIG_FILE")
        fi
        echo "  - $cat ($count sites)"
    done
    return 0
}

# Show help
show_help() {
    cat << 'EOF'
WordPress CLI Helper Script

Runs WP-CLI commands on sites configured in ~/.config/aidevops/wordpress-sites.json

Usage: wp-helper.sh [command] [options]

Commands:
  --list                              List all configured sites
  --list-category <category>          List sites in a category
  --categories                        List available categories
  --info <site>                       Show site configuration
  --all <wp-cli-command>              Run command on ALL sites
  --category <cat> <wp-cli-command>   Run command on sites in category
  <site> <wp-cli-command>             Run command on specific site
  help                                Show this help

Examples:
  # List all sites
  wp-helper.sh --list

  # List sites by category
  wp-helper.sh --list-category client

  # Show site info
  wp-helper.sh --info production

  # Run WP-CLI on specific site
  wp-helper.sh production plugin list
  wp-helper.sh local-dev core version
  wp-helper.sh staging user list --role=administrator

  # Run on all sites in a category
  wp-helper.sh --category client plugin update --all
  wp-helper.sh --category lead-gen core version

  # Run on ALL sites
  wp-helper.sh --all core version
  wp-helper.sh --all plugin list --status=active

Configuration:
  Config file: ~/.config/aidevops/wordpress-sites.json
  Template: ~/.aidevops/agents/configs/wordpress-sites.json.txt

Setup:
  mkdir -p ~/.config/aidevops
  cp ~/.aidevops/agents/configs/wordpress-sites.json.txt ~/.config/aidevops/wordpress-sites.json
  # Edit the file with your site details

Hosting Types:
  localwp   - Local by Flywheel (direct path access)
  hostinger - Hostinger (sshpass, port 65002)
  closte    - Closte (sshpass)
  hetzner   - Hetzner VPS (SSH key)
  cloudways - Cloudways (SSH key)
  cloudron  - Cloudron (SSH key)

Related:
  mainwp-helper.sh - For MainWP fleet management
  wordpress-mcp-helper.sh - For WordPress MCP adapter
EOF
    return 0
}

# Main script logic
main() {
    local command="${1:-help}"
    
    check_dependencies
    
    case "$command" in
        --list)
            list_sites
            ;;
        --list-category)
            local category="${2:-}"
            if [[ -z "$category" ]]; then
                print_error "Category is required"
                exit 1
            fi
            list_sites_by_category "$category"
            ;;
        --categories)
            list_categories
            ;;
        --info)
            local site="${2:-}"
            if [[ -z "$site" ]]; then
                print_error "$ERROR_SITE_REQUIRED"
                exit 1
            fi
            get_site_info "$site"
            ;;
        --all)
            shift
            run_on_all "$@"
            ;;
        --category)
            local category="${2:-}"
            if [[ -z "$category" ]]; then
                print_error "Category is required"
                exit 1
            fi
            shift 2
            run_on_category "$category" "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            # Assume first arg is site key, rest is WP-CLI command
            local site_key="$1"
            shift
            if [[ $# -eq 0 ]]; then
                print_error "$ERROR_COMMAND_REQUIRED"
                print_info "Usage: wp-helper.sh <site> <wp-cli-command>"
                exit 1
            fi
            run_wp_command "$site_key" "$@"
            ;;
    esac
    return 0
}

main "$@"
