#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Render the command prefix for printed `sudo aidevops approve ...` lines
# (GH#39027).
#
# Linux sudoers `secure_path` omits user-local bin directories. On Ubuntu and
# Debian it also omits Linuxbrew and npm/nvm prefixes, and on RHEL it omits
# /usr/local/bin. Setup falls back to ~/.local/bin when /usr/local/bin is not
# writable, so a pasted `sudo aidevops ...` fails with "command not found" on a
# default non-root Linux install. Printed commands therefore name the launcher
# whenever sudo cannot be relied on to find it.
#
# Output is limited to three forms, and matchers must accept only these
# (approval-snapshot-v2.sh, pulse-triage-evaluation.sh,
# command_policy_approval.py):
#   sudo aidevops         macOS, CLI not resolvable, or a launcher in
#                         /usr/bin, /bin, /usr/sbin or /sbin
#   sudo ~/<dirs>/aidevops  launcher under the invoking user's home. The tilde
#                         keeps usernames out of public comments; the pasting
#                         shell expands it before sudo runs.
#   sudo /<dirs>/aidevops   any other absolute launcher path
# Paths with characters outside [A-Za-z0-9._/+-], or with ./ or ../ segments,
# fall back to `sudo aidevops`.

[[ -n "${_SHARED_APPROVAL_CLI_LOADED:-}" ]] && return 0
_SHARED_APPROVAL_CLI_LOADED=1

_APPROVAL_CLI_DEFAULT_PREFIX="sudo aidevops"

# Print the launcher path that a pasted approval command should use, or nothing.
_approval_cli_launcher() {
	local launcher=""
	# Under sudo, secure_path hides user-local launchers from `command -v`.
	# SUDO_COMMAND holds the exact launcher path that sudo just ran.
	if [[ -n "${SUDO_COMMAND:-}" && "$(id -u 2>/dev/null)" == "0" ]]; then
		launcher="${SUDO_COMMAND%% *}"
		[[ "${launcher##*/}" == "aidevops" ]] || launcher=""
	fi
	if [[ -z "$launcher" ]]; then
		launcher=$(command -v aidevops 2>/dev/null) || launcher=""
	fi
	printf '%s\n' "$launcher"
	return 0
}

# Print the home directory of the person who will paste the command.
_approval_cli_user_home() {
	local sudo_user="${SUDO_USER:-}" entry="" home=""
	local user_re='^[A-Za-z0-9._-]+$'
	if [[ -n "$sudo_user" && "$sudo_user" =~ $user_re && "$(id -u 2>/dev/null)" == "0" ]]; then
		entry=$(getent passwd "$sudo_user" 2>/dev/null) || entry=""
		if [[ -n "$entry" ]]; then
			home=$(printf '%s\n' "$entry" | cut -d: -f6)
		fi
		# No getent (minimal images): read the exact passwd entry, never guess.
		if [[ -z "$home" && -r /etc/passwd ]]; then
			home=$(awk -F: -v user="$sudo_user" '$1 == user { print $6; exit }' /etc/passwd 2>/dev/null) || home=""
		fi
	fi
	if [[ -z "$home" ]]; then
		home="${HOME:-}"
	fi
	printf '%s\n' "$home"
	return 0
}

# Print the prefix for a pasteable approval command, for example
# "sudo aidevops" or "sudo ~/.local/bin/aidevops".
approval_cli_prefix() {
	local launcher="" home="" safe_re='^/[A-Za-z0-9._/+-]+$'
	if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
		printf '%s\n' "$_APPROVAL_CLI_DEFAULT_PREFIX"
		return 0
	fi
	launcher=$(_approval_cli_launcher)
	case "$launcher" in
	"" | /usr/bin/aidevops | /bin/aidevops | /usr/sbin/aidevops | /sbin/aidevops)
		printf '%s\n' "$_APPROVAL_CLI_DEFAULT_PREFIX"
		return 0
		;;
	*/./* | */../*)
		printf '%s\n' "$_APPROVAL_CLI_DEFAULT_PREFIX"
		return 0
		;;
	esac
	if ! [[ "$launcher" =~ $safe_re ]]; then
		printf '%s\n' "$_APPROVAL_CLI_DEFAULT_PREFIX"
		return 0
	fi
	home=$(_approval_cli_user_home)
	if [[ -n "$home" && "$home" != "/" && "$launcher" == "$home"/* ]]; then
		# shellcheck disable=SC2088 # Literal tilde: the pasting shell expands it.
		launcher="~/${launcher#"$home"/}"
	fi
	printf 'sudo %s\n' "$launcher"
	return 0
}

# Return 0 when $1 is one of the prefix forms approval_cli_prefix can print on
# any host. Content matchers use this to accept commands rendered elsewhere.
approval_cli_prefix_is_valid() {
	local prefix="$1" launcher=""
	local path_re='^(~/|/)([A-Za-z0-9._+-]+/)*aidevops$'
	[[ "$prefix" == "$_APPROVAL_CLI_DEFAULT_PREFIX" ]] && return 0
	[[ "$prefix" == "sudo "* ]] || return 1
	launcher="${prefix#sudo }"
	[[ "$launcher" =~ $path_re ]] || return 1
	case "/${launcher#\~/}" in
	*/./* | */../*) return 1 ;;
	esac
	return 0
}
