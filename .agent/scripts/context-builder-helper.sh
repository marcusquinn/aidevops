#!/bin/bash
# =============================================================================
# Context Builder Helper Script
# =============================================================================
# Wraps Repomix to provide token-efficient context generation for AI assistants
# Inspired by RepoPrompt's Code Maps and context engineering capabilities
#
# Usage: ./context-builder-helper.sh [command] [path] [options]
# Commands:
#   pack [path]       Pack repository with smart defaults
#   compress [path]   Pack with Tree-sitter compression (~80% token reduction)
#   quick [path]      Fast pack for small focused contexts
#   analyze [path]    Show token analysis without generating output
#   remote <url>      Pack a remote GitHub repository
#   help              Show this help message
#
# Version: 1.0.0
# =============================================================================

set -euo pipefail

# Configuration
# shellcheck disable=SC2034
declare SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
declare SCRIPT_NAME
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly VERSION="1.0.0"

# Default output directory
readonly DEFAULT_OUTPUT_DIR="$HOME/.aidevops/.agent-workspace/work/context"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

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
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  Context Builder - Token-Efficient AI Context${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    return 0
}

# Check if repomix is available
check_repomix() {
    if ! command -v npx &>/dev/null; then
        print_error "npx not found - please install Node.js"
        return 1
    fi
    return 0
}

# Ensure output directory exists
ensure_output_dir() {
    if [[ ! -d "$DEFAULT_OUTPUT_DIR" ]]; then
        mkdir -p "$DEFAULT_OUTPUT_DIR"
        print_info "Created output directory: $DEFAULT_OUTPUT_DIR"
    fi
    return 0
}

# Generate timestamped output filename
generate_output_name() {
    local base_path="$1"
    local style="${2:-xml}"
    local suffix="${3:-}"
    local base_name
    
    # Get directory name for output file
    if [[ "$base_path" == "." ]]; then
        base_name=$(basename "$(pwd)")
    else
        base_name=$(basename "$base_path")
    fi
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    
    if [[ -n "$suffix" ]]; then
        echo "${DEFAULT_OUTPUT_DIR}/${base_name}-${suffix}-${timestamp}.${style}"
    else
        echo "${DEFAULT_OUTPUT_DIR}/${base_name}-${timestamp}.${style}"
    fi
    return 0
}

# =============================================================================
# Core Commands
# =============================================================================

# Pack repository with smart defaults
cmd_pack() {
    local target_path="${1:-.}"
    local style="${2:-xml}"
    local output_file
    
    check_repomix || return 1
    ensure_output_dir
    
    output_file=$(generate_output_name "$target_path" "$style" "full")
    
    print_info "Packing repository: $target_path"
    print_info "Output format: $style"
    print_info "Output file: $output_file"
    echo ""
    
    npx repomix@latest "$target_path" \
        --output "$output_file" \
        --style "$style" \
        --output-show-line-numbers \
        --top-files-len 10
    
    if [[ -f "$output_file" ]]; then
        local size
        size=$(du -h "$output_file" | cut -f1)
        print_success "Context file generated: $output_file ($size)"
        print_info "Copy to clipboard: cat '$output_file' | pbcopy"
    fi
    
    return 0
}

# Pack with Tree-sitter compression (Code Maps equivalent)
cmd_compress() {
    local target_path="${1:-.}"
    local style="${2:-xml}"
    local output_file
    
    check_repomix || return 1
    ensure_output_dir
    
    output_file=$(generate_output_name "$target_path" "$style" "compressed")
    
    print_info "Compressing repository with Tree-sitter (Code Maps mode)"
    print_info "This extracts code structure (classes, functions, interfaces)"
    print_info "Expected token reduction: ~80%"
    print_info "Target: $target_path"
    print_info "Output: $output_file"
    echo ""
    
    npx repomix@latest "$target_path" \
        --output "$output_file" \
        --style "$style" \
        --compress \
        --remove-comments \
        --remove-empty-lines \
        --top-files-len 10
    
    if [[ -f "$output_file" ]]; then
        local size
        size=$(du -h "$output_file" | cut -f1)
        print_success "Compressed context file: $output_file ($size)"
        print_info "This contains code structure only - ideal for architecture understanding"
    fi
    
    return 0
}

# Quick pack for focused small contexts
cmd_quick() {
    local target_path="${1:-.}"
    local include_pattern="${2:-}"
    local output_file
    
    check_repomix || return 1
    ensure_output_dir
    
    output_file=$(generate_output_name "$target_path" "md" "quick")
    
    print_info "Quick pack mode (minimal output)"
    print_info "Target: $target_path"
    
    local include_args=()
    if [[ -n "$include_pattern" ]]; then
        include_args=("--include" "$include_pattern")
        print_info "Include pattern: $include_pattern"
    fi
    
    echo ""
    
    npx repomix@latest "$target_path" \
        --output "$output_file" \
        --style markdown \
        --no-file-summary \
        --remove-comments \
        --remove-empty-lines \
        "${include_args[@]}"
    
    if [[ -f "$output_file" ]]; then
        local size
        size=$(du -h "$output_file" | cut -f1)
        print_success "Quick context: $output_file ($size)"
        
        # Copy to clipboard on macOS
        if command -v pbcopy &>/dev/null; then
            cat "$output_file" | pbcopy
            print_success "Copied to clipboard!"
        fi
    fi
    
    return 0
}

# Analyze token usage without generating full output
cmd_analyze() {
    local target_path="${1:-.}"
    local threshold="${2:-100}"
    
    check_repomix || return 1
    
    print_info "Analyzing token usage in: $target_path"
    print_info "Showing files with >= $threshold tokens"
    echo ""
    
    npx repomix@latest "$target_path" \
        --token-count-tree "$threshold" \
        --no-files \
        --quiet 2>/dev/null || npx repomix@latest "$target_path" --token-count-tree "$threshold"
    
    return 0
}

# Pack a remote GitHub repository
cmd_remote() {
    local repo_url="$1"
    local branch="${2:-}"
    local style="${3:-xml}"
    local output_file
    
    if [[ -z "$repo_url" ]]; then
        print_error "Repository URL required"
        print_info "Usage: $SCRIPT_NAME remote <github-url|user/repo> [branch] [style]"
        return 1
    fi
    
    check_repomix || return 1
    ensure_output_dir
    
    # Extract repo name for output file
    local repo_name
    repo_name=$(echo "$repo_url" | sed 's|.*/||' | sed 's|\.git$||')
    output_file="${DEFAULT_OUTPUT_DIR}/${repo_name}-remote-$(date +%Y%m%d-%H%M%S).${style}"
    
    print_info "Packing remote repository: $repo_url"
    if [[ -n "$branch" ]]; then
        print_info "Branch: $branch"
    fi
    print_info "Output: $output_file"
    echo ""
    
    local branch_args=()
    if [[ -n "$branch" ]]; then
        branch_args=("--remote-branch" "$branch")
    fi
    
    npx repomix@latest \
        --remote "$repo_url" \
        "${branch_args[@]}" \
        --output "$output_file" \
        --style "$style" \
        --compress \
        --top-files-len 10
    
    if [[ -f "$output_file" ]]; then
        local size
        size=$(du -h "$output_file" | cut -f1)
        print_success "Remote context file: $output_file ($size)"
    fi
    
    return 0
}

# Compare full vs compressed token usage
cmd_compare() {
    local target_path="${1:-.}"
    
    check_repomix || return 1
    ensure_output_dir
    
    print_header
    print_info "Comparing full vs compressed context for: $target_path"
    echo ""
    
    # Generate both versions
    local full_output
    local compressed_output
    full_output=$(generate_output_name "$target_path" "xml" "full-compare")
    compressed_output=$(generate_output_name "$target_path" "xml" "compressed-compare")
    
    print_info "Generating full context..."
    npx repomix@latest "$target_path" \
        --output "$full_output" \
        --style xml \
        --quiet 2>/dev/null || true
    
    print_info "Generating compressed context..."
    npx repomix@latest "$target_path" \
        --output "$compressed_output" \
        --style xml \
        --compress \
        --remove-comments \
        --remove-empty-lines \
        --quiet 2>/dev/null || true
    
    if [[ -f "$full_output" ]] && [[ -f "$compressed_output" ]]; then
        local full_size
        local compressed_size
        local full_lines
        local compressed_lines
        
        full_size=$(du -h "$full_output" | cut -f1)
        compressed_size=$(du -h "$compressed_output" | cut -f1)
        full_lines=$(wc -l < "$full_output" | tr -d ' ')
        compressed_lines=$(wc -l < "$compressed_output" | tr -d ' ')
        
        echo ""
        echo "┌─────────────────────────────────────────────────┐"
        echo "│              Context Comparison                 │"
        echo "├─────────────────────────────────────────────────┤"
        printf "│ %-20s │ %10s │ %10s │\n" "Metric" "Full" "Compressed"
        echo "├─────────────────────────────────────────────────┤"
        printf "│ %-20s │ %10s │ %10s │\n" "File Size" "$full_size" "$compressed_size"
        printf "│ %-20s │ %10s │ %10s │\n" "Lines" "$full_lines" "$compressed_lines"
        echo "└─────────────────────────────────────────────────┘"
        echo ""
        
        # Calculate reduction percentage
        local full_bytes
        local compressed_bytes
        full_bytes=$(wc -c < "$full_output" | tr -d ' ')
        compressed_bytes=$(wc -c < "$compressed_output" | tr -d ' ')
        
        if [[ "$full_bytes" -gt 0 ]]; then
            local reduction
            reduction=$(echo "scale=1; (1 - $compressed_bytes / $full_bytes) * 100" | bc)
            print_success "Size reduction: ${reduction}%"
        fi
        
        print_info "Full output: $full_output"
        print_info "Compressed output: $compressed_output"
    fi
    
    return 0
}

# Start MCP server mode
cmd_mcp() {
    check_repomix || return 1
    
    print_info "Starting Context Builder MCP server..."
    print_info "This allows AI assistants to directly call context building tools"
    echo ""
    
    npx repomix@latest --mcp
    
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << 'HELP_EOF'
Context Builder - Token-Efficient AI Context Generation
=========================================================

Wraps Repomix to provide optimized context for AI coding assistants.
Inspired by RepoPrompt's Code Maps and context engineering approach.

USAGE:
  context-builder-helper.sh [command] [path] [options]

COMMANDS:
  pack [path] [style]           Pack repository with smart defaults
                                Styles: xml (default), markdown, json, plain

  compress [path] [style]       Pack with Tree-sitter compression (~80% token reduction)
                                Extracts: classes, functions, interfaces, imports
                                Omits: implementation details, comments

  quick [path] [pattern]        Fast pack for focused contexts
                                Auto-copies to clipboard on macOS
                                Optional: include pattern (e.g., "src/**/*.ts")

  analyze [path] [threshold]    Show token usage per file (default threshold: 100)
                                No output file generated

  remote <url> [branch] [style] Pack a remote GitHub repository
                                URL formats: https://github.com/user/repo or user/repo

  compare [path]                Compare full vs compressed output sizes
                                Shows token reduction percentage

  mcp                           Start as MCP server for AI assistant integration

  help                          Show this help message

EXAMPLES:
  # Pack current directory
  context-builder-helper.sh pack

  # Compress a specific project (80% smaller)
  context-builder-helper.sh compress ~/projects/myapp

  # Quick context for TypeScript files only
  context-builder-helper.sh quick . "**/*.ts"

  # Analyze token usage
  context-builder-helper.sh analyze ~/git/aidevops 50

  # Pack remote repo
  context-builder-helper.sh remote facebook/react main

  # Compare compression effectiveness
  context-builder-helper.sh compare .

OUTPUT:
  Files are saved to: ~/.aidevops/.agent-workspace/work/context/
  Format: {repo-name}-{mode}-{timestamp}.{style}

TOKEN EFFICIENCY:
  - compress mode uses Tree-sitter to extract code structure only
  - Equivalent to RepoPrompt's "Code Maps" feature
  - Reduces tokens by ~80% while preserving semantic understanding
  - AI can understand architecture without reading implementation

MCP INTEGRATION:
  The 'mcp' command starts a Model Context Protocol server.
  Add to your AI assistant's MCP config for direct integration.

For more information:
  https://github.com/yamadashy/repomix
  https://github.com/marcusquinn/aidevops

HELP_EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        pack)
            cmd_pack "$@"
            ;;
        compress)
            cmd_compress "$@"
            ;;
        quick)
            cmd_quick "$@"
            ;;
        analyze)
            cmd_analyze "$@"
            ;;
        remote)
            cmd_remote "$@"
            ;;
        compare)
            cmd_compare "$@"
            ;;
        mcp)
            cmd_mcp "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        version|--version|-v)
            echo "context-builder-helper.sh version $VERSION"
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            return 1
            ;;
    esac
    
    return 0
}

main "$@"
