#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# counter-stack-check.sh — CI lint gate for grep -c counter-stacking bug (t2762/t2763)
# counter-stack-check:disable — this file contains the anti-pattern regex as a fixture
#
# Detects the bug class:
#   count=$(... grep -c 'pat' ... || echo "N")
#
# grep -c outputs N to stdout AND exits 1 when there are zero matches, so the
# `|| echo "N"` fallback runs AND its output is APPENDED to grep's "0",
# yielding a multi-line string ("0\nN") instead of the expected single integer.
# Canonical failure: parent issue #20402 rendered "Progress: **0\n0 done**".
#
# Replace with the canonical pattern:
#   source shared-constants.sh; count=$(safe_grep_count 'pat' file)
# OR inline form (when shared-constants.sh is unavailable):
#   count=$(grep -c 'pat' file 2>/dev/null || true)
#   [[ "$count" =~ ^[0-9]+$ ]] || count=0
#
# Usage:
#   counter-stack-check.sh --scan-files <file1> <file2> ...
#   counter-stack-check.sh --scan-all
#   counter-stack-check.sh --fix-hint
#   counter-stack-check.sh --help
#
# Exit codes:
#   0 — clean (no violations found)
#   1 — violations found
#   2 — usage error
#
# Design:
# - Diff-scoped scanning (Option A from t2053): existing violations on main do
#   not fail CI; only PR-touched files are checked. Phase 2 sweep clears them.
# - Scans both .sh and .yml files (the bug appears in both).
# - File-level opt-out: `# counter-stack-check:disable` in first 20 lines
#   (shell) or `# counter-stack-check:disable` anywhere (YAML). For test
#   fixtures that embed the anti-pattern deliberately.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

SCRIPT_NAME=$(basename "$0")

# The anti-pattern. Matches `grep -c ... || echo "N"` where N is 0-9.
# Captures the shape: grep -c, optional args that don't include a pipe, ||,
# optional whitespace, echo, optional whitespace, quoted integer.
readonly ANTI_PATTERN='grep -c[^|]*\|\|[[:space:]]*echo[[:space:]]*"[0-9]+"'

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
	sed -n '5,37p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# _has_disable_directive <filepath> — returns 0 if file contains the
# opt-out directive in first 20 lines. Used by test fixtures.
_has_disable_directive() {
	local _file="$1"
	local _head
	_head=$(head -20 "$_file" 2>/dev/null || true)
	if [[ "$_head" == *"counter-stack-check:disable"* ]]; then
		return 0
	fi
	return 1
}

# scan_file <filepath> — check a single file for violations.
# Prints violation lines (file:line: <matched content>) to stdout.
# Returns 0 if clean, 1 if violations found.
scan_file() {
	local _file="$1"
	local _violations=0

	if [[ ! -f "$_file" ]]; then
		log "File not found: $_file"
		return 0
	fi

	# File-level opt-out for test fixtures
	if _has_disable_directive "$_file"; then
		return 0
	fi

	# grep -nE prints line numbers; we post-format for the CI report.
	# Use a temp file because pipes mask exit codes under `set -u`.
	local _tmp
	_tmp=$(mktemp)
	if grep -nE "$ANTI_PATTERN" "$_file" >"$_tmp" 2>/dev/null; then
		while IFS=: read -r _line_num _content; do
			printf '%s:%s: counter-stacking: %s\n' "$_file" "$_line_num" "$(_trim "$_content")"
			_violations=$((_violations + 1))
		done <"$_tmp"
	fi
	rm -f "$_tmp"

	if [[ "$_violations" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# _trim — strip leading/trailing whitespace from $1
_trim() {
	local _s="$1"
	_s="${_s#"${_s%%[![:space:]]*}"}"
	_s="${_s%"${_s##*[![:space:]]}"}"
	printf '%s' "$_s"
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
		# Only check .sh and .yml files
		case "$_file" in
		*.sh | *.yml | *.yaml) ;;
		*) continue ;;
		esac

		local _output
		_output=$(scan_file "$_file" 2>/dev/null)
		local _rc=$?
		if [[ $_rc -eq 1 && -n "$_output" ]]; then
			printf '%s\n' "$_output"
			local _count
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

# cmd_scan_all — scan every .sh and .yml under .agents/ and .github/
cmd_scan_all() {
	local _total_violations=0
	local _files_with_violations=0
	local _repo_root
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

	local _file
	while IFS= read -r _file; do
		[[ -n "$_file" ]] || continue
		local _output
		_output=$(scan_file "$_file" 2>/dev/null)
		local _rc=$?
		if [[ $_rc -eq 1 && -n "$_output" ]]; then
			printf '%s\n' "$_output"
			local _count
			_count=$(printf '%s\n' "$_output" | wc -l | tr -d ' ')
			_total_violations=$((_total_violations + _count))
			_files_with_violations=$((_files_with_violations + 1))
		fi
	done < <(
		find "${_repo_root}/.agents" "${_repo_root}/.github" \
			\( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \) -type f 2>/dev/null | sort
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
	printf 'Counter-stacking anti-pattern:\n\n'
	printf '  # BAD — produces "0\\n0" on zero-match path because grep -c exits 1\n'
	printf '  count=$(grep -c '"'"'pat'"'"' file 2>/dev/null || echo "0")\n\n'
	printf '=== Fix A (preferred) — source shared-constants.sh and use safe_grep_count ===\n\n'
	printf '  source "${SCRIPT_DIR}/shared-constants.sh"\n'
	printf '  count=$(safe_grep_count '"'"'pat'"'"' file)\n'
	printf '  count=$(printf '"'"'%%s\\n'"'"' "$data" | safe_grep_count '"'"'needle'"'"')\n\n'
	printf '=== Fix B (fallback) — inline regex guard ===\n\n'
	printf '  Use this in YAML workflow steps and bootstrap scripts that cannot\n'
	printf '  source shared-constants.sh:\n\n'
	printf '  count=$(grep -c '"'"'pat'"'"' file 2>/dev/null || true)\n'
	printf '  [[ "$count" =~ ^[0-9]+$ ]] || count=0\n\n'
	printf 'See: .agents/reference/shell-style-guide.md § Counter Safety (grep -c)\n'
	return 0
}

# _print_summary — print violation summary
_print_summary() {
	local _total="$1"
	local _files="$2"
	printf '\n--- Counter-Stack Check ---\n'
	if [[ "$_total" -eq 0 ]]; then
		printf 'No violations found.\n'
	else
		printf 'Found %d violation(s) across %d file(s).\n' "$_total" "$_files"
		printf 'See: .agents/reference/shell-style-guide.md § Counter Safety (grep -c)\n'
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
