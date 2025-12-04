#!/usr/bin/env bash
#
# MCP Inspector Helper Script
# Test and debug MCP servers using @modelcontextprotocol/inspector
#
# Usage: ./mcp-inspector-helper.sh [command] [options]
#
# Commands:
#   ui [server]           Launch web UI for interactive testing
#   list-tools [server]   List available tools from a server
#   call-tool [server]    Call a specific tool
#   list-resources        List available resources
#   health                Check health of all configured servers
#   config                Show current MCP configuration
#   help                  Show this help message

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_FILE="${SCRIPT_DIR}/../../.opencode/server/mcp-test-config.json"

print_info() { 
    local msg="$1"
    echo -e "${BLUE}ℹ️  ${msg}${NC}"
    return 0
}

print_success() { 
    local msg="$1"
    echo -e "${GREEN}✅ ${msg}${NC}"
    return 0
}

print_warning() { 
    local msg="$1"
    echo -e "${YELLOW}⚠️  ${msg}${NC}"
    return 0
}

print_error() { 
    local msg="$1"
    echo -e "${RED}❌ ${msg}${NC}"
    return 0
}

print_header() { 
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    return 0
}

# Check if MCP Inspector is available
check_inspector() {
    if ! command -v npx &> /dev/null; then
        print_error "npx not found. Please install Node.js first."
        return 1
    fi
    return 0
}

# Launch MCP Inspector Web UI
launch_ui() {
    local server="${1:-}"
    
    print_header
    echo -e "${CYAN}🔍 MCP Inspector - Web UI${NC}"
    print_header
    
    if [[ -n "$server" ]]; then
        print_info "Launching inspector for server: $server"
        npx @modelcontextprotocol/inspector --config "$CONFIG_FILE" --server "$server"
    else
        print_info "Launching inspector with config file..."
        print_info "Config: $CONFIG_FILE"
        echo ""
        print_info "Available servers:"
        jq -r '.mcpServers | keys[]' "$CONFIG_FILE" 2>/dev/null || echo "  (config file not found)"
        echo ""
        npx @modelcontextprotocol/inspector --config "$CONFIG_FILE"
    fi
    return 0
}

# List tools from a server
list_tools() {
    local server="${1:-}"
    
    print_header
    echo -e "${CYAN}🔧 MCP Inspector - List Tools${NC}"
    print_header
    
    if [[ -z "$server" ]]; then
        print_info "Listing tools from all configured servers..."
        echo ""
        
        local srv
        while IFS= read -r srv; do
            echo -e "${BLUE}Server: ${srv}${NC}"
            npx @modelcontextprotocol/inspector --cli --config "$CONFIG_FILE" --server "$srv" --method tools/list 2>/dev/null || print_warning "Failed to connect to $srv"
            echo ""
        done < <(jq -r '.mcpServers | keys[]' "$CONFIG_FILE" 2>/dev/null)
    else
        print_info "Listing tools from server: $server"
        npx @modelcontextprotocol/inspector --cli --config "$CONFIG_FILE" --server "$server" --method tools/list
    fi
    return 0
}

# Call a tool
call_tool() {
    local server="${1:-}"
    local tool_name="${2:-}"
    shift 2 || true
    local -a tool_args=("$@")
    
    if [[ -z "$server" || -z "$tool_name" ]]; then
        print_error "Usage: call-tool <server> <tool-name> [--tool-arg key=value ...]"
        return 1
    fi
    
    print_header
    echo -e "${CYAN}🎯 MCP Inspector - Call Tool${NC}"
    print_header
    print_info "Server: $server"
    print_info "Tool: $tool_name"
    
    # Build args array safely
    local -a cmd_args=("--cli" "--config" "$CONFIG_FILE" "--server" "$server" "--method" "tools/call" "--tool-name" "$tool_name")
    
    local arg
    for arg in "${tool_args[@]}"; do
        cmd_args+=("--tool-arg" "$arg")
    done
    
    npx @modelcontextprotocol/inspector "${cmd_args[@]}"
    return 0
}

# List resources
list_resources() {
    local server="${1:-}"
    
    print_header
    echo -e "${CYAN}📚 MCP Inspector - List Resources${NC}"
    print_header
    
    if [[ -z "$server" ]]; then
        print_info "Listing resources from all configured servers..."
        echo ""
        
        local srv
        while IFS= read -r srv; do
            echo -e "${BLUE}Server: ${srv}${NC}"
            npx @modelcontextprotocol/inspector --cli --config "$CONFIG_FILE" --server "$srv" --method resources/list 2>/dev/null || print_warning "No resources or failed to connect"
            echo ""
        done < <(jq -r '.mcpServers | keys[]' "$CONFIG_FILE" 2>/dev/null)
    else
        print_info "Listing resources from server: $server"
        npx @modelcontextprotocol/inspector --cli --config "$CONFIG_FILE" --server "$server" --method resources/list
    fi
    return 0
}

# Health check all servers
health_check() {
    print_header
    echo -e "${CYAN}🏥 MCP Server Health Check${NC}"
    print_header
    
    local total=0
    local healthy=0
    local failed=0
    
    # Check local Elysia servers first
    echo -e "\n${BLUE}Local Elysia Servers:${NC}"
    
    local port
    for port in 3100 3101; do
        total=$((total + 1))
        local name="localhost:$port"
        local response
        if response=$(curl -s "http://localhost:$port/health" 2>/dev/null); then
            local status
            status=$(echo "$response" | jq -r '.status // "ok"' 2>/dev/null || echo "healthy")
            print_success "$name - $status"
            healthy=$((healthy + 1))
        else
            print_error "$name - not running"
            failed=$((failed + 1))
        fi
    done
    
    # Check MCP servers from config
    echo -e "\n${BLUE}MCP Servers (from config):${NC}"
    
    local srv
    while IFS= read -r srv; do
        total=$((total + 1))
        local server_type
        server_type=$(jq -r ".mcpServers[\"$srv\"].type" "$CONFIG_FILE")
        
        if [[ "$server_type" == "streamable-http" || "$server_type" == "sse" ]]; then
            local url
            url=$(jq -r ".mcpServers[\"$srv\"].url" "$CONFIG_FILE")
            if curl -s "$url/health" > /dev/null 2>&1; then
                print_success "$srv ($server_type) - healthy"
                healthy=$((healthy + 1))
            else
                print_warning "$srv ($server_type) - not reachable"
                failed=$((failed + 1))
            fi
        else
            # For stdio servers, just note they need manual testing
            print_warning "$srv ($server_type) - stdio (use 'ui' to test)"
        fi
    done < <(jq -r '.mcpServers | keys[]' "$CONFIG_FILE" 2>/dev/null)
    
    echo ""
    print_header
    echo -e "Summary: ${GREEN}$healthy healthy${NC} / ${RED}$failed failed${NC} / $total total"
    return 0
}

# Show configuration
show_config() {
    print_header
    echo -e "${CYAN}⚙️  MCP Configuration${NC}"
    print_header
    
    if [[ -f "$CONFIG_FILE" ]]; then
        print_info "Config file: $CONFIG_FILE"
        echo ""
        jq '.' "$CONFIG_FILE"
    else
        print_error "Config file not found: $CONFIG_FILE"
        return 1
    fi
    return 0
}

# Test API Gateway endpoints
test_api_gateway() {
    print_header
    echo -e "${CYAN}🧪 API Gateway Test Suite${NC}"
    print_header
    
    local base_url="http://localhost:3100"
    local passed=0
    local failed=0
    
    # Test health endpoint
    echo -e "\n${BLUE}Testing endpoints:${NC}"
    
    local response
    
    # Health check
    if response=$(curl -s "$base_url/health" 2>/dev/null); then
        print_success "GET /health"
        echo "  Response: $response"
        passed=$((passed + 1))
    else
        print_error "GET /health - failed"
        failed=$((failed + 1))
    fi
    
    # Quality summary
    if response=$(curl -s "$base_url/api/quality/summary" 2>/dev/null); then
        print_success "GET /api/quality/summary"
        local issues
        local gate
        issues=$(echo "$response" | jq -r '.summary.totalIssues // "N/A"' 2>/dev/null || echo "N/A")
        gate=$(echo "$response" | jq -r '.summary.qualityGate // "N/A"' 2>/dev/null || echo "N/A")
        echo "  Issues: $issues"
        echo "  Quality Gate: $gate"
        passed=$((passed + 1))
    else
        print_error "GET /api/quality/summary - failed"
        failed=$((failed + 1))
    fi
    
    # SonarCloud status
    if curl -s "$base_url/api/sonarcloud/status" > /dev/null 2>&1; then
        print_success "GET /api/sonarcloud/status"
        passed=$((passed + 1))
    else
        print_error "GET /api/sonarcloud/status - failed"
        failed=$((failed + 1))
    fi
    
    # Cache stats
    if response=$(curl -s "$base_url/api/cache/stats" 2>/dev/null); then
        print_success "GET /api/cache/stats"
        local size
        size=$(echo "$response" | jq -r '.size // 0' 2>/dev/null || echo "0")
        echo "  Cache size: $size"
        passed=$((passed + 1))
    else
        print_error "GET /api/cache/stats - failed"
        failed=$((failed + 1))
    fi
    
    # Crawl4AI health
    if response=$(curl -s "$base_url/api/crawl4ai/health" 2>/dev/null); then
        local status
        status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        if [[ "$status" == "healthy" ]]; then
            print_success "GET /api/crawl4ai/health - $status"
        else
            print_warning "GET /api/crawl4ai/health - $status (Crawl4AI may not be running)"
        fi
        passed=$((passed + 1))
    else
        print_error "GET /api/crawl4ai/health - failed"
        failed=$((failed + 1))
    fi
    
    echo ""
    print_header
    echo -e "Results: ${GREEN}$passed passed${NC} / ${RED}$failed failed${NC}"
    return 0
}

# Show help
show_help() {
    cat << 'HELP'
MCP Inspector Helper Script
━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage: ./mcp-inspector-helper.sh [command] [options]

Commands:
  ui [server]              Launch web UI for interactive testing
                           Opens browser at http://localhost:6274
  
  list-tools [server]      List available tools from server(s)
                           If no server specified, lists from all
  
  call-tool <server> <tool> [args...]
                           Call a specific tool with arguments
                           Example: call-tool context7 resolve-library-id libraryName=react
  
  list-resources [server]  List available resources from server(s)
  
  health                   Check health of all configured servers
  
  test-gateway             Run API Gateway test suite
  
  config                   Show current MCP configuration
  
  help                     Show this help message

Examples:
  # Launch web UI for all servers
  ./mcp-inspector-helper.sh ui
  
  # Launch web UI for specific server
  ./mcp-inspector-helper.sh ui context7
  
  # List tools from Context7 server
  ./mcp-inspector-helper.sh list-tools context7
  
  # Call a tool
  ./mcp-inspector-helper.sh call-tool context7 resolve-library-id libraryName=bun
  
  # Health check all servers
  ./mcp-inspector-helper.sh health
  
  # Test API Gateway
  ./mcp-inspector-helper.sh test-gateway

Configuration:
  Config file: .opencode/server/mcp-test-config.json
  
  Servers defined:
    - api-gateway      (HTTP)  - AI DevOps API Gateway
    - mcp-dashboard    (HTTP)  - MCP Dashboard with WebSocket
    - crawl4ai         (stdio) - Web crawling
    - context7         (stdio) - Library documentation
    - repomix          (stdio) - Repository packaging
    - filesystem       (stdio) - File system access
    - memory           (stdio) - Persistent memory
    - github           (stdio) - GitHub API

Starting Local Servers:
  # Start API Gateway (port 3100)
  bun run .opencode/server/api-gateway.ts
  
  # Start MCP Dashboard (port 3101)
  bun run .opencode/server/mcp-dashboard.ts
  
  # Or use npm scripts
  bun run dev        # API Gateway
  bun run dashboard  # MCP Dashboard

HELP
    return 0
}

# Main
main() {
    check_inspector || exit 1
    
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        ui|web)
            launch_ui "$@"
            ;;
        list-tools|tools)
            list_tools "$@"
            ;;
        call-tool|call)
            call_tool "$@"
            ;;
        list-resources|resources)
            list_resources "$@"
            ;;
        health|status)
            health_check
            ;;
        test-gateway|test)
            test_api_gateway
            ;;
        config|show-config)
            show_config
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo "Run './mcp-inspector-helper.sh help' for usage"
            return 1
            ;;
    esac
    return 0
}

main "$@"
