#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# stat-portability-check.sh — CI gate for BSD-only stat -f %m usage (GH#21746)
#
# Detects `stat -f.*%m` (BSD/macOS-only) in .agents/scripts/** files outside
# the documented exemptions. Prevents regression of the Linux-incompatible
# stat pattern that PR #21689 migrated to _file_mtime_epoch().
#
# Exemptions:
#   - .agents/scripts/portable-stat.sh       (the helper body itself)
#   - .agents/scripts/shared-constants.sh    (_file_mtime_epoch definition)
#   - .agents/scripts/auto-update-helper-check.sh  (TEMPORARY — remove after
#     the migration PR that fixes this file merges)
#   - tests/ subdirectories
#   - Lines that are comments (leading #)
#   - Occurrences inside Darwin*/FreeBSD* platform-guarded case branches
#
# Usage:
#   .agents/scripts/stat-portability-check.sh [OPTIONS] [FILES...]
#
# Options:
#   --base <ref>       Compare against this git ref (for diff-scoped mode)
#   --dry-run          Report violations; always exit 0
#   --scan-files       Treat all remaining args as a file list (CI mode)
#   --summary          Print only the summary line
#   --no-exit-code     Always exit 0 (advisory mode, alias for --dry-run)
#   --help             Show this help
#
# With no FILES and no --base: scans all git-tracked .sh files under
#   .agents/scripts/ (minus exemptions).
#
# Exit codes:
#   0 — no violations (or --dry-run / --no-exit-code)
#   1 — violations found
#   2 — invocation or environment error
# =============================================================================

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# ---------------------------------------------------------------------------
# Colour helpers (no-op when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
	_SPC_RED=$'\033[0;31m'
	_SPC_YELLOW=$'\033[1;33m'
	_SPC_GREEN=$'\033[0;32m'
	_SPC_BLUE=$'\033[0;34m'
	_SPC_NC=$'\033[0m'
else
	_SPC_RED=''
	_SPC_YELLOW=''
	_SPC_GREEN=''
	_SPC_BLUE=''
	_SPC_NC=''
fi
readonly _SPC_RED _SPC_YELLOW _SPC_GREEN _SPC_BLUE _SPC_NC

_spc_info() {
	local msg="$1"
	printf '%b[stat-portability]%b %s\n' "${_SPC_BLUE}" "${_SPC_NC}" "${msg}"
	return 0
}

_spc_violation() {
	local file_line="$1"
	local snippet="$2"
	printf '%b%s%b: %s\n' "${_SPC_RED}" "${file_line}" "${_SPC_NC}" "${snippet}"
	return 0
}

_spc_ok() {
	local msg="$1"
	printf '%b[stat-portability]%b %s\n' "${_SPC_GREEN}" "${_SPC_NC}" "${msg}"
	return 0
}

usage() {
	sed -n '5,46p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
BASE_REF=""
DRY_RUN=0
NO_EXIT_CODE=0
SUMMARY_ONLY=0
SCAN_FILES_MODE=0
TARGET_FILES=()

_parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--base)
				local _base_val="$1"
				BASE_REF="$_base_val"
				shift
				;;
			--dry-run|--no-exit-code)
				DRY_RUN=1
				NO_EXIT_CODE=1
				;;
			--summary)
				SUMMARY_ONLY=1
				;;
			--scan-files)
				SCAN_FILES_MODE=1
				# All remaining args are files
				while [[ $# -gt 0 ]]; do
					local _sf_arg="$1"
					TARGET_FILES+=("$_sf_arg")
					shift
				done
				;;
			--help|-h)
				usage
				exit 0
				;;
			--)
				shift
				while [[ $# -gt 0 ]]; do
					local _dd_arg="$1"
					TARGET_FILES+=("$_dd_arg")
					shift
				done
				;;
			-*)
				printf 'Unknown option: %s\n' "$arg" >&2
				usage >&2
				exit 2
				;;
			*)
				TARGET_FILES+=("$arg")
				;;
		esac
	done
	return 0
}

_parse_args "$@"

# ---------------------------------------------------------------------------
# Exemption list (canonical)
# ---------------------------------------------------------------------------
# Files entirely exempt from scanning — the pattern is expected/intentional there.
EXEMPT_FILES=(
	".agents/scripts/portable-stat.sh"
	".agents/scripts/shared-constants.sh"
	# TEMPORARY: remove after the migration PR for this file merges (GH#21746)
	".agents/scripts/auto-update-helper-check.sh"
)

_is_exempt_file() {
	local file="$1"
	# Normalise: strip leading ./
	local normalised="${file#./}"
	local exempt
	for exempt in "${EXEMPT_FILES[@]}"; do
		[[ "$normalised" == "${exempt#./}" ]] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# File list resolution
# ---------------------------------------------------------------------------
if [[ ${#TARGET_FILES[@]} -eq 0 && -n "$BASE_REF" ]]; then
	# Diff-scoped mode: only files changed since BASE_REF
	while IFS= read -r f; do
		TARGET_FILES+=("$f")
	done < <(git diff --name-only --diff-filter=ACMR "${BASE_REF}...HEAD" -- \
		'.agents/scripts/*.sh' \
		'.agents/scripts/**/*.sh' 2>/dev/null || true)
elif [[ ${#TARGET_FILES[@]} -eq 0 && "$SCAN_FILES_MODE" -eq 0 ]]; then
	# Default: all tracked .sh files under .agents/scripts/
	while IFS= read -r f; do
		TARGET_FILES+=("$f")
	done < <(git ls-files '.agents/scripts/*.sh' '.agents/scripts/**/*.sh' 2>/dev/null || true)
fi

if [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
	[[ "$SUMMARY_ONLY" -eq 0 ]] && _spc_ok "no .agents/scripts/ shell files to scan"
	exit 0
fi

# ---------------------------------------------------------------------------
# Scan logic
# ---------------------------------------------------------------------------
# Detection: stat -f followed by anything containing %m
# BSD-only forms include:
#   stat -f %m file
#   stat -f "%m" file
#   stat -f'%m' file
_STAT_PATTERN='stat[[:space:]]+-f[[:space:]]+['\''"]?[^[:space:]]*%m'

violations_found=0
violation_lines=()

# _is_in_platform_guard <file> <lineno>
# Returns 0 (in guard) or 1 (not in guard)
# State machine: tracks whether target_lineno falls inside a Darwin/FreeBSD
# arm of a `case "$(uname)" in` block. Scans up to 150 lines backwards.
#
# States: OUT | HEADER | DARWIN | OTHER
#   OUT    — not inside any uname case block
#   HEADER — inside case block, between `case ... in` / `;;` and the next arm
#   DARWIN — inside a Darwin/FreeBSD arm (body lines between pattern and ;;)
#   OTHER  — inside any other arm (Linux, default, etc.)
#
# Key: only look for arm PATTERNS when state==HEADER. This prevents body lines
# ending with ) (e.g., mtime=$(stat -f %m "$file")) from being misidentified
# as arm pattern lines.
_is_in_platform_guard() {
	local file="$1"
	local target_lineno="$2"

	local start_line=$(( target_lineno > 150 ? target_lineno - 150 : 1 ))
	# States: 0=OUT 1=HEADER 2=DARWIN 3=OTHER
	local state=0
	local lineno=0

	while IFS= read -r line; do
		lineno=$(( lineno + 1 ))
		local abs_lineno=$(( start_line + lineno - 1 ))

		# Entering a uname case block
		if printf '%s' "$line" | grep -qE 'case[[:space:]]+"?\$\(uname\)"?[[:space:]]+in'; then
			state=1  # HEADER — now looking for first arm pattern
		fi

		# Arm terminator `;;` — back to HEADER looking for next arm pattern
		if printf '%s' "$line" | grep -qE '^[[:space:]]*;;'; then
			if [[ "$state" -ne 0 ]]; then
				state=1  # HEADER
			fi
		fi

		# esac — back to OUT
		if printf '%s' "$line" | grep -qE '^[[:space:]]*esac([[:space:]]|$)'; then
			state=0  # OUT
		fi

		# Look for arm pattern ONLY when in HEADER state.
		# Arm pattern lines: `word*|word*)` — must end with `)` but NOT
		# contain `$(...)` or backticks (those are body lines, not patterns).
		# Darwin/FreeBSD arm: pattern contains Darwin or FreeBSD.
		if [[ "$state" -eq 1 ]]; then
			# Is this line an arm pattern? Heuristics:
			#  - Ends with ) with only pattern chars before it (no $ subshells)
			#  - Starts at consistent indentation level
			local is_arm_pattern=0
			local trimmed="${line#"${line%%[![:space:]]*}"}"
			# Arm patterns don't contain $( or ` (shell syntax for subshells)
			if printf '%s' "$trimmed" | grep -qE '^\S[^$`]*\)$'; then
				is_arm_pattern=1
			fi
			if [[ "$is_arm_pattern" -eq 1 ]]; then
				if printf '%s' "$line" | grep -qE '(Darwin|FreeBSD|BSD)'; then
					state=2  # DARWIN arm
				else
					state=3  # OTHER arm
				fi
			fi
		fi

		[[ "$abs_lineno" -eq "$target_lineno" ]] && break
	done < <(sed -n "${start_line},${target_lineno}p" "$file" 2>/dev/null || true)

	[[ "$state" -eq 2 ]] && return 0
	return 1
}

scan_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0

	# Only scan .sh files
	case "$file" in
		*.sh) ;;
		*) return 0 ;;
	esac

	# Skip exempted files
	_is_exempt_file "$file" && return 0

	# Skip tests/ directories
	case "$file" in
		*tests/*|*test/*) return 0 ;;
	esac

	# Skip this script itself
	case "$file" in
		*stat-portability-check.sh) return 0 ;;
	esac

	local matches
	matches=$(grep -nE "$_STAT_PATTERN" "$file" 2>/dev/null || true)
	[[ -z "$matches" ]] && return 0

	while IFS= read -r entry; do
		[[ -z "$entry" ]] && continue

		local line_no="${entry%%:*}"
		local content="${entry#*:}"

		# Skip comment lines (leading #, possibly with whitespace)
		local trimmed="${content#"${content%%[![:space:]]*}"}"
		if [[ "${trimmed:0:1}" == "#" ]]; then
			continue
		fi

		# Skip occurrences inside Darwin/FreeBSD platform-guarded case branches
		if _is_in_platform_guard "$file" "$line_no"; then
			continue
		fi

		# Trim leading whitespace from the offending content for compactness.
		content="${content#"${content%%[![:space:]]*}"}"
		violation_lines+=("${file}:${line_no}: ${content}")
		violations_found=$(( violations_found + 1 ))
	done <<< "$matches"

	return 0
}

for f in "${TARGET_FILES[@]}"; do
	scan_file "$f"
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ "$violations_found" -eq 0 ]]; then
	[[ "$SUMMARY_ONLY" -eq 0 ]] && _spc_ok "0 violations across ${#TARGET_FILES[@]} file(s)"
	exit 0
fi

if [[ "$SUMMARY_ONLY" -eq 0 ]]; then
	printf '\n'
	printf '%b[stat-portability]%b %d violation(s) — stat -f %%m is BSD/macOS-only:\n\n' \
		"${_SPC_YELLOW}" "${_SPC_NC}" "$violations_found"
	local_entry=""
	for local_entry in "${violation_lines[@]}"; do
		local_pre="${local_entry%%: *}"
		local_snip="${local_entry#*: }"
		_spc_violation "$local_pre" "$local_snip"
	done
	printf '\n'
	printf 'Fix: replace with _file_mtime_epoch (from shared-constants.sh):\n'
	# shellcheck disable=SC2016 # single-quoted literals are intentional example patterns
	printf '  Before: mtime=$(stat -f %%m "$file")\n'
	# shellcheck disable=SC2016 # single-quoted literals are intentional example patterns
	printf '  After:  mtime=$(_file_mtime_epoch "$file")\n'
	printf '\n'
	printf 'See: .agents/scripts/shared-constants.sh (_file_mtime_epoch)\n'
	printf 'See: .agents/scripts/portable-stat.sh\n'
	printf 'Related: GH#21617, PR#21689\n\n'
fi

if [[ "$NO_EXIT_CODE" -eq 1 ]]; then
	exit 0
fi
exit 1
