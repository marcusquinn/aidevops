#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# screenshot-import-helper.sh — sanitize macOS screenshot paths containing U+202F
# Commands: sanitize | help
#
# macOS inserts U+202F (narrow no-break space, UTF-8: e2 80 af) before AM/PM
# in screenshot filenames. The Claude Code Read tool truncates paths at this
# character, returning "File not found: /Users". This helper detects the byte
# sequence, copies the file to a clean temp path, and prints the clean path.
#
# See reference/screenshot-limits.md "macOS Filename Hygiene" for the full
# failure mode and recovery workflow.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

# U+202F (NARROW NO-BREAK SPACE) as raw UTF-8 bytes (e2 80 af).
# macOS inserts this before AM/PM in screenshot filenames.
# shellcheck disable=SC2034
readonly U202F=$'\xe2\x80\xaf'

# =============================================================================
# Sanitize
# =============================================================================

# Sanitize a file path that may contain U+202F (narrow no-break space).
#
# If the path contains the U+202F byte sequence, copies the file to a clean
# temp path under ~/.aidevops/.agent-workspace/tmp/session-PID/ and prints
# the new path. If the path is already clean, prints it unchanged (idempotent).
#
# Args: $1 = source path (may include U+202F)
# Output: clean path on stdout
# Exit: 0 on success, 1 on error (missing path arg, source not found, copy fail)
cmd_sanitize() {
	local src="${1:-}"

	if [[ -z "$src" ]]; then
		log_error "Usage: screenshot-import-helper.sh sanitize <path>"
		return 1
	fi

	# Detect U+202F in the path. LC_ALL=C ensures byte-literal matching.
	if ! printf '%s' "$src" | LC_ALL=C grep -q "$U202F"; then
		# Path is already clean — print unchanged.
		printf '%s\n' "$src"
		return 0
	fi

	# Path contains U+202F. Verify source file exists before attempting copy.
	if [[ ! -f "$src" ]]; then
		log_error "File not found: ${src}"
		return 1
	fi

	# Build clean basename by stripping U+202F bytes.
	# LC_ALL=C + sed treats the 3-byte sequence as a literal pattern.
	local clean_name
	clean_name=$(basename "$src" | LC_ALL=C sed "s/${U202F}//g")

	if [[ -z "$clean_name" ]]; then
		log_error "Failed to compute clean filename from: $(basename "$src")"
		return 1
	fi

	# Build temp destination under the agent workspace session directory.
	local tmp_dir="${HOME}/.aidevops/.agent-workspace/tmp/session-$$"
	mkdir -p "$tmp_dir" || {
		log_error "Failed to create temp dir: ${tmp_dir}"
		return 1
	}

	local dest="${tmp_dir}/${clean_name}"

	# Copy source to clean destination.
	if ! cp "$src" "$dest"; then
		log_error "Failed to copy '${src}' to '${dest}'"
		return 1
	fi

	log_info "Sanitized: '$(basename "$src")' → '${clean_name}' at ${tmp_dir}"
	printf '%s\n' "$dest"
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
screenshot-import-helper.sh — sanitize macOS screenshot paths containing U+202F

macOS inserts a narrow no-break space (U+202F, UTF-8: e2 80 af) before AM/PM
in screenshot filenames. The Claude Code Read tool truncates paths at this
character, returning "File not found: /Users". This helper copies the file
to a clean temporary path and returns the clean path for the Read tool.

Usage:
  screenshot-import-helper.sh sanitize <path>
  screenshot-import-helper.sh help

Commands:
  sanitize <path>   Check path for U+202F. If found, copy to a clean temp
                    path and print it. If not found, print path unchanged.
                    Idempotent — safe to call on already-clean paths.
  help              Show this message.

Examples:
  # Read tool returns "File not found: /Users" on a screenshot — recover:
  clean=$(screenshot-import-helper.sh sanitize ~/Downloads/"Screenshot 2026-04-28 at 8.16.59 AM.png")
  # Then use $clean with the Read tool.

Recovery workflow when Read returns "File not found: /Users":
  1. Glob for the screenshot:
       ls ~/Downloads/Screenshot*.png
  2. Sanitize the path:
       clean=$(screenshot-import-helper.sh sanitize <path>)
  3. Read from $clean.

Full details: reference/screenshot-limits.md "macOS Filename Hygiene"
HELP
	return 0
}

# =============================================================================
# Main Dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	sanitize) cmd_sanitize "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
