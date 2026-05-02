#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Beads task graph visualization setup and Claude Code safety hooks.
# Split from agent-deploy.sh (t1940)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

install_beads_binary() {
	local os arch tarball_name
	os=$(uname -s | tr '[:upper:]' '[:lower:]')
	arch=$(uname -m)

	# Map architecture names to Beads release naming convention
	case "$arch" in
	x86_64 | amd64) arch="amd64" ;;
	aarch64 | arm64) arch="arm64" ;;
	*)
		print_warning "Unsupported architecture for Beads binary download: $arch"
		return 1
		;;
	esac

	# Get latest version tag from GitHub API
	local latest_version
	latest_version=$(curl -fsSL "https://api.github.com/repos/steveyegge/beads/releases/latest" 2>/dev/null |
		grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/')

	if [[ -z "$latest_version" ]]; then
		print_warning "Could not determine latest Beads version from GitHub"
		return 1
	fi

	tarball_name="beads_${latest_version}_${os}_${arch}.tar.gz"
	local download_url="https://github.com/steveyegge/beads/releases/download/v${latest_version}/${tarball_name}"

	print_info "Downloading Beads CLI v${latest_version} (${os}/${arch})..."

	local tmp_dir
	tmp_dir=$(mktemp -d)
	# shellcheck disable=SC2064  # Intentional: $tmp_dir must expand at trap definition time, not execution time
	trap "rm -rf '$tmp_dir'" RETURN

	if ! curl -fsSL "$download_url" -o "$tmp_dir/$tarball_name" 2>/dev/null; then
		print_warning "Failed to download Beads binary from $download_url"
		return 1
	fi

	if ! tar -xzf "$tmp_dir/$tarball_name" -C "$tmp_dir" 2>/dev/null; then
		print_warning "Failed to extract Beads binary"
		return 1
	fi

	local bd_binary
	bd_binary=$(find "$tmp_dir" -name "bd" -type f 2>/dev/null | head -1)
	if [[ -z "$bd_binary" ]]; then
		print_warning "bd binary not found in downloaded archive"
		return 1
	fi

	# Install to a writable location
	local install_dir="/usr/local/bin"
	if [[ ! -w "$install_dir" ]]; then
		if command -v sudo &>/dev/null; then
			sudo install -m 755 "$bd_binary" "$install_dir/bd"
		else
			# Fallback to user-local bin
			install_dir="$HOME/.local/bin"
			mkdir -p "$install_dir"
			install -m 755 "$bd_binary" "$install_dir/bd"
			if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
				export PATH="$HOME/.local/bin:$PATH"
				print_info "Added ~/.local/bin to PATH for this session"
			fi
		fi
	else
		install -m 755 "$bd_binary" "$install_dir/bd"
	fi

	if command -v bd &>/dev/null; then
		print_success "Beads CLI installed via binary download (v${latest_version})"
		return 0
	else
		print_warning "Beads binary installed to $install_dir/bd but not found in PATH"
		return 1
	fi
}

install_beads_go() {
	if ! command -v go &>/dev/null; then
		return 1
	fi
	if run_with_spinner "Installing Beads via Go" go install github.com/steveyegge/beads/cmd/bd@latest; then
		print_info "Ensure \$GOPATH/bin is in your PATH"
		return 0
	fi
	print_warning "Go installation failed"
	return 1
}

setup_beads() {
	print_info "Setting up Beads (task graph visualization)..."

	if command -v bd &>/dev/null; then
		local bd_version
		bd_version=$(bd --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Beads CLI (bd) already installed: $bd_version"
	else
		# Try to install via Homebrew first (macOS/Linux with Homebrew)
		if command -v brew &>/dev/null; then
			if run_with_spinner "Installing Beads via Homebrew" brew install steveyegge/beads/bd; then
				: # Success message handled by spinner
			else
				print_warning "Homebrew tap installation failed, trying alternative..."
				install_beads_binary || install_beads_go
			fi
		elif command -v go &>/dev/null; then
			if ! install_beads_go; then
				print_warning "Go installation failed, trying binary download..."
				install_beads_binary
			fi
		else
			# No brew, no Go -- try binary download first, then offer Homebrew install
			if ! install_beads_binary; then
				# Binary download failed -- offer to install Homebrew (Linux only)
				if ensure_homebrew; then
					# Homebrew now available, retry via tap
					if run_with_spinner "Installing Beads via Homebrew" brew install steveyegge/beads/bd; then
						: # Success
					else
						print_warning "Homebrew tap installation failed"
					fi
				else
					print_warning "Beads CLI (bd) not installed"
					echo ""
					echo "  Install options:"
					echo "    Binary download:        https://github.com/steveyegge/beads/releases"
					echo "    macOS/Linux (Homebrew):  brew install steveyegge/beads/bd"
					echo "    Go:                      go install github.com/steveyegge/beads/cmd/bd@latest"
					echo ""
				fi
			fi
		fi
	fi

	print_info "Beads provides task graph visualization for TODO.md and PLANS.md"
	print_info "After installation, run: aidevops init beads"

	# Offer to install optional Beads UI tools
	setup_beads_ui

	return 0
}

# _install_bv_tool: install the bv (beads_viewer) TUI tool.
# Returns 0 if installed, 1 if skipped or failed.
_install_bv_tool() {
	setup_prompt install_viewer "  Install bv (TUI with PageRank, critical path, graph analytics)? [Y/n]: " "Y"
	if [[ ! "$install_viewer" =~ ^[Yy]?$ ]]; then
		print_info "Install later:"
		print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
		print_info "  Go: go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest"
		return 1
	fi
	if command -v brew &>/dev/null; then
		if run_with_spinner "Installing bv via Homebrew" brew install dicklesworthstone/tap/bv; then
			print_info "Run: bv (in a beads-enabled project)"
			return 0
		else
			print_warning "Homebrew install failed - try manually:"
			print_info "  brew install dicklesworthstone/tap/bv"
			return 1
		fi
	elif command -v go &>/dev/null; then
		if run_with_spinner "Installing bv via Go" go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest; then
			print_info "Run: bv (in a beads-enabled project)"
			return 0
		else
			print_warning "Go install failed"
			return 1
		fi
	else
		# Offer verified install script (download-then-execute, not piped)
		setup_prompt use_script "  Install bv via install script? [Y/n]: " "Y"
		if [[ "$use_script" =~ ^[Yy]?$ ]]; then
			if verified_install "bv (beads viewer)" "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh"; then
				print_info "Run: bv (in a beads-enabled project)"
				return 0
			else
				print_warning "Install script failed - try manually:"
				print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
				return 1
			fi
		else
			print_info "Install later:"
			print_info "  Homebrew: brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv"
			print_info "  Go: go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest"
			return 1
		fi
	fi
}

# _install_beads_node_tools: install beads-ui and bdui via npm.
# Echoes the count of tools installed to stdout.
# All informational output (spinner, status) goes to stderr so that
# command-substitution callers receive only the numeric count.
_install_beads_node_tools() {
	local count=0
	if ! command -v npm &>/dev/null; then
		echo "$count"
		return 0
	fi
	setup_prompt install_web "  Install beads-ui (Web dashboard)? [Y/n]: " "Y"
	if [[ "$install_web" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing beads-ui" npm_global_install beads-ui 1>&2; then
			print_info "Run: beads-ui" >&2
			count=$((count + 1))
		fi
	fi
	setup_prompt install_bdui "  Install bdui (React/Ink TUI)? [Y/n]: " "Y"
	if [[ "$install_bdui" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing bdui" npm_global_install bdui 1>&2; then
			print_info "Run: bdui" >&2
			count=$((count + 1))
		fi
	fi
	echo "$count"
	return 0
}

# _install_perles: install the perles BQL query language TUI via cargo.
# Returns 0 if installed, 1 if skipped or unavailable.
_install_perles() {
	if ! command -v cargo &>/dev/null; then
		return 1
	fi
	setup_prompt install_perles "  Install perles (BQL query language TUI)? [Y/n]: " "Y"
	if [[ ! "$install_perles" =~ ^[Yy]?$ ]]; then
		return 1
	fi
	if run_with_spinner "Installing perles (Rust compile)" cargo install perles; then
		print_info "Run: perles"
		return 0
	fi
	return 1
}

setup_beads_ui() {
	echo ""
	print_info "Beads UI tools provide enhanced visualization:"
	echo "  • bv (Go)            - PageRank, critical path, graph analytics TUI"
	echo "  • beads-ui (Node.js) - Web dashboard with live updates"
	echo "  • bdui (Node.js)     - React/Ink terminal UI"
	echo "  • perles (Rust)      - BQL query language TUI"
	echo ""

	setup_prompt install_beads_ui "Install optional Beads UI tools? [Y/n]: " "Y"

	if [[ ! "$install_beads_ui" =~ ^[Yy]?$ ]]; then
		print_info "Skipped Beads UI tools (can install later from beads.md docs)"
		return 0
	fi

	local installed_count=0

	# bv (beads_viewer) - Go TUI installed via Homebrew
	# https://github.com/Dicklesworthstone/beads_viewer
	if _install_bv_tool; then
		installed_count=$((installed_count + 1))
	fi

	# beads-ui and bdui (Node.js)
	local node_count
	node_count=$(_install_beads_node_tools)
	installed_count=$((installed_count + node_count))

	# perles (Rust)
	if _install_perles; then
		installed_count=$((installed_count + 1))
	fi

	if [[ $installed_count -gt 0 ]]; then
		print_success "Installed $installed_count Beads UI tool(s)"
	else
		print_info "No Beads UI tools installed"
	fi

	echo ""
	print_info "Beads UI documentation: ~/.aidevops/agents/tools/task-management/beads.md"

	return 0
}

setup_safety_hooks() {
	print_info "Setting up Claude Code safety hooks..."

	if ! command -v python3 &>/dev/null; then
		print_warning "Python 3 not found - safety hooks require Python 3"
		return 0
	fi

	local helper_script="$HOME/.aidevops/agents/scripts/install-hooks-helper.sh"
	if [[ ! -f "$helper_script" ]]; then
		# Fall back to repo copy (INSTALL_DIR set by setup.sh)
		helper_script="${INSTALL_DIR:-.}/.agents/scripts/install-hooks-helper.sh"
	fi

	if [[ ! -f "$helper_script" ]]; then
		print_warning "install-hooks-helper.sh not found - skipping safety hooks"
		return 0
	fi

	if bash "$helper_script" install; then
		print_success "Claude Code safety hooks installed"
	else
		print_warning "Safety hook installation encountered issues (non-critical)"
	fi
	return 0
}
