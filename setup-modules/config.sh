#!/usr/bin/env bash
# Configuration functions: setup_configs, set_permissions, ssh, aidevops-cli, opencode-config, claude-config, validate, extract-prompts, drift-check
# Part of aidevops setup.sh modularization (t316.3)

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
	print_info "Updating OpenCode configuration..."

	# Generate OpenCode commands (independent of opencode.json — writes to ~/.config/opencode/command/)
	# Run this first so /onboarding and other commands exist even if opencode.json hasn't been created yet
	_run_generator ".agents/scripts/generate-opencode-commands.sh" \
		"Generating OpenCode commands..." \
		"OpenCode commands configured" \
		"OpenCode command generation encountered issues"

	# Generate OpenCode agent configuration (requires opencode.json)
	# - Primary agents: Added to opencode.json (for Tab order & MCP control)
	# - Subagents: Generated as markdown in ~/.config/opencode/agent/
	local opencode_config
	if ! opencode_config=$(find_opencode_config); then
		print_info "OpenCode config (opencode.json) not found — agent configuration skipped (commands still generated)"
		return 0
	fi

	print_info "Found OpenCode config at: $opencode_config"

	# Create backup (with rotation)
	create_backup_with_rotation "$opencode_config" "opencode"

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
	# Guard: only run if claude binary exists (t1161)
	if ! command -v claude &>/dev/null; then
		print_info "Claude Code not found — skipping Claude config (install: https://claude.ai/download)"
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
