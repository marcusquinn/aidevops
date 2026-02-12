#!/usr/bin/env bash
# Tool installation functions: git-clis, fd, ripgrep, shellcheck, shfmt, rosetta, worktrunk, minisim, recommended-tools, nodejs, python, orbstack
# Part of aidevops setup.sh modularization (t316.3)

setup_git_clis() {
	print_info "Setting up Git CLI tools..."

	local cli_tools=()
	local missing_packages=()
	local missing_names=()

	# Check for GitHub CLI
	if ! command -v gh >/dev/null 2>&1; then
		missing_packages+=("gh")
		missing_names+=("GitHub CLI")
	else
		cli_tools+=("GitHub CLI")
	fi

	# Check for GitLab CLI
	if ! command -v glab >/dev/null 2>&1; then
		missing_packages+=("glab")
		missing_names+=("GitLab CLI")
	else
		cli_tools+=("GitLab CLI")
	fi

	# Report found tools
	if [[ ${#cli_tools[@]} -gt 0 ]]; then
		print_success "Found Git CLI tools: ${cli_tools[*]}"
	fi

	# Offer to install missing tools
	if [[ ${#missing_packages[@]} -gt 0 ]]; then
		print_warning "Missing Git CLI tools: ${missing_names[*]}"
		echo "  These provide enhanced Git platform integration (repos, PRs, issues)"

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			echo ""
			read -r -p "Install Git CLI tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " install_git_clis

			if [[ "$install_git_clis" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_packages[*]}..."
				if install_packages "$pkg_manager" "${missing_packages[@]}"; then
					print_success "Git CLI tools installed"
					echo ""
					echo "📋 Next steps - authenticate each CLI:"
					for pkg in "${missing_packages[@]}"; do
						case "$pkg" in
						gh) echo "  • gh auth login" ;;
						glab) echo "  • glab auth login" ;;
						esac
					done
				else
					print_warning "Failed to install some Git CLI tools (non-critical)"
				fi
			else
				print_info "Skipped Git CLI tools installation"
				echo ""
				echo "📋 Manual installation:"
				echo "  macOS: brew install ${missing_packages[*]}"
				echo "  Ubuntu: sudo apt install ${missing_packages[*]}"
				echo "  Fedora: sudo dnf install ${missing_packages[*]}"
			fi
		else
			echo ""
			echo "📋 Manual installation:"
			echo "  macOS: brew install ${missing_packages[*]}"
			echo "  Ubuntu: sudo apt install ${missing_packages[*]}"
			echo "  Fedora: sudo dnf install ${missing_packages[*]}"
		fi
	else
		print_success "All Git CLI tools installed and ready!"
	fi

	# Check for Gitea CLI separately (not in standard package managers)
	if ! command -v tea >/dev/null 2>&1; then
		print_info "Gitea CLI (tea) not found - install manually if needed:"
		echo "  go install code.gitea.io/tea/cmd/tea@latest"
		echo "  Or download from: https://dl.gitea.io/tea/"
	else
		print_success "Gitea CLI (tea) found"
	fi

	return 0
}

setup_file_discovery_tools() {
	print_info "Setting up file discovery tools..."

	local missing_tools=()
	local missing_packages=()
	local missing_names=()

	local fd_version
	if command -v fd >/dev/null 2>&1; then
		fd_version=$(fd --version 2>/dev/null | head -1 || echo "unknown")
		print_success "fd found: $fd_version"
	elif command -v fdfind >/dev/null 2>&1; then
		fd_version=$(fdfind --version 2>/dev/null | head -1 || echo "unknown")
		print_success "fd found (as fdfind): $fd_version"
		print_warning "Note: 'fd' alias not active in current shell. Restart shell or run: alias fd=fdfind"
	else
		missing_tools+=("fd")
		missing_packages+=("fd")
		missing_names+=("fd (fast file finder)")
	fi

	# Check for ripgrep
	if ! command -v rg >/dev/null 2>&1; then
		missing_tools+=("rg")
		missing_packages+=("ripgrep")
		missing_names+=("ripgrep (fast content search)")
	else
		local rg_version
		rg_version=$(rg --version 2>/dev/null | head -1 || echo "unknown")
		print_success "ripgrep found: $rg_version"
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing file discovery tools: ${missing_names[*]}"
		echo ""
		echo "  These tools provide 10x faster file discovery than built-in glob:"
		echo "    fd      - Fast alternative to 'find', respects .gitignore"
		echo "    ripgrep - Fast alternative to 'grep', respects .gitignore"
		echo ""
		echo "  AI agents use these for efficient codebase navigation."
		echo ""

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			local install_fd_tools="y"
			if [[ "$INTERACTIVE_MODE" == "true" ]]; then
				read -r -p "Install file discovery tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " install_fd_tools
			fi

			if [[ "$install_fd_tools" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_packages[*]}..."

				# Handle package name differences across package managers
				local actual_packages=()
				for pkg in "${missing_packages[@]}"; do
					case "$pkg_manager" in
					apt)
						# Debian/Ubuntu uses fd-find instead of fd
						if [[ "$pkg" == "fd" ]]; then
							actual_packages+=("fd-find")
						else
							actual_packages+=("$pkg")
						fi
						;;
					*)
						actual_packages+=("$pkg")
						;;
					esac
				done

				if install_packages "$pkg_manager" "${actual_packages[@]}"; then
					print_success "File discovery tools installed"

					# On Debian/Ubuntu, fd is installed as fdfind - create alias in all existing shell rc files
					if [[ "$pkg_manager" == "apt" ]] && command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
						local rc_files=("$HOME/.bashrc" "$HOME/.zshrc")
						local added_to=""

						for rc_file in "${rc_files[@]}"; do
							[[ ! -f "$rc_file" ]] && continue

							if ! grep -q 'alias fd="fdfind"' "$rc_file" 2>/dev/null; then
								if { echo '' >>"$rc_file" &&
									echo '# fd-find alias for Debian/Ubuntu (added by aidevops)' >>"$rc_file" &&
									echo 'alias fd="fdfind"' >>"$rc_file"; }; then
									added_to="${added_to:+$added_to, }$rc_file"
								fi
							fi
						done

						if [[ -n "$added_to" ]]; then
							print_success "Added alias fd=fdfind to: $added_to"
							echo "  Restart your shell to activate"
						else
							print_success "fd alias already configured"
						fi
					fi
				else
					print_warning "Failed to install some file discovery tools (non-critical)"
				fi
			else
				print_info "Skipped file discovery tools installation"
				echo ""
				echo "  Manual installation:"
				echo "    macOS:        brew install fd ripgrep"
				echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep"
				echo "    Fedora:       sudo dnf install fd-find ripgrep"
				echo "    Arch:         sudo pacman -S fd ripgrep"
			fi
		else
			echo ""
			echo "  Manual installation:"
			echo "    macOS:        brew install fd ripgrep"
			echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep"
			echo "    Fedora:       sudo dnf install fd-find ripgrep"
			echo "    Arch:         sudo pacman -S fd ripgrep"
		fi
	else
		print_success "All file discovery tools installed!"
	fi

	return 0
}

setup_shell_linting_tools() {
	print_info "Setting up shell linting tools..."

	local missing_tools=()
	local pkg_manager
	pkg_manager=$(detect_package_manager)

	# Check shellcheck
	if command -v shellcheck >/dev/null 2>&1; then
		local sc_path sc_arch
		sc_path=$(command -v shellcheck)
		# Prefer arm64 if present (universal/fat binaries report both architectures)
		local sc_file_output
		sc_file_output=$(file "$sc_path" 2>/dev/null)
		if echo "$sc_file_output" | grep -q 'arm64'; then
			sc_arch="arm64"
		else
			sc_arch=$(echo "$sc_file_output" | grep -oE '(x86_64)' | head -1)
		fi
		if [[ "$(uname -m)" == "arm64" ]] && [[ "$sc_arch" == "x86_64" ]]; then
			print_warning "shellcheck found but running under Rosetta (x86_64)"
			print_info "  Run 'rosetta-audit-helper.sh migrate' to fix"
		else
			print_success "shellcheck found ($(shellcheck --version 2>/dev/null | grep 'version:' | awk '{print $2}'))"
		fi
	else
		missing_tools+=("shellcheck")
	fi

	# Check shfmt
	if command -v shfmt >/dev/null 2>&1; then
		print_success "shfmt found ($(shfmt --version 2>/dev/null))"
	else
		missing_tools+=("shfmt")
	fi

	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing shell linting tools: ${missing_tools[*]}"
		echo "  shellcheck - static analysis for shell scripts"
		echo "  shfmt      - shell script formatter (fast syntax checks)"

		if [[ "$pkg_manager" != "unknown" ]]; then
			local install_linters
			if [[ "${NON_INTERACTIVE:-}" == "true" ]]; then
				install_linters="Y"
			else
				read -r -p "Install missing shell linting tools using $pkg_manager? [Y/n]: " install_linters
			fi

			if [[ "$install_linters" =~ ^[Yy]?$ ]]; then
				if install_packages "$pkg_manager" "${missing_tools[@]}"; then
					print_success "Shell linting tools installed"
				else
					print_warning "Failed to install some shell linting tools"
				fi
			else
				print_info "Skipped shell linting tools"
			fi
		else
			echo "  Install manually:"
			echo "    macOS: brew install ${missing_tools[*]}"
			echo "    Linux: apt install ${missing_tools[*]}"
		fi
	fi

	return 0
}

setup_rosetta_audit() {
	# Skip on non-Apple-Silicon or non-macOS
	if [[ "$(uname)" != "Darwin" ]] || [[ "$(uname -m)" != "arm64" ]]; then
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

setup_worktrunk() {
	print_info "Setting up Worktrunk (git worktree management)..."

	# Check if worktrunk (wt) is already installed
	if command -v wt >/dev/null 2>&1; then
		local wt_version
		wt_version=$(wt --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Worktrunk already installed: $wt_version"

		# Check if shell integration is installed (check all rc files)
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
			read -r -p "Install Worktrunk shell integration (enables 'wt switch' to change directories)? [Y/n]: " install_shell
			if [[ "$install_shell" =~ ^[Yy]?$ ]]; then
				print_info "Installing shell integration..."
				if wt config shell install; then
					print_success "Shell integration installed"
					print_info "Restart your terminal for the change to take effect"
				else
					print_warning "Shell integration failed - run manually: wt config shell install"
				fi
			fi
		else
			print_success "Shell integration already configured"
		fi
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
		read -r -p "Install Worktrunk via Homebrew? [Y/n]: " install_wt

		if [[ "$install_wt" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing Worktrunk via Homebrew" brew install max-sixty/worktrunk/wt; then
				# Install shell integration (don't use spinner - command is fast and may need interaction)
				print_info "Installing shell integration..."
				if wt config shell install; then
					print_success "Shell integration installed"
					print_info "Restart your terminal or source your shell config"
				else
					print_warning "Shell integration failed - run manually: wt config shell install"
				fi

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
	elif command -v cargo >/dev/null 2>&1; then
		read -r -p "Install Worktrunk via Cargo? [Y/n]: " install_wt

		if [[ "$install_wt" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing Worktrunk via Cargo" cargo install worktrunk; then
				# Install shell integration (don't use spinner - command is fast and may need interaction)
				print_info "Installing shell integration..."
				if wt config shell install; then
					print_success "Shell integration installed"
					print_info "Restart your terminal or source your shell config"
				else
					print_warning "Shell integration failed - run manually: wt config shell install"
				fi
			else
				print_warning "Cargo installation failed"
			fi
		else
			print_info "Skipped Worktrunk installation"
		fi
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
		local zed_extensions_dir=""
		if [[ "$(uname)" == "Darwin" ]]; then
			zed_extensions_dir="$HOME/Library/Application Support/Zed/extensions/installed"
		elif [[ "$(uname)" == "Linux" ]]; then
			zed_extensions_dir="$HOME/.local/share/zed/extensions/installed"
		fi

		if [[ -d "$zed_extensions_dir" ]]; then
			if [[ ! -d "$zed_extensions_dir/opencode" ]]; then
				read -r -p "Install OpenCode extension for Zed? [Y/n]: " install_opencode_ext
				if [[ "$install_opencode_ext" =~ ^[Yy]?$ ]]; then
					print_info "Installing OpenCode extension..."
					if [[ "$(uname)" == "Darwin" ]]; then
						open "zed://extension/opencode" 2>/dev/null
						print_success "OpenCode extension install triggered"
						print_info "Zed will open and prompt to install the extension"
					elif [[ "$(uname)" == "Linux" ]]; then
						xdg-open "zed://extension/opencode" 2>/dev/null ||
							print_info "Open Zed and install 'opencode' from Extensions"
					fi
				fi
			else
				print_success "OpenCode extension already installed in Zed"
			fi
		fi
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing recommended tools: ${missing_names[*]}"
		echo "  Tabby - Modern terminal with profiles, SSH manager, split panes"
		echo "  Zed   - High-performance AI-native code editor"
		echo ""

		# Install Tabby if missing
		if [[ " ${missing_tools[*]} " =~ " tabby " ]]; then
			read -r -p "Install Tabby terminal? [Y/n]: " install_tabby

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
					local arch
					arch=$(uname -m)
					# Tabby packagecloud repo only has x86_64 packages
					# ARM64 (aarch64) must use .deb from GitHub releases or skip
					if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
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
					else
						local pkg_manager
						pkg_manager=$(detect_package_manager)
						case "$pkg_manager" in
						apt)
							# Add packagecloud repo for Tabby (verified download, not piped to sudo)
							VERIFIED_INSTALL_SUDO="true"
							if verified_install "Tabby repository (apt)" "https://packagecloud.io/install/repositories/eugeny/tabby/script.deb.sh"; then
								if ! sudo apt-get install -y tabby-terminal; then
									print_warning "Tabby package not found for this architecture"
									echo "  Download from: https://github.com/Eugeny/tabby/releases/latest"
								fi
							fi
							;;
						dnf | yum)
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
					fi
				fi
			else
				print_info "Skipped Tabby installation"
			fi
		fi

		# Install Zed if missing
		if [[ " ${missing_tools[*]} " =~ " zed " ]]; then
			read -r -p "Install Zed editor? [Y/n]: " install_zed

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
					VERIFIED_INSTALL_SHELL="sh"
					if verified_install "Zed" "https://zed.dev/install.sh"; then
						zed_installed=true
					else
						print_warning "Failed to install Zed"
						echo "  See: https://zed.dev/docs/linux"
					fi
				fi

				# Install OpenCode extension for Zed
				if [[ "$zed_installed" == "true" ]]; then
					read -r -p "Install OpenCode extension for Zed? [Y/n]: " install_opencode_ext
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
				fi
			else
				print_info "Skipped Zed installation"
			fi
		fi
	else
		print_success "All recommended tools installed!"
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
	read -r -p "Install MiniSim? [Y/n]: " install_minisim

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

setup_ssh_key() {
	print_info "Checking SSH key setup..."

	if [[ ! -f ~/.ssh/id_ed25519 ]]; then
		print_warning "Ed25519 SSH key not found"
		read -r -p "Generate new Ed25519 SSH key? [Y/n]: " generate_key

		if [[ "$generate_key" =~ ^[Yy]?$ ]]; then
			read -r -p "Enter your email address: " email
			ssh-keygen -t ed25519 -C "$email"
			print_success "SSH key generated"
		else
			print_info "Skipping SSH key generation"
		fi
	else
		print_success "Ed25519 SSH key found"
	fi
	return 0
}

setup_python_env() {
	print_info "Setting up Python environment for DSPy..."

	# Check if Python 3 is available
	local python3_bin
	if ! python3_bin=$(find_python3); then
		print_warning "Python 3 not found - DSPy setup skipped"
		print_info "Install Python 3.8+ to enable DSPy integration"
		return
	fi

	local python_version
	python_version=$("$python3_bin" --version | cut -d' ' -f2 | cut -d'.' -f1-2)
	local version_check
	version_check=$("$python3_bin" -c "import sys; print(1 if sys.version_info >= (3, 8) else 0)")

	if [[ "$version_check" != "1" ]]; then
		print_warning "Python 3.8+ required for DSPy, found $python_version - DSPy setup skipped"
		return
	fi

	# Create Python virtual environment
	if [[ ! -d "python-env/dspy-env" ]] || [[ ! -f "python-env/dspy-env/bin/activate" ]]; then
		print_info "Creating Python virtual environment for DSPy..."
		mkdir -p python-env
		# Remove corrupted venv if directory exists but activate script is missing
		if [[ -d "python-env/dspy-env" ]] && [[ ! -f "python-env/dspy-env/bin/activate" ]]; then
			rm -rf python-env/dspy-env
		fi
		if python3 -m venv python-env/dspy-env; then
			print_success "Python virtual environment created"
		else
			print_warning "Failed to create Python virtual environment - DSPy setup skipped"
			return
		fi
	else
		print_info "Python virtual environment already exists"
	fi

	# Install DSPy dependencies
	print_info "Installing DSPy dependencies..."
	# shellcheck source=/dev/null
	if [[ -f "python-env/dspy-env/bin/activate" ]]; then
		source python-env/dspy-env/bin/activate
	else
		print_warning "Python venv activate script not found - DSPy setup skipped"
		return
	fi
	pip install --upgrade pip >/dev/null 2>&1

	if run_with_spinner "Installing DSPy dependencies" pip install -r requirements.txt; then
		: # Success message handled by spinner
	else
		print_info "Check requirements.txt or run manually:"
		print_info "  source python-env/dspy-env/bin/activate && pip install -r requirements.txt"
	fi
}

setup_nodejs_env() {
	print_info "Setting up Node.js environment for DSPyGround..."

	# Check if Node.js is available
	if ! command -v node &>/dev/null; then
		print_warning "Node.js not found - DSPyGround setup skipped"
		print_info "Install Node.js 18+ to enable DSPyGround integration"
		return
	fi

	local node_version
	node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ $node_version -lt 18 ]]; then
		print_warning "Node.js 18+ required for DSPyGround, found v$node_version - DSPyGround setup skipped"
		return
	fi

	# Check if npm is available
	if ! command -v npm &>/dev/null; then
		print_warning "npm not found - DSPyGround setup skipped"
		return
	fi

	# Install DSPyGround globally if not already installed
	if ! command -v dspyground &>/dev/null; then
		if run_with_spinner "Installing DSPyGround" npm_global_install dspyground; then
			: # Success message handled by spinner
		else
			print_warning "Try manually: sudo npm install -g dspyground"
		fi
	else
		print_success "DSPyGround already installed"
	fi
}

setup_nodejs() {
	# Check if Node.js is already installed
	if command -v node >/dev/null 2>&1; then
		local node_version
		node_version=$(node --version 2>/dev/null || echo "unknown")
		print_success "Node.js already installed: $node_version"
		# Distro nodejs package may not include npm — install it if missing
		if ! command -v npm >/dev/null 2>&1; then
			print_info "npm not found (distro nodejs package may omit it) — installing..."
			local pkg_manager
			pkg_manager=$(detect_package_manager)
			case "$pkg_manager" in
			apt) sudo apt-get install -y npm 2>/dev/null || print_warning "Failed to install npm via apt" ;;
			dnf | yum) sudo "$pkg_manager" install -y npm 2>/dev/null || print_warning "Failed to install npm via $pkg_manager" ;;
			brew) brew install npm 2>/dev/null || print_warning "Failed to install npm via brew" ;;
			*) print_warning "Cannot auto-install npm — install manually" ;;
			esac
		fi
		return 0
	fi

	print_info "Node.js is required for OpenCode, MCP servers, and many tools"

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	case "$pkg_manager" in
	brew)
		read -r -p "Install Node.js via Homebrew? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing Node.js" brew install node; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	apt)
		read -r -p "Install Node.js via apt? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			# Clean up stale Tabby packagecloud repo if present (causes apt-get update failures)
			if [[ -f /etc/apt/sources.list.d/eugeny_tabby.list ]]; then
				local arch
				arch=$(uname -m)
				if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
					print_info "Removing stale Tabby repo (not available for ARM64)..."
					sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.list
					sudo rm -f /etc/apt/sources.list.d/eugeny_tabby.sources
				fi
			fi
			# Use NodeSource for a recent version (apt default may be old)
			print_info "Installing Node.js (via NodeSource for latest LTS)..."
			if command -v curl >/dev/null 2>&1; then
				VERIFIED_INSTALL_SUDO="true"
				if verified_install "NodeSource repository" "https://deb.nodesource.com/setup_22.x"; then
					# Install nodejs (NodeSource bundles npm, but distro fallback may not)
					# Include npm explicitly in case NodeSource setup failed silently
					# and apt falls back to the distro nodejs package (which lacks npm)
					if sudo apt-get install -y nodejs npm 2>/dev/null || sudo apt-get install -y nodejs; then
						print_success "Node.js installed: $(node --version)"
					else
						print_warning "Node.js installation failed"
					fi
				else
					# Fallback to distro package
					print_info "Falling back to distro Node.js package..."
					if sudo apt-get install -y nodejs npm; then
						print_success "Node.js installed: $(node --version)"
					else
						print_warning "Node.js installation failed"
					fi
				fi
			else
				if sudo apt-get install -y nodejs npm; then
					print_success "Node.js installed: $(node --version)"
				else
					print_warning "Node.js installation failed"
				fi
			fi
		fi
		;;
	dnf | yum)
		read -r -p "Install Node.js via $pkg_manager? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo "$pkg_manager" install -y nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	pacman)
		read -r -p "Install Node.js via pacman? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo pacman -S --noconfirm nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	apk)
		read -r -p "Install Node.js via apk? [Y/n]: " install_node
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo apk add nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	*)
		print_warning "No supported package manager found for Node.js installation"
		echo "  Install manually: https://nodejs.org/"
		;;
	esac

	return 0
}

setup_opencode_cli() {
	print_info "Setting up OpenCode CLI..."

	# Check if OpenCode is already installed
	if command -v opencode >/dev/null 2>&1; then
		local oc_version
		oc_version=$(opencode --version 2>/dev/null | head -1 || echo "unknown")
		print_success "OpenCode already installed: $oc_version"
		return 0
	fi

	# Need either bun or npm to install
	local installer=""
	local install_pkg="opencode-ai@latest"

	if command -v bun >/dev/null 2>&1; then
		installer="bun"
	elif command -v npm >/dev/null 2>&1; then
		installer="npm"
	else
		print_warning "Neither bun nor npm found - cannot install OpenCode"
		print_info "Install Node.js first, then re-run setup"
		return 0
	fi

	print_info "OpenCode is the AI coding tool that aidevops is built for"
	echo "  It provides an AI-powered terminal interface for development tasks."
	echo ""

	local install_oc="Y"
	if [[ "$NON_INTERACTIVE" != "true" ]]; then
		read -r -p "Install OpenCode via $installer? [Y/n]: " install_oc || install_oc="Y"
	fi
	if [[ "$install_oc" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing OpenCode" npm_global_install "$install_pkg"; then
			print_success "OpenCode installed"

			# Offer authentication
			echo ""
			print_info "OpenCode needs authentication to use AI models."
			print_info "Run 'opencode auth login' to authenticate."
			echo ""
		else
			print_warning "OpenCode installation failed"
			print_info "Try manually: sudo npm install -g $install_pkg"
		fi
	else
		print_info "Skipped OpenCode installation"
		print_info "Install later: $installer install -g $install_pkg"
	fi

	return 0
}

setup_orbstack_vm() {
	# Only available on macOS
	if [[ "$(uname)" != "Darwin" ]]; then
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
	echo ""

	if ! command -v brew >/dev/null 2>&1; then
		print_info "OrbStack available at: https://orbstack.dev/"
		return 0
	fi

	read -r -p "Install OrbStack? [y/N]: " install_orb
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

	local has_python=false

	# Check Python (prefer Homebrew/pyenv over system)
	local python3_bin
	if python3_bin=$(find_python3); then
		local python_version
		python_version=$("$python3_bin" --version 2>&1 | cut -d' ' -f2)
		local major minor
		major=$(echo "$python_version" | cut -d. -f1)
		minor=$(echo "$python_version" | cut -d. -f2)

		if [[ $major -ge 3 ]] && [[ $minor -ge 10 ]]; then
			has_python=true
			print_success "Python $python_version found (3.10+ required)"
		else
			print_warning "Python 3.10+ required for AI orchestration, found $python_version"
			echo ""
			echo "  Upgrade options:"
			echo "    macOS (Homebrew): brew install python@3.12"
			echo "    macOS (pyenv):    pyenv install 3.12 && pyenv global 3.12"
			echo "    Ubuntu/Debian:    sudo apt install python3.12"
			echo "    Fedora:           sudo dnf install python3.12"
			echo ""
		fi
	else
		print_warning "Python 3 not found - AI orchestration frameworks unavailable"
		echo ""
		echo "  Install options:"
		echo "    macOS: brew install python@3.12"
		echo "    Linux: sudo apt install python3 (or dnf/pacman)"
		echo ""
		return 0
	fi

	if [[ "$has_python" == "false" ]]; then
		return 0
	fi

	# Create orchestration directory
	mkdir -p "$HOME/.aidevops/orchestration"

	# Info about available frameworks
	print_info "AI Orchestration Frameworks available:"
	echo "  - Langflow: Visual flow builder (localhost:7860)"
	echo "  - CrewAI: Multi-agent teams (localhost:8501)"
	echo "  - AutoGen: Microsoft agentic AI (localhost:8081)"
	echo ""
	print_info "Setup individual frameworks with:"
	echo "  bash .agents/scripts/langflow-helper.sh setup"
	echo "  bash .agents/scripts/crewai-helper.sh setup"
	echo "  bash .agents/scripts/autogen-helper.sh setup"
	echo ""
	print_info "See .agents/tools/ai-orchestration/overview.md for comparison"

	return 0
}

