#!/bin/bash
# shellcheck disable=SC2329
# =============================================================================
# Ralph Upstream Check - Compare with Claude Code Plugin
# =============================================================================
# Checks for updates to the upstream Claude Code ralph-wiggum plugin
# and reports any significant changes we might want to incorporate.
#
# Usage:
#   ralph-upstream-check.sh [--verbose]
#
# This script is called automatically when starting an OpenCode session
# in the aidevops repository.
#
# Author: AI DevOps Framework
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly UPSTREAM_REPO="anthropics/claude-code"
readonly UPSTREAM_PATH="plugins/ralph-wiggum"
readonly UPSTREAM_API="https://api.github.com/repos/${UPSTREAM_REPO}/contents/${UPSTREAM_PATH}"
readonly CACHE_DIR="$HOME/.cache/aidevops"
readonly CACHE_FILE="${CACHE_DIR}/ralph-upstream-check.json"
readonly CACHE_TTL=86400  # 24 hours in seconds

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

verbose=false

log_info() {
    echo -e "${BLUE}[ralph-upstream]${NC} $1"
    return 0
}

log_success() {
    echo -e "${GREEN}[ralph-upstream]${NC} $1"
    return 0
}

log_warning() {
    echo -e "${YELLOW}[ralph-upstream]${NC} $1"
    return 0
}

log_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo -e "${BLUE}[ralph-upstream]${NC} $1"
    fi
    return 0
}

# =============================================================================
# Cache Functions
# =============================================================================

ensure_cache_dir() {
    mkdir -p "$CACHE_DIR"
    return 0
}

is_cache_valid() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi
    
    local cache_time
    cache_time=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    local current_time
    current_time=$(date +%s)
    local age=$((current_time - cache_time))
    
    if [[ $age -lt $CACHE_TTL ]]; then
        return 0
    fi
    return 1
}

read_cache() {
    if [[ -f "$CACHE_FILE" ]]; then
        cat "$CACHE_FILE"
    fi
    return 0
}

write_cache() {
    local data="$1"
    ensure_cache_dir
    echo "$data" > "$CACHE_FILE"
    return 0
}

# =============================================================================
# API Functions
# =============================================================================

fetch_upstream_info() {
    local response
    
    # Try to fetch from GitHub API
    if ! response=$(curl -sf -H "Accept: application/vnd.github.v3+json" "$UPSTREAM_API" 2>/dev/null); then
        log_verbose "Failed to fetch upstream info (network error or rate limit)"
        return 1
    fi
    
    echo "$response"
}

get_file_sha() {
    local json="$1"
    local filename="$2"
    
    echo "$json" | jq -r ".[] | select(.name == \"$filename\") | .sha" 2>/dev/null || echo ""
    return 0
}

fetch_file_content() {
    local filename="$1"
    local url="https://raw.githubusercontent.com/${UPSTREAM_REPO}/main/${UPSTREAM_PATH}/${filename}"
    
    curl -sf "$url" 2>/dev/null || echo ""
    return 0
}

# =============================================================================
# Comparison Functions
# =============================================================================

extract_version() {
    local content="$1"
    # Try to extract version from plugin.json or package.json
    echo "$content" | jq -r '.version // empty' 2>/dev/null || echo "unknown"
    return 0
}

compare_implementations() {
    local upstream_readme
    local upstream_setup
    local changes_found=false
    
    log_verbose "Fetching upstream README.md..." >&2
    upstream_readme=$(fetch_file_content "README.md")
    
    log_verbose "Fetching upstream setup script..." >&2
    upstream_setup=$(fetch_file_content "scripts/setup-ralph-loop.sh")
    
    # Check for new features in README
    if [[ -n "$upstream_readme" ]]; then
        # Look for new options we don't have
        local new_options
        new_options=$(echo "$upstream_readme" | grep -oE '\-\-[a-z-]+' | sort -u | grep -vE 'max-iterations|completion-promise|help' || true)
        if [[ -n "$new_options" ]]; then
            log_warning "Upstream may have new command-line options:" >&2
            echo "$new_options" | head -5 >&2
            changes_found=true
        fi
        
        # Check for new sections
        local new_sections
        new_sections=$(echo "$upstream_readme" | grep -E '^## ' | grep -vE 'What is Ralph|Quick Start|Commands|Philosophy|When to Use|Learn More|Prompt Writing|Completion Promise|State File|Cross-Tool|Monitoring|Real-World|For Help' || true)
        if [[ -n "$new_sections" ]]; then
            log_warning "Upstream has new documentation sections:" >&2
            echo "$new_sections" | head -5 >&2
            changes_found=true
        fi
    fi
    
    # Check for new features in setup script
    if [[ -n "$upstream_setup" ]]; then
        # Look for new case options
        local upstream_options
        upstream_options=$(echo "$upstream_setup" | grep -E '^\s+--[a-z-]+\)' | sed 's/)//' | tr -d ' ' || true)
        
        local our_options="max-iterations completion-promise help"
        
        for opt in $upstream_options; do
            # Strip leading dashes for comparison
            local opt_name="${opt#--}"
            if ! echo "$our_options" | grep -qF "$opt_name"; then
                log_warning "Upstream has new option: $opt" >&2
                changes_found=true
            fi
        done
    fi
    
    if [[ "$changes_found" == "false" ]]; then
        log_success "No significant upstream changes detected" >&2
    fi
    
    echo "$changes_found"
    return 0
}

# =============================================================================
# Main Check Function
# =============================================================================

check_upstream() {
    log_info "Checking for upstream ralph-wiggum plugin updates..."
    
    # Check cache first
    if is_cache_valid; then
        local cached
        cached=$(read_cache)
        local cached_result
        cached_result=$(echo "$cached" | jq -r '.result // "unknown"' 2>/dev/null || echo "unknown")
        
        if [[ "$cached_result" == "no_changes" ]]; then
            log_verbose "Cache valid, no changes (checked within 24h)"
            return 0
        elif [[ "$cached_result" == "changes_found" ]]; then
            log_warning "Upstream changes detected (from cache). Run with --verbose for details."
            return 0
        fi
    fi
    
    # Fetch upstream info
    local upstream_info
    if ! upstream_info=$(fetch_upstream_info); then
        log_verbose "Could not check upstream (offline or rate limited)"
        return 0
    fi
    
    # Get current SHAs
    local readme_sha
    local setup_sha
    readme_sha=$(get_file_sha "$upstream_info" "README.md")
    setup_sha=$(get_file_sha "$upstream_info" "scripts")
    
    # Check against cached SHAs
    local cached_readme_sha=""
    local cached_setup_sha=""
    if [[ -f "$CACHE_FILE" ]]; then
        cached_readme_sha=$(jq -r '.readme_sha // ""' "$CACHE_FILE" 2>/dev/null || echo "")
        cached_setup_sha=$(jq -r '.setup_sha // ""' "$CACHE_FILE" 2>/dev/null || echo "")
    fi
    
    # If SHAs match, no changes
    if [[ "$readme_sha" == "$cached_readme_sha" ]] && [[ "$setup_sha" == "$cached_setup_sha" ]] && [[ -n "$cached_readme_sha" ]]; then
        log_verbose "Upstream unchanged since last check"
        write_cache "{\"result\": \"no_changes\", \"readme_sha\": \"$readme_sha\", \"setup_sha\": \"$setup_sha\", \"checked\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
        return 0
    fi
    
    # SHAs differ or first check - do detailed comparison
    log_info "Upstream files have changed, analyzing..."
    local changes_found
    changes_found=$(compare_implementations)
    
    # Update cache
    local result="no_changes"
    if [[ "$changes_found" == "true" ]]; then
        result="changes_found"
        log_warning "Review upstream changes: https://github.com/${UPSTREAM_REPO}/tree/main/${UPSTREAM_PATH}"
    fi
    
    write_cache "{\"result\": \"$result\", \"readme_sha\": \"$readme_sha\", \"setup_sha\": \"$setup_sha\", \"checked\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    
    return 0
}

show_help() {
    cat << 'EOF'
Ralph Upstream Check - Compare with Claude Code Plugin

USAGE:
  ralph-upstream-check.sh [OPTIONS]

OPTIONS:
  --verbose, -v    Show detailed output
  --force, -f      Force check (ignore cache)
  --help, -h       Show this help

DESCRIPTION:
  Checks for updates to the upstream Claude Code ralph-wiggum plugin
  and reports any significant changes we might want to incorporate.

  Results are cached for 24 hours to avoid excessive API calls.

  This script runs automatically when starting an OpenCode session
  in the aidevops repository.

UPSTREAM:
  https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum
EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local force=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose|-v)
                verbose=true
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_help
                return 1
                ;;
        esac
    done
    
    # Clear cache if force
    if [[ "$force" == "true" ]] && [[ -f "$CACHE_FILE" ]]; then
        rm -f "$CACHE_FILE"
    fi
    
    check_upstream
    
    return 0
}

main "$@"
exit $?
