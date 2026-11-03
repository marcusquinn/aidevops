#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# tabby-recovery-shell-guard.sh - keep plain shells out of Tabby recovery markers.
#
# Sourced by interactive bash/zsh startup files (installed by setup_tabby).
#
# A Tabby-hosted OpenCode session reports a private marker directory
# (~/.aidevops/.agent-workspace/work/opencode-tabby-recovery/<ses_id>) as the
# tab's current directory with OSC 1337, so a crashed tab can be restored.
# Tabby also gives that reported directory to every new tab opened from the
# focused OpenCode tab and to restored plain-shell tabs, so ordinary shells
# start inside the marker. This guard moves such a shell to the session's
# project directory (falling back to $HOME). It never runs for command-string
# shells (`-c`), so managed profiles such as
# `<login-shell> -l -c 'exec aidevops opencode --tabby-shell'` still resolve
# the marker and resume the session.
#
# Opt out: AIDEVOPS_TABBY_MARKER_GUARD=0

_aidevops_tabby_marker_hint() {
	if [ -n "${_AIDEVOPS_TABBY_MARKER_HINT:-}" ]; then
		printf '%s\n' "${_AIDEVOPS_TABBY_MARKER_HINT}" >&2
	fi
	unset _AIDEVOPS_TABBY_MARKER_HINT
	if [ -n "${ZSH_VERSION:-}" ]; then
		add-zsh-hook -d precmd _aidevops_tabby_marker_hint 2>/dev/null
	fi
	return 0
}

_aidevops_tabby_marker_guard() {
	local here="${PWD:-}"
	local root=""
	local session=""
	local marker=""
	local line=""
	local directory=""
	local owner_pid=""
	local target="${HOME:-}"
	local resume="aidevops opencode --tabby-shell"

	[ "${AIDEVOPS_TABBY_MARKER_GUARD:-1}" != "0" ] || return 0
	[ -n "${HOME:-}" ] || return 0
	[ -n "$here" ] || return 0
	case "$-" in
	*i*) ;;
	*) return 0 ;;
	esac
	# Command-string shells are launchers, not user shells.
	[ -z "${BASH_EXECUTION_STRING:-}" ] || return 0
	[ -z "${ZSH_EXECUTION_STRING:-}" ] || return 0

	root="${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}/opencode-tabby-recovery"
	case "${here}/" in
	"${root}"/*) ;;
	*) return 0 ;;
	esac

	session="${here#"${root}"}"
	session="${session#/}"
	session="${session%%/*}"
	marker="${root}/${session}/recovery.json"
	if [ -n "$session" ] && [ -f "$marker" ] && [ -O "$marker" ]; then
		IFS= read -r line <"$marker" || true
		case "$line" in
		*'"directory":"'*)
			directory="${line#*\"directory\":\"}"
			directory="${directory%%\"*}"
			;;
		esac
		case "$directory" in
		/*) [ -d "$directory" ] && target="$directory" ;;
		esac
		case "$line" in
		*'"owner_pid":'*)
			owner_pid="${line#*\"owner_pid\":}"
			owner_pid="${owner_pid%%[!0-9]*}"
			;;
		esac
		case "$line" in
		*'"runtime":"v2"'*) resume="opencode2" ;;
		esac
		# A live owner means this is a new or split tab beside a running
		# session: move silently. Otherwise Tabby restored this shell from a
		# saved session, so say how to resume it.
		if [ -z "$owner_pid" ] || ! kill -0 "$owner_pid" 2>/dev/null; then
			_AIDEVOPS_TABBY_MARKER_HINT="aidevops: Tabby restored this tab from OpenCode session ${session}. Resume: cd '${root}/${session}' && ${resume}"
		fi
	fi

	builtin cd -- "$target" 2>/dev/null || builtin cd -- "$HOME" 2>/dev/null || return 0

	[ -n "${_AIDEVOPS_TABBY_MARKER_HINT:-}" ] || return 0
	if [ -n "${ZSH_VERSION:-}" ]; then
		# Defer output until the first prompt; zsh instant prompts reject
		# console output during startup.
		autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _aidevops_tabby_marker_hint && return 0
	fi
	_aidevops_tabby_marker_hint
	return 0
}

_aidevops_tabby_marker_guard
unset -f _aidevops_tabby_marker_guard
