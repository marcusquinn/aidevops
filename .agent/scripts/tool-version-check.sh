#!/bin/bash
# Tool Version Check
# Checks versions of key MCP tools and flags outdated ones
#
# Usage: tool-version-check.sh [--update]
#   --update  Automatically update outdated tools

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

AUTO_UPDATE="${1:-}"

# Tools to check: display_name|cli_command|version_flag|npm_package
# Version flag can be --version or -V or custom
TOOLS=(
    "osgrep|osgrep|--version|osgrep"
    "augment|auggie|--version|@augmentcode/auggie"
    "repomix|repomix|--version|repomix"
    "stagehand|stagehand|--version|@anthropic-ai/stagehand"
)

echo -e "${BLUE}=== Tool Version Check ===${NC}"
echo ""

OUTDATED_COUNT=0
declare -a OUTDATED_PACKAGES=()

for tool_spec in "${TOOLS[@]}"; do
    IFS='|' read -r name cmd ver_flag npm_pkg <<< "$tool_spec"
    
    # Get installed version
    if command -v "$cmd" &>/dev/null; then
        installed=$("$cmd" "$ver_flag" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
    else
        installed="not installed"
    fi
    
    # Get latest version from npm
    latest=$(npm view "$npm_pkg" version 2>/dev/null || echo "unknown")
    
    # Compare and report
    if [[ "$installed" == "not installed" ]]; then
        echo -e "${YELLOW}⚠️  $name: not installed${NC}"
        echo "   Latest: $latest"
        echo "   Install: npm install -g $npm_pkg"
    elif [[ "$installed" == "$latest" ]]; then
        echo -e "${GREEN}✓  $name: $installed (up to date)${NC}"
    elif [[ "$latest" == "unknown" ]]; then
        echo -e "${YELLOW}?  $name: $installed (could not check latest)${NC}"
    else
        echo -e "${RED}⬆️  $name: $installed → $latest (UPDATE AVAILABLE)${NC}"
        ((OUTDATED_COUNT++)) || true
        OUTDATED_PACKAGES+=("$npm_pkg")
    fi
done

echo ""

if [[ $OUTDATED_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}Found $OUTDATED_COUNT outdated tool(s)${NC}"
    echo ""
    
    if [[ "$AUTO_UPDATE" == "--update" ]]; then
        echo "Updating outdated tools..."
        for pkg in "${OUTDATED_PACKAGES[@]}"; do
            echo "  Updating $pkg..."
            npm update -g "$pkg" 2>&1 | tail -1
        done
        echo ""
        echo -e "${GREEN}Updates complete. Re-run to verify.${NC}"
    else
        echo "To update all outdated tools, run:"
        echo "  tool-version-check.sh --update"
        echo ""
        echo "Or update individually:"
        for pkg in "${OUTDATED_PACKAGES[@]}"; do
            echo "  npm update -g $pkg"
        done
    fi
else
    echo -e "${GREEN}All tools are up to date!${NC}"
fi
