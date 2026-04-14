#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# bash-upgrade-helper.sh — detect, advise, and install modern bash on macOS
# =============================================================================
# Self-contained: deliberately does NOT source shared-constants.sh
# (chicken-and-egg: shared-constants.sh re-exec guard uses this output).
#
# macOS ships /bin/bash 3.2.57 (GPLv2 license; Apple cannot upgrade it).
# Framework scripts target bash 4+. This helper detects the drift and
# provides an automated upgrade path via Homebrew.
#
# Subcommands:
#   check    Emit advisory if running bash < 4 (always exits 0)
#   status   Show current bash version and Homebrew bash path/version
#   install  Install bash 5+ via Homebrew (macOS only)
#   upgrade  Alias for install (idempotent)
#   path     Print path to a modern bash (4+), empty + exit 1 if none found
#
# Usage: bash-upgrade-helper.sh <subcommand>
#
# Environment:
#   AIDEVOPS_BASH_REEXECED=1   Set by shared-constants.sh re-exec guard to
#                               prevent infinite re-exec loops.
#
# References: GH#18830, GH#18950 (t2087)

set -euo pipefail

# =============================================================================
# Internal helpers — all bash 3.2 compatible (no declare -A, mapfile, ${var,,})
# =============================================================================

_current_bash_major() {
	# BASH_VERSINFO is a read-only indexed array available in all bash versions.
	printf '%s' "${BASH_VERSINFO[0]}"
	return 0
}

_current_bash_version() {
	printf '%s' "${BASH_VERSION:-unknown}"
	return 0
}

# Print path to the first modern bash found via Homebrew candidate paths.
# Returns empty string (not exit 1) so callers can [[ -z ]] test it.
_brew_bash_path() {
	local c
	for c in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash; do
		if [[ -x "$c" ]]; then
			printf '%s' "$c"
			return 0
		fi
	done
	printf ''
	return 0
}

_brew_bash_version() {
	local brew_bash
	brew_bash=$(_brew_bash_path)
	if [[ -z "$brew_bash" ]]; then
		printf ''
		return 0
	fi
	# Execute brew bash minimally to read its own BASH_VERSION.
	# Single quotes are intentional: $BASH_VERSION must expand inside brew bash,
	# not in the current (possibly 3.2) shell. SC2016 suppressed for this reason.
	# shellcheck disable=SC2016
	"$brew_bash" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null || printf ''
	return 0
}

_needs_upgrade() {
	local major
	major=$(_current_bash_major)
	[[ "$major" -lt 4 ]]
	return $?
}

_is_macos() {
	[[ "$(uname -s)" == "Darwin" ]]
	return $?
}

_brew_available() {
	command -v brew >/dev/null 2>&1
	return $?
}

# =============================================================================
# Subcommands
# =============================================================================

cmd_check() {
	# Always exits 0. Emits advisory to stderr when bash < 4 detected.
	if ! _needs_upgrade; then
		return 0
	fi

	local brew_path current_ver
	current_ver=$(_current_bash_version)
	brew_path=$(_brew_bash_path)

	printf 'BASH_DRIFT: running bash %s (< 4). Framework scripts require bash 4+.\n' "$current_ver" >&2

	if [[ -n "$brew_path" ]]; then
		local brew_ver
		brew_ver=$(_brew_bash_version)
		printf 'Modern bash %s found at: %s\n' "${brew_ver:-unknown}" "$brew_path" >&2
		printf 'To make it the default login shell:\n' >&2
		printf '  echo "%s" | sudo tee -a /etc/shells && chsh -s "%s"\n' "$brew_path" "$brew_path" >&2
	elif _is_macos && _brew_available; then
		printf 'Install via Homebrew: bash-upgrade-helper.sh install\n' >&2
	elif _is_macos; then
		printf 'Install Homebrew first (https://brew.sh), then: bash-upgrade-helper.sh install\n' >&2
	fi

	return 0
}

cmd_status() {
	local current_ver brew_path brew_ver status_str
	current_ver=$(_current_bash_version)
	brew_path=$(_brew_bash_path)
	brew_ver=$(_brew_bash_version)

	printf 'current: %s\n' "$current_ver"

	if [[ -n "$brew_path" ]]; then
		printf 'homebrew: %s  (%s)\n' "$brew_path" "${brew_ver:-unknown}"
	else
		printf 'homebrew: not installed\n'
	fi

	if _needs_upgrade; then
		printf 'status: drift — bash < 4 detected\n'
	else
		printf 'status: ok — bash 4+ in use\n'
	fi

	return 0
}

cmd_install() {
	if ! _is_macos; then
		printf 'ERROR: install subcommand is macOS-only. Use your Linux package manager.\n' >&2
		return 1
	fi

	if ! _brew_available; then
		printf 'ERROR: Homebrew not found. Install from https://brew.sh first.\n' >&2
		return 1
	fi

	local brew_path
	brew_path=$(_brew_bash_path)

	if [[ -n "$brew_path" ]]; then
		printf 'bash already installed via Homebrew at: %s\n' "$brew_path"
		printf 'Upgrading to latest...\n'
		HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade bash 2>/dev/null || true
		brew_path=$(_brew_bash_path)
		printf 'bash at %s\n' "${brew_path:-unknown}"
	else
		printf 'Installing bash via Homebrew...\n'
		HOMEBREW_NO_AUTO_UPDATE=1 brew install bash
		brew_path=$(_brew_bash_path)
		if [[ -z "$brew_path" ]]; then
			printf 'ERROR: installation succeeded but bash not found at expected paths.\n' >&2
			return 1
		fi
		printf 'Installed at: %s\n' "$brew_path"
	fi

	printf '\nTo set as default login shell (requires sudo):\n'
	printf '  echo "%s" | sudo tee -a /etc/shells\n' "$brew_path"
	printf '  chsh -s "%s"\n' "$brew_path"
	printf '\nTo use in framework scripts without changing login shell, the\n'
	printf 'shared-constants.sh re-exec guard will auto-detect it.\n'

	return 0
}

cmd_upgrade() {
	# Alias for install — both are idempotent
	cmd_install
	return $?
}

cmd_path() {
	local brew_path
	brew_path=$(_brew_bash_path)
	if [[ -n "$brew_path" ]]; then
		printf '%s\n' "$brew_path"
		return 0
	fi
	# No modern bash found — exit 1 for scripted checks
	return 1
}

# =============================================================================
# Dispatch
# =============================================================================

usage() {
	cat >&2 <<'EOF'
Usage: bash-upgrade-helper.sh <subcommand>

Subcommands:
  check    Emit advisory if bash < 4 (always exits 0; safe for setup hooks)
  status   Show current bash and Homebrew bash versions
  install  Install bash 5+ via Homebrew (macOS only, idempotent)
  upgrade  Alias for install
  path     Print path to modern bash (exit 1 if none found)

Environment variables:
  AIDEVOPS_BASH_REEXECED=1   Skip re-exec (set by shared-constants.sh guard)
EOF
	return 0
}

main() {
	local subcmd="${1:-}"
	case "$subcmd" in
	check) cmd_check ;;
	status) cmd_status ;;
	install) cmd_install ;;
	upgrade) cmd_upgrade ;; # SC2119: no args — upgrade is an alias for install
	path) cmd_path ;;
	help | --help | -h)
		usage
		return 0
		;;
	"")
		printf 'ERROR: subcommand required\n' >&2
		usage
		return 1
		;;
	*)
		printf 'ERROR: unknown subcommand: %s\n' "$subcmd" >&2
		usage
		return 1
		;;
	esac
	return $?
}

main "$@"
