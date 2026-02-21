#!/usr/bin/env bash
# shellcheck disable=SC1091
# AI CLI Configuration Script
# Configures MCP integrations for all detected AI assistants
#
# Usage: bash .agents/scripts/ai-cli-config.sh [function_name]
# Example: bash .agents/scripts/ai-cli-config.sh configure_openapi_search_mcp
#
# Functions:
#   configure_openapi_search_mcp  - Configure OpenAPI Search MCP (remote, no prerequisites)

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

log_info() {
	local msg="$1"
	echo -e "${BLUE}[INFO]${NC} $msg"
	return 0
}

log_success() {
	local msg="$1"
	echo -e "${GREEN}[SUCCESS]${NC} $msg"
	return 0
}

log_warning() {
	local msg="$1"
	echo -e "${YELLOW}[WARNING]${NC} $msg"
	return 0
}

log_error() {
	local msg="$1"
	echo -e "${RED}[ERROR]${NC} $msg"
	return 0
}

# Safely merge a key/value into a JSON file using python3.
# Usage: json_merge_key <file> <key_path_expr> <value_json>
# key_path_expr is a dot-separated path, e.g. "mcp.openapi-search"
# value_json is a valid JSON string, e.g. '{"type":"http","url":"https://..."}'
json_set_nested() {
	local file="$1"
	local outer_key="$2"
	local inner_key="$3"
	local value_json="$4"

	if ! command -v python3 >/dev/null 2>&1; then
		log_warning "python3 not found - cannot update $file"
		return 0
	fi

	python3 - "$file" "$outer_key" "$inner_key" "$value_json" <<'PYEOF'
import json, sys

file_path = sys.argv[1]
outer_key = sys.argv[2]
inner_key = sys.argv[3]
value_json = sys.argv[4]

try:
    with open(file_path, 'r') as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

if outer_key not in config or not isinstance(config[outer_key], dict):
    config[outer_key] = {}

if inner_key in config[outer_key]:
    print(f"{inner_key} already configured in {file_path} - skipping")
else:
    config[outer_key][inner_key] = json.loads(value_json)
    with open(file_path, 'w') as f:
        json.dump(config, f, indent=2)
        f.write('\n')
    print(f"Added {inner_key} to {file_path}")
PYEOF
	return 0
}

# Safely append an object to a JSON array in a file using python3.
# Usage: json_append_to_array <file> <array_key> <value_json>
json_append_to_array() {
	local file="$1"
	local array_key="$2"
	local value_json="$3"
	local match_key="$4"
	local match_val="$5"

	if ! command -v python3 >/dev/null 2>&1; then
		log_warning "python3 not found - cannot update $file"
		return 0
	fi

	python3 - "$file" "$array_key" "$value_json" "$match_key" "$match_val" <<'PYEOF'
import json, sys

file_path = sys.argv[1]
array_key = sys.argv[2]
value_json = sys.argv[3]
match_key = sys.argv[4]
match_val = sys.argv[5]

try:
    with open(file_path, 'r') as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

if array_key not in config or not isinstance(config[array_key], list):
    config[array_key] = []

# Check if already present by match_key/match_val
for item in config[array_key]:
    if isinstance(item, dict) and item.get(match_key) == match_val:
        print(f"{match_val} already in {array_key} array in {file_path} - skipping")
        sys.exit(0)

config[array_key].append(json.loads(value_json))
with open(file_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
print(f"Added {match_val} to {array_key} array in {file_path}")
PYEOF
	return 0
}

# =============================================================================
# configure_openapi_search_mcp
#
# Configures the OpenAPI Search MCP server for all detected AI assistants.
# Remote Cloudflare Worker — no local install or prerequisites required.
# Source: https://github.com/janwilmake/openapi-mcp-server
# URL:    https://openapi-mcp.openapisearch.com/mcp
# =============================================================================
configure_openapi_search_mcp() {
	local mcp_name="openapi-search"
	local mcp_url="https://openapi-mcp.openapisearch.com/mcp"

	log_info "Configuring OpenAPI Search MCP for AI assistants..."
	log_info "Remote URL: $mcp_url (no prerequisites required)"

	# -------------------------------------------------------------------------
	# OpenCode — ~/.config/opencode/opencode.json
	# -------------------------------------------------------------------------
	local opencode_config="$HOME/.config/opencode/opencode.json"
	if [[ -f "$opencode_config" ]]; then
		log_info "Configuring OpenAPI Search for OpenCode..."
		json_set_nested "$opencode_config" "mcp" "$mcp_name" \
			"{\"type\":\"remote\",\"url\":\"$mcp_url\",\"enabled\":false}"
		log_success "OpenCode configured (disabled by default — enable per-agent via tools: openapi-search_*: true)"
	else
		log_warning "OpenCode config not found at $opencode_config - skipping"
		log_info "Run setup.sh to create OpenCode config, then re-run this script"
	fi

	# -------------------------------------------------------------------------
	# Claude Code CLI — claude mcp add --transport http
	# -------------------------------------------------------------------------
	if command -v claude >/dev/null 2>&1; then
		log_info "Configuring OpenAPI Search for Claude Code..."
		if claude mcp add --scope user "$mcp_name" --transport http "$mcp_url" 2>/dev/null; then
			log_success "Claude Code configured for OpenAPI Search"
		else
			# May already be configured — try add-json as fallback
			claude mcp add-json "$mcp_name" --scope user \
				"{\"type\":\"http\",\"url\":\"$mcp_url\"}" 2>/dev/null || true
			log_success "Claude Code configured for OpenAPI Search (via add-json)"
		fi
	else
		log_info "Claude Code CLI not found - skipping (install: https://claude.ai/download)"
	fi

	# -------------------------------------------------------------------------
	# Cursor — ~/.cursor/mcp.json
	# -------------------------------------------------------------------------
	local cursor_config="$HOME/.cursor/mcp.json"
	if [[ -d "$HOME/.cursor" ]] || command -v cursor >/dev/null 2>&1; then
		log_info "Configuring OpenAPI Search for Cursor..."
		mkdir -p "$HOME/.cursor"
		json_set_nested "$cursor_config" "mcpServers" "$mcp_name" \
			"{\"url\":\"$mcp_url\"}"
		log_success "Cursor configured for OpenAPI Search"
	else
		log_info "Cursor not detected - skipping"
	fi

	# -------------------------------------------------------------------------
	# Windsurf — ~/.codeium/windsurf/mcp_config.json
	# -------------------------------------------------------------------------
	local windsurf_config="$HOME/.codeium/windsurf/mcp_config.json"
	if [[ -d "$HOME/.codeium/windsurf" ]] || command -v windsurf >/dev/null 2>&1; then
		log_info "Configuring OpenAPI Search for Windsurf..."
		mkdir -p "$HOME/.codeium/windsurf"
		json_set_nested "$windsurf_config" "mcpServers" "$mcp_name" \
			"{\"serverUrl\":\"$mcp_url\"}"
		log_success "Windsurf configured for OpenAPI Search"
	else
		log_info "Windsurf not detected - skipping"
	fi

	# -------------------------------------------------------------------------
	# Gemini CLI — ~/.gemini/settings.json
	# -------------------------------------------------------------------------
	local gemini_config="$HOME/.gemini/settings.json"
	if [[ -d "$HOME/.gemini" ]] || command -v gemini >/dev/null 2>&1; then
		log_info "Configuring OpenAPI Search for Gemini CLI..."
		mkdir -p "$HOME/.gemini"
		json_set_nested "$gemini_config" "mcpServers" "$mcp_name" \
			"{\"url\":\"$mcp_url\"}"
		log_success "Gemini CLI configured for OpenAPI Search"
	else
		log_info "Gemini CLI not detected - skipping"
	fi

	# -------------------------------------------------------------------------
	# Continue.dev — ~/.continue/config.json (array-based mcpServers)
	# -------------------------------------------------------------------------
	local continue_config="$HOME/.continue/config.json"
	if [[ -d "$HOME/.continue" ]] || command -v continue >/dev/null 2>&1; then
		log_info "Configuring OpenAPI Search for Continue.dev..."
		mkdir -p "$HOME/.continue"
		local continue_entry
		continue_entry="{\"name\":\"$mcp_name\",\"transport\":{\"type\":\"streamable-http\",\"url\":\"$mcp_url\"}}"
		json_append_to_array "$continue_config" "mcpServers" "$continue_entry" "name" "$mcp_name"
		log_success "Continue.dev configured for OpenAPI Search"
	else
		log_info "Continue.dev not detected - skipping"
	fi

	# -------------------------------------------------------------------------
	# Kilo Code / Kiro — ~/.kilo/mcp.json and ~/.kiro/mcp.json
	# -------------------------------------------------------------------------
	for kilo_dir in "$HOME/.kilo" "$HOME/.kiro"; do
		if [[ -d "$kilo_dir" ]]; then
			local kilo_config="$kilo_dir/mcp.json"
			local kilo_name
			kilo_name="$(basename "$kilo_dir")"
			log_info "Configuring OpenAPI Search for ${kilo_name}..."
			json_set_nested "$kilo_config" "mcpServers" "$mcp_name" \
				"{\"url\":\"$mcp_url\"}"
			log_success "${kilo_name} configured for OpenAPI Search"
		fi
	done

	# -------------------------------------------------------------------------
	# Droid (Factory.AI) — droid mcp add CLI
	# -------------------------------------------------------------------------
	if command -v droid >/dev/null 2>&1; then
		log_info "Configuring OpenAPI Search for Droid (Factory.AI)..."
		droid mcp add "$mcp_name" --url "$mcp_url" 2>/dev/null || true
		log_success "Droid configured for OpenAPI Search"
	else
		log_info "Droid (Factory.AI) not detected - skipping"
	fi

	log_success "OpenAPI Search MCP configured for all detected AI assistants"
	log_info "Docs: https://github.com/janwilmake/openapi-mcp-server"
	log_info "Directory: https://openapisearch.com/search"
	log_info "Verification: Ask your AI assistant to 'list tools from openapi-search'"
	return 0
}

# =============================================================================
# Main
# =============================================================================
main() {
	local cmd="${1:-help}"

	case "$cmd" in
	configure_openapi_search_mcp | openapi-search | openapi_search)
		configure_openapi_search_mcp
		;;
	help | --help | -h)
		echo "Usage: $0 [command]"
		echo ""
		echo "Commands:"
		echo "  configure_openapi_search_mcp  Configure OpenAPI Search MCP for all detected AI assistants"
		echo "  help                          Show this help"
		echo ""
		echo "Run without arguments to see this help."
		;;
	*)
		log_error "Unknown command: $cmd"
		echo "Run '$0 help' for usage."
		return 1
		;;
	esac
	return 0
}

# Allow sourcing without executing main (for testing individual functions)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
