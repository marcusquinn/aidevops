#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153
set -euo pipefail

# WordPress MCP Adapter Helper Script
# Manages WordPress MCP connections for AI assistants
# Supports both STDIO (local/SSH) and HTTP transports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# String literal constants
readonly ERROR_JQ_REQUIRED="jq is required but not installed"
readonly INFO_JQ_INSTALL_MACOS="Install with: brew install jq"
readonly INFO_JQ_INSTALL_UBUNTU="Install with: apt-get install jq"
readonly ERROR_CURL_REQUIRED="curl is required but not installed"
readonly ERROR_SITE_REQUIRED="Site name is required"
readonly ERROR_SITE_NOT_FOUND="Site not found in configuration"

# Configuration paths (XDG-compliant user config)
CONFIG_FILE="${HOME}/.config/aidevops/wordpress-sites-config.json"
TEMPLATE_FILE="${HOME}/.aidevops/agents/configs/wordpress-sites-config.json.txt"
CREDENTIALS_FILE="${HOME}/.config/aidevops/credentials.sh"
LOCAL_SITES_PATH="${HOME}/Local Sites"

# Check dependencies
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        print_error "$ERROR_JQ_REQUIRED"
        echo "$INFO_JQ_INSTALL_MACOS"
        echo "$INFO_JQ_INSTALL_UBUNTU"
        return 1
    fi
    return 0
}

# Load MCP environment variables
load_mcp_env() {
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CREDENTIALS_FILE"
    fi
    return 0
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_warning "$ERROR_CONFIG_NOT_FOUND"
        print_info "Using default configuration for LocalWP sites"
        return 1
    fi
    return 0
}

# Get site configuration
get_site_config() {
    local site_name="$1"
    
    if [[ -z "$site_name" ]]; then
        print_error "$ERROR_SITE_REQUIRED"
        return 1
    fi
    
    if [[ -f "$CONFIG_FILE" ]]; then
        local site_config
        site_config=$(jq -r ".sites.\"$site_name\"" "$CONFIG_FILE" 2>/dev/null)
        if [[ "$site_config" != "null" && -n "$site_config" ]]; then
            echo "$site_config"
            return 0
        fi
    fi
    
    print_error "$ERROR_SITE_NOT_FOUND: $site_name"
    return 1
}

# List all configured sites
list_sites() {
    print_info "Configured WordPress Sites:"
    echo ""
    
    # List from config file if exists
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${CYAN}From configuration:${NC}"
        jq -r '.sites | to_entries[] | "  \(.key): \(.value.type // "unknown") - \(.value.url // "no url")"' "$CONFIG_FILE" 2>/dev/null || echo "  No sites configured"
        echo ""
    fi
    
    # List LocalWP sites
    if [[ -d "$LOCAL_SITES_PATH" ]]; then
        echo -e "${CYAN}LocalWP Sites (auto-detected):${NC}"
        for site_dir in "$LOCAL_SITES_PATH"/*/; do
            if [[ -d "${site_dir}app/public" ]]; then
                local site_name
                site_name=$(basename "$site_dir")
                local wp_path="${site_dir}app/public"
                echo "  $site_name: local - $wp_path"
            fi
        done
        echo ""
    fi
    
    return 0
}

# Get WP-CLI path for a site
get_wp_cli_path() {
    local site_name="$1"
    local site_type="${2:-local}"
    
    case "$site_type" in
        "local"|"localwp")
            # LocalWP site
            local site_path="$LOCAL_SITES_PATH/$site_name/app/public"
            if [[ -d "$site_path" ]]; then
                echo "$site_path"
                return 0
            fi
            ;;
        "wp-env")
            # wp-env managed site
            echo "."
            return 0
            ;;
        *)
            # Remote or custom path
            if [[ -f "$CONFIG_FILE" ]]; then
                local path
                path=$(jq -r ".sites.\"$site_name\".path // empty" "$CONFIG_FILE" 2>/dev/null)
                if [[ -n "$path" ]]; then
                    echo "$path"
                    return 0
                fi
            fi
            ;;
    esac
    
    print_error "Could not determine WP path for site: $site_name"
    return 1
}

# Generate STDIO MCP configuration for a site
generate_stdio_config() {
    local site_name="$1"
    local wp_path="$2"
    local user="${3:-admin}"
    local server="${4:-mcp-adapter-default-server}"
    
    cat << EOF
{
  "mcpServers": {
    "wordpress-$site_name": {
      "command": "wp",
      "args": [
        "--path=$wp_path",
        "mcp-adapter",
        "serve",
        "--server=$server",
        "--user=$user"
      ]
    }
  }
}
EOF
    return 0
}

# Generate HTTP MCP configuration for a site
generate_http_config() {
    local site_name="$1"
    local api_url="$2"
    local username="$3"
    local app_password="$4"
    local server="${5:-mcp-adapter-default-server}"
    
    cat << EOF
{
  "mcpServers": {
    "wordpress-$site_name": {
      "command": "npx",
      "args": [
        "-y",
        "@automattic/mcp-wordpress-remote@latest"
      ],
      "env": {
        "WP_API_URL": "$api_url/wp-json/mcp/$server",
        "LOG_FILE": "$HOME/.agents/tmp/mcp-$site_name.log",
        "WP_API_USERNAME": "$username",
        "WP_API_PASSWORD": "$app_password"
      }
    }
  }
}
EOF
    return 0
}

# Generate SSH MCP configuration for remote site
generate_ssh_config() {
    local site_name="$1"
    local ssh_host="$2"
    local wp_path="$3"
    local user="${4:-admin}"
    local server="${5:-mcp-adapter-default-server}"
    local ssh_user="${6:-}"
    local ssh_password_file="${7:-}"
    
    # Check if sshpass is needed
    local ssh_command="ssh"
    if [[ -n "$ssh_password_file" && -f "$ssh_password_file" ]]; then
        ssh_command="sshpass -f $ssh_password_file ssh"
    fi
    
    if [[ -n "$ssh_user" ]]; then
        ssh_host="${ssh_user}@${ssh_host}"
    fi
    
    cat << EOF
{
  "mcpServers": {
    "wordpress-$site_name": {
      "command": "$ssh_command",
      "args": [
        "$ssh_host",
        "cd $wp_path && wp mcp-adapter serve --server=$server --user=$user" || exit
      ]
    }
  }
}
EOF
    return 0
}

# Test MCP connection (STDIO)
test_stdio_connection() {
    local site_name="$1"
    local wp_path="$2"
    local user="${3:-admin}"
    local server="${4:-mcp-adapter-default-server}"
    
    print_info "Testing STDIO MCP connection for $site_name..."
    
    # Check if WP-CLI is available
    if ! command -v wp &> /dev/null; then
        print_error "WP-CLI not found. Install from: https://wp-cli.org/"
        return 1
    fi
    
    # Check if path exists
    if [[ ! -d "$wp_path" ]]; then
        print_error "WordPress path not found: $wp_path"
        return 1
    fi
    
    # Check if MCP adapter is available
    local adapter_check
    adapter_check=$(wp --path="$wp_path" mcp-adapter list 2>&1)
    
    if echo "$adapter_check" | grep -q "Error\|not found\|is not a registered"; then
        print_warning "MCP Adapter plugin may not be installed/activated"
        print_info "Install with: composer require wordpress/abilities-api wordpress/mcp-adapter"
        return 1
    fi
    
    print_success "MCP Adapter available"
    echo "$adapter_check"
    
    # Test tools list
    print_info "Testing tools/list..."
    local tools_test
    tools_test=$(echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | wp --path="$wp_path" mcp-adapter serve --user="$user" --server="$server" 2>&1)
    
    if echo "$tools_test" | grep -q '"tools"'; then
        print_success "MCP connection successful!"
        echo "$tools_test" | jq -r '.result.tools[] | "  - \(.name): \(.description // "no description")"' 2>/dev/null | head -10
    else
        print_warning "Tools list test returned unexpected response"
        echo "$tools_test" | head -5
    fi
    
    return 0
}

# Test HTTP connection
test_http_connection() {
    local api_url="$1"
    local username="$2"
    local app_password="$3"
    local server="${4:-mcp-adapter-default-server}"
    
    print_info "Testing HTTP MCP connection..."
    
    if ! command -v curl &> /dev/null; then
        print_error "$ERROR_CURL_REQUIRED"
        return 1
    fi
    
    local endpoint="$api_url/wp-json/mcp/$server"
    
    # Test endpoint accessibility
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "$username:$app_password" \
        "$endpoint" 2>&1)
    
    if [[ "$response" == "200" || "$response" == "401" ]]; then
        print_success "Endpoint reachable: $endpoint (HTTP $response)"
    else
        print_error "Endpoint not reachable: $endpoint (HTTP $response)"
        return 1
    fi
    
    return 0
}

# List available MCP servers on a site
list_mcp_servers() {
    local site_name="$1"
    local wp_path="$2"
    
    print_info "Available MCP servers on $site_name:"
    
    if [[ -z "$wp_path" ]]; then
        wp_path=$(get_wp_cli_path "$site_name" "local")
    fi
    
    if [[ -z "$wp_path" || ! -d "$wp_path" ]]; then
        print_error "Could not determine WordPress path"
        return 1
    fi
    
    wp --path="$wp_path" mcp-adapter list 2>&1
    return 0
}

# Discover abilities on a site
discover_abilities() {
    local site_name="$1"
    local wp_path="$2"
    local user="${3:-admin}"
    local server="${4:-mcp-adapter-default-server}"
    
    print_info "Discovering WordPress abilities on $site_name..."
    
    if [[ -z "$wp_path" ]]; then
        wp_path=$(get_wp_cli_path "$site_name" "local")
    fi
    
    if [[ -z "$wp_path" || ! -d "$wp_path" ]]; then
        print_error "Could not determine WordPress path"
        return 1
    fi
    
    local response
    response=$(echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mcp-adapter-discover-abilities","arguments":{}}}' | \
        wp --path="$wp_path" mcp-adapter serve --user="$user" --server="$server" 2>&1)
    
    echo "$response" | jq -r '.result.content[0].text // .result // .' 2>/dev/null || echo "$response"
    return 0
}

# Show help
show_help() {
    cat << 'EOF'
WordPress MCP Adapter Helper Script
====================================

Usage: wordpress-mcp-helper.sh <command> [options]

Commands:
  sites                           List all configured WordPress sites
  servers <site>                  List MCP servers available on a site
  test-stdio <site> [user]        Test STDIO MCP connection
  test-http <url> <user> <pass>   Test HTTP MCP connection
  discover <site> [user]          Discover WordPress abilities via MCP
  
  config-stdio <site> [user]      Generate STDIO MCP config for Claude/OpenCode
  config-http <site> <url> <user> <pass>  Generate HTTP MCP config
  config-ssh <site> <host> <path> [user]  Generate SSH MCP config
  
  help                            Show this help

Site Types:
  local/localwp    LocalWP sites in ~/Local Sites/
  wp-env           Docker-based wp-env development
  remote           Remote sites via SSH or HTTP

Examples:
  # List all sites (LocalWP auto-detected)
  ./wordpress-mcp-helper.sh sites
  
  # Test LocalWP site connection
  ./wordpress-mcp-helper.sh test-stdio mysite
  
  # Generate config for Claude Desktop
  ./wordpress-mcp-helper.sh config-stdio mysite admin
  
  # Test remote site via HTTP
  ./wordpress-mcp-helper.sh test-http https://example.com admin "xxxx xxxx xxxx xxxx"
  
  # Generate SSH config for Hostinger
  ./wordpress-mcp-helper.sh config-ssh mysite ssh.example.com /home/user/public_html

Environment Variables:
  LOCAL_SITES_PATH    Path to LocalWP sites (default: ~/Local Sites)

Configuration:
  Sites config: ~/.config/aidevops/wordpress-sites-config.json
  Template:     ~/.aidevops/agents/configs/wordpress-sites-config.json.txt
  MCP env:      ~/.config/aidevops/credentials.sh

Setup:
  mkdir -p ~/.config/aidevops
  cp ~/.aidevops/agents/configs/wordpress-sites-config.json.txt ~/.config/aidevops/wordpress-sites-config.json
  # Edit the file with your site details

Prerequisites:
  - WP-CLI installed (for STDIO transport)
  - WordPress MCP Adapter plugin installed on target site
  - WordPress Abilities API plugin installed on target site

Installation (on WordPress site):
  composer require wordpress/abilities-api wordpress/mcp-adapter

EOF
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local arg1="$2"
    local arg2="$3"
    local arg3="$4"
    local arg4="$5"
    # arg5 removed - unused
    
    check_dependencies || exit 1
    load_mcp_env
    load_config
    
    case "$command" in
        "sites"|"list")
            list_sites
            ;;
        "servers")
            list_mcp_servers "$arg1" "$arg2"
            ;;
        "test-stdio"|"test")
            local wp_path
            wp_path=$(get_wp_cli_path "$arg1" "local")
            test_stdio_connection "$arg1" "$wp_path" "${arg2:-admin}"
            ;;
        "test-http")
            test_http_connection "$arg1" "$arg2" "$arg3" "${arg4:-mcp-adapter-default-server}"
            ;;
        "discover"|"abilities")
            local wp_path
            wp_path=$(get_wp_cli_path "$arg1" "local")
            discover_abilities "$arg1" "$wp_path" "${arg2:-admin}"
            ;;
        "config-stdio"|"stdio-config")
            local wp_path
            wp_path=$(get_wp_cli_path "$arg1" "local")
            if [[ -n "$wp_path" ]]; then
                generate_stdio_config "$arg1" "$wp_path" "${arg2:-admin}"
            fi
            ;;
        "config-http"|"http-config")
            generate_http_config "$arg1" "$arg2" "$arg3" "$arg4"
            ;;
        "config-ssh"|"ssh-config")
            generate_ssh_config "$arg1" "$arg2" "$arg3" "${arg4:-admin}"
            ;;
        "help"|"-h"|"--help"|*)
            show_help
            ;;
    esac
    
    return 0
}

# Run main function
main "$@"
