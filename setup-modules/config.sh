#!/usr/bin/env bash
# Configuration functions: setup_configs, set_permissions, ssh, aidevops-cli, opencode-config, claude-config, validate, extract-prompts, drift-check
# Part of aidevops setup.sh modularization (t316.3)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

setup_configs() {
	print_info "Setting up configuration files..."

	# Create configs directory if it doesn't exist
	mkdir -p configs

	# Copy template configs if they don't exist
	for template in configs/*.txt; do
		if [[ -f "$template" ]]; then
			config_file="${template%.txt}"
			if [[ ! -f "$config_file" ]]; then
				cp "$template" "$config_file"
				print_success "Created $(basename "$config_file")"
				print_warning "Please edit $(basename "$config_file") with your actual credentials"
			else
				print_info "Found existing config: $(basename "$config_file") - Skipping"
			fi
		fi
	done

	return 0
}

install_aidevops_cli() {
	print_info "Installing aidevops CLI command..."

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local cli_source="$script_dir/aidevops.sh"
	local cli_target="/usr/local/bin/aidevops"

	if [[ ! -f "$cli_source" ]]; then
		print_warning "aidevops.sh not found - skipping CLI installation"
		return 0
	fi

	# Check if we can write to /usr/local/bin
	if [[ -w "/usr/local/bin" ]]; then
		# Direct symlink
		ln -sf "$cli_source" "$cli_target"
		print_success "Installed aidevops command to $cli_target"
	elif [[ -w "$HOME/.local/bin" ]] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
		# Use ~/.local/bin instead
		cli_target="$HOME/.local/bin/aidevops"
		ln -sf "$cli_source" "$cli_target"
		print_success "Installed aidevops command to $cli_target"

		# Check if ~/.local/bin is in PATH and add it if not
		if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
			add_local_bin_to_path
		fi
	else
		# Need sudo
		print_info "Installing aidevops command requires sudo..."
		if sudo ln -sf "$cli_source" "$cli_target"; then
			print_success "Installed aidevops command to $cli_target"
		else
			print_warning "Could not install aidevops command globally"
			print_info "You can run it directly: $cli_source"
		fi
	fi

	return 0
}

# Helper: check for a generator script, run it, report result consistently
_run_generator() {
	local script_path="$1"
	local info_msg="$2"
	local success_msg="$3"
	local failure_msg="$4"
	shift 4
	local script_args=("$@")

	if [[ ! -f "$script_path" ]]; then
		print_warning "Generator script not found: $script_path"
		return 0
	fi

	print_info "$info_msg"
	# Use ${arr[@]+"${arr[@]}"} pattern for safe expansion under set -u when array may be empty
	if bash "$script_path" ${script_args[@]+"${script_args[@]}"}; then
		print_success "$success_msg"
	else
		print_warning "$failure_msg"
	fi

	return 0
}

update_opencode_config() {
	# Respect config (env var or config file)
	if ! is_feature_enabled manage_opencode_config 2>/dev/null; then
		print_info "OpenCode config management disabled via config (integrations.manage_opencode_config)"
		return 0
	fi

	print_info "Updating OpenCode configuration..."

	# Generate OpenCode commands (independent of opencode.json — writes to ~/.config/opencode/command/)
	_run_generator ".agents/scripts/generate-opencode-commands.sh" \
		"Generating OpenCode commands..." \
		"OpenCode commands configured" \
		"OpenCode command generation encountered issues"

	# Generate OpenCode agent configuration (creates opencode.json if missing)
	# - Primary agents: Added to opencode.json (for Tab order & MCP control)
	# - Subagents: Generated as markdown in ~/.config/opencode/agent/
	_run_generator ".agents/scripts/generate-opencode-agents.sh" \
		"Generating OpenCode agent configuration..." \
		"OpenCode agents configured (11 primary in JSON, subagents as markdown)" \
		"OpenCode agent generation encountered issues"

	# Regenerate subagent index for plugin startup (t1040)
	_run_generator ".agents/scripts/subagent-index-helper.sh" \
		"Regenerating subagent index..." \
		"Subagent index regenerated" \
		"Subagent index generation encountered issues" \
		generate

	return 0
}

update_claude_config() {
	# Respect config (env var or config file)
	if ! is_feature_enabled manage_claude_config 2>/dev/null; then
		print_info "Claude config management disabled via config (integrations.manage_claude_config)"
		return 0
	fi

	print_info "Updating Claude Code configuration..."

	# Generate Claude Code commands (writes to ~/.claude/commands/)
	_run_generator ".agents/scripts/generate-claude-commands.sh" \
		"Generating Claude Code commands..." \
		"Claude Code commands configured" \
		"Claude Code command generation encountered issues"

	# Generate Claude Code agent configuration (MCPs, settings.json, slash commands)
	# Mirrors update_opencode_config() calling generate-opencode-agents.sh (t1161.4)
	_run_generator ".agents/scripts/generate-claude-agents.sh" \
		"Generating Claude Code agent configuration..." \
		"Claude Code agents configured (MCPs, settings, commands)" \
		"Claude Code agent generation encountered issues"

	# Regenerate subagent index (shared between OpenCode and Claude Code)
	_run_generator ".agents/scripts/subagent-index-helper.sh" \
		"Regenerating subagent index..." \
		"Subagent index regenerated" \
		"Subagent index generation encountered issues" \
		generate

	return 0
}

update_codex_config() {
	# Only run if Codex is installed or config dir exists
	if [[ ! -d "$HOME/.codex" ]] && ! command -v codex >/dev/null 2>&1; then
		return 0
	fi

	print_info "Updating Codex configuration..."

	# Fix broken MCP_DOCKER entry (P0 — OrbStack/Colima don't support docker mcp)
	if type _fix_codex_docker_mcp &>/dev/null; then
		_fix_codex_docker_mcp
	fi

	# Deploy aidevops MCP servers to Codex config.toml
	_deploy_codex_mcps

	print_success "Codex configuration updated"
	return 0
}

# Deploy standard aidevops MCP servers to ~/.codex/config.toml
# Codex uses TOML format: [mcp_servers.NAME] sections
_deploy_codex_mcps() {
	local config="$HOME/.codex/config.toml"
	mkdir -p "$HOME/.codex"

	# Touch config if it doesn't exist
	[[ -f "$config" ]] || touch "$config"

	local mcp_count=0

	# Helper: add a TOML MCP section if not already present
	# Args: $1=name, $2=type (stdio|url), $3=command_or_url, $4=args (optional, comma-separated)
	_add_codex_mcp() {
		local name="$1"
		local mcp_type="$2"
		local cmd_or_url="$3"
		local args="${4:-}"

		if grep -q "\\[mcp_servers\\.${name}\\]" "$config" 2>/dev/null; then
			echo -e "  ${BLUE:-}=${NC:-} $name (already configured)"
			return 0
		fi

		{
			echo ""
			echo "[mcp_servers.${name}]"
			if [[ "$mcp_type" == "stdio" ]]; then
				echo "command = '${cmd_or_url}'"
				if [[ -n "$args" ]]; then
					echo "args = [${args}]"
				fi
			else
				echo "type = 'url'"
				echo "url = '${cmd_or_url}'"
			fi
		} >>"$config"
		((++mcp_count))
		echo -e "  ${GREEN:-}+${NC:-} $name"
		return 0
	}

	# --- context7 (library docs) ---
	_add_codex_mcp "context7" "stdio" "npx" "'-y', '@upstash/context7-mcp@latest'"

	# --- Playwright MCP ---
	_add_codex_mcp "playwright" "stdio" "npx" "'-y', '@anthropic-ai/mcp-server-playwright@latest'"

	# --- shadcn UI ---
	_add_codex_mcp "shadcn" "stdio" "npx" "'shadcn@latest', 'mcp'"

	# --- OpenAPI Search (remote, zero install) ---
	_add_codex_mcp "openapi-search" "url" "https://openapi-mcp.openapisearch.com/mcp"

	# --- Cloudflare API (remote) ---
	_add_codex_mcp "cloudflare-api" "url" "https://mcp.cloudflare.com/mcp"

	echo -e "  ${GREEN:-}Done${NC:-} -- $mcp_count new MCP servers added to Codex config"
	return 0
}

update_cursor_config() {
	# Only run if Cursor is installed or config dir exists
	if [[ ! -d "$HOME/.cursor" ]] && ! command -v cursor >/dev/null 2>&1 && ! command -v agent >/dev/null 2>&1; then
		return 0
	fi

	print_info "Updating Cursor configuration..."

	# Deploy aidevops MCP servers to Cursor mcp.json
	_deploy_cursor_mcps

	print_success "Cursor configuration updated"
	return 0
}

# Deploy standard aidevops MCP servers to ~/.cursor/mcp.json
# Cursor uses JSON format: { "mcpServers": { "name": { ... } } }
_deploy_cursor_mcps() {
	local config="$HOME/.cursor/mcp.json"
	mkdir -p "$HOME/.cursor"

	# Ensure config file exists with valid JSON
	if [[ ! -f "$config" ]]; then
		echo '{}' >"$config"
	fi

	# Use the json_set_nested helper from ai-cli-config.sh if available,
	# otherwise use python3 directly
	local mcp_count=0

	# Helper: add a JSON MCP entry if not already present
	# Increments mcp_count only when a new entry is actually added.
	_add_cursor_mcp() {
		local name="$1"
		local json_value="$2"

		if ! command -v python3 >/dev/null 2>&1; then
			print_warning "python3 not found - cannot update Cursor config"
			return 0
		fi

		local py_output
		py_output=$(
			python3 - "$config" "$name" "$json_value" <<'PYEOF'
import json, sys

file_path = sys.argv[1]
name = sys.argv[2]
value_json = sys.argv[3]

try:
    with open(file_path, 'r') as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}

if "mcpServers" not in cfg or not isinstance(cfg["mcpServers"], dict):
    cfg["mcpServers"] = {}

if name in cfg["mcpServers"]:
    print(f"SKIP  = {name} (already configured)")
else:
    cfg["mcpServers"][name] = json.loads(value_json)
    with open(file_path, 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
    print(f"ADDED + {name}")
PYEOF
		) || true
		echo "  ${py_output#* }"
		if [[ "$py_output" == ADDED* ]]; then
			((++mcp_count))
		fi
		return 0
	}

	# --- context7 (library docs) ---
	_add_cursor_mcp "context7" '{"command":"npx","args":["-y","@upstash/context7-mcp@latest"]}'

	# --- Playwright MCP ---
	_add_cursor_mcp "playwright" '{"command":"npx","args":["-y","@anthropic-ai/mcp-server-playwright@latest"]}'

	# --- shadcn UI ---
	_add_cursor_mcp "shadcn" '{"command":"npx","args":["shadcn@latest","mcp"]}'

	# --- OpenAPI Search (remote, zero install) ---
	_add_cursor_mcp "openapi-search" '{"url":"https://openapi-mcp.openapisearch.com/mcp"}'

	# --- Cloudflare API (remote) ---
	_add_cursor_mcp "cloudflare-api" '{"url":"https://mcp.cloudflare.com/mcp"}'

	echo "  Done -- $mcp_count new MCP servers added to Cursor config"
	return 0
}
