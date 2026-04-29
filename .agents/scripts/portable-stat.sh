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
#   _stat_batch FMT FILE... — batch stat with GNU-style format (auto-translated for BSD)

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
# _stat_batch — batch stat with GNU-style format, auto-translated for BSD
#
# Accepts a GNU stat format string and one or more file paths. Translates
# common GNU format tokens to BSD equivalents automatically.
#
# Supported tokens: %n (name), %s (size), %Y (mtime epoch), %y (mtime human),
#                   %a (octal perms), %U (owner username)
#
# Usage: _stat_batch '%n %s %Y' file1 file2 ...
#
# For find integration (handles ARG_MAX automatically):
#        find ... -print0 | xargs -0 bash -c 'source portable-stat.sh; _stat_batch "%n %s %Y" "$@"' _
# =============================================================================
_stat_batch() {
	local fmt="$1"; shift
	case "$_STAT_VARIANT" in
		gnu) command stat -c "$fmt" "$@" 2>/dev/null ;;
		bsd)
			local bsd_fmt="$fmt"
			bsd_fmt="${bsd_fmt//'%n'/%N}"
			bsd_fmt="${bsd_fmt//'%Y'/%m}"
			bsd_fmt="${bsd_fmt//'%s'/%z}"
			bsd_fmt="${bsd_fmt//'%a'/%Lp}"
			bsd_fmt="${bsd_fmt//'%U'/%Su}"
			bsd_fmt="${bsd_fmt//'%y'/%Sm}"
			command stat -f "$bsd_fmt" "$@" 2>/dev/null
			;;
		*) echo "$_PORTABLE_STAT_FATAL" >&2; return 1 ;;
	esac
}

# =============================================================================
# Convenience wrappers — single-file, single-field with safe fallbacks.
# All delegate to _stat_batch for the actual platform dispatch.
# =============================================================================

# _file_mtime_epoch PATH — modification time as epoch seconds (fallback: 0)
# On unknown variant: propagates error (fail loud, not silent zeros).
_file_mtime_epoch() {
	local file_path="$1"
	[[ "$_STAT_VARIANT" == "$_PORTABLE_STAT_UNKNOWN" ]] && { echo "$_PORTABLE_STAT_FATAL" >&2; return 1; }
	_stat_batch '%Y' "$file_path" || echo 0
	return 0
}

# _file_size_bytes PATH — file size in bytes (fallback: 0)
_file_size_bytes() {
	local file_path="$1"
	[[ "$_STAT_VARIANT" == "$_PORTABLE_STAT_UNKNOWN" ]] && { echo "$_PORTABLE_STAT_FATAL" >&2; return 1; }
	_stat_batch '%s' "$file_path" || echo 0
	return 0
}

# _file_perms PATH — octal permissions, e.g. "644" (fallback: "000")
_file_perms() {
	local file_path="$1"
	[[ "$_STAT_VARIANT" == "$_PORTABLE_STAT_UNKNOWN" ]] && { echo "$_PORTABLE_STAT_FATAL" >&2; return 1; }
	_stat_batch '%a' "$file_path" || echo "000"
	return 0
}

# _file_owner PATH — owner username (fallback: "unknown")
_file_owner() {
	local file_path="$1"
	[[ "$_STAT_VARIANT" == "$_PORTABLE_STAT_UNKNOWN" ]] && { echo "$_PORTABLE_STAT_FATAL" >&2; return 1; }
	_stat_batch '%U' "$file_path" || echo "$_PORTABLE_STAT_UNKNOWN"
	return 0
}
