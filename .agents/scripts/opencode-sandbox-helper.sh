#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OpenCode Version Sandbox
# =============================================================================
# Test a different OpenCode version in complete isolation — separate binary,
# config, data, and auth. Your production install is never touched.
#
# Usage:
#   opencode-sandbox-helper.sh install <version>   Install a version to sandbox
#   opencode-sandbox-helper.sh run [version]        Launch sandboxed OpenCode
#   opencode-sandbox-helper.sh list                 List installed sandbox versions
#   opencode-sandbox-helper.sh check [version]      Check OAuth/auth status in sandbox
#   opencode-sandbox-helper.sh clean [version|all]  Remove sandbox version(s)
#   opencode-sandbox-helper.sh help                 Show this help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || {
	# Minimal fallback if shared-constants.sh not available
	print_info() { echo "[INFO] $*"; }
	print_success() { echo "[SUCCESS] $*"; }
	print_warning() { echo "[WARNING] $*"; }
	print_error() { echo "[ERROR] $*" >&2; }
}

SANDBOX_ROOT="$HOME/.aidevops/.agent-workspace/opencode-sandbox"

show_help() {
	cat <<'EOF'
OpenCode Version Sandbox — test different versions without touching production

Commands:
  install <version>     Install a version (e.g., 1.3.0, 1.2.30, latest)
  run [version]         Launch sandboxed OpenCode (default: most recent install)
  list                  List installed sandbox versions
  check [version]       Check OAuth/auth.json status in a sandbox
  clean [version|all]   Remove sandbox version(s)

Examples:
  aidevops opencode-sandbox install 1.3.0    # Install 1.3.0 to sandbox
  aidevops opencode-sandbox run 1.3.0        # Launch it (isolated config/data)
  aidevops opencode-sandbox check 1.3.0      # Check auth.json in sandbox
  aidevops opencode-sandbox clean 1.3.0      # Remove when done
  aidevops opencode-sandbox clean all        # Remove all sandboxes

What's isolated:
  - Binary:  ~/.aidevops/.agent-workspace/opencode-sandbox/<version>/
  - Config:  XDG_CONFIG_HOME redirected (separate opencode.json)
  - Data:    XDG_DATA_HOME redirected (separate auth.json, sessions)
  - Your production OpenCode is never touched.

Testing OAuth in a sandbox:
  1. aidevops opencode-sandbox install 1.3.0
  2. aidevops opencode-sandbox run 1.3.0
  3. Inside the sandbox session, check stderr for [aidevops] plugin lines
  4. Use Ctrl+A to test provider auth flow
  5. aidevops opencode-sandbox check 1.3.0   # inspect auth.json
  6. aidevops opencode-sandbox clean 1.3.0   # clean up
EOF
	return 0
}

# Get the binary path for a sandbox version
_sandbox_bin() {
	local version="$1"
	local bin_path="${SANDBOX_ROOT}/${version}/node_modules/.bin/opencode"
	if [[ -f "$bin_path" ]]; then
		echo "$bin_path"
		return 0
	fi
	return 1
}

# Get the most recently installed sandbox version
_latest_sandbox() {
	# Run in a subshell to contain shopt -s nullglob — prevents leakage if
	# set -e causes early exit before shopt -u nullglob can restore the option.
	(
		shopt -s nullglob
		local latest=""
		local latest_time=0
		for dir in "${SANDBOX_ROOT}"/*/; do
			local ver
			ver=$(basename "$dir")
			local mtime
			mtime=$(_file_mtime_epoch "$dir")
			if [[ "$mtime" -gt "$latest_time" ]]; then
				latest_time="$mtime"
				latest="$ver"
			fi
		done
		echo "$latest"
	)
	return 0
}

cmd_install() {
	local version="${1:-}"
	if [[ -z "$version" ]]; then
		print_error "Usage: opencode-sandbox install <version>"
		print_info "Example: opencode-sandbox install 1.3.0"
		return 1
	fi

	local version_dir="${SANDBOX_ROOT}/${version}"
	if [[ -d "$version_dir/node_modules" ]]; then
		print_info "OpenCode ${version} already installed in sandbox"
		local bin_path
		bin_path=$(_sandbox_bin "$version") || true
		if [[ -n "$bin_path" ]]; then
			local installed_ver
			installed_ver=$("$bin_path" --version 2>/dev/null || echo "unknown")
			print_info "Installed version: ${installed_ver}"
		fi
		return 0
	fi

	mkdir -p "$version_dir"

	print_info "Installing OpenCode ${version} to sandbox..."
	if npm install --prefix "$version_dir" "opencode-ai@${version}" 2>&1; then
		local bin_path
		bin_path=$(_sandbox_bin "$version") || true
		if [[ -n "$bin_path" ]]; then
			local installed_ver
			installed_ver=$("$bin_path" --version 2>/dev/null || echo "unknown")
			print_success "OpenCode ${installed_ver} installed to sandbox"
			print_info "Binary: ${bin_path}"
			print_info "Run with: aidevops opencode-sandbox run ${version}"
		else
			print_warning "Package installed but binary not found at expected path"
			print_info "Check: ls ${version_dir}/node_modules/.bin/"
		fi
	else
		print_error "Failed to install OpenCode ${version}"
		rm -rf "$version_dir"
		return 1
	fi

	# Create isolated config/data dirs
	mkdir -p "${version_dir}/config/opencode"
	mkdir -p "${version_dir}/data/opencode"

	# Copy production opencode.json as starting point (if it exists)
	local prod_config
	for candidate in "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/config.json"; do
		if [[ -f "$candidate" ]]; then
			prod_config="$candidate"
			break
		fi
	done
	if [[ -n "${prod_config:-}" ]]; then
		cp "$prod_config" "${version_dir}/config/opencode/opencode.json"
		print_info "Copied production config as starting point"
	fi

	return 0
}

cmd_run() {
	local version="${1:-}"
	if [[ -z "$version" ]]; then
		version=$(_latest_sandbox)
		if [[ -z "$version" ]]; then
			print_error "No sandbox versions installed"
			print_info "Install one: aidevops opencode-sandbox install <version>"
			return 1
		fi
		print_info "Using most recent sandbox: ${version}"
	fi

	local bin_path
	bin_path=$(_sandbox_bin "$version") || {
		print_error "OpenCode ${version} not installed in sandbox"
		print_info "Install it: aidevops opencode-sandbox install ${version}"
		return 1
	}

	local version_dir="${SANDBOX_ROOT}/${version}"
	mkdir -p "${version_dir}/config/opencode" "${version_dir}/data/opencode"

	print_info "Launching OpenCode ${version} in sandbox..."
	print_info "Config: ${version_dir}/config/"
	print_info "Data:   ${version_dir}/data/"
	print_info "Production install is untouched."
	echo ""

	# Launch with isolated XDG dirs
	XDG_CONFIG_HOME="${version_dir}/config" \
		XDG_DATA_HOME="${version_dir}/data" \
		"$bin_path"

	return 0
}

cmd_list() {
	if [[ ! -d "$SANDBOX_ROOT" ]]; then
		print_info "No sandbox versions installed"
		return 0
	fi

	# Run the glob loop in a subshell to contain shopt -s nullglob — prevents
	# leakage if set -e causes early exit before shopt -u nullglob can restore.
	local list_output
	list_output=$(
		shopt -s nullglob
		for dir in "${SANDBOX_ROOT}"/*/; do
			local ver
			ver=$(basename "$dir")
			local bin_path
			bin_path=$(_sandbox_bin "$ver") || true
			local installed_ver="(binary not found)"
			if [[ -n "$bin_path" ]]; then
				installed_ver=$("$bin_path" --version 2>/dev/null || echo "unknown")
			fi
			local has_auth="no"
			if [[ -f "${dir}/data/opencode/auth.json" ]]; then
				has_auth="yes"
			fi
			printf '  %-12s  version=%-10s  auth.json=%s\n' "$ver" "$installed_ver" "$has_auth"
		done
	)

	if [[ -z "$list_output" ]]; then
		print_info "No sandbox versions installed"
	else
		printf '%s\n' "$list_output"
	fi

	local prod_ver
	prod_ver=$(opencode --version 2>/dev/null || echo "not installed")
	echo ""
	print_info "Production OpenCode: ${prod_ver}"

	return 0
}

cmd_check() {
	local version="${1:-}"
	if [[ -z "$version" ]]; then
		version=$(_latest_sandbox)
		if [[ -z "$version" ]]; then
			print_error "No sandbox versions installed"
			return 1
		fi
	fi

	local version_dir="${SANDBOX_ROOT}/${version}"
	local auth_file="${version_dir}/data/opencode/auth.json"

	if [[ ! -f "$auth_file" ]]; then
		print_info "No auth.json in sandbox ${version} — OAuth not yet configured"
		print_info "Run the sandbox first: aidevops opencode-sandbox run ${version}"
		return 0
	fi

	print_info "Auth entries in sandbox ${version}:"
	python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for k, v in d.items():
    t = v.get('type', '?') if isinstance(v, dict) else '?'
    has_access = bool(v.get('access', '')) if isinstance(v, dict) else False
    has_refresh = bool(v.get('refresh', '')) if isinstance(v, dict) else False
    print(f'  {k}: type={t} has_access={has_access} has_refresh={has_refresh}')
" "$auth_file" 2>/dev/null || {
		print_warning "Could not parse auth.json (python3 required)"
		return 1
	}

	return 0
}

cmd_clean() {
	local version="${1:-}"
	if [[ -z "$version" ]]; then
		print_error "Usage: opencode-sandbox clean <version|all>"
		return 1
	fi

	if [[ "$version" == "all" ]]; then
		if [[ -d "$SANDBOX_ROOT" ]]; then
			local count
			count=$(find "$SANDBOX_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
			rm -rf "$SANDBOX_ROOT"
			print_success "Removed all ${count} sandbox version(s)"
		else
			print_info "No sandboxes to clean"
		fi
		return 0
	fi

	local version_dir="${SANDBOX_ROOT}/${version}"
	if [[ -d "$version_dir" ]]; then
		rm -rf "$version_dir"
		print_success "Removed sandbox ${version}"
	else
		print_info "Sandbox ${version} not found"
	fi

	return 0
}

main() {
	local cmd="${1:-help}"
	if [[ $# -gt 0 ]]; then shift; fi

	case "$cmd" in
	install) cmd_install "$@" ;;
	run | launch) cmd_run "$@" ;;
	list | ls) cmd_list "$@" ;;
	check | status) cmd_check "$@" ;;
	clean | remove | rm) cmd_clean "$@" ;;
	help | -h | --help) show_help ;;
	*)
		print_error "Unknown command: $cmd"
		show_help
		return 1
		;;
	esac
}

main "$@"
