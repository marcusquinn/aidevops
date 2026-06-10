#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Status Library — status command helper functions
# =============================================================================
# Helper functions for `aidevops status`, extracted from aidevops.sh to keep
# the CLI orchestrator below the large-file gate while preserving behaviour.
#
# Usage: source "${INSTALL_DIR}/aidevops-status-lib.sh"
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AIDEVOPS_STATUS_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_STATUS_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_status_recommended_tools() {
	print_header "Recommended Tools"
	if [[ "$(uname)" == "Darwin" ]]; then
		check_dir "/Applications/Tabby.app" && print_success "Tabby terminal" || print_warning "Tabby terminal - not installed"
		if check_dir "/Applications/Zed.app"; then
			print_success "Zed editor"
			check_dir "$HOME/Library/Application Support/Zed/extensions/installed/opencode" && print_success "  └─ OpenCode extension" || print_warning "  └─ OpenCode extension - not installed"
		else print_warning "Zed editor - not installed"; fi
	else
		check_cmd tabby && print_success "Tabby terminal" || print_warning "Tabby terminal - not installed"
		if check_cmd zed; then
			print_success "Zed editor"
			check_dir "$HOME/.local/share/zed/extensions/installed/opencode" && print_success "  └─ OpenCode extension" || print_warning "  └─ OpenCode extension - not installed"
		else print_warning "Zed editor - not installed"; fi
	fi
	echo ""
	return 0
}

_status_ai_tools() {
	print_header "AI Tools & MCPs"
	check_cmd opencode && print_success "OpenCode CLI" || print_warning "OpenCode CLI - not installed"
	if check_cmd auggie; then
		check_file "$HOME/.augment/session.json" && print_success "Augment Context Engine (authenticated)" || print_warning "Augment Context Engine (not authenticated)"
	else print_warning "Augment Context Engine - not installed"; fi
	check_cmd bd && print_success "Beads CLI (task graph)" || print_warning "Beads CLI (bd) - not installed"
	echo ""
	return 0
}

_status_dev_envs() {
	print_header "Development Environments"
	check_dir "$INSTALL_DIR/python-env/dspy-env" && print_success "DSPy Python environment" || print_warning "DSPy Python environment - not created"
	check_cmd dspyground && print_success "DSPyGround" || print_warning "DSPyGround - not installed"
	echo ""
	return 0
}

_status_ai_configs() {
	print_header "AI Assistant Configurations"
	local ai_configs=("$HOME/.config/opencode/opencode.json:OpenCode" "$HOME/.claude/commands:Claude Code CLI" "$HOME/CLAUDE.md:Claude Code memory")
	for config in "${ai_configs[@]}"; do
		local path="${config%%:*}" name="${config##*:}"
		[[ -e "$path" ]] && print_success "$name" || print_warning "$name - not configured"
	done
	echo ""
	return 0
}

_status_headless_runtime_config() {
	print_header "Headless Runtime Configuration"
	local allowlist_set=false
	local credentials_file="${AIDEVOPS_CREDENTIALS_FILE:-${CONFIG_DIR:-$HOME/.config/aidevops}/credentials.sh}"
	local credentials_has_allowlist=false

	if [[ -n "${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}" ]]; then
		allowlist_set=true
	fi
	if [[ -f "$credentials_file" ]] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=' "$credentials_file" 2>/dev/null; then
		credentials_has_allowlist=true
	fi

	if [[ "$credentials_has_allowlist" == "true" ]]; then
		print_success "Headless provider allowlist is configured in credentials.sh"
	elif [[ "$allowlist_set" == "true" ]]; then
		print_warning "Headless provider allowlist is only set in this shell; pulse/systemd/cron may not see shell rc files"
		print_info "Add the export to ~/.config/aidevops/credentials.sh for daemon-visible headless routing"
	else
		print_info "No headless provider allowlist configured"
	fi
	echo ""
	return 0
}

# Status command
cmd_status() {
	print_header "AI DevOps Framework Status"
	echo "=========================="
	echo ""
	local current_version
	current_version=$(get_version)
	local remote_version
	remote_version=$(get_remote_version)
	print_header "Version"
	echo "  Installed: $current_version"
	echo "  Latest:    $remote_version"
	if [[ "$current_version" != "$remote_version" && "$remote_version" != "unknown" ]]; then
		print_warning "Update available! Run: aidevops update"
	elif [[ "$current_version" == "$remote_version" ]]; then print_success "Up to date"; fi
	echo ""
	print_header "Installation"
	check_dir "$INSTALL_DIR" && print_success "Repository: $INSTALL_DIR" || print_error "Repository: Not found at $INSTALL_DIR"
	if check_dir "$AGENTS_DIR"; then
		local agent_count
		agent_count=$(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		print_success "Agents: $AGENTS_DIR ($agent_count files)"
	else print_error "Agents: Not deployed"; fi
	echo ""
	print_header "Required Dependencies"
	for cmd in git curl jq ssh; do check_cmd "$cmd" && print_success "$cmd" || print_error "$cmd - not installed"; done
	echo ""
	print_header "Optional Dependencies"
	check_cmd sshpass && print_success "sshpass" || print_warning "sshpass - not installed (needed for password SSH)"
	echo ""
	_status_recommended_tools
	print_header "Git CLI Tools"
	if ! check_cmd gh; then
		print_warning "GitHub CLI (gh) - not installed"
	elif declare -F aidevops_gh_slurp_supported >/dev/null 2>&1 && aidevops_gh_slurp_supported; then
		print_success "$(aidevops_gh_slurp_status_message)"
	elif declare -F aidevops_gh_slurp_status_message >/dev/null 2>&1; then
		print_warning "$(aidevops_gh_slurp_status_message)"
	else
		print_success "GitHub CLI (gh)"
	fi
	check_cmd glab && print_success "GitLab CLI (glab)" || print_warning "GitLab CLI (glab) - not installed"
	check_cmd tea && print_success "Gitea CLI (tea)" || print_warning "Gitea CLI (tea) - not installed"
	echo ""
	_status_ai_tools
	_status_dev_envs
	_status_ai_configs
	_status_headless_runtime_config
	print_header "SSH Configuration"
	check_file "$HOME/.ssh/id_ed25519" && print_success "Ed25519 SSH key" || print_warning "Ed25519 SSH key - not found"
	echo ""
	print_header "Commit Signing"
	local signing_format signing_key signing_enabled
	signing_format=$(git config --global gpg.format 2>/dev/null || echo "")
	signing_key=$(git config --global user.signingkey 2>/dev/null || echo "")
	signing_enabled=$(git config --global commit.gpgsign 2>/dev/null || echo "")
	if [[ "$signing_format" == "ssh" && -n "$signing_key" && "$signing_enabled" == "true" ]]; then
		print_success "SSH commit signing enabled"
		if check_file "$HOME/.ssh/allowed_signers"; then
			print_success "Allowed signers file configured"
		else
			print_warning "No allowed_signers file — run: aidevops signing setup"
		fi
	else
		print_warning "Commit signing not configured — run: aidevops signing setup"
	fi
	echo ""
	# t2424/GH#20030: Pulse operational counters (pre-dispatch aborts, etc.)
	local stats_helper="$AGENTS_DIR/scripts/pulse-stats-helper.sh"
	if [[ -x "$stats_helper" ]]; then
		print_header "Pulse Stats"
		"$stats_helper" status 2>/dev/null || print_info "  (no stats recorded yet)"
		echo ""
	fi
}
