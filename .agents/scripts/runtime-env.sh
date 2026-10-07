#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Stable Nix profiles, not /nix/store generation paths or login-shell evaluation.

aidevops_runtime_path() {
	local input_path="${1:-${PATH:-}}"
	local result="$input_path"
	local dir=""
	local account="${USER:-${LOGNAME:-}}"
	if [[ -z "$account" ]]; then
		account=$(id -un 2>/dev/null) || account=""
	fi
	for dir in "${HOME:-}/.nix-profile/bin" "${HOME:-}/.local/state/nix/profile/bin" \
		"/etc/profiles/per-user/${account}/bin" /run/wrappers/bin /run/current-system/sw/bin; do
		[[ -d "$dir" ]] || continue
		case ":${result}:" in
		*":${dir}:"*) continue ;;
		esac
		result="${result:+${result}:}${dir}"
	done
	printf '%s' "$result"
	return 0
}

# Do not resolve Git through `command -v`: framework shims intentionally lead
# PATH. Follow symlinks and reject every deployed/source copy of the shim.
aidevops_resolve_native_git() {
	local candidate=""
	local resolved=""
	local directory=""
	local link=""
	local hops=0
	if [[ -n "${AIDEVOPS_REAL_GIT_BIN:-}" ]]; then
		printf '%s' "$AIDEVOPS_REAL_GIT_BIN"
		return 0
	fi
	while IFS= read -r candidate; do
		[[ "$candidate" == /* && -f "$candidate" && -x "$candidate" ]] || continue
		resolved="$candidate"
		hops=0
		while [[ -L "$resolved" && "$hops" -lt 40 ]]; do
			directory=$(cd "${resolved%/*}" && pwd -P) || break
			link=$(readlink "$resolved") || break
			case "$link" in
			/*) resolved="$link" ;;
			*) resolved="${directory}/${link}" ;;
			esac
			hops=$((hops + 1))
		done
		[[ -L "$resolved" ]] && continue
		directory=$(cd "${resolved%/*}" && pwd -P) || continue
		[[ -f "${directory}/canonical-git-command-guard.py" ]] && continue
		[[ -f "${directory}/../canonical-git-command-guard.py" && "${directory##*/}" == safe-bin ]] && continue
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
