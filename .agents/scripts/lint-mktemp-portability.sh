#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# lint-mktemp-portability.sh — static scanner for BSD-incompatible mktemp
# template patterns (XXXXXX followed by an extension).
#
# Issue: GH#21408 (t2997)
# Reference: .agents/reference/shell-style-guide.md § mktemp portability
#
# Bug class:
#   On macOS BSD mktemp, `mktemp prefix-XXXXXX.ext` does NOT substitute the
#   X placeholder when followed by a literal extension. First call returns the
#   literal template; subsequent calls fail with `mkstemp failed: File exists`.
#   GNU mktemp (Linux) accepts both forms, so the bug is invisible in CI until
#   it ships.
#
# Detection rule:
#   - Match `mktemp` invocations whose template argument contains XXXXXX
#     followed by `.<letter>` (i.e. an extension).
#   - Skip `mktemp -d ...` and `mktemp -u ...` (directory and dry-run forms
#     don't trigger the bug).
#   - Skip lines marked `# mktemp-portability: ignore` (inline suppression).
#   - Skip files in this scanner's own ignore list (test fixtures that
#     intentionally exercise the bug — currently none, but reserved).
#
# Usage:
#   .agents/scripts/lint-mktemp-portability.sh [OPTIONS] [FILES...]
#
# Options:
#   --summary       print only the summary line (no per-violation output)
#   --no-exit-code  always exit 0 (advisory mode)
#   --help          show this help
#
# With no FILES: scans all git-tracked .sh, .bash, and .zsh files.
#
# Output format: file:line: <offending mktemp template>
# Exit codes: 0=clean, 1=violations found
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers (no-op when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
	_MTP_RED=$'\033[0;31m'
	_MTP_YELLOW=$'\033[1;33m'
	_MTP_GREEN=$'\033[0;32m'
	_MTP_BLUE=$'\033[0;34m'
	_MTP_NC=$'\033[0m'
else
	_MTP_RED=''
	_MTP_YELLOW=''
	_MTP_GREEN=''
	_MTP_BLUE=''
	_MTP_NC=''
fi
readonly _MTP_RED _MTP_YELLOW _MTP_GREEN _MTP_BLUE _MTP_NC

_mtp_info() {
	local msg="$1"
	printf '%b[mktemp-portability]%b %s\n' "${_MTP_BLUE}" "${_MTP_NC}" "${msg}"
	return 0
}

_mtp_violation() {
	local file_line="$1"
	local snippet="$2"
	printf '%b%s%b: %s\n' "${_MTP_RED}" "${file_line}" "${_MTP_NC}" "${snippet}"
	return 0
}

_mtp_ok() {
	local msg="$1"
	printf '%b[mktemp-portability]%b %s\n' "${_MTP_GREEN}" "${_MTP_NC}" "${msg}"
	return 0
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
SUMMARY_ONLY=0
NO_EXIT_CODE=0
TARGET_FILES=()

usage() {
	local script_path="${BASH_SOURCE[0]}"
	sed -n '/^# ===/,/^# ===/p' "$script_path" | sed 's/^# \?//'
	return 0
}

# Wrap arg parsing in a function so $1/$2 are accessed via `local var="$1"`
# (per .agents/reference/shell-style-guide.md positional-parameter rule).
_parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--summary)
				SUMMARY_ONLY=1
				shift
				;;
			--no-exit-code)
				NO_EXIT_CODE=1
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			--)
				shift
				while [[ $# -gt 0 ]]; do
					local pos="$1"
					TARGET_FILES+=("$pos")
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
				shift
				;;
		esac
	done
	return 0
}

_parse_args "$@"

# ---------------------------------------------------------------------------
# File list resolution
# ---------------------------------------------------------------------------
if [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
	# Default: all tracked .sh files in the repo.
	if ! command -v git >/dev/null 2>&1; then
		printf 'mktemp-portability: git not found and no FILES given\n' >&2
		exit 2
	fi
	while IFS= read -r _f; do TARGET_FILES+=("$_f"); done \
		< <(git ls-files '*.sh' '*.bash' '*.zsh' 2>/dev/null || true)
fi

if [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
	[[ "$SUMMARY_ONLY" -eq 0 ]] && _mtp_ok "no shell files to scan"
	exit 0
fi

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
# The detection regex:
#   - mktemp                 — the command
#   - (?!-[a-zA-Z]*[duqQ][a-zA-Z]*[[:space:]]) — NOT if first flag contains
#                              d/u/q/Q (handles combined flags like -dq, -qu).
#                              NOTE: -t (template prefix) is fine — its template
#                              still goes through the same X-placement rule.
#   - .*X{6,}\.[a-zA-Z]      — XXXXXX (or more) followed by `.<letter>` extension
#
# We use POSIX-friendly grep with -P (PCRE) since rg may not be on the runner.
# Fall back to grep -P if rg unavailable.
#
# Suppression: a line with the comment `# mktemp-portability: ignore` is excluded.

violations_found=0
violation_lines=()

# Build the search pattern. Use a literal-X form to avoid pattern-detection
# hitting the lint script itself.
_pattern='mktemp[[:space:]]+(?!-[a-zA-Z]*[duqQ][a-zA-Z]*[[:space:]])[^|;&)`]*'
_pattern+='X{6,}\.[a-zA-Z]'

scan_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0

	# Skip non-shell files (defensive).
	case "$file" in
		*.sh|*.bash|*.zsh) ;;
		*) return 0 ;;
	esac

	# Skip this script itself — its examples and patterns will trip the regex.
	# (also covers tests/test-lint-mktemp-portability.sh via the *lint... glob)
	case "$file" in
		*lint-mktemp-portability.sh) return 0 ;;
	esac

	local matches
	if command -v rg >/dev/null 2>&1; then
		matches=$(rg --no-heading --line-number --color=never -P "$_pattern" "$file" 2>/dev/null || true)
	else
		matches=$(grep -nP "$_pattern" "$file" 2>/dev/null || true)
	fi

	[[ -z "$matches" ]] && return 0

	# Filter out lines that carry the inline-ignore comment.
	local filtered_lines=()
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		if [[ "$line" == *"# mktemp-portability: ignore"* ]]; then
			continue
		fi
		filtered_lines+=("$line")
	done <<< "$matches"

	[[ ${#filtered_lines[@]} -eq 0 ]] && return 0

	local entry
	for entry in "${filtered_lines[@]}"; do
		# entry format: LINE_NO:CONTENT (ripgrep) or grep variant
		local line_no="${entry%%:*}"
		local content="${entry#*:}"
		# Trim leading whitespace from the offending content for compactness.
		content="${content#"${content%%[![:space:]]*}"}"
		violation_lines+=("${file}:${line_no}: ${content}")
		violations_found=$((violations_found + 1))
	done

	return 0
}

for f in "${TARGET_FILES[@]}"; do
	scan_file "$f"
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ "$violations_found" -eq 0 ]]; then
	[[ "$SUMMARY_ONLY" -eq 0 ]] && _mtp_ok "0 violations across ${#TARGET_FILES[@]} file(s)"
	exit 0
fi

if [[ "$SUMMARY_ONLY" -eq 0 ]]; then
	printf '\n'
	printf '%b[mktemp-portability]%b %d violation(s) — XXXXXX must be at end of mktemp template:\n\n' \
		"${_MTP_YELLOW}" "${_MTP_NC}" "$violations_found"
	for line in "${violation_lines[@]}"; do
		# Split file:line: prefix from snippet.
		local_pre="${line%%: *}"
		local_snip="${line#*: }"
		_mtp_violation "$local_pre" "$local_snip"
	done
	printf '\n'
	# shellcheck disable=SC2016
	printf 'Fix: drop the extension OR use `mktemp -d` + fixed filename.\n'
	printf 'See: .agents/reference/shell-style-guide.md § mktemp portability\n\n'
fi

if [[ "$NO_EXIT_CODE" -eq 1 ]]; then
	exit 0
fi
exit 1
