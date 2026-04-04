#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# platform-detect.sh — OS/platform detection and abstraction layer
#
# Usage (source this file):
#   source "$(dirname "${BASH_SOURCE[0]}")/platform-detect.sh"
#   echo "$AIDEVOPS_PLATFORM"   # macos | linux | wsl2 | windows-native
#   echo "$AIDEVOPS_SCHEDULER"  # launchd | systemd | cron
#
# Exported variables:
#   AIDEVOPS_PLATFORM         — macos | linux | wsl2 | windows-native
#   AIDEVOPS_SCHEDULER        — launchd | systemd | cron
#   AIDEVOPS_CLIPBOARD_COPY   — command to copy stdin to clipboard
#   AIDEVOPS_CLIPBOARD_PASTE  — command to paste clipboard to stdout
#   AIDEVOPS_OPEN_CMD         — command to open a URL or file
#   AIDEVOPS_FILE_SEARCH      — preferred file search command
#   AIDEVOPS_PKG_INSTALL      — package install command prefix (e.g. "brew install")
#
# Part of t1748: Linux/WSL2 platform support

# Shell safety baseline (guard against sourcing in strict-mode scripts)
# shellcheck disable=SC2034  # Variables are used by callers

_detect_linux_platform() {
	# Distinguish WSL2 from native Linux
	if grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null; then
		AIDEVOPS_PLATFORM="wsl2"
	else
		AIDEVOPS_PLATFORM="linux"
	fi
	return 0
}

_detect_linux_scheduler() {
	# Scheduler: prefer systemd user services; fall back to cron
	if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
		AIDEVOPS_SCHEDULER="systemd"
	else
		AIDEVOPS_SCHEDULER="cron"
	fi
	return 0
}

_detect_linux_clipboard() {
	# Clipboard: prefer xclip, then xsel, then wl-copy (Wayland), then clip.exe (WSL2)
	if command -v xclip >/dev/null 2>&1; then
		AIDEVOPS_CLIPBOARD_COPY="xclip -selection clipboard"
		AIDEVOPS_CLIPBOARD_PASTE="xclip -selection clipboard -o"
	elif command -v xsel >/dev/null 2>&1; then
		AIDEVOPS_CLIPBOARD_COPY="xsel --clipboard --input"
		AIDEVOPS_CLIPBOARD_PASTE="xsel --clipboard --output"
	elif command -v wl-copy >/dev/null 2>&1; then
		AIDEVOPS_CLIPBOARD_COPY="wl-copy"
		AIDEVOPS_CLIPBOARD_PASTE="wl-paste"
	elif [[ "$AIDEVOPS_PLATFORM" == "wsl2" ]] && command -v clip.exe >/dev/null 2>&1; then
		AIDEVOPS_CLIPBOARD_COPY="clip.exe"
		AIDEVOPS_CLIPBOARD_PASTE="powershell.exe -c Get-Clipboard"
	else
		AIDEVOPS_CLIPBOARD_COPY=""
		AIDEVOPS_CLIPBOARD_PASTE=""
	fi
	return 0
}

_detect_linux_open_cmd() {
	# Open URL/file: prefer xdg-open, then wslview (WSL2 bridge)
	if command -v xdg-open >/dev/null 2>&1; then
		AIDEVOPS_OPEN_CMD="xdg-open"
	elif [[ "$AIDEVOPS_PLATFORM" == "wsl2" ]] && command -v wslview >/dev/null 2>&1; then
		AIDEVOPS_OPEN_CMD="wslview"
	else
		AIDEVOPS_OPEN_CMD=""
	fi
	return 0
}

_detect_linux_file_search() {
	# File search: prefer fd, then locate, then find
	if command -v fd >/dev/null 2>&1; then
		AIDEVOPS_FILE_SEARCH="fd"
	elif command -v locate >/dev/null 2>&1; then
		AIDEVOPS_FILE_SEARCH="locate"
	else
		AIDEVOPS_FILE_SEARCH="find"
	fi
	return 0
}

_detect_linux_pkg_manager() {
	# Package manager
	if command -v apt-get >/dev/null 2>&1; then
		AIDEVOPS_PKG_INSTALL="sudo apt-get install -y"
	elif command -v brew >/dev/null 2>&1; then
		AIDEVOPS_PKG_INSTALL="brew install"
	elif command -v dnf >/dev/null 2>&1; then
		AIDEVOPS_PKG_INSTALL="sudo dnf install -y"
	elif command -v pacman >/dev/null 2>&1; then
		AIDEVOPS_PKG_INSTALL="sudo pacman -S --noconfirm"
	elif command -v apk >/dev/null 2>&1; then
		AIDEVOPS_PKG_INSTALL="sudo apk add"
	else
		AIDEVOPS_PKG_INSTALL=""
	fi
	return 0
}

_detect_macos() {
	AIDEVOPS_PLATFORM="macos"
	AIDEVOPS_SCHEDULER="launchd"
	AIDEVOPS_CLIPBOARD_COPY="pbcopy"
	AIDEVOPS_CLIPBOARD_PASTE="pbpaste"
	AIDEVOPS_OPEN_CMD="open"
	AIDEVOPS_FILE_SEARCH="mdfind"
	AIDEVOPS_PKG_INSTALL="brew install"
	return 0
}

_detect_windows() {
	AIDEVOPS_PLATFORM="windows-native"
	AIDEVOPS_SCHEDULER="cron"
	AIDEVOPS_CLIPBOARD_COPY="clip"
	AIDEVOPS_CLIPBOARD_PASTE="powershell -c Get-Clipboard"
	AIDEVOPS_OPEN_CMD="start"
	AIDEVOPS_FILE_SEARCH="find"
	AIDEVOPS_PKG_INSTALL=""
	return 0
}

_detect_unknown() {
	AIDEVOPS_PLATFORM="unknown"
	AIDEVOPS_SCHEDULER="cron"
	AIDEVOPS_CLIPBOARD_COPY=""
	AIDEVOPS_CLIPBOARD_PASTE=""
	AIDEVOPS_OPEN_CMD=""
	AIDEVOPS_FILE_SEARCH="find"
	AIDEVOPS_PKG_INSTALL=""
	return 0
}

_aidevops_detect_platform() {
	local _kernel
	_kernel="$(uname -s 2>/dev/null || echo "unknown")"

	case "$_kernel" in
	Darwin)
		_detect_macos
		;;
	Linux)
		_detect_linux_platform
		_detect_linux_scheduler
		_detect_linux_clipboard
		_detect_linux_open_cmd
		_detect_linux_file_search
		_detect_linux_pkg_manager
		;;
	MINGW* | MSYS* | CYGWIN*)
		_detect_windows
		;;
	*)
		_detect_unknown
		;;
	esac

	export AIDEVOPS_PLATFORM AIDEVOPS_SCHEDULER
	export AIDEVOPS_CLIPBOARD_COPY AIDEVOPS_CLIPBOARD_PASTE
	export AIDEVOPS_OPEN_CMD AIDEVOPS_FILE_SEARCH AIDEVOPS_PKG_INSTALL
	return 0
}

# Run detection immediately on source
_aidevops_detect_platform

# Clipboard helper: copy stdin to clipboard (platform-agnostic)
# Usage: echo "text" | aidevops_clipboard_copy
# Returns 0 on success, 1 if no clipboard tool available
aidevops_clipboard_copy() {
	if [[ -z "$AIDEVOPS_CLIPBOARD_COPY" ]]; then
		return 1
	fi
	# shellcheck disable=SC2086  # intentional word splitting for multi-word commands
	$AIDEVOPS_CLIPBOARD_COPY
	return $?
}

# Clipboard helper: paste clipboard to stdout (platform-agnostic)
# Usage: aidevops_clipboard_paste
# Returns 0 on success, 1 if no clipboard tool available
aidevops_clipboard_paste() {
	if [[ -z "$AIDEVOPS_CLIPBOARD_PASTE" ]]; then
		return 1
	fi
	# shellcheck disable=SC2086  # intentional word splitting for multi-word commands
	$AIDEVOPS_CLIPBOARD_PASTE
	return $?
}

# Open a URL or file (platform-agnostic)
# Usage: aidevops_open "https://example.com"
# Returns 0 on success, 1 if no open command available
aidevops_open() {
	local target="$1"
	if [[ -z "$AIDEVOPS_OPEN_CMD" ]]; then
		return 1
	fi
	# shellcheck disable=SC2086  # intentional word splitting for multi-word commands
	$AIDEVOPS_OPEN_CMD "$target"
	return $?
}

# When run directly (not sourced), print detected platform info
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	echo "AIDEVOPS_PLATFORM=$AIDEVOPS_PLATFORM"
	echo "AIDEVOPS_SCHEDULER=$AIDEVOPS_SCHEDULER"
	echo "AIDEVOPS_CLIPBOARD_COPY=$AIDEVOPS_CLIPBOARD_COPY"
	echo "AIDEVOPS_CLIPBOARD_PASTE=$AIDEVOPS_CLIPBOARD_PASTE"
	echo "AIDEVOPS_OPEN_CMD=$AIDEVOPS_OPEN_CMD"
	echo "AIDEVOPS_FILE_SEARCH=$AIDEVOPS_FILE_SEARCH"
	echo "AIDEVOPS_PKG_INSTALL=$AIDEVOPS_PKG_INSTALL"
fi
