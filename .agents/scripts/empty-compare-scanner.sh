#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# empty-compare-scanner.sh — detect the empty-compare foot-gun in bash scripts (t2570)
#
# The foot-gun: a variable derived from command substitution or parameter
# expansion is used in a != / == comparison without a prior non-empty guard
# in the same function scope.  When the derived variable resolves to "",
# the comparison silently inverts — always true for any real value.
#
# Root cause (t2559 / GH#20205): cmd_clean compared $worktree_path against
# $main_wt (derived via `${_porcelain%%$'\n'*}`) without guarding for empty.
# When _porcelain was empty, main_wt="" and the path check passed for every
# path — moving the canonical repo to Trash.
#
# Subcommands:
#   scan  <dir> [--output <file>] [--output-md <file>]
#         Walk tracked .sh files under <dir>.
#         Output: one line per violation, tab-separated:
#           <relative-file>\t<function>\t<assign_line>\t<compare_line>\t<var>
#
# Exit codes:
#   0 — no violations (or AIDEVOPS_EMPTY_COMPARE_SKIP=1)
#   1 — violations found
#   2 — invocation / environment error
#
# Bypass:
#   Inline:     add  # scan:empty-compare-ok  on the comparison line
#   File-level: add path to .agents/configs/empty-compare-allowlist.txt
#   Global:     AIDEVOPS_EMPTY_COMPARE_SKIP=1

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
ALLOWLIST_DEFAULT=".agents/configs/empty-compare-allowlist.txt"

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
	sed -n '13,28p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# _collect_sh_files <dir>
# Emit newline-separated absolute paths of tracked .sh files under <dir>.
# Falls back to find for non-git dirs.
# ---------------------------------------------------------------------------
_collect_sh_files() {
	local _dir="$1"
	local _output=""

	if git -C "$_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		local _chunk
		_chunk=$(git -C "$_dir" ls-files '*.sh' 2>/dev/null |
			grep -Ev '_archive/' || true)
		if [ -n "$_chunk" ]; then
			_output=$(printf '%s\n' "$_chunk" | awk -v d="$_dir" 'NF{print d"/"$0}' | sort -u)
		fi
	fi

	if [ -z "$_output" ]; then
		_output=$(find "$_dir" -name '*.sh' \
			-not -path '*/_archive/*' \
			-not -path '*/.git/*' 2>/dev/null | sort -u)
	fi

	[ -n "$_output" ] && printf '%s\n' "$_output"
	return 0
}

# ---------------------------------------------------------------------------
# _read_allowlist [<file>]
# Print allowlist content (one pattern per line) or empty string.
# ---------------------------------------------------------------------------
_read_allowlist() {
	local _file="${1:-}"
	if [ -z "$_file" ]; then
		local _repo_root
		_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
		if [ -n "$_repo_root" ] && [ -f "${_repo_root}/${ALLOWLIST_DEFAULT}" ]; then
			_file="${_repo_root}/${ALLOWLIST_DEFAULT}"
		fi
	fi
	[ -n "$_file" ] && [ -f "$_file" ] && grep -v '^[[:space:]]*#' "$_file" || true
	return 0
}

# ---------------------------------------------------------------------------
# _is_file_allowed <rel_file> <allowlist_content>
# Returns 0 if file matches any allowlist pattern, 1 otherwise.
# ---------------------------------------------------------------------------
_is_file_allowed() {
	local _rel="$1"
	local _allowlist="$2"

	[ -z "$_allowlist" ] && return 1

	local _pattern
	while IFS= read -r _pattern; do
		[ -z "$_pattern" ] && continue
		# shellcheck disable=SC2254
		case "$_rel" in
		$_pattern) return 0 ;;
		esac
	done <<<"$_allowlist"
	return 1
}

# ---------------------------------------------------------------------------
# _scan_file <abs_file> <rel_file> <out_file>
# Run the AWK detection program on one file, appending to <out_file>.
# Detection: for each function, track derived assignments (var=$(..),
# var="${..}") and empty guards (-z/-n), flag comparisons (!= / ==) that
# use a derived var without a guard between assignment and comparison.
# ---------------------------------------------------------------------------
_scan_file() {
	local _file="$1"
	local _rel="$2"
	local _out="$3"

	[ -f "$_file" ] || return 0

	awk -v relfile="$_rel" '
BEGIN { curfunc="" }
/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
    curfunc=$0; sub(/\(.*/, "", curfunc); gsub(/^[[:space:]]+/, "", curfunc)
    for (k in derived) delete derived[k]
    for (k in guards)  delete guards[k]
    next
}
curfunc!="" && /^\}[[:space:]]*$/ { curfunc=""; next }
curfunc==""             { next }
/^[[:space:]]*#/        { next }
/# scan:empty-compare-ok/ { next }
/[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[^=]/ && /(\$\(|`|"\$\{|\$\{)/ {
    vn=$0
    gsub(/[[:space:]]*=.*/, "", vn)
    gsub(/^[[:space:]]+/, "", vn)
    gsub(/[[:space:]].*/, "", vn)
    if (vn ~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) derived[vn]=NR
}
/ -z / && /\$/ {
    tmp=$0
    gsub(/.*-z[[:space:]]+"?\$\{?/, "", tmp)
    gsub(/["}[:space:]].*/, "", tmp)
    if (tmp in derived) guards[tmp]=NR
}
/ -n / && /\$/ {
    tmp=$0
    gsub(/.*-n[[:space:]]+"?\$\{?/, "", tmp)
    gsub(/["}[:space:]].*/, "", tmp)
    if (tmp in derived) guards[tmp]=NR
}
/:[[:space:]]+"?\$\{/ && /:[?-]/ {
    tmp=$0
    gsub(/.*\$\{/, "", tmp)
    gsub(/[:{?-].*/, "", tmp)
    if (tmp in derived) guards[tmp]=NR
}
/[!=]=/ {
    line=$0; gsub(/\$\{/, "$", line)
    n=split(line, parts, "$")
    for (i=2; i<=n; i++) {
        vn=parts[i]; gsub(/[^a-zA-Z0-9_].*/, "", vn)
        if (length(vn)==0 || !(vn in derived)) continue
        if (derived[vn]>=NR) continue
        ok=(vn in guards && guards[vn]>derived[vn] && guards[vn]<NR)
        if (!ok) printf "%s\t%s\t%d\t%d\t%s\n",relfile,curfunc,derived[vn],NR,vn
    }
}
' "$_file" >>"$_out" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# scan_dir <dir> [<out_file>] [<md_file>]
# Scan all .sh files under <dir>, writing tab-separated violations to
# <out_file> (stdout if omitted) and optional markdown to <md_file>.
# ---------------------------------------------------------------------------
scan_dir() {
	local _dir="$1"
	local _out="${2:-}"
	local _md="${3:-}"

	[ -d "$_dir" ] || die "scan_dir: directory not found: $_dir"

	if [ "${AIDEVOPS_EMPTY_COMPARE_SKIP:-0}" = "1" ]; then
		log "AIDEVOPS_EMPTY_COMPARE_SKIP=1 — scan bypassed"
		[ -n "$_out" ] && : >"$_out"
		return 0
	fi

	local _allowlist
	_allowlist=$(_read_allowlist)

	local _tmp_out
	_tmp_out=$(mktemp /tmp/empty-compare-scan.XXXXXX)

	local _sh_files
	_sh_files=$(_collect_sh_files "$_dir")
	if [ -z "$_sh_files" ]; then
		log "WARN: no .sh files found in $_dir"
		rm -f "$_tmp_out"
		[ -n "$_out" ] && : >"$_out"
		return 0
	fi

	local _file _rel
	while IFS= read -r _file; do
		[ -n "$_file" ] || continue
		[ -f "$_file" ] || continue
		_rel="${_file#"${_dir}/"}"
		_is_file_allowed "$_rel" "$_allowlist" && continue
		_scan_file "$_file" "$_rel" "$_tmp_out"
	done <<<"$_sh_files"

	_emit_scan_output "$_tmp_out" "$_out" "$_md"
	rm -f "$_tmp_out"
	return 0
}

# ---------------------------------------------------------------------------
# _emit_scan_output <tmp_file> <out_file> <md_file>
# Copy violations to destination(s) and optionally write markdown report.
# ---------------------------------------------------------------------------
_emit_scan_output() {
	local _tmp="$1"
	local _out="${2:-}"
	local _md="${3:-}"

	local _count=0
	if [ -s "$_tmp" ]; then
		_count=$(wc -l <"$_tmp" | tr -d ' ')
	fi

	if [ -n "$_out" ]; then
		cp "$_tmp" "$_out"
	else
		[ -s "$_tmp" ] && cat "$_tmp"
	fi

	[ -z "$_md" ] && return 0

	{
		printf '## Empty-Compare Scanner Results\n\n'
		printf 'Total violations: **%d**\n\n' "$_count"
		if [ "$_count" -gt 0 ]; then
			printf '| File | Function | Assign L | Compare L | Variable |\n'
			printf '|---|---|---:|---:|---|\n'
			while IFS=$'\t' read -r _f _fn _al _cl _vn; do
				[ -n "$_f" ] || continue
			# shellcheck disable=SC2016
			printf '| `%s` | `%s` | %s | %s | `%s` |\n' \
				"$_f" "$_fn" "$_al" "$_cl" "$_vn"
		done <"$_tmp"
		printf '\n'
		# shellcheck disable=SC2016
		printf '> Add `# scan:empty-compare-ok` on the comparison line to suppress.\n'
		fi
	} >"$_md"
	return 0
}

# ===========================================================================
# Subcommand: scan
# ===========================================================================
cmd_scan() {
	local _dir=""
	local _out=""
	local _md=""

	while [ $# -gt 0 ]; do
		local _arg="$1"; shift
		case "$_arg" in
		--output)
			local _nextval="${1:-}"; shift || true
			[ -n "$_nextval" ] || die "missing value for --output"
			_out="$_nextval" ;;
		--output-md)
			local _nextmd="${1:-}"; shift || true
			[ -n "$_nextmd" ] || die "missing value for --output-md"
			_md="$_nextmd" ;;
		-h | --help)
			usage; exit 0 ;;
		*)
			if [ -z "$_dir" ]; then
				_dir="$_arg"
			else
				die "unexpected argument: $_arg"
			fi ;;
		esac
	done

	[ -n "$_dir" ] || die "scan: <dir> argument required"
	[ -d "$_dir" ] || die "scan: directory not found: $_dir"

	scan_dir "$_dir" "$_out" "$_md"

	local _violations=0
	if [ -n "$_out" ] && [ -f "$_out" ] && [ -s "$_out" ]; then
		_violations=$(wc -l <"$_out" | tr -d ' ')
	fi
	[ "$_violations" -gt 0 ] && return 1
	return 0
}

# ===========================================================================
# Main dispatch
# ===========================================================================
main() {
	[ $# -eq 0 ] && { usage; exit 0; }

	local _subcmd="$1"; shift
	case "$_subcmd" in
	scan) cmd_scan "$@" ;;
	help | --help | -h) usage; exit 0 ;;
	*) die "unknown subcommand: $_subcmd (try: scan, help)" ;;
	esac
}

main "$@"
