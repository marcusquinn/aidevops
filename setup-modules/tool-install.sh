#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Tool installation functions: git-clis, fd, ripgrep, shellcheck, shfmt, rosetta, worktrunk, minisim, recommended-tools, nodejs, python, orbstack
# Part of aidevops setup.sh modularization (t316.3)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

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
			setup_prompt install_git_clis "Install Git CLI tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " "Y"

			if [[ "$install_git_clis" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_packages[*]}..."
				if install_packages "$pkg_manager" "${missing_packages[@]}"; then
					print_success "Git CLI tools installed"
					echo ""
					echo "📋 Next steps - authenticate each CLI:"
					for pkg in "${missing_packages[@]}"; do
						case "$pkg" in
						gh) echo "  • gh auth login -s workflow  (workflow scope required for CI PRs)" ;;
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

_print_file_discovery_manual_install() {
	echo ""
	echo "  Manual installation:"
	echo "    macOS:        brew install fd ripgrep ripgrep-all"
	echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep  # rga: cargo install ripgrep_all"
	echo "    Fedora:       sudo dnf install fd-find ripgrep   # rga: cargo install ripgrep_all"
	echo "    Arch:         sudo pacman -S fd ripgrep ripgrep-all"
	return 0
}

# Add fd=fdfind alias to shell rc files on Debian/Ubuntu after apt install.
_add_fd_alias_debian() {
	local rc_files=("$HOME/.bashrc" "$HOME/.zshrc")
	local added_to=""
	local rc_file

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
	return 0
}

# Resolve apt package names (fd→fd-find on Debian/Ubuntu) and install.
_install_file_discovery_packages() {
	local pkg_manager="$1"
	shift
	local missing_packages=("$@")

	print_info "Installing ${missing_packages[*]}..."

	local actual_packages=()
	local pkg
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
		# On Debian/Ubuntu, fd is installed as fdfind — create alias in shell rc files
		if [[ "$pkg_manager" == "apt" ]] && command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
			_add_fd_alias_debian
		fi
	else
		print_warning "Failed to install some file discovery tools (non-critical)"
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

	# Check for ripgrep-all (searches inside PDFs, DOCX, SQLite, archives)
	if ! command -v rga >/dev/null 2>&1; then
		missing_tools+=("rga")
		missing_packages+=("ripgrep-all")
		missing_names+=("ripgrep-all (search inside PDFs/docs/archives)")
	else
		local rga_version
		rga_version=$(rga --version 2>/dev/null | head -1 || echo "unknown")
		print_success "ripgrep-all found: $rga_version"
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing file discovery tools: ${missing_names[*]}"
		echo ""
		echo "  These tools provide 10x faster file discovery than built-in glob:"
		echo "    fd          - Fast alternative to 'find', respects .gitignore"
		echo "    ripgrep     - Fast alternative to 'grep', respects .gitignore"
		echo "    ripgrep-all - Extends ripgrep to search inside PDFs, DOCX, SQLite, archives"
		echo ""
		echo "  AI agents use these for efficient codebase navigation."
		echo ""

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "unknown" ]]; then
			setup_prompt install_fd_tools "Install file discovery tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " "Y"

			if [[ "$install_fd_tools" =~ ^[Yy]?$ ]]; then
				_install_file_discovery_packages "$pkg_manager" "${missing_packages[@]}"
			else
				print_info "Skipped file discovery tools installation"
				_print_file_discovery_manual_install
			fi
		else
			_print_file_discovery_manual_install
		fi
	else
		print_success "All file discovery tools installed!"
	fi

	return 0
}

setup_rtk() {
	# rtk — CLI proxy that reduces LLM token consumption by 60-90% (t1430)
	# Optional optimization: compresses git/gh/test outputs before they reach LLM context
	# Single Rust binary, zero dependencies, <10ms overhead
	# https://github.com/rtk-ai/rtk

	# Pin to a tagged release for stability and auditability (Gemini review feedback).
	# Update the tag when upstream-watch detects a new release.
	local rtk_installer_url="https://raw.githubusercontent.com/rtk-ai/rtk/v0.28.2/install.sh"

	if command -v rtk >/dev/null 2>&1; then
		local rtk_version
		rtk_version=$(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
		print_success "rtk found: v$rtk_version (token optimization proxy)"
		# Fall through to ensure config is applied (telemetry, tee)
	else
		print_info "rtk (Rust Token Killer) reduces LLM token usage by 60-90% on CLI commands"
		echo "  Compresses git, gh, test runner, and linter outputs before they reach the AI context."
		echo "  Single binary, zero dependencies, <10ms overhead."
		echo ""

		setup_prompt install_rtk "Install rtk for token-optimized CLI output? [y/N]: " "n"

		if [[ "$install_rtk" =~ ^[Yy]$ ]]; then
			VERIFIED_INSTALL_SHELL="sh"
			if command -v brew >/dev/null 2>&1; then
				if run_with_spinner "Installing rtk via Homebrew" brew install rtk; then
					print_success "rtk installed via Homebrew"
				else
					print_warning "Homebrew install failed, trying curl installer..."
					if verified_install "rtk" "$rtk_installer_url"; then
						print_success "rtk installed to ~/.local/bin/rtk"
					else
						print_warning "rtk installation failed (non-critical, optional tool)"
					fi
				fi
			else
				# Linux or macOS without brew — use verified_install for secure execution
				if verified_install "rtk" "$rtk_installer_url"; then
					print_success "rtk installed to ~/.local/bin/rtk"
				else
					print_warning "rtk installation failed (non-critical, optional tool)"
					echo "  Manual install: https://github.com/rtk-ai/rtk#installation"
				fi
			fi
		else
			print_info "Skipped rtk installation (optional)"
			echo "  Manual install: brew install rtk  OR  curl -fsSL $rtk_installer_url | sh"
		fi
	fi

	# Configure rtk (telemetry off, tee for failure capture) — only if binary is present
	if command -v rtk >/dev/null 2>&1; then
		local rtk_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rtk"
		if [[ ! -f "$rtk_config_dir/config.toml" ]]; then
			mkdir -p "$rtk_config_dir"
			cat >"$rtk_config_dir/config.toml" <<-'RTKEOF'
				# rtk configuration (created by aidevops setup.sh)
				# https://github.com/rtk-ai/rtk

				[telemetry]
				enabled = false

				[tee]
				enabled = true
				mode = "failures"
				max_files = 20
			RTKEOF
			print_success "rtk config created (telemetry disabled)"
		fi
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
		local sc_version sc_rosetta=false
		sc_version=$(shellcheck --version 2>/dev/null | grep 'version:' | awk '{print $2}' || echo "unknown")
		# Rosetta detection (macOS Apple Silicon only, requires `file` command)
		if [[ "$PLATFORM_MACOS" == "true" ]] && [[ "$PLATFORM_ARM64" == "true" ]] && command -v file >/dev/null 2>&1; then
			local sc_file_output
			sc_file_output=$(file "$(command -v shellcheck)" 2>/dev/null || echo "")
			if [[ "$sc_file_output" == *"x86_64"* ]] && [[ "$sc_file_output" != *"arm64"* ]]; then
				sc_rosetta=true
			fi
		fi
		if [[ "$sc_rosetta" == "true" ]]; then
			print_warning "shellcheck found but running under Rosetta (x86_64)"
			print_info "  Run 'rosetta-audit-helper.sh migrate' to fix"
		else
			print_success "shellcheck found ($sc_version)"
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
			setup_prompt install_linters "Install missing shell linting tools using $pkg_manager? [Y/n]: " "Y"

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

setup_shellcheck_wrapper() {
	# Replace the real shellcheck binary with our wrapper script to prevent
	# --external-sources from causing exponential memory growth (GH#2915).
	# This intercepts ALL callers including compiled binaries (e.g., OpenCode)
	# that invoke shellcheck by absolute path rather than via PATH.

	local wrapper_src="${INSTALL_DIR:-.}/.agents/scripts/shellcheck-wrapper.sh"
	if [[ ! -f "$wrapper_src" ]]; then
		print_info "shellcheck-wrapper.sh not found — skipping binary replacement"
		return 0
	fi

	# Find the real shellcheck binary
	local sc_path
	sc_path="$(command -v shellcheck 2>/dev/null || true)"
	if [[ -z "$sc_path" ]]; then
		print_info "shellcheck not installed — wrapper not needed yet"
		return 0
	fi

	# Resolve symlinks to get the actual binary path
	local sc_resolved
	sc_resolved="$(realpath "$sc_path" 2>/dev/null || readlink -f "$sc_path" 2>/dev/null || echo "$sc_path")"

	# Check if the binary is already our wrapper (idempotent)
	if head -5 "$sc_resolved" 2>/dev/null | grep -q "shellcheck-wrapper" 2>/dev/null; then
		# Already replaced — check that .real exists
		local real_path="${sc_resolved}.real"
		if [[ ! -x "$real_path" ]]; then
			print_warning "shellcheck wrapper installed but .real binary missing at $real_path"
			print_info "Reinstall shellcheck (brew reinstall shellcheck) then re-run setup"
			return 0
		fi

		# Check if the installed wrapper is outdated vs the source
		if ! diff -q "$wrapper_src" "$sc_resolved" >/dev/null 2>&1; then
			print_info "Updating shellcheck wrapper at $sc_resolved (source is newer)"
			if cp "$wrapper_src" "$sc_resolved" 2>/dev/null || sudo cp "$wrapper_src" "$sc_resolved" 2>/dev/null; then
				chmod +x "$sc_resolved" 2>/dev/null || sudo chmod +x "$sc_resolved" 2>/dev/null || true
				print_success "shellcheck wrapper updated at $sc_resolved"
			else
				print_warning "Cannot update wrapper — insufficient permissions"
			fi
		else
			print_success "shellcheck wrapper already installed at $sc_resolved"
		fi
		return 0
	fi

	# The binary at sc_resolved is the real shellcheck — replace it
	local real_dest="${sc_resolved}.real"

	print_info "Installing shellcheck wrapper at $sc_resolved"
	print_info "  Real binary will be moved to $real_dest"

	# Move real binary to .real suffix
	if ! mv "$sc_resolved" "$real_dest" 2>/dev/null; then
		# May need sudo (e.g., /usr/local/bin on some systems)
		if ! sudo mv "$sc_resolved" "$real_dest" 2>/dev/null; then
			print_warning "Cannot move shellcheck binary — insufficient permissions"
			print_info "Run manually: sudo mv '$sc_resolved' '$real_dest'"
			return 0
		fi
	fi

	# Copy wrapper to the original path
	if ! cp "$wrapper_src" "$sc_resolved" 2>/dev/null; then
		if ! sudo cp "$wrapper_src" "$sc_resolved" 2>/dev/null; then
			# Rollback
			mv "$real_dest" "$sc_resolved" 2>/dev/null || sudo mv "$real_dest" "$sc_resolved" 2>/dev/null || true
			print_warning "Cannot install wrapper — insufficient permissions"
			return 0
		fi
	fi

	# Ensure wrapper is executable
	chmod +x "$sc_resolved" 2>/dev/null || sudo chmod +x "$sc_resolved" 2>/dev/null || true

	print_success "shellcheck wrapper installed — --external-sources will be stripped"
	print_info "  Real binary: $real_dest"
	print_info "  Wrapper:     $sc_resolved"

	return 0
}

setup_qlty_cli() {
	print_info "Setting up Qlty CLI (multi-linter code quality)..."

	local qlty_bin="${HOME}/.qlty/bin/qlty"

	# Check if already installed
	if [[ -x "$qlty_bin" ]]; then
		local qlty_version
		qlty_version=$("$qlty_bin" --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Qlty CLI already installed: $qlty_version"
		return 0
	fi

	# Also check PATH in case it's installed elsewhere
	if command -v qlty >/dev/null 2>&1; then
		local qlty_version
		qlty_version=$(qlty --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Qlty CLI found in PATH: $qlty_version"
		return 0
	fi

	print_info "Qlty provides universal code quality analysis for 40+ languages"
	echo "  - Runs 70+ static analysis tools (ShellCheck, ESLint, etc.)"
	echo "  - Detects code smells and maintainability issues"
	echo "  - Used by the daily code quality sweep (pulse-wrapper.sh)"
	echo ""

	local install_qlty
	setup_prompt install_qlty "Install Qlty CLI? [Y/n]: " "Y"

	if [[ "$install_qlty" =~ ^[Yy]?$ ]]; then
		if command -v curl >/dev/null 2>&1; then
			if verified_install "Qlty CLI" "https://qlty.sh"; then
				# Verify installation
				if [[ -x "$qlty_bin" ]]; then
					local qlty_version
					qlty_version=$("$qlty_bin" --version 2>/dev/null | head -1 || echo "unknown")
					print_success "Qlty CLI installed: $qlty_version"
					print_info "Ensure ~/.qlty/bin is in your PATH"
					print_info "Documentation: ~/.aidevops/agents/tools/code-review/qlty.md"
				elif command -v qlty >/dev/null 2>&1; then
					print_success "Qlty CLI installed: $(qlty --version 2>/dev/null | head -1)"
				else
					print_warning "Qlty CLI install script ran but binary not found at $qlty_bin"
					print_info "Try restarting your shell or check ~/.qlty/bin/"
				fi
			else
				print_warning "Qlty CLI installation failed"
				print_info "Install manually: curl -fsSL https://qlty.sh | bash"
			fi
		else
			print_warning "curl not found — cannot install Qlty CLI"
			print_info "Install manually: curl -fsSL https://qlty.sh | bash"
		fi
	else
		print_info "Skipped Qlty CLI installation"
		print_info "Install later: curl -fsSL https://qlty.sh | bash"
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

setup_claudebar() {
	local claudebar_release_url="https://github.com/tddworks/ClaudeBar/releases/latest"
	# Only available on macOS (native Swift menu bar app)
	if [[ "$(uname)" != "Darwin" ]]; then
		return 0
	fi

	print_info "Setting up ClaudeBar (AI quota monitor)..."

	# Check if ClaudeBar is already installed
	if [[ -d "/Applications/ClaudeBar.app" ]]; then
		print_success "ClaudeBar already installed"
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
	echo "  Features: real-time quota tracking, status notifications, multiple themes"
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
check_python_upgrade_available() {
	print_info "Checking Python version..."

	# 1. Check currently installed Python
	local python3_bin
	if ! python3_bin=$(find_python3); then
		print_warning "Python 3 not found"
		echo ""
		echo "  Install options:"
		if [[ "$PLATFORM_MACOS" == "true" ]]; then
			echo "    brew install python3"
		elif command -v apt-get >/dev/null 2>&1; then
			echo "    sudo apt install python3"
		elif command -v dnf >/dev/null 2>&1; then
			echo "    sudo dnf install python3"
		else
			echo "    Install Python 3 via your system package manager"
		fi
		echo ""
		return 0
	fi

	local installed_version
	installed_version=$("$python3_bin" --version 2>&1 | cut -d' ' -f2)
	local installed_major installed_minor
	installed_major=$(echo "$installed_version" | cut -d. -f1)
	installed_minor=$(echo "$installed_version" | cut -d. -f2)

	# 2. Determine latest stable version from package manager
	local latest_version=""

	if [[ "$PLATFORM_MACOS" == "true" ]] && command -v brew >/dev/null 2>&1; then
		# Homebrew: `brew info python3` outputs "python@3.X: 3.X.Y" on the first line
		latest_version=$(brew info --json=v2 python3 2>/dev/null |
			python3 -c "import sys,json; d=json.load(sys.stdin); print(d['formulae'][0]['versions']['stable'])" 2>/dev/null) || latest_version=""
	elif command -v apt-cache >/dev/null 2>&1; then
		# Debian/Ubuntu: get candidate version from apt-cache
		latest_version=$(apt-cache policy python3 2>/dev/null |
			awk '/Candidate:/{print $2}' |
			grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || latest_version=""
	elif command -v dnf >/dev/null 2>&1; then
		# Fedora/RHEL: get available version from dnf
		latest_version=$(dnf info python3 2>/dev/null |
			awk '/^Version/{print $3}') || latest_version=""
	fi

	# 3. Compare versions and advise
	if [[ -z "$latest_version" ]]; then
		# Could not determine latest — just report installed version
		print_success "Python $installed_version found"
		return 0
	fi

	local latest_major latest_minor
	latest_major=$(echo "$latest_version" | cut -d. -f1)
	latest_minor=$(echo "$latest_version" | cut -d. -f2)

	# Compare major.minor (patch differences are not worth warning about)
	if [[ "$installed_major" -lt "$latest_major" ]] ||
		{ [[ "$installed_major" -eq "$latest_major" ]] && [[ "$installed_minor" -lt "$latest_minor" ]]; }; then
		print_warning "Python $installed_version installed, but $latest_version is available"
		echo ""
		echo "  Some tools and skills require Python 3.10+."
		echo "  Upgrade is recommended but not required."
		echo ""
		if [[ "$PLATFORM_MACOS" == "true" ]]; then
			echo "  Upgrade command:"
			echo "    brew upgrade python3"
		elif command -v apt-get >/dev/null 2>&1; then
			echo "  Upgrade command:"
			echo "    sudo apt update && sudo apt install python3"
		elif command -v dnf >/dev/null 2>&1; then
			echo "  Upgrade command:"
			echo "    sudo dnf upgrade python3"
		fi
		echo ""
	else
		print_success "Python $installed_version found (latest stable: $latest_version)"
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
		if "$python3_bin" -m venv python-env/dspy-env; then
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
	node_version=$(node --version 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1)
	if [[ -z "$node_version" ]] || ! [[ "$node_version" =~ ^[0-9]+$ ]]; then
		print_warning "Could not determine Node.js version - DSPyGround setup skipped"
		return
	fi
	if [[ "$node_version" -lt 18 ]]; then
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

# Install Node.js via apt, preferring NodeSource LTS over the distro package.
_install_nodejs_apt() {
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
		# shellcheck disable=SC2034  # Read by verified_install() in setup.sh
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
	return 0
}

# Ensure npm is present when Node.js is already installed (distro packages may omit it).
_ensure_npm_installed() {
	if command -v npm >/dev/null 2>&1; then
		return 0
	fi
	print_info "npm not found (distro nodejs package may omit it) — installing..."
	local pkg_manager
	pkg_manager=$(detect_package_manager)
	case "$pkg_manager" in
	apt) sudo apt-get install -y npm 2>/dev/null || print_warning "Failed to install npm via apt" ;;
	dnf | yum) sudo "$pkg_manager" install -y npm 2>/dev/null || print_warning "Failed to install npm via $pkg_manager" ;;
	brew) brew install npm 2>/dev/null || print_warning "Failed to install npm via brew" ;;
	*) print_warning "Cannot auto-install npm — install manually" ;;
	esac
	return 0
}

setup_nodejs() {
	# Check if Node.js is already installed
	if command -v node >/dev/null 2>&1; then
		local node_version
		node_version=$(node --version 2>/dev/null || echo "unknown")
		print_success "Node.js already installed: $node_version"
		_ensure_npm_installed
		return 0
	fi

	print_info "Node.js is required for OpenCode, MCP servers, and many tools"

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	local install_node
	case "$pkg_manager" in
	brew)
		setup_prompt install_node "Install Node.js via Homebrew? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if run_with_spinner "Installing Node.js" brew install node; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	apt)
		setup_prompt install_node "Install Node.js via apt? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			_install_nodejs_apt
		fi
		;;
	dnf | yum)
		setup_prompt install_node "Install Node.js via $pkg_manager? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo "$pkg_manager" install -y nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	pacman)
		setup_prompt install_node "Install Node.js via pacman? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo pacman -S --noconfirm nodejs npm; then
				print_success "Node.js installed: $(node --version)"
			else
				print_warning "Node.js installation failed"
			fi
		fi
		;;
	apk)
		setup_prompt install_node "Install Node.js via apk? [Y/n]: " "Y"
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

	local install_oc
	setup_prompt install_oc "Install OpenCode via $installer? [Y/n]: " "Y"
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

setup_codex_cli() {
	print_info "Setting up OpenAI Codex CLI..."

	# Check if Codex is already installed
	if command -v codex >/dev/null 2>&1; then
		local codex_version
		codex_version=$(codex --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Codex already installed: $codex_version"
		# Fix broken MCP_DOCKER if present
		_fix_codex_docker_mcp
		return 0
	fi

	# Need either bun or npm to install
	local installer=""
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
	echo ""

	local install_codex
	setup_prompt install_codex "Install Codex via $installer? [Y/n]: " "Y"
	if [[ "$install_codex" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Codex" npm_global_install "$install_pkg"; then
			print_success "Codex installed"
			echo ""
			print_info "Codex needs OpenAI authentication."
			print_info "Run 'codex' and follow the auth prompts."
			echo ""
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
	local config="$HOME/.codex/config.toml"
	[[ -f "$config" ]] || return 0

	# Check if MCP_DOCKER section exists
	if ! grep -q '^\[mcp_servers\.MCP_DOCKER\]' "$config" 2>/dev/null; then
		return 0
	fi

	# Check if `docker mcp` subcommand is actually available
	if docker mcp --help >/dev/null 2>&1; then
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
		if [[ "$in_mcp_docker" == "true" ]] && [[ "$line" == "["* ]]; then
			in_mcp_docker=false
		fi
		if [[ "$in_mcp_docker" == "true" ]]; then
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
		droid_version=$(droid --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Droid already installed: $droid_version"
		return 0
	fi

	# Droid uses its own installer — not available via npm/brew
	print_info "Droid (Factory.AI) is an AI coding agent CLI"
	echo "  It provides autonomous coding capabilities with Factory.AI models."
	echo ""

	local install_droid
	setup_prompt install_droid "Install Droid CLI? [Y/n]: " "Y"
	if [[ "$install_droid" =~ ^[Yy]?$ ]]; then
		print_info "Installing Droid CLI..."
		if command -v curl >/dev/null 2>&1; then
			if curl -fsSL https://app.factory.ai/install.sh | bash 2>/dev/null; then
				print_success "Droid installed"
				echo ""
				print_info "Run 'droid auth login' to authenticate with Factory.AI."
				echo ""
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
		gws_version=$(gws --version 2>/dev/null | head -1 || echo "unknown")
		print_success "Google Workspace CLI already installed: $gws_version"
		return 0
	fi

	# Need either bun or npm to install
	local installer=""
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
	echo ""

	local install_gws
	setup_prompt install_gws "Install Google Workspace CLI via $installer? [Y/n]: " "Y"
	if [[ "$install_gws" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing Google Workspace CLI" npm_global_install "$install_pkg"; then
			print_success "Google Workspace CLI installed"

			echo ""
			print_info "Authentication required before use."
			print_info "Run 'gws auth setup' to authenticate with your Google account."
			print_info "For headless use: set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"
			echo ""
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

	setup_prompt install_orb "Install OrbStack? [y/N]: " "n"
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
	if ! check_python_version "" "AI orchestration" >/dev/null; then
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
