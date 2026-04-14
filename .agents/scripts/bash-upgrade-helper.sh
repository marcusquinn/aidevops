#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# bash-upgrade-helper.sh — detect and install modern bash on macOS.
#
# GH#18950 (t2087): Systemic fix for the class of bash 3.2 incompatibility
# bugs (GH#18770, GH#18784, GH#18786, GH#18804, GH#18830). macOS ships
# /bin/bash 3.2.57 which has parser and set-e propagation quirks that
# bash 4+ does not. This helper automates the "install bash via Homebrew"
# fix that we previously left to users.
#
# IMPORTANT: This script MUST NOT source shared-constants.sh.
# shared-constants.sh uses this helper to decide whether to re-exec under
# modern bash, so sourcing it here would create a chicken-and-egg. This
# helper is intentionally self-contained with minimal dependencies.
#
# Subcommands:
#   check    — exit 0 if modern bash (>=4) is available; 1 if not; 2 if platform unsupported
#   status   — print current /bin/bash version, modern bash path (if any), remediation
#   install  — on macOS with Homebrew, run `brew install bash`
#   upgrade  — `brew upgrade bash` if available
#   path     — print absolute path to modern bash (empty string if none)
#
# Flags:
#   --yes / -y      — skip interactive prompt (for install/upgrade)
#   --quiet / -q    — suppress informational output (only errors)
#
# Exit codes:
#   0 — success (check: modern bash available; install/upgrade: operation succeeded)
#   1 — modern bash missing or needs upgrade
#   2 — unsupported platform (Windows native, etc.)
#   3 — Homebrew missing on macOS
#   4 — install/upgrade command failed

set -u

# -------------------------------------------------------------------
# Config: where to look for modern bash.
# -------------------------------------------------------------------

# Candidate paths for modern bash, in detection order.
# /opt/homebrew/bin/bash  — Apple Silicon Homebrew default
# /usr/local/bin/bash     — Intel macOS Homebrew default
# /home/linuxbrew/.linuxbrew/bin/bash — Linuxbrew default
_BASH_UPGRADE_CANDIDATES="/opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash"

_MIN_MAJOR_VERSION=4

_ADVISORY_DIR="${HOME}/.aidevops/advisories"
_ADVISORY_FILE="${_ADVISORY_DIR}/bash-3.2-upgrade.advisory"
_STATE_DIR="${HOME}/.aidevops/state"
_UPDATE_CHECK_STATE="${_STATE_DIR}/bash-upgrade-last-check"

# -------------------------------------------------------------------
# Logging helpers (bash 3.2 safe, no colour dependency).
# -------------------------------------------------------------------

_BU_QUIET=""

_bu_info() {
	[[ -n "$_BU_QUIET" ]] && return 0
	printf '[bash-upgrade] %s\n' "$1"
}

_bu_warn() {
	printf '[bash-upgrade] WARN: %s\n' "$1" >&2
}

_bu_error() {
	printf '[bash-upgrade] ERROR: %s\n' "$1" >&2
}

# -------------------------------------------------------------------
# Platform detection (bash 3.2 safe).
# -------------------------------------------------------------------

_bu_platform() {
	local kernel
	kernel="$(uname -s 2>/dev/null || echo unknown)"
	case "$kernel" in
	Darwin) echo "macos" ;;
	Linux) echo "linux" ;;
	CYGWIN* | MINGW* | MSYS*) echo "windows" ;;
	*) echo "unknown" ;;
	esac
}

# -------------------------------------------------------------------
# Modern-bash detection: find the first candidate >= _MIN_MAJOR_VERSION.
# Uses bash -c to extract BASH_VERSINFO from each candidate safely.
# Output: absolute path to modern bash, or empty string.
# -------------------------------------------------------------------

_bu_find_modern_bash() {
	local candidate
	local major
	for candidate in $_BASH_UPGRADE_CANDIDATES; do
		[[ -x "$candidate" ]] || continue
		# Query the candidate's major version without running it in our context.
		major=$("$candidate" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo "0")
		if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge "$_MIN_MAJOR_VERSION" ]]; then
			echo "$candidate"
			return 0
		fi
	done

	# Fall back to `brew --prefix` in case the user has an unusual prefix.
	if command -v brew >/dev/null 2>&1; then
		local brew_prefix
		brew_prefix="$(brew --prefix 2>/dev/null || echo "")"
		if [[ -n "$brew_prefix" && -x "${brew_prefix}/bin/bash" ]]; then
			major=$("${brew_prefix}/bin/bash" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo "0")
			if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge "$_MIN_MAJOR_VERSION" ]]; then
				echo "${brew_prefix}/bin/bash"
				return 0
			fi
		fi
	fi

	# Also check whichever bash is first on PATH — on Linux, this is
	# almost always a modern version, and on macOS it may find a
	# user-installed alternative.
	local path_bash
	path_bash="$(command -v bash 2>/dev/null || echo "")"
	if [[ -n "$path_bash" && -x "$path_bash" && "$path_bash" != "/bin/bash" ]]; then
		major=$("$path_bash" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo "0")
		if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge "$_MIN_MAJOR_VERSION" ]]; then
			echo "$path_bash"
			return 0
		fi
	fi

	echo ""
	return 1
}

# -------------------------------------------------------------------
# Current bash version (the bash interpreter running this script).
# -------------------------------------------------------------------

_bu_current_version() {
	echo "${BASH_VERSINFO[0]:-0}.${BASH_VERSINFO[1]:-0}.${BASH_VERSINFO[2]:-0}"
}

_bu_current_major() {
	echo "${BASH_VERSINFO[0]:-0}"
}

# -------------------------------------------------------------------
# Advisory writer.
# -------------------------------------------------------------------

_bu_write_advisory() {
	local body="$1"
	mkdir -p "$_ADVISORY_DIR" 2>/dev/null || return 1
	printf '%s\n' "$body" >"$_ADVISORY_FILE"
	return 0
}

_bu_dismiss_advisory_if_resolved() {
	# If modern bash is now available, silently dismiss any stale advisory.
	local dismissed_file="${_ADVISORY_DIR}/dismissed.txt"
	if [[ -f "$_ADVISORY_FILE" ]]; then
		rm -f "$_ADVISORY_FILE" 2>/dev/null || true
	fi
	# Also remove from dismissed.txt if the user previously dismissed it;
	# a fresh advisory should fire on next drift.
	if [[ -f "$dismissed_file" ]] && grep -qxF "bash-3.2-upgrade" "$dismissed_file" 2>/dev/null; then
		grep -vxF "bash-3.2-upgrade" "$dismissed_file" >"${dismissed_file}.tmp" 2>/dev/null || true
		mv "${dismissed_file}.tmp" "$dismissed_file" 2>/dev/null || rm -f "${dismissed_file}.tmp"
	fi
	return 0
}

# -------------------------------------------------------------------
# Subcommand: check
# Exit 0 = modern bash available, 1 = needs upgrade, 2 = unsupported platform.
# -------------------------------------------------------------------

_bu_cmd_check() {
	local platform
	platform="$(_bu_platform)"

	case "$platform" in
	windows | unknown)
		_bu_info "platform=${platform}: bash upgrade not applicable"
		return 2
		;;
	esac

	# If the current running bash is already modern, we're done.
	if [[ "$(_bu_current_major)" -ge "$_MIN_MAJOR_VERSION" ]]; then
		_bu_dismiss_advisory_if_resolved
		return 0
	fi

	# Current bash is old — is a modern bash installed somewhere?
	local modern_bash
	modern_bash="$(_bu_find_modern_bash)"
	if [[ -n "$modern_bash" ]]; then
		_bu_dismiss_advisory_if_resolved
		return 0
	fi

	return 1
}

# -------------------------------------------------------------------
# Subcommand: status
# -------------------------------------------------------------------

_bu_cmd_status() {
	local platform current_version current_major modern_bash rc
	platform="$(_bu_platform)"
	current_version="$(_bu_current_version)"
	current_major="$(_bu_current_major)"
	modern_bash="$(_bu_find_modern_bash)"

	printf 'Platform:        %s\n' "$platform"
	printf 'Current bash:    %s (major=%s)\n' "$current_version" "$current_major"
	printf 'Minimum wanted:  %s\n' "$_MIN_MAJOR_VERSION"
	if [[ -n "$modern_bash" ]]; then
		local modern_version
		modern_version="$("$modern_bash" -c 'echo "$BASH_VERSION"' 2>/dev/null || echo "unknown")"
		printf 'Modern bash:     %s (%s)\n' "$modern_bash" "$modern_version"
	else
		printf 'Modern bash:     not found\n'
	fi

	rc=0
	if [[ "$current_major" -ge "$_MIN_MAJOR_VERSION" ]] || [[ -n "$modern_bash" ]]; then
		printf 'Status:          OK\n'
	else
		printf 'Status:          UPGRADE NEEDED\n'
		case "$platform" in
		macos)
			if command -v brew >/dev/null 2>&1; then
				printf 'Remediation:     %s install\n' "$0"
				printf '                 (or: brew install bash)\n'
			else
				printf 'Remediation:     install Homebrew first\n'
				# shellcheck disable=SC2016
				printf '                   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n'
				printf '                 then: %s install\n' "$0"
			fi
			;;
		linux)
			printf 'Remediation:     use your distro package manager (apt install bash / dnf install bash)\n'
			;;
		*)
			printf 'Remediation:     unsupported platform (%s)\n' "$platform"
			;;
		esac
		rc=1
	fi

	return $rc
}

# -------------------------------------------------------------------
# Subcommand: path — print absolute path to modern bash, or empty.
# -------------------------------------------------------------------

_bu_cmd_path() {
	local modern_bash
	modern_bash="$(_bu_find_modern_bash)"
	if [[ -n "$modern_bash" ]]; then
		echo "$modern_bash"
		return 0
	fi

	if [[ "$(_bu_current_major)" -ge "$_MIN_MAJOR_VERSION" ]]; then
		# Current bash is already modern — return its path.
		command -v bash 2>/dev/null || echo ""
		return 0
	fi

	echo ""
	return 1
}

# -------------------------------------------------------------------
# Subcommand: install — brew install bash (macOS only).
# -------------------------------------------------------------------

_bu_cmd_install() {
	local yes="$1"
	local platform
	platform="$(_bu_platform)"

	case "$platform" in
	linux)
		_bu_info "linux: distro bash is already modern; no install needed"
		return 0
		;;
	windows | unknown)
		_bu_error "platform=${platform}: bash install not supported via this helper"
		return 2
		;;
	esac

	# macOS path.
	if ! command -v brew >/dev/null 2>&1; then
		_bu_error "Homebrew is not installed. Install it first:"
		printf '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n' >&2
		_bu_write_advisory "bash-3.2-upgrade | macOS needs bash 4+ via Homebrew. Install Homebrew then run: aidevops update"
		return 3
	fi

	# Already installed?
	local existing
	existing="$(_bu_find_modern_bash)"
	if [[ -n "$existing" ]]; then
		_bu_info "modern bash already installed at ${existing}"
		_bu_dismiss_advisory_if_resolved
		return 0
	fi

	if [[ -z "$yes" ]] && [[ -t 0 ]]; then
		local response
		printf 'Install modern bash via Homebrew? This fixes macOS bash 3.2 compatibility issues. [Y/n] '
		read -r response
		case "$response" in
		"" | y | Y | yes | YES) ;;
		*)
			_bu_info "install declined by user"
			_bu_write_advisory "bash-3.2-upgrade | macOS bash 3.2 detected. Run: brew install bash (or: aidevops security posture)"
			return 1
			;;
		esac
	fi

	_bu_info "running: brew install bash"
	local brew_rc=0
	brew install bash || brew_rc=$?

	# Verify via detection, not via brew's exit code. brew install can
	# return non-zero for unrelated cleanup failures (e.g. dnsmasq
	# permission errors during post-install cleanup) even when the
	# target package installed successfully. Trust the actual state.
	local verified_path
	verified_path="$(_bu_find_modern_bash)"
	if [[ -n "$verified_path" ]]; then
		if [[ "$brew_rc" -ne 0 ]]; then
			_bu_info "brew exited rc=${brew_rc} but modern bash is installed at ${verified_path} (cleanup step likely failed, install OK)"
		else
			_bu_info "brew install bash succeeded (installed at ${verified_path})"
		fi
		_bu_dismiss_advisory_if_resolved
		return 0
	fi

	_bu_error "brew install bash failed (rc=${brew_rc}, no modern bash found after install)"
	_bu_write_advisory "bash-3.2-upgrade | brew install bash FAILED. Run manually: brew install bash"
	return 4
}

# -------------------------------------------------------------------
# Subcommand: upgrade — brew upgrade bash if outdated.
# -------------------------------------------------------------------

_bu_cmd_upgrade() {
	local platform
	platform="$(_bu_platform)"

	case "$platform" in
	linux)
		_bu_info "linux: distro bash updates via package manager, not this helper"
		return 0
		;;
	windows | unknown)
		_bu_info "platform=${platform}: upgrade not applicable"
		return 2
		;;
	esac

	if ! command -v brew >/dev/null 2>&1; then
		_bu_info "Homebrew not installed; nothing to upgrade"
		return 0
	fi

	if ! _bu_find_modern_bash >/dev/null; then
		_bu_info "modern bash not installed; run 'bash-upgrade-helper.sh install' first"
		return 1
	fi

	# Only run brew upgrade if bash is actually outdated.
	if brew outdated bash >/dev/null 2>&1; then
		_bu_info "bash is up to date; no upgrade needed"
		return 0
	fi

	_bu_info "running: brew upgrade bash"
	if brew upgrade bash 2>&1; then
		_bu_info "brew upgrade bash succeeded"
		return 0
	fi

	_bu_error "brew upgrade bash failed"
	return 4
}

# -------------------------------------------------------------------
# Subcommand: update-check — cheap drift check for the update loop.
# Rate-limited to once per 24h via state file. Writes advisory if
# modern bash is outdated (brew outdated bash reports drift).
# Returns 0 always (advisories are best-effort).
# -------------------------------------------------------------------

_bu_cmd_update_check() {
	local now last_check
	now="$(date +%s 2>/dev/null || echo 0)"
	[[ "$now" =~ ^[0-9]+$ ]] || now=0

	mkdir -p "$_STATE_DIR" 2>/dev/null || return 0

	if [[ -f "$_UPDATE_CHECK_STATE" ]]; then
		last_check="$(cat "$_UPDATE_CHECK_STATE" 2>/dev/null || echo 0)"
		[[ "$last_check" =~ ^[0-9]+$ ]] || last_check=0
		# 86400 seconds = 24h
		if [[ $((now - last_check)) -lt 86400 ]]; then
			return 0
		fi
	fi

	echo "$now" >"$_UPDATE_CHECK_STATE" 2>/dev/null || true

	local platform
	platform="$(_bu_platform)"
	[[ "$platform" == "macos" ]] || return 0

	local current_major
	current_major="$(_bu_current_major)"

	# Case 1: Running under old bash, modern not installed → install advisory.
	if [[ "$current_major" -lt "$_MIN_MAJOR_VERSION" ]]; then
		if ! _bu_find_modern_bash >/dev/null; then
			_bu_write_advisory "bash-3.2-upgrade | macOS default bash is 3.2. Run: brew install bash (requires Homebrew)"
			return 0
		fi
	fi

	# Case 2: Modern bash installed but drifted behind Homebrew latest → upgrade advisory.
	if command -v brew >/dev/null 2>&1; then
		if brew outdated bash >/dev/null 2>&1; then
			# brew outdated exits 0 when there are outdated packages to show
			local outdated_info
			outdated_info="$(brew outdated bash 2>/dev/null || true)"
			if [[ -n "$outdated_info" ]]; then
				_bu_write_advisory "bash-upgrade-drift | Homebrew bash has an update available. Run: brew upgrade bash"
			fi
		fi
	fi

	return 0
}

# -------------------------------------------------------------------
# Usage / dispatch.
# -------------------------------------------------------------------

_bu_usage() {
	cat <<EOF
Usage: bash-upgrade-helper.sh <subcommand> [flags]

Subcommands:
  check           Exit 0 if modern bash (>=${_MIN_MAJOR_VERSION}) is available; 1 if not; 2 if unsupported.
  status          Print current/modern bash versions and remediation.
  path            Print absolute path to modern bash (empty if none).
  install [-y]    Run \`brew install bash\` on macOS (interactive prompt unless -y).
  upgrade         Run \`brew upgrade bash\` if newer version is available.
  update-check    Emit rate-limited (24h) advisory for drift or missing install.

Flags:
  -y, --yes       Skip interactive prompt (install/upgrade).
  -q, --quiet     Suppress informational output.

Exit codes:
  0   Success
  1   Modern bash missing or needs upgrade
  2   Unsupported platform
  3   Homebrew missing on macOS
  4   Install/upgrade command failed

Examples:
  bash-upgrade-helper.sh check && echo "ok"
  bash-upgrade-helper.sh status
  MODERN=\$(bash-upgrade-helper.sh path) && echo "\$MODERN"
  bash-upgrade-helper.sh install --yes
  bash-upgrade-helper.sh upgrade

GH#18950 (t2087): Systemic fix for macOS bash 3.2 compatibility class of bugs.
EOF
}

main() {
	local subcmd="${1:-}"
	shift || true

	local yes=""
	local arg
	for arg in "$@"; do
		case "$arg" in
		-y | --yes) yes="1" ;;
		-q | --quiet) _BU_QUIET="1" ;;
		*) ;;
		esac
	done

	case "$subcmd" in
	check) _bu_cmd_check ;;
	status) _bu_cmd_status ;;
	path) _bu_cmd_path ;;
	install) _bu_cmd_install "$yes" ;;
	upgrade) _bu_cmd_upgrade ;;
	update-check) _bu_cmd_update_check ;;
	"" | help | -h | --help)
		_bu_usage
		return 0
		;;
	*)
		_bu_usage >&2
		_bu_error "unknown subcommand: $subcmd"
		return 2
		;;
	esac
}

main "$@"
