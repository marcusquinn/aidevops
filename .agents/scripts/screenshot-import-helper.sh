#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# screenshot-import-helper.sh — sanitize and prepare screenshots for AI pasting
# Commands: sanitize | prepare | help
#
# macOS inserts U+202F (narrow no-break space, UTF-8: e2 80 af) before AM/PM
# in screenshot filenames. The Claude Code Read tool truncates paths at this
# character, returning "File not found: /Users". This helper detects the byte
# sequence, copies the file to a clean temp path, and prints the clean path.
#
# The prepare command additionally checks image size and downscales images
# >4.5 MB (the Anthropic API preflight ceiling) before pasting, preventing
# the session-crashing "image exceeds 5 MB maximum" error (GH#21793).
#
# See reference/screenshot-limits.md for full details.

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
# Prepare (GH#21793) — sanitize path + downscale if >4.5 MB
# =============================================================================

# Anthropic API decoded-byte ceiling for user-pasted images.
# 4.5 MB = 4718592 bytes (10 % headroom under the hard 5 MB server limit).
readonly IMAGE_MAX_BYTES=4718592
readonly IMAGE_MAX_DIM=1568

# Prepare a screenshot for pasting into Claude Code or OpenCode.
#
# Combines the sanitize (U+202F removal) and size-guard (downscale if >4.5 MB)
# steps into a single command. Returns the path to a clean, size-safe copy.
#
# Args: $1 = source path (may include U+202F and/or be oversized)
# Output: prepared path on stdout
# Exit: 0 on success, 1 on error
cmd_prepare() {
	local src="${1:-}"

	if [[ -z "$src" ]]; then
		log_error "Usage: screenshot-import-helper.sh prepare <path>"
		return 1
	fi

	# Step 1: sanitize U+202F in path (reuse cmd_sanitize logic).
	local clean_path
	clean_path=$(cmd_sanitize "$src") || return 1

	# Step 2: check decoded byte size. The Anthropic API measures the base64-
	# decoded size, which equals the raw file size on disk.
	local file_bytes
	file_bytes=$(wc -c < "$clean_path" 2>/dev/null) || file_bytes=0
	# Strip leading whitespace from wc output (BSD wc pads with spaces).
	file_bytes="${file_bytes// /}"

	if [[ "$file_bytes" -le "$IMAGE_MAX_BYTES" ]]; then
		# Image is within limits — return the sanitized path as-is.
		printf '%s\n' "$clean_path"
		return 0
	fi

	local size_mb
	size_mb=$(awk "BEGIN { printf \"%.1f\", ${file_bytes}/1048576 }")
	log_info "Image is ${size_mb} MB (> 4.5 MB limit). Attempting downscale to ${IMAGE_MAX_DIM}px..."

	# Determine output path for the downscaled copy.
	local tmp_dir="${HOME}/.aidevops/.agent-workspace/tmp/session-$$"
	mkdir -p "$tmp_dir" || {
		log_error "Failed to create temp dir: ${tmp_dir}"
		return 1
	}

	local base_name
	base_name=$(basename "$clean_path")
	local ext="${base_name##*.}"
	local stem="${base_name%.*}"
	local dst="${tmp_dir}/${stem}-prepared.${ext}"

	# Step 3a: try sips (macOS built-in, no install required).
	local resized=0
	if command -v sips >/dev/null 2>&1; then
		if sips --resampleHeightWidthMax "${IMAGE_MAX_DIM}" "$clean_path" --out "$dst" >/dev/null 2>&1; then
			resized=1
			log_info "Downscaled with sips → ${dst}"
		fi
	fi

	# Step 3b: try ImageMagick (cross-platform fallback).
	if [[ "$resized" -eq 0 ]] && command -v magick >/dev/null 2>&1; then
		if magick "$clean_path" -resize "${IMAGE_MAX_DIM}x${IMAGE_MAX_DIM}>" "$dst" >/dev/null 2>&1; then
			resized=1
			log_info "Downscaled with magick → ${dst}"
		fi
	fi

	if [[ "$resized" -eq 0 ]]; then
		log_error "Downscale failed (sips and magick both unavailable or errored)."
		log_error "Install ImageMagick: brew install imagemagick (macOS) or apt install imagemagick (Linux)."
		log_error "Image is ${size_mb} MB — pasting it will crash the Claude Code session."
		return 1
	fi

	# Verify the downscaled size is within limits.
	local new_bytes
	new_bytes=$(wc -c < "$dst" 2>/dev/null) || new_bytes=0
	new_bytes="${new_bytes// /}"
	if [[ "$new_bytes" -gt "$IMAGE_MAX_BYTES" ]]; then
		local new_mb
		new_mb=$(awk "BEGIN { printf \"%.1f\", ${new_bytes}/1048576 }")
		log_error "Downscaled image is still ${new_mb} MB (> 4.5 MB). Cannot make it safe."
		log_error "Try saving as JPEG at lower quality, or crop the image before pasting."
		return 1
	fi

	printf '%s\n' "$dst"
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
screenshot-import-helper.sh — sanitize and prepare screenshots for AI pasting

Commands:
  prepare <path>    Full preflight: sanitize U+202F in path, then downscale
                    the image if it exceeds 4.5 MB (Anthropic API preflight
                    ceiling). Returns the path to a clean, size-safe copy.
                    Use this before pasting a screenshot into Claude Code.

  sanitize <path>   Check path for U+202F. If found, copy to a clean temp
                    path and print it. If not found, print path unchanged.
                    Idempotent — safe to call on already-clean paths.
                    (Does NOT check image size — use prepare for that.)

  help              Show this message.

Usage:
  screenshot-import-helper.sh prepare <path>
  screenshot-import-helper.sh sanitize <path>
  screenshot-import-helper.sh help

Examples:
  # Prepare a screenshot before pasting (handles both U+202F and >4.5MB):
  safe=$(screenshot-import-helper.sh prepare ~/Desktop/Screenshot.png)
  # Then paste $safe into the chat.

  # Read tool returns "File not found: /Users" on a screenshot — recover:
  clean=$(screenshot-import-helper.sh sanitize ~/Downloads/"Screenshot 2026-04-28 at 8.16.59 AM.png")
  # Then use $clean with the Read tool.

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
	prepare) cmd_prepare "$@" ;;
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
