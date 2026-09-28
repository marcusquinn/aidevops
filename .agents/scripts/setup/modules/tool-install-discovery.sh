#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Tool discovery, linting, and optional CLI installation functions.
# Part of aidevops setup.sh modularization (GH#32734)

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -Eeuo pipefail

# Include guard
[[ -n "${_TOOL_INSTALL_DISCOVERY_LOADED:-}" ]] && return 0
_TOOL_INSTALL_DISCOVERY_LOADED=1
TOOL_INSTALL_EMPTY=${TOOL_INSTALL_EMPTY-}
TOOL_INSTALL_BOOL_TRUE=${TOOL_INSTALL_BOOL_TRUE-true}
TOOL_INSTALL_UNKNOWN=${TOOL_INSTALL_UNKNOWN-unknown}

# SCRIPT_DIR fallback for direct sourcing and test harnesses.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_tool_install_module_path="${BASH_SOURCE[0]%/*}"
	[[ "$_tool_install_module_path" == "${BASH_SOURCE[0]}" ]] && _tool_install_module_path="."
	SCRIPT_DIR="$(cd "$_tool_install_module_path" && pwd)"
	unset _tool_install_module_path
fi

_print_gh_slurp_manual_upgrade() {
	echo "${TOOL_INSTALL_EMPTY}"
	echo "📋 GitHub CLI upgrade guidance:"
	echo "  Required: gh >= ${AIDEVOPS_GH_MIN_SLURP_VERSION:-2.51.0} for gh api --paginate --slurp"
	echo "  Linux: install or upgrade gh from the official GitHub CLI package source for your distribution; on Ubuntu/Debian avoid the older Ubuntu universe gh package"
	echo "  macOS: brew update && brew upgrade gh"
	echo "  Verify: gh --version && aidevops status"
	return 0
}
_offer_gh_slurp_upgrade() {
	local pkg_manager="$1"
	local os_name="${TOOL_INSTALL_EMPTY}"
	os_name=$(uname -s 2>/dev/null || printf 'unknown')

	if [[ "$os_name" != "Linux" ]]; then
		_print_gh_slurp_manual_upgrade
		return 1
	fi

	echo "${TOOL_INSTALL_EMPTY}"
	print_warning "Linux GitHub CLI is below the aidevops minimum. Old distro packages can break pulse dispatch."
	if [[ "$pkg_manager" == "${TOOL_INSTALL_UNKNOWN}" ]]; then
		print_warning "No supported package manager detected for an automatic gh upgrade attempt"
		_print_gh_slurp_manual_upgrade
		return 1
	fi
	setup_prompt upgrade_gh_cli "Try to upgrade GitHub CLI (gh) using ${pkg_manager}? [y/N]: " "N"
	# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
	if [[ "$upgrade_gh_cli" =~ ^[Yy]$ ]]; then
		print_info "Attempting to upgrade gh using ${pkg_manager}..."
		if install_packages "$pkg_manager" gh; then
			if declare -F aidevops_gh_slurp_supported >/dev/null 2>&1 && aidevops_gh_slurp_supported; then
				print_success "GitHub CLI now satisfies the aidevops prerequisite"
				return 0
			else
				print_warning "gh still does not satisfy the aidevops prerequisite after package-manager upgrade"
				_print_gh_slurp_manual_upgrade
			fi
		else
			print_warning "Package-manager gh upgrade failed or was unavailable"
			_print_gh_slurp_manual_upgrade
		fi
	else
		print_info "Skipped GitHub CLI upgrade"
		_print_gh_slurp_manual_upgrade
	fi
	return 1
}

setup_git_clis() {
	print_info "Setting up Git CLI tools..."

	local cli_tools=()
	local missing_packages=()
	local missing_names=()
	local gh_needs_slurp_upgrade="false"

	# Check for GitHub CLI
	if ! command -v gh >/dev/null 2>&1; then
		missing_packages+=("gh")
		missing_names+=("GitHub CLI")
	elif declare -F aidevops_gh_slurp_supported >/dev/null 2>&1 && ! aidevops_gh_slurp_supported; then
		local gh_slurp_message
		gh_slurp_message=$(aidevops_gh_slurp_status_message)
		print_warning "$gh_slurp_message"
		gh_needs_slurp_upgrade="${TOOL_INSTALL_BOOL_TRUE}"
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

	local pkg_manager
	pkg_manager=$(detect_package_manager)

	if [[ "$gh_needs_slurp_upgrade" == "${TOOL_INSTALL_BOOL_TRUE}" ]]; then
		if _offer_gh_slurp_upgrade "$pkg_manager"; then
			gh_needs_slurp_upgrade="false"
		fi
	fi

	# Offer to install missing tools
	if [[ ${#missing_packages[@]} -gt 0 ]]; then
		print_warning "Missing Git CLI tools: ${missing_names[*]}"
		echo "  These provide enhanced Git platform integration (repos, PRs, issues)"

		if [[ "$pkg_manager" != "${TOOL_INSTALL_UNKNOWN}" ]]; then
			echo "${TOOL_INSTALL_EMPTY}"
			setup_prompt install_git_clis "Install Git CLI tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " "Y"

			# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
			if [[ "$install_git_clis" =~ ^[Yy]?$ ]]; then
				print_info "Installing ${missing_packages[*]}..."
				if install_packages "$pkg_manager" "${missing_packages[@]}"; then
					print_success "Git CLI tools installed"
					echo "${TOOL_INSTALL_EMPTY}"
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
				echo "${TOOL_INSTALL_EMPTY}"
				echo "📋 Manual installation:"
				echo "  macOS: brew install ${missing_packages[*]}"
				echo "  Ubuntu: sudo apt install ${missing_packages[*]} (Note: for gh >= 2.51.0, use the GitHub CLI apt repository)"
				echo "  Fedora: sudo dnf install ${missing_packages[*]}"
			fi
		else
			echo "${TOOL_INSTALL_EMPTY}"
			echo "📋 Manual installation:"
			echo "  macOS: brew install ${missing_packages[*]}"
			echo "  Ubuntu: sudo apt install ${missing_packages[*]} (Note: for gh >= 2.51.0, use the GitHub CLI apt repository)"
			echo "  Fedora: sudo dnf install ${missing_packages[*]}"
		fi
	elif [[ "$gh_needs_slurp_upgrade" != "${TOOL_INSTALL_BOOL_TRUE}" ]]; then
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
	echo "${TOOL_INSTALL_EMPTY}"
	echo "  Manual installation:"
	echo "    macOS:        brew install fd ripgrep ripgrep-all"
	echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep  # rga: cargo install ripgrep_all"
	echo "    Fedora:       sudo dnf install fd-find ripgrep   # rga: cargo install ripgrep_all"
	echo "    Arch:         sudo pacman -S fd ripgrep ripgrep-all"
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
		# Debian/Ubuntu installs fdfind; expose the fd command to non-interactive agents.
		if [[ "$pkg_manager" == "apt" ]] && command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
			if aidevops_ensure_fd_command; then
				print_success "Installed fd compatibility command in ~/.local/bin"
			else
				print_warning "fdfind is installed but the required fd command could not be exposed"
			fi
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
		fd_version=$(fd --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		print_success "fd found: $fd_version"
	elif command -v fdfind >/dev/null 2>&1; then
		fd_version=$(fdfind --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		if aidevops_ensure_fd_command; then
			print_success "fd compatibility command installed for fdfind: $fd_version"
		else
			missing_tools+=("fd")
			missing_packages+=("fd")
			missing_names+=("fd command (fdfind exists but is not exposed as fd)")
		fi
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
		rg_version=$(rg --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		print_success "ripgrep found: $rg_version"
	fi

	# Check for ripgrep-all (searches inside PDFs, DOCX, SQLite, archives)
	if ! command -v rga >/dev/null 2>&1; then
		missing_tools+=("rga")
		missing_packages+=("ripgrep-all")
		missing_names+=("ripgrep-all (search inside PDFs/docs/archives)")
	else
		local rga_version
		rga_version=$(rga --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		print_success "ripgrep-all found: $rga_version"
	fi

	# Offer to install missing tools
	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		print_warning "Missing file discovery tools: ${missing_names[*]}"
		echo "${TOOL_INSTALL_EMPTY}"
		echo "  These tools provide 10x faster file discovery than built-in glob:"
		echo "    fd          - Fast alternative to 'find', respects .gitignore"
		echo "    ripgrep     - Fast alternative to 'grep', respects .gitignore"
		echo "    ripgrep-all - Extends ripgrep to search inside PDFs, DOCX, SQLite, archives"
		echo "${TOOL_INSTALL_EMPTY}"
		echo "  AI agents use these for efficient codebase navigation."
		echo "${TOOL_INSTALL_EMPTY}"

		local pkg_manager
		pkg_manager=$(detect_package_manager)

		if [[ "$pkg_manager" != "${TOOL_INSTALL_UNKNOWN}" ]]; then
			setup_prompt install_fd_tools "Install file discovery tools (${missing_packages[*]}) using $pkg_manager? [Y/n]: " "Y"

			# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
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

setup_shell_linting_tools() {
	print_info "Setting up shell linting tools..."

	local missing_tools=()
	local pkg_manager
	pkg_manager=$(detect_package_manager)

	# Check shellcheck
	if command -v shellcheck >/dev/null 2>&1; then
		local sc_version sc_rosetta=false
		sc_version=$(shellcheck --version 2>/dev/null | grep 'version:' | awk '{print $2}' || echo "${TOOL_INSTALL_UNKNOWN}")
		# Rosetta detection (macOS Apple Silicon only, requires `file` command)
		if [[ "$PLATFORM_MACOS" == "${TOOL_INSTALL_BOOL_TRUE}" ]] && [[ "$PLATFORM_ARM64" == "${TOOL_INSTALL_BOOL_TRUE}" ]] && command -v file >/dev/null 2>&1; then
			local sc_file_output
			sc_file_output=$(file "$(command -v shellcheck)" 2>/dev/null || echo "${TOOL_INSTALL_EMPTY}")
			if [[ "$sc_file_output" == *"x86_64"* ]] && [[ "$sc_file_output" != *"$TOOL_INSTALL_ARCH_ARM64"* ]]; then
				sc_rosetta=true
			fi
		fi
		if [[ "$sc_rosetta" == "${TOOL_INSTALL_BOOL_TRUE}" ]]; then
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

		if [[ "$pkg_manager" != "${TOOL_INSTALL_UNKNOWN}" ]]; then
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

setup_setsid_advisory() {
	# setsid is required to detach pulse workers into their own process group
	# (t2757, GH#20561, GH#21102). Without it, workers inherit pulse's PGID and
	# are killed by any PG-scoped signal (launchd unload, restart chain).
	#
	# Linux: setsid ships with util-linux (present on all mainstream distros).
	# macOS: available from macOS 12+ at /usr/bin/setsid. Older macOS or systems
	#        where /usr/bin/setsid is absent need util-linux via Homebrew.
	#        util-linux is keg-only on Homebrew — binary is not linked into PATH
	#        automatically, so we create a symlink after install.
	if command -v setsid >/dev/null 2>&1; then
		local setsid_path
		setsid_path="$(command -v setsid)"
		print_success "setsid found at $setsid_path (worker process-group isolation enabled)"
		return 0
	fi

	# setsid missing — on macOS with Homebrew, auto-install util-linux and
	# symlink setsid into PATH (GH#21102 / t2926). On Linux and macOS without
	# Homebrew, emit an actionable error with install instructions.
	if [[ "$(uname)" == "Darwin" ]]; then
		if command -v brew >/dev/null 2>&1; then
			print_info "setsid not found — installing util-linux for worker PGID isolation (GH#21102)"
			if brew install util-linux 2>&1 | tail -3; then
				# util-linux is keg-only: binary lives under the keg, not in /opt/homebrew/bin.
				# Symlink setsid into a standard PATH directory so 'command -v setsid' works.
				local brew_prefix
				brew_prefix="$(brew --prefix 2>/dev/null || echo "${TOOL_INSTALL_EMPTY}")"
				local keg_setsid="${brew_prefix}/opt/util-linux/bin/setsid"
				local link_target="${brew_prefix}/bin/setsid"
				if [[ -x "$keg_setsid" && ! -e "$link_target" ]]; then
					ln -s "$keg_setsid" "$link_target" &&
						print_success "Symlinked setsid: $keg_setsid → $link_target"
				fi
				# Verify setsid is now reachable
				if command -v setsid >/dev/null 2>&1; then
					print_success "setsid installed at $(command -v setsid) (worker PGID isolation enabled)"
				else
					print_error "util-linux installed but setsid still not in PATH — check brew --prefix"
				fi
			else
				print_error "brew install util-linux failed — workers will share pulse PGID until resolved"
				echo "  Manual fix: brew install util-linux"
			fi
		else
			print_error "setsid not found — worker isolation broken; install util-linux"
			echo "  Impact: every pulse restart sends SIGHUP to workers in its PGID,"
			echo "          killing in-flight workers before they can finish (GH#21102)"
			echo "  Fix:    install Homebrew, then run: brew install util-linux"
			echo "  Or upgrade to macOS 12+ where /usr/bin/setsid ships by default"
		fi
	else
		# Linux: setsid should be present on all mainstream distros via util-linux.
		# If it is missing, emit an error rather than a warning — workers will be
		# killed on every pulse cycle restart without it.
		print_error "setsid not found — worker isolation broken; install util-linux"
		echo "  Impact: every pulse restart sends SIGHUP to workers in its PGID,"
		echo "          killing in-flight workers before they can finish (GH#21102)"
		echo "  Fix:    sudo apt install util-linux     # Debian/Ubuntu"
		echo "          sudo dnf install util-linux     # Fedora/RHEL"
		echo "          sudo pacman -S util-linux       # Arch"
		echo "          sudo apk add util-linux         # Alpine"
	fi
	echo "${TOOL_INSTALL_EMPTY}"

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
		qlty_version=$("$qlty_bin" --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		print_success "Qlty CLI already installed: $qlty_version"
		return 0
	fi

	# Also check PATH in case it's installed elsewhere
	if command -v qlty >/dev/null 2>&1; then
		local qlty_version
		qlty_version=$(qlty --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
		print_success "Qlty CLI found in PATH: $qlty_version"
		return 0
	fi

	print_info "Qlty provides universal code quality analysis for 40+ languages"
	echo "  - Runs 70+ static analysis tools (ShellCheck, ESLint, etc.)"
	echo "  - Detects code smells and maintainability issues"
	echo "  - Used by the daily code quality sweep (pulse-wrapper.sh)"
	echo "${TOOL_INSTALL_EMPTY}"

	local install_qlty
	setup_prompt install_qlty "Install Qlty CLI? [Y/n]: " "Y"

	if [[ "$install_qlty" =~ ^[Yy]?$ ]]; then
		if command -v curl >/dev/null 2>&1; then
			if verified_install "Qlty CLI" "https://qlty.sh"; then
				# Verify installation
				if [[ -x "$qlty_bin" ]]; then
					local qlty_version
					qlty_version=$("$qlty_bin" --version 2>/dev/null | head -1 || echo "${TOOL_INSTALL_UNKNOWN}")
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
