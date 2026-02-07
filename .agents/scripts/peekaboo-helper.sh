#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# SC1091: Can't follow non-constant source (shared-constants.sh)
# SC2034: Unused variables (sourced constants may not all be used)

# Peekaboo Helper - macOS Screen Capture and GUI Automation
# Part of AI DevOps Framework
# Provides installation, configuration, and usage of Peekaboo for AI agents

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

# Peekaboo-specific constants
readonly PEEKABOO_CONFIG_DIR="${HOME}/.peekaboo"
readonly PEEKABOO_SNAPSHOTS_DIR="${PEEKABOO_CONFIG_DIR}/snapshots"
readonly PEEKABOO_LOGS_DIR="${PEEKABOO_CONFIG_DIR}/logs"

# Check if running on macOS
check_macos() {
    if [[ "$(uname)" != "Darwin" ]]; then
        print_error "Peekaboo is only available on macOS"
        return 1
    fi
    return 0
}

# Check macOS version (requires 15+)
check_macos_version() {
    local version
    version=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
    if [[ -z "$version" ]] || [[ "$version" -lt 15 ]]; then
        print_error "Peekaboo requires macOS 15 (Sequoia) or later"
        print_info "Current version: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
        return 1
    fi
    return 0
}

# Check if Homebrew is installed
check_homebrew() {
    if ! command -v brew &> /dev/null; then
        print_error "Homebrew is required but not installed"
        print_info "Install with: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        return 1
    fi
    return 0
}

# Check if Node.js is installed (for MCP server)
check_nodejs() {
    if ! command -v node &> /dev/null; then
        print_warning "Node.js not found - required for MCP server"
        print_info "Install with: brew install node"
        return 1
    fi
    
    local version
    version=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
    if [[ -z "$version" ]] || [[ "$version" -lt 22 ]]; then
        print_warning "Node.js 22+ recommended for MCP server"
        print_info "Current version: $(node --version 2>/dev/null || echo 'unknown')"
    fi
    return 0
}

# Install Peekaboo CLI via Homebrew
install_cli() {
    print_info "Installing Peekaboo CLI via Homebrew..."
    
    check_macos || return 1
    check_macos_version || return 1
    check_homebrew || return 1
    
    # Add tap if not already added
    if ! brew tap-info steipete/tap &>/dev/null; then
        print_info "Adding steipete/tap..."
        brew tap steipete/tap
    fi
    
    # Install peekaboo
    print_info "Installing peekaboo..."
    brew install steipete/tap/peekaboo
    
    if command -v peekaboo &> /dev/null; then
        print_success "Peekaboo CLI installed successfully"
        peekaboo --version
        return 0
    else
        print_error "Installation failed"
        return 1
    fi
}

# Install MCP server (npm package)
install_mcp() {
    print_info "Setting up Peekaboo MCP server..."
    
    check_nodejs || return 1
    
    # Test that npx can run the package
    print_info "Testing MCP server..."
    if npx -y @steipete/peekaboo --help &> /dev/null; then
        print_success "Peekaboo MCP server is available"
        print_info "Run with: npx -y @steipete/peekaboo"
        return 0
    else
        print_error "Failed to run MCP server"
        return 1
    fi
}

# Full setup (CLI + MCP)
setup() {
    print_info "Setting up Peekaboo (CLI + MCP)..."
    
    check_macos || return 1
    check_macos_version || return 1
    
    # Install CLI
    install_cli || print_warning "CLI installation failed, continuing..."
    
    # Setup MCP
    install_mcp || print_warning "MCP setup failed, continuing..."
    
    # Check permissions
    print_info "Checking permissions..."
    check_permissions
    
    print_success "Peekaboo setup complete"
    print_info "Run 'peekaboo permissions grant' to grant required permissions"
    return 0
}

# Check installation status
status() {
    print_info "Checking Peekaboo installation status..."
    
    echo ""
    echo "=== System Requirements ==="
    
    # macOS check
    if [[ "$(uname)" == "Darwin" ]]; then
        local version
        version=$(sw_vers -productVersion 2>/dev/null)
        local major
        major=$(echo "$version" | cut -d. -f1)
        if [[ "$major" -ge 15 ]]; then
            echo -e "  macOS: ${GREEN}$version (OK)${NC}"
        else
            echo -e "  macOS: ${RED}$version (requires 15+)${NC}"
        fi
    else
        echo -e "  macOS: ${RED}Not macOS${NC}"
    fi
    
    # Homebrew
    if command -v brew &> /dev/null; then
        echo -e "  Homebrew: ${GREEN}$(brew --version | head -1)${NC}"
    else
        echo -e "  Homebrew: ${RED}Not installed${NC}"
    fi
    
    # Node.js
    if command -v node &> /dev/null; then
        echo -e "  Node.js: ${GREEN}$(node --version)${NC}"
    else
        echo -e "  Node.js: ${YELLOW}Not installed (optional for MCP)${NC}"
    fi
    
    echo ""
    echo "=== Peekaboo Installation ==="
    
    # CLI
    if command -v peekaboo &> /dev/null; then
        echo -e "  CLI: ${GREEN}$(peekaboo --version 2>/dev/null || echo 'installed')${NC}"
    else
        echo -e "  CLI: ${RED}Not installed${NC}"
    fi
    
    # MCP package
    if npm list -g @steipete/peekaboo &> /dev/null 2>&1; then
        echo -e "  MCP (global): ${GREEN}Installed${NC}"
    else
        echo -e "  MCP (global): ${YELLOW}Not installed (use npx)${NC}"
    fi
    
    echo ""
    echo "=== Permissions ==="
    check_permissions
    
    return 0
}

# Check macOS permissions
check_permissions() {
    if ! command -v peekaboo &> /dev/null; then
        print_warning "Peekaboo CLI not installed, cannot check permissions"
        return 1
    fi
    
    peekaboo permissions status 2>/dev/null || {
        print_warning "Could not check permissions"
        print_info "Screen Recording: System Preferences > Privacy & Security > Screen Recording"
        print_info "Accessibility: System Preferences > Privacy & Security > Accessibility"
    }
    return 0
}

# Grant permissions
grant_permissions() {
    if ! command -v peekaboo &> /dev/null; then
        print_error "Peekaboo CLI not installed"
        return 1
    fi
    
    print_info "Opening System Preferences to grant permissions..."
    peekaboo permissions grant
    return 0
}

# Capture screenshot
capture() {
    local mode="${1:-screen}"
    local output="${2:-}"
    local app="${3:-}"
    
    if ! command -v peekaboo &> /dev/null; then
        print_error "Peekaboo CLI not installed"
        return 1
    fi
    
    local cmd_args=("peekaboo" "image" "--mode" "$mode")
    
    if [[ -n "$output" ]]; then
        cmd_args+=("--path" "$output")
    fi
    
    if [[ -n "$app" ]] && [[ "$mode" == "window" ]]; then
        cmd_args+=("--app" "$app")
    fi
    
    print_info "Capturing: ${cmd_args[*]}"
    "${cmd_args[@]}"
    return $?
}

# Run agent command
agent() {
    local prompt="$1"
    
    if ! command -v peekaboo &> /dev/null; then
        print_error "Peekaboo CLI not installed"
        return 1
    fi
    
    if [[ -z "$prompt" ]]; then
        print_error "Agent prompt is required"
        return 1
    fi
    
    print_info "Running agent: $prompt"
    peekaboo agent "$prompt"
    return $?
}

# Clean snapshots
clean() {
    local option="${1:---all-snapshots}"
    
    if ! command -v peekaboo &> /dev/null; then
        print_error "Peekaboo CLI not installed"
        return 1
    fi
    
    print_info "Cleaning snapshots..."
    peekaboo clean "$option"
    return $?
}

# Show MCP configuration example
show_mcp_config() {
    echo ""
    echo "=== Claude Desktop Configuration ==="
    echo "Add to Claude Desktop config (Developer > Edit Config):"
    echo ""
    cat << 'EOF'
{
  "mcpServers": {
    "peekaboo": {
      "command": "npx",
      "args": ["-y", "@steipete/peekaboo"],
      "env": {
        "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.1,anthropic/claude-opus-4"
      }
    }
  }
}
EOF
    echo ""
    echo "=== OpenCode Configuration ==="
    echo "Add to ~/.config/opencode/opencode.json:"
    echo ""
    cat << 'EOF'
{
  "mcp": {
    "peekaboo": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@steipete/peekaboo"],
      "env": {
        "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.1"
      }
    }
  }
}
EOF
    echo ""
    return 0
}

# Show help
show_help() {
    cat << EOF
Peekaboo Helper - macOS Screen Capture and GUI Automation

Usage: $(basename "$0") <command> [options]

Commands:
  install-cli       Install Peekaboo CLI via Homebrew
  install-mcp       Setup Peekaboo MCP server (npm)
  setup             Full setup (CLI + MCP)
  status            Check installation status
  permissions       Check macOS permissions
  grant             Grant required permissions
  capture [mode] [output] [app]
                    Capture screenshot (mode: screen|window|menu)
  agent "prompt"    Run natural language automation
  clean [option]    Clean snapshots (--all-snapshots|--older-than 7d)
  mcp-config        Show MCP configuration examples
  help              Show this help message

Examples:
  $(basename "$0") setup
  $(basename "$0") status
  $(basename "$0") capture screen ~/Desktop/screen.png
  $(basename "$0") capture window ~/Desktop/safari.png Safari
  $(basename "$0") agent "Open Safari and go to github.com"
  $(basename "$0") mcp-config

Requirements:
  - macOS 15+ (Sequoia)
  - Homebrew (for CLI installation)
  - Node.js 22+ (for MCP server)
  - Screen Recording permission
  - Accessibility permission

Documentation:
  https://github.com/steipete/Peekaboo
  https://peekaboo.boo
EOF
    return 0
}

# Main command handler
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        install-cli|install_cli)
            install_cli
            ;;
        install-mcp|install_mcp)
            install_mcp
            ;;
        setup)
            setup
            ;;
        status)
            status
            ;;
        permissions|check-permissions)
            check_permissions
            ;;
        grant|grant-permissions)
            grant_permissions
            ;;
        capture)
            capture "$@"
            ;;
        agent)
            agent "$@"
            ;;
        clean)
            clean "$@"
            ;;
        mcp-config|mcp_config)
            show_mcp_config
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
