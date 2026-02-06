#!/bin/bash

# Verify AI Assistant Mirror Symlinks
# Ensures all mirror directories are properly symlinked to .agents/
#
# Usage: ./.agents/scripts/verify-mirrors.sh [--fix]
#
# Options:
#   --fix      Create missing symlinks (default: report only)
#   --help     Show this help message
#
# This script is for aidevops repository development only.

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

print_info() { local msg="$1"; echo -e "${BLUE}[INFO]${NC} $msg"; return 0; }
print_success() { local msg="$1"; echo -e "${GREEN}[OK]${NC} $msg"; return 0; }
print_warning() { local msg="$1"; echo -e "${YELLOW}[WARN]${NC} $msg"; return 0; }
print_error() { local msg="$1"; echo -e "${RED}[ERROR]${NC} $msg"; return 0; }

# Get repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Expected symlinks (target:link_path relative to repo root)
# Format: "link_path:target"
EXPECTED_SYMLINKS=(
    ".ai:.agent"
    ".continue:.agent"
    ".kiro:.agent"
    ".claude/skills:../.agent"
    ".cursor/rules:../.agent"
    ".codex/prompts:../.agent"
    ".factory/skills:../.agent"
)

FIX_MODE=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Verifies AI assistant mirror symlinks point to .agents/"
    echo ""
    echo "Options:"
    echo "  --fix      Create missing symlinks"
    echo "  --help     Show this help message"
    echo ""
    echo "Expected symlinks:"
    for entry in "${EXPECTED_SYMLINKS[@]}"; do
        local link_path="${entry%%:*}"
        local target="${entry##*:}"
        echo "  $link_path -> $target"
    done
    return 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        local arg="$1"
        case "$arg" in
            --fix)
                FIX_MODE=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $arg"
                usage
                exit 1
                ;;
        esac
    done
    return 0
}

verify_symlink() {
    local link_path="$1"
    local expected_target="$2"
    local full_link="$REPO_ROOT/$link_path"
    local parent_dir
    parent_dir="$(dirname "$full_link")"
    
    # Check if symlink exists
    if [[ -L "$full_link" ]]; then
        local actual_target
        actual_target=$(readlink "$full_link")
        if [[ "$actual_target" == "$expected_target" ]]; then
            print_success "$link_path -> $expected_target"
            return 0
        else
            print_warning "$link_path -> $actual_target (expected: $expected_target)"
            if [[ "$FIX_MODE" == "true" ]]; then
                rm "$full_link"
                ln -s "$expected_target" "$full_link"
                print_info "Fixed: $link_path -> $expected_target"
            fi
            return 1
        fi
    elif [[ -e "$full_link" ]]; then
        print_error "$link_path exists but is not a symlink"
        return 1
    else
        print_warning "$link_path missing"
        if [[ "$FIX_MODE" == "true" ]]; then
            # Create parent directory if needed
            if [[ ! -d "$parent_dir" ]]; then
                mkdir -p "$parent_dir"
                print_info "Created directory: $(dirname "$link_path")"
            fi
            ln -s "$expected_target" "$full_link"
            print_info "Created: $link_path -> $expected_target"
        fi
        return 1
    fi
}

main() {
    parse_args "$@"
    
    # Verify we're in the right repo
    if [[ ! -d "$REPO_ROOT/.agent" ]]; then
        print_error "Source directory not found: $REPO_ROOT/.agent"
        print_error "Run this script from the aidevops repository"
        exit 1
    fi
    
    echo "🔗 Verifying AI Assistant Mirror Symlinks"
    echo "=========================================="
    if [[ "$FIX_MODE" == "true" ]]; then
        echo "Mode: Fix (will create missing symlinks)"
    else
        echo "Mode: Verify only (use --fix to create missing)"
    fi
    echo ""
    
    local issues=0
    
    for entry in "${EXPECTED_SYMLINKS[@]}"; do
        local link_path="${entry%%:*}"
        local target="${entry##*:}"
        if ! verify_symlink "$link_path" "$target"; then
            ((issues++)) || true
        fi
    done
    
    echo ""
    if [[ $issues -eq 0 ]]; then
        print_success "All symlinks verified!"
    else
        if [[ "$FIX_MODE" == "true" ]]; then
            print_info "Fixed $issues symlink(s)"
        else
            print_warning "$issues issue(s) found. Run with --fix to repair."
        fi
    fi
    return 0
}

main "$@"
