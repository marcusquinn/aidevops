#!/usr/bin/env bash
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

# Setup PIM tools (Reminders, Calendar, Contacts, Notes)
# macOS: remindctl (Reminders), osascript (Calendar, Contacts, Notes — no install)
# Linux: todoman, khal, khard + vdirsyncer (CalDAV/CardDAV), nb (notes)
setup_pim_tools() {
	local os
	os="$(uname -s)"

	print_info "Setting up PIM tools (Reminders, Calendar, Contacts, Notes)..."

	if [[ "$os" == "Darwin" ]]; then
		# macOS: Calendar, Contacts, Notes use osascript (no install needed)
		print_success "Calendar: uses Calendar.app via osascript (no install needed)"
		print_success "Contacts: uses Contacts.app via osascript (no install needed)"
		print_success "Notes: uses Notes.app via osascript (no install needed)"

		# Reminders needs remindctl
		if command -v remindctl >/dev/null 2>&1; then
			print_success "Reminders: remindctl installed"
		else
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
		fi
	else
		# Linux: todoman, khal, khard via pipx/brew; vdirsyncer for sync; nb for notes
		local missing=()

		if ! command -v todo >/dev/null 2>&1; then
			missing+=("todoman")
		else
			print_success "Reminders: todoman installed"
		fi

		if ! command -v khal >/dev/null 2>&1; then
			missing+=("khal")
		else
			print_success "Calendar: khal installed"
		fi

		if ! command -v khard >/dev/null 2>&1; then
			missing+=("khard")
		else
			print_success "Contacts: khard installed"
		fi

		if ! command -v vdirsyncer >/dev/null 2>&1; then
			missing+=("vdirsyncer")
		else
			print_success "CalDAV/CardDAV sync: vdirsyncer installed"
		fi

		# Notes: nb (not in pipx — brew or direct install)
		if ! command -v nb >/dev/null 2>&1; then
			print_info "Notes: nb not installed"
			if command -v brew >/dev/null 2>&1; then
				print_info "Notes: installing nb..."
				brew install nb 2>&1 || print_warning "nb install failed"
				if command -v nb >/dev/null 2>&1; then
					print_success "nb installed"
				fi
			else
				print_warning "Notes: install nb manually — brew install nb (or see https://xwmx.github.io/nb/)"
			fi
		else
			print_success "Notes: nb installed"
		fi

		if [[ ${#missing[@]} -gt 0 ]]; then
			local pkg_list
			pkg_list="$(printf '%s ' "${missing[@]}")"
			print_info "Installing missing PIM tools: ${pkg_list}"
			if command -v pipx >/dev/null 2>&1; then
				local pkg
				for pkg in "${missing[@]}"; do
					pipx install "$pkg" 2>&1 || print_warning "Failed to install ${pkg}"
				done
			elif command -v brew >/dev/null 2>&1; then
				brew install "${missing[@]}" 2>&1 || print_warning "Some PIM tools failed to install"
			else
				print_warning "Install manually with pipx or brew: ${pkg_list}"
			fi
		fi

		# Check configs
		if [[ ! -f "${HOME}/.config/vdirsyncer/config" ]]; then
			print_warning "vdirsyncer not configured. Run: reminders-helper.sh help (for CalDAV config example)"
		fi
		if [[ ! -f "${HOME}/.config/khal/config" ]]; then
			print_warning "khal not configured. Run: khal configure"
		fi
		if [[ ! -f "${HOME}/.config/khard/khard.conf" ]]; then
			print_warning "khard not configured. See: contacts-helper.sh help"
		fi
		if [[ ! -f "${HOME}/.config/todoman/config.py" ]]; then
			print_warning "todoman not configured. See: reminders-helper.sh help"
		fi
	fi

	print_success "PIM tools setup complete. Use *-helper.sh setup for per-tool verification."
	return 0
}
