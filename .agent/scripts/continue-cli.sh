#!/bin/bash

# Continue.dev CLI Integration Script
# AI pair programmer and coding assistant integration
#
# Usage: ./continue-cli.sh [command] [options]
# Commands:
#   setup       - Setup Continue.dev configuration
#   chat        - Start AI pair programming session
#   explain     - Get code explanation
#   refactor    - Get refactoring suggestions
#   test        - Generate unit tests
#   review      - Code review with AI
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
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Configuration
readonly CONTINUE_VERSION="1.0.0"
readonly CONTINUE_CONFIG_DIR=".continue"
readonly CONTINUE_CONFIG_FILE="$CONTINUE_CONFIG_DIR/config.json"
readonly CONTINUE_API_CONFIG="configs/continue-config.json"
readonly CONTINUE_RESULTS_DIR=".agent/tmp/continue"

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
    echo -e "${PURPLE}🧠 $message${NC}"
    return 0
}

# Ensure results directory exists
ensure_results_dir() {
    mkdir -p "$CONTINUE_RESULTS_DIR"
    mkdir -p "$CONTINUE_CONFIG_DIR"
    return 0
}

# Load API configuration
load_api_config() {
    local api_key_script="$(dirname "$0")/setup-local-api-keys.sh"
    if [[ -f "$api_key_script" ]]; then
        local stored_key
        stored_key=$("$api_key_script" get continue 2>/dev/null)
        if [[ -n "$stored_key" ]]; then
            export CONTINUE_API_KEY="$stored_key"
            print_info "Loaded Continue.dev API key from secure local storage"
            return 0
        fi
    fi

    if [[ -f "$CONTINUE_API_CONFIG" ]]; then
        if command -v jq >/dev/null 2>&1; then
            local api_key
            api_key=$(jq -r '.api_key // empty' "$CONTINUE_API_CONFIG" 2>/dev/null)
            if [[ -n "$api_key" ]]; then
                export CONTINUE_API_KEY="$api_key"
                print_info "Loaded Continue.dev API key from configuration"
                return 0
            fi
        fi
    fi

    print_warning "Continue.dev API key not found in local storage"
    return 1
}

# Setup Continue.dev configuration
setup_continue_config() {
    print_header "Setting Up Continue.dev Configuration"
    
    # Create default configuration
    cat > "$CONTINUE_CONFIG_FILE" << 'EOF'
{
  "models": [
    {
      "title": "GPT-4",
      "provider": "openai",
      "model": "gpt-4",
      "apiKey": ""
    }
  ],
  "tabAutocompleteModel": {
    "title": "GPT-3.5-Turbo",
    "provider": "openai",
    "model": "gpt-3.5-turbo"
  },
  "apiKeyLocation": "environment",
  "contextLength": {
    "code": 4000,
    "general": 8000
  },
  "customCommands": [
    {
      "name": "explain",
      "prompt": "Explain the selected code, including its purpose and how it works."
    },
    {
      "name": "refactor",
      "prompt": "Refactor the selected code to improve readability, performance, or maintainability."
    },
    {
      "name": "test",
      "prompt": "Write comprehensive unit tests for the selected code."
    },
    {
      "name": "bug",
      "prompt": "Identify and explain any bugs in the selected code, then suggest fixes."
    }
  ]
}
EOF

    # Create API config
    mkdir -p configs
    cat > "$CONTINUE_API_CONFIG" << 'EOF'
{
  "api_key": "",
  "provider": "openai",
  "model": "gpt-4",
  "custom_settings": {
    "temperature": 0.7,
    "max_tokens": 2000,
    "frequency_penalty": 0,
    "presence_penalty": 0
  },
  "workspace_preferences": {
    "auto_context": true,
    "code_explanation": true,
    "refactoring_assistance": true,
    "test_generation": true
  }
}
EOF

    print_success "Continue.dev configuration created: $CONTINUE_CONFIG_FILE"
    
    # Setup instructions
    print_info "To complete setup:"
    print_info "1. Install Continue.dev extension in your VS Code"
    print_info "2. Visit https://continue.dev to get your API key"
    print_info "3. Run: bash .agent/scripts/setup-local-api-keys.sh set continue YOUR_API_KEY"
    
    return 0
}

# Start AI pair programming session
start_pair_programming() {
    local context_file="$1"
    
    print_header "Starting AI Pair Programming Session"
    
    # Load API configuration
    if ! load_api_config; then
        print_warning "API key not found. You may need to configure it in VS Code."
    fi

    # Create session context
    ensure_results_dir
    local session_file="$CONTINUE_RESULTS_DIR/session-$(date +%Y%m%d-%H%M%S).md"
    
    cat > "$session_file" << 'EOF'
# AI Pair Programming Session

## Current Context
Repository: AI DevOps Framework
Focus: DevOps automation and AI integration
Language: Bash shell scripts, Python, configuration files

## Session Goals
- Code quality improvements
- Bug fixes and refactoring
- Feature development assistance
- Security and performance optimization

## Files in Focus
Identify the files you want help with and I'll provide detailed assistance.

## Available Commands
- /explain - Get code explanations
- /refactor - Get refactoring suggestions
- /test - Generate unit tests
- /debug - Debug issues
- /optimize - Performance optimization
EOF

    print_success "Session context created: $session_file"
    print_info "Open VS Code with Continue.dev extension and start coding!"
    print_info "The extension will automatically load the current context."
    
    # Try to open VS Code if available
    if command -v code &> /dev/null; then
        print_info "Opening VS Code..."
        code . 2>/dev/null &
    fi
    
    return 0
}

# Get code explanation
get_code_explanation() {
    local file_path="$1"
    local line_range="$2"  # Format: "start-end"

    if [[ -z "$file_path" ]]; then
        print_error "File path required"
        print_info "Usage: $0 explain <file_path> [line_range]"
        return 1
    fi

    print_header "Getting Code Explanation"
    
    if [[ ! -f "$file_path" ]]; then
        print_error "File not found: $file_path"
        return 1
    fi

    ensure_results_dir
    local explanation_file="$CONTINUE_RESULTS_DIR/explain-$(date +%Y%m%d-%H%M%S).md"
    
    print_info "Analyzing file: $file_path"
    if [[ -n "$line_range" ]]; then
        print_info "Line range: $line_range"
    fi

    # Create explanation request
    local code_content
    if [[ -n "$line_range" ]]; then
        code_content=$(sed -n "${line_range}p" "$file_path")
    else
        # For large files, show first 50 lines
        code_content=$(head -50 "$file_path")
        if [[ $(wc -l < "$file_path") -gt 50 ]]; then
            echo "" >> explanation_file
            echo "# Note: Showing first 50 lines only" >> explanation_file
        fi
    fi

    cat > "$explanation_file" << EOF
# Code Explanation Request

## File: $file_path
$(if [[ -n "$line_range" ]]; then echo "## Lines: $line_range"; fi)

## Code to Explain
\`\`\`bash
$code_content
\`\`\`

## Explanation Analysis

*[This section will be populated by Continue.dev AI]*

### Purpose
### How it Works
### Key Components
### Dependencies
### Potential Issues
EOF

    print_success "Explanation request created: $explanation_file"
    print_info "Use Continue.dev extension in VS Code to get AI explanation"
    
    return 0
}

# Get refactoring suggestions
get_refactoring_suggestions() {
    local file_path="$1"
    local refactor_type="${2:-general}"

    print_header "Getting Refactoring Suggestions"
    
    if [[ -z "$file_path" ]]; then
        print_error "File path required"
        return 1
    fi

    if [[ ! -f "$file_path" ]]; then
        print_error "File not found: $file_path"
        return 1
    fi

    ensure_results_dir
    local refactor_file="$CONTINUE_RESULTS_DIR/refactor-$(date +%Y%m%d-%H%M%S).md"
    
    print_info "Analyzing for refactoring: $file_path"
    print_info "Refactoring type: $refactor_type"

    local code_content
    if [[ ${#file_path} -lt 10000 ]]; then
        code_content=$(cat "$file_path")
    else
        code_content=$(head -100 "$file_path")
    fi

    cat > "$refactor_file" << EOF
# Refactoring Suggestions

## File: $file_path
## Type: $refactor_type

## Current Code
\`\`\`bash
$code_content
\`\`\`

## Refactoring Analysis

*[This section will be populated by Continue.dev AI]*

### Issues Identified
### Suggested Improvements
### Refactored Code
### Benefits of Changes
EOF

    print_success "Refactoring request created: $refactor_file"
    print_info "Use Continue.dev extension in VS Code to get refactoring suggestions"
    
    return 0
}

# Generate unit tests
generate_unit_tests() {
    local file_path="$1"
    local test_framework="${2:-bash}"

    print_header "Generating Unit Tests"
    
    if [[ -z "$file_path" ]]; then
        print_error "File path required"
        return 1
    fi

    if [[ ! -f "$file_path" ]]; then
        print_error "File not found: $file_path"
        return 1
    fi

    ensure_results_dir
    local test_file="$CONTINUE_RESULTS_DIR/test-$(date +%Y%m%d-%H%M%S).$test_framework"
    
    print_info "Generating tests for: $file_path"
    print_info "Test framework: $test_framework"

    local code_content
    if [[ ${#file_path} -lt 10000 ]]; then
        code_content=$(cat "$file_path")
    else
        code_content=$(head -100 "$file_path")
    fi

    if [[ "$test_framework" == "bash" ]]; then
        cat > "$test_file" << EOF
#!/bin/bash

# Unit Tests for $(basename "$file_path")
# Generated by Continue.dev AI

# Test Setup
readonly TEST_FILE="$file_path"
readonly TEST_DIR="\$(dirname "\$0")"
readonly RESULTS_FILE="\$TEST_DIR/test-results.json"

# Test Framework Functions
test_assert_equals() {
    local expected="\$1"
    local actual="\$2"
    local message="\$3"
    
    if [[ "\$expected" == "\$actual" ]]; then
        echo "✅ PASS: \$message"
        return 0
    else
        echo "❌ FAIL: \$message"
        echo "   Expected: \$expected"
        echo "   Actual: \$actual"
        return 1
    fi
}

test_assert_file_exists() {
    local file="\$1"
    local message="\$2"
    
    if [[ -f "\$file" ]]; then
        echo "✅ PASS: \$message"
        return 0
    else
        echo "❌ FAIL: \$message"
        echo "   File not found: \$file"
        return 1
    fi
}

# Test Cases
run_tests() {
    echo "🧪 Running tests for $file_path"
    
    # Test: File exists
    test_assert_file_exists "\$TEST_FILE" "Source file exists"
    
    # Test: Function exists
    if grep -q "function_name()" "\$TEST_FILE"; then
        test_assert_equals "0" "0" "Function structure exists"
    fi
    
    echo ""
    echo "✅ Test run completed"
}

# Execute tests
run_tests "\$@"
EOF

        chmod +x "$test_file"
    fi

    print_success "Test file generated: $test_file"
    print_info "Use Continue.dev extension to enhance and complete the tests"
    
    return 0
}

# Perform AI code review
perform_code_review() {
    local target_path="${1:-.}"

    print_header "Performing AI Code Review"
    
    ensure_results_dir
    local review_file="$CONTINUE_RESULTS_DIR/review-$(date +%Y%m%d-%H%M%S).md"

    # Analyze the codebase
    local shell_files
    shell_files=$(find "$target_path" -name "*.sh" -type f 2>/dev/null | head -10)
    local python_files
    python_files=$(find "$target_path" -name "*.py" -type f 2>/dev/null | head -5)
    local config_files
    config_files=$(find "$target_path" -name "*.json" -o -name "*.yaml" -o -name "*.yml" | head -5)

    cat > "$review_file" << EOF
# AI Code Review Report

## Review Scope
Path: $target_path
Date: $(date -I)
Generated by: Continue.dev AI

## Files Analyzed

### Shell Scripts
$(for file in $shell_files; do echo "- $file"; done)

### Python Files
$(for file in $python_files; do echo "- $file"; done)

### Configuration Files
$(for file in $config_files; do echo "- $file"; done)

## Review Analysis

*[This comprehensive review will be populated by Continue.dev AI]*

### Quality Assessment
### Security Issues
### Performance Concerns
### Best Practices
### Maintainability
### Documentation

### Recommendations
### Priority Issues
### Suggested Improvements
### Code Enhancements
EOF

    print_success "Code review template created: $review_file"
    print_info "Use Continue.dev extension in VS Code to complete the AI review"
    
    return 0
}

# Show Continue.dev status
show_status() {
    print_header "Continue.dev Status"
    
    echo "Configuration Status:"
    
    if [[ -f "$CONTINUE_CONFIG_FILE" ]]; then
        print_success "VS Code Config: ✅ $CONTINUE_CONFIG_FILE"
    else
        print_warning "VS Code Config: ⚠️ Not found"
        print_info "Run: $0 setup"
    fi

    if load_api_config; then
        print_success "API Key: ✅ Configured"
    else
        print_warning "API Key: ⚠️ Not configured in local storage"
        print_info "You may configure it directly in VS Code"
    fi

    echo ""
    print_info "Extension Status:"
    if code --list-extensions 2>/dev/null | grep -q "Continue" || code --list-extensions 2>/dev/null | grep -q "continue"; then
        print_success "Continue Extension: ✅ Installed"
    else
        print_warning "Continue Extension: ⚠️ Not installed in VS Code"
        print_info "Install from VS Code Marketplace: 'Continue - AI Pair Programmer'"
    fi

    echo ""
    print_info "Recent Sessions:"
    find "$CONTINUE_RESULTS_DIR" -name "*.md" 2>/dev/null | sort -r | head -3 | while read -r file; do
        local size=$(du -h "$file" 2>/dev/null | cut -f1 || echo "unknown")
        local type=$(basename "$file" | sed 's/.*-\([^-]*\)..*/\1/')
        print_info "  $(basename "$file") ($type - $size)"
    done

    echo ""
    print_info "Quick Start:"
    print_info "1. Open VS Code"
    print_info "2. Press Cmd/Ctrl + L to open Continue chat"
    print_info "3. Ask questions or use commands like /explain, /refactor, /test"

    return 0
}

# Show help
show_help() {
    print_header "Continue.dev CLI Integration Help"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  setup             - Setup Continue.dev configuration"
    echo "  chat              - Start AI pair programming session"
    echo "  explain <file>    - Get code explanation"
    echo "  refactor <file>   - Get refactoring suggestions"
    echo "  test <file>       - Generate unit tests"
    echo "  review [path]     - Code review with AI"
    echo "  status            - Show Continue.dev status"
    echo "  help              - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 setup"
    echo "  $0 chat"
    echo "  $0 explain providers/hostinger-helper.sh"
    echo "  $0 refactor .agent/scripts/quality-check.sh"
    echo "  $0 test providers/setup-wizard-helper.sh bash"
    echo "  $0 review"
    echo ""
    echo "Setup:"
    echo "  1. Install Continue.dev extension in VS Code"
    echo "  2. Visit https://continue.dev to get API key"
    echo "  3. Run: bash .agent/scripts/setup-local-api-keys.sh set continue YOUR_API_KEY"
    echo "  4. Run: $0 setup"
    echo ""
    echo "VS Code Commands (in Continue extension):"
    echo "  /explain          - Explain selected code"
    echo "  /refactor         - Refactor selected code"
    echo "  /test             - Write tests for selected code"
    echo "  /bug              - Find bugs in selected code"
    echo "  /comment          - Add comments to code"
    echo "  /optimize         - Optimize code performance"
    echo ""
    echo "This script integrates Continue.dev's AI pair programming"
    echo "capabilities with the AI DevOps Framework for enhanced development."
    echo ""
    return 0
}

# Main function
main() {
    local command="${1:-help}"

    # Ensure temp directory exists
    mkdir -p .agent/tmp

    case "$command" in
        "setup")
            setup_continue_config
            ;;
        "chat")
            start_pair_programming "$2"
            ;;
        "explain")
            get_code_explanation "$2" "$3"
            ;;
        "refactor")
            get_refactoring_suggestions "$2" "$3"
            ;;
        "test")
            generate_unit_tests "$2" "$3"
            ;;
        "review")
            perform_code_review "$2"
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
