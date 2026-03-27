#!/usr/bin/env bash
# MCP Connection Failure Diagnostics
# Usage: mcp-diagnose.sh <mcp-name>
#        mcp-diagnose.sh check-all
#
# Diagnoses common MCP connection issues:
# - Command availability
# - Version mismatches
# - Configuration errors
# - Known breaking changes
#
# check-all: scans all enabled MCP servers and reports which are unavailable,
# helping identify dead tool schemas that waste context tokens (t1682).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

MCP_NAME="${1:-}"

if [[ -z "$MCP_NAME" ]]; then
	echo "Usage: mcp-diagnose.sh <mcp-name>"
	echo "       mcp-diagnose.sh check-all"
	echo ""
	echo "Examples:"
	echo "  mcp-diagnose.sh augment-context-engine"
	echo "  mcp-diagnose.sh check-all"
	exit 1
fi

# =============================================================================
# check-all: scan all enabled MCP servers for connection errors (t1682)
# Identifies servers whose tool schemas are in context but can't execute.
# =============================================================================
_check_all_mcps() {
	echo -e "${BLUE}=== MCP Server Health Check (t1682) ===${NC}"
	echo ""
	echo "Scanning all enabled MCP servers for connection errors..."
	echo "Errored servers inject dead tool schemas into context, wasting tokens."
	echo ""

	# Resolve config file — registry-driven with opencode fallback
	local config_file=""
	if type rt_config_path &>/dev/null; then
		config_file=$(rt_config_path "opencode" 2>/dev/null) || config_file=""
	fi
	if [[ -z "$config_file" || ! -f "$config_file" ]]; then
		config_file="$HOME/.config/opencode/opencode.json"
	fi

	if [[ ! -f "$config_file" ]]; then
		echo -e "${RED}✗ No MCP config file found at: $config_file${NC}"
		return 1
	fi

	echo "Config: $config_file"
	echo ""

	# Extract enabled MCP server names and their commands using Python
	local server_list
	server_list=$(
		python3 - "$config_file" <<'PYEOF'
import json, sys

config_file = sys.argv[1]
with open(config_file) as f:
    cfg = json.load(f)

# Support both 'mcp' (opencode) and 'mcpServers' (Claude Code / other runtimes)
mcp_section = cfg.get('mcp', cfg.get('mcpServers', {}))

for name, server in mcp_section.items():
    enabled = server.get('enabled', True)
    if not enabled:
        continue
    server_type = server.get('type', 'local')
    if server_type == 'remote':
        # Remote MCPs: just print name with remote marker
        print(f"{name}\tremote\t")
        continue
    cmd = server.get('command', [])
    if isinstance(cmd, list) and len(cmd) > 0:
        print(f"{name}\tlocal\t{cmd[0]}")
    elif isinstance(cmd, str):
        print(f"{name}\tlocal\t{cmd}")
    else:
        print(f"{name}\tlocal\t")
PYEOF
	) || {
		echo -e "${RED}✗ Failed to parse config file${NC}"
		return 1
	}

	if [[ -z "$server_list" ]]; then
		echo -e "${YELLOW}No enabled MCP servers found in config.${NC}"
		return 0
	fi

	local ok_count=0
	local error_count=0
	local skip_count=0
	local errored_names=()

	while IFS=$'\t' read -r name server_type cmd_path; do
		[[ -z "$name" ]] && continue

		if [[ "$server_type" == "remote" ]]; then
			echo -e "  ${CYAN}[remote]${NC} $name — skipping connectivity check (remote MCP)"
			((++skip_count))
			continue
		fi

		# For local MCPs: check if the command binary exists
		# cmd_path may be a full path (e.g. /home/user/.nvm/.../npx) or a bare name
		local cmd_ok=false
		if [[ -n "$cmd_path" ]]; then
			if [[ -x "$cmd_path" ]]; then
				cmd_ok=true
			elif command -v "$cmd_path" &>/dev/null; then
				cmd_ok=true
			fi
		fi

		if [[ "$cmd_ok" == "true" ]]; then
			echo -e "  ${GREEN}[ok]${NC}     $name"
			((++ok_count))
		else
			echo -e "  ${RED}[error]${NC}  $name — command not found: ${cmd_path:-<none>}"
			errored_names+=("$name")
			((++error_count))
		fi
	done <<<"$server_list"

	echo ""
	echo "Summary: ${ok_count} ok, ${error_count} errored, ${skip_count} skipped (remote)"

	if [[ ${#errored_names[@]} -gt 0 ]]; then
		echo ""
		echo -e "${YELLOW}=== Errored Servers — Dead Tool Schemas in Context ===${NC}"
		echo ""
		echo "These servers have tool schemas registered but cannot execute."
		echo "Each errored server wastes context tokens on unusable tools."
		echo ""
		echo "Remediation options:"
		echo ""
		echo "  Option A — Fix the connection (preferred):"
		for name in "${errored_names[@]}"; do
			echo "    mcp-diagnose.sh $name"
		done
		echo ""
		echo "  Option B — Disable until fixed (removes schemas from context):"
		echo "    Edit $config_file"
		for name in "${errored_names[@]}"; do
			echo "    Set \"$name\": { ..., \"enabled\": false }"
		done
		echo ""
		echo "  Option C — Remove registration entirely:"
		for name in "${errored_names[@]}"; do
			echo "    Delete the \"$name\" entry from $config_file"
		done
		echo ""
		echo -e "${BLUE}Tip:${NC} After fixing, restart your AI runtime to reload tool schemas."
		return 1
	fi

	echo ""
	echo -e "${GREEN}All enabled local MCP servers have reachable commands.${NC}"
	return 0
}

# =============================================================================
# Single-server diagnosis (original behaviour)
# =============================================================================
if [[ "$MCP_NAME" == "check-all" ]]; then
	_check_all_mcps
	exit $?
fi

echo -e "${BLUE}=== MCP Diagnosis: $MCP_NAME ===${NC}"
echo ""

# 1. Check if command exists
echo "1. Checking command availability..."
# Map MCP names to their CLI commands
case "$MCP_NAME" in
augment-context-engine | augment)
	CLI_CMD="auggie"
	NPM_PKG="@augmentcode/auggie"
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

# 3. Check runtime configs for MCP (t1665.5 — registry-driven)
echo ""
echo "3. Checking runtime configurations..."

# Build list of config files to check from registry, fallback to hardcoded
_MCP_DIAG_CONFIGS=()
if type rt_detect_configured &>/dev/null; then
	while IFS= read -r _rt_id; do
		_cfg=$(rt_config_path "$_rt_id") || continue
		[[ -n "$_cfg" && -f "$_cfg" ]] && _MCP_DIAG_CONFIGS+=("$_rt_id:$_cfg")
	done < <(rt_detect_configured)
fi
# Fallback if registry not loaded or no configs found
if [[ ${#_MCP_DIAG_CONFIGS[@]} -eq 0 ]]; then
	_fallback_cfg="$HOME/.config/opencode/opencode.json"
	[[ -f "$_fallback_cfg" ]] && _MCP_DIAG_CONFIGS+=("opencode:$_fallback_cfg")
fi

_mcp_found_in_any=0
for _diag_entry in "${_MCP_DIAG_CONFIGS[@]}"; do
	_diag_rt="${_diag_entry%%:*}"
	CONFIG_FILE="${_diag_entry#*:}"
	_diag_name=""
	if type rt_display_name &>/dev/null; then
		_diag_name=$(rt_display_name "$_diag_rt") || _diag_name="$_diag_rt"
	else
		_diag_name="$_diag_rt"
	fi

	if grep -q "\"$MCP_NAME\"" "$CONFIG_FILE" 2>/dev/null; then
		echo -e "   ${GREEN}✓ MCP configured in ${_diag_name} config${NC}"
		# Extract and show the command using Python
		python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
# Try both 'mcp' (opencode) and 'mcpServers' (other runtimes) root keys
mcp = cfg.get('mcp', cfg.get('mcpServers', {})).get('$MCP_NAME', {})
cmd = mcp.get('command', 'not set')
enabled = mcp.get('enabled', 'not set')
print(f'   Command: {cmd}')
print(f'   Enabled: {enabled}')
" 2>/dev/null || echo "   (Could not parse config)"
		_mcp_found_in_any=1
	fi
done

if [[ "$_mcp_found_in_any" -eq 0 ]]; then
	if [[ ${#_MCP_DIAG_CONFIGS[@]} -eq 0 ]]; then
		echo -e "   ${RED}✗ No runtime config files found${NC}"
	else
		echo -e "   ${RED}✗ MCP '$MCP_NAME' not found in any runtime config${NC}"
	fi
fi

# 4. Check for known breaking changes
echo ""
echo "4. Known issues for $MCP_NAME..."
case "$MCP_NAME" in
augment-context-engine | augment)
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

# timeout_sec (from shared-constants.sh) handles macOS + Linux portably
case "$MCP_NAME" in
augment-context-engine | augment)
	echo "   Running: auggie --mcp"
	timeout_sec 5 auggie --mcp 2>&1 | head -3 || echo "   (timeout - normal for MCP servers)"
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
echo "5. Verify MCP status in your runtime's config after fixes"
