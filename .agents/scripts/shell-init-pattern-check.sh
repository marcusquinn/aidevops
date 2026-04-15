#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shell-init-pattern-check.sh — CI lint gate for shell init patterns (t2053 Phase 2)
#
# Enforces the canonical patterns from .agents/reference/shell-style-guide.md:
# scripts must either source shared-constants.sh (Pattern A) or use
# [[ -z "${VAR+x}" ]] guards (Pattern B) for canonical color variables.
# Unguarded assignments and readonly declarations of RED/GREEN/YELLOW/
# BLUE/PURPLE/CYAN/WHITE/NC outside shared-constants.sh are banned.
#
# Usage:
#   shell-init-pattern-check.sh --scan-files <file1> <file2> ...
#   shell-init-pattern-check.sh --scan-all
#   shell-init-pattern-check.sh --fix-hint
#   shell-init-pattern-check.sh --help
#
# Exit codes:
#   0 — clean (no violations found)
#   1 — violations found
#   2 — usage error
#
# Design:
# - Option A (diff-scoped scanning) for phased migration: existing
#   violations on main do not fail CI; only PR-touched files are checked.
# - shared-constants.sh is unconditionally exempt.
# - Lines with indentation > 0 (inside function bodies) are safe.
# - Lines with [[ -z "${VAR+x}" ]] guard on the same line are safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

SCRIPT_NAME=$(basename "$0")

# Canonical color variable names (from shell-style-guide.md)
readonly BANNED_VARS='RED|GREEN|YELLOW|BLUE|PURPLE|CYAN|WHITE|NC'

# ── helpers ──────────────────────────────────────────────────────────

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

die() {
	local _msg="$1"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit 2
}

usage() {
	sed -n '5,28p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# is_exempt <filepath> — returns 0 if the file should be skipped entirely
is_exempt() {
	local _path="$1"
	local _basename
	_basename=$(basename "$_path")
	# shared-constants.sh is the canonical source — always exempt
	if [[ "$_basename" == "shared-constants.sh" ]]; then
		return 0
	fi
	return 1
}

# _is_guarded_line <line> — returns 0 if line uses Pattern B guard
_is_guarded_line() {
	local _line="$1"
	# Pattern B: [[ -z "${VAR+x}" ]] && VAR=...
	if [[ "$_line" =~ \[\[\ -z\ \"\$\{[A-Z_]+\+x\}\"\ \]\] ]]; then
		return 0
	fi
	return 1
}

# _is_indented <line> — returns 0 if line starts with whitespace (inside function/if block)
_is_indented() {
	local _line="$1"
	if [[ "$_line" =~ ^[[:space:]]+ ]]; then
		return 0
	fi
	return 1
}

# ── scan_file ────────────────────────────────────────────────────────

# _has_disable_directive <filepath> — returns 0 if file contains
# a '# shell-init-check:disable' comment in the first 20 lines.
# Used by test harnesses that embed violation examples as fixtures.
_has_disable_directive() {
	local _file="$1"
	local _head
	_head=$(head -20 "$_file" 2>/dev/null || true)
	if [[ "$_head" == *"# shell-init-check:disable"* ]]; then
		return 0
	fi
	return 1
}

# scan_file <filepath> — check a single file for violations.
# Prints violation lines to stdout. Returns 0 if clean, 1 if violations found.
scan_file() {
	local _file="$1"
	local _violations=0
	local _line_num=0
	local _line

	if [[ ! -f "$_file" ]]; then
		log "File not found: $_file"
		return 0
	fi

	if is_exempt "$_file"; then
		return 0
	fi

	# File-level opt-out: # shell-init-check:disable in first 10 lines.
	# For test harnesses that embed violation patterns as fixtures.
	if _has_disable_directive "$_file"; then
		return 0
	fi

	while IFS= read -r _line || [[ -n "$_line" ]]; do
		_line_num=$((_line_num + 1))

		# Skip indented lines (inside function/if blocks — safe)
		if _is_indented "$_line"; then
			continue
		fi

		# Skip guarded lines (Pattern B)
		if _is_guarded_line "$_line"; then
			continue
		fi

		# Check banned pattern 1: unguarded plain assignment
		# e.g. RED='\033[0;31m'  or  GREEN='...'
		if [[ "$_line" =~ ^(${BANNED_VARS})=[\'\"] ]]; then
			printf '%s:%d: unguarded plain assignment of %s (use Pattern A or B from shell-style-guide.md)\n' \
				"$_file" "$_line_num" "${BASH_REMATCH[1]}"
			_violations=$((_violations + 1))
			continue
		fi

		# Check banned pattern 2: unguarded readonly on canonical names
		# e.g. readonly RED='\033[0;31m'
		if [[ "$_line" =~ ^readonly[[:space:]]+(${BANNED_VARS})= ]]; then
			printf '%s:%d: banned readonly of %s outside shared-constants.sh (use Pattern B or C from shell-style-guide.md)\n' \
				"$_file" "$_line_num" "${BASH_REMATCH[1]}"
			_violations=$((_violations + 1))
			continue
		fi
	done <"$_file"

	if [[ "$_violations" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# ── subcommands ──────────────────────────────────────────────────────

# cmd_scan_files <file1> <file2> ... — scan explicit files (used by CI)
cmd_scan_files() {
	local _total_violations=0
	local _files_with_violations=0
	local _file

	if [[ $# -eq 0 ]]; then
		die "No files specified. Usage: $SCRIPT_NAME --scan-files <file1> <file2> ..."
	fi

	for _file in "$@"; do
		# Only check .sh files
		case "$_file" in
		*.sh) ;;
		*) continue ;;
		esac

		local _output
		_output=$(scan_file "$_file" 2>/dev/null)
		local _rc=$?
		if [[ $_rc -eq 1 && -n "$_output" ]]; then
			printf '%s\n' "$_output"
			local _count
			_count=$(printf '%s\n' "$_output" | wc -l)
			_total_violations=$((_total_violations + _count))
			_files_with_violations=$((_files_with_violations + 1))
		fi
	done

	_print_summary "$_total_violations" "$_files_with_violations"
	if [[ "$_total_violations" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# cmd_scan_all — scan every .sh under .agents/scripts/
cmd_scan_all() {
	local _total_violations=0
	local _files_with_violations=0
	local _repo_root
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	local _scripts_dir="${_repo_root}/.agents/scripts"

	if [[ ! -d "$_scripts_dir" ]]; then
		die "Scripts directory not found: $_scripts_dir"
	fi

	local _file
	while IFS= read -r _file; do
		[[ -n "$_file" ]] || continue
		local _output
		_output=$(scan_file "$_file" 2>/dev/null)
		local _rc=$?
		if [[ $_rc -eq 1 && -n "$_output" ]]; then
			printf '%s\n' "$_output"
			local _count
			_count=$(printf '%s\n' "$_output" | wc -l)
			_total_violations=$((_total_violations + _count))
			_files_with_violations=$((_files_with_violations + 1))
		fi
	done < <(find "$_scripts_dir" -name '*.sh' -type f | sort)

	_print_summary "$_total_violations" "$_files_with_violations"
	if [[ "$_total_violations" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# cmd_fix_hint — print remediation snippets per violation
cmd_fix_hint() {
	printf 'Remediation patterns for shell init violations:\n\n'
	printf '=== Pattern A (preferred) — source shared-constants.sh ===\n'
	printf 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
	printf '# shellcheck source=shared-constants.sh\n'
	printf '[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"\n\n'
	printf '=== Pattern B (fallback) — granular ${VAR+x} guard ===\n'
	printf '[[ -z "${RED+x}" ]]    && RED='"'"'\\033[0;31m'"'"'\n'
	printf '[[ -z "${GREEN+x}" ]]  && GREEN='"'"'\\033[0;32m'"'"'\n'
	printf '[[ -z "${NC+x}" ]]     && NC='"'"'\\033[0m'"'"'\n\n'
	printf '=== Pattern C (tests only) — prefixed names ===\n'
	printf 'readonly TEST_RED=$'"'"'\\033[0;31m'"'"'\n'
	printf 'readonly TEST_GREEN=$'"'"'\\033[0;32m'"'"'\n'
	printf 'readonly TEST_RESET=$'"'"'\\033[0m'"'"'\n\n'
	printf 'See: .agents/reference/shell-style-guide.md\n'
	return 0
}

# _print_summary — print violation summary
_print_summary() {
	local _total="$1"
	local _files="$2"
	printf '\n--- Shell Init Pattern Check ---\n'
	if [[ "$_total" -eq 0 ]]; then
		printf 'No violations found.\n'
	else
		printf 'Found %d violation(s) across %d file(s).\n' "$_total" "$_files"
		printf 'See: .agents/reference/shell-style-guide.md\n'
	fi
	return 0
}

# ── main dispatch ────────────────────────────────────────────────────

main() {
	if [[ $# -eq 0 ]]; then
		usage
		exit 2
	fi

	local _cmd="$1"
	shift

	case "$_cmd" in
	--scan-files)
		cmd_scan_files "$@"
		;;
	--scan-all)
		cmd_scan_all "$@"
		;;
	--fix-hint)
		cmd_fix_hint
		;;
	-h | --help)
		usage
		;;
	*)
		die "Unknown command: $_cmd. Use --help for usage."
		;;
	esac
}

main "$@"
