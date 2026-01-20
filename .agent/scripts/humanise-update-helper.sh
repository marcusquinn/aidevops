#!/bin/bash
# Humanise Update Helper
# Checks for updates to the upstream humanizer skill and reports differences
#
# Usage:
#   humanise-update-helper.sh check     # Check for upstream updates
#   humanise-update-helper.sh diff      # Show diff between local and upstream
#   humanise-update-helper.sh version   # Show current versions
#   humanise-update-helper.sh help      # Show help
#
# Upstream: https://github.com/blader/humanizer

set -euo pipefail

# Configuration
readonly UPSTREAM_REPO="blader/humanizer"
readonly UPSTREAM_RAW="https://raw.githubusercontent.com/${UPSTREAM_REPO}/main/SKILL.md"
readonly LOCAL_SUBAGENT="${HOME}/.aidevops/agents/content/humanise.md"
SCRIPT_DIR="$(dirname "$0")"
readonly SCRIPT_DIR
readonly SOURCE_SUBAGENT="${SCRIPT_DIR}/../content/humanise.md"
readonly CACHE_DIR="${HOME}/.aidevops/.agent-workspace/cache"
readonly CACHE_FILE="${CACHE_DIR}/humanizer-upstream.md"
readonly CACHE_VERSION_FILE="${CACHE_DIR}/humanizer-version.txt"
readonly CACHE_TTL=86400  # 24 hours in seconds

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Get local version from subagent frontmatter
get_local_version() {
    local subagent_file="$1"
    if [[ -f "$subagent_file" ]]; then
        grep -E '^version:' "$subagent_file" | head -1 | sed 's/version:[[:space:]]*//' | tr -d '"'"'"
    else
        echo "not found"
    fi
    return 0
}

# Get upstream version from subagent frontmatter
get_upstream_version() {
    local subagent_file="$1"
    if [[ -f "$subagent_file" ]]; then
        grep -E '^upstream_version:' "$subagent_file" | head -1 | sed 's/upstream_version:[[:space:]]*//' | tr -d '"'"'"
    else
        echo "not found"
    fi
    return 0
}

# Fetch upstream SKILL.md
fetch_upstream() {
    mkdir -p "$CACHE_DIR"
    
    # Check cache freshness
    if [[ -f "$CACHE_FILE" && -f "$CACHE_VERSION_FILE" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt $CACHE_TTL ]]; then
            echo "Using cached upstream ($(( cache_age / 60 )) minutes old)"
            return 0
        fi
    fi
    
    echo "Fetching upstream from ${UPSTREAM_REPO}..."
    if curl -fsSL "$UPSTREAM_RAW" -o "$CACHE_FILE"; then
        # Extract version from fetched file
        local version
        version=$(grep -E '^version:' "$CACHE_FILE" | head -1 | sed 's/version:[[:space:]]*//' | tr -d '"'"'" || echo "unknown")
        echo "$version" > "$CACHE_VERSION_FILE"
        echo -e "${GREEN}Fetched upstream version: ${version}${NC}"
        return 0
    else
        echo -e "${RED}Failed to fetch upstream${NC}"
        return 1
    fi
}

# Compare versions
compare_versions() {
    local local_ver="$1"
    local upstream_ver="$2"
    
    if [[ "$local_ver" == "$upstream_ver" ]]; then
        return 0  # Same version
    fi
    
    # Use sort -V for version comparison
    local lowest
    lowest=$(printf '%s\n%s' "$local_ver" "$upstream_ver" | sort -V | head -1)
    if [[ "$lowest" == "$local_ver" ]]; then
        return 1  # Local is older
    else
        return 2  # Local is newer (shouldn't happen normally)
    fi
}

# Show version info
cmd_version() {
    local subagent_file="$LOCAL_SUBAGENT"
    if [[ -f "$SOURCE_SUBAGENT" ]]; then
        subagent_file="$SOURCE_SUBAGENT"
    fi
    
    local local_ver
    local_ver=$(get_local_version "$subagent_file")
    local upstream_tracked
    upstream_tracked=$(get_upstream_version "$subagent_file")
    
    echo -e "${BOLD}Humanise Subagent Versions${NC}"
    echo "=========================="
    echo ""
    echo -e "Local version:    ${CYAN}${local_ver}${NC}"
    echo -e "Tracking upstream: ${CYAN}${upstream_tracked}${NC}"
    echo -e "Upstream repo:    ${BLUE}https://github.com/${UPSTREAM_REPO}${NC}"
    echo ""
    
    if [[ -f "$CACHE_VERSION_FILE" ]]; then
        local cached_ver
        cached_ver=$(cat "$CACHE_VERSION_FILE")
        echo -e "Cached upstream:  ${CYAN}${cached_ver}${NC}"
    fi
}

# Check for updates
cmd_check() {
    local subagent_file="$LOCAL_SUBAGENT"
    if [[ -f "$SOURCE_SUBAGENT" ]]; then
        subagent_file="$SOURCE_SUBAGENT"
    fi
    
    if [[ ! -f "$subagent_file" ]]; then
        echo -e "${RED}Humanise subagent not found at: ${subagent_file}${NC}"
        echo "Run setup.sh to deploy agents."
        return 1
    fi
    
    local upstream_tracked
    upstream_tracked=$(get_upstream_version "$subagent_file")
    
    if ! fetch_upstream; then
        return 1
    fi
    
    local upstream_latest
    upstream_latest=$(cat "$CACHE_VERSION_FILE")
    
    echo ""
    echo -e "${BOLD}Update Check${NC}"
    echo "============"
    echo ""
    echo -e "Tracking version: ${CYAN}${upstream_tracked}${NC}"
    echo -e "Latest upstream:  ${CYAN}${upstream_latest}${NC}"
    echo ""
    
    if compare_versions "$upstream_tracked" "$upstream_latest"; then
        echo -e "${GREEN}Up to date with upstream.${NC}"
        return 0
    else
        echo -e "${YELLOW}UPDATE AVAILABLE${NC}"
        echo ""
        echo "The upstream humanizer skill has been updated."
        echo "Review changes and incorporate into the subagent:"
        echo ""
        echo "  1. Run: humanise-update-helper.sh diff"
        echo "  2. Review changes at: https://github.com/${UPSTREAM_REPO}/commits/main"
        echo "  3. Update .agent/content/humanise.md with relevant changes"
        echo "  4. Update upstream_version in frontmatter to: ${upstream_latest}"
        echo ""
        return 1
    fi
}

# Show diff between local and upstream
cmd_diff() {
    local subagent_file="$LOCAL_SUBAGENT"
    if [[ -f "$SOURCE_SUBAGENT" ]]; then
        subagent_file="$SOURCE_SUBAGENT"
    fi
    
    if ! fetch_upstream; then
        return 1
    fi
    
    if [[ ! -f "$CACHE_FILE" ]]; then
        echo -e "${RED}No cached upstream file. Run 'check' first.${NC}"
        return 1
    fi
    
    echo -e "${BOLD}Diff: Local Subagent vs Upstream SKILL.md${NC}"
    echo "=========================================="
    echo ""
    echo "Note: Local subagent has aidevops-specific adaptations."
    echo "Focus on content changes in the upstream patterns."
    echo ""
    
    # Show diff (ignore frontmatter differences)
    if command -v delta &>/dev/null; then
        diff -u "$subagent_file" "$CACHE_FILE" | delta --side-by-side || true
    elif command -v colordiff &>/dev/null; then
        diff -u "$subagent_file" "$CACHE_FILE" | colordiff || true
    else
        diff -u "$subagent_file" "$CACHE_FILE" || true
    fi
    
    echo ""
    echo -e "${BLUE}Upstream commits: https://github.com/${UPSTREAM_REPO}/commits/main${NC}"
}

# Show help
cmd_help() {
    echo "Humanise Update Helper"
    echo "======================"
    echo ""
    echo "Checks for updates to the upstream humanizer skill from:"
    echo "  https://github.com/${UPSTREAM_REPO}"
    echo ""
    echo "Usage:"
    echo "  humanise-update-helper.sh check     Check for upstream updates"
    echo "  humanise-update-helper.sh diff      Show diff between local and upstream"
    echo "  humanise-update-helper.sh version   Show current versions"
    echo "  humanise-update-helper.sh help      Show this help"
    echo ""
    echo "The humanise subagent is adapted from the upstream skill with:"
    echo "  - British English spelling (humanise, colour, etc.)"
    echo "  - aidevops frontmatter format"
    echo "  - Integration with content.md main agent"
    echo ""
    echo "When updates are available:"
    echo "  1. Review the diff and upstream commits"
    echo "  2. Incorporate relevant changes into .agent/content/humanise.md"
    echo "  3. Update the upstream_version field in frontmatter"
}

# Main
main() {
    local cmd="${1:-check}"
    
    case "$cmd" in
        check)
            cmd_check
            ;;
        diff)
            cmd_diff
            ;;
        version|ver|-v|--version)
            cmd_version
            ;;
        help|-h|--help)
            cmd_help
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'humanise-update-helper.sh help' for usage."
            exit 1
            ;;
    esac
}

main "$@"
