#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# OpenCode companion CLI and service setup functions.
# Part of aidevops setup.sh modularization (GH#32734)

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -Eeuo pipefail

# Include guard
[[ -n "${_TOOL_INSTALL_OPENCODE_SERVICES_LOADED:-}" ]] && return 0
_TOOL_INSTALL_OPENCODE_SERVICES_LOADED=1
TOOL_INSTALL_EMPTY=${TOOL_INSTALL_EMPTY-}
TOOL_INSTALL_OS_DARWIN=${TOOL_INSTALL_OS_DARWIN-Darwin}
TOOL_INSTALL_BOOL_TRUE=${TOOL_INSTALL_BOOL_TRUE-true}
TOOL_INSTALL_UNKNOWN=${TOOL_INSTALL_UNKNOWN-unknown}

# SCRIPT_DIR fallback for direct sourcing and test harnesses.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_tool_install_module_path="${BASH_SOURCE[0]%/*}"
	[[ "$_tool_install_module_path" == "${BASH_SOURCE[0]}" ]] && _tool_install_module_path="."
	SCRIPT_DIR="$(cd "$_tool_install_module_path" && pwd)"
	unset _tool_install_module_path
fi

setup_opencode_service() {
	# Optional user-session service: never block other setup or enable a disabled
	# installation. Existing histories keep their current default launch route.
	case "${AIDEVOPS_OPENCODE_SERVICE:-1}" in
	0 | false | no) return 0 ;;
	esac
	local helper="${HOME}/.aidevops/agents/scripts/opencode-service-helper.py"
	[[ -f "$helper" ]] || return 0
	command -v opencode >/dev/null 2>&1 || return 0
	command -v python3 >/dev/null 2>&1 || return 0
	if python3 "$helper" install --fresh-default; then
		print_success "OpenCode owner reconciled; existing histories and routing choices preserved"
	else
		print_warning "OpenCode service unavailable or needs attention; direct launch is unchanged. See reference/opencode-service.md"
	fi
	return 0
}

setup_opencode_desktop_launcher() {
	if [[ "$(uname -s)" != "${TOOL_INSTALL_OS_DARWIN}" ]]; then
		return 0
	fi

	local launcher_script="${HOME}/.aidevops/agents/scripts/opencode-launcher-helper.sh"
	if ! [[ -x "$launcher_script" ]]; then
		return 0
	fi

	local install_rc=0
	bash "$launcher_script" desktop install-shortcut >/dev/null 2>&1 || install_rc=$?
	case "$install_rc" in
	0)
		print_success "OpenCode AIDevOps Desktop app installed in ~/Applications"
		;;
	3)
		# OpenCode Desktop is optional; do not warn on systems that only use the CLI.
		return 0
		;;
	*)
		print_warning "Failed to install OpenCode AIDevOps Desktop app wrapper"
		;;
	esac
	return 0
}

setup_codex_cli() {
	print_info "Setting up OpenAI Codex CLI..."

	# Check if Codex is already installed
	if command -v codex >/dev/null 2>&1; then
		local codex_version
		codex_version=$(codex --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		print_success "Codex already installed: $codex_version"
		# Fix broken MCP_DOCKER if present
		_fix_codex_docker_mcp
		return 0
	fi

	# Need either bun or npm to install
	local installer="${TOOL_INSTALL_EMPTY}"
	local install_pkg="@openai/codex@latest"

	if command -v bun >/dev/null 2>&1; then
		installer="bun"
	elif command -v npm >/dev/null 2>&1; then
		installer="npm"
	else
		print_warning "Neither bun nor npm found - cannot install Codex"
		print_info "Install Node.js first, then re-run setup"
		return 0
	fi

	print_info "Codex is OpenAI's AI coding CLI (terminal-based, agentic)"
	echo "  It provides an AI-powered terminal interface using OpenAI models."
	echo "${TOOL_INSTALL_EMPTY}"

	local install_codex
	setup_prompt install_codex "Install Codex via $installer? [Y/n]: " "Y"
	if [[ "$install_codex" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Codex" npm_global_install "$install_pkg"; then
			print_success "Codex installed"
			echo "${TOOL_INSTALL_EMPTY}"
			print_info "Codex needs OpenAI authentication."
			print_info "Run 'codex' and follow the auth prompts."
			echo "${TOOL_INSTALL_EMPTY}"
			# Fix broken MCP_DOCKER if Codex created a default config
			_fix_codex_docker_mcp
		else
			print_warning "Codex installation failed"
			print_info "Try manually: npm install -g $install_pkg"
		fi
	else
		print_info "Skipped Codex installation"
		print_info "Install later: $installer install -g $install_pkg"
	fi

	return 0
}

# P0 fix: Remove broken MCP_DOCKER from Codex config.toml
# Docker Desktop 4.40+ with MCP Toolkit extension is required for `docker mcp`.
# OrbStack, Colima, Rancher Desktop do not support it.
_fix_codex_docker_mcp() {
	local config="${CODEX_HOME:-$HOME/.codex}/config.toml"
	[[ -f "$config" ]] || return 0

	# Check if MCP_DOCKER section exists
	if ! grep -q '^\[mcp_servers\.MCP_DOCKER\]' "$config" 2>/dev/null; then
		return 0
	fi

	# Docker can return success for help on an unknown subcommand.
	# The version command verifies that the MCP CLI plugin actually exists.
	if docker mcp version >/dev/null 2>&1; then
		return 0
	fi

	# Comment out the MCP_DOCKER section (from header to next section or EOF)
	# Use sed to comment out lines from [mcp_servers.MCP_DOCKER] to the next
	# section header or end of file. Portable sed (no -i on macOS without ext).
	local tmp_config
	tmp_config=$(mktemp)
	local in_mcp_docker=false
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "[mcp_servers.MCP_DOCKER]" ]]; then
			in_mcp_docker=true
			printf '# %s  # Disabled by aidevops: docker mcp not available\n' "$line" >>"$tmp_config"
			continue
		fi
		# If we hit another section header, stop commenting
		if [[ "$in_mcp_docker" == "${TOOL_INSTALL_BOOL_TRUE}" ]] && [[ "$line" == "["* ]]; then
			in_mcp_docker=false
		fi
		if [[ "$in_mcp_docker" == "${TOOL_INSTALL_BOOL_TRUE}" ]]; then
			printf '# %s\n' "$line" >>"$tmp_config"
		else
			printf '%s\n' "$line" >>"$tmp_config"
		fi
	done <"$config"
	mv "$tmp_config" "$config"
	print_info "Disabled MCP_DOCKER in Codex config (docker mcp not available on this system)"
	return 0
}

setup_droid_cli() {
	print_info "Setting up Factory.AI Droid CLI..."

	# Check if Droid is already installed
	if command -v droid >/dev/null 2>&1; then
		local droid_version
		droid_version=$(droid --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		print_success "Droid already installed: $droid_version"
		return 0
	fi

	# Droid uses its own installer — not available via npm/brew
	print_info "Droid (Factory.AI) is an AI coding agent CLI"
	echo "  It provides autonomous coding capabilities with Factory.AI models."
	echo "${TOOL_INSTALL_EMPTY}"

	local install_droid
	setup_prompt install_droid "Install Droid CLI? [Y/n]: " "Y"
	if [[ "$install_droid" =~ ^[Yy]?$ ]]; then
		print_info "Installing Droid CLI..."
		if command -v curl >/dev/null 2>&1; then
			if curl -fsSL https://app.factory.ai/install.sh | bash 2>/dev/null; then
				print_success "Droid installed"
				echo "${TOOL_INSTALL_EMPTY}"
				print_info "Run 'droid auth login' to authenticate with Factory.AI."
				echo "${TOOL_INSTALL_EMPTY}"
			else
				print_warning "Droid installation failed"
				print_info "Install manually from: https://docs.factory.ai/cli/installation"
			fi
		else
			print_warning "curl not found - cannot install Droid"
			print_info "Install manually from: https://docs.factory.ai/cli/installation"
		fi
	else
		print_info "Skipped Droid installation"
		print_info "Install later: curl -fsSL https://app.factory.ai/install.sh | bash"
	fi

	return 0
}

setup_google_workspace_cli() {
	print_info "Setting up Google Workspace CLI (gws)..."

	# Check if gws is already installed
	if command -v gws >/dev/null 2>&1; then
		local gws_version
		gws_version=$(gws --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		print_success "Google Workspace CLI already installed: $gws_version"
		return 0
	fi

	# Need either bun or npm to install
	local installer="${TOOL_INSTALL_EMPTY}"
	local install_pkg="@googleworkspace/cli@latest"

	if command -v bun >/dev/null 2>&1; then
		installer="bun"
	elif command -v npm >/dev/null 2>&1; then
		installer="npm"
	else
		print_warning "Neither bun nor npm found - cannot install gws"
		print_info "Install Node.js first, then re-run setup"
		return 0
	fi

	print_info "Google Workspace CLI provides Gmail, Calendar, Drive, and all Workspace APIs"
	echo "  Used by Email, Business, and Accounts agents for Google Workspace integration."
	echo "${TOOL_INSTALL_EMPTY}"

	local install_gws
	setup_prompt install_gws "Install Google Workspace CLI via $installer? [Y/n]: " "Y"
	if [[ "$install_gws" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Google Workspace CLI" npm_global_install "$install_pkg"; then
			print_success "Google Workspace CLI installed"

			echo "${TOOL_INSTALL_EMPTY}"
			print_info "Authentication required before use."
			print_info "Run 'gws auth setup' to authenticate with your Google account."
			print_info "For headless use: set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"
			echo "${TOOL_INSTALL_EMPTY}"
		else
			print_warning "Google Workspace CLI installation failed"
			print_info "Try manually: sudo npm install -g $install_pkg"
		fi
	else
		print_info "Skipped Google Workspace CLI installation"
		print_info "Install later: $installer install -g $install_pkg"
	fi

	return 0
}

setup_orbstack_vm() {
	# Only available on macOS
	if [[ "$(uname)" != "${TOOL_INSTALL_OS_DARWIN}" ]]; then
		return 0
	fi

	# Check if OrbStack is already installed
	if [[ -d "/Applications/OrbStack.app" ]] || command -v orb >/dev/null 2>&1; then
		print_success "OrbStack already installed"
		return 0
	fi

	print_info "OrbStack provides fast, lightweight Linux VMs on macOS"
	echo "  You can run aidevops in an isolated Linux environment."
	echo "  This is optional - aidevops works natively on macOS too."
	echo "${TOOL_INSTALL_EMPTY}"

	if ! command -v brew >/dev/null 2>&1; then
		print_info "OrbStack available at: https://orbstack.dev/"
		return 0
	fi

	setup_prompt install_orb "Install OrbStack? [y/N]: " "n"
	# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
	if [[ "$install_orb" =~ ^[Yy]$ ]]; then
		if run_with_spinner "Installing OrbStack" brew install --cask orbstack; then
			print_success "OrbStack installed"
			print_info "Create a VM: orb create ubuntu aidevops"
			print_info "Then install aidevops inside: orb run aidevops bash <(curl -fsSL https://aidevops.sh/install)"
		else
			print_warning "OrbStack installation failed"
			print_info "Download manually: https://orbstack.dev/"
		fi
	else
		print_info "Skipped OrbStack installation"
	fi

	return 0
}

setup_ai_orchestration() {
	print_info "Setting up AI orchestration frameworks..."

	# Check Python — uses check_python_version from _common.sh to avoid
	# duplicating find_python3 → parse → compare → offer_python_brew_install logic.
	if ! check_python_version "${TOOL_INSTALL_EMPTY}" "AI orchestration" >/dev/null; then
		return 0
	fi

	# Create orchestration directory
	mkdir -p "$HOME/.aidevops/orchestration"

	# Info about available frameworks
	print_info "AI Orchestration Frameworks available:"
	echo "  - Langflow: Visual flow builder (localhost:7860)"
	echo "  - CrewAI: Multi-agent teams (localhost:8501)"
	echo "  - AutoGen: Microsoft agentic AI (localhost:8081)"
	echo "${TOOL_INSTALL_EMPTY}"
	print_info "Setup individual frameworks with:"
	echo "  bash .agents/scripts/langflow-helper.sh setup"
	echo "  bash .agents/scripts/crewai-helper.sh setup"
	echo "  bash .agents/scripts/autogen-helper.sh setup"
	echo "${TOOL_INSTALL_EMPTY}"
	print_info "See .agents/tools/ai-orchestration/overview.md for comparison"

	return 0
}

# Prompt to install Ollama when the knowledge plane is enabled.
# Called from _setup_run_interactive when the user opts in.
# Installs Ollama and pulls the recommended fast model (llama3.1:8b).
# The reasoning model (llama3.1:70b) and embed model are suggested but not
# pulled automatically due to their large size (39 GB and 274 MB respectively).
setup_ollama_for_knowledge() {
	print_info "Ollama — local LLM for knowledge plane (pii/sensitive/privileged tiers)"
	print_info "Required for: tier:pii, tier:sensitive, tier:privileged routing."

	# Check if Ollama is already installed
	if command -v ollama >/dev/null 2>&1; then
		local version
		version=$(ollama --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1) || version="${TOOL_INSTALL_UNKNOWN}"
		print_success "Ollama already installed (version: ${version})"
	else
		print_info "Ollama not found."
		if [[ "$(uname -s)" == "${TOOL_INSTALL_OS_DARWIN}" ]] && command -v brew >/dev/null 2>&1; then
			print_info "Installing Ollama via Homebrew..."
			if brew install ollama 2>/dev/null; then
				print_success "Ollama installed via Homebrew"
			else
				print_warning "Homebrew install failed. Download from https://ollama.com"
				return 0
			fi
		else
			print_info "Install Ollama manually from https://ollama.com"
			print_info "Then re-run this setup to pull the recommended models."
			return 0
		fi
	fi

	# Deploy the bundle config template
	local bundle_dir="$HOME/.aidevops/configs"
	local bundle_dest="${bundle_dir}/ollama-bundle.json"
	local bundle_src
	bundle_src="${INSTALL_DIR}/.agents/templates/ollama-bundle.json"
	if [[ ! -f "$bundle_src" ]]; then
		bundle_src="$HOME/.aidevops/agents/templates/ollama-bundle.json"
	fi
	if [[ -f "$bundle_src" ]] && [[ ! -f "$bundle_dest" ]]; then
		mkdir -p "$bundle_dir"
		cp "$bundle_src" "$bundle_dest"
		print_success "Ollama bundle config deployed: ${bundle_dest}"
	fi

	# Start Ollama service if not running
	if ! curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
		print_info "Starting Ollama service..."
		ollama serve >/dev/null 2>&1 &
		local i=0
		while [[ $i -lt 10 ]]; do
			if curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
				break
			fi
			sleep 1
			i=$((i + 1))
		done
	fi

	# Pull the fast model (minimum required for pii/sensitive tiers)
	print_info "Pulling minimum required model: llama3.1:8b (~4.9 GB)"
	print_info "This is required for tier:pii and tier:sensitive routing."
	if ollama pull llama3.1:8b 2>/dev/null; then
		print_success "llama3.1:8b pulled successfully"
	else
		print_warning "Failed to pull llama3.1:8b. Run manually: ollama pull llama3.1:8b"
	fi

	# Pull the embed model (small — pull automatically)
	print_info "Pulling embed model: nomic-embed-text (~274 MB)"
	if ollama pull nomic-embed-text 2>/dev/null; then
		print_success "nomic-embed-text pulled successfully"
	else
		print_warning "Failed to pull nomic-embed-text. Run manually: ollama pull nomic-embed-text"
	fi

	print_info "${TOOL_INSTALL_EMPTY}"
	print_info "Optional: pull the reasoning model for tier:privileged (~39 GB, requires 48+ GB RAM):"
	print_info "  ollama pull llama3.1:70b"
	print_info "${TOOL_INSTALL_EMPTY}"
	print_info "Verify: ollama-helper.sh health"

	return 0
}
