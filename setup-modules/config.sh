#!/usr/bin/env bash
# Configuration functions: setup_configs, set_permissions, ssh, aidevops-cli, opencode-config, validate, extract-prompts, drift-check
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

update_opencode_config() {
	print_info "Updating OpenCode configuration..."

	# Generate OpenCode commands (independent of opencode.json — writes to ~/.config/opencode/command/)
	# Run this first so /onboarding and other commands exist even if opencode.json hasn't been created yet
	local commands_script=".agents/scripts/generate-opencode-commands.sh"
	if [[ -f "$commands_script" ]]; then
		print_info "Generating OpenCode commands..."
		if bash "$commands_script"; then
			print_success "OpenCode commands configured"
		else
			print_warning "OpenCode command generation encountered issues"
		fi
	else
		print_warning "OpenCode command generator not found at $commands_script"
	fi

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

	local generator_script=".agents/scripts/generate-opencode-agents.sh"
	if [[ -f "$generator_script" ]]; then
		print_info "Generating OpenCode agent configuration..."
		if bash "$generator_script"; then
			print_success "OpenCode agents configured (11 primary in JSON, subagents as markdown)"
		else
			print_warning "OpenCode agent generation encountered issues"
		fi
	else
		print_warning "OpenCode agent generator not found at $generator_script"
	fi

	return 0
}

