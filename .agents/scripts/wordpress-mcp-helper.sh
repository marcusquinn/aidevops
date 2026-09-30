#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
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

# Validate the site URL, username and secret name used by remote HTTP commands.
# Rejects quotes and shell metacharacters so generated commands stay literal.
validate_remote_args() {
    local api_url="$1"
    local username="$2"
    local secret_name="$3"

    if [[ ! "$api_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
        print_error "Invalid site URL (expected https://example.com): $api_url"
        return 1
    fi
    if [[ ! "$username" =~ ^[A-Za-z0-9\ ._@-]+$ ]]; then
        print_error "Invalid WordPress username: $username"
        return 1
    fi
    if [[ ! "$secret_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        print_error "Invalid secret name (use letters, digits, underscore): $secret_name"
        return 1
    fi
    return 0
}

# Resolve a secret by name without echoing it to the terminal.
# Order: environment (including credentials.sh), then `aidevops secret get`.
resolve_secret_value() {
    local secret_name="$1"
    local value="${!secret_name:-}"

    if [[ -z "$value" ]] && command -v aidevops &> /dev/null; then
        # stdin is detached: under serve-http it carries the MCP JSON-RPC stream.
        value=$(aidevops secret get "$secret_name" < /dev/null 2> /dev/null) || value=""
    fi
    if [[ -z "$value" ]]; then
        print_error "Secret not found: $secret_name"
        print_info "Store it in your terminal: aidevops secret set $secret_name"
        return 1
    fi
    printf '%s' "$value"
    return 0
}

# Run @automattic/mcp-wordpress-remote over STDIO for an MCP client.
# Keeps stdout clean for JSON-RPC; the password only exists in the child env.
serve_http() {
    local api_url="$1"
    local username="$2"
    local secret_name="$3"
    local server="${4:-mcp-adapter-default-server}"

    validate_remote_args "$api_url" "$username" "$secret_name" || return 1
    if ! command -v npx &> /dev/null; then
        print_error "npx not found. Install Node.js 18+ first."
        return 1
    fi

    local password
    password=$(resolve_secret_value "$secret_name") || return 1

    export WP_API_URL="${api_url%/}/wp-json/mcp/${server}"
    export WP_API_USERNAME="$username"
    export WP_API_PASSWORD="$password"
    export OAUTH_ENABLED="false"
    exec npx -y @automattic/mcp-wordpress-remote@latest
}

# Generate Rank Math MCP runtime config that launches serve_http.
# No secret values are written; only the secret name is referenced.
generate_rankmath_config() {
    local site_name="$1"
    local api_url="$2"
    local username="$3"
    local secret_name="$4"
    local format="${5:-opencode}"

    if [[ ! "$site_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        print_error "Site name must be lowercase letters, digits and hyphens: $site_name"
        return 1
    fi
    validate_remote_args "$api_url" "$username" "$secret_name" || return 1

    local helper="${HOME}/.aidevops/agents/scripts/wordpress-mcp-helper.sh"
    local server_name="rankmath-${site_name}"
    local args_json
    args_json=$(jq -cn --arg u "${api_url%/}" --arg n "$username" --arg s "$secret_name" \
        '["serve-http", $u, $n, $s]') || return 1

    case "$format" in
        "opencode")
            jq -n --arg name "$server_name" --arg h "$helper" --argjson a "$args_json" \
                '{mcp: {($name): {type: "local", command: ([$h] + $a), enabled: false}}}'
            ;;
        "claude")
            local entry
            entry=$(jq -cn --arg h "$helper" --argjson a "$args_json" \
                '{type: "stdio", command: $h, args: $a}') || return 1
            printf "claude mcp add-json %s '%s' --scope user\n" "$server_name" "$entry"
            ;;
        "json")
            jq -n --arg name "$server_name" --arg h "$helper" --argjson a "$args_json" \
                '{mcpServers: {($name): {command: $h, args: $a}}}'
            ;;
        *)
            print_error "Unknown format: $format (use opencode, claude or json)"
            return 1
            ;;
    esac
    return 0
}

# POST one JSON-RPC message to a WordPress MCP endpoint.
# Credentials are passed through a curl config on stdin, not argv.
mcp_http_post() {
    local endpoint="$1"
    local credentials="$2"
    local payload="$3"
    local header_file="$4"
    local body_file="$5"
    local session_id="${6:-}"

    local -a extra_headers=()
    if [[ -n "$session_id" ]]; then
        extra_headers=(-H "Mcp-Session-Id: $session_id")
    fi
    printf '%s\n' "$credentials" | curl -sS -K - -o "$body_file" -D "$header_file" \
        -w '%{http_code}' -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        ${extra_headers[@]+"${extra_headers[@]}"} --data "$payload" "$endpoint"
    return $?
}

# Verify a site exposes rank-math/* abilities through the MCP Adapter.
rankmath_check() {
    local api_url="$1"
    local username="$2"
    local secret_name="$3"
    local server="${4:-mcp-adapter-default-server}"

    validate_remote_args "$api_url" "$username" "$secret_name" || return 1
    if ! command -v curl &> /dev/null; then
        print_error "$ERROR_CURL_REQUIRED"
        return 1
    fi

    local password
    password=$(resolve_secret_value "$secret_name") || return 1
    local escaped="${username}:${password}"
    escaped="${escaped//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    local credentials="user = \"${escaped}\""

    local endpoint="${api_url%/}/wp-json/mcp/${server}"
    local work_dir
    work_dir=$(mktemp -d) || return 1
    local rc=0
    _rankmath_check_session "$endpoint" "$credentials" "$work_dir" || rc=1
    rm -rf "$work_dir"
    return "$rc"
}

# Run initialize + discover-abilities and report rank-math/* abilities.
_rankmath_check_session() {
    local endpoint="$1"
    local credentials="$2"
    local work_dir="$3"
    local init_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"aidevops-rankmath-check","version":"1.0.0"}}}'
    local discover_payload='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mcp-adapter-discover-abilities","arguments":{}}}'

    print_info "Checking Rank Math MCP abilities at $endpoint"
    local status
    status=$(mcp_http_post "$endpoint" "$credentials" "$init_payload" "$work_dir/h1" "$work_dir/b1") || status="000"
    if [[ "$status" != "200" ]]; then
        print_error "initialize failed (HTTP $status). Check URL, user, Application Password and /wp-json/mcp/ access."
        return 1
    fi

    local session_id
    session_id=$(awk 'tolower($1) == "mcp-session-id:" {gsub(/\r/, "", $2); print $2}' "$work_dir/h1")
    if [[ -z "$session_id" ]]; then
        print_error "No Mcp-Session-Id header returned; the endpoint may not be an MCP Adapter server."
        return 1
    fi
    mcp_http_post "$endpoint" "$credentials" '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        "$work_dir/h2" "$work_dir/b2" "$session_id" > /dev/null || true

    status=$(mcp_http_post "$endpoint" "$credentials" "$discover_payload" "$work_dir/h3" "$work_dir/b3" "$session_id") || status="000"
    if [[ "$status" != "200" ]]; then
        print_error "discover-abilities failed (HTTP $status)"
        return 1
    fi

    local abilities
    abilities=$(jq -r '(.result.structuredContent // (.result.content[0].text | fromjson? // {})) | .abilities[]?.name | select(startswith("rank-math/"))' "$work_dir/b3" 2> /dev/null)
    if [[ -z "$abilities" ]]; then
        print_error "No rank-math/* abilities exposed. Update Rank Math and confirm the user can manage it."
        return 1
    fi
    print_success "Rank Math abilities available: $(printf '%s\n' "$abilities" | wc -l | tr -d ' ')"
    printf '%s\n' "$abilities" | sed 's/^/  - /'
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

  serve-http <url> <user> <secret-name> [server]
                                  Run mcp-wordpress-remote over STDIO, resolving
                                  the Application Password at launch (for MCP clients)

Rank Math SEO (rank-math/* abilities, see tools/wordpress/rankmath-mcp.md):
  rankmath-check <url> <user> <secret-name>
                                  Verify the site exposes rank-math/* abilities
  rankmath-config <site> <url> <user> <secret-name> [opencode|claude|json]
                                  Generate MCP config (no secret values written)

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

  # Rank Math: store the Application Password, verify, then generate config
  aidevops secret set RANKMATH_EXAMPLE_WP_APP_PASSWORD
  ./wordpress-mcp-helper.sh rankmath-check https://example.com aidevops-bot RANKMATH_EXAMPLE_WP_APP_PASSWORD
  ./wordpress-mcp-helper.sh rankmath-config example https://example.com aidevops-bot RANKMATH_EXAMPLE_WP_APP_PASSWORD opencode

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
    local arg1="${2:-}"
    local arg2="${3:-}"
    local arg3="${4:-}"
    local arg4="${5:-}"
    local arg5="${6:-}"
    
    check_dependencies || exit 1
    load_mcp_env
    case "$command" in
        "serve-http"|"rankmath-check"|"rankmath-config"|"help"|"-h"|"--help") ;;
        *) load_config || true ;;
    esac
    
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
        "serve-http")
            serve_http "$arg1" "$arg2" "$arg3" "${arg4:-mcp-adapter-default-server}" || exit 1
            ;;
        "rankmath-check")
            rankmath_check "$arg1" "$arg2" "$arg3" || exit 1
            ;;
        "rankmath-config")
            generate_rankmath_config "$arg1" "$arg2" "$arg3" "$arg4" "${arg5:-opencode}" || exit 1
            ;;
        "help"|"-h"|"--help"|*)
            show_help
            ;;
    esac
    
    return 0
}

# Run main function
main "$@"
