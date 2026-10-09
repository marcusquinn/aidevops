#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Browser MCP launcher (GH#34111). MCP clients start stdio servers in the
# caller's project directory, often a canonical checkout. Raw relative paths
# such as `page.screenshot({ path: 'x.png' })` in Playwright run-code or
# Playwriter execute calls resolve against the server process cwd, not
# --output-dir, so this launcher runs the server from a private per-launch
# artifact directory under the aidevops temp workspace.
#
# Usage (MCP config):
#   bash browser-mcp-launcher.sh playwright npx -y @playwright/mcp@<pin> [args...]
#   bash browser-mcp-launcher.sh playwriter <playwriter command...>
# Playwright also receives --output-dir for its managed artifacts; Playwriter
# has no output-dir option, so it receives only the private cwd.
# The package invocation stays visible so mcp-diagnose.sh can version-check it.
# stdout is reserved for the MCP protocol; diagnostics go to stderr.
# Absolute or traversal paths in raw code are not confined; that needs an OS
# sandbox. Artifacts age out through system-cleanup.sh temp retention.

set -euo pipefail

_launcher_fail() {
	local message="$1"
	printf 'browser-mcp-launcher: %s\n' "$message" >&2
	return 1
}

_launcher_artifact_root() {
	local server="$1"
	local default_root="${HOME:?}/.aidevops/.agent-workspace/tmp"
	local temp_root="${AIDEVOPS_TEMP_DIR:-$default_root}"
	[[ "$temp_root" == /* ]] || temp_root="$default_root"
	printf '%s/mcp/%s\n' "$temp_root" "$server"
	return 0
}

_launcher_inside_git_worktree() {
	local directory="$1"
	# Check the nearest existing ancestor so a refused root is never created.
	while [[ ! -d "$directory" && "$directory" != "/" ]]; do
		directory=$(dirname -- "$directory")
	done
	command -v git >/dev/null 2>&1 || return 1
	git -C "$directory" rev-parse --is-inside-work-tree >/dev/null 2>&1
	return $?
}

main() {
	local server="${1:-}"
	case "$server" in
	playwright | playwriter) shift ;;
	*)
		_launcher_fail "first argument must be playwright or playwriter"
		return 1
		;;
	esac
	[[ "$#" -gt 0 ]] || {
		_launcher_fail "missing MCP server command"
		return 1
	}
	local root session_dir
	root=$(_launcher_artifact_root "$server")
	if _launcher_inside_git_worktree "$root"; then
		_launcher_fail "artifact root resolves inside a Git work tree; set AIDEVOPS_TEMP_DIR outside repositories"
		return 1
	fi
	umask 077
	mkdir -p -- "$root" || {
		_launcher_fail "cannot create artifact root"
		return 1
	}
	[[ -d "$root" && ! -L "$root" ]] || {
		_launcher_fail "artifact root is not a regular directory"
		return 1
	}
	# Re-check after creation in case an ancestor symlink resolves into a repo.
	if _launcher_inside_git_worktree "$root"; then
		_launcher_fail "artifact root resolves inside a Git work tree; set AIDEVOPS_TEMP_DIR outside repositories"
		return 1
	fi
	session_dir=$(mktemp -d "$root/launch-XXXXXX") || {
		_launcher_fail "cannot create per-launch artifact directory"
		return 1
	}
	cd -- "$session_dir" || return 1
	if [[ "$server" == "playwright" ]]; then
		exec "$@" --output-dir "$session_dir"
	fi
	exec "$@"
}

main "$@"
