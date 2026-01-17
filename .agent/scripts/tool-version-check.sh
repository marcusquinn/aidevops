#!/bin/bash
# Tool Version Check
# Checks versions of key tools and flags outdated ones
#
# Usage: 
#   tool-version-check.sh              # Check all tools
#   tool-version-check.sh --update     # Check and update outdated tools
#   tool-version-check.sh --category npm  # Check only npm tools
#   tool-version-check.sh --json       # Output as JSON
#
# Categories: npm, brew, pip, all (default)

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Parse arguments
AUTO_UPDATE=false
CATEGORY="all"
JSON_OUTPUT=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update|-u)
            AUTO_UPDATE=true
            shift
            ;;
        --category|-c)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --category requires a value (npm, brew, pip, all)"
                exit 1
            fi
            CATEGORY="$2"
            shift 2
            ;;
        --json|-j)
            JSON_OUTPUT=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --help|-h)
            echo "Usage: tool-version-check.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --update, -u       Automatically update outdated tools"
            echo "  --category, -c     Check only specific category (npm, brew, pip, all)"
            echo "  --json, -j         Output results as JSON"
            echo "  --quiet, -q        Only show outdated tools"
            echo "  --help, -h         Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Tool definitions
# Format: category|display_name|cli_command|version_flag|package_name|update_command

NPM_TOOLS=(
    "npm|osgrep|osgrep|--version|osgrep|npm update -g osgrep"
    "npm|Augment CLI|auggie|--version|@augmentcode/auggie@prerelease|npm update -g @augmentcode/auggie@prerelease"
    "npm|Repomix|repomix|--version|repomix|npm update -g repomix"
    "npm|DSPyGround|dspyground|--version|dspyground|npm update -g dspyground"
    "npm|LocalWP MCP|mcp-local-wp|--version|@verygoodplugins/mcp-local-wp|npm update -g @verygoodplugins/mcp-local-wp"
    "npm|Beads UI|beads-ui|--version|beads-ui|npm update -g beads-ui"
    "npm|BDUI|bdui|--version|bdui|npm update -g bdui"
    "npm|OpenCode|opencode|--version|opencode|npm update -g opencode"
)

BREW_TOOLS=(
    "brew|GitHub CLI|gh|--version|gh|brew upgrade gh"
    "brew|GitLab CLI|glab|--version|glab|brew upgrade glab"
    "brew|Worktrunk|wt|--version|max-sixty/worktrunk/wt|brew upgrade max-sixty/worktrunk/wt"
    "brew|Beads CLI|bd|version|steveyegge/beads/bd|brew upgrade steveyegge/beads/bd"
    "brew|jq|jq|--version|jq|brew upgrade jq"
    "brew|ShellCheck|shellcheck|--version|shellcheck|brew upgrade shellcheck"
)

PIP_TOOLS=(
    "pip|Beads Viewer|beads_viewer|--version|beads-viewer|pip install --upgrade beads-viewer"
    "pip|DSPy|dspy|--version|dspy-ai|pip install --upgrade dspy-ai"
    "pip|Crawl4AI|crawl4ai|--version|crawl4ai|pip install --upgrade crawl4ai"
)

# Counters
OUTDATED_COUNT=0
INSTALLED_COUNT=0
NOT_INSTALLED_COUNT=0
declare -a OUTDATED_PACKAGES=()
declare -a JSON_RESULTS=()

# Get installed version
get_installed_version() {
    local cmd="$1"
    local ver_flag="$2"
    
    if command -v "$cmd" &>/dev/null; then
        local version
        # shellcheck disable=SC2086
        version=$("$cmd" $ver_flag 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
        if [[ -z "$version" ]]; then
            # Try alternative patterns
            # shellcheck disable=SC2086
            version=$("$cmd" $ver_flag 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        fi
        echo "$version"
    else
        echo "not installed"
    fi
    return 0
}

# Get latest npm version
get_npm_latest() {
    local pkg="$1"
    npm view "$pkg" version 2>/dev/null || echo "unknown"
    return 0
}

# Get latest brew version
get_brew_latest() {
    local pkg="$1"
    if command -v brew &>/dev/null; then
        brew info "$pkg" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
    else
        echo "unknown"
    fi
    return 0
}

# Get latest pip version
get_pip_latest() {
    local pkg="$1"
    pip index versions "$pkg" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
    return 0
}

# Compare versions (returns 0 if v1 < v2)
version_lt() {
    local v1="$1"
    local v2="$2"
    
    if [[ "$v1" == "$v2" ]]; then
        return 1
    fi
    
    # Use sort -V for version comparison
    local lowest
    lowest=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -1)
    [[ "$lowest" == "$v1" ]]
}

# Check a single tool
check_tool() {
    local category="$1"
    local name="$2"
    local cmd="$3"
    local ver_flag="$4"
    local pkg="$5"
    local update_cmd="$6"
    
    local installed
    installed=$(get_installed_version "$cmd" "$ver_flag")
    
    local latest="unknown"
    case "$category" in
        npm) latest=$(get_npm_latest "$pkg") ;;
        brew) latest=$(get_brew_latest "$pkg") ;;
        pip) latest=$(get_pip_latest "$pkg") ;;
    esac
    
    local status="up_to_date"
    local icon="✓"
    local color="$GREEN"
    
    if [[ "$installed" == "not installed" ]]; then
        status="not_installed"
        icon="○"
        color="$YELLOW"
        ((NOT_INSTALLED_COUNT++)) || true
    elif [[ "$installed" == "unknown" || "$latest" == "unknown" ]]; then
        status="unknown"
        icon="?"
        color="$YELLOW"
        ((INSTALLED_COUNT++)) || true
    elif [[ "$installed" != "$latest" ]] && version_lt "$installed" "$latest"; then
        status="outdated"
        icon="⬆"
        color="$RED"
        ((OUTDATED_COUNT++)) || true
        OUTDATED_PACKAGES+=("$update_cmd")
    else
        ((INSTALLED_COUNT++)) || true
    fi
    
    # JSON output (escape special characters for valid JSON)
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        # Escape backslashes and double quotes for JSON safety
        local json_name="${name//\\/\\\\}"
        json_name="${json_name//\"/\\\"}"
        local json_update="${update_cmd//\\/\\\\}"
        json_update="${json_update//\"/\\\"}"
        JSON_RESULTS+=("{\"name\":\"$json_name\",\"category\":\"$category\",\"installed\":\"$installed\",\"latest\":\"$latest\",\"status\":\"$status\",\"update_cmd\":\"$json_update\"}")
    else
        # Console output
        if [[ "$QUIET" == "true" && "$status" != "outdated" ]]; then
            return
        fi
        
        case "$status" in
            not_installed)
                echo -e "${color}${icon}  $name: not installed${NC}"
                if [[ "$QUIET" != "true" ]]; then
                    echo "   Latest: $latest"
                fi
                ;;
            outdated)
                echo -e "${color}${icon}  $name: $installed → $latest (UPDATE AVAILABLE)${NC}"
                ;;
            unknown)
                echo -e "${color}${icon}  $name: $installed (could not check latest)${NC}"
                ;;
            up_to_date)
                echo -e "${color}${icon}  $name: $installed${NC}"
                ;;
        esac
    fi
}

# Check tools by category
check_category() {
    local cat_name="$1"
    shift
    local tools=("$@")
    
    if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}=== $cat_name Tools ===${NC}"
    fi
    
    for tool_spec in "${tools[@]}"; do
        IFS='|' read -r category name cmd ver_flag pkg update_cmd <<< "$tool_spec"
        check_tool "$category" "$name" "$cmd" "$ver_flag" "$pkg" "$update_cmd"
    done
    return 0
}

# Main
main() {
    if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
        echo -e "${BOLD}${BLUE}Tool Version Check${NC}"
        echo "=================="
    fi
    
    # Check requested categories
    case "$CATEGORY" in
        npm)
            check_category "NPM" "${NPM_TOOLS[@]}"
            ;;
        brew)
            check_category "Homebrew" "${BREW_TOOLS[@]}"
            ;;
        pip)
            check_category "Python/Pip" "${PIP_TOOLS[@]}"
            ;;
        all|*)
            if [[ ${#NPM_TOOLS[@]} -gt 0 ]]; then
                check_category "NPM" "${NPM_TOOLS[@]}"
            fi
            if command -v brew &>/dev/null && [[ ${#BREW_TOOLS[@]} -gt 0 ]]; then
                check_category "Homebrew" "${BREW_TOOLS[@]}"
            fi
            if command -v pip &>/dev/null && [[ ${#PIP_TOOLS[@]} -gt 0 ]]; then
                check_category "Python/Pip" "${PIP_TOOLS[@]}"
            fi
            ;;
    esac
    
    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "{"
        echo "  \"summary\": {"
        echo "    \"installed\": $INSTALLED_COUNT,"
        echo "    \"outdated\": $OUTDATED_COUNT,"
        echo "    \"not_installed\": $NOT_INSTALLED_COUNT"
        echo "  },"
        echo "  \"tools\": ["
        local first=true
        for result in "${JSON_RESULTS[@]}"; do
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            echo -n "    $result"
        done
        echo ""
        echo "  ]"
        echo "}"
        return 0
    fi
    
    # Summary (skip in quiet mode if nothing outdated)
    if [[ "$QUIET" == "true" && $OUTDATED_COUNT -eq 0 ]]; then
        return 0
    fi
    
    if [[ "$QUIET" != "true" ]]; then
        echo ""
        echo -e "${BOLD}Summary${NC}"
        echo "  Installed & up to date: $INSTALLED_COUNT"
        echo "  Outdated: $OUTDATED_COUNT"
        echo "  Not installed: $NOT_INSTALLED_COUNT"
        echo ""
    fi
    
    # Handle updates
    if [[ $OUTDATED_COUNT -gt 0 ]]; then
        if [[ "$AUTO_UPDATE" == "true" ]]; then
            echo -e "${BLUE}Updating outdated tools...${NC}"
            echo ""
            for update_cmd in "${OUTDATED_PACKAGES[@]}"; do
                echo "  Running: $update_cmd"
                # Run update command directly (not via eval for security)
                # Commands are hardcoded in tool definitions, not user input
                if bash -c "$update_cmd" 2>&1 | tail -2; then
                    echo -e "  ${GREEN}✓ Updated${NC}"
                else
                    echo -e "  ${RED}✗ Failed${NC}"
                fi
                echo ""
            done
            echo -e "${GREEN}Updates complete. Re-run to verify.${NC}"
        else
            echo "To update all outdated tools, run:"
            echo "  tool-version-check.sh --update"
            echo ""
            echo "Or update individually:"
            for update_cmd in "${OUTDATED_PACKAGES[@]}"; do
                echo "  $update_cmd"
            done
        fi
    else
        echo -e "${GREEN}All installed tools are up to date!${NC}"
    fi
}

main
exit $?
