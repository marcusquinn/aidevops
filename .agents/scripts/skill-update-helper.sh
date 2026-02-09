#!/usr/bin/env bash
# =============================================================================
# Skill Update Helper
# =============================================================================
# Check imported skills for upstream updates and optionally auto-update.
# Designed to be run periodically (e.g., weekly cron) or on-demand.
#
# Usage:
#   skill-update-helper.sh check           # Check for updates (default)
#   skill-update-helper.sh update [name]   # Update specific or all skills
#   skill-update-helper.sh status          # Show skill status summary
#
# Options:
#   --auto-update    Automatically update skills with changes
#   --quiet          Suppress non-essential output
#   --json           Output in JSON format
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
SKILL_SOURCES="${AGENTS_DIR}/configs/skill-sources.json"
ADD_SKILL_HELPER="${AGENTS_DIR}/scripts/add-skill-helper.sh"

# Options
AUTO_UPDATE=false
QUIET=false
JSON_OUTPUT=false

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    if [[ "$QUIET" != true ]]; then
        echo -e "${BLUE}[skill-update]${NC} $1"
    fi
    return 0
}

log_success() {
    if [[ "$QUIET" != true ]]; then
        echo -e "${GREEN}[OK]${NC} $1"
    fi
    return 0
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    return 0
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    return 0
}

show_help() {
    cat << 'EOF'
Skill Update Helper - Check and update imported skills

USAGE:
    skill-update-helper.sh <command> [options]

COMMANDS:
    check              Check all skills for upstream updates (default)
    update [name]      Update specific skill or all if no name given
    status             Show summary of all imported skills

OPTIONS:
    --auto-update      Automatically update skills with changes
    --quiet            Suppress non-essential output
    --json             Output results in JSON format

EXAMPLES:
    # Check for updates
    skill-update-helper.sh check

    # Check and auto-update
    skill-update-helper.sh check --auto-update

    # Update specific skill
    skill-update-helper.sh update cloudflare

    # Update all skills
    skill-update-helper.sh update

    # Get status in JSON (for scripting)
    skill-update-helper.sh status --json

CRON EXAMPLE:
    # Weekly update check (Sundays at 3am)
    0 3 * * 0 ~/.aidevops/agents/scripts/skill-update-helper.sh check --quiet
EOF
    return 0
}

# Check if jq is available
require_jq() {
    if ! command -v jq &>/dev/null; then
        log_error "jq is required for this operation"
        log_info "Install with: brew install jq (macOS) or apt install jq (Ubuntu)"
        exit 1
    fi
    return 0
}

# Check if skill-sources.json exists and has skills
check_skill_sources() {
    if [[ ! -f "$SKILL_SOURCES" ]]; then
        log_info "No skill-sources.json found. No imported skills to check."
        exit 0
    fi
    
    local count
    count=$(jq '.skills | length' "$SKILL_SOURCES" 2>/dev/null || echo "0")
    
    if [[ "$count" -eq 0 ]]; then
        log_info "No imported skills found."
        exit 0
    fi
    
    echo "$count"
    return 0
}

# Parse GitHub URL to extract owner/repo
parse_github_url() {
    local url="$1"
    
    # Remove https://github.com/ prefix
    url="${url#https://github.com/}"
    url="${url#http://github.com/}"
    url="${url#github.com/}"
    
    # Remove .git suffix
    url="${url%.git}"
    
    # Remove /tree/... suffix
    url=$(echo "$url" | sed -E 's|/tree/[^/]+(/.*)?$|\1|')
    
    echo "$url"
    return 0
}

# Get latest commit from GitHub API
get_latest_commit() {
    local owner_repo="$1"
    
    local api_url="https://api.github.com/repos/$owner_repo/commits?per_page=1"
    local response
    
    response=$(curl -s --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github.v3+json" "$api_url" 2>/dev/null)
    
    if [[ -z "$response" ]]; then
        return 1
    fi
    
    local commit
    commit=$(echo "$response" | jq -r '.[0].sha // empty' 2>/dev/null)
    
    if [[ -z "$commit" || "$commit" == "null" ]]; then
        return 1
    fi
    
    echo "$commit"
    return 0
}

# Update last_checked timestamp
update_last_checked() {
    local skill_name="$1"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local tmp_file
    tmp_file=$(mktemp)
    _save_cleanup_scope; trap '_run_cleanups' RETURN
    push_cleanup "rm -f '${tmp_file}'"
    
    jq --arg name "$skill_name" --arg ts "$timestamp" \
        '.skills = [.skills[] | if .name == $name then .last_checked = $ts else . end]' \
        "$SKILL_SOURCES" > "$tmp_file" && mv "$tmp_file" "$SKILL_SOURCES"
    return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_check() {
    require_jq
    
    local skill_count
    skill_count=$(check_skill_sources)
    
    log_info "Checking $skill_count imported skill(s) for updates..."
    echo ""
    
    local updates_available=0
    local up_to_date=0
    local check_failed=0
    local results=()
    
    # Read skills from JSON
    while IFS= read -r skill_json; do
        local name upstream_url current_commit
        name=$(echo "$skill_json" | jq -r '.name')
        upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
        current_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')
        
        # Parse owner/repo from URL
        local owner_repo
        owner_repo=$(parse_github_url "$upstream_url")
        
        # Extract just owner/repo (first two path components)
        owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)
        
        if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
            log_warning "Could not parse URL for $name: $upstream_url"
            ((check_failed++)) || true
            continue
        fi
        
        # Get latest commit
        local latest_commit
        if ! latest_commit=$(get_latest_commit "$owner_repo"); then
            log_warning "Could not fetch latest commit for $name ($owner_repo)"
            ((check_failed++)) || true
            continue
        fi
        
        # Update last_checked timestamp
        update_last_checked "$name"
        
        # Compare commits
        if [[ -z "$current_commit" ]]; then
            # No commit recorded, consider as update available
            echo -e "${YELLOW}UNKNOWN${NC}: $name (no commit recorded)"
            echo "  Source: $upstream_url"
            echo "  Latest: ${latest_commit:0:7}"
            echo ""
            ((updates_available++)) || true
            results+=("{\"name\":\"$name\",\"status\":\"unknown\",\"latest\":\"$latest_commit\"}")
        elif [[ "$latest_commit" != "$current_commit" ]]; then
            echo -e "${YELLOW}UPDATE AVAILABLE${NC}: $name"
            echo "  Current: ${current_commit:0:7}"
            echo "  Latest:  ${latest_commit:0:7}"
            echo "  Run: aidevops skill update $name"
            echo ""
            ((updates_available++)) || true
            results+=("{\"name\":\"$name\",\"status\":\"update_available\",\"current\":\"$current_commit\",\"latest\":\"$latest_commit\"}")
            
            # Auto-update if enabled
            if [[ "$AUTO_UPDATE" == true ]]; then
                log_info "Auto-updating $name..."
                if "$ADD_SKILL_HELPER" add "$upstream_url" --force; then
                    log_success "Updated $name"
                else
                    log_error "Failed to update $name"
                fi
            fi
        else
            echo -e "${GREEN}Up to date${NC}: $name"
            ((up_to_date++)) || true
            results+=("{\"name\":\"$name\",\"status\":\"up_to_date\",\"commit\":\"$current_commit\"}")
        fi
        
    done < <(jq -c '.skills[]' "$SKILL_SOURCES")
    
    # Summary
    echo ""
    echo "Summary:"
    echo "  Up to date: $up_to_date"
    echo "  Updates available: $updates_available"
    if [[ $check_failed -gt 0 ]]; then
        echo "  Check failed: $check_failed"
    fi
    
    # JSON output if requested
    if [[ "$JSON_OUTPUT" == true ]]; then
        echo ""
        echo "{"
        echo "  \"up_to_date\": $up_to_date,"
        echo "  \"updates_available\": $updates_available,"
        echo "  \"check_failed\": $check_failed,"
        # Join results array with comma using printf
        local results_json
        results_json=$(printf '%s,' "${results[@]}")
        results_json="${results_json%,}"  # Remove trailing comma
        echo "  \"results\": [$results_json]"
        echo "}"
    fi
    
    # Return non-zero if updates available (useful for CI)
    if [[ $updates_available -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

cmd_update() {
    local skill_name="${1:-}"
    
    require_jq
    check_skill_sources >/dev/null
    
    if [[ -n "$skill_name" ]]; then
        # Update specific skill
        local upstream_url
        upstream_url=$(jq -r --arg name "$skill_name" '.skills[] | select(.name == $name) | .upstream_url' "$SKILL_SOURCES")
        
        if [[ -z "$upstream_url" ]]; then
            log_error "Skill not found: $skill_name"
            return 1
        fi
        
        log_info "Updating $skill_name from $upstream_url"
        "$ADD_SKILL_HELPER" add "$upstream_url" --force
    else
        # Update all skills with available updates
        log_info "Checking and updating all skills..."
        AUTO_UPDATE=true
        # cmd_check returns 1 when updates are available, which is expected here
        cmd_check || true
    fi
    
    return 0
}

cmd_status() {
    require_jq
    
    local skill_count
    skill_count=$(check_skill_sources)
    
    if [[ "$JSON_OUTPUT" == true ]]; then
        jq '{
            total: (.skills | length),
            skills: [.skills[] | {
                name: .name,
                upstream: .upstream_url,
                local_path: .local_path,
                format: .format_detected,
                imported: .imported_at,
                last_checked: .last_checked,
                strategy: .merge_strategy
            }]
        }' "$SKILL_SOURCES"
        return 0
    fi
    
    echo ""
    echo "Imported Skills Status"
    echo "======================"
    echo ""
    echo "Total: $skill_count skill(s)"
    echo ""
    
    jq -r '.skills[] | "  \(.name)\n    Path: \(.local_path)\n    Source: \(.upstream_url)\n    Format: \(.format_detected)\n    Imported: \(.imported_at)\n    Last checked: \(.last_checked // "never")\n    Strategy: \(.merge_strategy)\n"' "$SKILL_SOURCES"
    
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="check"
    local skill_name=""
    
    # Parse arguments using named variable for clarity (S7679)
    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            check|update|status)
                command="$arg"
                shift
                ;;
            --auto-update)
                AUTO_UPDATE=true
                shift
                ;;
            --quiet|-q)
                QUIET=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $arg"
                show_help
                exit 1
                ;;
            *)
                # Assume it's a skill name for update command
                skill_name="$arg"
                shift
                ;;
        esac
    done
    
    case "$command" in
        check)
            cmd_check
            ;;
        update)
            cmd_update "$skill_name"
            ;;
        status)
            cmd_status
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
