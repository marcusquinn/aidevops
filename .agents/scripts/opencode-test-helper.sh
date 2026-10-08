#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2155
# =============================================================================
# OpenCode CLI Testing Helper
# =============================================================================
# Quick testing of OpenCode configuration changes without TUI restart.
# Useful for testing new MCPs, agent permissions, and slash commands.
#
# Usage:
#   opencode-test-helper.sh test-mcp <mcp-name> <agent>
#   opencode-test-helper.sh test-agent <agent>
#   opencode-test-helper.sh list-tools <agent>
#   opencode-test-helper.sh serve [port]
#   opencode-test-helper.sh attach <message> [agent] [port]
#   opencode-test-helper.sh run <message> [--agent <agent>]
#   opencode-test-helper.sh tui-capture --session <id> --out <file> [--expect <text>]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

show_help() {
    cat << 'EOF'
OpenCode CLI Testing Helper

Test OpenCode configuration changes without restarting the TUI.

Commands:
  test-mcp <mcp-name> [agent]   Test if MCP is accessible by agent
  test-agent <agent>            Test agent tool permissions
  list-tools [agent]            List tools available to agent
  serve [port]                  Start persistent server (default: 4096)
  attach <message> [agent]      Run against persistent server
  run <message> [--agent name]  Run single command (passthrough to opencode)
  tui-capture --session ID --out FILE [options]
                               Capture TUI text; repeat --expect TEXT to assert
                               Options: --cwd DIR, --data-dir DIR, --seconds 20,
                               --tui-config FILE, --cols 200, --rows 50,
                               --binary opencode (opencode2: best effort)
  
Examples:
  opencode-test-helper.sh test-mcp dataforseo SEO
  opencode-test-helper.sh test-mcp serper SEO
  opencode-test-helper.sh test-agent Plan+
  opencode-test-helper.sh list-tools Build+
  opencode-test-helper.sh serve 4096
  opencode-test-helper.sh attach "quick test" SEO

Workflow for testing new MCPs:
  1. Edit ~/.config/opencode/opencode.json
  2. Run: opencode-test-helper.sh test-mcp <mcp-name> <agent>
  3. If working, restart TUI
  4. If failing, check output and iterate
EOF
    return 0
}

# Check if opencode is installed
check_opencode() {
    if ! command -v opencode &> /dev/null; then
        print_error "OpenCode CLI not found. Install from https://opencode.ai"
        exit 1
    fi
    return 0
}

# Test if MCP is accessible by agent
test_mcp() {
    local mcp_name="$1"
    local agent="${2:-Build+}"
    
    print_info "Testing MCP '$mcp_name' with agent '$agent'..."
    echo ""
    
    local result
    result=$(opencode run "Invoke the '${agent}' subagent. In that subagent, use aidevops_mcp to connect '${mcp_name}', then confirm whether '${mcp_name}_*' tools become available on the following step. Disconnect when finished. If activation or delegation is unavailable, say 'No ${mcp_name} tools available' and include the exact diagnostic." 2>&1) || true
    
    echo "$result"
    echo ""
    
    if echo "$result" | grep -qi "no.*tools\|not available\|error\|failed"; then
        print_warning "MCP '$mcp_name' may not be accessible to agent '$agent'"
        print_info "Check ~/.config/opencode/opencode.json for:"
        print_info "  1. MCP server is defined in 'mcp' section"
        print_info "  2. The '$agent' activation agent has aidevops_mcp and '${mcp_name}_*' permissions"
        return 1
    else
        print_success "MCP '$mcp_name' appears accessible to agent '$agent'"
        return 0
    fi
}

# Test agent permissions
test_agent() {
    local agent="$1"
    
    print_info "Testing agent '$agent' permissions..."
    echo ""
    
    print_info "Testing read access..."
    opencode run "Read the first 3 lines of ~/.aidevops/agents/AGENTS.md and confirm you can read files." --agent "$agent" 2>&1 || true
    echo ""
    
    print_info "Testing write access (should fail for read-only agents like Plan+)..."
    local write_result
    write_result=$(opencode run "Try to create a file at /tmp/opencode-test-$$.txt with content 'test'. Report if you succeeded or were denied." --agent "$agent" 2>&1) || true
    echo "$write_result"
    
    # Cleanup
    rm -f "/tmp/opencode-test-$$.txt" 2>/dev/null || true
    
    echo ""
    if echo "$write_result" | grep -qi "denied\|cannot\|not allowed\|permission"; then
        print_info "Agent '$agent' is read-only (write denied)"
    else
        print_info "Agent '$agent' has write access"
    fi
    
    return 0
}

# List tools available to agent
list_tools() {
    local agent="${1:-Build+}"
    
    print_info "Listing tools for agent '$agent'..."
    echo ""
    
    opencode run "List ALL tools you have access to. Group them by: 1) Built-in tools (read, write, edit, bash, etc.) 2) MCP tools (grouped by MCP name). Be comprehensive and format as a clear list." --agent "$agent" 2>&1 || true
    
    return 0
}

# Start persistent server
start_serve() {
    local port="${1:-4096}"
    
    print_info "Starting OpenCode server on port $port..."
    print_info "Use 'opencode run --attach http://localhost:$port \"message\" --agent AgentName' to test"
    print_info "Or use: $0 attach \"message\" AgentName"
    print_warning "Press Ctrl+C to stop"
    echo ""
    
    opencode serve --port "$port"
    return 0
}

# Run against persistent server
run_attach() {
    local message="$1"
    local agent="${2:-Build+}"
    local port="${3:-4096}"
    
    print_info "Running against server on port $port with agent '$agent'..."
    opencode run --attach "http://localhost:$port" "$message" --agent "$agent"
    return 0
}

# Passthrough to opencode run
run_passthrough() {
    opencode run "$@"
    return 0
}

# Capture an existing session's render without sending interactive input.
tui_capture() {
    local cwd=""
    local data_dir=""
    local resolved_dir=""
    local base_name=""
    local checksum=""
    local args=("$@")
    cwd=$(pwd -P) || return 1
    while [[ $# -gt 0 ]]; do
        local option="$1"
        local value="${2:-}"
        case "$option" in
            --cwd | --data-dir)
                if [[ $# -lt 2 || -z "$value" ]]; then
                    print_error "Missing value for $option"
                    return 1
                fi
                if [[ "$option" == --cwd ]]; then
                    cwd="$value"
                else
                    data_dir="$value"
                fi
                shift 2
                ;;
            --cwd=*)
                cwd=${option#*=}
                shift
                ;;
            --data-dir=*)
                data_dir=${option#*=}
                shift
                ;;
            --session | --out | --seconds | --tui-config | --cols | --rows | --binary | --expect)
                # Skip values so an expectation such as '--cwd' is not parsed
                # as a launcher-directory option. Python validates all flags.
                if [[ $# -lt 2 ]]; then
                    print_error "Missing value for $option"
                    return 1
                fi
                shift 2
                ;;
            *) shift ;;
        esac
    done
    resolved_dir=$(cd "$cwd" && pwd -P) || return 1
    if [[ -z "$data_dir" ]]; then
        # Mirror build_project_session_id/sql_escape_label in the launcher;
        # sourcing that executable helper would invoke its main().
        base_name=$(basename "$resolved_dir")
        base_name=${base_name//[^A-Za-z0-9._-]/-}
        base_name=${base_name#-}
        base_name=${base_name%-}
        checksum=$(printf '%s' "$resolved_dir" | cksum)
        checksum=${checksum%% *}
        data_dir="${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}/opencode-interactive/project-${base_name:-session}-${checksum}"
    fi
    python3 "${SCRIPT_DIR}/opencode-tui-capture.py" --cwd "$resolved_dir" --data-dir "$data_dir" "${args[@]}" || return 1
    return 0
}

# Main
main() {
    local command="${1:-help}"
    # tui-capture validates its selected binary, allowing --binary opencode2.
    case "$command" in
        tui-capture | help | --help | -h) ;;
        *) check_opencode ;;
    esac
    
    case "$command" in
        test-mcp)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 test-mcp <mcp-name> [agent]"; exit 1; }
            test_mcp "$2" "${3:-Build+}"
            ;;
        test-agent)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 test-agent <agent>"; exit 1; }
            test_agent "$2"
            ;;
        list-tools)
            list_tools "${2:-Build+}"
            ;;
        serve)
            start_serve "${2:-4096}"
            ;;
        attach)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 attach <message> [agent] [port]"; exit 1; }
            run_attach "$2" "${3:-Build+}" "${4:-4096}"
            ;;
        run)
            shift
            run_passthrough "$@"
            ;;
        tui-capture)
            shift
            tui_capture "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
    
    return 0
}

main "$@"
