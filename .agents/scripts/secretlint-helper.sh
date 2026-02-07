#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Secretlint Integration Script
# Pluggable linting tool to prevent committing credentials and secrets
#
# Usage: ./secretlint-helper.sh [command] [options]
# Commands:
#   install     - Install Secretlint and recommended rules
#   init        - Initialize project configuration
#   scan        - Scan for secrets (alias for lint)
#   lint        - Lint files for secrets
#   mask        - Mask secrets in a file
#   status      - Check installation and configuration
#   fix         - Mask secrets and fix files in place
#   quick       - Quick scan without installation (npx)
#   docker      - Run scan via Docker
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT
# Reference: https://github.com/secretlint/secretlint

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Common constants
readonly SECRETLINT_CONFIG_FILE=".secretlintrc.json"
readonly SECRETLINT_IGNORE_FILE=".secretlintignore"
readonly DEFAULT_GLOB_PATTERN="**/*"

# Print functions
print_header() {
    local message="$1"
    echo -e "${PURPLE}🔐 $message${NC}"
    return 0
}

print_secret() {
    local message="$1"
    echo -e "${CYAN}🛡️  $message${NC}"
    return 0
}

# Check if Secretlint is installed
check_secretlint_installed() {
    if command -v secretlint &> /dev/null; then
        local version
        version=$(secretlint --version 2>/dev/null || echo "unknown")
        print_success "Secretlint installed: v$version"
        return 0
    elif [[ -f "node_modules/.bin/secretlint" ]]; then
        local version
        version=$(./node_modules/.bin/secretlint --version 2>/dev/null || echo "unknown")
        print_success "Secretlint installed (local): v$version"
        return 0
    else
        print_warning "Secretlint not found"
        return 1
    fi
}

# Check if required rule presets are installed
# Returns: 0=all rules installed, 1=missing rules, 2=no config
check_rules_installed() {
    local config_file="${1:-$SECRETLINT_CONFIG_FILE}"
    
    if [[ ! -f "$config_file" ]]; then
        return 2
    fi
    
    # Extract rule IDs from config
    local missing_rules=()
    
    # Check for preset-recommend (most common)
    if grep -q "secretlint-rule-preset-recommend" "$config_file" \
        && ! npm list @secretlint/secretlint-rule-preset-recommend &>/dev/null \
        && ! npm list -g @secretlint/secretlint-rule-preset-recommend &>/dev/null; then
        missing_rules+=("@secretlint/secretlint-rule-preset-recommend")
    fi
    
    # Check for pattern rule
    if grep -q "secretlint-rule-pattern" "$config_file" \
        && ! npm list @secretlint/secretlint-rule-pattern &>/dev/null \
        && ! npm list -g @secretlint/secretlint-rule-pattern &>/dev/null; then
        missing_rules+=("@secretlint/secretlint-rule-pattern")
    fi
    
    if [[ ${#missing_rules[@]} -gt 0 ]]; then
        print_error "Missing required secretlint rules:"
        for rule in "${missing_rules[@]}"; do
            echo "  - $rule"
        done
        print_info "Install with: npm install --save-dev ${missing_rules[*]}"
        return 1
    fi
    
    return 0
}

# Validate secretlint installation (binary + rules)
validate_secretlint_setup() {
    local has_issues=0
    
    # Check binary
    if ! check_secretlint_installed; then
        has_issues=1
    fi
    
    # Check rules - exit code 1 means missing rules, exit code 2 means no config (ok)
    check_rules_installed
    local rules_exit=$?
    if [[ $rules_exit -eq 1 ]]; then
        has_issues=1
    fi
    
    return $has_issues
}

# Check if Docker is available
check_docker_available() {
    if command -v docker &> /dev/null; then
        print_success "Docker available"
        return 0
    else
        print_warning "Docker not found"
        return 1
    fi
}

# Get secretlint command (global or local)
get_secretlint_cmd() {
    if command -v secretlint &> /dev/null; then
        echo "secretlint"
    elif [[ -f "node_modules/.bin/secretlint" ]]; then
        echo "./node_modules/.bin/secretlint"
    else
        echo "npx secretlint"
    fi
    return 0
}

# Install Secretlint and recommended rules
install_secretlint() {
    local install_type="${1:-local}"
    
    print_header "Installing Secretlint"
    
    # Check for Node.js
    if ! command -v node &> /dev/null; then
        print_error "Node.js is required. Please install Node.js 20+ first."
        print_info "Alternatively, use Docker: $0 docker scan"
        return 1
    fi
    
    local node_version
    node_version=$(node -v | sed 's/v//' | cut -d. -f1)
    if [[ $node_version -lt 18 ]]; then
        print_warning "Node.js 20+ recommended. Current version: $(node -v)"
    fi
    
    case "$install_type" in
        "global")
            print_info "Installing Secretlint globally..."
            npm install -g secretlint @secretlint/secretlint-rule-preset-recommend
            ;;
        "local"|*)
            print_info "Installing Secretlint locally..."
            npm install --save-dev secretlint @secretlint/secretlint-rule-preset-recommend
            ;;
    esac
    
    if [[ $? -eq 0 ]]; then
        print_success "Secretlint installed successfully"
        
        # Initialize if config doesn't exist
        if [[ ! -f "$SECRETLINT_CONFIG_FILE" ]]; then
            print_info "Initializing configuration..."
            init_secretlint_config
        fi
        
        return 0
    else
        print_error "Installation failed"
        return 1
    fi
}

# Install additional rules
install_additional_rules() {
    local rules="${1:-pattern}"
    
    print_header "Installing Additional Secretlint Rules"
    
    local npm_cmd="npm install --save-dev"
    if command -v secretlint &> /dev/null; then
        npm_cmd="npm install -g"
    fi
    
    case "$rules" in
        "pattern")
            print_info "Installing custom pattern rule..."
            $npm_cmd @secretlint/secretlint-rule-pattern
            ;;
        "sarif")
            print_info "Installing SARIF formatter..."
            $npm_cmd @secretlint/secretlint-formatter-sarif
            ;;
        "all")
            print_info "Installing all recommended additional rules..."
            $npm_cmd @secretlint/secretlint-rule-pattern \
                     @secretlint/secretlint-rule-no-k8s-kind-secret \
                     @secretlint/secretlint-rule-no-homedir \
                     @secretlint/secretlint-rule-no-dotenv \
                     @secretlint/secretlint-formatter-sarif
            ;;
        *)
            print_info "Installing rule: $rules"
            $npm_cmd "$rules"
            ;;
    esac
    
    if [[ $? -eq 0 ]]; then
        print_success "Additional rules installed"
        return 0
    else
        print_error "Failed to install rules"
        return 1
    fi
}

# Initialize Secretlint configuration
init_secretlint_config() {
    print_header "Initializing Secretlint Configuration"
    
    local cmd
    cmd=$(get_secretlint_cmd)
    
    if [[ -f "$SECRETLINT_CONFIG_FILE" ]]; then
        print_warning "Configuration already exists: $SECRETLINT_CONFIG_FILE"
        print_info "Use 'secretlint --init' to overwrite"
        return 0
    fi
    
    # Try to use secretlint --init
    if $cmd --init &>/dev/null; then
        print_success "Configuration initialized: $SECRETLINT_CONFIG_FILE"
    else
        # Manually create comprehensive config
        print_info "Creating comprehensive configuration..."
        create_comprehensive_config
    fi
    
    # Create ignore file if it doesn't exist
    if [[ ! -f "$SECRETLINT_IGNORE_FILE" ]]; then
        create_ignore_file
    fi
    
    return 0
}

# Create comprehensive configuration
create_comprehensive_config() {
    cat > "$SECRETLINT_CONFIG_FILE" << 'EOF'
{
  "rules": [
    {
      "id": "@secretlint/secretlint-rule-preset-recommend",
      "rules": [
        {
          "id": "@secretlint/secretlint-rule-aws",
          "options": {
            "allows": []
          }
        },
        {
          "id": "@secretlint/secretlint-rule-github",
          "options": {
            "allows": []
          }
        },
        {
          "id": "@secretlint/secretlint-rule-privatekey"
        },
        {
          "id": "@secretlint/secretlint-rule-basicauth"
        },
        {
          "id": "@secretlint/secretlint-rule-slack"
        },
        {
          "id": "@secretlint/secretlint-rule-sendgrid"
        },
        {
          "id": "@secretlint/secretlint-rule-openai"
        },
        {
          "id": "@secretlint/secretlint-rule-anthropic"
        },
        {
          "id": "@secretlint/secretlint-rule-gcp"
        },
        {
          "id": "@secretlint/secretlint-rule-npm"
        },
        {
          "id": "@secretlint/secretlint-rule-shopify"
        },
        {
          "id": "@secretlint/secretlint-rule-linear"
        },
        {
          "id": "@secretlint/secretlint-rule-1password"
        },
        {
          "id": "@secretlint/secretlint-rule-database-connection-string"
        }
      ]
    }
  ]
}
EOF
    print_success "Created comprehensive configuration: $SECRETLINT_CONFIG_FILE"
    return 0
}

# Create ignore file
create_ignore_file() {
    cat > "$SECRETLINT_IGNORE_FILE" << 'EOF'
# Secretlint Ignore File
# Uses .gitignore syntax

# Dependencies
**/node_modules/**
**/vendor/**
**/.venv/**
**/venv/**

# Build outputs
**/dist/**
**/build/**
**/.next/**
**/out/**

# IDE and editor
**/.idea/**
**/.vscode/**
**/.vs/**
*.swp
*.swo

# Git
**/.git/**

# Test fixtures (may contain fake secrets for testing)
**/test/fixtures/**
**/tests/fixtures/**
**/__tests__/fixtures/**
**/testdata/**

# Generated files
**/*.min.js
**/*.min.css
**/package-lock.json
**/pnpm-lock.yaml
**/yarn.lock
**/composer.lock
**/Gemfile.lock
**/Cargo.lock
**/poetry.lock

# Documentation and examples (review manually if needed)
**/docs/**
**/examples/**

# Binary files
**/*.png
**/*.jpg
**/*.jpeg
**/*.gif
**/*.ico
**/*.svg
**/*.woff
**/*.woff2
**/*.ttf
**/*.eot
**/*.pdf
**/*.zip
**/*.tar
**/*.gz
**/*.rar

# Logs
**/*.log
**/logs/**

# Coverage reports
**/coverage/**
**/.nyc_output/**

# Cache
**/.cache/**
**/.tmp/**
**/tmp/**
EOF
    print_success "Created ignore file: $SECRETLINT_IGNORE_FILE"
    return 0
}

# Run Secretlint scan
run_secretlint_scan() {
    local target="${1:-$DEFAULT_GLOB_PATTERN}"
    local format="${2:-stylish}"
    local output_file="$3"
    local extra_args="$4"
    
    print_header "Running Secretlint Scan"
    
    # Validate target pattern for dangerous characters
    if [[ "$target" == *";"* ]] || [[ "$target" == *"|"* ]] || [[ "$target" == *"&"* ]] || [[ "$target" == *"\`"* ]]; then
        print_error "Invalid target pattern: contains forbidden characters"
        return 1
    fi
    
    local cmd
    cmd=$(get_secretlint_cmd)
    
    # Check if configuration exists
    if [[ ! -f "$SECRETLINT_CONFIG_FILE" ]]; then
        print_warning "No configuration found. Initializing..."
        init_secretlint_config
    fi
    
    # Validate that required rules are installed
    if ! check_rules_installed "$SECRETLINT_CONFIG_FILE"; then
        print_error "Secretlint rules not properly installed. Run: $0 install"
        return 2
    fi
    
    # Build command array for safe execution
    local -a cmd_array
    read -ra cmd_array <<< "$cmd"
    cmd_array+=("$target" "--format" "$format")
    
    if [[ -n "$output_file" ]]; then
        cmd_array+=("--output" "$output_file")
    fi
    
    # Handle extra_args safely by splitting on spaces (limited use case)
    if [[ -n "$extra_args" ]]; then
        read -ra extra_array <<< "$extra_args"
        cmd_array+=("${extra_array[@]}")
    fi
    
    print_info "Scanning: $target"
    print_info "Format: $format"
    print_info "Command: ${cmd_array[*]}"
    echo ""
    
    # Execute scan using array (safe from injection)
    "${cmd_array[@]}"
    local exit_code=$?
    
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        print_success "No secrets detected! Your code is clean."
    elif [[ $exit_code -eq 1 ]]; then
        print_error "Secrets detected! Please review and remove/rotate exposed credentials."
        print_info "Tip: Use 'secretlint-disable-line' comments to ignore false positives"
    elif [[ $exit_code -eq 2 ]]; then
        print_error "Scan failed - configuration or installation error"
        print_info "Run: $0 status (to diagnose)"
        print_info "Run: $0 install (to fix installation)"
    else
        print_error "Scan failed with error code: $exit_code"
    fi
    
    return $exit_code
}

# Run quick scan via npx (no installation)
run_quick_scan() {
    local target="${1:-$DEFAULT_GLOB_PATTERN}"
    
    # Validate target pattern for dangerous characters
    if [[ "$target" == *";"* ]] || [[ "$target" == *"|"* ]] || [[ "$target" == *"&"* ]] || [[ "$target" == *"\`"* ]]; then
        print_error "Invalid target pattern: contains forbidden characters"
        return 1
    fi
    
    print_header "Quick Secretlint Scan (via npx)"
    print_info "This requires no installation"
    
    npx @secretlint/quick-start "$target"
}

# Run scan via Docker
run_docker_scan() {
    local target="${1:-$DEFAULT_GLOB_PATTERN}"
    local extra_args="$2"
    
    print_header "Running Secretlint via Docker"
    
    # Validate target pattern for dangerous characters
    if [[ "$target" == *";"* ]] || [[ "$target" == *"|"* ]] || [[ "$target" == *"&"* ]] || [[ "$target" == *"\`"* ]]; then
        print_error "Invalid target pattern: contains forbidden characters"
        return 1
    fi
    
    if ! check_docker_available; then
        print_error "Docker is required for this command"
        return 1
    fi
    
    local current_dir
    current_dir=$(pwd)
    
    # Build command array for safe execution
    local -a cmd_array=(
        "docker" "run"
        "-v" "${current_dir}:${current_dir}"
        "-w" "$current_dir"
        "--rm" "-it"
        "secretlint/secretlint"
        "secretlint" "$target"
    )
    
    # Handle extra_args safely
    if [[ -n "$extra_args" ]]; then
        read -ra extra_array <<< "$extra_args"
        cmd_array+=("${extra_array[@]}")
    fi
    
    print_info "Command: ${cmd_array[*]}"
    echo ""
    
    # Execute using array (safe from injection)
    "${cmd_array[@]}"
}

# Mask secrets in a file
mask_secrets() {
    local input_file="$1"
    local output_file="${2:-$input_file}"
    
    print_header "Masking Secrets"
    
    if [[ -z "$input_file" ]]; then
        print_error "Input file required"
        print_info "Usage: $0 mask <input-file> [output-file]"
        return 1
    fi
    
    if [[ ! -f "$input_file" ]]; then
        print_error "File not found: $input_file"
        return 1
    fi
    
    local cmd
    cmd=$(get_secretlint_cmd)
    
    print_info "Input: $input_file"
    print_info "Output: $output_file"
    
    $cmd "$input_file" --format=mask-result --output="$output_file"
    
    if [[ $? -eq 0 ]]; then
        print_success "Secrets masked successfully"
        return 0
    else
        print_error "Failed to mask secrets"
        return 1
    fi
}

# Show status
show_status() {
    print_header "Secretlint Status"
    echo ""
    
    # Check installation
    print_info "Installation:"
    check_secretlint_installed
    check_docker_available
    echo ""
    
    # Check Node.js
    print_info "Node.js:"
    if command -v node &> /dev/null; then
        print_success "Node.js: $(node -v)"
    else
        print_warning "Node.js: Not installed"
    fi
    echo ""
    
    # Check configuration
    print_info "Configuration:"
    if [[ -f "$SECRETLINT_CONFIG_FILE" ]]; then
        print_success "Config file: $SECRETLINT_CONFIG_FILE"
        
        # Count rules
        if command -v jq &> /dev/null; then
            local rules_count
            rules_count=$(jq -r '.rules | length' "$SECRETLINT_CONFIG_FILE" 2>/dev/null || echo "unknown")
            print_info "Configured rule presets: $rules_count"
        fi
    else
        print_warning "Config file: Not found"
        print_info "Run: $0 init"
    fi
    
    if [[ -f "$SECRETLINT_IGNORE_FILE" ]]; then
        print_success "Ignore file: $SECRETLINT_IGNORE_FILE"
        local ignore_count
        ignore_count=$(grep -cv '^#\|^$' "$SECRETLINT_IGNORE_FILE" 2>/dev/null || echo "0")
        print_info "Ignore patterns: $ignore_count"
    else
        print_warning "Ignore file: Not found"
    fi
    echo ""
    
    # Validate rule installation
    print_info "Rule Installation:"
    if [[ -f "$SECRETLINT_CONFIG_FILE" ]]; then
        if check_rules_installed "$SECRETLINT_CONFIG_FILE"; then
            print_success "All configured rules are installed"
        fi
    else
        print_warning "No config file - cannot validate rules"
    fi
    echo ""
    
    # Show available rules in preset
    print_info "Recommended Rules (preset-recommend):"
    echo "  - AWS credentials (Access Key, Secret Key, Account ID)"
    echo "  - GCP credentials"
    echo "  - GitHub tokens (PAT, OAuth, App)"
    echo "  - npm tokens"
    echo "  - Private keys (RSA, DSA, EC, OpenSSH)"
    echo "  - Basic auth in URLs"
    echo "  - Slack tokens and webhooks"
    echo "  - SendGrid API keys"
    echo "  - Shopify API keys"
    echo "  - OpenAI API keys"
    echo "  - Anthropic/Claude API keys"
    echo "  - Linear API keys"
    echo "  - 1Password service account tokens"
    echo "  - Database connection strings"
    echo ""
    
    return 0
}

# Generate SARIF output
generate_sarif() {
    local target="${1:-$DEFAULT_GLOB_PATTERN}"
    local output_file="${2:-secretlint-results.sarif}"
    
    print_header "Generating SARIF Output"
    
    # Check if SARIF formatter is installed
    if ! npm list @secretlint/secretlint-formatter-sarif &>/dev/null; then
        print_info "Installing SARIF formatter..."
        npm install --save-dev @secretlint/secretlint-formatter-sarif
    fi
    
    local cmd
    cmd=$(get_secretlint_cmd)
    
    $cmd "$target" --format @secretlint/secretlint-formatter-sarif > "$output_file"
    
    if [[ $? -eq 0 ]]; then
        print_success "SARIF output saved: $output_file"
        return 0
    else
        print_error "Failed to generate SARIF output"
        return 1
    fi
}

# Pre-commit hook setup
setup_precommit_hook() {
    print_header "Setting Up Pre-commit Hook"
    
    local hook_file=".git/hooks/pre-commit"
    local hook_dir=".git/hooks"
    
    if [[ ! -d ".git" ]]; then
        print_error "Not a git repository"
        return 1
    fi
    
    mkdir -p "$hook_dir"
    
    # Check if hook already exists
    if [[ -f "$hook_file" ]]; then
        if grep -q "secretlint" "$hook_file"; then
            print_warning "Secretlint hook already configured"
            return 0
        else
            print_warning "Pre-commit hook exists. Adding Secretlint..."
            # Append to existing hook
            cat >> "$hook_file" << 'EOF'

# Secretlint - Secret Detection
FILES=$(git diff --cached --name-only --diff-filter=ACMR | sed 's| |\\ |g')
[ -z "$FILES" ] && exit 0

echo "Running Secretlint..."
echo "$FILES" | xargs npx secretlint
RET=$?
if [ $RET -ne 0 ]; then
    echo "Secretlint found potential secrets. Please review before committing."
    exit 1
fi
EOF
        fi
    else
        # Create new hook
        cat > "$hook_file" << 'EOF'
#!/bin/sh
# Pre-commit hook with Secretlint integration

# Secretlint - Secret Detection
FILES=$(git diff --cached --name-only --diff-filter=ACMR | sed 's| |\\ |g')
[ -z "$FILES" ] && exit 0

echo "Running Secretlint..."
echo "$FILES" | xargs npx secretlint
RET=$?
if [ $RET -ne 0 ]; then
    echo "Secretlint found potential secrets. Please review before committing."
    exit 1
fi

exit 0
EOF
    fi
    
    chmod +x "$hook_file"
    print_success "Pre-commit hook configured: $hook_file"
    
    return 0
}

# Setup with Husky + lint-staged
setup_husky_integration() {
    print_header "Setting Up Husky + lint-staged Integration"
    
    if [[ ! -f "package.json" ]]; then
        print_error "package.json not found. Initialize npm project first."
        return 1
    fi
    
    print_info "Installing Husky and lint-staged..."
    npx husky-init 2>/dev/null || npm install husky --save-dev
    npm install lint-staged --save-dev
    
    # Initialize Husky
    npx husky install
    
    # Add pre-commit hook
    npx husky add .husky/pre-commit "npx --no-install lint-staged"
    
    # Update package.json with lint-staged config
    print_info "Adding lint-staged configuration to package.json..."
    
    if command -v jq &> /dev/null; then
        local tmp_file
        tmp_file=$(mktemp)
        jq '. + {"lint-staged": {"*": ["secretlint"]}}' package.json > "$tmp_file" && mv "$tmp_file" package.json
        print_success "Added lint-staged configuration"
    else
        print_warning "jq not available. Please add manually to package.json:"
        echo '  "lint-staged": {'
        echo '    "*": ["secretlint"]'
        echo '  }'
    fi
    
    print_success "Husky + lint-staged configured"
    
    return 0
}

# Show help
show_help() {
    print_header "Secretlint Helper - Secret Detection Tool"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  install [local|global]   - Install Secretlint and recommended rules"
    echo "  install-rules [rule]     - Install additional rules (pattern|sarif|all|<pkg>)"
    echo "  init                     - Initialize project configuration"
    echo "  scan [target] [format]   - Scan files for secrets"
    echo "  lint [target] [format]   - Alias for scan"
    echo "  quick [target]           - Quick scan via npx (no install)"
    echo "  docker [target]          - Scan via Docker"
    echo "  mask <file> [output]     - Mask secrets in a file"
    echo "  sarif [target] [output]  - Generate SARIF output"
    echo "  hook                     - Setup git pre-commit hook"
    echo "  husky                    - Setup Husky + lint-staged"
    echo "  status                   - Show installation and configuration status"
    echo "  help                     - Show this help message"
    echo ""
    echo "Formats: stylish (default), json, compact, table, sarif, mask-result"
    echo ""
    echo "Examples:"
    echo "  $0 install               # Install locally"
    echo "  $0 init                  # Initialize configuration"
    echo "  $0 scan                  # Scan all files"
    echo "  $0 scan \"src/**/*\"       # Scan specific directory"
    echo "  $0 scan . json           # Output as JSON"
    echo "  $0 quick                 # Quick scan (no install)"
    echo "  $0 docker                # Scan via Docker"
    echo "  $0 mask .env.example     # Mask secrets in file"
    echo "  $0 sarif                 # Generate SARIF for CI/CD"
    echo "  $0 hook                  # Setup pre-commit hook"
    echo ""
    echo "Environment Variables:"
    echo "  None required - Secretlint works offline"
    echo ""
    echo "Detected Secret Types:"
    echo "  - AWS credentials (Access Key, Secret Key)"
    echo "  - GCP service account keys"
    echo "  - GitHub tokens (PAT, OAuth, App, Actions)"
    echo "  - OpenAI/Anthropic API keys"
    echo "  - Private keys (RSA, DSA, EC, OpenSSH)"
    echo "  - Database connection strings"
    echo "  - Slack tokens and webhooks"
    echo "  - npm tokens"
    echo "  - And many more..."
    echo ""
    echo "Reference: https://github.com/secretlint/secretlint"
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local arg2="${2:-}"
    local arg3="${3:-}"
    local arg4="${4:-}"
    
    case "$command" in
        "install")
            install_secretlint "$arg2"
            ;;
        "install-rules")
            install_additional_rules "$arg2"
            ;;
        "init")
            init_secretlint_config
            ;;
        "scan"|"lint")
            run_secretlint_scan "$arg2" "$arg3" "$arg4"
            ;;
        "quick")
            run_quick_scan "$arg2"
            ;;
        "docker")
            run_docker_scan "$arg2" "$arg3"
            ;;
        "mask"|"fix")
            mask_secrets "$arg2" "$arg3"
            ;;
        "sarif")
            generate_sarif "$arg2" "$arg3"
            ;;
        "hook")
            setup_precommit_hook
            ;;
        "husky")
            setup_husky_integration
            ;;
        "status")
            show_status
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            echo ""
            show_help
            return 1
            ;;
    esac
    return $?
}

# Execute main function with all arguments
main "$@"
