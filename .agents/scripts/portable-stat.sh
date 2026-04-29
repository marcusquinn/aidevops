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
#   _stat_translate_fmt FMT — sets _STAT_FLAG + _STAT_FMT for use with xargs/find
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
# _stat_translate_fmt GNU_FMT — translate GNU format tokens to platform-native.
# Sets two variables in caller scope: _STAT_FLAG and _STAT_FMT
# Usage:
#   _stat_translate_fmt '%n %s %Y'
#   find ... -print0 | xargs -0 stat "$_STAT_FLAG" "$_STAT_FMT"
# =============================================================================
_stat_translate_fmt() {
	local fmt="$1"
	case "$_STAT_VARIANT" in
		gnu) _STAT_FLAG="-c"; _STAT_FMT="$fmt" ;;
		bsd)
			_STAT_FLAG="-f"
			_STAT_FMT="$fmt"
			_STAT_FMT="${_STAT_FMT//'%n'/%N}"
			_STAT_FMT="${_STAT_FMT//'%Y'/%m}"
			_STAT_FMT="${_STAT_FMT//'%s'/%z}"
			_STAT_FMT="${_STAT_FMT//'%a'/%Lp}"
			_STAT_FMT="${_STAT_FMT//'%U'/%Su}"
			_STAT_FMT="${_STAT_FMT//'%y'/%Sm}"
			;;
		*) echo "$_PORTABLE_STAT_FATAL" >&2; return 1 ;;
	esac
	return 0
}

# =============================================================================
# _stat_batch — batch stat with GNU-style format, auto-translated for BSD
#
# Accepts a GNU stat format string and one or more file paths.
#
# Supported tokens: %n (name), %s (size), %Y (mtime epoch), %y (mtime human),
#                   %a (octal perms), %U (owner username)
#
# Usage: _stat_batch '%n %s %Y' file1 file2 ...
#
# For find/xargs integration (handles ARG_MAX automatically):
#   _stat_translate_fmt '%n %s %Y'
#   find ... -print0 | xargs -0 stat "$_STAT_FLAG" "$_STAT_FMT"
# =============================================================================
_stat_batch() {
	local fmt="$1"; shift
	_stat_translate_fmt "$fmt" || return 1
	command stat "$_STAT_FLAG" "$_STAT_FMT" "$@" 2>/dev/null
}

# =============================================================================
# Convenience wrappers — single-file, single-field with safe fallbacks.
# All delegate to _stat_batch for the actual platform dispatch.
# On unknown variant: propagates error (fail loud, not silent zeros).
# Fallback values (0, "000", "unknown") only apply when the file is missing
# but the stat variant is known.
# =============================================================================

_stat_assert_variant() {
	[[ "$_STAT_VARIANT" != "$_PORTABLE_STAT_UNKNOWN" ]] && return 0
	echo "$_PORTABLE_STAT_FATAL" >&2
	return 1
}

# _file_mtime_epoch PATH — modification time as epoch seconds (fallback: 0)
_file_mtime_epoch() {
	local file_path="$1"
	_stat_assert_variant || return 1
	_stat_batch '%Y' "$file_path" || echo 0
	return 0
}

# _file_size_bytes PATH — file size in bytes (fallback: 0)
_file_size_bytes() {
	local file_path="$1"
	_stat_assert_variant || return 1
	_stat_batch '%s' "$file_path" || echo 0
	return 0
}

# _file_perms PATH — octal permissions, e.g. "644" (fallback: "000")
_file_perms() {
	local file_path="$1"
	_stat_assert_variant || return 1
	_stat_batch '%a' "$file_path" || echo "000"
	return 0
}

# _file_owner PATH — owner username (fallback: "unknown")
_file_owner() {
	local file_path="$1"
	_stat_assert_variant || return 1
	_stat_batch '%U' "$file_path" || echo "$_PORTABLE_STAT_UNKNOWN"
	return 0
}
