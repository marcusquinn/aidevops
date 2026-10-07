#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Tool installation orchestrator. Focused function groups are sourced below:
# discovery/linting, developer tooling, and language environments.
# Part of aidevops setup.sh modularization (t316.3, GH#32734)

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# Include guard
[[ -n "${_TOOL_INSTALL_LOADED:-}" ]] && return 0
_TOOL_INSTALL_LOADED=1

_tool_install_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
_file_discovery_readiness_lib="${_tool_install_dir}/../../file-discovery-readiness.sh"
_rtk_readiness_lib="${_tool_install_dir}/../../rtk-readiness.sh"
if [[ -f "$_file_discovery_readiness_lib" ]]; then
	# shellcheck source=../../file-discovery-readiness.sh
	source "$_file_discovery_readiness_lib"
fi
if [[ -f "$_rtk_readiness_lib" ]]; then
	# shellcheck source=../../rtk-readiness.sh
	source "$_rtk_readiness_lib"
fi
unset _file_discovery_readiness_lib _rtk_readiness_lib
TOOL_INSTALL_ARCH_ARM64="${TOOL_INSTALL_ARCH_ARM64:-arm64}"

# shellcheck source=./tool-install-discovery.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_tool_install_dir}/tool-install-discovery.sh"
# shellcheck source=./tool-install-developer.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_tool_install_dir}/tool-install-developer.sh"
# shellcheck source=./tool-install-environments.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_tool_install_dir}/tool-install-environments.sh"

# Keep Vault ownership verification in this file: security readiness checks
# inspect the exact creation-to-marker sequence here (GH#32734).
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

_setup_rtk_installed_version() {
	if declare -F aidevops_rtk_installed_version >/dev/null 2>&1; then
		aidevops_rtk_installed_version
	else
		printf 'unknown\n'
	fi
	return 0
}

_setup_rtk_install_supported_version() {
	local rtk_installer_url="$1"
	local rtk_supported_version="$2"
	VERIFIED_INSTALL_SHELL="sh"

	if command -v brew >/dev/null 2>&1; then
		if run_with_spinner "Upgrading rtk via Homebrew" brew upgrade rtk; then
			print_success "rtk upgraded via Homebrew"
			return 0
		fi
		print_warning "Homebrew upgrade failed, trying pinned installer..."
	fi

	if verified_install "rtk" "$rtk_installer_url"; then
		print_success "rtk installed to ~/.local/bin/rtk (v${rtk_supported_version})"
		return 0
	fi

	print_warning "rtk upgrade failed (non-critical, optional tool)"
	_setup_rtk_print_manual_install "$rtk_installer_url" "upgrade"
	return 1
}

_setup_rtk_print_manual_install() {
	local rtk_installer_url="$1"
	local brew_cmd="${2:-upgrade}"
	echo "  Manual install: brew $brew_cmd rtk  OR  curl -fsSL $rtk_installer_url | sh"
	return 0
}

_setup_rtk_offer_supported_upgrade() {
	local rtk_version="$1"
	local rtk_supported_version="$2"
	local rtk_installer_url="$3"

	print_warning "rtk v${rtk_version} is older than the aidevops-tested baseline v${rtk_supported_version}"
	setup_prompt upgrade_rtk "Upgrade rtk to the aidevops-tested v${rtk_supported_version}? [Y/n]: " "Y"
	# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
	if [[ "$upgrade_rtk" =~ ^[Yy]?$ ]]; then
		_setup_rtk_install_supported_version "$rtk_installer_url" "$rtk_supported_version"
		return $?
	fi

	print_info "Skipped rtk upgrade"
	_setup_rtk_print_manual_install "$rtk_installer_url"
	return 1
}

_setup_rtk_report_upgrade_result() {
	local rtk_state="$1"
	local rtk_version="$2"
	local rtk_supported_version="$3"
	local rtk_installer_url="$4"
	case "$rtk_state" in
	tested) print_success "rtk now matches the aidevops-tested version" ;;
	newer-untested) print_warning "rtk now reports v${rtk_version}, newer than the aidevops-tested baseline v${rtk_supported_version}; compatibility is not yet verified" ;;
	*)
		print_warning "rtk still reports v${rtk_version}; aidevops tested baseline is v${rtk_supported_version}"
		_setup_rtk_print_manual_install "$rtk_installer_url"
		;;
	esac
	return 0
}

setup_rtk() {
	# rtk — CLI proxy that reduces LLM token consumption by 60-90% (t1430)
	# Opinionated default optimization: compresses git/gh/test outputs before they reach LLM context
	# Single Rust binary, zero dependencies, <10ms overhead
	# https://github.com/rtk-ai/rtk

	# Pin to a tagged release for stability and auditability (Gemini review feedback).
	# Update the tag when upstream-watch detects a new release.
	local rtk_supported_version=""
	if ! declare -F aidevops_rtk_tested_version >/dev/null 2>&1 ||
		! declare -F aidevops_rtk_installed_version >/dev/null 2>&1 ||
		! declare -F aidevops_rtk_version_state >/dev/null 2>&1; then
		print_warning "rtk readiness helper unavailable; leaving the optional tool unchanged"
		return 0
	fi
	rtk_supported_version=$(aidevops_rtk_tested_version)
	local rtk_installer_url="https://raw.githubusercontent.com/rtk-ai/rtk/v${rtk_supported_version}/install.sh"

	if command -v rtk >/dev/null 2>&1; then
		local rtk_version rtk_state="unknown"
		rtk_version=$(_setup_rtk_installed_version)
		rtk_state=$(aidevops_rtk_version_state "$rtk_version" "$rtk_supported_version")
		print_success "rtk found: v$rtk_version (token optimization proxy)"
		if [[ "$rtk_state" == "older" ]]; then
			if _setup_rtk_offer_supported_upgrade "$rtk_version" "$rtk_supported_version" "$rtk_installer_url"; then
				rtk_version=$(_setup_rtk_installed_version)
				rtk_state=$(aidevops_rtk_version_state "$rtk_version" "$rtk_supported_version")
				_setup_rtk_report_upgrade_result "$rtk_state" "$rtk_version" "$rtk_supported_version" "$rtk_installer_url"
			fi
		elif [[ "$rtk_state" == "newer-untested" ]]; then
			print_warning "rtk v${rtk_version} is newer than the aidevops-tested baseline v${rtk_supported_version}; leaving the installed version unchanged"
		elif [[ "$rtk_state" == "unknown" ]]; then
			print_warning "rtk is available but its version could not be determined; leaving the optional tool unchanged"
		else
			print_success "rtk matches the aidevops-tested baseline"
		fi
		# Fall through to ensure config is applied (telemetry, tee)
	else
		print_info "rtk (Rust Token Killer) reduces LLM token usage by 60-90% on CLI commands"
		echo "  Compresses git, gh, test runner, and linter outputs before they reach the AI context."
		echo "  Single binary, zero dependencies, <10ms overhead. Installed by default; answer 'n' to skip."
		echo ""

		setup_prompt install_rtk "Install rtk for token-optimized CLI output? [Y/n]: " "y"

		# shellcheck disable=SC2154  # set indirectly by setup_prompt via read
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
			print_info "Skipped rtk installation"
			_setup_rtk_print_manual_install "$rtk_installer_url" "install"
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

_setup_serve_sim_node_version_ok() {
	local node_version="$1"
	local version="${node_version#v}"
	local major="${version%%.*}"

	if [[ "$major" =~ ^[0-9]+$ ]] && ((10#$major >= 20)); then
		return 0
	fi
	return 1
}

_setup_serve_sim_cli_version() {
	if serve-sim --version >/dev/null 2>&1; then
		serve-sim --version 2>/dev/null
	else
		printf '%s\n' 'installed'
	fi
	return 0
}

_setup_serve_sim_swiftpm_ok() {
	if ! command -v xcrun >/dev/null 2>&1; then
		return 1
	fi

	if ! xcrun simctl list devices >/dev/null 2>&1; then
		return 1
	fi

	if ! xcrun swift build --version >/dev/null 2>&1; then
		return 1
	fi

	return 0
}

setup_serve_sim() {
	# serve-sim currently ships an arm64 native Apple Simulator addon.
	if [[ "$(uname -s)" != "Darwin" ]]; then
		return 0
	fi

	if [[ "$(uname -m)" != "$TOOL_INSTALL_ARCH_ARM64" ]]; then
		print_info "serve-sim requires Apple Silicon (arm64); skipping on this Mac"
		return 0
	fi

	print_info "Setting up serve-sim (Apple Simulator browser preview)..."

	if command -v serve-sim >/dev/null 2>&1; then
		local serve_sim_version
		serve_sim_version=$(_setup_serve_sim_cli_version)
		print_success "serve-sim already installed: ${serve_sim_version}"
		print_info "Documentation: ~/.aidevops/agents/tools/mobile/serve-sim.md"
		return 0
	fi

	if ! _setup_serve_sim_swiftpm_ok; then
		print_info "serve-sim requires Xcode command-line tools, SwiftPM swiftbuild support, and simulator support"
		print_info "Install Xcode/Command Line Tools, then re-run setup"
		return 0
	fi

	if ! command -v node >/dev/null 2>&1; then
		print_info "serve-sim requires Node.js 20+"
		print_info "Install Node.js, then re-run setup"
		return 0
	fi

	local node_version
	node_version=$(node --version 2>/dev/null || printf '%s\n' 'unknown')
	if ! _setup_serve_sim_node_version_ok "$node_version"; then
		print_warning "serve-sim requires Node.js 20+, found ${node_version}"
		print_info "Upgrade Node.js, then re-run setup"
		return 0
	fi

	if ! command -v npm >/dev/null 2>&1; then
		print_info "serve-sim installs via npm; install Node.js/npm first"
		return 0
	fi

	print_info "serve-sim streams booted Apple Simulators to a browser for agent/user review"
	printf '%s\n' "  Features:"
	printf '%s\n' "    - Browser preview at http://localhost:3200"
	printf '%s\n' "    - In-process native capture/HID with H.264/MJPEG stream control"
	printf '%s\n' "    - SwiftPM swiftbuild-backed native addon on current Xcode toolchains"
	printf '%s\n' "    - Gestures, hardware buttons, typing, rotation, memory warnings"
	printf '%s\n' "    - Camera feed injection for simulator apps"
	printf '%s\n' ""

	local install_serve_sim
	setup_prompt install_serve_sim "Install serve-sim globally? [Y/n]: " "Y" || install_serve_sim="N"

	if [[ "${install_serve_sim:-}" =~ ^[Yy]?$ ]]; then
		if run_with_spinner "Installing serve-sim" npm_global_install "serve-sim@latest"; then
			print_success "serve-sim installed"
			print_info "Start a booted simulator preview: serve-sim"
			print_info "Documentation: ~/.aidevops/agents/tools/mobile/serve-sim.md"
		else
			print_warning "Failed to install serve-sim"
			printf '%s\n' "  Try manually: npm install -g serve-sim"
		fi
	else
		print_info "Skipped serve-sim installation"
		print_info "Install later: npm install -g serve-sim"
	fi

	return 0
}

setup_android_platform_tools() {
	if command -v adb >/dev/null 2>&1; then
		print_success "Android Platform Tools (adb) already installed; device availability is not yet verified"
		print_info "Before connecting Mobile MCP, check adb devices for an authorized emulator or test device"
		print_info "A local emulator needs more SDK packages in one SDK root; see tools/mobile/mobile-mcp.md"
		return 0
	fi

	if [[ "$(uname -s)" != "Darwin" ]]; then
		print_info "For Android device automation, install Android SDK Platform Tools for this OS, then check adb devices"
		return 0
	fi
	if ! command -v brew >/dev/null 2>&1; then
		print_info "To add adb on macOS, install Homebrew or Android SDK Platform Tools, then re-run setup"
		return 0
	fi

	local install_android_tools
	setup_prompt install_android_tools "Install optional Android SDK Platform Tools (adb) via Homebrew? [y/N]: " "N" || install_android_tools="N"
	if [[ "${install_android_tools:-}" =~ ^[Yy]$ ]]; then
		if run_with_spinner "Installing Android SDK Platform Tools" brew install --cask android-platform-tools; then
			if command -v adb >/dev/null 2>&1; then
				print_success "Android Platform Tools installed; check adb devices for an authorized emulator or test device"
				print_info "A local emulator needs more SDK packages in one SDK root; see tools/mobile/mobile-mcp.md"
			else
				print_warning "Android Platform Tools installed, but adb is not on PATH; check your Homebrew environment"
			fi
		else
			print_warning "Android Platform Tools installation failed; no Android device access was enabled"
		fi
	fi
	return 0
}

setup_ios_simulator_prerequisites() {
	if [[ "$(uname -s)" != "Darwin" ]]; then
		return 0
	fi
	if command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices >/dev/null 2>&1; then
		print_success "Xcode simctl available; a booted simulator is still required for device automation"
		return 0
	fi
	print_info "iOS Simulator requires full Xcode and a simulator runtime; Command Line Tools alone do not include simctl"
	print_info "Install Xcode, select its developer directory in Xcode Settings > Locations, and install a simulator runtime"
	print_info "Verify with xcrun simctl list devices available, then boot a simulator before connecting Mobile MCP"
	return 0
}

_setup_mobile_mcp_node_version_ok() {
	local version="${1#v}"
	local major="${version%%.*}"
	local minor="${version#*.}"
	minor="${minor%%.*}"
	[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
	((10#$major > 22 || (10#$major == 22 && 10#$minor >= 12)))
}

setup_mobile_mcp() {
	local tool_name="Mobile MCP"
	if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
		print_skip "$tool_name" "Node.js/npm unavailable" "Install Node.js 22.12+ first"
		return 0
	fi
	local node_version
	node_version=$(node --version 2>/dev/null) || return 0
	if ! _setup_mobile_mcp_node_version_ok "$node_version"; then
		print_skip "$tool_name" "Node.js ${node_version} is below the effective dependency minimum" "Install Node.js 22.12+"
		return 0
	fi
	if command -v mcp-server-mobile >/dev/null 2>&1; then
		print_success "Mobile MCP already installed (disabled until explicitly connected)"
		return 0
	fi
	if ! { command -v adb >/dev/null 2>&1 || { command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices >/dev/null 2>&1; }; }; then
		print_skip "$tool_name" "No Android platform tools or usable iOS simulator SDK" "Install adb or Xcode simulator tools"
		return 0
	fi
	local install_mobile_mcp
	setup_prompt install_mobile_mcp "Install optional Mobile MCP for local device automation? [y/N]: " "N" || install_mobile_mcp="N"
	if [[ "${install_mobile_mcp:-}" =~ ^[Yy]$ ]]; then
		if run_with_spinner "Installing Mobile MCP" npm_global_install "@mobilenext/mobile-mcp@1.0.5"; then
			print_success "Mobile MCP installed; restart your MCP client, then select @mobile-mcp to connect"
		else
			print_warning "Mobile MCP installation failed; no device automation was activated"
		fi
	fi
	return 0
}

setup_mobile_simulator_tools() {
	setup_android_platform_tools
	setup_ios_simulator_prerequisites
	setup_minisim
	setup_serve_sim
	setup_mobile_mcp
	return 0
}

_setup_opencode_timeout_cmd() {
	local timeout_seconds="$1"
	shift

	[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=5
	[[ "$timeout_seconds" -gt 0 ]] || timeout_seconds=5

	local command_name="${1:-}"
	if [[ -n "$command_name" ]] && ! declare -F "$command_name" >/dev/null 2>&1; then
		if declare -F timeout_sec >/dev/null 2>&1; then
			timeout_sec "$timeout_seconds" "$@"
			return $?
		fi

		if command -v gtimeout >/dev/null 2>&1; then
			gtimeout "$timeout_seconds" "$@"
			return $?
		fi

		if command -v timeout >/dev/null 2>&1; then
			timeout "$timeout_seconds" "$@"
			return $?
		fi
	fi

	local output_file=""
	output_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-opencode-timeout.XXXXXX" 2>/dev/null || printf '')
	if [[ -z "$output_file" ]]; then
		"$@"
		return $?
	fi

	local pid=""
	"$@" >"$output_file" 2>&1 &
	pid=$!

	local elapsed=0
	while kill -0 "$pid" 2>/dev/null; do
		if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			rm -f "$output_file" 2>/dev/null || true
			return 124
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	local rc=0
	wait "$pid" || rc=$?
	while IFS= read -r line; do
		printf '%s\n' "$line"
	done <"$output_file"
	rm -f "$output_file" 2>/dev/null || true
	return "$rc"
}

_setup_opencode_version_output() {
	local bin="$1"
	local version_timeout="${AIDEVOPS_OPENCODE_VERSION_TIMEOUT:-5}"
	local version_path=""

	version_path=$(_setup_opencode_node_path_for_binary "$bin")
	PATH="${version_path}${PATH:+:${PATH}}" _setup_opencode_timeout_cmd "$version_timeout" "$bin" --version
	return $?
}

_setup_opencode_help_output() {
	local bin="$1"
	local help_timeout="${AIDEVOPS_OPENCODE_VERSION_TIMEOUT:-5}"
	local help_path=""

	help_path=$(_setup_opencode_node_path_for_binary "$bin")
	# OpenCode 1.18.31 writes its help text to stderr. Merge both streams so
	# identity validation accepts the functional CLI while still checking the
	# actual command surface rather than trusting semver alone.
	PATH="${help_path}${PATH:+:${PATH}}" _setup_opencode_timeout_cmd "$help_timeout" "$bin" --help 2>&1
	return $?
}

_setup_opencode_help_identifies_opencode() {
	local help_output="$1"

	[[ -n "$help_output" ]] || return 1

	# Prefer OpenCode's canonical command synopsis, but accept equivalent
	# spacing/placeholders so small help text formatting changes do not break
	# setup healing.
	if [[ "$help_output" =~ opencode[[:space:]]+run ]] &&
		[[ "$help_output" =~ message ]]; then
		return 0
	fi

	# Fallback for help formats that keep the command description but omit the
	# full synopsis from compact output.
	if [[ "$help_output" =~ run[[:space:]]+opencode[[:space:]]+with[[:space:]]+a[[:space:]]+message ]]; then
		return 0
	fi
	if [[ "$(_setup_opencode_profile_id)" == "v2" ]] &&
		[[ "$help_output" == *"OpenCode command line interface"* ]] &&
		[[ "$help_output" == *"Run OpenCode with a message"* ]]; then
		return 0
	fi

	return 1
}

_setup_opencode_first_line() {
	local input="$1"
	local first_line=""

	IFS= read -r first_line <<<"$input" || true
	printf '%s\n' "$first_line"
	return 0
}

_setup_opencode_homebrew_owner_action() {
	local bin="${1:-}"
	local brew_bin=""
	local brew_prefix=""
	local bin_real=""
	local prefix_real=""

	[[ -n "$bin" ]] || return 1
	[[ "$(_setup_opencode_profile_id)" == "v1" ]] || return 1
	command -v brew >/dev/null 2>&1 || return 1
	brew_bin=$(command -v brew 2>/dev/null || printf '')
	[[ -n "$brew_bin" ]] || return 1
	brew_prefix=$(brew --prefix opencode 2>/dev/null || printf '')
	[[ -n "$brew_prefix" ]] || brew_prefix=$(brew --prefix 2>/dev/null || printf '')
	[[ -n "$brew_prefix" ]] || return 1

	bin_real=$(cd "$(dirname "$bin")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$bin")") || return 1
	prefix_real=$(cd "$brew_prefix" 2>/dev/null && pwd -P) || return 1

	case "$bin_real" in
	"$prefix_real"/*)
		printf '%s\n' "brew reinstall opencode"
		return 0
		;;
	esac

	return 1
}

_setup_opencode_profile_id() {
	if command -v aidevops_opencode_profile_id >/dev/null 2>&1; then
		aidevops_opencode_profile_id
	else
		case "${AIDEVOPS_OPENCODE_PROFILE:-v1}" in
		v2) printf 'v2\n' ;;
		*) printf 'v1\n' ;;
		esac
	fi
	return 0
}

_setup_opencode_profile_value() {
	local field="$1"
	local profile="${2:-$(_setup_opencode_profile_id)}"
	if command -v aidevops_opencode_profile_value >/dev/null 2>&1; then
		aidevops_opencode_profile_value "$field" "$profile"
		return $?
	fi
	case "$profile:$field" in
	v2:package) printf '@opencode/cli\n' ;;
	v2:binary) printf 'opencode2\n' ;;
	v1:package) printf 'opencode-ai\n' ;;
	v1:binary) printf 'opencode\n' ;;
	*) return 1 ;;
	esac
	return 0
}

_setup_opencode_v2_install_root() {
	local v2_root="${AIDEVOPS_OPENCODE_V2_ROOT:-${HOME}/.aidevops/runtimes/opencode-v2}"
	printf '%s\n' "${v2_root}/runtime"
	return 0
}

_setup_opencode_v2_install_binary() {
	local install_root=""
	install_root=$(_setup_opencode_v2_install_root) || return 1
	printf '%s\n' "${install_root}/node_modules/.bin/opencode2"
	return 0
}

_setup_install_opencode_package() {
	local install_pkg="$1"
	if [[ "$(_setup_opencode_profile_id)" != "v2" ]]; then
		npm_global_install "$install_pkg"
		return $?
	fi

	command -v npm >/dev/null 2>&1 || return 1
	local install_root=""
	install_root=$(_setup_opencode_v2_install_root) || return 1
	mkdir -p "$install_root" || return 1
	chmod 700 "${install_root%/runtime}" "$install_root" 2>/dev/null || true
	npm install --no-audit --no-fund --prefix "$install_root" "$install_pkg"
	return $?
}

_setup_opencode_installer() {
	if [[ "$(_setup_opencode_profile_id)" == "v2" ]]; then
		command -v npm >/dev/null 2>&1 || return 1
		printf 'npm\n'
		return 0
	fi
	if command -v npm >/dev/null 2>&1; then
		printf 'npm\n'
		return 0
	fi
	if command -v bun >/dev/null 2>&1; then
		printf 'bun\n'
		return 0
	fi
	return 1
}

_setup_opencode_print_missing_installer() {
	if [[ "$(_setup_opencode_profile_id)" == "v2" ]]; then
		print_warning "npm not found - cannot install the isolated OpenCode V2 preview"
		print_info "Install Node.js and npm first, then re-run setup"
		return 0
	fi
	print_warning "Neither bun nor npm found - cannot install OpenCode"
	print_info "Install Node.js or Bun first, then re-run setup"
	return 0
}

_setup_opencode_print_manual_install_hint() {
	local installer="${1:-}"
	local install_pkg="${2:-opencode-ai@latest}"
	local current_bin="${3:-}"
	local brew_action=""
	local manual_cmd=""
	local profile=""
	profile=$(_setup_opencode_profile_id) || return 1

	if [[ "$profile" == "v2" ]]; then
		local install_root=""
		install_root=$(_setup_opencode_v2_install_root) || return 1
		print_info "Try manually: npm install --no-audit --no-fund --prefix $install_root $install_pkg"
		return 0
	fi

	if brew_action=$(_setup_opencode_homebrew_owner_action "$current_bin" 2>/dev/null); then
		print_info "OpenCode appears to be managed by Homebrew; try manually: $brew_action"
		return 0
	fi

	case "$installer" in
	bun) manual_cmd="bun install -g $install_pkg" ;;
	npm | *) manual_cmd="npm install -g $install_pkg" ;;
	esac
	print_info "Try manually: $manual_cmd"
	return 0
}

_setup_opencode_node_path_for_binary() {
	local bin="$1"
	local bin_dir=""
	local path_value=""

	bin_dir=$(dirname "$bin" 2>/dev/null || printf '')
	if [[ -n "$bin_dir" && "$bin_dir" == /* ]]; then
		path_value="${bin_dir}:"
	fi
	path_value="${path_value}${HOME}/.local/bin:${HOME}/.aidevops/agents/scripts:/usr/local/bin:/usr/bin:/bin"
	path_value="${path_value}:${HOME}/.nix-profile/bin:${HOME}/.local/state/nix/profile/bin:/etc/profiles/per-user/${USER:-$(id -un)}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
	printf '%s\n' "$path_value"
	return 0
}

_setup_opencode_binary_is_ephemeral() {
	local bin="$1"
	local temp_root="${TMPDIR:-}"

	while [[ "$temp_root" == */ && "$temp_root" != "/" ]]; do
		temp_root="${temp_root%/}"
	done
	if [[ "$temp_root" == "/" && "$bin" == /* ]]; then
		return 0
	fi
	if [[ -n "$temp_root" && "$bin" == "$temp_root"/* ]]; then
		return 0
	fi

	case "$bin" in
	/tmp/* | /private/tmp/* | /var/tmp/* | /var/folders/*/*/T/* | /private/var/folders/*/*/T/*) return 0 ;;
	esac

	return 1
}

_setup_clear_canary_negative_cache() {
	local state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	rm -f "${state_dir}/canary-last-fail" "${state_dir}/canary-last-fail.reason" 2>/dev/null || true
	return 0
}

_setup_opencode_managed_shim_target() {
	local shim_path="${1:-}"
	local exec_line=""
	local encoded="" decoded="" char=""

	[[ -f "$shim_path" ]] || return 1
	grep -Fq '# aidevops:terminal-title-owner' "$shim_path" 2>/dev/null || return 1
	exec_line=$(grep '^exec "' "$shim_path" 2>/dev/null || true)
	local pattern='^exec[[:space:]]+"(([^"\\]|\\.)*)"[[:space:]]+"\$@"$'
	if [[ "$exec_line" =~ $pattern ]]; then
		encoded="${BASH_REMATCH[1]}"
		while [[ -n "$encoded" ]]; do
			char="${encoded:0:1}"
			encoded="${encoded:1}"
			if [[ "$char" == "\\" ]]; then
				[[ -n "$encoded" ]] || return 1
				char="${encoded:0:1}"
				encoded="${encoded:1}"
			fi
			decoded+="$char"
		done
		printf '%s\n' "$decoded"
		return 0
	fi

	return 1
}

# Check managed exec chains without running them. -ef catches symlink and
# hard-link aliases; the depth cap also bounds non-cyclic wrapper chains.
_setup_opencode_target_is_safe() {
	local bin="$1"
	local forbidden="${2:-}"
	local target="" seen_bin=""
	local seen=()
	local depth=0
	while [[ "$depth" -lt 16 ]]; do
		[[ -f "$bin" && -x "$bin" ]] || return 1
		[[ -z "$forbidden" || ! "$bin" -ef "$forbidden" ]] || return 1
		for seen_bin in "${seen[@]}"; do
			[[ ! "$bin" -ef "$seen_bin" ]] || return 1
		done
		seen+=("$bin")
		if ! grep -Fq '# aidevops:terminal-title-owner' "$bin" 2>/dev/null; then
			return 0
		fi
		target=$(_setup_opencode_managed_shim_target "$bin") || return 1
		[[ "$target" == /* ]] || return 1
		bin="$target"
		depth=$((depth + 1))
	done
	return 1
}

# Escape literal values embedded inside the generated shell's double quotes.
_setup_opencode_quote_value() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\$/\\\$}"
	value="${value//\`/\\\`}"
	value="${value//\"/\\\"}"
	printf '%s' "$value"
	return 0
}

# Bump when the generated V2 shim changes so existing shims regenerate.
_setup_opencode_v2_shim_version_marker() {
	printf '%s\n' '# aidevops:opencode-v2-shim-version=4'
	return 0
}

# The V2 background service outlives whichever process starts it and serves
# every later session. Invocations that use or may start it (anything without
# --standalone/--server) drop caller-session identity, headless flags, and
# bundle pins first, so a restart from a worker or another OpenCode session
# cannot make interactive V2 sessions headless (GH#32498).
#
# Tabby restoration (GH#32700): an interactive TUI in Tabby exports
# AIDEVOPS_TABBY_V2_RECOVERY=1 so the V2 TUI plugin reports a private marker
# directory for the active session. Launching from a valid V2 marker resumes
# that session unless its owner is still live (split tab) or the caller chose
# a session. V1 markers only open their project directory.
_setup_append_opencode_v2_session_guard() {
	local temp_shim="$1"
	cat >>"$temp_shim" <<'EOF' || return 1
_aidevops_v2_subcommand=""
_aidevops_v2_private_server=0
_aidevops_v2_session_arg=0
_aidevops_v2_skip_value=0
for _aidevops_v2_arg in "$@"; do
	if [[ "$_aidevops_v2_skip_value" -eq 1 ]]; then
		_aidevops_v2_skip_value=0
		continue
	fi
	case ${_aidevops_v2_arg} in
	--standalone | --server=*) _aidevops_v2_private_server=1 ;;
	--server)
		_aidevops_v2_private_server=1
		_aidevops_v2_skip_value=1
		;;
	-s | --session)
		_aidevops_v2_session_arg=1
		_aidevops_v2_skip_value=1
		;;
	--session=* | -c | --continue) _aidevops_v2_session_arg=1 ;;
	--log-level | --hostname | --mdns-domain | --cors | -m | --model | --prompt | --agent | --replay-limit | --config | --cwd | --directory | --port)
		_aidevops_v2_skip_value=1
		;;
	-*) ;;
	*) [[ -n "$_aidevops_v2_subcommand" ]] || _aidevops_v2_subcommand="${_aidevops_v2_arg}" ;;
	esac
done
if [[ "$_aidevops_v2_private_server" -eq 0 ]]; then
	unset OPENCODE OPENCODE_PID AGENT OPENCODE_SESSION_ID OPENCODE_MODEL \
		AIDEVOPS_OPENCODE_SESSION_ID AIDEVOPS_SESSION_ID AIDEVOPS_OPERATION_ID AIDEVOPS_TASK_OPERATION_ID \
		AIDEVOPS_SESSION_ORIGIN AIDEVOPS_SIG_MODEL AIDEVOPS_SIG_SESSION_ID \
		FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS \
		AIDEVOPS_WORKER_ID AIDEVOPS_PARENT_WORKER_ID AIDEVOPS_ROOT_WORKER_ID AIDEVOPS_CORRELATION_ID \
		AIDEVOPS_CAUSATION_ID AIDEVOPS_PARENT_EVENT_ID AIDEVOPS_ROOT_EVENT_ID \
		AIDEVOPS_TABBY_SESSION_RECOVERY AIDEVOPS_OPENCODE_ISOLATED_DB AIDEVOPS_OPENCODE_SERVER_OWNER \
		AIDEVOPS_TEAM_INTERFACE_OVERLAY AIDEVOPS_REMOTE_INTERFACE AIDEVOPS_REMOTE_RUNTIME_ANCHOR AIDEVOPS_REMOTE_PROJECT_ROOT \
		AIDEVOPS_AGENTS_DIR AIDEVOPS_ACTIVE_AGENTS_DIR AIDEVOPS_ACTIVE_BUNDLE_ROOT AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE \
		AIDEVOPS_VERSION
fi
if [[ -z "$_aidevops_v2_subcommand" && "${TERM_PROGRAM:-}" == "Tabby" && -n "${TABBY_CONFIG_DIRECTORY:-}" \
	&& "${AIDEVOPS_TABBY_V2_RECOVERY:-1}" != "0" ]]; then
	export AIDEVOPS_TABBY_V2_RECOVERY=1
else
	export AIDEVOPS_TABBY_V2_RECOVERY=0
fi
_aidevops_v2_work_dir="${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}"
_aidevops_v2_resume_session=""
if [[ -z "$_aidevops_v2_subcommand" && "$PWD" == "${_aidevops_v2_work_dir}/opencode-tabby-recovery/"* ]]; then
	_aidevops_v2_launch_dir="$HOME"
	_aidevops_v2_resolver="${HOME}/.aidevops/agents/plugins/opencode-aidevops/session-recovery-marker.mjs"
	_aidevops_v2_recovery=""
	_aidevops_v2_recovery_status=2
	if command -v node >/dev/null 2>&1; then
		if _aidevops_v2_recovery=$(node "$_aidevops_v2_resolver" resolve --cwd "$PWD" --work-dir "$_aidevops_v2_work_dir" \
			--runtime v2 --data-dir "$XDG_DATA_HOME" 2>/dev/null); then
			_aidevops_v2_recovery_status=0
		else
			_aidevops_v2_recovery_status=$?
		fi
	fi
	# 0 resumable, 3 owner still live, 4 V1 marker: all name a project directory.
	case "$_aidevops_v2_recovery_status" in
	0 | 3 | 4) [[ -z "$_aidevops_v2_recovery" ]] || _aidevops_v2_launch_dir="${_aidevops_v2_recovery%%$'\t'*}" ;;
	esac
	if [[ "$_aidevops_v2_recovery_status" -eq 0 && "$_aidevops_v2_session_arg" -eq 0 ]]; then
		_aidevops_v2_resume_session="${_aidevops_v2_recovery##*$'\t'}"
		printf 'opencode2: restoring Tabby session %s in %s\n' "$_aidevops_v2_resume_session" "$_aidevops_v2_launch_dir" >&2
	else
		printf 'opencode2: leaving the Tabby recovery marker directory for %s\n' "$_aidevops_v2_launch_dir" >&2
	fi
	cd "$_aidevops_v2_launch_dir" || exit 1
fi
if [[ -n "$_aidevops_v2_resume_session" ]]; then
	set -- --session "$_aidevops_v2_resume_session" "$@"
fi
EOF
	return 0
}

_setup_write_opencode_v2_shim() {
	local temp_shim="$1"
	local wrapper_path="$2"
	local wrapper_path_value="$3"
	local version_marker=""
	version_marker=$(_setup_opencode_v2_shim_version_marker)
	cat >"$temp_shim" <<EOF || return 1
#!/usr/bin/env bash
# Generated by aidevops setup: isolated OpenCode V2 preview shim.
# aidevops:terminal-title-owner
# aidevops:opencode-v2-isolation
$version_marker
export PATH="$wrapper_path_value\${PATH:+:\$PATH}"
export AIDEVOPS_OPENCODE_PROFILE=v2
export AIDEVOPS_TERMINAL_TITLE_OWNER="\${AIDEVOPS_TERMINAL_TITLE_OWNER:-aidevops}"
export OPENCODE_DISABLE_AUTOUPDATE="\${OPENCODE_DISABLE_AUTOUPDATE:-1}"
export OPENCODE_DISABLE_TERMINAL_TITLE="\${OPENCODE_DISABLE_TERMINAL_TITLE:-1}"
_aidevops_v2_root="\${AIDEVOPS_OPENCODE_V2_ROOT:-\${HOME}/.aidevops/runtimes/opencode-v2}"
_aidevops_v2_caller_config_home="\${XDG_CONFIG_HOME:-\${HOME}/.config}"
# gh must retain the caller's auth location, including in a shared V2 service.
export GH_CONFIG_DIR="\${GH_CONFIG_DIR:-\${_aidevops_v2_caller_config_home}/gh}"
export XDG_CONFIG_HOME="\${AIDEVOPS_OPENCODE_V2_CONFIG_HOME:-\${_aidevops_v2_root}/config}"
export XDG_DATA_HOME="\${AIDEVOPS_OPENCODE_V2_DATA_HOME:-\${_aidevops_v2_root}/data}"
export XDG_CACHE_HOME="\${AIDEVOPS_OPENCODE_V2_CACHE_HOME:-\${_aidevops_v2_root}/cache}"
export XDG_STATE_HOME="\${AIDEVOPS_OPENCODE_V2_STATE_HOME:-\${_aidevops_v2_root}/state}"
export TMPDIR="\${AIDEVOPS_OPENCODE_V2_TMPDIR:-\${_aidevops_v2_root}/tmp}"
export TMP="\$TMPDIR"
export TEMP="\$TMP"
export OPENCODE_CONFIG_DIR="\${AIDEVOPS_OPENCODE_V2_CONFIG_DIR:-\${XDG_CONFIG_HOME}/opencode}"
export OPENCODE_CONFIG="\${AIDEVOPS_OPENCODE_V2_CONFIG:-\${OPENCODE_CONFIG_DIR}/opencode.json}"
export AIDEVOPS_OAUTH_POOL_FILE="\${AIDEVOPS_OPENCODE_V2_OAUTH_POOL_FILE:-\${_aidevops_v2_root}/auth/oauth-pool.json}"
_aidevops_v2_auth_dir="\${AIDEVOPS_OAUTH_POOL_FILE%/*}"
mkdir -p "\$OPENCODE_CONFIG_DIR" "\$XDG_DATA_HOME" "\$XDG_CACHE_HOME" "\$XDG_STATE_HOME" "\$TEMP" "\$_aidevops_v2_auth_dir"
chmod 700 "\${_aidevops_v2_root}" "\$OPENCODE_CONFIG_DIR" "\$XDG_DATA_HOME" "\$XDG_CACHE_HOME" "\$XDG_STATE_HOME" "\$TMPDIR" "\$_aidevops_v2_auth_dir" 2>/dev/null || true
EOF
	_setup_append_opencode_v2_session_guard "$temp_shim" || return 1
	cat >>"$temp_shim" <<EOF || return 1
_aidevops_v2_has_port=0
for _aidevops_v2_arg in "\$@"; do
	case \${_aidevops_v2_arg} in
	--port | --port=*) _aidevops_v2_has_port=1 ;;
	esac
done
if [[ "\$_aidevops_v2_has_port" -eq 0 ]]; then
	_aidevops_v2_args=()
	_aidevops_v2_command_seen=0
	_aidevops_v2_skip_value=0
	for _aidevops_v2_arg in "\$@"; do
		if [[ "\$_aidevops_v2_skip_value" -eq 1 ]]; then
			_aidevops_v2_args+=("\${_aidevops_v2_arg}")
			_aidevops_v2_skip_value=0
			continue
		fi
		if [[ "\$_aidevops_v2_command_seen" -eq 0 ]]; then
			case \${_aidevops_v2_arg} in
			--)
				_aidevops_v2_command_seen=1
				;;
			--log-level | --hostname | --mdns-domain | --cors | -m | --model | -s | --session | --prompt | --agent | --replay-limit | --config | --cwd | --directory)
				_aidevops_v2_skip_value=1
				;;
			-*) ;;
			serve)
				_aidevops_v2_args+=(serve --port "\${AIDEVOPS_OPENCODE_V2_PORT:-4097}")
				_aidevops_v2_command_seen=1
				continue
				;;
			*) _aidevops_v2_command_seen=1 ;;
			esac
		fi
		_aidevops_v2_args+=("\${_aidevops_v2_arg}")
	done
	set -- "\${_aidevops_v2_args[@]}"
fi
if [[ "\$AIDEVOPS_TABBY_V2_RECOVERY" == "1" ]]; then
	# A normal exit returns the Tabby tab to its project directory. A hangup
	# (Tabby quit or crash) ends this shim too, so the session marker remains
	# the tab's saved directory and the next launch restores that session.
	"$wrapper_path" "\$@"
	_aidevops_v2_status=\$?
	if [[ "\$PWD" != *[[:cntrl:]]* ]]; then
		printf '\\033]1337;CurrentDir=%s\\007' "\$PWD" 2>/dev/null >/dev/tty || true
	fi
	exit "\$_aidevops_v2_status"
fi
exec "$wrapper_path" "\$@"
EOF
	return 0
}

_setup_write_opencode_v1_shim() {
	local temp_shim="$1"
	local wrapper_path="$2"
	local wrapper_path_value="$3"
	cat >"$temp_shim" <<EOF || return 1
#!/usr/bin/env bash
# Generated by aidevops setup: daemon-safe OpenCode shim.
# aidevops:terminal-title-owner
export PATH="$wrapper_path_value\${PATH:+:\$PATH}"
export AIDEVOPS_TERMINAL_TITLE_OWNER="\${AIDEVOPS_TERMINAL_TITLE_OWNER:-aidevops}"
if [[ "\$AIDEVOPS_TERMINAL_TITLE_OWNER" == "aidevops" ]]; then
	export OPENCODE_DISABLE_TERMINAL_TITLE="\${OPENCODE_DISABLE_TERMINAL_TITLE:-1}"
fi
exec "$wrapper_path" "\$@"
EOF
	return 0
}

_setup_ensure_opencode_stable_shim() {
	local real_bin="${1:-}"
	local shim_dir="${HOME}/.local/bin"
	local binary_name=""
	binary_name=$(_setup_opencode_profile_value binary) || return 1
	local shim_path="${shim_dir}/${binary_name}"
	local resolved_bin=""
	local wrapper_path=""
	local physical_dir=""
	local wrapper_path_value=""
	local temp_shim=""
	local isolation_ready=1
	local existing_target=""

	[[ -n "$real_bin" ]] || return 1
	resolved_bin=$(command -v "$real_bin" 2>/dev/null || printf '%s' "$real_bin")
	if [[ "$resolved_bin" == "$shim_path" || "$resolved_bin" -ef "$shim_path" ]]; then
		existing_target=$(_setup_opencode_managed_shim_target "$shim_path" 2>/dev/null || true)
		if [[ -n "$existing_target" ]] && _setup_validate_opencode_binary "$existing_target"; then
			resolved_bin="$existing_target"
		else
			resolved_bin=$(_setup_find_valid_opencode_binary) || return 1
		fi
	fi
	_setup_opencode_target_is_safe "$resolved_bin" "$shim_path" || {
		printf 'OpenCode shim target is missing or self-referential: %s\n' "$resolved_bin" >&2
		return 1
	}
	_setup_validate_opencode_binary "$resolved_bin" || return 1
	if _setup_opencode_binary_is_ephemeral "$resolved_bin" &&
		! _setup_opencode_binary_is_ephemeral "${HOME}/.aidevops-home"; then
		return 1
	fi

	mkdir -p "$shim_dir" 2>/dev/null || return 1
	# Keep profile symlinks logical: pinning a Nix store generation breaks
	# upgrades and can leave a garbage-collected executable in the launcher.
	[[ "$resolved_bin" == /* ]] || return 1
	wrapper_path="$resolved_bin"
	# Retain the physical-directory persistence guard without using that
	# physical path as the execution target (profiles must remain upgradeable).
	physical_dir=$(cd "$(dirname "$resolved_bin")" 2>/dev/null && pwd -P) || return 1
	if _setup_opencode_binary_is_ephemeral "$physical_dir/$(basename "$resolved_bin")" &&
		! _setup_opencode_binary_is_ephemeral "${HOME}/.aidevops-home"; then
		return 1
	fi
	if [[ "$binary_name" == "opencode2" ]] &&
		! grep -Fxq "$(_setup_opencode_v2_shim_version_marker)" "$shim_path" 2>/dev/null; then
		isolation_ready=0
	fi
	wrapper_path_value=$(_setup_opencode_node_path_for_binary "$wrapper_path")
	wrapper_path_value=$(_setup_opencode_quote_value "$wrapper_path_value")
	if [[ "$resolved_bin" != "$shim_path" ]] &&
		_setup_validate_opencode_binary "$shim_path" &&
		[[ "$isolation_ready" -eq 1 ]] &&
		grep -Fxq "export PATH=\"$wrapper_path_value\${PATH:+:\$PATH}\"" "$shim_path" 2>/dev/null &&
		[[ "$(_setup_opencode_managed_shim_target "$shim_path" 2>/dev/null || true)" == "$wrapper_path" ]]; then
		printf '%s\n' "$shim_path"
		return 0
	fi
	wrapper_path=$(_setup_opencode_quote_value "$wrapper_path")

	temp_shim="${shim_path}.tmp.$$"
	if [[ "$binary_name" == "opencode2" ]]; then
		_setup_write_opencode_v2_shim "$temp_shim" "$wrapper_path" "$wrapper_path_value" || return 1
	else
		_setup_write_opencode_v1_shim "$temp_shim" "$wrapper_path" "$wrapper_path_value" || return 1
	fi
	chmod +x "$temp_shim" 2>/dev/null || {
		rm -f "$temp_shim" 2>/dev/null || true
		return 1
	}
	_setup_opencode_target_is_safe "$temp_shim" "$shim_path" &&
		_setup_validate_opencode_binary "$temp_shim" || {
		printf 'OpenCode generated launcher validation failed; keeping existing launcher\n' >&2
		rm -f "$temp_shim" 2>/dev/null || true
		return 1
	}
	mv -f "$temp_shim" "$shim_path" 2>/dev/null || {
		rm -f "$temp_shim" 2>/dev/null || true
		return 1
	}

	_setup_validate_opencode_binary "$shim_path" || return 1
	_setup_clear_canary_negative_cache
	printf '%s\n' "$shim_path"
	return 0
}

_setup_record_opencode_binary_path() {
	local stable_bin="$1"
	local profile=""
	profile=$(_setup_opencode_profile_id) || return 1
	mkdir -p "${HOME}/.aidevops" 2>/dev/null || true
	printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-${profile}-bin-resolved" 2>/dev/null || true
	if [[ "${AIDEVOPS_OPENCODE_PRESERVE_PRIMARY_RECEIPT:-0}" != "1" ]]; then
		printf '%s\n' "$stable_bin" >"${HOME}/.aidevops/.opencode-bin-resolved" 2>/dev/null || true
	fi
	return 0
}

_setup_find_valid_opencode_binary() {
	local preferred_bin="${1:-}"
	local candidate=""
	local candidate_path=""
	local binary_name=""
	binary_name=$(_setup_opencode_profile_value binary) || return 1
	local shim_path="${HOME}/.local/bin/${binary_name}"
	local managed_shim_target=""
	local isolated_install_bin=""
	local path_dir=""
	local path_dirs=() path_candidates=()

	managed_shim_target=$(_setup_opencode_managed_shim_target "$shim_path" 2>/dev/null || true)
	if [[ "$(_setup_opencode_profile_id)" == "v2" ]]; then
		isolated_install_bin=$(_setup_opencode_v2_install_binary 2>/dev/null || true)
	fi
	# command -v only sees the first launcher. Inspect later absolute PATH
	# entries too (including explicit Nix store paths), never cwd/empty entries.
	IFS=: read -r -a path_dirs <<<"${PATH:-}"
	for path_dir in "${path_dirs[@]}"; do
		[[ "$path_dir" == /* ]] || continue
		path_candidates+=("${path_dir}/${binary_name}")
	done

	for candidate in \
		"$preferred_bin" \
		"$isolated_install_bin" \
		"${HOME}/.nix-profile/bin/${binary_name}" \
		"${HOME}/.local/state/nix/profile/bin/${binary_name}" \
		"/etc/profiles/per-user/${USER:-$(id -un)}/bin/${binary_name}" \
		"/run/current-system/sw/bin/${binary_name}" \
		"/nix/var/nix/profiles/default/bin/${binary_name}" \
		"/opt/homebrew/bin/${binary_name}" \
		"/usr/local/bin/${binary_name}" \
		"/home/linuxbrew/.linuxbrew/bin/${binary_name}" \
		"${HOME}/.npm-global/bin/${binary_name}" \
		"${HOME}/.bun/bin/${binary_name}" \
		"$managed_shim_target" \
		"${path_candidates[@]}" \
		"$binary_name"; do
		[[ -n "$candidate" ]] || continue
		[[ "$candidate" == "$shim_path" ]] && continue
		candidate_path=$(command -v "$candidate" 2>/dev/null || printf '%s' "$candidate")
		[[ "$candidate_path" == "$shim_path" ]] && continue
		_setup_opencode_target_is_safe "$candidate_path" "$shim_path" || continue
		if _setup_opencode_binary_is_ephemeral "$candidate_path" &&
			! _setup_opencode_binary_is_ephemeral "${HOME}/.aidevops-home"; then
			continue
		fi
		if _setup_validate_opencode_binary "$candidate_path"; then
			printf '%s\n' "$candidate_path"
			return 0
		fi
	done

	return 1
}

# A freshly installed Node CLI can briefly be present before its first process
# is ready. Retry the full candidate lookup a small, bounded number of times so
# setup does not reinstall an otherwise valid OpenCode binary on the next run.
_setup_find_post_install_opencode_binary() {
	local preferred_bin="${1:-}"
	local retry_attempts="${AIDEVOPS_OPENCODE_POST_INSTALL_ATTEMPTS:-3}"
	local retry_delay="${AIDEVOPS_OPENCODE_POST_INSTALL_RETRY_DELAY:-1}"
	local attempt=1
	local valid_bin=""

	[[ "$retry_attempts" =~ ^[1-3]$ ]] || retry_attempts=3
	[[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=1

	while [[ "$attempt" -le "$retry_attempts" ]]; do
		valid_bin=$(_setup_find_valid_opencode_binary "$preferred_bin" 2>/dev/null || printf '')
		if [[ -n "$valid_bin" ]]; then
			printf '%s\n' "$valid_bin"
			return 0
		fi

		if [[ "$attempt" -lt "$retry_attempts" ]]; then
			print_info "OpenCode post-install validation is not ready; retrying..." >&2
			sleep "$retry_delay"
		fi
		attempt=$((attempt + 1))
	done

	return 1
}

_setup_record_valid_opencode_binary() {
	local valid_bin="$1"
	local valid_version=""
	local stable_bin=""

	[[ -n "$valid_bin" ]] || return 1
	valid_version=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$valid_bin" 2>/dev/null || printf 'unknown')")
	stable_bin=$(_setup_ensure_opencode_stable_shim "$valid_bin") || {
		print_warning "OpenCode stable shim verification failed for '$valid_bin'"
		return 1
	}
	print_success "OpenCode CLI: $valid_bin ($valid_version)"
	_setup_record_opencode_binary_path "$stable_bin"
	return 0
}

_setup_record_current_opencode_binary() {
	local current_bin="$1"
	local current_version=""
	local stable_bin=""

	current_version=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$current_bin" 2>/dev/null || printf 'unknown')")
	stable_bin=$(_setup_ensure_opencode_stable_shim "$current_bin") || {
		print_warning "OpenCode stable shim verification failed for '$current_bin'"
		return 1
	}
	print_success "OpenCode already installed: $current_version"
	_setup_record_opencode_binary_path "$stable_bin"
	return 0
}

_setup_find_valid_opencode_alternative() {
	local current_bin="$1"
	local validate_rc="$2"
	local valid_bin=""

	[[ "$validate_rc" -ne 0 ]] || return 1
	valid_bin=$(_setup_find_valid_opencode_binary "$current_bin" 2>/dev/null || printf '')
	[[ -n "$valid_bin" && "$valid_bin" != "$current_bin" ]] || return 1

	printf '%s\n' "$valid_bin"
	return 0
}

# t2891: Validate that an opencode binary is real anomalyco/opencode.
# Mirrors the t2887 runtime canary validator (headless-runtime-lib.sh) and
# the t2888 setup module validator (.agents/scripts/setup/_services.sh).
# Inlined to keep tool-install.sh self-contained — sourced from setup.sh
# during early bootstrap before headless-runtime-lib.sh is on the path.
# Returns: 0=valid, 1=wrong package (e.g. claude CLI), 2=missing/unrunnable.
_setup_validate_opencode_binary() {
	local bin="${1:-}"
	local profile=""
	profile=$(_setup_opencode_profile_id)
	[[ -n "$bin" ]] || return 2
	command -v "$bin" >/dev/null 2>&1 || return 2
	bin=$(command -v "$bin") || return 2
	_setup_opencode_target_is_safe "$bin" || return 2

	local v
	v=$(_setup_opencode_version_output "$bin" 2>/dev/null || printf '')
	[[ -n "$v" ]] || return 2
	local help_output
	help_output=$(_setup_opencode_help_output "$bin" 2>/dev/null || printf '')
	[[ -n "$help_output" ]] || return 2

	# Anthropic claude CLI signature — highest-confidence rejection.
	[[ "$v" == *"(Claude Code)"* ]] && return 1

	# Sanity: must look like a semver (X.Y.Z).
	local semantic_version=""
	if [[ "$v" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
		semantic_version="${BASH_REMATCH[1]}"
	else
		return 1
	fi
	if [[ "$profile" == "v2" ]]; then
		[[ "$semantic_version" =~ ^2\. ]] || return 1
	else
		# V1 selection rejects V2 and the similarly versioned Claude CLI.
		[[ "$semantic_version" =~ ^([2-9]|[1-9][[:digit:]]+)\. ]] && return 1
	fi

	# Positive OpenCode identity check. Qwen and other CLIs can return a
	# semver-compatible --version (for example 0.2.1), so version shape alone is
	# not enough. Require OpenCode's command surface before writing/accepting the
	# stable ~/.local/bin/opencode shim used by Tabby and workers.
	_setup_opencode_help_identifies_opencode "$help_output" || return 1

	return 0
}

# t2891: detect-and-heal when 'opencode' bin name is owned by a wrong
# package (canonical case: @anthropic-ai/claude-code shadowing
# anomalyco/opencode after a npm install collision). Auto-installs
# without prompt because:
#   1) it's healing a broken state, not first-time setup
#   2) non-interactive runners (the canonical victim) would auto-Y anyway
# Idempotent. Fail-open if no installer available.
_setup_opencode_force_heal() {
	local install_pkg="$1" wrong_bin="$2" wrong_v="$3"
	print_warning "OpenCode binary at '$wrong_bin' is the wrong package ('$wrong_v')"
	print_info "Forcing reinstall of $install_pkg to heal bin collision (t2891)..."

	local installer=""
	installer=$(_setup_opencode_installer 2>/dev/null || true)
	if [[ -z "$installer" ]]; then
		_setup_opencode_print_missing_installer
		return 0
	fi

	local install_timeout="${AIDEVOPS_OPENCODE_INSTALL_TIMEOUT:-180}"
	# npm_global_install intentionally uses npm first for opencode-ai when npm is
	# available, falling back to bun only for bun-only systems.
	if run_with_spinner "Reinstalling OpenCode via $installer (heal)" _setup_opencode_timeout_cmd "$install_timeout" _setup_install_opencode_package "$install_pkg"; then
		print_success "OpenCode reinstalled via $installer"
	else
		print_warning "Heal install failed via $installer"
		_setup_opencode_print_manual_install_hint "$installer" "$install_pkg" "$wrong_bin"
	fi

	# Re-validate post-heal.
	local new_bin
	local binary_name
	binary_name=$(_setup_opencode_profile_value binary) || return 1
	local preferred_bin=""
	preferred_bin=$(command -v "$binary_name" 2>/dev/null || echo "")
	if [[ "$(_setup_opencode_profile_id)" == "v2" ]]; then
		preferred_bin=$(_setup_opencode_v2_install_binary 2>/dev/null || printf '%s' "$preferred_bin")
	fi
	new_bin=$(_setup_find_valid_opencode_binary "$preferred_bin" 2>/dev/null || echo "")
	if [[ -n "$new_bin" ]] && _setup_validate_opencode_binary "$new_bin"; then
		local new_v
		new_v=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$new_bin" 2>/dev/null || printf 'unknown')")
		local stable_bin
		stable_bin=$(_setup_ensure_opencode_stable_shim "$new_bin") || {
			print_warning "OpenCode stable shim verification failed for '$new_bin'"
			return 1
		}
		print_success "OpenCode CLI: $new_bin ($new_v)"
		_setup_record_opencode_binary_path "$stable_bin"
	else
		local v_after
		v_after="<missing>"
		if [[ -n "$new_bin" ]] && [[ -x "$new_bin" ]]; then
			v_after=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$new_bin" 2>/dev/null || printf 'unknown')")
		fi
		print_warning "Post-heal validation still failing: '${new_bin:-opencode}' returns '$v_after'"
		print_info "Check PATH: 'which -a opencode' — npm/bun global bin dir must come first"
		return 1
	fi
	return 0
}

setup_opencode_cli() {
	print_info "Setting up OpenCode CLI..."

	# The compatibility pin is scoped to Linux headless dispatch. General setup
	# tracks upstream; the headless launch guard restores its approved version.
	local package binary_name
	package=$(_setup_opencode_profile_value package) || return 1
	binary_name=$(_setup_opencode_profile_value binary) || return 1
	local install_pkg="${package}@latest"

	# t2891: validate the resolved binary is anomalyco/opencode, not a
	# wrong package (claude CLI etc) that took the 'opencode' bin name.
	# Without this, alex-solovyev's runner — where command -v opencode
	# resolves to @anthropic-ai/claude-code — silently passes through
	# this function, leaving t2887's runtime canary to throttle the spam
	# without ever healing the binary.
	local current_bin
	current_bin=$(command -v "$binary_name" 2>/dev/null || echo "")
	local validate_rc=0
	_setup_validate_opencode_binary "$current_bin" || validate_rc=$?
	local valid_bin=""
	valid_bin=$(_setup_find_valid_opencode_alternative "$current_bin" "$validate_rc" 2>/dev/null || printf '')
	if [[ -n "$valid_bin" ]]; then
		_setup_record_valid_opencode_binary "$valid_bin"
		return $?
	fi

	# Already valid → record + early return.
	if [[ $validate_rc -eq 0 ]]; then
		_setup_record_current_opencode_binary "$current_bin"
		return $?
	fi

	# Wrong package → auto-heal (no prompt).
	if [[ $validate_rc -eq 1 ]]; then
		local wrong_v
		wrong_v=$(_setup_opencode_first_line "$(_setup_opencode_version_output "$current_bin" 2>/dev/null || printf '<unknown>')")
		_setup_opencode_force_heal "$install_pkg" "$current_bin" "$wrong_v"
		return 0
	fi

	# Missing → first-time install path (preserves prompt for interactive UX).
	local installer=""
	installer=$(_setup_opencode_installer 2>/dev/null || true)
	if [[ -z "$installer" ]]; then
		_setup_opencode_print_missing_installer
		return 0
	fi

	print_info "OpenCode is the AI coding tool that aidevops is built for"
	echo "  It provides an AI-powered terminal interface for development tasks."
	echo ""

	local install_oc
	local install_label="OpenCode"
	[[ "$binary_name" == "opencode2" ]] && install_label="OpenCode V2 preview"
	setup_prompt install_oc "Install ${install_label} via $installer? [Y/n]: " "Y"
	if [[ "$install_oc" =~ ^[Yy]?$ ]]; then
		local install_timeout="${AIDEVOPS_OPENCODE_INSTALL_TIMEOUT:-180}"
		if run_with_spinner "Installing ${install_label}" _setup_opencode_timeout_cmd "$install_timeout" _setup_install_opencode_package "$install_pkg"; then
			print_success "${install_label} installed"

			# Persist resolved path on first-time success too (t2891).
			local new_bin
			local preferred_bin=""
			preferred_bin=$(command -v "$binary_name" 2>/dev/null || echo "")
			if [[ "$(_setup_opencode_profile_id)" == "v2" ]]; then
				preferred_bin=$(_setup_opencode_v2_install_binary 2>/dev/null || printf '%s' "$preferred_bin")
			fi
			new_bin=$(_setup_find_post_install_opencode_binary "$preferred_bin" 2>/dev/null || echo "")
			if [[ -n "$new_bin" ]] && _setup_validate_opencode_binary "$new_bin"; then
				local stable_bin
				stable_bin=$(_setup_ensure_opencode_stable_shim "$new_bin") || {
					print_warning "OpenCode stable shim verification failed for '$new_bin'"
					return 1
				}
				_setup_record_opencode_binary_path "$stable_bin"
			else
				print_warning "Post-install OpenCode validation failed"
				return 1
			fi

			# Offer authentication
			echo ""
			print_info "OpenCode needs authentication to use AI models."
			print_info "Run '$binary_name auth login' to authenticate."
			echo ""
		else
			print_warning "OpenCode installation failed"
			_setup_opencode_print_manual_install_hint "$installer" "$install_pkg" "$current_bin"
		fi
	else
		print_info "Skipped OpenCode installation"
		print_info "Install later: $installer install -g $install_pkg"
	fi

	return 0
}

_setup_opencode_v2_preview_enabled() {
	case "${AIDEVOPS_INSTALL_OPENCODE2_PREVIEW:-1}" in
	0 | false | FALSE | no | NO) return 1 ;;
	esac
	return 0
}

setup_opencode_runtimes() {
	local selected_profile=""
	selected_profile=$(_setup_opencode_profile_id) || return 1

	if [[ "$selected_profile" == "v2" ]]; then
		AIDEVOPS_OPENCODE_PROFILE=v1 AIDEVOPS_OPENCODE_PRESERVE_PRIMARY_RECEIPT=1 \
			setup_opencode_cli || print_warning "OpenCode V1 rollback runtime setup encountered issues"
		AIDEVOPS_OPENCODE_PROFILE=v2 setup_opencode_cli
		return $?
	fi

	AIDEVOPS_OPENCODE_PROFILE=v1 setup_opencode_cli || return $?
	if ! _setup_opencode_v2_preview_enabled; then
		print_info "OpenCode V2 preview installation disabled via AIDEVOPS_INSTALL_OPENCODE2_PREVIEW"
		return 0
	fi
	AIDEVOPS_OPENCODE_PROFILE=v2 AIDEVOPS_OPENCODE_PRESERVE_PRIMARY_RECEIPT=1 \
		setup_opencode_cli || print_warning "OpenCode V2 preview setup encountered issues; V1 remains available"
	return 0
}

# shellcheck source=./tool-install-opencode-services.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_tool_install_dir}/tool-install-opencode-services.sh"
unset _tool_install_dir
