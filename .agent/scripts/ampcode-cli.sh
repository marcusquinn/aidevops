#!/bin/bash

# AmpCode CLI Integration Script
# Professional AI coding assistant integration
#
# Usage: ./ampcode-cli.sh [command] [options]
# Commands:
#   install     - Install AmpCode CLI
#   setup       - Configure AmpCode with API key
#   scan        - Run code scan and analysis
#   review      - Get AI code review
#   fix         - Apply AI-suggested fixes
#   status      - Check AmpCode status
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Configuration
readonly AMPCODE_API_CONFIG="configs/ampcode-config.json"
readonly AMPCODE_RESULTS_DIR=".agent/tmp/ampcode"

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

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}" >&2
    return 0
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}🤖 $message${NC}"
    return 0
}

# Ensure results directory exists
ensure_results_dir() {
    mkdir -p "$AMPCODE_RESULTS_DIR"
    return 0
}

# Load API configuration
load_api_config() {
    local api_key_script
    api_key_script="$(dirname "$0")/setup-local-api-keys.sh"
    if [[ -f "$api_key_script" ]]; then
        local stored_key
        stored_key=$("$api_key_script" get ampcode 2>/dev/null)
        if [[ -n "$stored_key" ]]; then
            export AMPCODE_API_KEY="$stored_key"
            print_info "Loaded AmpCode API key from secure local storage"
            return 0
        fi
    fi

    if [[ -f "$AMPCODE_API_CONFIG" ]]; then
        if command -v jq >/dev/null 2>&1; then
            local api_key
            api_key=$(jq -r '.api_key // empty' "$AMPCODE_API_CONFIG" 2>/dev/null)
            if [[ -n "$api_key" ]]; then
                export AMPCODE_API_KEY="$api_key"
                print_info "Loaded AmpCode API key from configuration"
                return 0
            fi
        fi
    fi

    print_warning "AmpCode API key not found in local storage"
    return 1
}

# Check if AmpCode CLI is installed
check_ampcode_cli() {
    local ampcode_cmd="amp"  # Likely CLI command name
    
    if command -v "$ampcode_cmd" &> /dev/null; then
        local version
        version=$("$ampcode_cmd" --version 2>/dev/null || echo "unknown")
        print_success "AmpCode CLI installed: $version"
        return 0
    else
        print_warning "AmpCode CLI not found"
        print_info "Expected CLI command: amp"
        return 1
    fi
}

# Install AmpCode CLI
install_ampcode_cli() {
    print_header "Installing AmpCode CLI"
    
    # Check if already installed
    if check_ampcode_cli; then
        print_info "AmpCode CLI is already installed"
        return 0
    fi

    # Detect platform and install method
    local platform
    case "$(uname -s)" in
        Darwin*)
            platform="macOS"
            if command -v brew &> /dev/null; then
                print_info "Installing via Homebrew..."
                # Install via npm as common method
                if command -v npm &> /dev/null; then
                    npm install -g @ampcode/cli
                else
                    print_error "npm not found. Please install Node.js first"
                    return 1
                fi
            else
                print_error "Homebrew not found. Please install Homebrew first"
                return 1
            fi
            ;;
        Linux*)
            platform="Linux"
            if command -v npm &> /dev/null; then
                print_info "Installing via npm..."
                npm install -g @ampcode/cli
            else
                print_error "npm not found. Please install Node.js first"
                return 1
            fi
            ;;
        *)
            print_error "Unsupported platform: $(uname -s)"
            return 1
            ;;
    esac
    
    # Verify installation
    if check_ampcode_cli; then
        print_success "AmpCode CLI installed successfully on $platform"
        return 0
    else
        print_error "Installation failed"
        print_info "Alternative: Visit https://ampcode.com to download CLI"
        return 1
    fi
}

# Setup AmpCode configuration
setup_ampcode_config() {
    print_header "Setting Up AmpCode Configuration"
    
    # Load existing config
    if ! load_api_config; then
        print_info "Please visit https://ampcode.com to get your API key"
        print_info "Then run: bash .agent/scripts/setup-local-api-keys.sh set ampcode YOUR_API_KEY"
        return 1
    fi

    # Create config file
    mkdir -p configs
    cat > "$AMPCODE_API_CONFIG" << 'EOF'
{
  "api_key": "",
  "organisation": "",
  "workspace": "",
  "preferences": {
    "auto_review": true,
    "severity_threshold": "medium",
    "focus_areas": ["security", "performance", "maintainability"]
  }
}
EOF

    # Update config with API key
    if command -v jq >/dev/null 2>&1 && [[ -n "$AMPCODE_API_KEY" ]]; then
        jq --arg api_key "$AMPCODE_API_KEY" '.api_key = $api_key' "$AMPCODE_API_CONFIG" > "${AMPCODE_API_CONFIG}.tmp"
        mv "${AMPCODE_API_CONFIG}.tmp" "$AMPCODE_API_CONFIG"
    fi

    print_success "AmpCode configuration created: $AMPCODE_API_CONFIG"
    print_info "You can customize the configuration file as needed"
    return 0
}

# Run code scan
run_code_scan() {
    local target_path="${1:-.}"
    local output_format="${2:-json}"

    print_header "Running AmpCode Code Scan"
    
    # Ensure CLI is installed
    if ! check_ampcode_cli; then
        print_error "AmpCode CLI not installed"
        print_info "Run: $0 install"
        return 1
    fi

    # Load API configuration
    if ! load_api_config; then
        print_error "API configuration not found"
        print_info "Run: $0 setup"
        return 1
    fi

    ensure_results_dir
    local output_file="$AMPCODE_RESULTS_DIR/scan-$(date +%Y%m%d-%H%M%S).$output_format"

    print_info "Scanning path: $target_path"
    print_info "Output format: $output_format"
    
    local cmd="amp scan --path $target_path --format $output_format --output $output_file"
    print_info "Executing: $cmd"

    local start_time=$(date +%s)
    eval "$cmd"
    local exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 ]]; then
        print_success "Code scan completed in ${duration}s"
        print_info "Results saved to: $output_file"
        
        # Show summary
        if [[ -f "$output_file" && "$output_format" == "json" ]]; then
            if command -v jq >/dev/null 2>&1; then
                local issues
                issues=$(jq '.issues | length // 0' "$output_file" 2>/dev/null || echo "0")
                local suggestions
                suggestions=$(jq '.suggestions | length // 0' "$output_file" 2>/dev/null || echo "0")
                print_info "Issues found: $issues"
                print_info "AI suggestions: $suggestions"
            fi
        fi
        return 0
    else
        print_error "Code scan failed after ${duration}s"
        return 1
    fi
}

# Get AI code review
get_ai_review() {
    local target_path="${1:-.}"
    local severity_level="${2:-medium}"

    print_header "Getting AmpCode AI Review"
    
    # Ensure CLI is installed
    if ! check_ampcode_cli; then
        print_error "AmpCode CLI not installed"
        return 1
    fi

    # Load API configuration
    if ! load_api_config; then
        print_error "API configuration not found"
        return 1
    fi

    ensure_results_dir
    local review_file="$AMPCODE_RESULTS_DIR/review-$(date +%Y%m%d-%H%M%S).md"

    print_info "Reviewing path: $target_path"
    print_info "Severity level: $severity_level"

    local cmd="amp review --path $target_path --severity $severity_level --output $review_file"
    print_info "Executing: $cmd"

    local start_time=$(date +%s)
    eval "$cmd"
    local exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 ]]; then
        print_success "AI review completed in ${duration}s"
        print_info "Review saved to: $review_file"
        
        # Show preview
        if [[ -f "$review_file" ]]; then
            print_info "Review preview:"
            echo ""
            head -20 "$review_file"
            echo ""
            local total_lines=$(wc -l < "$review_file")
            print_info "Total review lines: $total_lines"
        fi
        return 0
    else
        print_error "AI review failed after ${duration}s"
        return 1
    fi
}

# Apply AI-suggested fixes
apply_fixes() {
    local target_path="${1:-.}"
    local auto_apply="${2:-false}"

    print_header "Applying AmpCode AI Fixes"
    
    # Ensure CLI is installed
    if ! check_ampcode_cli; then
        print_error "AmpCode CLI not installed"
        return 1
    fi

    # Load API configuration
    if ! load_api_config; then
        print_error "API configuration not found"
        return 1
    fi

    ensure_results_dir
    local fixes_file="$AMPCODE_RESULTS_DIR/fixes-$(date +%Y%m%d-%H%M%S).json"

    print_info "Analyzing fixes for: $target_path"
    
    local cmd="amp analyze --path $target_path --suggest-fixes --output $fixes_file"
    print_info "Executing: $cmd"

    local start_time=$(date +%s)
    eval "$cmd"
    local exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 && -f "$fixes_file" ]]; then
        print_success "Fix analysis completed in ${duration}s"
        
        if command -v jq >/dev/null 2>&1; then
            local fixes_count
            fixes_count=$(jq '.fixes | length // 0' "$fixes_file" 2>/dev/null || echo "0")
            print_info "AI fixes available: $fixes_count"
        fi

        if [[ "$auto_apply" == "true" ]]; then
            print_warning "Auto-apply enabled - Apply with caution!"
            print_info "Applying fixes..."
            
            local apply_cmd="amp apply-fixes --file $fixes_file"
            eval "$apply_cmd"
            local apply_exit_code=$?

            if [[ $apply_exit_code -eq 0 ]]; then
                print_success "Fixes applied successfully"
            else
                print_error "Failed to apply some fixes"
                return 1
            fi
        else
            print_info "Use --auto-apply flag to automatically apply fixes"
            print_info "Review fixes file: $fixes_file"
        fi

        return 0
    else
        print_error "Fix analysis failed after ${duration}s"
        return 1
    fi
}

# Show AmpCode status
show_status() {
    print_header "AmpCode CLI Status"
    
    # Check CLI installation
    if check_ampcode_cli; then
        echo ""
    else
        print_info "Run: $0 install"
        echo ""
    fi

    # Check configuration
    echo "Configuration Status:"
    if load_api_config; then
        print_success "API Key: ✅ Configured"
    else
        print_warning "API Key: ⚠️ Not configured"
        print_info "Run: $0 setup"
    fi

    if [[ -f "$AMPCODE_API_CONFIG" ]]; then
        print_success "Config File: ✅ $AMPCODE_API_CONFIG"
    else
        print_warning "Config File: ❌ Not found"
    fi

    echo ""
    print_info "Recent Results:"
    find "$AMPCODE_RESULTS_DIR" -name "*.json" -o -name "*.md" 2>/dev/null | sort -r | head -3 | while read -r file; do
        local age=$(find "$file" -mmin +1 2>/dev/null || echo "0")
        local size=$(du -h "$file" 2>/dev/null | cut -f1 || echo "unknown")
        local type=$(basename "$file" | sed 's/.*\.//' | sed 's/-.*/./')
        print_info "  $(basename "$file") (${type} - $size)"
    done

    return 0
}

# Show help
show_help() {
    print_header "AmpCode CLI Integration Help"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install           - Install AmpCode CLI"
    echo "  setup             - Configure AmpCode with API key"
    echo "  scan [path]       - Run code scan and analysis"
    echo "  review [path]     - Get AI code review"
    echo "  fix [path]        - Apply AI-suggested fixes"
    echo "  status            - Check AmpCode status"
    echo "  help              - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 setup"
    echo "  $0 scan ./src"
    echo "  $0 review --severity high"
    echo "  $0 fix --auto-apply"
    echo ""
    echo "Setup:"
    echo "  1. Visit https://ampcode.com to create account"
    echo "  2. Get your API key"
    echo "  3. Run: bash .agent/scripts/setup-local-api-keys.sh set ampcode YOUR_API_KEY"
    echo "  4. Run: $0 setup"
    echo ""
    echo "This script integrates AmpCode's professional AI coding assistant"
    echo "with the AI DevOps Framework for enhanced code quality and productivity."
    echo ""
    return 0
}

# Main function
main() {
    local command="${1:-help}"

    # Ensure temp directory exists
    mkdir -p .agent/tmp

    case "$command" in
        "install")
            install_ampcode_cli
            ;;
        "setup")
            setup_ampcode_config
            ;;
        "scan")
            run_code_scan "$2" "$3"
            ;;
        "review")
            get_ai_review "$2" "$3"
            ;;
        "fix")
            if [[ "$2" == "--auto-apply" ]]; then
                apply_fixes "$3" "true"
            else
                apply_fixes "$2" "false"
            fi
            ;;
        "status")
            show_status
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"
