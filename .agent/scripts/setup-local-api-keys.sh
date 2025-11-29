#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Setup Local API Keys - Secure User-Private Storage
# Manage API keys in ~/.config/aidevops/mcp-env.sh (sourced by shell configs)
#
# Author: AI DevOps Framework
# Version: 2.1.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Common constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
print_success() {
    local _arg1="$1"
    echo -e "${GREEN}[OK] $_arg1${NC}"
    return 0
}

print_info() {
    local _arg1="$1"
    echo -e "${BLUE}[INFO] $_arg1${NC}"
    return 0
}

print_warning() {
    local _arg1="$1"
    echo -e "${YELLOW}[WARN] $_arg1${NC}"
    return 0
}

print_error() {
    local _arg1="$1"
    echo -e "${RED}[ERROR] $_arg1${NC}" >&2
    return 0
}

# Secure API key directory and file
readonly API_KEY_DIR="$HOME/.config/aidevops"
readonly MCP_ENV_FILE="$API_KEY_DIR/mcp-env.sh"

# Shell config files to check/update
SHELL_CONFIGS=(
    "$HOME/.zshrc"
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
)

# Create secure API key directory
setup_secure_directory() {
    if [[ ! -d "$API_KEY_DIR" ]]; then
        mkdir -p "$API_KEY_DIR"
        chmod 700 "$API_KEY_DIR"
        print_success "Created secure API key directory: $API_KEY_DIR"
    fi
    
    # Ensure proper permissions
    chmod 700 "$API_KEY_DIR"
    
    # Create mcp-env.sh if it doesn't exist
    if [[ ! -f "$MCP_ENV_FILE" ]]; then
        cat > "$MCP_ENV_FILE" << 'EOF'
#!/bin/bash
# ------------------------------------------------------------------------------
# API Keys & Tokens - Single Source of Truth
# This file is sourced by shell configs (zsh, bash) for all processes
# File permissions should be 600 (owner read/write only)
# Location: ~/.config/aidevops/mcp-env.sh
#
# Usage: Add keys with setup-local-api-keys.sh or manually:
#   export SERVICE_NAME_API_KEY="your-key-here"
# ------------------------------------------------------------------------------

EOF
        chmod 600 "$MCP_ENV_FILE"
        print_success "Created mcp-env.sh"
    fi
    
    return 0
}

# Ensure shell configs source mcp-env.sh
setup_shell_integration() {
    local source_line='[[ -f ~/.config/aidevops/mcp-env.sh ]] && source ~/.config/aidevops/mcp-env.sh'
    local updated=0
    
    for config in "${SHELL_CONFIGS[@]}"; do
        if [[ -f "$config" ]] && ! grep -q "mcp-env.sh" "$config" 2>/dev/null; then
            echo "" >> "$config"
            echo "# AI DevOps API Keys (single source of truth)" >> "$config"
            echo "$source_line" >> "$config"
            print_success "Added mcp-env.sh sourcing to $config"
            ((updated++))
        fi
    done
    
    if [[ $updated -eq 0 ]]; then
        print_info "Shell configs already configured"
    fi
    
    return 0
}

# Convert service name to env var name (e.g., "updown-api-key" -> "UPDOWN_API_KEY")
service_to_env_var() {
    local service="$1"
    echo "$service" | tr '[:lower:]-' '[:upper:]_'
    return 0
}

# Parse export command (e.g., 'export VERCEL_TOKEN="xxx"' -> extracts var name and value)
parse_export_command() {
    local input="$1"
    
    # Remove 'export ' prefix if present
    input="${input#export }"
    
    # Extract var name and value
    local var_name="${input%%=*}"
    local value="${input#*=}"
    
    # Remove quotes from value
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    
    echo "$var_name"
    echo "$value"
    return 0
}

# Set API key securely
set_api_key() {
    local service="$1"
    local key="$2"
    
    if [[ -z "$service" ]]; then
        print_warning "Usage: $0 set <service> <api_key>"
        print_info "Or paste an export command: $0 add 'export TOKEN=\"xxx\"'"
        return 1
    fi
    
    # If only one argument and it looks like an export command
    if [[ -z "$key" && "$service" == export* ]]; then
        local parsed
        parsed=$(parse_export_command "$service")
        service=$(echo "$parsed" | head -1)
        key=$(echo "$parsed" | tail -1)
        print_info "Parsed export command: $service"
    fi
    
    if [[ -z "$key" ]]; then
        print_warning "Usage: $0 set <service> <api_key>"
        return 1
    fi
    
    setup_secure_directory
    
    local env_var
    # If service is already UPPER_CASE, use it directly
    if [[ "$service" =~ ^[A-Z_]+$ ]]; then
        env_var="$service"
    else
        env_var=$(service_to_env_var "$service")
    fi
    
    # Check if the env var already exists in the file
    if grep -q "^export ${env_var}=" "$MCP_ENV_FILE" 2>/dev/null; then
        # Update existing entry
        local tmp_file="${MCP_ENV_FILE}.tmp"
        sed "s|^export ${env_var}=.*|export ${env_var}=\"${key}\"|" "$MCP_ENV_FILE" > "$tmp_file"
        mv "$tmp_file" "$MCP_ENV_FILE"
        chmod 600 "$MCP_ENV_FILE"
        print_success "Updated $env_var in mcp-env.sh"
    else
        # Append new entry
        echo "export ${env_var}=\"${key}\"" >> "$MCP_ENV_FILE"
        chmod 600 "$MCP_ENV_FILE"
        print_success "Added $env_var to mcp-env.sh"
    fi
    
    # Also export to current shell
    export "${env_var}=${key}"
    print_info "Exported to current shell. Run 'source ~/.zshrc' (or ~/.bashrc) for other terminals."
    
    return 0
}

# Add command - alias for set, better for pasting export commands
add_api_key() {
    set_api_key "$@"
    return 0
}

# Get API key
get_api_key() {
    local service="$1"
    
    if [[ -z "$service" ]]; then
        print_warning "Usage: $0 get <service>"
        return 1
    fi
    
    if [[ ! -f "$MCP_ENV_FILE" ]]; then
        print_warning "No API keys configured. Run '$0 setup' first."
        return 1
    fi
    
    local env_var
    # If service is already UPPER_CASE, use it directly
    if [[ "$service" =~ ^[A-Z_]+$ ]]; then
        env_var="$service"
    else
        env_var=$(service_to_env_var "$service")
    fi
    
    # First check environment (already loaded)
    local key="${!env_var}"
    
    # If not in env, try to extract from file
    if [[ -z "$key" ]]; then
        key=$(grep "^export ${env_var}=" "$MCP_ENV_FILE" 2>/dev/null | sed 's/^export [^=]*="//' | sed 's/"$//')
    fi
    
    if [[ -n "$key" ]]; then
        echo "$key"
        return 0
    else
        print_warning "API key for $service ($env_var) not found"
        return 1
    fi
    return 0
}

# List configured services (without showing keys)
list_services() {
    if [[ ! -f "$MCP_ENV_FILE" ]]; then
        print_info "No API keys configured"
        return 0
    fi
    
    print_info "Configured API keys in mcp-env.sh:"
    echo ""
    grep "^export " "$MCP_ENV_FILE" | sed 's/=.*//' | sed 's/export /  /' | sort
    echo ""
    print_info "File: $MCP_ENV_FILE"
    
    return 0
}

# Show help
show_help() {
    print_info "AI DevOps - Secure Local API Key Management"
    echo ""
    print_info "Manages API keys in: $MCP_ENV_FILE"
    print_info "This file is sourced by shell configs (zsh & bash) for all processes."
    echo ""
    print_info "Usage: $0 <command> [args]"
    echo ""
    print_info "Commands:"
    echo "  setup                  - Initialize storage and shell integration"
    echo "  set <service> <key>    - Store API key for service"
    echo "  add 'export X=\"y\"'   - Parse and store from export command"
    echo "  get <service>          - Retrieve API key for service"
    echo "  list                   - List configured services"
    echo ""
    print_info "Examples:"
    echo "  $0 setup"
    echo "  $0 set vercel-token YOUR_TOKEN"
    echo "  $0 add 'export VERCEL_TOKEN=\"abc123\"'    # Paste from service"
    echo "  $0 set SUPABASE_KEY abc123                # Direct env var name"
    echo "  $0 get vercel-token"
    echo "  $0 list"
    echo ""
    print_info "When a service gives you 'export TOKEN=xxx', use:"
    echo "  $0 add 'export TOKEN=\"xxx\"'"
    echo ""
    print_info "Service names are converted to env vars:"
    echo "  vercel-token    ->  VERCEL_TOKEN"
    echo "  supabase-key    ->  SUPABASE_KEY"
    echo "  DIRECT_NAME     ->  DIRECT_NAME (kept as-is)"
    return 0
}

# Main execution
main() {
    local command="$1"
    shift 2>/dev/null || true
    
    case "$command" in
        "set")
            set_api_key "$@"
            ;;
        "add")
            add_api_key "$@"
            ;;
        "get")
            get_api_key "$@"
            ;;
        "list")
            list_services
            ;;
        "setup")
            setup_secure_directory
            setup_shell_integration
            print_success "Secure API key storage ready"
            echo ""
            show_help
            ;;
        "help"|"--help"|"-h"|"")
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            echo ""
            show_help
            return 1
            ;;
    esac
    
    return 0
}

main "$@"
