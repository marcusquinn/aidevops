#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Python and Node.js environment installation functions.
# Part of aidevops setup.sh modularization (GH#32734)

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -Eeuo pipefail

# Include guard
[[ -n "${_TOOL_INSTALL_ENVIRONMENTS_LOADED:-}" ]] && return 0
_TOOL_INSTALL_ENVIRONMENTS_LOADED=1
TOOL_INSTALL_EMPTY=${TOOL_INSTALL_EMPTY-}
TOOL_INSTALL_BOOL_TRUE=${TOOL_INSTALL_BOOL_TRUE-true}
TOOL_INSTALL_NODE_LABEL=${TOOL_INSTALL_NODE_LABEL-Node.js}
TOOL_INSTALL_UPGRADE_COMMAND=${TOOL_INSTALL_UPGRADE_COMMAND-"  Upgrade command:"}

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
		echo "${TOOL_INSTALL_EMPTY}"
		echo "  Install options:"
		if [[ "$PLATFORM_MACOS" == "${TOOL_INSTALL_BOOL_TRUE}" ]]; then
			echo "    brew install python3"
		elif command -v apt-get >/dev/null 2>&1; then
			echo "    sudo apt install python3"
		elif command -v dnf >/dev/null 2>&1; then
			echo "    sudo dnf install python3"
		else
			echo "    Install Python 3 via your system package manager"
		fi
		echo "${TOOL_INSTALL_EMPTY}"
		return 0
	fi

	local installed_version
	installed_version=$("$python3_bin" --version 2>&1 | cut -d' ' -f2)
	local installed_major installed_minor
	installed_major=$(echo "$installed_version" | cut -d. -f1)
	installed_minor=$(echo "$installed_version" | cut -d. -f2)

	# 2. Determine latest stable version from package manager
	local latest_version="${TOOL_INSTALL_EMPTY}"

	if [[ "$PLATFORM_MACOS" == "${TOOL_INSTALL_BOOL_TRUE}" ]] && command -v brew >/dev/null 2>&1; then
		# Homebrew: `brew info python3` outputs "python@3.X: 3.X.Y" on the first line
		latest_version=$(brew info --json=v2 python3 2>/dev/null |
			python3 -c "import sys,json; d=json.load(sys.stdin); print(d['formulae'][0]['versions']['stable'])" 2>/dev/null) || latest_version="${TOOL_INSTALL_EMPTY}"
	elif command -v apt-cache >/dev/null 2>&1; then
		# Debian/Ubuntu: get candidate version from apt-cache
		latest_version=$(apt-cache policy python3 2>/dev/null |
			awk '/Candidate:/{print $2}' |
			grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || latest_version="${TOOL_INSTALL_EMPTY}"
	elif command -v dnf >/dev/null 2>&1; then
		# Fedora/RHEL: get available version from dnf
		latest_version=$(dnf info python3 2>/dev/null |
			awk '/^Version/{print $3}') || latest_version="${TOOL_INSTALL_EMPTY}"
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
		echo "${TOOL_INSTALL_EMPTY}"
		echo "  Some tools and skills require Python 3.10+."
		echo "  Upgrade is recommended but not required."
		echo "${TOOL_INSTALL_EMPTY}"
		if [[ "$PLATFORM_MACOS" == "${TOOL_INSTALL_BOOL_TRUE}" ]]; then
			echo "${TOOL_INSTALL_UPGRADE_COMMAND}"
			echo "    brew upgrade python3"
		elif command -v apt-get >/dev/null 2>&1; then
			echo "${TOOL_INSTALL_UPGRADE_COMMAND}"
			echo "    sudo apt update && sudo apt install python3"
		elif command -v dnf >/dev/null 2>&1; then
			echo "${TOOL_INSTALL_UPGRADE_COMMAND}"
			echo "    sudo dnf upgrade python3"
		fi
		echo "${TOOL_INSTALL_EMPTY}"
	else
		print_success "Python $installed_version found (latest stable: $latest_version)"
	fi

	return 0
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
		VERIFIED_INSTALL_SUDO="${TOOL_INSTALL_BOOL_TRUE}"
		if verified_install "NodeSource repository" "https://deb.nodesource.com/setup_22.x"; then
			# Install nodejs (NodeSource bundles npm, but distro fallback may not)
			# Include npm explicitly in case NodeSource setup failed silently
			# and apt falls back to the distro nodejs package (which lacks npm)
			if sudo apt-get install -y nodejs npm 2>/dev/null || sudo apt-get install -y nodejs; then
				print_success "${TOOL_INSTALL_NODE_LABEL} installed: $(node --version)"
			else
				print_warning "${TOOL_INSTALL_NODE_LABEL} installation failed"
			fi
		else
			# Fallback to distro package
			print_info "Falling back to distro Node.js package..."
			if sudo apt-get install -y nodejs npm; then
				print_success "${TOOL_INSTALL_NODE_LABEL} installed: $(node --version)"
			else
				print_warning "${TOOL_INSTALL_NODE_LABEL} installation failed"
			fi
		fi
	else
		if sudo apt-get install -y nodejs npm; then
			print_success "${TOOL_INSTALL_NODE_LABEL} installed: $(node --version)"
		else
			print_warning "${TOOL_INSTALL_NODE_LABEL} installation failed"
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
				print_success "${TOOL_INSTALL_NODE_LABEL} installed: $(node --version)"
			else
				print_warning "${TOOL_INSTALL_NODE_LABEL} installation failed"
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
				print_success "${TOOL_INSTALL_NODE_LABEL} installed: $(node --version)"
			else
				print_warning "${TOOL_INSTALL_NODE_LABEL} installation failed"
			fi
		fi
		;;
	pacman)
		setup_prompt install_node "Install Node.js via pacman? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo pacman -S --noconfirm nodejs npm; then
				print_success "${TOOL_INSTALL_NODE_LABEL} installed: $(node --version)"
			else
				print_warning "${TOOL_INSTALL_NODE_LABEL} installation failed"
			fi
		fi
		;;
	apk)
		setup_prompt install_node "Install Node.js via apk? [Y/n]: " "Y"
		if [[ "$install_node" =~ ^[Yy]?$ ]]; then
			if sudo apk add nodejs npm; then
				print_success "${TOOL_INSTALL_NODE_LABEL} installed: $(node --version)"
			else
				print_warning "${TOOL_INSTALL_NODE_LABEL} installation failed"
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
