#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Tool setup functions for setup.sh

# Setup git CLIs (gh, glab)
setup_git_clis() {
	# TODO: Extract from setup.sh lines 1955-2039
	:
	return 0
}

# Setup file discovery tools (fd, rg, rga)
setup_file_discovery_tools() {
	# TODO: Extract from setup.sh lines 2042-2167
	:
	return 0
}

# Setup shell linting tools (shellcheck, shfmt)
setup_shell_linting_tools() {
	# TODO: Extract from setup.sh lines 2170-2236
	:
	return 0
}

# Setup Rosetta audit tool
setup_rosetta_audit() {
	# TODO: Extract from setup.sh lines 2239-2277
	:
	return 0
}

# Setup Worktrunk (git worktree manager)
setup_worktrunk() {
	# TODO: Extract from setup.sh lines 2279-2393
	:
	return 0
}

# Setup recommended tools
setup_recommended_tools() {
	# TODO: Extract from setup.sh lines 2396-2605
	:
	return 0
}

# Setup MiniSim (iOS simulator manager)
setup_minisim() {
	# TODO: Extract from setup.sh lines 2608-2687
	:
	return 0
}

# Setup browser tools (Playwright, Puppeteer, etc.)
setup_browser_tools() {
	# TODO: Extract from setup.sh lines 4527-4647
	:
	return 0
}

# Check for tool updates
check_tool_updates() {
	# TODO: Extract from setup.sh lines 5347-5400
	:
	return 0
}

# Module-level global for linux PIM tool check/install (bash 3.2 / zsh compatible).
# Replaces local -n namerefs which are unsupported in bash 3.2 and zsh.
# See t2719 / GH#20393 and the canonical pattern in shared-gh-wrappers.sh (t2688).
_SETUP_TOOLS_LINUX_MISSING=()

# macOS PIM: Calendar/Contacts/Notes use osascript; Reminders needs remindctl
_setup_pim_tools_macos() {
	print_success "Calendar: uses Calendar.app via osascript (no install needed)"
	print_success "Contacts: uses Contacts.app via osascript (no install needed)"
	print_success "Notes: uses Notes.app via osascript (no install needed)"

	if command -v remindctl >/dev/null 2>&1; then
		print_success "Reminders: remindctl installed"
		return 0
	fi

	print_info "Reminders: installing remindctl..."
	if command -v brew >/dev/null 2>&1; then
		brew install steipete/tap/remindctl 2>&1 || print_warning "remindctl install failed"
		if command -v remindctl >/dev/null 2>&1; then
			print_success "remindctl installed"
			print_info "Run 'remindctl authorize' to grant Reminders access"
		fi
	else
		print_warning "Homebrew not found. Install remindctl manually: brew install steipete/tap/remindctl"
	fi
	return 0
}

# Linux PIM: detect missing tools and populate _SETUP_TOOLS_LINUX_MISSING.
# Resets the module global on entry; callers read _SETUP_TOOLS_LINUX_MISSING
# after this call. No arguments required.
# Bash 3.2 / zsh compatible — does NOT use local -n namerefs (t2719).
_setup_pim_tools_linux_check() {
	_SETUP_TOOLS_LINUX_MISSING=()

	if ! command -v todo >/dev/null 2>&1; then
		_SETUP_TOOLS_LINUX_MISSING+=("todoman")
	else
		print_success "Reminders: todoman installed"
	fi

	if ! command -v khal >/dev/null 2>&1; then
		_SETUP_TOOLS_LINUX_MISSING+=("khal")
	else
		print_success "Calendar: khal installed"
	fi

	if ! command -v khard >/dev/null 2>&1; then
		_SETUP_TOOLS_LINUX_MISSING+=("khard")
	else
		print_success "Contacts: khard installed"
	fi

	if ! command -v vdirsyncer >/dev/null 2>&1; then
		_SETUP_TOOLS_LINUX_MISSING+=("vdirsyncer")
	else
		print_success "CalDAV/CardDAV sync: vdirsyncer installed"
	fi
	return 0
}

# Linux PIM: install nb (notes) and any missing tools via pipx or brew.
# Reads _SETUP_TOOLS_LINUX_MISSING populated by _setup_pim_tools_linux_check.
# No arguments required.
# Bash 3.2 / zsh compatible — does NOT use local -n namerefs (t2719).
_setup_pim_tools_linux_install() {
	# Notes: nb (not in pipx — brew or direct install)
	if ! command -v nb >/dev/null 2>&1; then
		print_info "Notes: nb not installed"
		if command -v brew >/dev/null 2>&1; then
			print_info "Notes: installing nb..."
			brew install nb 2>&1 || print_warning "nb install failed"
			command -v nb >/dev/null 2>&1 && print_success "nb installed"
		else
			print_warning "Notes: install nb manually — brew install nb (or see https://xwmx.github.io/nb/)"
		fi
	else
		print_success "Notes: nb installed"
	fi

	if [[ ${#_SETUP_TOOLS_LINUX_MISSING[@]} -eq 0 ]]; then
		return 0
	fi

	local pkg_list
	pkg_list="$(printf '%s ' "${_SETUP_TOOLS_LINUX_MISSING[@]}")"
	print_info "Installing missing PIM tools: ${pkg_list}"
	if command -v pipx >/dev/null 2>&1; then
		local pkg
		for pkg in "${_SETUP_TOOLS_LINUX_MISSING[@]}"; do
			pipx install "$pkg" 2>&1 || print_warning "Failed to install ${pkg}"
		done
	elif command -v brew >/dev/null 2>&1; then
		brew install "${_SETUP_TOOLS_LINUX_MISSING[@]}" 2>&1 || print_warning "Some PIM tools failed to install"
	else
		print_warning "Install manually with pipx or brew: ${pkg_list}"
	fi
	return 0
}

# Linux PIM: warn about missing config files
_setup_pim_tools_linux_configs() {
	[[ ! -f "${HOME}/.config/vdirsyncer/config" ]] &&
		print_warning "vdirsyncer not configured. Run: reminders-helper.sh help (for CalDAV config example)"
	[[ ! -f "${HOME}/.config/khal/config" ]] &&
		print_warning "khal not configured. Run: khal configure"
	[[ ! -f "${HOME}/.config/khard/khard.conf" ]] &&
		print_warning "khard not configured. See: contacts-helper.sh help"
	[[ ! -f "${HOME}/.config/todoman/config.py" ]] &&
		print_warning "todoman not configured. See: reminders-helper.sh help"
	return 0
}

# Setup PIM tools (Reminders, Calendar, Contacts, Notes)
# macOS: remindctl (Reminders), osascript (Calendar, Contacts, Notes — no install)
# Linux: todoman, khal, khard + vdirsyncer (CalDAV/CardDAV), nb (notes)
setup_pim_tools() {
	local os
	os="$(uname -s)"

	print_info "Setting up PIM tools (Reminders, Calendar, Contacts, Notes)..."

	if [[ "$os" == "Darwin" ]]; then
		_setup_pim_tools_macos
	else
		_setup_pim_tools_linux_check
		_setup_pim_tools_linux_install
		_setup_pim_tools_linux_configs
	fi

	print_success "PIM tools setup complete. Use *-helper.sh setup for per-tool verification."
	return 0
}
