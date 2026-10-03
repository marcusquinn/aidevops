#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Ownership checks for ambient OpenCode config paths used by setup writers.
#
# OPENCODE_CONFIG / OPENCODE_CONFIG_DIR are per-process overrides. Other tools
# export them for their own sandboxed `opencode` children, and aidevops setup
# can inherit them (for example the plugin greeting's update check, which runs
# inside such a child). Setup must write only to the user's own OpenCode config
# and never into a third-party tool's private config (GH#33046), nor into the
# aidevops-managed V2 runtime config from an opencode2 shell (GH#32738).

[[ -n "${_AIDEVOPS_OPENCODE_CONFIG_PATHS_LOADED:-}" ]] && return 0
_AIDEVOPS_OPENCODE_CONFIG_PATHS_LOADED=1

# Succeeds when the path belongs to an aidevops-managed OpenCode V2 runtime.
opencode_config_path_is_v2_owned() {
	local candidate="$1"
	local v2_root="${AIDEVOPS_OPENCODE_V2_ROOT:-${HOME}/.aidevops/runtimes/opencode-v2}"
	local v2_config_home="${AIDEVOPS_OPENCODE_V2_CONFIG_HOME:-${v2_root}/config}"
	case "$candidate" in
	"$v2_root" | "$v2_root"/* | "$v2_config_home" | "$v2_config_home"/*) return 0 ;;
	*/.aidevops/runtimes/opencode-v2 | */.aidevops/runtimes/opencode-v2/*) return 0 ;;
	esac
	return 1
}

# Print the physical path, resolving symlinks where the path exists. Falls
# back to the lexical path so a missing file still compares predictably.
_opencode_config_physical_path() {
	local path="$1"
	local resolved=""
	if command -v realpath >/dev/null 2>&1 && resolved=$(realpath "$path" 2>/dev/null); then
		printf '%s\n' "$resolved"
		return 0
	fi
	local dir="${path%/*}"
	local base="${path##*/}"
	[[ "$dir" == "$path" ]] && dir="."
	if resolved=$(cd -P "$dir" 2>/dev/null && pwd -P); then
		printf '%s/%s\n' "$resolved" "$base"
		return 0
	fi
	printf '%s\n' "$path"
	return 0
}

# Directories that hold the user's own OpenCode config. The opt-in
# AIDEVOPS_OPENCODE_USER_CONFIG (a file or directory) keeps a deliberately
# relocated main config writable, for example a dotfiles volume.
_opencode_config_user_roots() {
	printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" \
		"$HOME/.config/opencode" \
		"$HOME/.opencode" \
		"$HOME/Library/Application Support/opencode"
	[[ -n "${AIDEVOPS_OPENCODE_USER_CONFIG:-}" ]] && printf '%s\n' "$AIDEVOPS_OPENCODE_USER_CONFIG"
	return 0
}

# Succeeds when the candidate (or its physical path) is a user-owned root,
# lies under one, or is the physical target of a root's opencode.json(c).
_opencode_config_path_is_user_owned() {
	local candidate="$1"
	local physical=""
	physical=$(_opencode_config_physical_path "$candidate")
	local root="" form="" path=""
	while IFS= read -r root; do
		[[ -n "$root" ]] || continue
		for form in "$root" "$(_opencode_config_physical_path "$root")"; do
			for path in "$candidate" "$physical"; do
				case "$path" in
				"$form" | "$form"/*) return 0 ;;
				esac
			done
		done
		for form in "$root/opencode.json" "$root/opencode.jsonc"; do
			[[ -e "$form" && "$(_opencode_config_physical_path "$form")" == "$physical" ]] && return 0
		done
	done < <(_opencode_config_user_roots)
	return 1
}

# Print the opt-in config file (AIDEVOPS_OPENCODE_USER_CONFIG may name the
# file or its directory). This keeps a relocated config reachable even when the
# ambient OPENCODE_CONFIG is scrubbed, as the update check does for setup.
opencode_config_user_opt_in_path() {
	local opt_in="${AIDEVOPS_OPENCODE_USER_CONFIG:-}"
	[[ -n "$opt_in" ]] || return 0
	if [[ -d "$opt_in" ]]; then
		printf '%s\n' "$opt_in/opencode.json"
	else
		printf '%s\n' "$opt_in"
	fi
	return 0
}

# Print the ambient path when setup may write through it; print nothing when it
# belongs to the V2 runtime or to another program. The skip notice goes to
# stderr because callers capture stdout.
opencode_config_ambient_write_path() {
	local candidate="$1"
	[[ -n "$candidate" ]] || return 0
	opencode_config_path_is_v2_owned "$candidate" && return 0
	if _opencode_config_path_is_user_owned "$candidate"; then
		printf '%s\n' "$candidate"
		return 0
	fi
	printf '[INFO] Ignoring ambient OpenCode config outside the user config home: %s (set AIDEVOPS_OPENCODE_USER_CONFIG to opt in)\n' \
		"$candidate" >&2
	return 0
}
