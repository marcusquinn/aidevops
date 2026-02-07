#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317
set -euo pipefail

# CodeRabbit CLI Integration Script
# Provides AI-powered code review capabilities through CodeRabbit CLI
#
# This script integrates CodeRabbit CLI into the AI DevOps workflow
# for local code analysis, review automation, and quality assurance.
#
# Usage: ./coderabbit-cli.sh [command] [options]
# Commands:
#   install     - Install CodeRabbit CLI
#   auth        - Authenticate with CodeRabbit (browser-based)
#   review      - Review uncommitted changes (--plain for AI agents)
#   review-all  - Review all changes including committed (--plain)
#   status      - Check CodeRabbit CLI status
#   help        - Show this help message
#
# CLI Modes:
#   --plain       - Plain text output (for scripts/AI agents)
#   --prompt-only - Minimal output optimized for AI agents
#   --base <branch> - Compare against specific base branch
#
# Author: AI DevOps Framework
# Version: 1.2.0
# License: MIT

# Source shared constants (provides sed_inplace and other utilities)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Common constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
# Configuration constants
readonly CODERABBIT_CLI_INSTALL_URL="https://cli.coderabbit.ai/install.sh"
readonly CONFIG_DIR="$HOME/.config/coderabbit"
readonly API_KEY_FILE="$CONFIG_DIR/api_key"

# Print functions
print_success() {
    local message="$1"
    echo -e "${GREEN}✅ $message${NC}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}ℹ️  $message${NC}"
    return 0
}

# Get CodeRabbit reviews from GitHub API
get_coderabbit_reviews() {
    print_header "Fetching CodeRabbit Reviews"

    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        print_warning "GitHub CLI (gh) not found. Install it for API access."
        print_info "Visit: https://cli.github.com/"
        return 1
    fi

    # Get recent PRs with CodeRabbit reviews
    print_info "Fetching recent pull requests with CodeRabbit reviews..."

    local prs
    prs=$(gh pr list --state all --limit 5 --json number,title,state,url)

    if [[ -n "$prs" && "$prs" != "[]" ]]; then
        print_success "Found pull requests with potential CodeRabbit reviews"
        echo "$prs" | jq -r '.[] | "PR #\(.number): \(.title) (\(.state))"'

        # Get reviews for the most recent PR
        local latest_pr
        latest_pr=$(echo "$prs" | jq -r '.[0].number')

        if [[ -n "$latest_pr" && "$latest_pr" != "null" ]]; then
            print_info "Checking reviews for PR #$latest_pr..."

            local reviews
            reviews=$(gh pr view "$latest_pr" --json reviews)

            if [[ -n "$reviews" ]]; then
                local coderabbit_reviews
                coderabbit_reviews=$(echo "$reviews" | jq -r '.reviews[] | select(.author.login == "coderabbitai[bot]") | .body' 2>/dev/null || echo "")

                if [[ -n "$coderabbit_reviews" ]]; then
                    print_success "Found CodeRabbit reviews!"
                    print_info "Review summary available for PR #$latest_pr"
                else
                    print_warning "No CodeRabbit reviews found in recent PRs"
                fi
            fi
        fi
    else
        print_warning "No pull requests found"
    fi

    return 0
}

# Apply CodeRabbit auto-fixes
apply_coderabbit_fixes() {
    print_header "Applying CodeRabbit Auto-Fixes"

    local file="${1:-}"

    if [[ -z "$file" ]]; then
        print_error "Please specify a file to fix"
        print_info "Usage: apply_coderabbit_fixes <file>"
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi

    print_info "Applying common CodeRabbit fixes to: $file"

    # Backup original file
    cp "$file" "$file.coderabbit-backup"
    print_info "Created backup: $file.coderabbit-backup"

    # Apply markdown formatting fixes if it's a markdown file
    if [[ "$file" == *.md ]]; then
        print_info "Applying markdown formatting fixes..."

        # Fix heading spacing (add blank line after headings)
        sed_inplace '/^#.*$/{
            N
            /\n$/!s/$/\n/
        }' "$file"

        # Fix list spacing (ensure blank lines around lists)
        sed_inplace '/^[[:space:]]*[-*+][[:space:]]/{
            i\

        }' "$file"
        print_success "Applied markdown formatting fixes"
    fi

    # Apply shell script fixes if it's a shell script
    if [[ "$file" == *.sh ]]; then
        print_info "Applying shell script fixes..."

        # Add return statements to functions (basic implementation)
        awk '
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { in_function = 1; function_name = $_arg1 }
        /^}$/ && in_function {
            print "    return 0"
            print $0
            in_function = 0
            next
        }
        { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

        print_success "Applied shell script fixes"
    fi

    print_success "CodeRabbit auto-fixes applied to $file"
    print_info "Original backed up as: $file.coderabbit-backup"

    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}"
    return 0
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}🤖 $message${NC}"
    return 0
}

# Check if CodeRabbit CLI is installed
check_cli_installed() {
    if command -v coderabbit &> /dev/null; then
        return 0
    else
        return 1
    fi
    return 0
}

# Install CodeRabbit CLI
install_cli() {
    print_header "Installing CodeRabbit CLI..."
    
    if check_cli_installed; then
        print_info "CodeRabbit CLI is already installed"
        coderabbit --version
        return 0
    fi
    
    print_info "Downloading and installing CodeRabbit CLI..."
    if curl -fsSL "$CODERABBIT_CLI_INSTALL_URL" | sh; then
        print_success "CodeRabbit CLI installed successfully"
        return 0
    else
        print_error "Failed to install CodeRabbit CLI"
        return 1
    fi
    return 0
}

# Setup API key configuration
setup_api_key() {
    print_header "Setting up CodeRabbit API Key..."
    
    # Check if API key is already configured
    if [[ -f "$API_KEY_FILE" ]]; then
        print_info "API key is already configured"
        print_warning "To reconfigure, delete $API_KEY_FILE and run setup again"
        return 0
    fi
    
    # Create config directory
    mkdir -p "$CONFIG_DIR"
    
    print_info "CodeRabbit API Key Setup"
    echo ""
    print_info "To get your API key:"
    print_info "1. Visit https://app.coderabbit.ai"
    print_info "2. Go to Settings > API Keys"
    print_info "3. Generate a new API key for your organization"
    echo ""
    
    read -r -p "Enter your CodeRabbit API key: " api_key
    
    if [[ -z "$api_key" ]]; then
        print_error "API key cannot be empty"
        return 1
    fi
    
    # Save API key securely
    echo "$api_key" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    
    # Export for current session
    export CODERABBIT_API_KEY="$api_key"
    
    print_success "API key configured successfully"
    return 0
}

# Load API key from configuration
load_api_key() {
    # Check environment variable first (set via credentials.sh, sourced by .zshrc)
    if [[ -n "${CODERABBIT_API_KEY:-}" ]]; then
        print_info "Using CodeRabbit API key from environment"
        return 0
    fi

    # Fallback to legacy storage location
    if [[ -f "$API_KEY_FILE" ]]; then
        local legacy_key
        legacy_key=$(cat "$API_KEY_FILE")
        export CODERABBIT_API_KEY="$legacy_key"
        print_info "Loaded CodeRabbit API key from legacy storage"
        print_warning "Consider migrating to ~/.config/aidevops/credentials.sh"
        return 0
    else
        print_error "CODERABBIT_API_KEY not found in environment"
        print_info "Add to ~/.config/aidevops/credentials.sh:"
        print_info "  export CODERABBIT_API_KEY=\"your-api-key\""
        return 1
    fi
    return 0
}

# Review uncommitted changes (default mode for local development)
review_changes() {
    local mode="${1:-plain}"
    local base_branch="${2:-}"
    
    print_header "Reviewing uncommitted changes with CodeRabbit..."
    
    if ! check_cli_installed; then
        print_error "CodeRabbit CLI not installed. Run: $0 install"
        return 1
    fi
    
    print_info "Analyzing uncommitted git changes..."
    
    # Build command as array to avoid eval
    local cmd=("coderabbit")
    case "$mode" in
        "plain")
            cmd+=("--plain" "--type" "uncommitted")
            ;;
        "prompt-only")
            cmd+=("--prompt-only" "--type" "uncommitted")
            ;;
        "interactive")
            cmd+=("--type" "uncommitted")
            ;;
    esac
    
    # Add base branch if specified
    if [[ -n "$base_branch" ]]; then
        cmd+=("--base" "$base_branch")
    fi
    
    print_info "Running: ${cmd[*]}"
    if "${cmd[@]}"; then
        print_success "Code review completed"
        return 0
    else
        print_error "Code review failed"
        return 1
    fi
}

# Review all changes (committed + uncommitted)
review_all_changes() {
    local mode="${1:-plain}"
    local base_branch="${2:-}"
    
    print_header "Reviewing all changes with CodeRabbit..."
    
    if ! check_cli_installed; then
        print_error "CodeRabbit CLI not installed. Run: $0 install"
        return 1
    fi
    
    print_info "Analyzing all git changes (committed + uncommitted)..."
    
    # Build command as array to avoid eval
    local cmd=("coderabbit")
    case "$mode" in
        "plain")
            cmd+=("--plain" "--type" "all")
            ;;
        "prompt-only")
            cmd+=("--prompt-only" "--type" "all")
            ;;
        "interactive")
            cmd+=("--type" "all")
            ;;
    esac
    
    # Add base branch if specified
    if [[ -n "$base_branch" ]]; then
        cmd+=("--base" "$base_branch")
    fi
    
    print_info "Running: ${cmd[*]}"
    if "${cmd[@]}"; then
        print_success "Code review completed"
        return 0
    else
        print_error "Code review failed"
        return 1
    fi
}

# Authenticate with CodeRabbit (browser-based OAuth)
auth_login() {
    print_header "Authenticating with CodeRabbit..."
    
    if ! check_cli_installed; then
        print_error "CodeRabbit CLI not installed. Run: $0 install"
        return 1
    fi
    
    print_info "Opening browser for authentication..."
    print_info "Follow the prompts to sign in and copy the access token."
    
    if coderabbit auth login; then
        print_success "Authentication successful"
        return 0
    else
        print_error "Authentication failed"
        return 1
    fi
}

# Check CodeRabbit CLI status
check_status() {
    print_header "CodeRabbit CLI Status"

    if check_cli_installed; then
        print_success "CodeRabbit CLI is installed"
        coderabbit --version
    else
        print_warning "CodeRabbit CLI is not installed"
    fi

    if [[ -f "$API_KEY_FILE" ]]; then
        print_success "API key is configured"
    else
        print_warning "API key is not configured"
    fi

    return 0
}

# Show help message
show_help() {
    print_header "CodeRabbit CLI Integration Help"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install              - Install CodeRabbit CLI"
    echo "  auth                 - Authenticate with CodeRabbit (browser-based)"
    echo "  review [mode] [base] - Review uncommitted changes"
    echo "  review-all [mode] [base] - Review all changes (committed + uncommitted)"
    echo "  status               - Check CodeRabbit CLI status"
    echo "  reviews              - Fetch CodeRabbit reviews from GitHub PRs"
    echo "  fix <file>           - Apply auto-fixes to a file"
    echo "  help                 - Show this help message"
    echo ""
    echo "Review modes:"
    echo "  plain       - Plain text output (default, best for scripts/AI)"
    echo "  prompt-only - Minimal output optimized for AI agents"
    echo "  interactive - Full interactive TUI mode"
    echo ""
    echo "Examples:"
    echo "  $0 install                    # Install CLI"
    echo "  $0 auth                       # Authenticate (browser)"
    echo "  $0 review                     # Review uncommitted (plain mode)"
    echo "  $0 review prompt-only         # Review for AI agents"
    echo "  $0 review plain develop       # Review against develop branch"
    echo "  $0 review-all                 # Review all changes"
    echo "  $0 status                     # Check CLI status"
    echo ""
    echo "Direct CLI usage (equivalent commands):"
    echo "  coderabbit --plain            # Plain text review"
    echo "  coderabbit --prompt-only      # AI agent optimized"
    echo "  coderabbit --type uncommitted # Only uncommitted changes"
    echo "  coderabbit --base develop     # Compare against develop"
    echo ""
    echo "For more information: https://docs.coderabbit.ai/cli/overview"
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local arg2="${2:-}"
    local arg3="${3:-}"

    case "$command" in
        "install")
            install_cli
            ;;
        "auth"|"login")
            auth_login
            ;;
        "setup")
            # Legacy: redirect to auth
            print_warning "setup is deprecated, use 'auth' instead"
            auth_login
            ;;
        "review")
            review_changes "$arg2" "$arg3"
            ;;
        "review-all")
            review_all_changes "$arg2" "$arg3"
            ;;
        "status")
            check_status
            ;;
        "reviews")
            get_coderabbit_reviews
            ;;
        "fix")
            apply_coderabbit_fixes "$arg2"
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            show_help
            return 1
            ;;
    esac
    return 0
}

# Execute main function with all arguments
main "$@"
