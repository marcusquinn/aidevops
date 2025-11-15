#!/bin/bash

# DSPy Helper Script for AI DevOps Framework
# Provides DSPy prompt optimization and language model integration
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
CONFIG_FILE="$PROJECT_ROOT/configs/dspy-config.json"
PYTHON_ENV_PATH="$PROJECT_ROOT/python-env/dspy-env"
DATA_DIR="$PROJECT_ROOT/data/dspy"
LOGS_DIR="$PROJECT_ROOT/logs"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/dspy-config.json.txt $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# Check Python environment
check_python_env() {
    if [[ ! -d "$PYTHON_ENV_PATH" ]]; then
        print_error "Python virtual environment not found: $PYTHON_ENV_PATH"
        print_info "Run: python3 -m venv $PYTHON_ENV_PATH"
        print_info "Then: source $PYTHON_ENV_PATH/bin/activate && pip install -r ../requirements.txt"
        exit 1
    fi
    
    if [[ ! -f "$PYTHON_ENV_PATH/bin/activate" ]]; then
        print_error "Virtual environment activation script not found"
        exit 1
    fi
    
    return 0
}

# Activate Python environment
activate_env() {
    source "$PYTHON_ENV_PATH/bin/activate"
    if [[ $? -ne 0 ]]; then
        print_error "Failed to activate Python virtual environment"
        exit 1
    fi
    print_success "Python virtual environment activated"
}

# Setup directories
setup_directories() {
    mkdir -p "$DATA_DIR" "$LOGS_DIR"
    print_success "Created directories: $DATA_DIR, $LOGS_DIR"
}

# Install DSPy dependencies
install_deps() {
    print_info "Installing DSPy dependencies..."
    check_python_env
    activate_env
    
    pip install --upgrade pip
    pip install -r "$PROJECT_ROOT/requirements.txt"
    
    if [[ $? -eq 0 ]]; then
        print_success "DSPy dependencies installed successfully"
    else
        print_error "Failed to install DSPy dependencies"
        exit 1
    fi
}

# Test DSPy installation
test_installation() {
    print_info "Testing DSPy installation..."
    check_python_env
    activate_env
    
    python3 -c "
import dspy
import sys
print(f'DSPy version: {dspy.__version__}')
print('DSPy installation test: SUCCESS')
sys.exit(0)
" 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        print_success "DSPy installation test passed"
    else
        print_error "DSPy installation test failed"
        exit 1
    fi
}

# Initialize DSPy project
init_project() {
    local project_name="${1:-dspy-project}"
    print_info "Initializing DSPy project: $project_name"
    
    check_config
    check_python_env
    activate_env
    setup_directories
    
    local project_dir="$DATA_DIR/$project_name"
    mkdir -p "$project_dir"
    
    # Create basic DSPy project structure
    cat > "$project_dir/main.py" << 'EOF'
#!/usr/bin/env python3
"""
DSPy Project Template
Basic structure for DSPy prompt optimization
"""

import dspy
import json
import os
from pathlib import Path

# Load configuration
config_path = Path(__file__).parent.parent.parent / "configs" / "dspy-config.json"
with open(config_path) as f:
    config = json.load(f)

# Configure DSPy with OpenAI (example)
def setup_language_model():
    """Setup the language model for DSPy"""
    provider_config = config["language_models"]["providers"]["openai"]

    # Use environment variable first, fallback to config
    api_key = os.getenv("OPENAI_API_KEY", provider_config["api_key"])
    model = f"openai/{provider_config['default_model']}"

    lm = dspy.LM(
        model=model,
        api_key=api_key,
        api_base=provider_config.get("base_url")
    )

    dspy.settings.configure(lm=lm)
    return lm

# Example DSPy signature
class BasicQA(dspy.Signature):
    """Answer questions with helpful, accurate responses."""
    question = dspy.InputField()
    answer = dspy.OutputField(desc="A helpful and accurate answer")

# Example DSPy module
class BasicQAModule(dspy.Module):
    def __init__(self):
        super().__init__()
        self.generate_answer = dspy.ChainOfThought(BasicQA)
    
    def forward(self, question):
        return self.generate_answer(question=question)

if __name__ == "__main__":
    # Setup
    lm = setup_language_model()
    qa_module = BasicQAModule()
    
    # Example usage
    question = "What is DSPy and how does it help with prompt optimization?"
    result = qa_module(question=question)
    
    print(f"Question: {question}")
    print(f"Answer: {result.answer}")
EOF
    
    print_success "DSPy project initialized: $project_dir"
    print_info "Edit $project_dir/main.py to customize your DSPy application"
}

# Run DSPy optimization
optimize() {
    local project_name="${1:-dspy-project}"
    print_info "Running DSPy optimization for project: $project_name"
    
    check_config
    check_python_env
    activate_env
    
    local project_dir="$DATA_DIR/$project_name"
    if [[ ! -d "$project_dir" ]]; then
        print_error "Project not found: $project_dir"
        print_info "Run: $0 init $project_name"
        exit 1
    fi
    
    cd "$project_dir"
    python3 main.py
}

# Show help
show_help() {
    echo "DSPy Helper Script for AI DevOps Framework"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install              - Install DSPy dependencies"
    echo "  test                 - Test DSPy installation"
    echo "  init [project_name]  - Initialize new DSPy project"
    echo "  optimize [project]   - Run DSPy optimization"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 init my-chatbot"
    echo "  $0 optimize my-chatbot"
    echo ""
    echo "Configuration:"
    echo "  Edit $CONFIG_FILE to customize settings"
    echo ""
}

# Main command handler
main() {
    case "${1:-help}" in
        "install")
            install_deps
            ;;
        "test")
            test_installation
            ;;
        "init")
            init_project "$2"
            ;;
        "optimize")
            optimize "$2"
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

# Run main function
main "$@"
