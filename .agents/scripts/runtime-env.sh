#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Portable PATH composition and tool resolution. Tools are resolved through
# PATH only: no distro-specific roots (FHS, Homebrew, or Nix) are ever placed
# ahead of the inherited PATH, so user-managed toolchains (mise, nvm, corepack,
# Nix profiles, Homebrew-in-~) win over older system copies.

# Generic last-resort roots, appended only when they exist on this host. They
# exist so a daemon started with an empty or minimal PATH can still find basic
# tools; they never shadow inherited entries.
AIDEVOPS_SYSTEM_PATH_FALLBACK="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Compose a PATH from colon-separated segments, in argument order.
# Drops empty and relative entries, duplicates, missing directories (when
# AIDEVOPS_PATH_KEEP_MISSING is not 1), and immutable runtime-bundle paths.
# Usage: aidevops_compose_path "<leading dirs>" "<inherited PATH>" "<fallback dirs>"
aidevops_compose_path() {
	local _acp_result=""
	local _acp_segment=""
	local _acp_dir=""
	local _acp_keep_missing="${AIDEVOPS_PATH_KEEP_MISSING:-0}"
	local -a _acp_dirs=()
	for _acp_segment in "$@"; do
		[[ -n "$_acp_segment" ]] || continue
		IFS=':' read -r -a _acp_dirs <<<"$_acp_segment"
		for _acp_dir in "${_acp_dirs[@]}"; do
			[[ "$_acp_dir" == /* ]] || continue
			case "$_acp_dir" in
			*/.aidevops/runtime-bundles/*) continue ;;
			esac
			if [[ "$_acp_keep_missing" != "1" && ! -d "$_acp_dir" ]]; then
				continue
			fi
			case ":${_acp_result}:" in
			*":${_acp_dir}:"*) continue ;;
			esac
			_acp_result="${_acp_result:+${_acp_result}:}${_acp_dir}"
		done
	done
	printf '%s' "$_acp_result"
	return 0
}

# Normalise an inherited PATH for non-login environments: keep its order,
# de-duplicate, and append generic system roots only as a fallback.
aidevops_runtime_path() {
	local input_path="${1:-${PATH:-}}"
	local _arp_fallback=""
	# Inherited entries are kept even if missing (they may appear later, e.g.
	# a mounted toolchain); fallback roots are only added when present.
	_arp_fallback=$(aidevops_compose_path "$AIDEVOPS_SYSTEM_PATH_FALLBACK")
	AIDEVOPS_PATH_KEEP_MISSING=1 aidevops_compose_path "$input_path" "$_arp_fallback"
	return 0
}

# PATH for long-lived service definitions (launchd EnvironmentVariables,
# systemd Environment=, cron): aidevops-owned dirs, then the installing user's
# PATH (their toolchain wins), then generic system roots as fallback only.
# Missing, relative, duplicate and runtime-bundle entries are dropped.
aidevops_service_path() {
	local input_path="${1:-${PATH:-}}"
	local stable_path=""
	if [[ -n "${HOME:-}" ]]; then
		stable_path="${HOME}/.bun/bin:${HOME}/.local/bin:${HOME}/.aidevops/agents/scripts:${HOME}/.aidevops/bin"
	fi
	aidevops_compose_path "$stable_path" "$input_path" \
		"/opt/homebrew/bin:${AIDEVOPS_SYSTEM_PATH_FALLBACK}"
	return 0
}

# Emit a systemd `Environment="PATH=..."` directive built from the installing
# user's PATH (escaped for systemd: backslash, double quote, % specifiers).
aidevops_systemd_path_env() {
	local value=""
	value=$(aidevops_service_path "${1:-${PATH:-}}")
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//%/%%}"
	printf 'Environment="PATH=%s"\n' "$value"
	return 0
}

# Backward-compatible name used by launchd plist generators.
aidevops_launchd_sanitized_path() {
	aidevops_service_path "$@"
	return 0
}

# Return 0 when the current user cannot modify a directory or any ancestor.
# Uses shell builtins only (no PATH lookup). As root, require root ownership.
aidevops_dir_chain_is_trusted() {
	local dir="$1"
	local physical=""
	physical=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
	while :; do
		if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
			[[ -O "$physical" ]] || return 1
		else
			[[ -w "$physical" ]] && return 1
		fi
		[[ "$physical" == "/" ]] && break
		physical="${physical%/*}"
		[[ -n "$physical" ]] || physical="/"
	done
	return 0
}

# Resolve a tool through PATH for trust-sensitive callers: accept the first
# PATH entry whose executable and directory chain the current user cannot
# modify (root-owned when running as root). No fixed distro roots, so the
# same rule works on macOS, FHS Linux and Nix-based systems.
# Usage: aidevops_resolve_trusted_tool <name> [search_path]
aidevops_resolve_trusted_tool() {
	local tool="$1"
	local search_path="${2:-${PATH:-}}"
	local dir=""
	local candidate=""
	local -a dirs=()
	[[ "$tool" =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
	IFS=':' read -r -a dirs <<<"$search_path"
	for dir in "${dirs[@]}"; do
		[[ "$dir" == /* ]] || continue
		candidate="${dir%/}/${tool}"
		[[ -f "$candidate" && -x "$candidate" ]] || continue
		if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
			[[ -O "$candidate" ]] || continue
		else
			[[ -w "$candidate" ]] && continue
		fi
		aidevops_dir_chain_is_trusted "$dir" || continue
		printf '%s' "$candidate"
		return 0
	done
	return 1
}

# Return 0 when a resolved candidate is an aidevops Git shim (or a symlink to one).
aidevops_is_git_shim() {
	local candidate="$1"
	local resolved="$candidate"
	local directory=""
	local link=""
	local hops=0
	while [[ -L "$resolved" && "$hops" -lt 40 ]]; do
		directory=$(cd "${resolved%/*}" && pwd -P) || return 1
		link=$(readlink "$resolved") || return 1
		case "$link" in
		/*) resolved="$link" ;;
		*) resolved="${directory}/${link}" ;;
		esac
		hops=$((hops + 1))
	done
	[[ -L "$resolved" ]] && return 0
	directory=$(cd "${resolved%/*}" && pwd -P) || return 0
	[[ -f "${directory}/canonical-git-command-guard.py" ]] && return 0
	[[ -f "${directory}/../canonical-git-command-guard.py" && "${directory##*/}" == safe-bin ]] && return 0
	return 1
}

# Resolve native Git from PATH. Do not use plain `command -v`: framework shims
# intentionally lead PATH. Follow symlinks and reject every deployed/source
# copy of the shim. AIDEVOPS_REAL_GIT_BIN (operator override) wins.
aidevops_resolve_native_git() {
	local candidate=""
	if [[ -n "${AIDEVOPS_REAL_GIT_BIN:-}" ]]; then
		printf '%s' "$AIDEVOPS_REAL_GIT_BIN"
		return 0
	fi
	while IFS= read -r candidate; do
		[[ "$candidate" == /* && -f "$candidate" && -x "$candidate" ]] || continue
		aidevops_is_git_shim "$candidate" && continue
		printf '%s' "$candidate"
		return 0
	done < <(type -a -p git 2>/dev/null)
	return 1
}

PATH=$(aidevops_runtime_path "${PATH:-}")
export PATH
if [[ -z "${AIDEVOPS_REAL_GIT_BIN:-}" ]]; then
	AIDEVOPS_REAL_GIT_BIN=$(aidevops_resolve_native_git) || AIDEVOPS_REAL_GIT_BIN=""
	[[ -z "$AIDEVOPS_REAL_GIT_BIN" ]] || export AIDEVOPS_REAL_GIT_BIN
fi
return 0
