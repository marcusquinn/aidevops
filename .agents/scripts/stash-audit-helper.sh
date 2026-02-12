#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155

# =============================================================================
# Git Stash Audit Helper Script
# =============================================================================
# Audit and cleanup git stashes with safety checks.
# Classifies stashes as safe-to-drop, obsolete, or needs-review.
# Never drops stashes containing user work that isn't in HEAD.
#
# Usage:
#   stash-audit-helper.sh <command> [options]
#
# Commands:
#   audit [--repo PATH]        Audit all stashes and show classification
#   clean [--repo PATH]        Drop safe-to-drop stashes (interactive)
#   auto-clean [--repo PATH]   Drop safe-to-drop stashes (non-interactive)
#   list [--repo PATH]         List all stashes with details
#   help                       Show this help
#
# Classification:
#   safe-to-drop    All changes are in HEAD (can drop safely)
#   obsolete        Stash is old (>30 days) and likely irrelevant
#   needs-review    Contains changes not in HEAD (manual review needed)
#
# Examples:
#   stash-audit-helper.sh audit
#   stash-audit-helper.sh clean
#   stash-audit-helper.sh auto-clean --repo /path/to/repo
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly BOLD='\033[1m'
readonly RESET="$NC"  # Alias for NC from shared-constants.sh
readonly STASH_AGE_THRESHOLD=30  # days

# Color constants are defined in shared-constants.sh

#######################################
# Logging functions
#######################################
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

#######################################
# Show help message
# Arguments:
#   None
# Returns:
#   0 always
#######################################
show_help() {
    cat << 'EOF'
Git Stash Audit Helper

Usage:
  stash-audit-helper.sh <command> [options]

Commands:
  audit [--repo PATH]        Audit all stashes and show classification
  clean [--repo PATH]        Drop safe-to-drop stashes (interactive)
  auto-clean [--repo PATH]   Drop safe-to-drop stashes (non-interactive)
  list [--repo PATH]         List all stashes with details
  help                       Show this help

Classification:
  safe-to-drop    All changes are in HEAD (can drop safely)
  obsolete        Stash is old (>30 days) and likely irrelevant
  needs-review    Contains changes not in HEAD (manual review needed)

Examples:
  stash-audit-helper.sh audit
  stash-audit-helper.sh clean
  stash-audit-helper.sh auto-clean --repo /path/to/repo

Safety:
  - Never drops stashes with changes not in HEAD
  - Interactive mode asks for confirmation before dropping
  - Auto-clean only drops stashes classified as safe-to-drop
  - Dry-run available via audit command
EOF
    return 0
}

#######################################
# Get repository root
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
# Outputs:
#   Repository root path
#######################################
get_repo_root() {
    local repo_path="${1:-$(pwd)}"
    
    if [[ ! -d "$repo_path" ]]; then
        log_error "Directory does not exist: $repo_path"
        return 1
    fi
    
    cd "$repo_path" || return 1
    
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null)
    
    if [[ -z "$root" ]]; then
        log_error "Not a git repository: $repo_path"
        return 1
    fi
    
    echo "$root"
    return 0
}

#######################################
# Get stash age in days
# Arguments:
#   $1 - Stash reference (e.g., stash@{0})
# Returns:
#   0 on success, 1 on failure
# Outputs:
#   Age in days
#######################################
get_stash_age() {
    local stash_ref="$1"
    local stash_timestamp
    local current_timestamp
    local age_seconds
    local age_days
    
    stash_timestamp=$(git log -1 --format=%ct "$stash_ref" 2>/dev/null)
    if [[ -z "$stash_timestamp" ]]; then
        echo "0"
        return 1
    fi
    
    current_timestamp=$(date +%s)
    age_seconds=$((current_timestamp - stash_timestamp))
    age_days=$((age_seconds / 86400))
    
    echo "$age_days"
    return 0
}

#######################################
# Check if stash changes are in HEAD
# Arguments:
#   $1 - Stash reference (e.g., stash@{0})
# Returns:
#   0 if all changes are in HEAD, 1 otherwise
#######################################
stash_changes_in_head() {
    local stash_ref="$1"
    
    # Get files changed in the stash
    local stash_files
    stash_files=$(git stash show --name-only "$stash_ref" 2>/dev/null || echo "")
    
    if [[ -z "$stash_files" ]]; then
        # Empty stash, safe to drop
        return 0
    fi
    
    # For each file in stash, compare content with HEAD
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        
        # Get file content from stash and HEAD
        local stash_content
        local head_content
        
        stash_content=$(git show "$stash_ref:$file" 2>/dev/null || echo "__STASH_FILE_NOT_FOUND__")
        head_content=$(git show "HEAD:$file" 2>/dev/null || echo "__HEAD_FILE_NOT_FOUND__")
        
        # If content differs, stash has unique changes
        if [[ "$stash_content" != "$head_content" ]]; then
            return 1
        fi
    done <<< "$stash_files"
    
    # All files match HEAD
    return 0
}

#######################################
# Classify a stash
# Arguments:
#   $1 - Stash reference (e.g., stash@{0})
# Returns:
#   0 on success, 1 on failure
# Outputs:
#   Classification: safe-to-drop, obsolete, or needs-review
#######################################
classify_stash() {
    local stash_ref="$1"
    
    # Check if all changes are in HEAD
    if stash_changes_in_head "$stash_ref"; then
        echo "safe-to-drop"
        return 0
    fi
    
    # Check age
    local age_days
    age_days=$(get_stash_age "$stash_ref")
    
    if [[ "$age_days" -ge "$STASH_AGE_THRESHOLD" ]]; then
        echo "obsolete"
        return 0
    fi
    
    echo "needs-review"
    return 0
}

#######################################
# Audit all stashes
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_audit() {
    local repo_path="${1:-$(pwd)}"
    local repo_root
    
    repo_root=$(get_repo_root "$repo_path")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    cd "$repo_root" || return 1
    
    # Get stash list
    local stash_list
    stash_list=$(git stash list 2>/dev/null)
    
    if [[ -z "$stash_list" ]]; then
        log_info "No stashes found"
        return 0
    fi
    
    log_info "Auditing stashes in: $repo_root"
    echo ""
    
    local safe_count=0
    local obsolete_count=0
    local review_count=0
    
    while IFS= read -r stash_line; do
        local stash_ref
        stash_ref=$(echo "$stash_line" | cut -d: -f1)
        
        local classification
        classification=$(classify_stash "$stash_ref")
        
        local age_days
        age_days=$(get_stash_age "$stash_ref")
        
        local message
        message=$(echo "$stash_line" | cut -d: -f2- | sed 's/^ //')
        
        case "$classification" in
            safe-to-drop)
                echo -e "${GREEN}✓${RESET} $stash_ref (${age_days}d): $message"
                echo "  → safe-to-drop (all changes in HEAD)"
                safe_count=$((safe_count + 1))
                ;;
            obsolete)
                echo -e "${YELLOW}⚠${RESET} $stash_ref (${age_days}d): $message"
                echo "  → obsolete (>$STASH_AGE_THRESHOLD days old)"
                obsolete_count=$((obsolete_count + 1))
                ;;
            needs-review)
                echo -e "${RED}✗${RESET} $stash_ref (${age_days}d): $message"
                echo "  → needs-review (contains unique changes)"
                review_count=$((review_count + 1))
                ;;
        esac
        echo ""
    done <<< "$stash_list"
    
    log_info "Summary:"
    echo "  Safe to drop:  $safe_count"
    echo "  Obsolete:      $obsolete_count"
    echo "  Needs review:  $review_count"
    echo "  Total:         $((safe_count + obsolete_count + review_count))"
    
    return 0
}

#######################################
# List all stashes with details
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_list() {
    local repo_path="${1:-$(pwd)}"
    local repo_root
    
    repo_root=$(get_repo_root "$repo_path")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    cd "$repo_root" || return 1
    
    log_info "Stashes in: $repo_root"
    echo ""
    
    git stash list --format="%gd: %cr - %s" 2>/dev/null
    
    return 0
}

#######################################
# Clean safe-to-drop stashes (interactive)
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_clean() {
    local repo_path="${1:-$(pwd)}"
    local repo_root
    
    repo_root=$(get_repo_root "$repo_path")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    cd "$repo_root" || return 1
    
    # Get stash list
    local stash_list
    stash_list=$(git stash list 2>/dev/null)
    
    if [[ -z "$stash_list" ]]; then
        log_info "No stashes found"
        return 0
    fi
    
    log_info "Finding safe-to-drop stashes..."
    echo ""
    
    local safe_stashes=()
    
    while IFS= read -r stash_line; do
        local stash_ref
        stash_ref=$(echo "$stash_line" | cut -d: -f1)
        
        local classification
        classification=$(classify_stash "$stash_ref")
        
        if [[ "$classification" == "safe-to-drop" ]]; then
            safe_stashes+=("$stash_ref")
            local message
            message=$(echo "$stash_line" | cut -d: -f2- | sed 's/^ //')
            echo "  $stash_ref: $message"
        fi
    done <<< "$stash_list"
    
    if [[ ${#safe_stashes[@]} -eq 0 ]]; then
        log_info "No safe-to-drop stashes found"
        return 0
    fi
    
    echo ""
    log_warn "Found ${#safe_stashes[@]} safe-to-drop stash(es)"
    echo -n "Drop these stashes? [y/N] "
    read -r response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        return 0
    fi
    
    local dropped=0
    for stash_ref in "${safe_stashes[@]}"; do
        if git stash drop "$stash_ref" 2>/dev/null; then
            log_success "Dropped: $stash_ref"
            dropped=$((dropped + 1))
        else
            log_error "Failed to drop: $stash_ref"
        fi
    done
    
    log_success "Dropped $dropped stash(es)"
    
    return 0
}

#######################################
# Auto-clean safe-to-drop stashes (non-interactive)
# Arguments:
#   $1 - Optional repo path
# Returns:
#   0 on success, 1 on failure
#######################################
cmd_auto_clean() {
    local repo_path="${1:-$(pwd)}"
    local repo_root
    
    repo_root=$(get_repo_root "$repo_path")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    cd "$repo_root" || return 1
    
    # Get stash list
    local stash_list
    stash_list=$(git stash list 2>/dev/null)
    
    if [[ -z "$stash_list" ]]; then
        log_info "No stashes found in: $repo_root"
        return 0
    fi
    
    local safe_stashes=()
    
    while IFS= read -r stash_line; do
        local stash_ref
        stash_ref=$(echo "$stash_line" | cut -d: -f1)
        
        local classification
        classification=$(classify_stash "$stash_ref")
        
        if [[ "$classification" == "safe-to-drop" ]]; then
            safe_stashes+=("$stash_ref")
        fi
    done <<< "$stash_list"
    
    if [[ ${#safe_stashes[@]} -eq 0 ]]; then
        log_info "No safe-to-drop stashes found in: $repo_root"
        return 0
    fi
    
    log_info "Auto-cleaning ${#safe_stashes[@]} safe-to-drop stash(es) in: $repo_root"
    
    local dropped=0
    for stash_ref in "${safe_stashes[@]}"; do
        if git stash drop "$stash_ref" 2>/dev/null; then
            log_info "  Dropped: $stash_ref"
            dropped=$((dropped + 1))
        else
            log_warn "  Failed to drop: $stash_ref"
        fi
    done
    
    if [[ "$dropped" -gt 0 ]]; then
        log_success "Auto-cleaned $dropped stash(es) in: $repo_root"
    fi
    
    return 0
}

#######################################
# Main entry point
# Arguments:
#   $@ - Command and options
# Returns:
#   0 on success, 1 on failure
#######################################
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        return 1
    fi
    
    local command="$1"
    shift
    
    local repo_path=""
    
    # Parse common options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                repo_path="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    case "$command" in
        audit)
            cmd_audit "$repo_path"
            ;;
        clean)
            cmd_clean "$repo_path"
            ;;
        auto-clean)
            cmd_auto_clean "$repo_path"
            ;;
        list)
            cmd_list "$repo_path"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
    
    return $?
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
