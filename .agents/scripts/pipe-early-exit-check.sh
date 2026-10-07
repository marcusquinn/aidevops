#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pipe-early-exit-check.sh — diff-scoped gate for early-exit pipe readers under pipefail
# pipe-early-exit-check:disable — this file contains the anti-pattern regex as documentation
#
# Detects the bug class (in scripts that enable pipefail):
#   writer | grep -q PATTERN      writer | grep -m1 PATTERN      writer | head -n N
#
# The reader exits after its first match and closes the pipe. A writer that is
# still producing output receives SIGPIPE (exit 141), and pipefail reports 141
# instead of the reader's 0: a false "no match" that depends on input size and
# pipe buffer timing (#27981, #30824, #33882).
#
# Usage:
#   pipe-early-exit-check.sh --scan-files [--diff-base <ref>] <file1> <file2> ...
#   pipe-early-exit-check.sh --scan-all
#   pipe-early-exit-check.sh --fix-hint
#   pipe-early-exit-check.sh --help
#
# Exit codes:
#   0 — clean
#   1 — violations found
#   2 — usage error
#
# Design:
# - With --diff-base <ref>, only lines added relative to <ref> are judged, so
#   legacy matches in touched files never fail a PR.
# - Only files that enable pipefail (set -o pipefail / set -euo pipefail) are judged.
# - Comment lines are skipped. Here-string forms (grep -q … <<<"$x") have no pipe.
# - File-level opt-out: `# pipe-early-exit-check:disable` in the first 20 lines.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")

# Awk ERE fragments (kept in variables so the awk program stays readable).
readonly PIPEFAIL_RE='^[[:space:]]*set[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(-[a-zA-Z]*o[[:space:]]+pipefail|-o[[:space:]]+pipefail)'
readonly GREP_RE='(^|[^|])[|][[:space:]]*(e|f)?grep[[:space:]]+(-[-a-zA-Z0-9=]+[[:space:]]+)*(-[a-zA-Z]*q[a-zA-Z]*|--quiet|--silent|-m[[:space:]]*1|--max-count[= ]1)([[:space:]]|$)'
readonly HEAD_RE='(^|[^|])[|][[:space:]]*head([[:space:]]|$|[)])'

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
	sed -n '5,32p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

_has_disable_directive() {
	local _file="$1"
	local _head
	_head=$(head -20 "$_file" 2>/dev/null || true)
	if [[ "$_head" == *"pipe-early-exit-check:disable"* ]]; then
		return 0
	fi
	return 1
}

# _added_lines <base> <file> — print space-delimited added line numbers.
_added_lines() {
	local _base="$1"
	local _file="$2"
	git diff -U0 --no-color "$_base" -- "$_file" 2>/dev/null | awk '
		/^@@ / {
			plus = $(NF - 1); sub(/^\+/, "", plus)
			n = split(plus, a, ",")
			start = a[1] + 0
			cnt = (n > 1) ? a[2] + 0 : 1
			for (i = 0; i < cnt; i++) printf "%d ", start + i
		}'
	return 0
}

# scan_file <file> [base] — print "file:line: early-exit pipe: <content>" findings.
# Returns 1 if any finding, else 0.
scan_file() {
	local _file="$1"
	local _base="${2:-}"
	local _added="ALL"

	if [[ ! -f "$_file" ]]; then
		log "File not found: $_file"
		return 0
	fi
	if _has_disable_directive "$_file"; then
		return 0
	fi
	if [[ -n "$_base" ]]; then
		_added=$(_added_lines "$_base" "$_file")
		[[ -n "$_added" ]] || return 0
	fi

	local _out
	_out=$(awk -v file="$_file" -v added=" ${_added} " \
		-v pf_re="$PIPEFAIL_RE" -v grep_re="$GREP_RE" -v head_re="$HEAD_RE" '
		{ lines[NR] = $0 }
		/^[[:space:]]*#/ { next }
		$0 ~ pf_re { pf = 1 }
		END {
			if (!pf) exit
			for (i = 1; i <= NR; i++) {
				l = lines[i]
				if (l ~ /^[[:space:]]*#/) continue
				if (added != " ALL " && index(added, " " i " ") == 0) continue
				if (l ~ grep_re || l ~ head_re) {
					sub(/^[[:space:]]+/, "", l)
					printf "%s:%d: early-exit pipe under pipefail: %s\n", file, i, l
				}
			}
		}' "$_file")

	if [[ -n "$_out" ]]; then
		printf '%s\n' "$_out"
		return 1
	fi
	return 0
}

_print_summary() {
	local _total="$1"
	local _files="$2"
	printf '\n--- Pipe Early-Exit Check ---\n'
	if [[ "$_total" -eq 0 ]]; then
		printf 'No violations found.\n'
	else
		printf 'Found %d violation(s) across %d file(s).\n' "$_total" "$_files"
		printf 'Run %s --fix-hint or see: .agents/reference/shell-style-guide.md § Early-Exit Pipe Readers (SIGPIPE)\n' "$SCRIPT_NAME"
	fi
	return 0
}

# _scan_list <base> <file...> — scan files, print findings and summary.
_scan_list() {
	local _base="$1"
	shift
	local _total=0
	local _files=0
	local _file _output _count

	for _file in "$@"; do
		case "$_file" in
		*.sh) ;;
		*) continue ;;
		esac
		_output=$(scan_file "$_file" "$_base")
		if [[ -n "$_output" ]]; then
			printf '%s\n' "$_output"
			_count=$(printf '%s\n' "$_output" | wc -l | tr -d ' ')
			_total=$((_total + _count))
			_files=$((_files + 1))
		fi
	done

	_print_summary "$_total" "$_files"
	if [[ "$_total" -gt 0 ]]; then
		return 1
	fi
	return 0
}

cmd_scan_files() {
	local -a _args=("$@")
	local _base=""
	if [[ "${_args[0]:-}" == "--diff-base" ]]; then
		[[ ${#_args[@]} -ge 2 ]] || die "--diff-base requires a ref"
		_base="${_args[1]}"
		_args=("${_args[@]:2}")
	fi
	if [[ ${#_args[@]} -eq 0 ]]; then
		die "No files specified. Usage: $SCRIPT_NAME --scan-files [--diff-base <ref>] <file1> ..."
	fi
	_scan_list "$_base" "${_args[@]}"
	return $?
}

cmd_scan_all() {
	local _root
	_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	local _files=()
	local _f
	while IFS= read -r _f; do
		[[ -n "$_f" ]] && _files+=("$_f")
	done < <(find "${_root}/.agents" -name '*.sh' -type f 2>/dev/null | sort)
	if [[ ${#_files[@]} -eq 0 ]]; then
		_print_summary 0 0
		return 0
	fi
	_scan_list "" "${_files[@]}"
	return $?
}

# shellcheck disable=SC2016 # single-quoted literals are intentional example patterns
cmd_fix_hint() {
	printf 'Early-exit pipe reader under pipefail:\n\n'
	printf '  # BAD — grep -q exits on first match; a still-writing producer gets SIGPIPE (141)\n'
	printf '  printf '"'"'%%s\\n'"'"' "$body" | grep -qF "$marker"\n\n'
	printf '=== Fix A (preferred) — here-string, no pipe ===\n\n'
	printf '  grep -qF -- "$marker" <<<"$body"\n\n'
	printf '=== Fix B — capture first, then test ===\n\n'
	printf '  out=$(writer) || return 1\n'
	printf '  [[ "$out" == *"$marker"* ]]\n\n'
	printf '=== Fix C — only when the writer status is genuinely irrelevant ===\n\n'
	printf '  { writer || true; } | grep -q "$marker"\n\n'
	printf 'See: .agents/reference/shell-style-guide.md § Early-Exit Pipe Readers (SIGPIPE)\n'
	return 0
}

main() {
	if [[ $# -eq 0 ]]; then
		usage
		exit 2
	fi
	local _cmd="$1"
	shift
	case "$_cmd" in
	--scan-files) cmd_scan_files "$@" ;;
	--scan-all) cmd_scan_all "$@" ;;
	--fix-hint) cmd_fix_hint ;;
	-h | --help) usage ;;
	*) die "Unknown command: $_cmd. Use --help for usage." ;;
	esac
}

main "$@"
