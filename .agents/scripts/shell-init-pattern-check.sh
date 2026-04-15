#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shell-init-pattern-check.sh — CI lint gate for shell helper init patterns (t2053 Phase 2)
#
# Enforces canonical patterns from .agents/reference/shell-style-guide.md.
# Prevents unguarded assignments to RED/GREEN/YELLOW/BLUE/PURPLE/CYAN/WHITE/NC
# which caused the GH#18702 outage (auto-update broken for 4 days).
#
# Usage:
#   shell-init-pattern-check.sh --scan-files <file1> [file2 ...]
#   shell-init-pattern-check.sh --scan-all
#   shell-init-pattern-check.sh --fix-hint
#   shell-init-pattern-check.sh --help
#
# Options:
#   --scan-files <file1> [file2 ...]  Scan explicit files (used by CI on PR diffs)
#   --scan-all                        Scan every *.sh under .agents/scripts/
#   --fix-hint                        Print a remediation snippet per pattern
#   -h, --help                        Show this help and exit 0
#
# Flags (combinable with --scan-files or --scan-all):
#   --fix-hint    Also print fix hints alongside violation output
#
# Exit codes:
#   0 — clean, no violations found
#   1 — one or more violations found
#   2 — usage error
#
# Detection rules:
#   Banned pattern 1: unguarded top-level assignment to canonical color name
#     (column-0, no leading whitespace — inside function/block = indented = safe)
#   Banned pattern 2: readonly on canonical name outside shared-constants.sh
#   Canonical names: RED GREEN YELLOW BLUE PURPLE CYAN WHITE NC
#   Safe: [[ -z "${VAR+x}" ]] guard on same line or immediately preceding line
#   Exempt: shared-constants.sh (defines the canonical values)
#
# This helper follows Pattern A (sources shared-constants.sh) — the enforcement
# script cannot violate its own rule.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

SCRIPT_NAME=$(basename "$0")

# Pattern B fallback colors for bootstrap contexts where shared-constants.sh
# is not yet available (e.g. early CI steps before the repo is fully set up).
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Canonical color variable names declared readonly in shared-constants.sh.
# This list is the source of truth for what is banned at top level.
CANONICAL_NAMES_PATTERN="^(RED|GREEN|YELLOW|BLUE|PURPLE|CYAN|WHITE|NC)="
CANONICAL_READONLY_PATTERN="^[[:space:]]*readonly[[:space:]]+(RED|GREEN|YELLOW|BLUE|PURPLE|CYAN|WHITE|NC)="
GUARD_PATTERN='\[\[ -z "\$\{[A-Z_]+\+x\}" \]\]'

# ── helpers ─────────────────────────────────────────────────────────────────

usage() {
	sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

die() {
	local _msg="$1"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit 2
}

log_violation() {
	local _file="$1"
	local _lineno="$2"
	local _type="$3"
	local _content="$4"
	printf '%b[VIOLATION]%b %s:%s\n' "${RED}" "${NC}" "$_file" "$_lineno" >&2
	printf '  Type: %s\n' "$_type" >&2
	printf '  Line: %s\n' "$_content" >&2
	return 0
}

# line_has_guard <line>: returns 0 if line contains a [[ -z "${VAR+x}" ]] guard
line_has_guard() {
	local _line="$1"
	printf '%s' "$_line" | grep -qE "${GUARD_PATTERN}"
	return $?
}

print_fix_hint() {
	printf '\n%b── Fix Hint: Shell Init Pattern Guide ──%b\n' "${YELLOW}" "${NC}"
	printf 'Reference: .agents/reference/shell-style-guide.md\n\n'
	printf '%bPattern A (preferred — scripts inside .agents/scripts/):%b\n' "${GREEN}" "${NC}"
	# shellcheck disable=SC2016
	printf '  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
	printf '  # shellcheck source=shared-constants.sh\n'
	# shellcheck disable=SC2016
	printf '  [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"\n\n'
	printf '%bPattern B (fallback — bootstrap/standalone/curl-distributed):%b\n' "${GREEN}" "${NC}"
	# shellcheck disable=SC2016
	printf '  [[ -z "${RED+x}" ]]    && RED='\''\033[0;31m'\''\n'
	# shellcheck disable=SC2016
	printf '  [[ -z "${GREEN+x}" ]]  && GREEN='\''\033[0;32m'\''\n'
	# shellcheck disable=SC2016
	printf '  [[ -z "${YELLOW+x}" ]] && YELLOW='\''\033[1;33m'\''\n'
	# shellcheck disable=SC2016
	printf '  [[ -z "${NC+x}" ]]     && NC='\''\033[0m'\''\n\n'
	printf '%bPattern C (test harnesses and strictly-internal utilities only):%b\n' "${GREEN}" "${NC}"
	printf '  readonly TEST_RED=$'"'"'\033[0;31m'"'"'\n'
	printf '  readonly TEST_GREEN=$'"'"'\033[0;32m'"'"'\n'
	printf '  readonly TEST_RESET=$'"'"'\033[0m'"'"'\n\n'
	printf 'NEVER: %breadonly RED=%b or unguarded %bRED=%b at column 0.\n\n' "${RED}" "${NC}" "${RED}" "${NC}"
	return 0
}

# ── scanner ──────────────────────────────────────────────────────────────────

# scan_file <path> <violations_file>
# Appends violation records to <violations_file>, one per line:
#   <file>:<lineno>:<type>:<content>
scan_file() {
	local _file="$1"
	local _vfile="$2"
	local _basename

	_basename=$(basename "$_file")

	# shared-constants.sh is unconditionally exempt
	if [[ "$_basename" == "shared-constants.sh" ]]; then
		return 0
	fi

	local _lineno=0
	local _prev_line=""
	local _line

	while IFS= read -r _line || [[ -n "${_line}" ]]; do
		_lineno=$((_lineno + 1))

		# Banned pattern 2: readonly on canonical name (any indentation)
		if printf '%s' "${_line}" | grep -qE "${CANONICAL_READONLY_PATTERN}"; then
			printf '%s\n' "${_file}:${_lineno}:readonly on canonical name (breaks on re-sourcing — Banned pattern 2):${_line}" >>"${_vfile}"
			_prev_line="${_line}"
			continue
		fi

		# Banned pattern 1: unguarded top-level assignment (column 0, no leading whitespace)
		if printf '%s' "${_line}" | grep -qE "${CANONICAL_NAMES_PATTERN}"; then
			# Safe if guarded on same line or previous line
			if line_has_guard "${_line}" || line_has_guard "${_prev_line}"; then
				: # guarded — allowed
			else
				printf '%s\n' "${_file}:${_lineno}:unguarded top-level assignment (collides with parent readonly — Banned pattern 1):${_line}" >>"${_vfile}"
			fi
		fi

		_prev_line="${_line}"
	done <"${_file}"

	return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

MODE=""
SHOW_FIX_HINT=0
SCAN_FILES=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--scan-all)
		MODE="scan-all"
		shift
		;;
	--scan-files)
		MODE="scan-files"
		shift
		while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
			SCAN_FILES+=("$1")
			shift
		done
		;;
	--fix-hint)
		SHOW_FIX_HINT=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "Unknown argument: $1 — use --help for usage"
		;;
	esac
done

# Validate: at least one mode or --fix-hint standalone
if [[ -z "${MODE}" && "${SHOW_FIX_HINT}" -eq 0 ]]; then
	die "No mode specified. Use --scan-all, --scan-files <files...>, or --fix-hint."
fi

# Standalone --fix-hint (no scan mode)
if [[ -z "${MODE}" && "${SHOW_FIX_HINT}" -eq 1 ]]; then
	print_fix_hint
	exit 0
fi

if [[ "${MODE}" == "scan-files" && "${#SCAN_FILES[@]}" -eq 0 ]]; then
	die "--scan-files requires at least one file argument."
fi

# Build file list
FILES_TO_SCAN=()
if [[ "${MODE}" == "scan-all" ]]; then
	while IFS= read -r -d '' _f; do
		FILES_TO_SCAN+=("${_f}")
	done < <(find "${SCRIPT_DIR}" -name "*.sh" -type f -print0 2>/dev/null | sort -z)
else
	FILES_TO_SCAN=("${SCAN_FILES[@]}")
fi

# Scan files and collect violations in a temp file
VIOLATIONS_FILE=$(mktemp)
trap 'rm -f "${VIOLATIONS_FILE}"' EXIT

FILES_SCANNED=0
FILES_SKIPPED=0

for _f in "${FILES_TO_SCAN[@]}"; do
	if [[ ! -f "${_f}" ]]; then
		printf '[%s] WARNING: skipping (not found): %s\n' "${SCRIPT_NAME}" "${_f}" >&2
		FILES_SKIPPED=$((FILES_SKIPPED + 1))
		continue
	fi
	if [[ "${_f}" != *.sh ]]; then
		continue
	fi
	scan_file "${_f}" "${VIOLATIONS_FILE}"
	FILES_SCANNED=$((FILES_SCANNED + 1))
done

TOTAL_VIOLATIONS=$(wc -l <"${VIOLATIONS_FILE}" | tr -d ' ')

# Report violations
if [[ "${TOTAL_VIOLATIONS}" -gt 0 ]]; then
	printf '%b[FAIL]%b shell-init-pattern-check: %d violation(s) across %d file(s) scanned\n' \
		"${RED}" "${NC}" "${TOTAL_VIOLATIONS}" "${FILES_SCANNED}"
	printf '\n'
	while IFS= read -r _vline; do
		# Format: file:lineno:type:content
		_vfile="${_vline%%:*}"
		_rest="${_vline#*:}"
		_vlineno="${_rest%%:*}"
		_rest="${_rest#*:}"
		_vtype="${_rest%%:*}"
		_vcontent="${_rest#*:}"
		log_violation "${_vfile}" "${_vlineno}" "${_vtype}" "${_vcontent}"
	done <"${VIOLATIONS_FILE}"
	if [[ "${SHOW_FIX_HINT}" -eq 1 ]]; then
		print_fix_hint
	else
		printf '\nRun with --fix-hint for remediation guidance.\n' >&2
	fi
	exit 1
fi

printf '%b[OK]%b shell-init-pattern-check: no violations in %d file(s) scanned\n' \
	"${GREEN}" "${NC}" "${FILES_SCANNED}"
if [[ "${SHOW_FIX_HINT}" -eq 1 ]]; then
	print_fix_hint
fi
exit 0
