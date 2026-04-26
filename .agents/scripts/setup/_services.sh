#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Service setup functions for setup.sh

# Setup SSH key
setup_ssh_key() {
	# TODO: Extract from setup.sh lines 2690-2708
	:
	return 0
}

# Setup configs (credentials, repos, etc.)
setup_configs() {
	# TODO: Extract from setup.sh lines 2711-2732
	:
	return 0
}

# Setup terminal title
setup_terminal_title() {
	# TODO: Extract from setup.sh lines 2951-3020
	:
	return 0
}

# Setup Python environment
setup_python_env() {
	# TODO: Extract from setup.sh lines 3814-3870
	:
	return 0
}

# Setup Node.js environment
setup_nodejs_env() {
	# TODO: Extract from setup.sh lines 3873-3906
	:
	return 0
}

# Setup Node.js
setup_nodejs() {
	# TODO: Extract from setup.sh lines 4650-4768
	:
	return 0
}

# Validate that an opencode binary is real anomalyco/opencode (t2888, mirrors t2887 validator).
# Returns: 0=valid, 1=wrong package, 2=missing/unrunnable.
# Inlined (not sourced from headless-runtime-lib.sh) so this module stays self-contained
# and runnable from `setup.sh --non-interactive` without sourcing the full runtime stack.
_setup_validate_opencode_binary() {
	local bin="${1:-}"
	[[ -n "$bin" ]] || return 2
	command -v "$bin" >/dev/null 2>&1 || return 2

	local version_output
	version_output=$("$bin" --version 2>/dev/null || echo "")
	[[ -n "$version_output" ]] || return 2

	# Anthropic claude CLI signature -- highest-confidence rejection
	[[ "$version_output" == *"(Claude Code)"* ]] && return 1

	# opencode is at 1.x; any 2.x+ is wrong (claude CLI is 2.1.x)
	[[ "$version_output" =~ ^[2-9][0-9]*\. ]] && return 1

	# Sanity check: must look like a semver (X.Y.Z)
	[[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1

	return 0
}

# Setup OpenCode CLI -- install/heal anomalyco/opencode (t2888).
#
# Why this exists: aidevops is built on opencode/Claude Code; the framework
# is supposed to ensure the CLI is present and correct. This function was
# a no-op stub since PR #20189 (t316.3 module extraction never ported the
# install body), so `aidevops update` never installed or healed opencode.
# Companion to t2887 (canary fail-fast) -- t2887 detects, this one heals.
#
# Behaviour:
#   1. Resolve current binary via $OPENCODE_BIN, then `command -v opencode`.
#   2. Validate via _setup_validate_opencode_binary (semver shape, no Claude
#      Code marker, major <= 1).
#   3. If invalid/missing: install opencode-ai@latest via bun (preferred)
#      or npm. The npm install overwrites whatever currently owns the
#      `opencode` bin symlink, healing wrong-package collisions.
#   4. Re-validate after install. Persist resolved path to
#      ~/.aidevops/.opencode-bin-resolved for diagnostics.
#
# Idempotent: skips install when validator passes. Safe in non-interactive
# (no prompts -- always installs when needed). Fail-open on errors so a
# missing toolchain (no bun/npm) doesn't block the rest of setup.
setup_opencode_cli() {
	local current_bin="${OPENCODE_BIN:-}"
	[[ -z "$current_bin" ]] && current_bin=$(command -v opencode 2>/dev/null || echo "")

	# Validate current state.
	local validate_rc=0
	if [[ -n "$current_bin" ]]; then
		_setup_validate_opencode_binary "$current_bin" || validate_rc=$?
	else
		validate_rc=2
	fi

	# Already valid -- record + exit fast.
	if [[ $validate_rc -eq 0 ]]; then
		local v
		v=$("$current_bin" --version 2>/dev/null | head -1 || echo "unknown")
		print_success "OpenCode CLI: $current_bin ($v)"
		mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
		printf '%s\n' "$current_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
		return 0
	fi

	# Diagnose what we found.
	if [[ $validate_rc -eq 1 ]]; then
		local wrong_version
		wrong_version=$("$current_bin" --version 2>/dev/null | head -1 || echo "<unknown>")
		print_warning "OpenCode binary at '$current_bin' is the wrong package ('$wrong_version')"
		print_info "Forcing reinstall of opencode-ai@latest to heal the bin collision (t2888)..."
	else
		print_info "OpenCode CLI not found -- installing opencode-ai@latest..."
	fi

	# Pick installer. Prefer bun (faster), fall back to npm.
	local installer=""
	if command -v bun >/dev/null 2>&1; then
		installer="bun"
	elif command -v npm >/dev/null 2>&1; then
		installer="npm"
	else
		print_warning "Neither bun nor npm found -- cannot install opencode-ai"
		print_info "Install Node.js or Bun first, then re-run 'aidevops update'"
		return 0
	fi

	# Install. opencode-ai@latest, global. npm install -g overwrites the
	# bin symlink even when another package (e.g. @anthropic-ai/claude-code)
	# previously owned the `opencode` name -- last-installed wins.
	if "$installer" install -g opencode-ai@latest >/dev/null 2>&1; then
		print_success "opencode-ai installed via $installer"
	else
		print_warning "opencode-ai install via $installer failed"
		print_info "Try manually: $installer install -g opencode-ai@latest"
		return 0
	fi

	# Re-resolve and re-validate.
	current_bin=$(command -v opencode 2>/dev/null || echo "")
	validate_rc=0
	if [[ -n "$current_bin" ]]; then
		_setup_validate_opencode_binary "$current_bin" || validate_rc=$?
	else
		validate_rc=2
	fi

	if [[ $validate_rc -eq 0 ]]; then
		local v
		v=$("$current_bin" --version 2>/dev/null | head -1 || echo "unknown")
		print_success "OpenCode CLI: $current_bin ($v)"
		mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
		printf '%s\n' "$current_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
	else
		# Post-install still wrong -- another `opencode` is earlier on PATH
		# than the npm/bun bin dir. The t2887 fallback path search will pick
		# this up at runtime, but flag it so the user knows.
		local v
		v=$("$current_bin" --version 2>/dev/null | head -1 || echo "<missing>")
		print_warning "Post-install validation still failing: '$current_bin' returns '$v'"
		print_info "Check PATH ordering: 'which -a opencode' and ensure the npm/bun global bin dir is first"
	fi

	return 0
}

# Setup OrbStack VM
setup_orbstack_vm() {
	# TODO: Extract from setup.sh lines 4826-4863
	:
	return 0
}

# Setup AI orchestration
setup_ai_orchestration() {
	# TODO: Extract from setup.sh lines 4866-4924
	:
	return 0
}

# Setup safety hooks
setup_safety_hooks() {
	# TODO: Extract from setup.sh lines 4927-4956
	:
	return 0
}

# Setup OpenCode plugins
setup_opencode_plugins() {
	# TODO: Extract from setup.sh lines 5000-5037
	:
	return 0
}

# Setup SEO MCPs
setup_seo_mcps() {
	# TODO: Extract from setup.sh lines 5040-5075
	:
	return 0
}

# Setup Google Analytics MCP
setup_google_analytics_mcp() {
	# TODO: Extract from setup.sh lines 5078-5182
	:
	return 0
}

# Setup QuickFile MCP
setup_quickfile_mcp() {
	# TODO: Extract from setup.sh lines 5185-5280
	:
	return 0
}

# Setup multi-tenant credentials
setup_multi_tenant_credentials() {
	# TODO: Extract from setup.sh lines 5283-5344
	:
	return 0
}

# Setup LocalWP MCP
setup_localwp_mcp() {
	# TODO: Extract from setup.sh lines 4100-4147
	:
	return 0
}

# Setup Augment Context Engine
setup_augment_context_engine() {
	# TODO: Extract from setup.sh lines 4150-4191
	:
	return 0
}

# Setup Beads (task management)
setup_beads() {
	# TODO: Extract from setup.sh lines 4364-4419
	:
	return 0
}

# Setup Beads UI
setup_beads_ui() {
	# TODO: Extract from setup.sh lines 4422-4524
	:
	return 0
}
