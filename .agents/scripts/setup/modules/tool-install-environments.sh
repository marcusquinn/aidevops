#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Python and Node.js environment installation functions.
# Part of aidevops setup.sh modularization (GH#32734)

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -Eeuo pipefail

# Include guard
[[ -n "${_TOOL_INSTALL_ENVIRONMENTS_LOADED:-}" ]] && return 0
_TOOL_INSTALL_ENVIRONMENTS_LOADED=1

# SCRIPT_DIR fallback for direct sourcing and test harnesses.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_tool_install_module_path="${BASH_SOURCE[0]%/*}"
	[[ "$_tool_install_module_path" == "${BASH_SOURCE[0]}" ]] && _tool_install_module_path="."
	SCRIPT_DIR="$(cd "$_tool_install_module_path" && pwd)"
	unset _tool_install_module_path
fi

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

_vault_runtime_path_safe() {
	local env_dir="$1"
	local expected_dir="${HOME}/.aidevops/.agent-workspace/python-env/vault"
	[[ "$env_dir" == "$expected_dir" ]] || return 1
	local component=""
	for component in \
		"${HOME}/.aidevops" \
		"${HOME}/.aidevops/.agent-workspace" \
		"${HOME}/.aidevops/.agent-workspace/python-env" \
		"$env_dir"; do
		[[ -L "$component" ]] && return 1
	done
	return 0
}

_vault_runtime_marker_valid() {
	local marker_path="$1"
	[[ -f "$marker_path" && ! -L "$marker_path" && -O "$marker_path" ]] || return 1
	local marker_value=""
	marker_value=$(<"$marker_path")
	[[ "$marker_value" == "aidevops-vault-runtime-v1" || "$marker_value" == "managed by aidevops setup" ]]
	return $?
}

setup_vault_python_env() {
	print_info "Setting up isolated Python crypto runtime for Vault..."
	local python3_bin=""
	if ! python3_bin=$(find_python3); then
		print_warning "Python 3 not found - Vault crypto runtime unavailable"
		return 1
	fi
	local module_dir=""
	module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
	local source_root="${INSTALL_DIR:-}"
	[[ -z "$source_root" ]] && source_root="$(cd "${module_dir}/../../../.." && pwd)"
	local requirements_file="${source_root}/.agents/configs/vault-requirements.txt"
	local runtime_check="${source_root}/.agents/scripts/vault-runtime-check.py"
	local env_dir="${HOME}/.aidevops/.agent-workspace/python-env/vault"
	local env_python="${env_dir}/bin/python3"
	local managed_marker="${env_dir}/.aidevops-managed-runtime"
	local marker_value="aidevops-vault-runtime-v1"

	if ! _vault_runtime_path_safe "$env_dir"; then
		print_warning "Refusing unsafe Vault runtime path: $env_dir"
		return 1
	fi
	if [[ ! -f "$requirements_file" || ! -f "$runtime_check" ]]; then
		print_warning "Vault runtime requirements or readiness check is missing"
		return 1
	fi
	if [[ -e "$env_dir" ]]; then
		if ! _vault_runtime_marker_valid "$managed_marker" || ! "$python3_bin" "$runtime_check" --check-ancestors "$HOME" "$env_dir"; then
			print_warning "Refusing to execute or replace an unowned Vault runtime: $env_dir"
			return 1
		fi
		if "$python3_bin" "$runtime_check" --check-path "$env_dir" "$managed_marker" && [[ -x "$env_python" ]] && "$env_python" "$runtime_check" 2>/dev/null; then
			printf '%s\n' "$marker_value" >"$managed_marker"
			chmod 600 "$managed_marker"
			print_success "Vault crypto runtime is ready"
			return 0
		fi
	fi
	if ! (umask 077 && mkdir -p "${env_dir%/*}"); then
		print_warning "Failed to create the protected Vault runtime parent"
		return 1
	fi
	if ! _vault_runtime_path_safe "$env_dir"; then
		print_warning "Refusing unsafe Vault runtime path after parent creation: $env_dir"
		return 1
	fi
	if ! "$python3_bin" "$runtime_check" --check-ancestors "$HOME" "$env_dir"; then
		print_warning "Refusing writable or unowned Vault runtime ancestors"
		return 1
	fi
	if [[ -d "$env_dir" ]]; then
		rm -rf "$env_dir"
	fi
	if ! (umask 077 && "$python3_bin" -m venv --copies "$env_dir"); then
		print_warning "Failed to create isolated Vault Python environment"
		rm -rf "$env_dir"
		return 1
	fi
	chmod 755 "$env_dir"
	if ! "$python3_bin" "$runtime_check" --check-path "$env_dir"; then
		print_warning "Fresh Vault runtime ownership verification failed"
		rm -rf "$env_dir"
		return 1
	fi
	if ! (umask 077 && "$env_python" -m pip install --disable-pip-version-check --no-input --only-binary=:all: -r "$requirements_file"); then
		print_warning "Failed to install the pinned Vault crypto runtime"
		rm -rf "$env_dir"
		return 1
	fi
	if ! "$python3_bin" "$runtime_check" --check-path "$env_dir"; then
		print_warning "Vault crypto runtime ownership verification failed"
		rm -rf "$env_dir"
		return 1
	fi
	if ! "$env_python" "$runtime_check"; then
		print_warning "Vault crypto runtime verification failed"
		rm -rf "$env_dir"
		return 1
	fi
	if ! (umask 077 && printf '%s\n' "$marker_value" >"$managed_marker"); then
		print_warning "Failed to publish the verified Vault runtime marker"
		rm -rf "$env_dir"
		return 1
	fi
	chmod 600 "$managed_marker"
	if ! "$python3_bin" "$runtime_check" --check-path "$env_dir" "$managed_marker"; then
		print_warning "Published Vault runtime verification failed"
		rm -rf "$env_dir"
		return 1
	fi
	print_success "Vault crypto runtime is ready"
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

	if ! declare -F aidevops_secure_dspy_cache >/dev/null 2>&1; then
		print_warning "DSPy cache security helper unavailable - DSPy setup skipped"
		return 0
	fi
	if ! aidevops_secure_dspy_cache; then
		print_warning "DSPy cache could not be restricted to an owner-only directory - DSPy setup skipped"
		return 0
	fi
	if ! aidevops_persist_dspy_cache_env "python-env/dspy-env/bin/activate"; then
		print_warning "DSPy cache environment could not be persisted - DSPy setup skipped"
		return 0
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
	return 0
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
		if [[ "$arch" == "aarch64" || "$arch" == "$TOOL_INSTALL_ARCH_ARM64" ]]; then
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

# Bound OpenCode setup probes/installers so non-interactive setup cannot hang
# indefinitely when an opencode shim or package manager blocks.
