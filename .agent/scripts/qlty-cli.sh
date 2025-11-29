#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Qlty CLI Integration Script
# Universal linting, auto-formatting, security scanning, and maintainability
# 
# Author: AI DevOps Framework
# Version: 1.1.1

# Colors for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Common constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
print_success() {
    local _arg1="$1"
    echo -e "${GREEN}✅ $_arg1${NC}"
    return 0
}

print_error() {
    local _arg1="$1"
    echo -e "${RED}❌ $_arg1${NC}" >&2
    return 0
}

print_warning() {
    local _arg1="$1"
    echo -e "${YELLOW}⚠️  $_arg1${NC}"
    return 0
}

print_info() {
    local _arg1="$1"
    echo -e "${BLUE}ℹ️  $_arg1${NC}"
    return 0
}

print_header() {
    local _arg1="$1"
    echo -e "${BLUE}🚀 $_arg1${NC}"
    echo "=========================================="
    return 0
}

# Load API configuration with intelligent credential selection
load_api_config() {
    local org="${1:-marcusquinn}"  # Default to marcusquinn organization
    
    # First check environment variables (set via mcp-env.sh, sourced by .zshrc)
    local account_api_key="${QLTY_ACCOUNT_API_KEY:-}"
    local api_key="${QLTY_API_KEY:-}"
    local workspace_id="${QLTY_WORKSPACE_ID:-}"

    # Intelligent credential selection
    if [[ -n "$account_api_key" ]]; then
        # Prefer account-level API key (broader access)
        export QLTY_API_TOKEN="$account_api_key"
        print_info "Using Qlty Account API Key (account-wide access)"

        if [[ -n "$workspace_id" ]]; then
            export QLTY_WORKSPACE_ID="$workspace_id"
            print_info "Loaded Qlty Workspace ID for organization: $org"
        fi

        if [[ -n "$api_key" ]]; then
            print_info "Note: Organization Coverage Token available but using Account API Key for broader access"
        fi

        return 0

    elif [[ -n "$api_key" ]]; then
        # Fall back to organization-specific coverage token
        export QLTY_COVERAGE_TOKEN="$api_key"
        print_info "Using Qlty Coverage Token for organization: $org"

        if [[ -n "$workspace_id" ]]; then
            export QLTY_WORKSPACE_ID="$workspace_id"
            print_info "Loaded Qlty Workspace ID for organization: $org"
        else
            print_warning "No Qlty Workspace ID found for organization: $org (optional)"
        fi

        return 0

    else
        # No credentials found
        print_warning "No Qlty credentials found"
        print_info "Add to ~/.config/aidevops/mcp-env.sh:"
        print_info "  export QLTY_ACCOUNT_API_KEY=\"your-key\""
        print_info "  export QLTY_WORKSPACE_ID=\"your-workspace-id\""
        return 1
    fi
    return 0
}

# Install Qlty CLI
install_qlty() {
    print_header "Installing Qlty CLI"

    if command -v qlty &> /dev/null; then
        print_warning "Qlty CLI already installed: $(qlty --version)"
        return 0
    fi

    print_info "Installing Qlty CLI..."

    # Install using the official installer
    if command -v curl &> /dev/null; then
        curl -sSL https://qlty.sh | bash
    else
        print_error "curl is required to install Qlty CLI"
        return 1
    fi

    # Update PATH for current session
    export PATH="$HOME/.qlty/bin:$PATH"

    # Verify installation
    if command -v qlty &> /dev/null; then
        print_success "Qlty CLI installed successfully: $(qlty --version)"
        print_info "PATH updated for current session. Restart shell for permanent access."
        return 0
    else
        print_error "Failed to install Qlty CLI"
        return 1
    fi
    return 0
}

# Initialize Qlty in repository
init_qlty() {
    print_header "Initializing Qlty in Repository"
    
    if [[ ! -d ".git" ]]; then
        print_error "Not in a Git repository. Qlty requires a Git repository."
        return 1
    fi
    
    if [[ -f ".qlty/qlty.toml" ]]; then
        print_warning "Qlty already initialized (.qlty/qlty.toml exists)"
        return 0
    fi
    
    print_info "Initializing Qlty configuration..."
    qlty init
    
    if [[ -f ".qlty/qlty.toml" ]]; then
        print_success "Qlty initialized successfully"
        print_info "Configuration file created: .qlty/qlty.toml"
        return 0
    else
        print_error "Failed to initialize Qlty"
        return 1
    fi
    return 0
}

# Run Qlty check (linting)
check_qlty() {
    local sample_size="$1"
    local org="$2"

    print_header "Running Qlty Code Quality Check"

    # Load API configuration
    load_api_config "$org"

    if [[ ! -f ".qlty/qlty.toml" ]]; then
        print_error "Qlty not initialized. Run 'init' first."
        return 1
    fi

    local cmd="qlty check"

    if [[ -n "$sample_size" ]]; then
        cmd="$cmd --sample=$sample_size"
        print_info "Running check with sample size: $sample_size"
    else
        print_info "Running full codebase check"
    fi

    print_info "Executing: $cmd"
    eval "$cmd"

    return $?
}

# Run Qlty auto-formatting
format_qlty() {
    local scope="$1"
    local org="$2"

    print_header "Running Qlty Auto-Formatting"

    # Load API configuration
    load_api_config "$org"

    if [[ ! -f ".qlty/qlty.toml" ]]; then
        print_error "Qlty not initialized. Run 'init' first."
        return 1
    fi

    local cmd="qlty fmt"

    if [[ "$scope" == "--all" ]]; then
        cmd="$cmd --all"
        print_info "Auto-formatting entire codebase"
    else
        print_info "Auto-formatting changed files"
    fi

    print_info "Executing: $cmd"

    if eval "$cmd"; then
        print_success "Auto-formatting completed successfully"
        return 0
    else
        print_error "Auto-formatting failed"
        return 1
    fi
    return 0
}

# Run Qlty code smells detection
smells_qlty() {
    local scope="$1"
    local org="$2"

    print_header "Running Qlty Code Smells Detection"

    # Load API configuration
    load_api_config "$org"

    if [[ ! -f ".qlty/qlty.toml" ]]; then
        print_error "Qlty not initialized. Run 'init' first."
        return 1
    fi

    local cmd="qlty smells"

    if [[ "$scope" == "--all" ]]; then
        cmd="$cmd --all"
        print_info "Scanning entire codebase for code smells"
    else
        print_info "Scanning changed files for code smells"
    fi

    print_info "Executing: $cmd"
    eval "$cmd"

    return $?
}

# Show help
show_help() {
    echo "Qlty CLI Integration - Universal Code Quality Tool"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  install              - Install Qlty CLI"
    echo "  init                 - Initialize Qlty in repository"
    echo "  check [sample] [org] - Run code quality check (optionally with sample size and organization)"
    echo "  fmt [--all] [org]    - Auto-format code (optionally entire codebase and organization)"
    echo "  smells [--all] [org] - Detect code smells (optionally entire codebase and organization)"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 init"
    echo "  $0 check 5           # Check sample of 5 issues (default: marcusquinn org)"
    echo "  $0 check 5 myorg     # Check sample of 5 issues for 'myorg' organization"
    echo "  $0 fmt --all         # Format entire codebase (default: marcusquinn org)"
    echo "  $0 fmt --all myorg   # Format entire codebase for 'myorg' organization"
    echo "  $0 smells --all      # Scan all files for code smells"
    echo ""
    echo "Features:"
    echo "  🐛 Linting: 70+ tools for 40+ languages"
    echo "  🖌️  Auto-formatting: Consistent code style"
    echo "  💩 Code smells: Duplication and complexity detection"
    echo "  🚨 Security: SAST, SCA, secret detection"
    echo "  ⚡ Performance: Fast, concurrent execution"
    echo ""
    echo "Qlty Credential Management:"
    echo "  Add to ~/.config/aidevops/mcp-env.sh:"
    echo "    export QLTY_ACCOUNT_API_KEY=\"qltp_...\""
    echo "    export QLTY_API_KEY=\"qltcw_...\""
    echo "    export QLTY_WORKSPACE_ID=\"...\""
    echo "  Then run: source ~/.zshrc"
    echo ""
    echo "Credential Priority:"
    echo "  1. Account API Key (qltp_...) - Preferred for account-wide access"
    echo "  2. Coverage Token (qltcw_...) - Organization-specific access"
    echo ""
    echo "Current Qlty Configuration:"
    if [[ -n "${QLTY_ACCOUNT_API_KEY:-}" ]]; then
        echo "  Account API Key: Configured (account-wide access)"
    else
        echo "  Account API Key: Not configured"
    fi
    if [[ -n "${QLTY_API_KEY:-}" ]]; then
        echo "  Coverage Token: Configured"
    else
        echo "  Coverage Token: Not configured"
    fi
    if [[ -n "${QLTY_WORKSPACE_ID:-}" ]]; then
        echo "  Workspace ID: Configured"
    else
        echo "  Workspace ID: Not configured"
    fi
    return 0
}

# Main execution
main() {
    local _arg1="$1"
    local _arg2="$2"
    local command="$1"
    shift
    
    case "$command" in
        "install")
            install_qlty
            ;;
        "init")
            init_qlty
            ;;
        "check")
            check_qlty "$_arg1" "$_arg2"
            ;;
        "fmt")
            format_qlty "$_arg1" "$_arg2"
            ;;
        "smells")
            smells_qlty "$_arg1" "$_arg2"
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
