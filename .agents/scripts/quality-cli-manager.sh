#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Quality CLI Manager Script
# Unified management for CodeRabbit, Codacy, SonarScanner, and Snyk CLIs
#
# Usage: ./quality-cli-manager.sh [command] [cli] [options]
# Commands:
#   install     - Install specified CLI or all CLIs
#   init        - Initialize configuration for specified CLI or all CLIs
#   analyze     - Run analysis with specified CLI or all CLIs
#   status      - Check status of specified CLI or all CLIs
#   help        - Show this help message
#
# CLIs:
#   coderabbit  - CodeRabbit CLI for AI-powered code review
#   codacy      - Codacy CLI v2 for comprehensive code analysis
#   sonar       - SonarScanner CLI for SonarQube Cloud analysis
#   snyk        - Snyk CLI for security vulnerability scanning
#   all         - All quality CLIs (default)
#
# Author: AI DevOps Framework
# Version: 1.2.0
# License: MIT

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Common constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
# CLI Scripts
readonly CODERABBIT_SCRIPT=".agent/scripts/coderabbit-cli.sh"
readonly CODACY_SCRIPT=".agent/scripts/codacy-cli.sh"
readonly SONAR_SCRIPT=".agent/scripts/sonarscanner-cli.sh"
readonly SNYK_SCRIPT=".agent/scripts/snyk-helper.sh"

# CLI Names
readonly CLI_CODERABBIT="coderabbit"
readonly CLI_SNYK="snyk"

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
    echo -e "${PURPLE}🔧 $message${NC}"
    return 0
}

# Execute CLI command
execute_cli_command() {
    local cli="$1"
    local command="$2"
    shift 2
    local args="$*"
    
    local script=""
    local cli_name=""
    
    case "$cli" in
        "$CLI_CODERABBIT")
            script="$CODERABBIT_SCRIPT"
            cli_name="CodeRabbit CLI"
            ;;
        "codacy")
            script="$CODACY_SCRIPT"
            cli_name="Codacy CLI"
            ;;
        "sonar")
            script="$SONAR_SCRIPT"
            cli_name="SonarScanner CLI"
            ;;
        "$CLI_SNYK")
            script="$SNYK_SCRIPT"
            cli_name="Snyk CLI"
            ;;
        *)
            print_error "Unknown CLI: $cli"
            return 1
            ;;
    esac
    
    if [[ ! -f "$script" ]]; then
        print_error "$cli_name script not found: $script"
        return 1
    fi
    
    print_info "Executing: $cli_name $command $args"
    bash "$script" "$command" "$args"
    return $?
}

# Install CLIs
install_clis() {
    local target_cli="$1"
    
    print_header "Installing Quality CLIs"
    
    local success_count=0
    local total_count=0
    
    if [[ "$target_cli" == "all" || "$target_cli" == "$CLI_CODERABBIT" ]]; then
        print_info "Installing CodeRabbit CLI..."
        if execute_cli_command "$CLI_CODERABBIT" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    if [[ "$target_cli" == "all" || "$target_cli" == "codacy" ]]; then
        print_info "Installing Codacy CLI..."
        if execute_cli_command "codacy" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    if [[ "$target_cli" == "all" || "$target_cli" == "sonar" ]]; then
        print_info "Installing SonarScanner CLI..."
        if execute_cli_command "sonar" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "qlty" ]]; then
        print_info "Installing Qlty CLI..."
        if execute_cli_command "qlty" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "$CLI_SNYK" ]]; then
        print_info "Installing Snyk CLI..."
        if execute_cli_command "$CLI_SNYK" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "linters" ]]; then
        print_info "Installing CodeFactor-inspired linters..."
        if bash "$(dirname "$0")/linter-manager.sh" install-detected; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    print_info "Installation Summary: $success_count/$total_count CLIs installed successfully"
    
    if [[ $success_count -eq $total_count ]]; then
        print_success "All requested CLIs installed successfully"
        return 0
    else
        print_warning "Some CLI installations failed"
        return 1
    fi
    return 0
}

# Initialize CLI configurations
init_clis() {
    local target_cli="$1"
    
    print_header "Initializing Quality CLI Configurations"
    
    local success_count=0
    local total_count=0
    
    if [[ "$target_cli" == "all" || "$target_cli" == "$CLI_CODERABBIT" ]]; then
        print_info "Initializing CodeRabbit CLI..."
        if execute_cli_command "$CLI_CODERABBIT" "setup"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    if [[ "$target_cli" == "all" || "$target_cli" == "codacy" ]]; then
        print_info "Initializing Codacy CLI..."
        if execute_cli_command "codacy" "init"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    if [[ "$target_cli" == "all" || "$target_cli" == "sonar" ]]; then
        print_info "Initializing SonarScanner CLI..."
        if execute_cli_command "sonar" "init"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "qlty" ]]; then
        print_info "Initializing Qlty CLI..."
        if execute_cli_command "qlty" "init"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "$CLI_SNYK" ]]; then
        print_info "Initializing Snyk CLI..."
        if execute_cli_command "$CLI_SNYK" "auth"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    print_info "Initialization Summary: $success_count/$total_count CLIs initialized successfully"
    
    if [[ $success_count -eq $total_count ]]; then
        print_success "All requested CLIs initialized successfully"
        return 0
    else
        print_warning "Some CLI initializations failed"
        return 1
    fi
    return 0
}

# Run analysis with CLIs
analyze_with_clis() {
    local target_cli="$1"
    shift
    local args="$*"

    print_header "Running Quality Analysis"

    local success_count=0
    local total_count=0

    if [[ "$target_cli" == "all" || "$target_cli" == "$CLI_CODERABBIT" ]]; then
        print_info "Running CodeRabbit analysis..."
        if execute_cli_command "$CLI_CODERABBIT" "review" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "codacy" ]]; then
        print_info "Running Codacy analysis..."
        if execute_cli_command "codacy" "analyze" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    # Add auto-fix option for Codacy
    if [[ "$target_cli" == "codacy-fix" ]]; then
        print_info "Running Codacy analysis with auto-fix..."
        if execute_cli_command "codacy" "analyze" "--fix"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "sonar" ]]; then
        print_info "Running SonarQube analysis..."
        if execute_cli_command "sonar" "analyze" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "qlty" ]]; then
        print_info "Running Qlty analysis..."
        # Add organization parameter if provided
        local qlty_args="$args"
        if [[ -n "$QLTY_ORG" ]]; then
            qlty_args="$args $QLTY_ORG"
        fi
        if execute_cli_command "qlty" "check" "$qlty_args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "$CLI_SNYK" ]]; then
        print_info "Running Snyk security analysis..."
        if execute_cli_command "$CLI_SNYK" "full" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    # Add Snyk-specific scan options
    if [[ "$target_cli" == "snyk-sca" ]]; then
        print_info "Running Snyk SCA (dependency) scan..."
        if execute_cli_command "$CLI_SNYK" "test" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "snyk-code" ]]; then
        print_info "Running Snyk Code (SAST) scan..."
        if execute_cli_command "$CLI_SNYK" "code" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "snyk-iac" ]]; then
        print_info "Running Snyk IaC scan..."
        if execute_cli_command "$CLI_SNYK" "iac" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    print_info "Analysis Summary: $success_count/$total_count analyses completed successfully"

    if [[ $success_count -eq $total_count ]]; then
        print_success "All requested analyses completed successfully"
        return 0
    else
        print_warning "Some analyses failed"
        return 1
    fi
    return 0
}

# Show CLI status
show_cli_status() {
    local target_cli="$1"

    print_header "Quality CLI Status Report"

    if [[ "$target_cli" == "all" || "$target_cli" == "$CLI_CODERABBIT" ]]; then
        print_info "CodeRabbit CLI Status:"
        execute_cli_command "$CLI_CODERABBIT" "status"
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "codacy" ]]; then
        print_info "Codacy CLI Status:"
        execute_cli_command "codacy" "status"
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "sonar" ]]; then
        print_info "SonarScanner CLI Status:"
        execute_cli_command "sonar" "status"
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "qlty" ]]; then
        print_info "Qlty CLI Status:"
        if command -v qlty &> /dev/null; then
            echo "✅ Qlty CLI installed: $(qlty --version 2>/dev/null || echo 'version unknown')"
            if [[ -f ".qlty/qlty.toml" ]]; then
                echo "✅ Qlty initialized in repository"
            else
                echo "⚠️  Qlty not initialized (run 'qlty init')"
            fi
        else
            echo "❌ Qlty CLI not installed"
        fi
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "$CLI_SNYK" ]]; then
        print_info "Snyk CLI Status:"
        if command -v snyk &> /dev/null; then
            echo "✅ Snyk CLI installed: $(snyk --version 2>/dev/null || echo 'version unknown')"
            if [[ -n "${SNYK_TOKEN:-}" ]] || snyk config get api &>/dev/null 2>&1; then
                echo "✅ Snyk authenticated"
            else
                echo "⚠️  Snyk not authenticated (run 'snyk auth' or set SNYK_TOKEN)"
            fi
        else
            echo "❌ Snyk CLI not installed"
        fi
        echo ""
    fi

    return 0
}

# Show help message
show_help() {
    print_header "Quality CLI Manager Help"
    echo ""
    echo "Usage: $0 [command] [cli] [options]"
    echo ""
    echo "Commands:"
    echo "  install [cli]        - Install specified CLI or all CLIs"
    echo "  init [cli]           - Initialize configuration for specified CLI or all CLIs"
    echo "  analyze [cli] [opts] - Run analysis with specified CLI or all CLIs"
    echo "  status [cli]         - Check status of specified CLI or all CLIs"
    echo "  help                 - Show this help message"
    echo ""
    echo "CLIs:"
    echo "  coderabbit           - CodeRabbit CLI for AI-powered code review"
    echo "  codacy               - Codacy CLI v2 for comprehensive code analysis"
    echo "  codacy-fix           - Codacy CLI with auto-fix (applies fixes when available)"
    echo "  sonar                - SonarScanner CLI for SonarQube Cloud analysis"
    echo "  snyk                 - Snyk CLI for security vulnerability scanning"
    echo "  snyk-sca             - Snyk dependency vulnerability scan only"
    echo "  snyk-code            - Snyk source code scan (SAST) only"
    echo "  snyk-iac             - Snyk Infrastructure as Code scan only"
    echo "  qlty                 - Qlty CLI for universal linting and auto-formatting"
    echo "  linters              - Linter Manager for CodeFactor-inspired multi-language linters"
    echo "  all                  - All quality CLIs (default)"
    echo ""
    echo "Examples:"
    echo "  $0 install all"
    echo "  $0 init codacy"
    echo "  $0 analyze coderabbit"
    echo "  $0 analyze codacy-fix      # Auto-fix issues when possible"
    echo "  $0 analyze qlty            # Universal linting and formatting"
    echo "  $0 analyze snyk            # Full Snyk security scan (SCA + SAST + IaC)"
    echo "  $0 analyze snyk-code       # Snyk source code scan only"
    echo "  $0 install linters         # Install CodeFactor-inspired linters"
    echo "  $0 analyze all"
    echo "  $0 status sonar"
    echo "  $0 status snyk"
    echo ""
    echo "Environment Variables:"
    echo "  CodeRabbit:"
    echo "    CODERABBIT_API_KEY   - CodeRabbit API key"
    echo ""
    echo "  Codacy:"
    echo "    CODACY_API_TOKEN     - Codacy API token"
    echo "    CODACY_PROJECT_TOKEN - Codacy project token"
    echo "    CODACY_PROVIDER      - Provider (gh, gl, bb)"
    echo "    CODACY_ORGANIZATION  - Organization name"
    echo "    CODACY_REPOSITORY    - Repository name"
    echo ""
    echo "  SonarQube:"
    echo "    SONAR_TOKEN          - SonarCloud authentication token"
    echo "    SONAR_ORGANIZATION   - SonarCloud organization key"
    echo "    SONAR_PROJECT_KEY    - Project key"
    echo ""
    echo "  Snyk:"
    echo "    SNYK_TOKEN           - Snyk API token"
    echo "    SNYK_ORG             - Snyk organization ID"
    echo ""
    echo "This script provides unified management for all quality analysis CLIs"
    echo "in the AI DevOps Framework."
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local cli="${2:-all}"
    shift 2 2>/dev/null || shift $# # Remove processed arguments

    case "$command" in
        "install")
            install_clis "$cli"
            ;;
        "init")
            init_clis "$cli"
            ;;
        "analyze")
            analyze_with_clis "$cli" "$@"
            ;;
        "status")
            show_cli_status "$cli"
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
