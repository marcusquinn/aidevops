#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2317
# =============================================================================
# lint-shell-portability.sh — static scanner for unguarded platform-specific
# command calls in shell scripts.
#
# Issue: GH#18787 (t2076)
# Reference: .agents/reference/bash-compat.md (the full pattern table)
#
# Usage:
#   .agents/scripts/lint-shell-portability.sh [OPTIONS] [FILES...]
#
# Options:
#   --summary       print only a summary line (no per-violation output)
#   --no-exit-code  always exit 0 (advisory mode)
#   --help          show this help
#
# With no FILES: scans all git-tracked .sh files via git ls-files
#
# Output format: file:line: unguarded <cmd> [linux-only|macos-only]
# Exit codes: 0=clean, 1=violations found
#
# Guards recognised (in a window of 5 preceding lines + hit line):
#   command -v <cmd>                  — explicit availability check
#   $(uname) or $OSTYPE or OSTYPE     — platform branch
#   2>/dev/null on the hit line       — failure is handled (silent fallback)
#   # shell-portability: ignore next  — inline suppression (on preceding line)
#
# Inline suppression (rare legitimate cases):
#   Add the comment on the line BEFORE the unguarded call:
#     # shell-portability: ignore next
#     launchctl load "$PLIST"   # <- suppressed
#
# Files excluded from scanning:
#   - This script itself (its grep patterns contain the command names as text)
#   - .agents/reference/bash-compat.md (documentation, not runnable code)
#   - Files matching **/tests/fixtures/**
# =============================================================================

set -euo pipefail

_PORTABILITY_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly _PORTABILITY_SCRIPT_NAME

# ---------------------------------------------------------------------------
# Colour helpers (no-op when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
	readonly _PC_RED='\033[0;31m'
	readonly _PC_YELLOW='\033[1;33m'
	readonly _PC_BLUE='\033[0;34m'
	readonly _PC_NC='\033[0m'
else
	readonly _PC_RED=''
	readonly _PC_YELLOW=''
	readonly _PC_BLUE=''
	readonly _PC_NC=''
fi

_pc_info() {
	printf '%b[portability]%b %s\n' "${_PC_BLUE}" "${_PC_NC}" "$1"
	return 0
}
_pc_warn() {
	printf '%b[portability]%b %s\n' "${_PC_YELLOW}" "${_PC_NC}" "$1"
	return 0
}
_pc_error() {
	printf '%b[portability-error]%b %s\n' "${_PC_RED}" "${_PC_NC}" "$1" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Command table — format: CMD_NAME|ERE_PATTERN|PLATFORM
#
# CMD_NAME  — short identifier (used in guard-detection: command -v <CMD_NAME>)
# ERE_PATTERN — POSIX ERE; must NOT use PCRE (\b, \s, etc.); use [[:space:]], etc.
# PLATFORM — linux-only or macos-only
#
# Guidelines:
#  - Anchor patterns so they don't match comments or substrings
#  - The pattern is tested against the full line content; comment lines
#    (leading optional whitespace + #) are pre-filtered before matching
# ---------------------------------------------------------------------------
_portability_cmd_list() {
	# Each line: CMD_NAME@ERE_PATTERN@PLATFORM
	#
	# Separator is '@' (not '|') because ERE patterns use '|' for alternation.
	#
	# ERE anchor convention:
	#   Use (^|[[:space:]]|[({;&]) before the command name to avoid matching
	#   compound flag names like --connect-timeout or string literals like .timeout.
	#   The group avoids the '|' inside [...] which conflicts with the separator.
	#
	# Linux-only commands (crash on macOS: "command not found" or wrong flags)
	cat <<'CMDEOF'
getent@(^|[[:space:]]|[({;&])getent[[:space:]]@linux-only
sha256sum@(^|[[:space:]]|[({;&])sha256sum[[:space:]]@linux-only
readlink_f@(^|[[:space:]]|[({;&])readlink[[:space:]]*-[a-zA-Z]*f@linux-only
stat_c@(^|[[:space:]]|[({;&])stat[[:space:]]*(-c[[:space:]]|-c%|--format)@linux-only
date_d@(^|[[:space:]]|[({;&])date[[:space:]]+-d[[:space:]]@linux-only
timeout_cmd@(^|[[:space:]]|[({;&])timeout[[:space:]]+[0-9]@linux-only
sed_r@(^|[[:space:]]|[({;&])sed[[:space:]]*(-[a-zA-Z]*r[^e]|-[a-zA-Z]*r$)@linux-only
grep_P@(^|[[:space:]]|[({;&])grep[[:space:]]*(-[a-zA-Z]*P[^C]|-[a-zA-Z]*P$)@linux-only
xargs_r@(^|[[:space:]]|[({;&])xargs[[:space:]]*-[a-zA-Z]*r[[:space:]]@linux-only
find_printf@(^|[[:space:]]|[({;&])find[^(]*-printf[[:space:]]@linux-only
mktemp_suffix@(^|[[:space:]]|[({;&])mktemp[[:space:]]*--suffix@linux-only
base64_w@(^|[[:space:]]|[({;&])base64[[:space:]]*-[a-zA-Z]*w[[:space:]]@linux-only
dscl@(^|[[:space:]]|[({;&])dscl[[:space:]]@macos-only
sw_vers@(^|[[:space:]]|[({;&])sw_vers[[:space:]]@macos-only
launchctl@(^|[[:space:]]|[({;&])launchctl[[:space:]]@macos-only
pbcopy@(^|[[:space:]]|[({;&])pbcopy[[:space:]]@macos-only
pbpaste@(^|[[:space:]]|[({;&])pbpaste[[:space:]]@macos-only
defaults_plist@(^|[[:space:]]|[({;&])defaults[[:space:]]+(read|write|delete|export|import)@macos-only
security_keychain@(^|[[:space:]]|[({;&])security[[:space:]]+(find-generic-password|add-generic-password|find-internet-password|delete-generic-password)@macos-only
codesign@(^|[[:space:]]|[({;&])codesign[[:space:]]@macos-only
CMDEOF
	return 0
}

# ---------------------------------------------------------------------------
# _portability_is_guarded: check whether a hit is covered by a guard.
#
# Args: $1=file $2=line_num $3=cmd_name (for command -v check)
# Returns: 0 if guarded (safe), 1 if unguarded (violation)
# ---------------------------------------------------------------------------
_portability_is_guarded() {
	local file="$1"
	local line_num="$2"
	local cmd_name="$3"

	# Extract the hit line itself
	local hit_line
	hit_line=$(sed -n "${line_num}p" "$file" 2>/dev/null) || return 1

	# Guard 1: failure-is-handled on the hit line — any of these patterns means
	# the developer acknowledged that the command might not be available:
	#   cmd &>/dev/null               — both stdout+stderr suppressed
	#   cmd >/dev/null 2>&1           — same, alternate form
	#   cmd 2>/dev/null || fallback   — stderr suppressed + explicit fallback
	#   cmd ... || true               — failure explicitly caught
	#   cmd ... || return             — failure caught and returns
	#   cmd ... || :                  — failure caught with no-op
	if echo "$hit_line" | grep -qE '&>/dev/null'; then
		return 0
	fi
	if echo "$hit_line" | grep -qE '>/dev/null[[:space:]]*2>&1'; then
		return 0
	fi
	# Any || fallback on the same line: || true, || return, || echo, || die, etc.
	if echo "$hit_line" | grep -qE '[[:space:]]\|\|[[:space:]]'; then
		return 0
	fi
	# Pipeline end: cmd 2>/dev/null (no fallback — stderr suppressed + output captured)
	# This covers: result=$(cmd 2>/dev/null) pattern where empty result is handled downstream
	if echo "$hit_line" | grep -qE '2>/dev/null'; then
		return 0
	fi

	# Guard 2: check the preceding line for inline suppression
	if [[ "$line_num" -gt 1 ]]; then
		local prev_line
		prev_line=$(sed -n "$((line_num - 1))p" "$file" 2>/dev/null) || true
		if echo "$prev_line" | grep -qE '#[[:space:]]*shell-portability:[[:space:]]*ignore[[:space:]]*(next)?'; then
			return 0
		fi
	fi

	# Guard 3: context window (10 preceding lines + hit line)
	# 10 lines covers the common BSD-vs-GNU if/else probing patterns like:
	#   if [[ "$(uname)" == "Darwin" ]]; then
	#       ...
	#   else
	#       stat -c %Y ...   # <- hit, uname check is up to 8 lines above
	#   fi
	local start=$((line_num > 10 ? line_num - 10 : 1))
	local context
	context=$(sed -n "${start},${line_num}p" "$file" 2>/dev/null) || return 1

	# Guard 3a: command -v <cmd_name> in the context window
	# Match the canonical form of the cmd_name (strip _suffix like _f, _c, _d, etc.)
	local base_cmd="${cmd_name%%_*}"
	if echo "$context" | grep -qE "command[[:space:]]+-v[[:space:]]+${base_cmd}"; then
		return 0
	fi
	# Also check for the full cmd_name (e.g., command -v sha256sum)
	if echo "$context" | grep -qE "command[[:space:]]+-v[[:space:]]+${cmd_name}"; then
		return 0
	fi

	# Guard 3b: uname / OSTYPE platform check in the context window
	if echo "$context" | grep -qE '\$\(uname\)|\$\{?OSTYPE\}?|OSTYPE[[:space:]]*='; then
		return 0
	fi

	# Guard 3c: shell-portability: ignore in context (covers "ignore" without "next")
	if echo "$context" | grep -qE '#[[:space:]]*shell-portability:[[:space:]]*ignore'; then
		return 0
	fi

	# Guard 3d: BSD-probe pattern in context — an `if <cmd> ...` check on a
	# preceding line that tests for platform-specific command availability.
	# Covers patterns like:
	#   if date -v-1d &>/dev/null; then ... else date -d ...
	#   if date -v -90d >/dev/null 2>&1; then ... else date -d ...
	if echo "$context" | grep -qE 'if[[:space:]]+[a-z].*&>/dev/null'; then
		return 0
	fi
	if echo "$context" | grep -qE 'if[[:space:]]+[a-z].*2>/dev/null'; then
		return 0
	fi
	if echo "$context" | grep -qE 'if[[:space:]]+[a-z].*>/dev/null.*2>&1'; then
		return 0
	fi

	return 1
}

# ---------------------------------------------------------------------------
# _portability_scan_file: scan a single file for violations.
# Appends findings to $2 (tmp file). Args: $1=file $2=tmp_file
# Returns: 0 always (findings go to tmp_file)
# ---------------------------------------------------------------------------
_portability_scan_file() {
	local file="$1"
	local tmp_file="$2"

	# Skip the scanner itself (its patterns contain command names as literals)
	[[ "$(basename "$file")" == "$_PORTABILITY_SCRIPT_NAME" ]] && return 0

	# Skip bash-compat.md (documentation, not runnable code)
	case "$file" in
	*bash-compat.md*) return 0 ;;
	esac

	# Skip test directories — test scripts intentionally use platform-specific tools
	# for CI testing and shouldn't be held to the same portability standard.
	case "$file" in
	*/tests/fixtures/*) return 0 ;;
	tests/*) return 0 ;;
	*/tests/*.sh) return 0 ;;
	esac

	[[ -f "$file" ]] || return 0

	# Process each command in the command table
	while IFS='@' read -r cmd_name pattern platform; do
		# Skip blank lines or comment lines in the heredoc
		[[ -z "$cmd_name" || "${cmd_name:0:1}" == "#" ]] && continue

		# Find all matching lines (exclude pure comment lines via grep -v)
		# grep -n returns "linenum:content"
		local matches
		matches=$(grep -nE "$pattern" "$file" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' |
			grep -vE "command[[:space:]]+-v[[:space:]]" ||
			true)

		[[ -z "$matches" ]] && continue

		while IFS= read -r match_line; do
			[[ -z "$match_line" ]] && continue

			# Extract line number (everything before first ':')
			local line_num="${match_line%%:*}"
			# Validate it's a number
			[[ "$line_num" =~ ^[0-9]+$ ]] || continue

			if ! _portability_is_guarded "$file" "$line_num" "$cmd_name"; then
				# Build human-readable display name from cmd_name identifier
				local display_cmd
				case "$cmd_name" in
				timeout_cmd) display_cmd="timeout" ;;
				readlink_f) display_cmd="readlink -f" ;;
				stat_c) display_cmd="stat -c/--format" ;;
				date_d) display_cmd="date -d" ;;
				sed_r) display_cmd="sed -r" ;;
				grep_P) display_cmd="grep -P" ;;
				xargs_r) display_cmd="xargs -r" ;;
				find_printf) display_cmd="find -printf" ;;
				mktemp_suffix) display_cmd="mktemp --suffix" ;;
				base64_w) display_cmd="base64 -w" ;;
				defaults_plist) display_cmd="defaults" ;;
				security_keychain) display_cmd="security (keychain)" ;;
				sw_vers) display_cmd="sw_vers" ;;
				*) display_cmd="${cmd_name%%_*}" ;;
				esac
				printf '%s:%s: unguarded %s [%s]\n' "$file" "$line_num" "$display_cmd" "$platform" >>"$tmp_file"
			fi
		done <<<"$matches"

	done < <(_portability_cmd_list)

	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	local summary_only=false
	local no_exit_code=false
	local explicit_files=()

	# Parse arguments
	local arg
	for arg in "$@"; do
		case "$arg" in
		--summary) summary_only=true ;;
		--no-exit-code) no_exit_code=true ;;
		--help)
			sed -n '/^# =/,/^# =/p' "${BASH_SOURCE[0]}" 2>/dev/null | grep '^#' | sed 's/^# \?//'
			exit 0
			;;
		-*)
			_pc_error "Unknown flag: $arg"
			exit 2
			;;
		*) explicit_files+=("$arg") ;;
		esac
	done

	# Resolve file list
	local files=()
	if [[ "${#explicit_files[@]}" -gt 0 ]]; then
		files=("${explicit_files[@]}")
	else
		# Default: all git-tracked .sh files
		while IFS= read -r f; do
			[[ -n "$f" ]] && files+=("$f")
		done < <(git ls-files '*.sh' 2>/dev/null || true)
		if [[ "${#files[@]}" -eq 0 ]]; then
			_pc_warn "No tracked .sh files found (is this a git repo?)"
			exit 0
		fi
	fi

	[[ "$summary_only" == "false" ]] && _pc_info "Scanning ${#files[@]} shell file(s) for unguarded platform-specific commands..."

	# Collect violations in a temp file
	local tmp_violations
	tmp_violations=$(mktemp 2>/dev/null || mktemp -t portability.XXXXXX)
	# shellcheck disable=SC2064
	trap "rm -f '${tmp_violations}'" EXIT

	local file
	for file in "${files[@]}"; do
		_portability_scan_file "$file" "$tmp_violations"
	done

	# Report results
	local violation_count=0
	if [[ -s "$tmp_violations" ]]; then
		violation_count=$(wc -l <"$tmp_violations")
		violation_count="${violation_count//[^0-9]/}"
		violation_count="${violation_count:-0}"

		if [[ "$summary_only" == "false" ]]; then
			printf '\n'
			while IFS= read -r line; do
				printf '%b%s%b\n' "${_PC_RED}" "$line" "${_PC_NC}"
			done <"$tmp_violations"
			printf '\n'
			_pc_error "${violation_count} unguarded platform-specific command(s) found."
			# shellcheck disable=SC2016
			printf 'Fix: add `command -v <cmd>` guard, `[[ "$(uname)" == "Linux" ]]` branch,\n'
			# shellcheck disable=SC2016
			printf '     or add `# shell-portability: ignore next` above the call.\n'
			printf 'Ref: .agents/reference/bash-compat.md\n'
		else
			printf 'shell-portability: %d violation(s)\n' "$violation_count"
		fi
	else
		if [[ "$summary_only" == "false" ]]; then
			_pc_info "No unguarded platform-specific commands found."
		else
			printf 'shell-portability: clean\n'
		fi
	fi

	if [[ "$no_exit_code" == "true" ]]; then
		return 0
	fi

	[[ "$violation_count" -eq 0 ]] && return 0 || return 1
}

main "$@"
