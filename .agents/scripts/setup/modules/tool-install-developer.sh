#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Developer, simulator, SSH, and recommended-tool installation functions.
# Part of aidevops setup.sh modularization (GH#32734)

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -Eeuo pipefail

# Include guard
[[ -n "${_TOOL_INSTALL_DEVELOPER_LOADED:-}" ]] && return 0
_TOOL_INSTALL_DEVELOPER_LOADED=1

# SCRIPT_DIR fallback for direct sourcing and test harnesses.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_tool_install_module_path="${BASH_SOURCE[0]%/*}"
	[[ "$_tool_install_module_path" == "${BASH_SOURCE[0]}" ]] && _tool_install_module_path="."
	SCRIPT_DIR="$(cd "$_tool_install_module_path" && pwd)"
	unset _tool_install_module_path
fi

setup_rosetta_audit() {
	# Skip on non-Apple-Silicon or non-macOS
	if [[ "$(uname)" != "Darwin" ]] || [[ "$(uname -m)" != "$TOOL_INSTALL_ARCH_ARM64" ]]; then
		print_info "Rosetta audit: not applicable (Intel Mac or non-macOS)"
		return 0
	fi

	# Skip if no dual-brew setup
	if [[ ! -x "/usr/local/bin/brew" ]] || [[ ! -x "/opt/homebrew/bin/brew" ]]; then
		print_success "Rosetta audit: clean Homebrew setup (no x86 brew detected)"
		return 0
	fi

	print_info "Detected dual Homebrew (x86 + ARM) — checking for Rosetta overhead..."

	local x86_only_count dup_count
	dup_count=$(comm -12 \
		<(/usr/local/bin/brew list --formula 2>/dev/null | sort) \
		<(/opt/homebrew/bin/brew list --formula 2>/dev/null | sort) | wc -l | tr -d ' ')
	x86_only_count=$(comm -23 \
		<(/usr/local/bin/brew list --formula 2>/dev/null | sort) \
		<(/opt/homebrew/bin/brew list --formula 2>/dev/null | sort) | wc -l | tr -d ' ')

	local total=$((x86_only_count + dup_count))

	if [[ "$total" -eq 0 ]]; then
		print_success "No x86 Homebrew packages found — clean ARM setup"
		return 0
	fi

	print_warning "Found $total x86 Homebrew packages ($x86_only_count x86-only, $dup_count duplicates)"
	echo "  These run under Rosetta 2 emulation with ~30% performance overhead"
	echo ""
	echo "  To audit:   rosetta-audit-helper.sh scan"
	echo "  To migrate: rosetta-audit-helper.sh migrate --dry-run"
	echo "  To fix:     rosetta-audit-helper.sh migrate"

	return 0
}

# Install Worktrunk shell integration (enables 'wt switch' to change directories).
_setup_worktrunk_shell_integration() {
	print_info "Installing shell integration..."
	if wt config shell install; then
		print_success "Shell integration installed"
		print_info "Restart your terminal or source your shell config"
	else
		print_warning "Shell integration failed - run manually: wt config shell install"
	fi
	return 0
}

# Check and optionally install Worktrunk shell integration when wt is already present.
_check_worktrunk_shell_integration() {
	local wt_integrated=false
	local rc_file
	while IFS= read -r rc_file; do
		[[ -z "$rc_file" ]] && continue
		if [[ -f "$rc_file" ]] && grep -q "worktrunk" "$rc_file" 2>/dev/null; then
			wt_integrated=true
			break
		fi
	done < <(get_all_shell_rcs)

	if [[ "$wt_integrated" == "false" ]]; then
		print_info "Shell integration not detected"
		local install_shell
		setup_prompt install_shell "Install Worktrunk shell integration (enables 'wt switch' to change directories)? [Y/n]: " "Y"
		if [[ "$install_shell" =~ ^[Yy]?$ ]]; then
			_setup_worktrunk_shell_integration
		fi
	else
		print_success "Shell integration already configured"
	fi
	return 0
}

# Install Worktrunk via Homebrew and set up shell integration.
_install_worktrunk_brew() {
	local install_wt
	setup_prompt install_wt "Install Worktrunk via Homebrew? [Y/n]: " "Y"

	if [[ "$install_wt" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Worktrunk via Homebrew" brew install max-sixty/worktrunk/wt; then
			_setup_worktrunk_shell_integration
			echo ""
			print_info "Quick start:"
			echo "  wt switch feature/my-feature  # Create/switch to worktree"
			echo "  wt list                       # List all worktrees"
			echo "  wt merge                      # Merge and cleanup"
			echo ""
			print_info "Documentation: ~/.aidevops/agents/tools/git/worktrunk.md"
		else
			print_warning "Homebrew installation failed"
			echo "  Try: cargo install worktrunk && wt config shell install"
		fi
	else
		print_info "Skipped Worktrunk installation"
		print_info "Install later: brew install max-sixty/worktrunk/wt"
		print_info "Fallback available: ~/.aidevops/agents/scripts/worktree-helper.sh"
	fi
	return 0
}

# Install Worktrunk via Cargo and set up shell integration.
_install_worktrunk_cargo() {
	local install_wt
	setup_prompt install_wt "Install Worktrunk via Cargo? [Y/n]: " "Y"

	if [[ "$install_wt" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Worktrunk via Cargo" cargo install worktrunk; then
			_setup_worktrunk_shell_integration
		else
			print_warning "Cargo installation failed"
		fi
	else
		print_info "Skipped Worktrunk installation"
	fi
	return 0
}

setup_worktrunk() {
	print_info "Setting up Worktrunk (git worktree management)..."

	# Check if worktrunk (wt) is already installed
	if command -v wt >/dev/null 2>&1; then
		local wt_version
		wt_version=$(wt --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Worktrunk already installed: $wt_version"
		_check_worktrunk_shell_integration
		return 0
	fi

	# Worktrunk not installed - offer to install
	print_info "Worktrunk makes git worktrees as easy as branches"
	echo "  • wt switch feat     - Switch/create worktree (with cd)"
	echo "  • wt list            - List worktrees with CI status"
	echo "  • wt merge           - Squash/rebase/merge + cleanup"
	echo "  • Hooks for automated setup (npm install, etc.)"
	echo ""
	echo "  Note: aidevops also includes worktree-helper.sh as a fallback"
	echo ""

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	if [[ "$pkg_manager" == "brew" ]]; then
		_install_worktrunk_brew
	elif command -v cargo >/dev/null 2>&1; then
		_install_worktrunk_cargo
	else
		print_warning "Worktrunk not installed"
		echo ""
		echo "  Install options:"
		echo "    macOS/Linux (Homebrew): brew install max-sixty/worktrunk/wt"
		echo "    Cargo:                  cargo install worktrunk"
		echo "    Windows:                winget install max-sixty.worktrunk"
		echo ""
		echo "  After install: wt config shell install"
		echo ""
		print_info "Fallback available: ~/.aidevops/agents/scripts/worktree-helper.sh"
	fi

	return 0
}

# Trigger OpenCode extension install in Zed via the zed:// URI scheme.
_install_opencode_ext_for_zed() {
	local install_opencode_ext
	setup_prompt install_opencode_ext "Install OpenCode extension for Zed? [Y/n]: " "Y"
	if [[ "$install_opencode_ext" =~ ^[Yy]?$ ]]; then
		print_info "Installing OpenCode extension..."
		if [[ "$(uname)" == "Darwin" ]]; then
			open "zed://extension/opencode" 2>/dev/null
			print_success "OpenCode extension install triggered"
			print_info "Zed will open and prompt to install the extension"
		elif [[ "$(uname)" == "Linux" ]]; then
			xdg-open "zed://extension/opencode" 2>/dev/null ||
				print_info "Open Zed and install 'opencode' from Extensions (Cmd+Shift+X)"
		fi
	fi
	return 0
}

# Install Tabby terminal on Linux (x86_64 only via packagecloud; ARM64 manual).
_install_tabby_linux() {
	local arch
	arch=$(uname -m)
	# Tabby packagecloud repo only has x86_64 packages
	# ARM64 (aarch64) must use .deb from GitHub releases or skip
	if [[ "$arch" == "aarch64" || "$arch" == "$TOOL_INSTALL_ARCH_ARM64" ]]; then
		# Clean up stale Tabby packagecloud repo if it exists from a previous run
		# (it causes apt-get update failures on ARM64)
		if [[ -f /etc/apt/sources.list.d/eugeny_tabby.list ]]; then
			print_info "Removing stale Tabby packagecloud repo (not available for ARM64)..."
			sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.list
			sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.sources
			sudo apt-get update -qq 2>/dev/null || true
		fi
		print_warning "Tabby packages are not available for ARM64 Linux via package manager"
		echo "  Download ARM64 .deb from: https://github.com/Eugeny/tabby/releases/latest"
		echo "  Or skip Tabby - it's optional (a modern terminal emulator)"
		return 0
	fi

	local pkg_manager
	pkg_manager=$(detect_package_manager)
	case "$pkg_manager" in
	apt)
		# Add packagecloud repo for Tabby (verified download, not piped to sudo)
		# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
		VERIFIED_INSTALL_SUDO="true"
		if verified_install "Tabby repository (apt)" "https://packagecloud.io/install/repositories/eugeny/tabby/script.deb.sh"; then
			if ! sudo apt-get install -y tabby-terminal; then
				print_warning "Tabby package not found for this architecture"
				echo "  Download from: https://github.com/Eugeny/tabby/releases/latest"
			fi
		fi
		;;
	dnf | yum)
		# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
		VERIFIED_INSTALL_SUDO="true"
		if verified_install "Tabby repository (rpm)" "https://packagecloud.io/install/repositories/eugeny/tabby/script.rpm.sh"; then
			if ! sudo "$pkg_manager" install -y tabby-terminal; then
				print_warning "Tabby package not found for this architecture"
				echo "  Download from: https://github.com/Eugeny/tabby/releases/latest"
			fi
		fi
		;;
	pacman)
		# AUR package
		print_info "Tabby available in AUR as 'tabby-bin'"
		echo "  Install with: yay -S tabby-bin"
		;;
	*)
		echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
		;;
	esac
	return 0
}

# Offer and perform Tabby terminal installation.
_install_tabby() {
	local install_tabby
	setup_prompt install_tabby "Install Tabby terminal? [Y/n]: " "Y"

	if [[ "$install_tabby" =~ ^[Yy]?$ ]]; then
		if [[ "$(uname)" == "Darwin" ]]; then
			if command -v brew >/dev/null 2>&1; then
				if run_with_spinner "Installing Tabby" brew install --cask tabby; then
					: # Success message handled by spinner
				else
					print_warning "Failed to install Tabby via Homebrew"
					echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
				fi
			else
				print_warning "Homebrew not found"
				echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
			fi
		elif [[ "$(uname)" == "Linux" ]]; then
			_install_tabby_linux
		fi
	else
		print_info "Skipped Tabby installation"
	fi
	return 0
}

# Offer and perform Zed editor installation, then optionally install OpenCode extension.
_install_zed_and_opencode_ext() {
	local install_zed
	setup_prompt install_zed "Install Zed editor? [Y/n]: " "Y"

	if [[ "$install_zed" =~ ^[Yy]?$ ]]; then
		local zed_installed=false
		if [[ "$(uname)" == "Darwin" ]]; then
			if command -v brew >/dev/null 2>&1; then
				if run_with_spinner "Installing Zed" brew install --cask zed; then
					zed_installed=true
				else
					print_warning "Failed to install Zed via Homebrew"
					echo "  Download manually: https://zed.dev/download"
				fi
			else
				print_warning "Homebrew not found"
				echo "  Download manually: https://zed.dev/download"
			fi
		elif [[ "$(uname)" == "Linux" ]]; then
			# Zed provides an install script for Linux (verified download)
			# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
			VERIFIED_INSTALL_SHELL="sh"
			if verified_install "Zed" "https://zed.dev/install.sh"; then
				zed_installed=true
			else
				print_warning "Failed to install Zed"
				echo "  See: https://zed.dev/docs/linux"
			fi
		fi

		if [[ "$zed_installed" == "true" ]]; then
			_install_opencode_ext_for_zed
		fi
	else
		print_info "Skipped Zed installation"
	fi
	return 0
}

# Check for OpenCode extension in an existing Zed installation and offer to install.
_check_opencode_ext_existing_zed() {
	local zed_extensions_dir=""
	if [[ "$(uname)" == "Darwin" ]]; then
		zed_extensions_dir="$HOME/Library/Application Support/Zed/extensions/installed"
	elif [[ "$(uname)" == "Linux" ]]; then
		zed_extensions_dir="$HOME/.local/share/zed/extensions/installed"
	fi

	if [[ -d "$zed_extensions_dir" ]]; then
		if [[ ! -d "$zed_extensions_dir/opencode" ]]; then
			_install_opencode_ext_for_zed
		else
			print_success "OpenCode extension already installed in Zed"
		fi
	fi
	return 0
}

setup_recommended_tools() {
	print_info "Checking recommended development tools..."

	local missing_tools=()
	local missing_names=()

	# Check for Tabby terminal
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS - check Applications folder
		if [[ ! -d "/Applications/Tabby.app" ]]; then
			missing_tools+=("tabby")
			missing_names+=("Tabby (modern terminal)")
		else
			print_success "Tabby terminal found"
		fi
	elif [[ "$(uname)" == "Linux" ]]; then
		# Linux - check if tabby command exists
		if ! command -v tabby >/dev/null 2>&1; then
			missing_tools+=("tabby")
			missing_names+=("Tabby (modern terminal)")
		else
			print_success "Tabby terminal found"
		fi
	fi

	# Check for Zed editor
	local zed_exists=false
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS - check Applications folder
		if [[ ! -d "/Applications/Zed.app" ]]; then
			missing_tools+=("zed")
			missing_names+=("Zed (AI-native editor)")
		else
			print_success "Zed editor found"
			zed_exists=true
		fi
	elif [[ "$(uname)" == "Linux" ]]; then
		# Linux - check if zed command exists
		if ! command -v zed >/dev/null 2>&1; then
			missing_tools+=("zed")
			missing_names+=("Zed (AI-native editor)")
		else
			print_success "Zed editor found"
			zed_exists=true
		fi
	fi

	# Check for OpenCode extension in existing Zed installation
	if [[ "$zed_exists" == "true" ]]; then
		_check_opencode_ext_existing_zed
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing recommended tools: ${missing_names[*]}"
		echo "  Tabby - Modern terminal with profiles, SSH manager, split panes"
		echo "  Zed   - High-performance AI-native code editor"
		echo ""

		# Install Tabby if missing
		if [[ " ${missing_tools[*]} " =~ " tabby " ]]; then
			_install_tabby
		fi

		# Install Zed if missing
		if [[ " ${missing_tools[*]} " =~ " zed " ]]; then
			_install_zed_and_opencode_ext
		fi
	else
		print_success "All recommended tools installed!"
	fi

	# Check for Cursor CLI (agent) — independent of the missing_tools flow
	# since it uses a curl installer, not brew
	setup_cursor_cli

	return 0
}

setup_cursor_cli() {
	print_info "Checking Cursor CLI (agent)..."

	if command -v agent >/dev/null 2>&1; then
		local cursor_version
		cursor_version=$(agent --version 2>/dev/null || echo "unknown")
		print_success "Cursor CLI found: $cursor_version"
		return 0
	fi

	# Check ~/.local/bin specifically (may not be in PATH yet)
	if [[ -x "$HOME/.local/bin/agent" ]]; then
		local cursor_version
		cursor_version=$("$HOME/.local/bin/agent" --version 2>/dev/null || echo "unknown")
		print_success "Cursor CLI found at ~/.local/bin/agent: $cursor_version"
		print_info "Ensure ~/.local/bin is in your PATH"
		return 0
	fi

	echo "  Cursor CLI provides access to Cursor's AI models (including Composer 2)"
	echo "  from the terminal. Also usable as an OpenCode provider via the"
	echo "  opencode-cursor plugin for OAuth-based model access."
	echo ""

	local install_cursor
	setup_prompt install_cursor "Install Cursor CLI? [Y/n]: " "Y"

	if [[ "$install_cursor" =~ ^[Yy]?$ ]]; then
		print_info "Installing Cursor CLI..."
		if verified_install "Cursor CLI" "https://cursor.com/install"; then
			# Ensure ~/.local/bin is in PATH for this session
			if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
				export PATH="$HOME/.local/bin:$PATH"
				print_info "Added ~/.local/bin to PATH for this session"
			fi
			print_success "Cursor CLI installed"
			echo ""
			echo "  Next steps:"
			echo "    agent login     # Authenticate with your Cursor account"
			echo "    agent models    # List available models"
			echo "    agent status    # Check auth status"
		else
			print_warning "Failed to install Cursor CLI"
			echo "  Install manually: curl https://cursor.com/install -fsS | bash"
		fi
	else
		print_info "Skipped Cursor CLI installation"
		echo "  Install later: curl https://cursor.com/install -fsS | bash"
	fi

	return 0
}

setup_minisim() {
	# Only available on macOS
	if [[ "$(uname)" != "Darwin" ]]; then
		return 0
	fi

	print_info "Setting up MiniSim (iOS/Android emulator launcher)..."

	# Check if MiniSim is already installed
	if [[ -d "/Applications/MiniSim.app" ]]; then
		print_success "MiniSim already installed"
		print_info "Global shortcut: Option + Shift + E"
		return 0
	fi

	# Check if Xcode or Android Studio is installed (MiniSim needs at least one)
	local has_xcode=false
	local has_android=false

	if command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices >/dev/null 2>&1; then
		has_xcode=true
	fi

	if [[ -n "${ANDROID_HOME:-}" ]] || [[ -n "${ANDROID_SDK_ROOT:-}" ]] || [[ -d "$HOME/Library/Android/sdk" ]]; then
		has_android=true
	fi

	if [[ "$has_xcode" == "false" && "$has_android" == "false" ]]; then
		print_info "MiniSim requires Xcode (iOS) or Android Studio (Android)"
		print_info "Install one of these first, then re-run setup to install MiniSim"
		return 0
	fi

	# Show what's available
	local available_for=""
	if [[ "$has_xcode" == "true" ]]; then
		available_for="iOS simulators"
	fi
	if [[ "$has_android" == "true" ]]; then
		if [[ -n "$available_for" ]]; then
			available_for="$available_for and Android emulators"
		else
			available_for="Android emulators"
		fi
	fi

	print_info "MiniSim is a menu bar app for launching $available_for"
	echo "  Features:"
	echo "    - Global shortcut: Option + Shift + E"
	echo "    - Launch/manage iOS simulators and Android emulators"
	echo "    - Copy device UDID/ADB ID"
	echo "    - Cold boot Android emulators"
	echo "    - Run Android emulators without audio (saves Bluetooth battery)"
	echo ""

	# Check if Homebrew is available
	if ! command -v brew >/dev/null 2>&1; then
		print_warning "Homebrew not found - cannot install MiniSim automatically"
		echo "  Install manually: https://github.com/okwasniewski/MiniSim/releases"
		return 0
	fi

	local install_minisim
	setup_prompt install_minisim "Install MiniSim? [Y/n]: " "Y"

	if [[ "$install_minisim" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing MiniSim" brew install --cask minisim; then
			print_info "Global shortcut: Option + Shift + E"
			print_info "Documentation: ~/.aidevops/agents/tools/mobile/minisim.md"
		else
			print_warning "Failed to install MiniSim via Homebrew"
			echo "  Install manually: https://github.com/okwasniewski/MiniSim/releases"
		fi
	else
		print_info "Skipped MiniSim installation"
		print_info "Install later: brew install --cask minisim"
	fi

	return 0
}

setup_claudebar_needs_upgrade() {
	local installed_version="$1"
	local target_version="$2"
	local installed_major="" installed_minor="" installed_patch=""
	local target_major="" target_minor="" target_patch=""

	installed_version="${installed_version#v}"
	target_version="${target_version#v}"

	if [[ ! "$installed_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
		return 0
	fi
	installed_major="${BASH_REMATCH[1]}"
	installed_minor="${BASH_REMATCH[2]}"
	installed_patch="${BASH_REMATCH[3]}"

	if [[ ! "$target_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
		return 0
	fi
	target_major="${BASH_REMATCH[1]}"
	target_minor="${BASH_REMATCH[2]}"
	target_patch="${BASH_REMATCH[3]}"

	if ((10#$installed_major > 10#$target_major)); then
		return 1
	fi
	if ((10#$installed_major == 10#$target_major && 10#$installed_minor > 10#$target_minor)); then
		return 1
	fi
	if ((10#$installed_major == 10#$target_major && 10#$installed_minor == 10#$target_minor && 10#$installed_patch >= 10#$target_patch)); then
		return 1
	fi

	return 0
}

setup_claudebar() {
	local claudebar_release_url="https://github.com/tddworks/ClaudeBar/releases/latest"
	local claudebar_target_version="0.4.66"
	# Only available on macOS (native Swift menu bar app)
	if [[ "$(uname)" != "Darwin" ]]; then
		return 0
	fi

	print_info "Setting up ClaudeBar (AI quota monitor)..."

	# Check if ClaudeBar is already installed
	if [[ -d "/Applications/ClaudeBar.app" ]]; then
		local claudebar_info_plist="/Applications/ClaudeBar.app/Contents/Info.plist"
		local installed_version=""

		if [[ -f "$claudebar_info_plist" ]]; then
			installed_version="$(defaults read "$claudebar_info_plist" CFBundleShortVersionString 2>/dev/null || true)"
		fi

		print_success "ClaudeBar already installed"
		if ! setup_claudebar_needs_upgrade "$installed_version" "$claudebar_target_version"; then
			print_info "ClaudeBar ${installed_version} already includes the v${claudebar_target_version} setup upgrade"
			return 0
		fi

		print_info "ClaudeBar v0.4.66 adds live background menu-bar refresh and suppresses its own quota probe events"
		if command -v brew >/dev/null 2>&1; then
			local upgrade_claudebar
			setup_prompt upgrade_claudebar "Upgrade ClaudeBar via Homebrew cask? [y/N]: " "N"
			if [[ "$upgrade_claudebar" =~ ^[Yy]$ ]]; then
				if run_with_spinner "Upgrading ClaudeBar" brew upgrade --cask claudebar; then
					print_success "ClaudeBar upgraded"
				else
					print_warning "Failed to upgrade ClaudeBar via Homebrew"
					print_info "Manual ClaudeBar download: $claudebar_release_url"
				fi
			else
				print_info "Upgrade later: brew upgrade --cask claudebar"
			fi
		else
			print_info "Update manually: $claudebar_release_url"
		fi
		return 0
	fi

	# Check if Homebrew is available (required for cask install)
	if ! command -v brew >/dev/null 2>&1; then
		print_warning "Homebrew not found - cannot install ClaudeBar automatically"
		echo "  Download manually: $claudebar_release_url"
		return 0
	fi

	print_info "ClaudeBar monitors AI coding assistant usage quotas in your menu bar"
	echo "  Supports: Claude, Codex, Gemini, Copilot, Antigravity, Kimi, Kiro, Amp"
	echo "  Features: live menu-bar refresh, quota probe suppression, real-time quota tracking, provider process detection, status notifications, multiple themes"
	echo "  Requires: macOS 15+, CLI tools for providers you want to monitor"
	echo ""

	local install_claudebar
	setup_prompt install_claudebar "Install ClaudeBar? [Y/n]: " "Y"

	if [[ "$install_claudebar" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing ClaudeBar" brew install --cask claudebar; then
			print_success "ClaudeBar installed"
			print_info "Launch from Applications or Spotlight to start monitoring quotas"
		else
			print_warning "Failed to install ClaudeBar via Homebrew"
			echo "  Download manually: $claudebar_release_url"
		fi
	else
		print_info "Skipped ClaudeBar installation"
		print_info "Install later: brew install --cask claudebar"
	fi

	return 0
}

# Keep an existing Nostr VPN install current (GH#23846). Never installs Nostr VPN:
# it adds a root network daemon, so first install stays an explicit user choice.
setup_nostr_vpn() {
	local helper="$HOME/.aidevops/agents/scripts/nostr-vpn-helper.sh"
	if [[ ! -d "/Applications/Nostr VPN.app" && ! -x "/Library/PrivilegedHelperTools/to.nostrvpn.nvpn" ]] &&
		! command -v nvpn >/dev/null 2>&1; then
		return 0
	fi
	if [[ ! -f "$helper" ]]; then
		print_warning "nostr-vpn-helper.sh not deployed yet; skipping Nostr VPN update check"
		return 0
	fi
	print_info "Checking Nostr VPN (nvpn) install..."
	bash "$helper" update || print_warning "Nostr VPN update check encountered issues (non-critical)"
	return 0
}

setup_ssh_key() {
	print_info "Checking SSH key setup..."

	if [[ ! -f ~/.ssh/id_ed25519 ]]; then
		print_warning "Ed25519 SSH key not found"

		# SSH key generation requires email input — skip in non-interactive mode
		if [[ "${NON_INTERACTIVE:-false}" == "true" ]] || [[ ! -t 0 ]]; then
			print_info "Skipping SSH key generation (non-interactive mode)"
			return 0
		fi

		local generate_key
		setup_prompt generate_key "Generate new Ed25519 SSH key? [Y/n]: " "Y"

		if [[ "$generate_key" =~ ^[Yy]?$ ]]; then
			local email
			setup_prompt email "Enter your email address: " ""
			if [[ -z "$email" ]]; then
				print_warning "No email provided — skipping SSH key generation"
				return 0
			fi
			install -d -m 700 ~/.ssh
			ssh-keygen -t ed25519 -C "$email" -f ~/.ssh/id_ed25519
			print_success "SSH key generated"
		else
			print_info "Skipping SSH key generation"
		fi
	else
		print_success "Ed25519 SSH key found"
	fi
	return 0
}

# Check installed Python version against latest stable available from package manager.
# Warns if an upgrade is available but never auto-upgrades (GH#5237).
# Works on macOS (Homebrew) and Linux (apt/dnf).
# Named check_python_upgrade_available() to avoid collision with the shared
# check_python_version() in _common.sh (which validates minimum required version).
