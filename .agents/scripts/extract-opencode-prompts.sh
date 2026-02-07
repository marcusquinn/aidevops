#!/usr/bin/env bash
# =============================================================================
# Extract OpenCode Prompts from Binary
# =============================================================================
# Extracts embedded prompts from the OpenCode binary for use by aidevops agents.
# This ensures our agents stay in sync with OpenCode updates.
#
# Usage: ./extract-opencode-prompts.sh
# Output: ~/.aidevops/cache/opencode-prompts/
# =============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
# shellcheck disable=SC2034  # RED reserved for future error messages
RED='\033[0;31m'
NC='\033[0m'

CACHE_DIR="$HOME/.aidevops/cache/opencode-prompts"
OPENCODE_BIN=""

# Find OpenCode binary
find_opencode_binary() {
    local locations=(
        "$HOME/.bun/install/global/node_modules/opencode-darwin-arm64/bin/opencode"
        "$HOME/.bun/install/global/node_modules/opencode-darwin-x64/bin/opencode"
        "$HOME/.bun/install/global/node_modules/opencode-linux-x64/bin/opencode"
        "$HOME/.bun/install/global/node_modules/opencode-linux-arm64/bin/opencode"
        "/usr/local/bin/opencode"
        "$HOME/.local/bin/opencode"
    )
    
    for loc in "${locations[@]}"; do
        if [[ -f "$loc" ]]; then
            OPENCODE_BIN="$loc"
            return 0
        fi
    done
    
    # Try which as fallback
    if command -v opencode &>/dev/null; then
        local bin_path
        bin_path=$(which opencode)
        # Follow symlinks to find actual binary
        if [[ -L "$bin_path" ]]; then
            bin_path=$(readlink -f "$bin_path" 2>/dev/null || readlink "$bin_path")
        fi
        if [[ -f "$bin_path" ]]; then
            OPENCODE_BIN="$bin_path"
            return 0
        fi
    fi
    
    return 1
}

# Extract a specific prompt by variable name
# Usage: extract_prompt "plan_default" "plan.txt"
extract_prompt() {
    local var_name="$1"
    local output_file="$2"
    local start_marker="var ${var_name} = \`"
    
    # Extract content between backticks
    strings "$OPENCODE_BIN" | \
        grep -A 500 "^${start_marker}" | \
        head -n 100 | \
        sed "s/^${start_marker}//" | \
        sed '/^var init_/q' | \
        sed '/^var init_/d' | \
        sed 's/`$//' \
        > "$CACHE_DIR/$output_file"
    
    # Verify extraction worked
    if [[ -s "$CACHE_DIR/$output_file" ]]; then
        echo -e "  ${GREEN}✓${NC} Extracted $output_file"
        return 0
    else
        echo -e "  ${YELLOW}⚠${NC} Failed to extract $output_file"
        return 1
    fi
}

# Get OpenCode version
get_opencode_version() {
    if command -v opencode &>/dev/null; then
        opencode --version 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

main() {
    echo -e "${BLUE}Extracting OpenCode prompts...${NC}"
    
    # Find binary
    if ! find_opencode_binary; then
        echo -e "${YELLOW}Warning: OpenCode binary not found. Skipping prompt extraction.${NC}"
        echo -e "${YELLOW}Install OpenCode with: bun install -g opencode-ai${NC}"
        return 0
    fi
    
    echo -e "  Found binary: $OPENCODE_BIN"
    
    # Create cache directory
    mkdir -p "$CACHE_DIR"
    
    # Get version for tracking
    local version
    version=$(get_opencode_version)
    echo "$version" > "$CACHE_DIR/version.txt"
    echo -e "  OpenCode version: $version"
    
    # Extract prompts
    extract_prompt "plan_default" "plan-reminder.txt" || true
    extract_prompt "build_switch_default" "build-switch.txt" || true
    extract_prompt "max_steps_default" "max-steps.txt" || true
    
    # Record extraction timestamp
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$CACHE_DIR/extracted-at.txt"
    
    echo -e "${GREEN}Done!${NC} Prompts cached in $CACHE_DIR"
}

main "$@"
