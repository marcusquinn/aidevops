#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Snyk Security Helper Script
# Comprehensive security scanning using Snyk CLI
# Managed by AI DevOps Framework
#
# Usage: ./snyk-helper.sh [command] [options]
# Commands:
#   test          - Run dependency vulnerability scan (SCA)
#   code          - Run source code security scan (SAST)
#   container     - Scan container images for vulnerabilities
#   iac           - Scan Infrastructure as Code files
#   monitor       - Create project snapshot for continuous monitoring
#   sbom          - Generate Software Bill of Materials
#   auth          - Authenticate with Snyk
#   status        - Check authentication and installation status
#   accounts      - List configured organizations
#   install       - Install Snyk CLI
#   help          - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Set strict mode
set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR="$script_dir"

repo_root="$(dirname "$SCRIPT_DIR")"
readonly REPO_ROOT="$repo_root"
readonly CONFIG_FILE="$REPO_ROOT/configs/snyk-config.json"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Common constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
# Error Messages
readonly ERROR_SNYK_NOT_INSTALLED="Snyk CLI is required but not installed"
readonly ERROR_NOT_AUTHENTICATED="Snyk CLI is not authenticated. Run 'snyk auth' or set SNYK_TOKEN"
readonly ERROR_CONFIG_MISSING="Configuration file not found"
readonly ERROR_ORG_NOT_FOUND="Organization not found in configuration"
readonly ERROR_SCAN_FAILED="Snyk scan failed"
readonly ERROR_ARGS_MISSING="Missing required arguments"
readonly ERROR_TARGET_REQUIRED="Target path or image is required"
readonly ERROR_FILE_NOT_FOUND="File or directory not found"

# Success Messages
readonly SUCCESS_SCAN_COMPLETE="Scan completed successfully"
readonly SUCCESS_MONITOR_CREATED="Project snapshot created for monitoring"
readonly SUCCESS_AUTH_COMPLETE="Authentication successful"
readonly SUCCESS_INSTALL_COMPLETE="Snyk CLI installed successfully"

# API Configuration (exported for external use)
export SNYK_API_BASE="https://api.snyk.io"

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

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

print_header() {
    local msg="$1"
    echo -e "${PURPLE}🔒 $msg${NC}"
    return 0
}

# ------------------------------------------------------------------------------
# DEPENDENCY CHECKING
# ------------------------------------------------------------------------------

check_snyk_installed() {
    if ! command -v snyk &> /dev/null; then
        return 1
    fi
    return 0
}

check_snyk_authenticated() {
    # Check if SNYK_TOKEN is set or if already authenticated
    if [[ -n "${SNYK_TOKEN:-}" ]]; then
        return 0
    fi
    
    # Check if authenticated via snyk auth
    if snyk auth check &> /dev/null 2>&1; then
        return 0
    fi
    
    # Try a simple API call to verify authentication
    if snyk config get api &> /dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

check_dependencies() {
    if ! check_snyk_installed; then
        print_error "$ERROR_SNYK_NOT_INSTALLED"
        print_info "Install Snyk CLI:"
        print_info "  macOS: brew tap snyk/tap && brew install snyk-cli"
        print_info "  npm: npm install -g snyk"
        print_info "  Binary: curl --compressed https://downloads.snyk.io/cli/stable/snyk-macos -o snyk && chmod +x snyk"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# CONFIGURATION LOADING
# ------------------------------------------------------------------------------

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    return 0
}

get_org_config() {
    local org_name="$1"
    
    if [[ -z "$org_name" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi
    
    if ! load_config; then
        print_warning "$ERROR_CONFIG_MISSING - using defaults"
        echo "{}"
        return 0
    fi
    
    local config
    if ! config=$(jq -r ".organizations.\"$org_name\"" "$CONFIG_FILE" 2>/dev/null); then
        print_warning "Failed to read configuration for $org_name"
        echo "{}"
        return 0
    fi
    
    if [[ "$config" == "null" ]]; then
        print_warning "$ERROR_ORG_NOT_FOUND: $org_name"
        echo "{}"
        return 0
    fi
    
    echo "$config"
    return 0
}

get_default_options() {
    if ! load_config; then
        echo ""
        return 0
    fi
    
    local severity_threshold
    severity_threshold=$(jq -r '.defaults.severity_threshold // "high"' "$CONFIG_FILE" 2>/dev/null)
    
    echo "--severity-threshold=$severity_threshold"
    return 0
}

# ------------------------------------------------------------------------------
# INSTALLATION
# ------------------------------------------------------------------------------

install_snyk() {
    print_header "Installing Snyk CLI"
    
    local os_type
    os_type=$(uname -s | tr '[:upper:]' '[:lower:]')
    
    case "$os_type" in
        "darwin")
            print_info "Detected macOS - installing via Homebrew..."
            if command -v brew &> /dev/null; then
                brew tap snyk/tap 2>/dev/null || true
                if brew install snyk-cli; then
                    print_success "$SUCCESS_INSTALL_COMPLETE"
                    return 0
                fi
            fi
            print_warning "Homebrew installation failed, trying npm..."
            # NOSONAR - merged nested if: check npm exists AND try install
            if command -v npm &> /dev/null && npm install -g snyk; then
                print_success "$SUCCESS_INSTALL_COMPLETE"
                return 0
            fi
            print_info "Downloading binary directly..."
            curl --compressed https://downloads.snyk.io/cli/stable/snyk-macos -o /usr/local/bin/snyk
            chmod +x /usr/local/bin/snyk
            ;;
        "linux")
            print_info "Detected Linux - installing via npm or binary..."
            # NOSONAR - npm scripts required for CLI binary installation
            if command -v npm &> /dev/null && npm install -g snyk; then
                print_success "$SUCCESS_INSTALL_COMPLETE"
                return 0
            fi
            print_info "Downloading binary directly..."
            curl --compressed https://downloads.snyk.io/cli/stable/snyk-linux -o /usr/local/bin/snyk
            chmod +x /usr/local/bin/snyk
            ;;
        *)
            print_error "Unsupported OS: $os_type"
            print_info "Please install manually: https://docs.snyk.io/snyk-cli/install-the-snyk-cli"
            return 1
            ;;
    esac
    
    if check_snyk_installed; then
        print_success "$SUCCESS_INSTALL_COMPLETE"
        snyk --version
        return 0
    else
        print_error "Installation failed"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# AUTHENTICATION
# ------------------------------------------------------------------------------

authenticate() {
    local token="${1:-}"
    
    print_header "Authenticating with Snyk"
    
    if [[ -n "$token" ]]; then
        print_info "Setting API token from argument..."
        export SNYK_TOKEN="$token"
        if snyk config set api="$token"; then
            print_success "$SUCCESS_AUTH_COMPLETE"
            return 0
        fi
    fi
    
    # Check if SNYK_TOKEN environment variable is set
    if [[ -n "${SNYK_TOKEN:-}" ]]; then
        print_info "Using SNYK_TOKEN environment variable..."
        if snyk config set api="$SNYK_TOKEN"; then
            print_success "$SUCCESS_AUTH_COMPLETE"
            return 0
        fi
    fi
    
    # Interactive OAuth authentication
    print_info "Starting OAuth authentication flow..."
    print_info "A browser window will open for authentication."
    
    if snyk auth; then
        print_success "$SUCCESS_AUTH_COMPLETE"
        return 0
    else
        print_error "Authentication failed"
        print_info "Get your API token from: https://app.snyk.io/account"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# STATUS & INFORMATION
# ------------------------------------------------------------------------------

show_status() {
    print_header "Snyk CLI Status"
    
    echo ""
    echo "Installation:"
    if check_snyk_installed; then
        local version
        version=$(snyk --version 2>/dev/null || echo "unknown")
        echo "  ✅ Snyk CLI installed: $version"
    else
        echo "  ❌ Snyk CLI not installed"
        return 1
    fi
    
    echo ""
    echo "Authentication:"
    if check_snyk_authenticated; then
        echo "  ✅ Authenticated with Snyk"
        # Try to get organization info
        if [[ -n "${SNYK_TOKEN:-}" ]]; then
            echo "  📋 Using SNYK_TOKEN environment variable"
        fi
        local configured_api
        configured_api=$(snyk config get api 2>/dev/null || echo "")
        if [[ -n "$configured_api" && "$configured_api" != "null" ]]; then
            echo "  📋 API token configured"
        fi
    else
        echo "  ❌ Not authenticated"
        echo "  💡 Run 'snyk auth' or set SNYK_TOKEN environment variable"
    fi
    
    echo ""
    echo "Configuration:"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  ✅ Configuration file found: $CONFIG_FILE"
        local orgs
        orgs=$(jq -r '.organizations | keys | join(", ")' "$CONFIG_FILE" 2>/dev/null || echo "none")
        echo "  📋 Configured organizations: $orgs"
    else
        echo "  ⚠️  No configuration file found"
        echo "  💡 Create: cp configs/snyk-config.json.txt configs/snyk-config.json"
    fi
    
    echo ""
    echo "Scan Capabilities:"
    echo "  🔍 Open Source (SCA): snyk test"
    echo "  🔍 Code (SAST): snyk code test"
    echo "  🐳 Container: snyk container test"
    echo "  📄 IaC: snyk iac test"
    echo "  🤖 MCP Server: snyk mcp"
    
    return 0
}

list_accounts() {
    print_header "Configured Snyk Organizations"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        echo ""
        jq -r '.organizations | to_entries[] | "  \(.key): \(.value.org_id // "no org_id")"' "$CONFIG_FILE" 2>/dev/null || print_warning "No organizations configured"
    else
        print_warning "$ERROR_CONFIG_MISSING"
        print_info "Create configuration: cp configs/snyk-config.json.txt configs/snyk-config.json"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# VULNERABILITY SCANNING
# ------------------------------------------------------------------------------

scan_dependencies() {
    local target="${1:-.}"
    local org_name="${2:-}"
    local extra_args="${3:-}"
    
    print_header "Running Dependency Vulnerability Scan (SCA)"
    
    if ! check_snyk_authenticated; then
        print_error "$ERROR_NOT_AUTHENTICATED"
        return 1
    fi
    
    local snyk_args=()
    
    # Add organization if specified
    if [[ -n "$org_name" ]]; then
        local config
        config=$(get_org_config "$org_name")
        local org_id
        org_id=$(echo "$config" | jq -r '.org_id // ""')
        if [[ -n "$org_id" && "$org_id" != "null" ]]; then
            snyk_args+=("--org=$org_id")
        fi
    fi
    
    # Add default options
    local defaults
    defaults=$(get_default_options)
    if [[ -n "$defaults" ]]; then
        # shellcheck disable=SC2206
        snyk_args+=($defaults)
    fi
    
    # Add extra arguments
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        snyk_args+=($extra_args)
    fi
    
    print_info "Scanning: $target"
    print_info "Options: ${snyk_args[*]:-none}"
    
    if [[ "$target" != "." ]] && [[ ! -e "$target" ]]; then
        print_error "$ERROR_FILE_NOT_FOUND: $target"
        return 1
    fi
    
    local exit_code=0
    if snyk test "$target" "${snyk_args[@]}" 2>&1; then
        print_success "$SUCCESS_SCAN_COMPLETE - No vulnerabilities found"
    else
        exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            print_warning "Vulnerabilities found - review results above"
        else
            print_error "$ERROR_SCAN_FAILED (exit code: $exit_code)"
        fi
    fi
    
    return $exit_code
}

scan_code() {
    local target="${1:-.}"
    local org_name="${2:-}"
    local extra_args="${3:-}"
    
    print_header "Running Source Code Security Scan (SAST)"
    
    if ! check_snyk_authenticated; then
        print_error "$ERROR_NOT_AUTHENTICATED"
        return 1
    fi
    
    local snyk_args=()
    
    # Add organization if specified
    if [[ -n "$org_name" ]]; then
        local config
        config=$(get_org_config "$org_name")
        local org_id
        org_id=$(echo "$config" | jq -r '.org_id // ""')
        if [[ -n "$org_id" && "$org_id" != "null" ]]; then
            snyk_args+=("--org=$org_id")
        fi
    fi
    
    # Add extra arguments
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        snyk_args+=($extra_args)
    fi
    
    print_info "Scanning: $target"
    print_info "Options: ${snyk_args[*]:-none}"
    
    if [[ "$target" != "." ]] && [[ ! -e "$target" ]]; then
        print_error "$ERROR_FILE_NOT_FOUND: $target"
        return 1
    fi
    
    local exit_code=0
    if snyk code test "$target" "${snyk_args[@]}" 2>&1; then
        print_success "$SUCCESS_SCAN_COMPLETE - No code vulnerabilities found"
    else
        exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            print_warning "Code vulnerabilities found - review results above"
        else
            print_error "$ERROR_SCAN_FAILED (exit code: $exit_code)"
        fi
    fi
    
    return $exit_code
}

scan_container() {
    local image="$1"
    local org_name="${2:-}"
    local extra_args="${3:-}"
    
    if [[ -z "$image" ]]; then
        print_error "$ERROR_TARGET_REQUIRED"
        print_info "Usage: snyk-helper.sh container <image:tag> [org] [options]"
        return 1
    fi
    
    print_header "Running Container Security Scan"
    
    if ! check_snyk_authenticated; then
        print_error "$ERROR_NOT_AUTHENTICATED"
        return 1
    fi
    
    local snyk_args=()
    
    # Add organization if specified
    if [[ -n "$org_name" ]]; then
        local config
        config=$(get_org_config "$org_name")
        local org_id
        org_id=$(echo "$config" | jq -r '.org_id // ""')
        if [[ -n "$org_id" && "$org_id" != "null" ]]; then
            snyk_args+=("--org=$org_id")
        fi
    fi
    
    # Add default severity threshold
    local defaults
    defaults=$(get_default_options)
    if [[ -n "$defaults" ]]; then
        # shellcheck disable=SC2206
        snyk_args+=($defaults)
    fi
    
    # Add extra arguments
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        snyk_args+=($extra_args)
    fi
    
    print_info "Scanning image: $image"
    print_info "Options: ${snyk_args[*]:-none}"
    
    local exit_code=0
    if snyk container test "$image" "${snyk_args[@]}" 2>&1; then
        print_success "$SUCCESS_SCAN_COMPLETE - No container vulnerabilities found"
    else
        exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            print_warning "Container vulnerabilities found - review results above"
        else
            print_error "$ERROR_SCAN_FAILED (exit code: $exit_code)"
        fi
    fi
    
    return $exit_code
}

scan_iac() {
    local target="${1:-.}"
    local org_name="${2:-}"
    local extra_args="${3:-}"
    
    print_header "Running Infrastructure as Code Scan"
    
    if ! check_snyk_authenticated; then
        print_error "$ERROR_NOT_AUTHENTICATED"
        return 1
    fi
    
    local snyk_args=()
    
    # Add organization if specified
    if [[ -n "$org_name" ]]; then
        local config
        config=$(get_org_config "$org_name")
        local org_id
        org_id=$(echo "$config" | jq -r '.org_id // ""')
        if [[ -n "$org_id" && "$org_id" != "null" ]]; then
            snyk_args+=("--org=$org_id")
        fi
    fi
    
    # Add default severity threshold
    local defaults
    defaults=$(get_default_options)
    if [[ -n "$defaults" ]]; then
        # shellcheck disable=SC2206
        snyk_args+=($defaults)
    fi
    
    # Add extra arguments
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        snyk_args+=($extra_args)
    fi
    
    print_info "Scanning: $target"
    print_info "Options: ${snyk_args[*]:-none}"
    
    if [[ "$target" != "." ]] && [[ ! -e "$target" ]]; then
        print_error "$ERROR_FILE_NOT_FOUND: $target"
        return 1
    fi
    
    local exit_code=0
    if snyk iac test "$target" "${snyk_args[@]}" 2>&1; then
        print_success "$SUCCESS_SCAN_COMPLETE - No IaC misconfigurations found"
    else
        exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            print_warning "IaC misconfigurations found - review results above"
        else
            print_error "$ERROR_SCAN_FAILED (exit code: $exit_code)"
        fi
    fi
    
    return $exit_code
}

# ------------------------------------------------------------------------------
# MONITORING
# ------------------------------------------------------------------------------

create_monitor() {
    local target="${1:-.}"
    local org_name="${2:-}"
    local project_name="${3:-}"
    local extra_args="${4:-}"
    
    print_header "Creating Project Snapshot for Monitoring"
    
    if ! check_snyk_authenticated; then
        print_error "$ERROR_NOT_AUTHENTICATED"
        return 1
    fi
    
    local snyk_args=()
    
    # Add organization if specified
    if [[ -n "$org_name" ]]; then
        local config
        config=$(get_org_config "$org_name")
        local org_id
        org_id=$(echo "$config" | jq -r '.org_id // ""')
        if [[ -n "$org_id" && "$org_id" != "null" ]]; then
            snyk_args+=("--org=$org_id")
        fi
    fi
    
    # Add project name if specified
    if [[ -n "$project_name" ]]; then
        snyk_args+=("--project-name=$project_name")
    fi
    
    # Add extra arguments
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        snyk_args+=($extra_args)
    fi
    
    print_info "Creating snapshot for: $target"
    print_info "Options: ${snyk_args[*]:-none}"
    
    if snyk monitor "$target" "${snyk_args[@]}" 2>&1; then
        print_success "$SUCCESS_MONITOR_CREATED"
        print_info "View results at: https://app.snyk.io"
        return 0
    else
        print_error "Failed to create monitoring snapshot"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# SBOM GENERATION
# ------------------------------------------------------------------------------

generate_sbom() {
    local target="${1:-.}"
    local format="${2:-cyclonedx1.4+json}"
    local output="${3:-}"
    
    print_header "Generating Software Bill of Materials (SBOM)"
    
    if ! check_snyk_authenticated; then
        print_error "$ERROR_NOT_AUTHENTICATED"
        return 1
    fi
    
    local snyk_args=("--format=$format")
    
    if [[ -n "$output" ]]; then
        snyk_args+=("--file=$output")
    fi
    
    print_info "Generating SBOM for: $target"
    print_info "Format: $format"
    
    if [[ "$target" != "." ]] && [[ ! -e "$target" ]]; then
        print_error "$ERROR_FILE_NOT_FOUND: $target"
        return 1
    fi
    
    if snyk sbom "$target" "${snyk_args[@]}" 2>&1; then
        print_success "SBOM generated successfully"
        if [[ -n "$output" ]]; then
            print_info "Output saved to: $output"
        fi
        return 0
    else
        print_error "Failed to generate SBOM"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# FULL SECURITY SCAN
# ------------------------------------------------------------------------------

full_scan() {
    local target="${1:-.}"
    local org_name="${2:-}"
    
    print_header "Running Full Security Scan"
    print_info "This will run SCA, Code, and IaC scans"
    
    local has_issues=false
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "1. Dependency Scan (SCA)"
    echo "═══════════════════════════════════════════════════════════════"
    if ! scan_dependencies "$target" "$org_name"; then
        has_issues=true
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "2. Source Code Scan (SAST)"
    echo "═══════════════════════════════════════════════════════════════"
    if ! scan_code "$target" "$org_name"; then
        has_issues=true
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "3. Infrastructure as Code Scan"
    echo "═══════════════════════════════════════════════════════════════"
    if ! scan_iac "$target" "$org_name"; then
        has_issues=true
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "SCAN SUMMARY"
    echo "═══════════════════════════════════════════════════════════════"
    
    if $has_issues; then
        print_warning "Security issues were found - review results above"
        return 1
    else
        print_success "All scans completed - no security issues found"
        return 0
    fi
    return 0
}

# ------------------------------------------------------------------------------
# MCP SERVER
# ------------------------------------------------------------------------------

start_mcp_server() {
    print_header "Starting Snyk MCP Server"
    
    if ! check_snyk_installed; then
        print_error "$ERROR_SNYK_NOT_INSTALLED"
        return 1
    fi
    
    if ! check_snyk_authenticated; then
        print_warning "Not authenticated - some features may not work"
    fi
    
    print_info "Starting MCP server..."
    print_info "Available tools: snyk_sca_scan, snyk_code_scan, snyk_iac_scan, snyk_container_scan, snyk_sbom_scan"
    
    # The Snyk MCP server runs as: snyk mcp
    exec snyk mcp
    return 0
}

# ------------------------------------------------------------------------------
# HELP
# ------------------------------------------------------------------------------

show_help() {
    cat << 'EOF'
Snyk Security Helper Script
Usage: ./snyk-helper.sh [command] [options]

SECURITY SCANNING:
  test [path] [org] [opts]          - Scan dependencies for vulnerabilities (SCA)
  code [path] [org] [opts]          - Scan source code for vulnerabilities (SAST)
  container <image> [org] [opts]    - Scan container images
  iac [path] [org] [opts]           - Scan Infrastructure as Code
  full [path] [org]                 - Run all scans (SCA + SAST + IaC)

MONITORING & REPORTING:
  monitor [path] [org] [name]       - Create project snapshot for monitoring
  sbom [path] [format] [output]     - Generate Software Bill of Materials

AUTHENTICATION & STATUS:
  auth [token]                      - Authenticate with Snyk
  status                            - Check installation and auth status
  accounts                          - List configured organizations

INSTALLATION:
  install                           - Install Snyk CLI

MCP INTEGRATION:
  mcp                               - Start Snyk MCP server for AI assistants

GENERAL:
  help                              - Show this help message

EXAMPLES:
  ./snyk-helper.sh test                           # Scan current directory
  ./snyk-helper.sh test ./my-project my-org       # Scan with organization
  ./snyk-helper.sh code . --json                  # Code scan with JSON output
  ./snyk-helper.sh container nginx:latest         # Scan container image
  ./snyk-helper.sh iac ./terraform/               # Scan Terraform files
  ./snyk-helper.sh full .                         # Run all security scans
  ./snyk-helper.sh monitor . my-org my-project    # Create monitoring snapshot
  ./snyk-helper.sh sbom . cyclonedx1.4+json sbom.json

SCAN TYPES:
  SCA (test)      - Open source dependency vulnerabilities
  SAST (code)     - Source code security issues
  Container       - Container image vulnerabilities + base image recommendations
  IaC             - Infrastructure as Code misconfigurations

SEVERITY LEVELS:
  --severity-threshold=low|medium|high|critical

OUTPUT FORMATS:
  --json              - JSON output for parsing
  --sarif             - SARIF format for CI/CD integration
  --html              - HTML report

ENVIRONMENT VARIABLES:
  SNYK_TOKEN          - API token for authentication
  SNYK_ORG            - Default organization ID
  SNYK_API            - Custom API URL (for regional/self-hosted)

CONFIGURATION:
  File: configs/snyk-config.json
  Template: cp configs/snyk-config.json.txt configs/snyk-config.json

For more information:
  - Documentation: https://docs.snyk.io/snyk-cli
  - API Token: https://app.snyk.io/account
  - Status Page: https://status.snyk.io/
EOF
    return 0
}

# ------------------------------------------------------------------------------
# MAIN COMMAND HANDLER
# ------------------------------------------------------------------------------

main() {
    local command="${1:-help}"
    shift || true
    
    # Commands that don't require snyk to be installed
    case "$command" in
        "install")
            install_snyk
            return $?
            ;;
        "help"|"-h"|"--help")
            show_help
            return 0
            ;;
        *)
            # Other commands handled below after dependency check
            ;;
    esac
    
    # Check dependencies for other commands
    if ! check_dependencies; then
        return 1
    fi
    
    case "$command" in
        "test"|"sca"|"dependencies")
            scan_dependencies "$@"
            ;;
        "code"|"sast")
            scan_code "$@"
            ;;
        "container"|"docker"|"image")
            scan_container "$@"
            ;;
        "iac"|"infrastructure")
            scan_iac "$@"
            ;;
        "full"|"all")
            full_scan "$@"
            ;;
        "monitor")
            create_monitor "$@"
            ;;
        "sbom")
            generate_sbom "$@"
            ;;
        "auth"|"login")
            authenticate "$@"
            ;;
        "status")
            show_status
            ;;
        "accounts"|"orgs"|"organizations")
            list_accounts
            ;;
        "mcp")
            start_mcp_server
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            print_info "Use './snyk-helper.sh help' for usage information"
            return 1
            ;;
    esac
    
    return $?
}

# Execute main function
main "$@"
