#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Stagehand Helper - AI Browser Automation Framework Integration
# Part of AI DevOps Framework
# Provides local setup and usage of Stagehand for browser automation

# Source shared constants and functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Stagehand-specific constants
readonly STAGEHAND_CONFIG_DIR="${HOME}/.aidevops/stagehand"
readonly STAGEHAND_EXAMPLES_DIR="${STAGEHAND_CONFIG_DIR}/examples"
readonly STAGEHAND_LOGS_DIR="${STAGEHAND_CONFIG_DIR}/logs"
readonly STAGEHAND_CACHE_DIR="${STAGEHAND_CONFIG_DIR}/cache"

# Create necessary directories
create_stagehand_directories() {
    local directories=(
        "$STAGEHAND_CONFIG_DIR"
        "$STAGEHAND_EXAMPLES_DIR"
        "$STAGEHAND_LOGS_DIR"
        "$STAGEHAND_CACHE_DIR"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
    done
    
    print_success "Created Stagehand directories"
    return 0
}

# Install Stagehand and dependencies
install_stagehand() {
    print_info "Installing Stagehand AI Browser Automation Framework..."
    
    # Check if Node.js is installed
    if ! command -v node &> /dev/null; then
        print_error "Node.js is required but not installed. Please install Node.js first."
        return 1
    fi
    
    # Check if npm is installed
    if ! command -v npm &> /dev/null; then
        print_error "npm is required but not installed. Please install npm first."
        return 1
    fi
    
    # Create project directory
    create_stagehand_directories
    
    # Initialize npm project if needed
    if [[ ! -f "${STAGEHAND_CONFIG_DIR}/package.json" ]]; then
        print_info "Initializing npm project..."
        cd "$STAGEHAND_CONFIG_DIR" || return 1
        npm init -y > /dev/null 2>&1
    fi
    
    # Install Stagehand
    print_info "Installing @browserbasehq/stagehand..."
    cd "$STAGEHAND_CONFIG_DIR" || return 1
    # NOSONAR - npm scripts required for Playwright browser automation binaries
    npm install @browserbasehq/stagehand
    
    # Install additional dependencies for better functionality
    print_info "Installing additional dependencies..."
    # NOSONAR - npm scripts required for dependency compilation
    npm install zod dotenv
    
    print_success "Stagehand installation completed"
    return 0
}

# Create example Stagehand script
create_example_script() {
    local example_file="${STAGEHAND_EXAMPLES_DIR}/basic-example.js"
    
    cat > "$example_file" << 'EOF'
// Basic Stagehand Example
// AI-powered browser automation with natural language

import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

async function main() {
    // Initialize Stagehand
    const stagehand = new Stagehand({
        env: "LOCAL", // Use local browser
        verbose: 1,
        debugDom: true
    });

    try {
        // Initialize browser context
        await stagehand.init();
        
        // Navigate to a website
        await stagehand.page.goto("https://example.com");
        
        // Use natural language to interact with the page
        await stagehand.act("click on the 'More information...' link");
        
        // Extract structured data from the page
        const pageInfo = await stagehand.extract(
            "extract the page title and main heading",
            z.object({
                title: z.string().describe("The page title"),
                heading: z.string().describe("The main heading text")
            })
        );
        
        console.log("Extracted data:", pageInfo);
        
        // Use observe to discover available actions
        const actions = await stagehand.observe("find all clickable buttons");
        console.log("Available actions:", actions);
        
    } catch (error) {
        console.error("Error during automation:", error);
    } finally {
        // Clean up
        await stagehand.close();
    }
    return 0
}

// Run the example
main().catch(console.error);
EOF

    print_success "Created basic example script at: $example_file"
    return 0
}

# Create environment configuration
create_env_config() {
    local env_file="${STAGEHAND_CONFIG_DIR}/.env"
    
    if [[ -f "$env_file" ]]; then
        print_info "Environment file already exists: $env_file"
        return 0
    fi
    
    cat > "$env_file" << 'EOF'
# Stagehand Configuration
# Copy this file and customize for your needs

# OpenAI API Key (for AI-powered actions)
OPENAI_API_KEY=your_openai_api_key_here

# Anthropic API Key (alternative AI provider)
ANTHROPIC_API_KEY=your_anthropic_api_key_here

# Browserbase credentials (optional, for cloud browsers)
BROWSERBASE_API_KEY=your_browserbase_api_key_here
BROWSERBASE_PROJECT_ID=your_browserbase_project_id_here

# Browser configuration
STAGEHAND_ENV=LOCAL
STAGEHAND_HEADLESS=false
STAGEHAND_VERBOSE=1
STAGEHAND_DEBUG_DOM=true

# Logging
STAGEHAND_LOG_LEVEL=info
STAGEHAND_LOG_FILE=stagehand.log
EOF

    print_success "Created environment configuration at: $env_file"
    print_info "Please edit $env_file to add your API keys"
    return 0
}

# Show help information
show_help() {
    cat << EOF
Stagehand Helper - AI Browser Automation Framework Integration

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    help                    Show this help message
    install                 Install Stagehand and dependencies
    setup                   Complete setup (install + configure)
    create-example          Create basic example script
    run-example             Run the basic example script
    status                  Check Stagehand installation status
    logs                    Show recent Stagehand logs
    clean                   Clean cache and temporary files

EXAMPLES:
    $0 install              # Install Stagehand
    $0 setup                # Complete setup
    $0 run-example          # Run basic example
    $0 status               # Check installation

DOCUMENTATION:
    For detailed documentation, see: .agent/STAGEHAND.md
    Official docs: https://docs.stagehand.dev
    GitHub: https://github.com/browserbase/stagehand

EOF
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    
    case "$command" in
        "help")
            show_help
            ;;
        "install")
            install_stagehand
            ;;
        "setup")
            install_stagehand && create_env_config && create_example_script
            ;;
        "create-example")
            create_stagehand_directories && create_example_script
            ;;
        "run-example")
            if [[ -f "${STAGEHAND_EXAMPLES_DIR}/basic-example.js" ]]; then
                cd "$STAGEHAND_CONFIG_DIR" || return 1
                node "${STAGEHAND_EXAMPLES_DIR}/basic-example.js"
            else
                print_error "Example script not found. Run '$0 create-example' first."
                return 1
            fi
            ;;
        "status")
            if [[ -d "$STAGEHAND_CONFIG_DIR" ]] && [[ -f "${STAGEHAND_CONFIG_DIR}/package.json" ]]; then
                print_success "Stagehand is installed at: $STAGEHAND_CONFIG_DIR"
                if command -v node &> /dev/null; then
                    print_info "Node.js version: $(node --version)"
                fi
                if command -v npm &> /dev/null; then
                    print_info "npm version: $(npm --version)"
                fi
            else
                print_error "Stagehand is not installed. Run '$0 install' first."
                return 1
            fi
            ;;
        "logs")
            if [[ -f "${STAGEHAND_LOGS_DIR}/stagehand.log" ]]; then
                tail -n 50 "${STAGEHAND_LOGS_DIR}/stagehand.log"
            else
                print_info "No log files found"
            fi
            ;;
        "clean")
            print_info "Cleaning Stagehand cache and temporary files..."
            rm -rf "${STAGEHAND_CACHE_DIR:?}"/*
            rm -rf "${STAGEHAND_LOGS_DIR:?}"/*
            print_success "Cleanup completed"
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
