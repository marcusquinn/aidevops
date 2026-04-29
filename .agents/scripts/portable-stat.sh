#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# portable-stat.sh — Cross-platform stat wrappers (GNU coreutils vs BSD)
#
# GNU stat uses -c FORMAT; BSD (macOS) stat uses -f FORMAT.
# On Linux, `stat -f` means "filesystem stat" — a completely different
# operation that outputs multi-line garbage and may exit 0, silently
# corrupting variables.
#
# This library detects the stat variant ONCE at source-time by testing
# actual output (capability detection, not platform detection). All
# subsequent calls use only the detected variant — no || chains, no
# stdout contamination risk.
#
# Usage: source this file from any script that needs portable stat.
#   source "${BASH_SOURCE[0]%/*}/portable-stat.sh"
#
# Functions provided:
#   _file_mtime_epoch PATH  — modification time as epoch seconds
#   _file_size_bytes  PATH  — file size in bytes
#   _file_perms       PATH  — octal permissions (e.g. "644")
#   _file_owner       PATH  — owner username

[[ -n "${_PORTABLE_STAT_LOADED:-}" ]] && return 0
_PORTABLE_STAT_LOADED=1

# =============================================================================
# Detect stat variant ONCE at source-time.
#
# Tests real capability by running stat on / (always exists) and validating
# the output is numeric. This works on Linux, macOS, FreeBSD, Alpine/BusyBox,
# and any future environment — no uname checks, no platform assumptions.
#
# If neither variant produces a numeric result, _STAT_VARIANT stays "unknown"
# and all functions return error + stderr message (fail loud, not silent zeros).
# =============================================================================

_PORTABLE_STAT_FATAL="FATAL: portable-stat.sh: unsupported stat variant (neither GNU nor BSD)"
_PORTABLE_STAT_UNKNOWN="unknown"

_STAT_VARIANT="$_PORTABLE_STAT_UNKNOWN"
if _ps_test_val=$(stat -c %Y / 2>/dev/null) && [[ "$_ps_test_val" =~ ^[0-9]+$ ]]; then
	_STAT_VARIANT="gnu"
elif _ps_test_val=$(stat -f %m / 2>/dev/null) && [[ "$_ps_test_val" =~ ^[0-9]+$ ]]; then
	_STAT_VARIANT="bsd"
fi
unset _ps_test_val

# =============================================================================
# _file_mtime_epoch — modification time as epoch seconds
# Usage: epoch=$(_file_mtime_epoch "/path/to/file")
# Returns: epoch seconds, or 0 on stat failure. Errors on unknown variant.
# =============================================================================
_file_mtime_epoch() {
	local file_path="$1"
	case "$_STAT_VARIANT" in
		gnu) stat -c %Y "$file_path" 2>/dev/null || echo 0 ;;
		bsd) stat -f %m "$file_path" 2>/dev/null || echo 0 ;;
		*) echo "$_PORTABLE_STAT_FATAL" >&2; return 1 ;;
	esac
}

# =============================================================================
# _file_size_bytes — file size in bytes
# Usage: bytes=$(_file_size_bytes "/path/to/file")
# Returns: size in bytes, or 0 on stat failure. Errors on unknown variant.
# =============================================================================
_file_size_bytes() {
	local file_path="$1"
	case "$_STAT_VARIANT" in
		gnu) stat -c %s "$file_path" 2>/dev/null || echo 0 ;;
		bsd) stat -f %z "$file_path" 2>/dev/null || echo 0 ;;
		*) echo "$_PORTABLE_STAT_FATAL" >&2; return 1 ;;
	esac
}

# =============================================================================
# _file_perms — octal permission string
# Usage: mode=$(_file_perms "/path/to/file")
# Returns: octal string (e.g. "644"), or "000" on stat failure.
# =============================================================================
_file_perms() {
	local file_path="$1"
	case "$_STAT_VARIANT" in
		gnu) stat -c %a "$file_path" 2>/dev/null || echo "000" ;;
		bsd) stat -f %Lp "$file_path" 2>/dev/null || echo "000" ;;
		*) echo "$_PORTABLE_STAT_FATAL" >&2; return 1 ;;
	esac
}

# =============================================================================
# _file_owner — owner username
# Usage: owner=$(_file_owner "/path/to/file")
# Returns: username string, or "unknown" on stat failure.
# =============================================================================
_file_owner() {
	local file_path="$1"
	case "$_STAT_VARIANT" in
		gnu) stat -c %U "$file_path" 2>/dev/null || echo "$_PORTABLE_STAT_UNKNOWN" ;;
		bsd) stat -f %Su "$file_path" 2>/dev/null || echo "$_PORTABLE_STAT_UNKNOWN" ;;
		*) echo "$_PORTABLE_STAT_FATAL" >&2; return 1 ;;
	esac
}
