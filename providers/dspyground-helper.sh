#!/bin/bash

# DSPyGround Helper Script for AI DevOps Framework
# Provides DSPyGround prompt optimization playground integration
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/configs/dspyground-config.json"
PROJECTS_DIR="$PROJECT_ROOT/data/dspyground"
DEFAULT_PORT=3000

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/dspyground-config.json.txt $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# Check Node.js and npm
check_nodejs() {
    if ! command -v node &> /dev/null; then
        print_error "Node.js is required but not installed"
        print_info "Install Node.js from: https://nodejs.org/"
        exit 1
    fi
    
    local node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ $node_version -lt 18 ]]; then
        print_error "Node.js 18+ is required, found v$node_version"
        exit 1
    fi
    
    if ! command -v npm &> /dev/null; then
        print_error "npm is required but not installed"
        exit 1
    fi
    
    print_success "Node.js $(node --version) and npm $(npm --version) found"
}

# Check DSPyGround installation
check_dspyground() {
    if ! command -v dspyground &> /dev/null; then
        print_error "DSPyGround is not installed globally"
        print_info "Install with: npm install -g dspyground"
        exit 1
    fi
    
    local version=$(dspyground --version)
    print_success "DSPyGround v$version found"
}

# Install DSPyGround
install() {
    print_info "Installing DSPyGround..."
    check_nodejs
    
    npm install -g dspyground
    
    if [[ $? -eq 0 ]]; then
        print_success "DSPyGround installed successfully"
        dspyground --version
    else
        print_error "Failed to install DSPyGround"
        exit 1
    fi
}

# Initialize DSPyGround project
init_project() {
    local project_name="${1:-dspyground-project}"
    print_info "Initializing DSPyGround project: $project_name"
    
    check_nodejs
    check_dspyground
    
    mkdir -p "$PROJECTS_DIR"
    local project_dir="$PROJECTS_DIR/$project_name"
    
    if [[ -d "$project_dir" ]]; then
        print_warning "Project directory already exists: $project_dir"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    mkdir -p "$project_dir"
    cd "$project_dir"
    
    # Initialize DSPyGround
    dspyground init
    
    if [[ $? -eq 0 ]]; then
        print_success "DSPyGround project initialized: $project_dir"
        print_info "Edit dspyground.config.ts to customize your agent environment"
        print_info "Create .env file with your API keys"
    else
        print_error "Failed to initialize DSPyGround project"
        exit 1
    fi
}

# Start DSPyGround development server
start_dev() {
    local project_name="${1:-dspyground-project}"
    print_info "Starting DSPyGround development server for: $project_name"
    
    check_nodejs
    check_dspyground
    
    local project_dir="$PROJECTS_DIR/$project_name"
    
    if [[ ! -d "$project_dir" ]]; then
        print_error "Project not found: $project_dir"
        print_info "Run: $0 init $project_name"
        exit 1
    fi
    
    cd "$project_dir"
    
    # Check for .env file
    if [[ ! -f ".env" ]]; then
        print_warning ".env file not found"
        print_info "Create .env file with your API keys:"
        echo "AI_GATEWAY_API_KEY=your_api_key_here"
        echo "OPENAI_API_KEY=your_openai_api_key_here"
    fi
    
    print_info "Starting development server on http://localhost:$DEFAULT_PORT"
    dspyground dev
}

# Build DSPyGround project
build() {
    local project_name="${1:-dspyground-project}"
    print_info "Building DSPyGround project: $project_name"
    
    check_nodejs
    check_dspyground
    
    local project_dir="$PROJECTS_DIR/$project_name"
    
    if [[ ! -d "$project_dir" ]]; then
        print_error "Project not found: $project_dir"
        exit 1
    fi
    
    cd "$project_dir"
    dspyground build
    
    if [[ $? -eq 0 ]]; then
        print_success "DSPyGround project built successfully"
    else
        print_error "Failed to build DSPyGround project"
        exit 1
    fi
}

# List DSPyGround projects
list_projects() {
    print_info "DSPyGround projects:"
    
    if [[ ! -d "$PROJECTS_DIR" ]]; then
        print_warning "No projects directory found: $PROJECTS_DIR"
        return
    fi
    
    local count=0
    for project in "$PROJECTS_DIR"/*; do
        if [[ -d "$project" ]]; then
            local name=$(basename "$project")
            echo "  - $name"
            count=$((count + 1))
        fi
    done
    
    if [[ $count -eq 0 ]]; then
        print_info "No projects found. Create one with: $0 init <project_name>"
    else
        print_success "Found $count project(s)"
    fi
}

# Show help
show_help() {
    echo "DSPyGround Helper Script for AI DevOps Framework"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install              - Install DSPyGround globally"
    echo "  init [project_name]  - Initialize new DSPyGround project"
    echo "  dev [project_name]   - Start development server"
    echo "  build [project_name] - Build project for production"
    echo "  list                 - List all DSPyGround projects"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 init my-agent"
    echo "  $0 dev my-agent"
    echo "  $0 build my-agent"
    echo ""
    echo "Configuration:"
    echo "  Edit $CONFIG_FILE to customize settings"
    echo ""
    echo "Environment Variables:"
    echo "  AI_GATEWAY_API_KEY   - Required for AI Gateway access"
    echo "  OPENAI_API_KEY       - Optional for voice feedback feature"
    echo ""
}

# Main command handler
main() {
    case "${1:-help}" in
        "install")
            install
            ;;
        "init")
            init_project "$2"
            ;;
        "dev"|"start")
            start_dev "$2"
            ;;
        "build")
            build "$2"
            ;;
        "list")
            list_projects
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

# Run main function
main "$@"
