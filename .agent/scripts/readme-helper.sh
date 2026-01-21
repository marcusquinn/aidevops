#!/bin/bash
# shellcheck disable=SC2034,SC2155

# AI DevOps Framework - README Helper
# Manages dynamic counts and README maintenance tasks

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/.agent"

# Color output functions
print_success() { local msg="$1"; echo -e "\033[32m[SUCCESS]\033[0m $msg"; return 0; }
print_error() { local msg="$1"; echo -e "\033[31m[ERROR]\033[0m $msg"; return 0; }
print_warning() { local msg="$1"; echo -e "\033[33m[WARNING]\033[0m $msg"; return 0; }
print_info() { local msg="$1"; echo -e "\033[34m[INFO]\033[0m $msg"; return 0; }

# Count main agents (*.md files in .agent/ root, excluding AGENTS.md)
count_main_agents() {
    local count
    count=$(find "$AGENT_DIR" -maxdepth 1 -name "*.md" -type f ! -name "AGENTS.md" 2>/dev/null | wc -l | tr -d ' ')
    echo "$count"
    return 0
}

# Count subagent markdown files (all .md files in subdirectories)
count_subagents() {
    local count
    count=$(find "$AGENT_DIR" -mindepth 2 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "$count"
    return 0
}

# Count helper scripts
count_scripts() {
    local count
    count=$(find "$AGENT_DIR/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "$count"
    return 0
}

# Get all counts as JSON
get_counts_json() {
    local main_agents subagents scripts
    main_agents=$(count_main_agents)
    subagents=$(count_subagents)
    scripts=$(count_scripts)
    
    echo "{\"main_agents\": $main_agents, \"subagents\": $subagents, \"scripts\": $scripts}"
    return 0
}

# Get approximate counts (for README display)
get_approximate_counts() {
    local main_agents subagents scripts
    main_agents=$(count_main_agents)
    subagents=$(count_subagents)
    scripts=$(count_scripts)
    
    # Round to nearest 5 or 10 for cleaner display
    local approx_agents approx_subagents approx_scripts
    
    # For agents, use ~N format
    approx_agents="~$main_agents"
    
    # For subagents, round to nearest 50
    if [[ $subagents -ge 200 ]]; then
        approx_subagents="$((subagents / 50 * 50))+"
    else
        approx_subagents="$((subagents / 10 * 10))+"
    fi
    
    # For scripts, round to nearest 10
    approx_scripts="$((scripts / 10 * 10))+"
    
    echo "main_agents=$approx_agents"
    echo "subagents=$approx_subagents"
    echo "scripts=$approx_scripts"
    return 0
}

# Check if README counts are stale
check_readme_counts() {
    local readme_file="${1:-$REPO_ROOT/README.md}"
    
    if [[ ! -f "$readme_file" ]]; then
        print_error "README not found: $readme_file"
        return 1
    fi
    
    local main_agents subagents scripts
    main_agents=$(count_main_agents)
    subagents=$(count_subagents)
    scripts=$(count_scripts)
    
    print_info "Current counts:"
    echo "  Main agents: $main_agents"
    echo "  Subagents: $subagents"
    echo "  Scripts: $scripts"
    echo ""
    
    # Check for count patterns in README
    local stale=0
    
    # Check main agents count (patterns like "~15 main agents" or "14 domain agents")
    if grep -qE "~?[0-9]+ (main|domain) agents" "$readme_file"; then
        local readme_count
        readme_count=$(grep -oE "~?[0-9]+ (main|domain) agents" "$readme_file" | head -1 | grep -oE "[0-9]+")
        local diff=$((main_agents - readme_count))
        if [[ ${diff#-} -gt 2 ]]; then
            print_warning "Main agents count may be stale: README says ~$readme_count, actual is $main_agents"
            stale=1
        else
            print_success "Main agents count is current (~$readme_count vs $main_agents)"
        fi
    fi
    
    # Check scripts count (patterns like "100+ helper scripts" or "130+ scripts")
    if grep -qE "[0-9]+\+ (helper )?scripts" "$readme_file"; then
        local readme_scripts
        readme_scripts=$(grep -oE "[0-9]+\+ (helper )?scripts" "$readme_file" | head -1 | grep -oE "[0-9]+")
        if [[ $scripts -lt $readme_scripts ]]; then
            print_warning "Scripts count may be overstated: README says $readme_scripts+, actual is $scripts"
            stale=1
        elif [[ $((scripts - readme_scripts)) -gt 20 ]]; then
            print_warning "Scripts count may be understated: README says $readme_scripts+, actual is $scripts"
            stale=1
        else
            print_success "Scripts count is current ($readme_scripts+ vs $scripts)"
        fi
    fi
    
    # Check subagents count
    if grep -qE "[0-9]+\+ subagent" "$readme_file"; then
        local readme_subagents
        readme_subagents=$(grep -oE "[0-9]+\+ subagent" "$readme_file" | head -1 | grep -oE "[0-9]+")
        if [[ $subagents -lt $readme_subagents ]]; then
            print_warning "Subagents count may be overstated: README says $readme_subagents+, actual is $subagents"
            stale=1
        elif [[ $((subagents - readme_subagents)) -gt 50 ]]; then
            print_warning "Subagents count may be understated: README says $readme_subagents+, actual is $subagents"
            stale=1
        else
            print_success "Subagents count is current ($readme_subagents+ vs $subagents)"
        fi
    fi
    
    if [[ $stale -eq 1 ]]; then
        echo ""
        print_info "Suggested updates:"
        get_approximate_counts
        return 1
    fi
    
    return 0
}

# Update README counts (dry-run by default)
update_readme_counts() {
    local readme_file="${1:-$REPO_ROOT/README.md}"
    local dry_run="${2:-true}"
    
    if [[ ! -f "$readme_file" ]]; then
        print_error "README not found: $readme_file"
        return 1
    fi
    
    local main_agents subagents scripts
    main_agents=$(count_main_agents)
    subagents=$(count_subagents)
    scripts=$(count_scripts)
    
    # Calculate approximate values
    local approx_scripts approx_subagents
    approx_scripts=$((scripts / 10 * 10))
    approx_subagents=$((subagents / 50 * 50))
    
    if [[ "$dry_run" == "true" ]]; then
        print_info "Dry run - would update:"
        echo "  Main agents: ~$main_agents"
        echo "  Subagents: ${approx_subagents}+"
        echo "  Scripts: ${approx_scripts}+"
        echo ""
        print_info "Run with --apply to make changes"
        return 0
    fi
    
    # Create backup
    cp "$readme_file" "$readme_file.bak"
    
    # Update patterns
    # ~N main agents or ~N domain agents
    sed -i.tmp -E "s/~[0-9]+ (main|domain) agents/~$main_agents \1 agents/g" "$readme_file"
    
    # N+ helper scripts
    sed -i.tmp -E "s/[0-9]+\+ helper scripts/${approx_scripts}+ helper scripts/g" "$readme_file"
    
    # N+ subagent markdown files
    sed -i.tmp -E "s/[0-9]+\+ subagent/${approx_subagents}+ subagent/g" "$readme_file"
    
    # Clean up temp files
    rm -f "$readme_file.tmp"
    
    print_success "Updated README counts"
    print_info "Backup saved to $readme_file.bak"
    
    # Show diff
    if command -v diff &>/dev/null; then
        echo ""
        print_info "Changes:"
        diff "$readme_file.bak" "$readme_file" || true
    fi
    
    return 0
}

# Show help
show_help() {
    cat << 'EOF'
AI DevOps Framework - README Helper

Usage: readme-helper.sh <command> [options]

Commands:
  counts              Show current counts (main agents, subagents, scripts)
  counts --json       Show counts as JSON
  counts --approx     Show approximate counts for README display
  
  check [file]        Check if README counts are stale
  
  update [file]       Update README counts (dry-run)
  update --apply      Update README counts (apply changes)

Examples:
  # Check current counts
  readme-helper.sh counts
  
  # Check if README is stale
  readme-helper.sh check
  
  # Preview updates
  readme-helper.sh update
  
  # Apply updates
  readme-helper.sh update --apply

EOF
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        counts)
            case "${1:-}" in
                --json)
                    get_counts_json
                    ;;
                --approx)
                    get_approximate_counts
                    ;;
                *)
                    print_info "Current counts:"
                    echo "  Main agents: $(count_main_agents)"
                    echo "  Subagents: $(count_subagents)"
                    echo "  Scripts: $(count_scripts)"
                    ;;
            esac
            ;;
        check)
            check_readme_counts "${1:-}"
            ;;
        update)
            local apply="false"
            local file=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --apply) apply="true"; shift ;;
                    *) file="$1"; shift ;;
                esac
            done
            if [[ "$apply" == "true" ]]; then
                update_readme_counts "$file" "false"
            else
                update_readme_counts "$file" "true"
            fi
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
    
    return 0
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
