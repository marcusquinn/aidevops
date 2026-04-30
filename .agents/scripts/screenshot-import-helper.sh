#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# screenshot-import-helper.sh — sanitize and size-check images for AI pasting
# Commands: sanitize | prepare | help
#
# macOS inserts U+202F (narrow no-break space, UTF-8: e2 80 af) before AM/PM
# in screenshot filenames. The Claude Code Read tool truncates paths at this
# character, returning "File not found: /Users". This helper detects the byte
# sequence, copies the file to a clean temp path, and prints the clean path.
#
# The 'prepare' subcommand also enforces the Anthropic 5 MB per-image API limit
# (using 4.5 MB as a 10% headroom margin). Images above the limit are resized
# to max 1568px on the longest side using sips (macOS) or ImageMagick.
#
# See reference/screenshot-limits.md for the full failure modes and recovery
# workflow, including the "User-Provided Images" section (GH#21793).

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
# Prepare (sanitize + size-bound for AI pasting)
# =============================================================================

# Anthropic API limit: 5 MB per image (base64-decoded).
# We use 4.5 MB (4718592 bytes) as a 10% headroom margin.
readonly IMAGE_BYTE_LIMIT=4718592
# Vision-API efficiency target: 1568px on the longest side.
readonly IMAGE_MAX_DIM=1568

# Prepare an image for pasting into a Claude Code session:
#   1. Sanitize U+202F from the filename (idempotent).
#   2. Check file size against the Anthropic 5 MB API limit.
#   3. If oversized, resize using sips (macOS) or magick (cross-platform).
#   4. Print the path to the prepared file on stdout.
#
# Args: $1 = source path
# Output: path to a safe, size-bounded copy on stdout
# Exit: 0 on success, 1 on error
cmd_prepare() {
	local src="${1:-}"

	if [[ -z "$src" ]]; then
		log_error "Usage: screenshot-import-helper.sh prepare <path>"
		return 1
	fi

	# Step 1: sanitize U+202F from path.
	local clean_path
	clean_path=$(cmd_sanitize "$src") || return 1

	# Step 2: check file size.
	local file_size
	file_size=$(_file_size_bytes "$clean_path")

	if [[ "$file_size" -le "$IMAGE_BYTE_LIMIT" ]]; then
		# Already within limit — return clean path as-is.
		printf '%s\n' "$clean_path"
		return 0
	fi

	local size_mb
	size_mb=$(awk "BEGIN { printf \"%.1f\", ${file_size} / 1048576 }")
	log_info "Image ${size_mb} MB exceeds 4.5 MB limit — attempting resize to max ${IMAGE_MAX_DIM}px"

	# Step 3: resize to IMAGE_MAX_DIM on the longest side.
	local tmp_dir="${HOME}/.aidevops/.agent-workspace/tmp/session-$$"
	mkdir -p "$tmp_dir" || {
		log_error "Failed to create temp dir: ${tmp_dir}"
		return 1
	}

	local base_name
	base_name=$(basename "$clean_path")
	local resized_path="${tmp_dir}/prepared-${base_name}"
	local downscaled=0

	# Attempt 1: sips (macOS native — no extra install required)
	if command -v sips >/dev/null 2>&1; then
		if sips --resampleHeightWidthMax "${IMAGE_MAX_DIM}" "$clean_path" --out "$resized_path" >/dev/null 2>&1; then
			downscaled=1
		fi
	fi

	# Attempt 2: ImageMagick (cross-platform fallback)
	if [[ "$downscaled" -eq 0 ]] && command -v magick >/dev/null 2>&1; then
		if magick "$clean_path" -resize "${IMAGE_MAX_DIM}x${IMAGE_MAX_DIM}>" "$resized_path" 2>/dev/null; then
			downscaled=1
		fi
	fi

	# Attempt 3: convert (older ImageMagick)
	if [[ "$downscaled" -eq 0 ]] && command -v convert >/dev/null 2>&1; then
		if convert "$clean_path" -resize "${IMAGE_MAX_DIM}x${IMAGE_MAX_DIM}>" "$resized_path" 2>/dev/null; then
			downscaled=1
		fi
	fi

	if [[ "$downscaled" -eq 0 ]]; then
		log_error "Could not resize image: neither sips, magick, nor convert is available."
		log_error "Install ImageMagick (brew install imagemagick) or use sips on macOS."
		return 1
	fi

	# Step 4: verify the resized file is within the limit.
	local new_size
	new_size=$(_file_size_bytes "$resized_path")
	local new_mb
	new_mb=$(awk "BEGIN { printf \"%.1f\", ${new_size} / 1048576 }")

	if [[ "$new_size" -gt "$IMAGE_BYTE_LIMIT" ]]; then
		log_error "Resized image still ${new_mb} MB — exceeds 4.5 MB limit. Manual resize required."
		return 1
	fi

	log_info "Resized: '${base_name}' ${size_mb} MB → ${new_mb} MB at ${resized_path}"
	printf '%s\n' "$resized_path"
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
screenshot-import-helper.sh — sanitize and size-check images for AI pasting

macOS inserts a narrow no-break space (U+202F, UTF-8: e2 80 af) before AM/PM
in screenshot filenames. The Claude Code Read tool truncates paths at this
character, returning "File not found: /Users". This helper copies the file
to a clean temporary path and returns the clean path for the Read tool.

The 'prepare' subcommand also enforces the Anthropic 5 MB per-image API limit.
Images over 4.5 MB are automatically resized to max 1568px on the longest side.

Usage:
  screenshot-import-helper.sh sanitize <path>
  screenshot-import-helper.sh prepare <path>
  screenshot-import-helper.sh help

Commands:
  sanitize <path>   Check path for U+202F. If found, copy to a clean temp
                    path and print it. If not found, print path unchanged.
                    Idempotent — safe to call on already-clean paths.
  prepare <path>    Sanitize path AND enforce Anthropic's 5 MB image limit.
                    If the image is over 4.5 MB, resize to max 1568px using
                    sips (macOS) or ImageMagick. Returns the safe path.
                    Use this before pasting any large screenshot into Claude.
  help              Show this message.

Examples:
  # Before pasting a large Retina screenshot into Claude Code:
  safe=$(screenshot-import-helper.sh prepare ~/Downloads/Screenshot.png)
  # Drag-and-drop $safe into the Claude Code chat input.

  # Read tool returns "File not found: /Users" on a screenshot — recover:
  clean=$(screenshot-import-helper.sh sanitize ~/Downloads/"Screenshot 2026-04-28 at 8.16.59 AM.png")
  # Then use $clean with the Read tool.

Recovery workflow when a pasted image crashes the session:
  - Image >5 MB causes permanent "image exceeds 5 MB maximum" error on replay.
  - Prevention: always run 'prepare' before pasting screenshots into Claude.
  - Run 'prepare' on the image file, use the returned path.

Recovery workflow when Read returns "File not found: /Users":
  1. Glob for the screenshot:
       ls ~/Downloads/Screenshot*.png
  2. Sanitize the path:
       clean=$(screenshot-import-helper.sh sanitize <path>)
  3. Read from $clean.

Full details: reference/screenshot-limits.md
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
	prepare) cmd_prepare "$@" ;;
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
