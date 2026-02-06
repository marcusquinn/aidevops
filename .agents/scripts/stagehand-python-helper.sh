#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Stagehand Python Helper - AI Browser Automation Framework Integration
# Part of AI DevOps Framework
# Provides local setup and usage of Stagehand Python for browser automation

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

# Stagehand Python-specific constants
readonly STAGEHAND_PYTHON_CONFIG_DIR="${HOME}/.aidevops/stagehand-python"
readonly STAGEHAND_PYTHON_EXAMPLES_DIR="${STAGEHAND_PYTHON_CONFIG_DIR}/examples"
readonly STAGEHAND_PYTHON_LOGS_DIR="${STAGEHAND_PYTHON_CONFIG_DIR}/logs"
readonly STAGEHAND_PYTHON_CACHE_DIR="${STAGEHAND_PYTHON_CONFIG_DIR}/cache"
readonly STAGEHAND_PYTHON_VENV_DIR="${STAGEHAND_PYTHON_CONFIG_DIR}/.venv"

# Create necessary directories
create_stagehand_python_directories() {
    local directories=(
        "$STAGEHAND_PYTHON_CONFIG_DIR"
        "$STAGEHAND_PYTHON_EXAMPLES_DIR"
        "$STAGEHAND_PYTHON_LOGS_DIR"
        "$STAGEHAND_PYTHON_CACHE_DIR"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
    done
    
    print_success "Created Stagehand Python directories"
    return 0
}

# Check Python installation and version
check_python_requirements() {
    print_info "Checking Python requirements..."
    
    # Check for Python 3.8+
    if command -v python3 &> /dev/null; then
        local python_version
        python_version=$(python3 --version | cut -d' ' -f2)
        print_success "Python 3 found: $python_version"
        
        # Check if version is 3.8+
        local major minor
        major=$(echo "$python_version" | cut -d'.' -f1)
        minor=$(echo "$python_version" | cut -d'.' -f2)
        
        if [[ "$major" -ge 3 ]] && [[ "$minor" -ge 8 ]]; then
            print_success "Python version is compatible (3.8+)"
        else
            print_error "Python 3.8+ is required. Found: $python_version"
            return 1
        fi
    else
        print_error "Python 3 is not installed. Please install Python 3.8+ first."
        return 1
    fi
    
    # Check for pip
    if command -v pip3 &> /dev/null; then
        local pip_version
        pip_version=$(pip3 --version | cut -d' ' -f2)
        print_success "pip3 found: $pip_version"
    else
        print_error "pip3 is not installed. Please install pip3 first."
        return 1
    fi
    
    return 0
}

# Install Stagehand Python with virtual environment
install_stagehand_python() {
    print_info "Installing Stagehand Python AI Browser Automation Framework..."
    
    # Check requirements first
    if ! check_python_requirements; then
        return 1
    fi
    
    # Create directories
    create_stagehand_python_directories
    
    cd "$STAGEHAND_PYTHON_CONFIG_DIR" || return 1
    
    # Check if uv is available (recommended)
    if command -v uv &> /dev/null; then
        print_info "Using uv for faster installation..."
        
        # Create virtual environment with uv
        print_info "Creating virtual environment with uv..."
        uv venv .venv
        
        # Activate virtual environment
        # shellcheck source=/dev/null
        source .venv/bin/activate
        
        # Install Stagehand with uv
        print_info "Installing stagehand with uv..."
        uv pip install stagehand
        
        # Install additional dependencies
        print_info "Installing additional dependencies..."
        uv pip install python-dotenv pydantic playwright
        
    else
        print_info "Using pip for installation..."
        
        # Create virtual environment with venv
        print_info "Creating virtual environment..."
        python3 -m venv .venv
        
        # Activate virtual environment
        # shellcheck source=/dev/null
        source .venv/bin/activate
        
        # Upgrade pip
        pip install --upgrade pip
        
        # Install Stagehand
        print_info "Installing stagehand..."
        pip install stagehand
        
        # Install additional dependencies
        print_info "Installing additional dependencies..."
        pip install python-dotenv pydantic playwright
    fi
    
    # Install Playwright browsers
    print_info "Installing Playwright browsers..."
    playwright install
    
    print_success "Stagehand Python installation completed"
    print_info "Virtual environment created at: $STAGEHAND_PYTHON_VENV_DIR"
    return 0
}

# Create Python environment configuration
create_python_env_config() {
    local env_file="${STAGEHAND_PYTHON_CONFIG_DIR}/.env"
    
    if [[ -f "$env_file" ]]; then
        print_info "Environment file already exists: $env_file"
        return 0
    fi
    
    cat > "$env_file" << 'EOF'
# Stagehand Python Configuration
# Copy this file and customize for your needs

# AI Model Configuration (choose one)
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_api_key_here
GOOGLE_API_KEY=your_google_api_key_here

# Browserbase Configuration (optional, for cloud browsers)
BROWSERBASE_API_KEY=your_browserbase_api_key_here
BROWSERBASE_PROJECT_ID=your_browserbase_project_id_here

# Stagehand Configuration
STAGEHAND_ENV=LOCAL
STAGEHAND_HEADLESS=false
STAGEHAND_VERBOSE=1
STAGEHAND_DEBUG_DOM=true

# Model Configuration
MODEL_NAME=google/gemini-2.5-flash-preview-05-20
MODEL_API_KEY=${GOOGLE_API_KEY}

# Logging Configuration
LOG_LEVEL=INFO
LOG_FILE=stagehand-python.log
EOF

    print_success "Created Python environment configuration at: $env_file"
    print_info "Please edit $env_file to add your API keys"
    return 0
}

# Show help information
show_help() {
    cat << EOF
Stagehand Python Helper - AI Browser Automation Framework Integration

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    help                    Show this help message
    install                 Install Stagehand Python and dependencies
    setup                   Complete setup (install + configure + examples)
    create-examples         Create Python example scripts
    run-example [NAME]      Run a specific example script
    status                  Check Stagehand Python installation status
    activate                Show activation command for virtual environment
    logs                    Show recent Stagehand Python logs
    clean                   Clean cache and temporary files
    test                    Run basic functionality test

EXAMPLES:
    $0 install              # Install Stagehand Python
    $0 setup                # Complete setup
    $0 activate             # Show venv activation command
    $0 run-example basic    # Run basic example
    $0 status               # Check installation

VIRTUAL ENVIRONMENT:
    To activate the virtual environment manually:
    source ~/.aidevops/stagehand-python/.venv/bin/activate

DOCUMENTATION:
    For detailed documentation, see: .agent/STAGEHAND-PYTHON.md
    Official docs: https://docs.stagehand.dev
    GitHub: https://github.com/browserbase/stagehand-python

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
            install_stagehand_python
            ;;
        "setup")
            install_stagehand_python && create_python_env_config
            ;;
        "create-examples")
            create_stagehand_python_directories
            print_info "Python examples will be created by the setup script"
            ;;
        "status")
            if [[ -d "$STAGEHAND_PYTHON_VENV_DIR" ]] && [[ -f "${STAGEHAND_PYTHON_VENV_DIR}/bin/activate" ]]; then
                print_success "Stagehand Python is installed at: $STAGEHAND_PYTHON_CONFIG_DIR"
                print_info "Virtual environment: $STAGEHAND_PYTHON_VENV_DIR"
                if command -v python3 &> /dev/null; then
                    print_info "Python version: $(python3 --version)"
                fi
                if [[ -f "${STAGEHAND_PYTHON_VENV_DIR}/bin/python" ]]; then
                    print_info "Virtual env Python: $(${STAGEHAND_PYTHON_VENV_DIR}/bin/python --version)"
                fi
            else
                print_error "Stagehand Python is not installed. Run '$0 install' first."
                return 1
            fi
            ;;
        "activate")
            if [[ -f "${STAGEHAND_PYTHON_VENV_DIR}/bin/activate" ]]; then
                print_info "To activate the virtual environment, run:"
                echo "source ${STAGEHAND_PYTHON_VENV_DIR}/bin/activate"
            else
                print_error "Virtual environment not found. Run '$0 install' first."
                return 1
            fi
            ;;
        "logs")
            if [[ -f "${STAGEHAND_PYTHON_LOGS_DIR}/stagehand-python.log" ]]; then
                tail -n 50 "${STAGEHAND_PYTHON_LOGS_DIR}/stagehand-python.log"
            else
                print_info "No log files found"
            fi
            ;;
        "clean")
            print_info "Cleaning Stagehand Python cache and temporary files..."
            rm -rf "${STAGEHAND_PYTHON_CACHE_DIR:?}"/*
            rm -rf "${STAGEHAND_PYTHON_LOGS_DIR:?}"/*
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
