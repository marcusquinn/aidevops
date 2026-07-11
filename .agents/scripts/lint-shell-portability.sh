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

# Scan every selected file in one awk process. The previous implementation
# spawned three grep processes for every pattern in every file (roughly 100k
# processes for the aidevops repository). Keeping the pattern classification
# and ten-line guard window in one process preserves the diagnostics without
# the process churn that caused high system CPU and fan activity.
_portability_scan_files() {
	local tmp_file="$1"
	shift
	[[ "$#" -gt 0 ]] || return 0

	awk -v output_file="$tmp_file" -v scanner_name="$_PORTABILITY_SCRIPT_NAME" '
		function basename(path, value) {
			value = path
			sub(/^.*\//, "", value)
			return value
		}
		function context_is_guarded(cmd_name, base_cmd, context, start, i) {
			if ($0 ~ /&>\/dev\/null|>\/dev\/null[[:space:]]*2>&1|[[:space:]]\|\|[[:space:]]|2>\/dev\/null/) return 1
			if (FNR > 1 && source_line[FNR - 1] ~ /#[[:space:]]*shell-portability:[[:space:]]*ignore[[:space:]]*(next)?/) return 1
			start = FNR > 10 ? FNR - 10 : 1
			context = ""
			for (i = start; i <= FNR; i++) context = context "\n" source_line[i]
			base_cmd = cmd_name
			sub(/_.*/, "", base_cmd)
			if (context ~ ("command[[:space:]]+-v[[:space:]]+" base_cmd)) return 1
			if (context ~ ("command[[:space:]]+-v[[:space:]]+" cmd_name)) return 1
			if (context ~ /\$\(uname\)|\$\{?OSTYPE\}?|OSTYPE[[:space:]]*=/) return 1
			if (context ~ /#[[:space:]]*shell-portability:[[:space:]]*ignore/) return 1
			if (context ~ /if[[:space:]]+[a-z].*(&>|2>)\/dev\/null/) return 1
			if (context ~ /if[[:space:]]+[a-z].*>\/dev\/null.*2>&1/) return 1
			return 0
		}
		function report(pattern, cmd_name, display_name, platform) {
			if ($0 ~ pattern && !context_is_guarded(cmd_name)) {
				printf "%s:%d: unguarded %s [%s]\n", FILENAME, FNR, display_name, platform >> output_file
			}
		}
		FNR == 1 {
			for (i in source_line) delete source_line[i]
			skip_file = basename(FILENAME) == scanner_name || FILENAME ~ /bash-compat\.md/ || FILENAME ~ /(^|\/)tests\//
		}
		{
			source_line[FNR] = $0
			if (skip_file || $0 ~ /^[[:space:]]*#/ || $0 ~ /command[[:space:]]+-v[[:space:]]/) next
			if ($0 !~ /(getent|sha256sum|readlink|stat|date|timeout|sed|grep|xargs|find|mktemp|base64|dscl|sw_vers|launchctl|pbcopy|pbpaste|defaults|security|codesign)/) next
			report("(^|[[:space:]]|[({;&])getent[[:space:]]", "getent", "getent", "linux-only")
			report("(^|[[:space:]]|[({;&])sha256sum[[:space:]]", "sha256sum", "sha256sum", "linux-only")
			report("(^|[[:space:]]|[({;&])readlink[[:space:]]*-[a-zA-Z]*f", "readlink_f", "readlink -f", "linux-only")
			report("(^|[[:space:]]|[({;&])stat[[:space:]]*(-c[[:space:]]|-c%|--format)", "stat_c", "stat -c/--format", "linux-only")
			report("(^|[[:space:]]|[({;&])date[[:space:]]+-d[[:space:]]", "date_d", "date -d", "linux-only")
			report("(^|[[:space:]]|[({;&])timeout[[:space:]]+[0-9]", "timeout_cmd", "timeout", "linux-only")
			report("(^|[[:space:]]|[({;&])sed[[:space:]]*(-[a-zA-Z]*r[^e]|-[a-zA-Z]*r$)", "sed_r", "sed -r", "linux-only")
			report("(^|[[:space:]]|[({;&])grep[[:space:]]*(-[a-zA-Z]*P[^C]|-[a-zA-Z]*P$)", "grep_P", "grep -P", "linux-only")
			report("(^|[[:space:]]|[({;&])xargs[[:space:]]*-[a-zA-Z]*r[[:space:]]", "xargs_r", "xargs -r", "linux-only")
			report("(^|[[:space:]]|[({;&])find[^(]*-printf[[:space:]]", "find_printf", "find -printf", "linux-only")
			report("(^|[[:space:]]|[({;&])mktemp[[:space:]]*--suffix", "mktemp_suffix", "mktemp --suffix", "linux-only")
			report("(^|[[:space:]]|[({;&])base64[[:space:]]*-[a-zA-Z]*w[[:space:]]", "base64_w", "base64 -w", "linux-only")
			report("(^|[[:space:]]|[({;&])dscl[[:space:]]", "dscl", "dscl", "macos-only")
			report("(^|[[:space:]]|[({;&])sw_vers[[:space:]]", "sw_vers", "sw_vers", "macos-only")
			report("(^|[[:space:]]|[({;&])launchctl[[:space:]]", "launchctl", "launchctl", "macos-only")
			report("(^|[[:space:]]|[({;&])pbcopy[[:space:]]", "pbcopy", "pbcopy", "macos-only")
			report("(^|[[:space:]]|[({;&])pbpaste[[:space:]]", "pbpaste", "pbpaste", "macos-only")
			report("(^|[[:space:]]|[({;&])defaults[[:space:]]+(read|write|delete|export|import)", "defaults_plist", "defaults", "macos-only")
			report("(^|[[:space:]]|[({;&])security[[:space:]]+(find-generic-password|add-generic-password|find-internet-password|delete-generic-password)", "security_keychain", "security (keychain)", "macos-only")
			report("(^|[[:space:]]|[({;&])codesign[[:space:]]", "codesign", "codesign", "macos-only")
		}
	' "$@"
	return $?
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
	local scan_files=()
	for file in "${files[@]}"; do
		[[ -f "$file" ]] && scan_files+=("$file")
	done
	_portability_scan_files "$tmp_violations" "${scan_files[@]}"

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
