#!/usr/bin/env bash
# MCP Connection Failure Diagnostics
# Usage: mcp-diagnose.sh <mcp-name>
#
# Diagnoses common MCP connection issues:
# - Command availability
# - Version mismatches
# - Configuration errors
# - Known breaking changes

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

MCP_NAME="${1:-}"

if [[ -z "$MCP_NAME" ]]; then
    echo "Usage: mcp-diagnose.sh <mcp-name>"
    echo ""
    echo "Examples:"
    echo "  mcp-diagnose.sh osgrep"
    echo "  mcp-diagnose.sh augment-context-engine"
    exit 1
fi

echo -e "${BLUE}=== MCP Diagnosis: $MCP_NAME ===${NC}"
echo ""

# 1. Check if command exists
echo "1. Checking command availability..."
# Map MCP names to their CLI commands
case "$MCP_NAME" in
    augment-context-engine|augment)
        CLI_CMD="auggie"
        NPM_PKG="@augmentcode/auggie"
        ;;
    osgrep)
        CLI_CMD="osgrep"
        NPM_PKG="osgrep"
        ;;
    context7)
        CLI_CMD="context7"
        NPM_PKG="@context7/mcp"
        ;;
    *)
        CLI_CMD="$MCP_NAME"
        NPM_PKG="$MCP_NAME"
        ;;
esac

if command -v "$CLI_CMD" &>/dev/null; then
    echo -e "   ${GREEN}✓ Command found: $(which "$CLI_CMD")${NC}"
    INSTALLED_VERSION=$("$CLI_CMD" --version 2>/dev/null | head -1 || echo 'unknown')
    echo "   Version: $INSTALLED_VERSION"
else
    echo -e "   ${RED}✗ Command not found: $CLI_CMD${NC}"
    echo "   Try: npm install -g $NPM_PKG"
    exit 1
fi

# 2. Check latest version
echo ""
echo "2. Checking for updates..."
LATEST_VERSION=$(npm view "$NPM_PKG" version 2>/dev/null || echo "unknown")
echo "   Installed: $INSTALLED_VERSION"
echo "   Latest:    $LATEST_VERSION"

if [[ "$INSTALLED_VERSION" != *"$LATEST_VERSION"* ]] && [[ "$LATEST_VERSION" != "unknown" ]]; then
    echo -e "   ${YELLOW}⚠️  UPDATE AVAILABLE - run: npm update -g $NPM_PKG${NC}"
fi

# 3. Check OpenCode config
echo ""
echo "3. Checking OpenCode configuration..."
CONFIG_FILE="$HOME/.config/opencode/opencode.json"
if [[ -f "$CONFIG_FILE" ]]; then
    if grep -q "\"$MCP_NAME\"" "$CONFIG_FILE"; then
        echo -e "   ${GREEN}✓ MCP configured in opencode.json${NC}"
        # Extract and show the command using Python
        python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
mcp = cfg.get('mcp', {}).get('$MCP_NAME', {})
cmd = mcp.get('command', 'not set')
enabled = mcp.get('enabled', 'not set')
print(f'   Command: {cmd}')
print(f'   Enabled: {enabled}')
" 2>/dev/null || echo "   (Could not parse config)"
    else
        echo -e "   ${RED}✗ MCP not found in config${NC}"
    fi
else
    echo -e "   ${RED}✗ Config file not found: $CONFIG_FILE${NC}"
fi

# 4. Check for known breaking changes
echo ""
echo "4. Known issues for $MCP_NAME..."
case "$MCP_NAME" in
    osgrep)
        echo "   - v0.4.x: Used 'osgrep serve' (HTTP server, NOT MCP-compatible)"
        echo "   - v0.5.x: Use 'osgrep mcp' or run 'osgrep install-opencode'"
        echo ""
        echo "   If using v0.5+, the correct command is: [\"osgrep\", \"mcp\"]"
        ;;
    augment-context-engine|augment)
        echo "   - Requires 'auggie login' before MCP works"
        echo "   - Session stored in ~/.augment/"
        echo "   - Correct command: [\"auggie\", \"--mcp\"]"
        ;;
    context7)
        echo "   - Remote MCP, no local command needed"
        echo "   - Use: \"type\": \"remote\", \"url\": \"https://mcp.context7.com/mcp\""
        ;;
    *)
        echo "   No known issues documented for this MCP"
        ;;
esac

# 5. Test MCP command directly
echo ""
echo "5. Testing MCP command (5 second timeout)..."

# Use gtimeout on macOS if available, otherwise skip timeout
TIMEOUT_CMD=""
if command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout 5"
elif command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout 5"
fi

case "$MCP_NAME" in
    osgrep)
        echo "   Running: osgrep mcp"
        if [[ -n "$TIMEOUT_CMD" ]]; then
            $TIMEOUT_CMD osgrep mcp 2>&1 | head -3 || echo "   (timeout - normal for MCP servers)"
        else
            echo "   (skipping - install coreutils for timeout: brew install coreutils)"
        fi
        ;;
    augment-context-engine|augment)
        echo "   Running: auggie --mcp"
        if [[ -n "$TIMEOUT_CMD" ]]; then
            $TIMEOUT_CMD auggie --mcp 2>&1 | head -3 || echo "   (timeout - normal for MCP servers)"
        else
            echo "   (skipping - install coreutils for timeout: brew install coreutils)"
        fi
        ;;
    *)
        echo "   Skipping direct test (unknown command pattern)"
        ;;
esac

# 6. Suggested fixes
echo ""
echo -e "${BLUE}=== Suggested Fixes ===${NC}"
echo "1. Update tool: npm update -g $NPM_PKG"
echo "2. Check official docs for command changes"
echo "3. Run: $CLI_CMD --help"
echo "4. Check ~/.aidevops/agents/tools/ for updated documentation"
echo "5. Run: opencode mcp list (to verify status after fixes)"
