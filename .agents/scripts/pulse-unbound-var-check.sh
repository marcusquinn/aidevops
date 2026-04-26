#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-unbound-var-check.sh — CI lint gate for set -u unbound variable bugs (t2863)
# pulse-unbound-var-check:disable — this file contains the anti-pattern regex as a fixture
#
# Detects the high-risk multi-var local declaration without initialisation:
#
#   local foo bar baz        # BAD — under set -u, any of foo/bar/baz that
#                            # are only assigned in conditional branches will
#                            # trigger "unbound variable" if that branch is
#                            # never taken. Canonical failure: t2841 (_b_nums).
#
# Fix: initialise all variables at declaration time:
#
#   local foo="" bar="" baz=""    # explicit empty-string init (most common)
#   local foo=0 bar=0 baz=0       # explicit integer init where appropriate
#   local foo bar                 # single-var is fine; only multi-var is flagged
#
# Usage:
#   pulse-unbound-var-check.sh --scan-files <file1> <file2> ...
#   pulse-unbound-var-check.sh --scan-all
#   pulse-unbound-var-check.sh --fix-hint
#   pulse-unbound-var-check.sh --help
#
# Exit codes:
#   0 — clean (no violations found)
#   1 — violations found
#   2 — usage error
#
# Design:
# - Diff-scoped: CI checks only PR-changed pulse-*.sh files; pre-existing
#   violations on main do not fail CI. New violations in a PR fail CI.
# - File-level opt-out: add "# pulse-unbound-var-check:disable" in first 20
#   lines of a .sh file to skip it (for test fixtures that embed the pattern).
# - Single-variable `local foo` declarations are NOT flagged; only 2+ vars
#   on the same line without any `=` init are flagged.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

SCRIPT_NAME=$(basename "$0")

# The anti-pattern: `local` followed by 2+ space-separated bare identifiers
# (no `=` assignment, no leading `-` flag).
#
# Matches:  "  local foo bar"
#           "  local _a _b _c _d"
#           "\tlocal x y z"
# Does NOT match:
#           "  local foo"               (single var — allowed)
#           "  local foo="" bar=""     (has = init — allowed)
#           "  local -a arr"            (flag form — allowed)
#           "  local foo bar baz=val"   (has partial init — allowed; flag for review)
#
# Pattern breakdown:
#   ^\s+          — leading whitespace (inside a function body)
#   local         — local keyword
#   (\s+-\w+)*    — optional flag(s) like -a, -r, -i
#   \s+           — whitespace
#   [a-zA-Z_]\w* — first identifier (no = following)
#   (\s+[a-zA-Z_]\w*){1,} — one or more additional identifiers (no =)
#   \s*$          — end of line (no = anywhere on the line)
#
# We use grep -P (perl regex) for the negative lookahead on `=`.
readonly ANTI_PATTERN='^\s+local(\s+-\w+)*\s+[a-zA-Z_]\w*(\s+[a-zA-Z_]\w*)+\s*$'

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
	sed -n '5,38p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# _has_disable_directive <filepath> — returns 0 if file opts out
_has_disable_directive() {
	local _file="$1"
	local _head
	_head=$(head -20 "$_file" 2>/dev/null || true)
	if [[ "$_head" == *"pulse-unbound-var-check:disable"* ]]; then
		return 0
	fi
	return 1
}

# _trim — strip leading/trailing whitespace
_trim() {
	local _s="$1"
	_s="${_s#"${_s%%[![:space:]]*}"}"
	_s="${_s%"${_s##*[![:space:]]}"}"
	printf '%s' "$_s"
	return 0
}

# scan_file <filepath> — check a single .sh file for violations.
# Prints violation lines (file:line: <description>) to stdout.
# Returns 0 if clean, 1 if violations found.
scan_file() {
	local _file="$1"
	local _violations=0

	if [[ ! -f "$_file" ]]; then
		log "File not found: $_file"
		return 0
	fi

	# Only scan shell files
	case "$_file" in
	*.sh) ;;
	*) return 0 ;;
	esac

	# File-level opt-out for test fixtures
	if _has_disable_directive "$_file"; then
		return 0
	fi

	# Use grep -E (extended regex) to find multi-var locals without init.
	# Exclude lines that contain `=` (those have at least one init).
	while IFS=: read -r _line_num _content; do
		printf '%s:%s: multi-var local without init (set -u risk): %s\n' \
			"$_file" "$_line_num" "$(_trim "$_content")"
		_violations=$((_violations + 1))
	done < <(grep -nE "$ANTI_PATTERN" "$_file" 2>/dev/null | grep -v '=')

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
		# Only check .sh files in pulse-*.sh scope
		case "$(basename "$_file")" in
		pulse-*.sh) ;;
		*) continue ;;
		esac

		local _output=""
		_output=$(scan_file "$_file" 2>/dev/null) || true
		if [[ -n "$_output" ]]; then
			printf '%s\n' "$_output"
			local _count=0
			_count=$(printf '%s\n' "$_output" | wc -l | tr -d ' ')
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

# cmd_scan_all — scan all pulse-*.sh under .agents/scripts/
cmd_scan_all() {
	local _total_violations=0
	local _files_with_violations=0
	local _repo_root
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

	local _file
	while IFS= read -r _file; do
		[[ -n "$_file" ]] || continue
		local _output=""
		_output=$(scan_file "$_file" 2>/dev/null) || true
		if [[ -n "$_output" ]]; then
			printf '%s\n' "$_output"
			local _count=0
			_count=$(printf '%s\n' "$_output" | wc -l | tr -d ' ')
			_total_violations=$((_total_violations + _count))
			_files_with_violations=$((_files_with_violations + 1))
		fi
	done < <(
		find "${_repo_root}/.agents/scripts" -name 'pulse-*.sh' -type f 2>/dev/null | sort
	)

	_print_summary "$_total_violations" "$_files_with_violations"
	if [[ "$_total_violations" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# cmd_fix_hint — print remediation snippets
# shellcheck disable=SC2016 # single-quoted literals are intentional example patterns
cmd_fix_hint() {
	printf 'Multi-var local without init anti-pattern:\n\n'
	printf '  # BAD — under set -u, conditionally-assigned vars trigger "unbound variable"\n'
	printf '  local _g_nums _b_nums _p_nums child_nums\n\n'
	printf '=== Fix — explicit empty-string init at declaration ===\n\n'
	printf '  local _g_nums="" _b_nums="" _p_nums="" child_nums=""\n\n'
	printf 'For numeric accumulators:\n\n'
	printf '  local total_merged=0 total_closed=0 total_failed=0\n\n'
	printf 'For vars assigned immediately after declaration, the single-var form is safe:\n\n'
	printf '  # OK — assigned on the very next line, set -u cannot fire between them\n'
	printf '  local pr_json\n'
	printf '  pr_json=$(gh pr list ...)\n\n'
	printf 'Canonical failure: t2841 — _b_nums in pulse-issue-reconcile.sh fired 3-7x/cycle.\n'
	printf 'See: t2863 sweep for the full fix pattern across pulse-*.sh.\n'
	return 0
}

# _print_summary — print violation summary
_print_summary() {
	local _total="$1"
	local _files="$2"
	printf '\n--- Pulse Unbound-Var Check ---\n'
	if [[ "$_total" -eq 0 ]]; then
		printf 'No violations found.\n'
	else
		printf 'Found %d violation(s) across %d file(s).\n' "$_total" "$_files"
		printf 'Fix: initialise all vars at declaration: local foo="" bar="" baz=""\n'
		printf 'See: t2863 and reference fix at e05bcae1f (t2841)\n'
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
