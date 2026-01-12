#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Agent Browser Helper - Headless Browser Automation CLI for AI Agents
# Part of AI DevOps Framework
# Provides setup and management of agent-browser CLI

# Source shared constants and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Print functions
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

# Check if agent-browser is installed
check_installed() {
    if command -v agent-browser &> /dev/null; then
        local version
        version=$(agent-browser --version 2>/dev/null || echo "unknown")
        print_success "agent-browser is installed: $version"
        return 0
    else
        print_warning "agent-browser is not installed"
        return 1
    fi
}

# Check if Chromium is installed
check_chromium() {
    if agent-browser install --check 2>/dev/null; then
        print_success "Chromium browser is installed"
        return 0
    else
        print_warning "Chromium browser not found"
        return 1
    fi
}

# Install agent-browser globally
install_agent_browser() {
    print_info "Installing agent-browser CLI..."
    
    # Check for npm
    if ! command -v npm &> /dev/null; then
        print_error "npm is required. Please install Node.js first."
        return 1
    fi
    
    # Install globally
    if npm install -g agent-browser; then
        print_success "agent-browser installed successfully"
    else
        print_error "Failed to install agent-browser"
        return 1
    fi
    
    return 0
}

# Install Chromium browser
install_chromium() {
    print_info "Installing Chromium browser..."
    
    if ! check_installed; then
        print_error "agent-browser must be installed first. Run: $0 install"
        return 1
    fi
    
    # Detect platform for deps
    local with_deps=""
    if [[ "$(uname)" == "Linux" ]]; then
        print_info "Linux detected - installing with system dependencies"
        with_deps="--with-deps"
    fi
    
    if agent-browser install $with_deps; then
        print_success "Chromium installed successfully"
    else
        print_error "Failed to install Chromium"
        return 1
    fi
    
    return 0
}

# Full setup
setup() {
    print_info "Setting up agent-browser..."
    
    if ! check_installed; then
        install_agent_browser || return 1
    fi
    
    if ! check_chromium 2>/dev/null; then
        install_chromium || return 1
    fi
    
    print_success "agent-browser setup complete!"
    echo ""
    print_info "Quick start:"
    echo "  agent-browser open example.com"
    echo "  agent-browser snapshot"
    echo "  agent-browser click @e1"
    echo "  agent-browser close"
    
    return 0
}

# Show status
status() {
    echo "=== Agent Browser Status ==="
    echo ""
    
    # Check installation
    if check_installed; then
        echo ""
    fi
    
    # Check Chromium
    check_chromium 2>/dev/null || true
    echo ""
    
    # Check active sessions
    print_info "Active sessions:"
    agent-browser session list 2>/dev/null || echo "  (none or daemon not running)"
    
    return 0
}

# List active sessions
sessions() {
    print_info "Active browser sessions:"
    agent-browser session list 2>/dev/null || echo "No active sessions"
    return 0
}

# Close all sessions
close_all() {
    print_info "Closing all browser sessions..."
    
    # Get list of sessions and close each
    local sessions
    sessions=$(agent-browser session list 2>/dev/null | grep -E '^\s*\w+' | awk '{print $1}')
    
    if [[ -z "$sessions" ]]; then
        print_info "No active sessions to close"
        return 0
    fi
    
    for session in $sessions; do
        print_info "Closing session: $session"
        AGENT_BROWSER_SESSION="$session" agent-browser close 2>/dev/null || true
    done
    
    print_success "All sessions closed"
    return 0
}

# Run a quick demo
demo() {
    print_info "Running agent-browser demo..."
    
    if ! check_installed; then
        print_error "agent-browser not installed. Run: $0 setup"
        return 1
    fi
    
    echo ""
    print_info "1. Opening example.com..."
    agent-browser open https://example.com
    
    echo ""
    print_info "2. Getting snapshot (accessibility tree)..."
    agent-browser snapshot -i
    
    echo ""
    print_info "3. Getting page title..."
    agent-browser get title
    
    echo ""
    print_info "4. Taking screenshot..."
    local screenshot_path="/tmp/agent-browser-demo.png"
    agent-browser screenshot "$screenshot_path"
    print_success "Screenshot saved to: $screenshot_path"
    
    echo ""
    print_info "5. Closing browser..."
    agent-browser close
    
    print_success "Demo complete!"
    return 0
}

# Show help
show_help() {
    cat << 'EOF'
Agent Browser Helper - Headless Browser Automation CLI for AI Agents

Usage: agent-browser-helper.sh <command>

Commands:
  setup       Full setup (install CLI + Chromium)
  install     Install agent-browser CLI only
  chromium    Install Chromium browser only
  status      Show installation and session status
  sessions    List active browser sessions
  close-all   Close all active sessions
  demo        Run a quick demonstration
  help        Show this help message

Examples:
  # First-time setup
  agent-browser-helper.sh setup

  # Check status
  agent-browser-helper.sh status

  # Run demo
  agent-browser-helper.sh demo

  # Close all sessions
  agent-browser-helper.sh close-all

Direct CLI Usage:
  agent-browser open example.com          # Navigate to URL
  agent-browser snapshot                  # Get accessibility tree with refs
  agent-browser click @e2                 # Click by ref from snapshot
  agent-browser fill @e3 "text"           # Fill input by ref
  agent-browser screenshot page.png       # Take screenshot
  agent-browser close                     # Close browser

Multi-Session:
  agent-browser --session s1 open site-a.com
  agent-browser --session s2 open site-b.com
  agent-browser session list

For full documentation, see:
  ~/.aidevops/agents/tools/browser/agent-browser.md
  https://github.com/vercel-labs/agent-browser
EOF
    return 0
}

# Main entry point
main() {
    local command="${1:-help}"
    
    case "$command" in
        setup)
            setup
            ;;
        install)
            install_agent_browser
            ;;
        chromium)
            install_chromium
            ;;
        status)
            status
            ;;
        sessions)
            sessions
            ;;
        close-all)
            close_all
            ;;
        demo)
            demo
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            return 1
            ;;
    esac
}

main "$@"
