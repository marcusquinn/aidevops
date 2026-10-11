#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Portable PATH composition and tool resolution. Tools are resolved through
# PATH only: no distro-specific roots (FHS, Homebrew, or Nix) are ever placed
# ahead of the inherited PATH, so user-managed toolchains (mise, nvm, corepack,
# Nix profiles, Homebrew-in-~) win over older system copies.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	printf 'runtime-env.sh is a source-only library\n' >&2
	exit 2
fi

# Generic last-resort roots, appended only when they exist on this host. They
# exist so a daemon started with an empty or minimal PATH can still find basic
# tools; they never shadow inherited entries.
AIDEVOPS_SYSTEM_PATH_FALLBACK="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Fallback for launchd/cron entrypoints, which may start with an empty PATH:
# package-manager roots first so e.g. Homebrew bash 5 wins over /bin/bash 3.2.
# Selected by setting AIDEVOPS_PATH_PROFILE=daemon before sourcing this file:
#   AIDEVOPS_PATH_PROFILE=daemon
#   source "${BASH_SOURCE[0]%/*}/runtime-env.sh"
AIDEVOPS_DAEMON_PATH_FALLBACK="/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:${AIDEVOPS_SYSTEM_PATH_FALLBACK}"

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
			while [[ "$_acp_dir" != / && "$_acp_dir" == */ ]]; do
				_acp_dir="${_acp_dir%/}"
			done
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
	local _arp_fallback="$AIDEVOPS_SYSTEM_PATH_FALLBACK"
	[[ "${AIDEVOPS_PATH_PROFILE:-}" != "daemon" ]] || _arp_fallback="$AIDEVOPS_DAEMON_PATH_FALLBACK"
	# Inherited entries are kept even if missing (they may appear later, e.g.
	# a mounted toolchain); fallback roots are only added when present.
	_arp_fallback=$(aidevops_compose_path "$_arp_fallback")
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
	stable_path=$(AIDEVOPS_PATH_KEEP_MISSING=1 aidevops_compose_path "$stable_path")
	input_path=$(aidevops_compose_path "$input_path" "$AIDEVOPS_DAEMON_PATH_FALLBACK")
	AIDEVOPS_PATH_KEEP_MISSING=1 aidevops_compose_path "$stable_path" "$input_path"
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

# Bootstrap metadata uses only the shell's standard utility PATH, isolated
# from caller PATH and portable-stat's cached state.
aidevops_bootstrap_metadata() (
	local candidate="$1"
	PATH=$(command -p getconf PATH) || return 1
	export PATH
	unset _PORTABLE_STAT_LOADED
	# shellcheck source=portable-stat.sh
	source "${BASH_SOURCE[0]%/*}/portable-stat.sh" || return 1
	_stat_batch '%u %a' "$candidate" || return 1
	return 0
)

# Bootstrap only: root ownership, no group/other writes; sticky ancestors allowed.
aidevops_dir_chain_is_trusted() {
	local dir="$1"
	local physical=""
	local metadata=""
	local uid=""
	local mode=""
	local current="$dir"
	local target=""
	local hops="${2:-0}"
	[[ -n "$dir" && "$dir" == /* ]] || return 1
	[[ "$hops" -lt 40 ]] || return 1
	physical=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
	# A sticky shared dir (e.g. /tmp) never holds trusted tools; it is only
	# acceptable as an ancestor (e.g. /nix/store). Matters as root, where -O
	# alone cannot see group/world-writable modes.
	[[ -k "$physical" ]] && return 1
	# Check logical prefixes too: resolving first must not conceal an editable
	# intermediate symlink or a link target reached through an untrusted chain.
	while :; do
		metadata=$(aidevops_bootstrap_metadata "$current") || return 1
		read -r uid mode <<<"$metadata"
		[[ "$uid" == 0 && "$mode" =~ ^[0-7]+$ ]] || return 1
		if [[ -L "$current" ]]; then
			target=$(command -p readlink "$current") || return 1
			[[ "$target" == /* ]] || target="${current%/*}/$target"
			aidevops_dir_chain_is_trusted "$target" "$((hops + 1))" || return 1
		elif (( (8#$mode & 0022) != 0 )); then
			[[ -k "$current" ]] || return 1
		fi
		[[ "$current" == / ]] && break
		current="${current%/*}"
		[[ -n "$current" ]] || current=/
	done
	while :; do
		metadata=$(aidevops_bootstrap_metadata "$physical") || return 1
		read -r uid mode <<<"$metadata"
		[[ "$uid" == 0 && "$mode" =~ ^[0-7]+$ ]] || return 1
		if (( (8#$mode & 0022) != 0 )); then
			[[ -k "$physical" ]] || return 1
		fi
		[[ "$physical" == "/" ]] && break
		physical="${physical%/*}"
		[[ -n "$physical" ]] || physical="/"
	done
	return 0
}

# Resolve a tool through PATH for trust-sensitive callers: accept the first
# PATH entry whose executable and directory chain are root-controlled.
# No fixed distro roots, so the
# same rule works on macOS, FHS Linux and Nix-based systems.
# Usage: aidevops_resolve_trusted_tool <name> [search_path]
aidevops_resolve_trusted_tool() {
	local tool="$1"
	local search_path="${2-${PATH:-}}"
	local candidate=""
	local physical=""
	local library="${BASH_SOURCE[0]%/*}/trusted_executable.py"
	local metadata=""
	local uid=""
	local mode=""
	[[ "$tool" =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
	while IFS= read -r candidate; do
		[[ "$candidate" == /* && -f "$candidate" && -x "$candidate" ]] || continue
		physical=$(aidevops_physical_path "$candidate" 1) || continue
		metadata=$(aidevops_bootstrap_metadata "$physical") || continue
		read -r uid mode <<<"$metadata"
		[[ "$uid" == 0 && "$mode" =~ ^[0-7]+$ ]] || continue
		(( (8#$mode & 0022) == 0 )) || continue
		aidevops_dir_chain_is_trusted "${candidate%/*}" || continue
		aidevops_dir_chain_is_trusted "${physical%/*}" || continue
		if [[ "$#" -gt 1 ]]; then
			"$physical" -I -S -B "$library" "$tool" "$search_path"
		else
			"$physical" -I -S -B "$library" "$tool"
		fi
		return $?
	done < <(PATH="${PATH:-}:/bin:/usr/bin" type -a -p python3 2>/dev/null)
	return 1
}

# Resolve links without ever allowing an empty dirname to mean $PWD.
aidevops_physical_path() {
	local candidate="$1"
	local directory=""
	local link=""
	local hops=0
	local trusted="${2:-0}"
	local metadata=""
	local uid=""
	local mode=""
	[[ -n "$candidate" && "$candidate" == /* ]] || return 1
	while :; do
		if [[ "$trusted" == 1 ]]; then
			aidevops_dir_chain_is_trusted "${candidate%/*}/" || return 1
			metadata=$(aidevops_bootstrap_metadata "$candidate") || return 1
			read -r uid mode <<<"$metadata"
			[[ "$uid" == 0 ]] || return 1
		fi
		directory=$(cd -P -- "${candidate%/*}/" 2>/dev/null && pwd -P) || return 1
		candidate="${directory%/}/${candidate##*/}"
		[[ -L "$candidate" ]] || break
		[[ "$hops" -lt 40 ]] || return 1
		link=$(command -p readlink "$candidate") || return 1
		case "$link" in
		/*) candidate="$link" ;;
		*) candidate="${directory}/${link}" ;;
		esac
		hops=$((hops + 1))
	done
	[[ -f "$candidate" ]] || return 1
	printf '%s' "$candidate"
	return 0
}

# Return 0 when a resolved candidate is an aidevops Git shim (or a symlink to one).
aidevops_is_git_shim() {
	local candidate="$1"
	local resolved=""
	local directory=""
	resolved=$(aidevops_physical_path "$candidate") || return 0
	directory="${resolved%/*}"
	[[ -f "${directory}/canonical-git-command-guard.py" ]] && return 0
	return 1
}

# Resolve native Git from PATH. Do not use plain `command -v`: framework shims
# intentionally lead PATH. Follow symlinks and reject every deployed/source
# copy of the shim. AIDEVOPS_REAL_GIT_BIN (operator override) wins.
aidevops_resolve_native_git() {
	local candidate=""
	local override="${AIDEVOPS_REAL_GIT_BIN:-${AIDEVOPS_REAL_GIT:-}}"
	if [[ -n "$override" ]]; then
		if [[ "$override" != /* || ! -f "$override" || ! -x "$override" ]] || aidevops_is_git_shim "$override"; then
			printf 'BLOCKED: invalid native Git override\n' >&2
			return 1
		fi
		printf '%s' "$override"
		return 0
	fi
	while IFS= read -r candidate; do
		[[ "$candidate" == /* && -f "$candidate" && -x "$candidate" ]] || continue
		aidevops_is_git_shim "$candidate" && continue
		printf '%s' "$candidate"
		return 0
	done < <(type -a -p git 2>/dev/null)
	printf 'BLOCKED: native Git unavailable on PATH\n' >&2
	return 1
}

[[ "${AIDEVOPS_RUNTIME_ENV_LIBRARY_ONLY:-0}" != 1 ]] || return 0
PATH=$(aidevops_runtime_path "${PATH:-}")
export PATH
AIDEVOPS_REAL_GIT_BIN=$(aidevops_resolve_native_git) || return 1
export AIDEVOPS_REAL_GIT_BIN
return 0
