#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# complexity-regression-helper.sh — CI regression gate for shell function complexity (t2159)
#
# Scans shell functions >100 lines at PR base and head, computes the
# set difference (new violations only), and emits a markdown report.
# Exits 1 only when the PR introduces NEW violations — not for total
# drift already present in the base.
#
# Subcommands:
#   scan  <dir> [--output <file>]
#         Scan all .sh files in <dir> for functions >100 lines.
#         Output: one line per violation, tab-separated:
#           <relative-file>\t<function-name>\t<line-count>
#
#   diff  --base-file <scan-file> --head-file <scan-file>
#         [--output-md <file>] [--base-sha <sha>] [--head-sha <sha>]
#         Compute the set difference and produce a markdown report.
#
#   check --base <sha> [--head <sha>] [--output-md <file>]
#         [--allow-increase] [--dry-run]
#         Full regression check using git worktrees. Main entry point.
#
# Exit codes:
#   0 — no new violations (or --allow-increase / --dry-run)
#   1 — new violations detected
#   2 — invocation or environment error

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
TMP_DIR=""
BASE_WORKTREE=""
HEAD_WORKTREE=""

cleanup() {
	if [ -n "$BASE_WORKTREE" ] && [ -d "$BASE_WORKTREE" ]; then
		git worktree remove --force "$BASE_WORKTREE" >/dev/null 2>&1 || true
	fi
	if [ -n "$HEAD_WORKTREE" ] && [ -d "$HEAD_WORKTREE" ]; then
		git worktree remove --force "$HEAD_WORKTREE" >/dev/null 2>&1 || true
	fi
	if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
	return 0
}
trap cleanup EXIT

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
	sed -n '4,42p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# scan_dir <dir> [<output-file>]
#
# Scan all .sh files in <dir> for shell functions >100 lines.
# Output format (per violation): <relative-file>\t<function-name>\t<line-count>
# If <output-file> is given, write there; otherwise write to stdout.
# ---------------------------------------------------------------------------
scan_dir() {
	local _dir="$1"
	local _out="${2:-}"

	# Collect all .sh files, excluding _archive/ dirs.
	# Works in both git-worktree contexts (where ls-files may not reflect
	# an arbitrary checkout) and plain directory scans.
	local _sh_files
	_sh_files=$(find "$_dir" -name '*.sh' -not -path '*/_archive/*' \
		-not -path '*/.git/*' 2>/dev/null | sort)

	if [ -z "$_sh_files" ]; then
		log "WARN: no .sh files found in $_dir"
		if [ -n "$_out" ]; then
			: >"$_out"
		fi
		return 0
	fi

	local _result_file
	if [ -n "$_out" ]; then
		_result_file="$_out"
		: >"$_result_file"
	else
		_result_file="/dev/stdout"
	fi

	local _file _rel_file _awk_result
	while IFS= read -r _file; do
		[ -n "$_file" ] || continue
		# Compute path relative to the scanned dir.
		_rel_file="${_file#"${_dir}/"}"
		# Use the same AWK pattern as code-quality.yml:391-404.
		# Detects top-level functions of the form:  name() {
		# and closes on a bare } line.  Output: <file>\t<fname>\t<lines>
		_awk_result=$(awk -v relfile="$_rel_file" '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
				fname = $1
				sub(/\(\)/, "", fname)
				start = NR
				next
			}
			fname && /^\}$/ {
				lines = NR - start
				if (lines > 100) {
					printf "%s\t%s\t%d\n", relfile, fname, lines
				}
				fname = ""
			}
		' "$_file" 2>/dev/null || true)

		if [ -n "$_awk_result" ] && [ -n "$_out" ]; then
			printf '%s\n' "$_awk_result" >>"$_result_file"
		elif [ -n "$_awk_result" ]; then
			printf '%s\n' "$_awk_result"
		fi
	done <<<"$_sh_files"

	return 0
}

# ---------------------------------------------------------------------------
# violation_count <scan-file>  — count lines in a scan file
# ---------------------------------------------------------------------------
violation_count() {
	local _f="$1"
	if [ ! -s "$_f" ]; then
		printf '0'
		return 0
	fi
	wc -l <"$_f" | tr -d ' '
	return 0
}

# ---------------------------------------------------------------------------
# compute_new_violations <base-file> <head-file> <out-file>
#
# Writes to <out-file> the violations in head that are NOT in base.
# Identity key: <relative-file>\t<function-name>  (ignores line count).
# ---------------------------------------------------------------------------
compute_new_violations() {
	local _base="$1"
	local _head="$2"
	local _out="$3"
	: >"$_out"

	# Build a set of "file\tname" keys from base.
	local _base_keys
	_base_keys=$(awk -F '\t' '{print $1"\t"$2}' "$_base" 2>/dev/null | sort -u || true)

	# For each head violation, check if its key exists in base.
	while IFS= read -r _line; do
		[ -n "$_line" ] || continue
		local _key
		_key=$(printf '%s' "$_line" | awk -F '\t' '{print $1"\t"$2}')
		if ! printf '%s\n' "$_base_keys" | grep -qxF "$_key"; then
			printf '%s\n' "$_line" >>"$_out"
		fi
	done <"$_head"

	return 0
}

# ---------------------------------------------------------------------------
# write_report <new-count> <base-total> <head-total>
#              <new-violations-file> <base-sha> <head-sha> <out-md>
# ---------------------------------------------------------------------------
write_report() {
	local _new_count="$1"
	local _base_total="$2"
	local _head_total="$3"
	local _new_file="$4"
	local _base_sha="$5"
	local _head_sha="$6"
	local _out="$7"

	local _verdict
	if [ "$_new_count" -gt 0 ]; then
		_verdict="❌ **Regression** — this PR introduces $_new_count NEW function complexity violation(s)."
	else
		_verdict="✅ **No regression** — no new function complexity violations."
	fi

	{
		printf '## Shell Function Complexity Regression Gate\n\n'
		printf '%s\n\n' "$_verdict"
		# shellcheck disable=SC2016
		printf '| Metric | Base (`%s`) | Head (`%s`) |\n' \
			"${_base_sha:0:7}" "${_head_sha:0:7}"
		printf '|---|---:|---:|\n'
		printf '| Total violations (>100 lines) | %s | %s |\n\n' \
			"$_base_total" "$_head_total"

		if [ "$_new_count" -gt 0 ]; then
			printf '### New violations\n\n'
			printf '| File | Function | Lines |\n|---|---|---:|\n'
			while IFS=$'\t' read -r _file _fname _lines; do
				[ -n "$_file" ] || continue
				# shellcheck disable=SC2016
				printf '| `%s` | `%s` | %s |\n' "$_file" "$_fname" "$_lines"
			done <"$_new_file"
			printf '\n'
			# shellcheck disable=SC2016
			printf '> To override (with justification), add the `complexity-bump-ok` label to this PR\n'
			# shellcheck disable=SC2016
			printf '> and include a `## Complexity Bump Justification` section in the PR description.\n'
		fi

		printf '\n<!-- complexity-regression-gate -->\n'
	} >"$_out"

	return 0
}

# ===========================================================================
# Subcommand: scan
# ===========================================================================
cmd_scan() {
	local _dir=""
	local _out=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--output)
			[ $# -ge 2 ] || die "missing value for --output"
			_out="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			if [ -z "$_dir" ]; then
				_dir="$1"
				shift
			else
				die "unexpected argument: $1"
			fi
			;;
		esac
	done

	[ -n "$_dir" ] || die "scan: <dir> argument required"
	[ -d "$_dir" ] || die "scan: directory not found: $_dir"

	scan_dir "$_dir" "$_out"
	return 0
}

# ===========================================================================
# Subcommand: diff
# ===========================================================================
cmd_diff() {
	local _base_file=""
	local _head_file=""
	local _output_md=""
	local _base_sha="unknown"
	local _head_sha="unknown"

	while [ $# -gt 0 ]; do
		case "$1" in
		--base-file)
			[ $# -ge 2 ] || die "missing value for --base-file"
			_base_file="$2"
			shift 2
			;;
		--head-file)
			[ $# -ge 2 ] || die "missing value for --head-file"
			_head_file="$2"
			shift 2
			;;
		--output-md)
			[ $# -ge 2 ] || die "missing value for --output-md"
			_output_md="$2"
			shift 2
			;;
		--base-sha)
			[ $# -ge 2 ] || die "missing value for --base-sha"
			_base_sha="$2"
			shift 2
			;;
		--head-sha)
			[ $# -ge 2 ] || die "missing value for --head-sha"
			_head_sha="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "diff: unknown argument: $1" ;;
		esac
	done

	[ -n "$_base_file" ] || die "diff: --base-file is required"
	[ -n "$_head_file" ] || die "diff: --head-file is required"
	[ -f "$_base_file" ] || die "diff: base-file not found: $_base_file"
	[ -f "$_head_file" ] || die "diff: head-file not found: $_head_file"

	TMP_DIR=$(mktemp -d)
	local _new_file="$TMP_DIR/new-violations.tsv"

	compute_new_violations "$_base_file" "$_head_file" "$_new_file"

	local _new_count _base_total _head_total
	_new_count=$(violation_count "$_new_file")
	_base_total=$(violation_count "$_base_file")
	_head_total=$(violation_count "$_head_file")

	log "base: $_base_total  head: $_head_total  new: $_new_count"

	if [ -n "$_output_md" ]; then
		write_report "$_new_count" "$_base_total" "$_head_total" \
			"$_new_file" "$_base_sha" "$_head_sha" "$_output_md"
		log "report written to $_output_md"
	fi

	if [ "$_new_count" -gt 0 ]; then
		printf 'NEW violations: %s\n' "$_new_count"
		exit 1
	fi

	printf 'No new violations\n'
	exit 0
}

# ---------------------------------------------------------------------------
# _check_dry_run — scan current tree, report total count, exit 0 always
# ---------------------------------------------------------------------------
_check_dry_run() {
	TMP_DIR=$(mktemp -d)
	local _head_scan="$TMP_DIR/head.tsv"
	log "dry-run: scanning current tree"
	scan_dir "." "$_head_scan"
	local _count
	_count=$(violation_count "$_head_scan")
	printf 'Total violations (>100 lines): %s\n' "$_count"
	if [ "$_count" -gt 0 ]; then
		printf '\nViolations:\n'
		cat "$_head_scan"
	fi
	exit 0
}

# ---------------------------------------------------------------------------
# _check_regression <base_sha> <head_sha> <output_md> <allow_increase>
# Scan base+head via worktrees, compute diff, optionally write report.
# Exits 0 (no regression), 1 (regression), or 2 (error).
# ---------------------------------------------------------------------------
_check_regression() {
	local _base_sha="$1"
	local _head_sha="$2"
	local _output_md="$3"
	local _allow_increase="$4"

	TMP_DIR=$(mktemp -d)
	local _base_scan="$TMP_DIR/base.tsv"
	local _head_scan="$TMP_DIR/head.tsv"
	local _new_file="$TMP_DIR/new-violations.tsv"

	BASE_WORKTREE="$TMP_DIR/base-worktree"
	log "creating base worktree at ${_base_sha:0:7}"
	if ! git worktree add --detach --force "$BASE_WORKTREE" "$_base_sha" >/dev/null 2>&1; then
		die "failed to create base worktree for $_base_sha"
	fi
	log "scanning base (${_base_sha:0:7})"
	scan_dir "$BASE_WORKTREE" "$_base_scan"

	HEAD_WORKTREE="$TMP_DIR/head-worktree"
	log "creating head worktree at ${_head_sha:0:7}"
	if ! git worktree add --detach --force "$HEAD_WORKTREE" "$_head_sha" >/dev/null 2>&1; then
		die "failed to create head worktree for $_head_sha"
	fi
	log "scanning head (${_head_sha:0:7})"
	scan_dir "$HEAD_WORKTREE" "$_head_scan"

	compute_new_violations "$_base_scan" "$_head_scan" "$_new_file"

	local _new_count _base_total _head_total
	_new_count=$(violation_count "$_new_file")
	_base_total=$(violation_count "$_base_scan")
	_head_total=$(violation_count "$_head_scan")

	log "base: $_base_total  head: $_head_total  new: $_new_count"

	if [ -n "$_output_md" ]; then
		write_report "$_new_count" "$_base_total" "$_head_total" \
			"$_new_file" "$_base_sha" "$_head_sha" "$_output_md"
		log "report written to $_output_md"
	fi

	if [ "$_new_count" -gt 0 ] && [ "$_allow_increase" -eq 0 ]; then
		log "REGRESSION: $_new_count new violation(s)"
		exit 1
	fi

	if [ "$_new_count" -gt 0 ]; then
		log "new violations detected but --allow-increase is set"
	else
		log "no new violations"
	fi
	exit 0
}

# ===========================================================================
# Subcommand: check
# ===========================================================================
cmd_check() {
	local _base=""
	local _head="HEAD"
	local _output_md=""
	local _allow_increase=0
	local _dry_run=0

	while [ $# -gt 0 ]; do
		case "$1" in
		--base)
			[ $# -ge 2 ] || die "missing value for --base"
			_base="$2"
			shift 2
			;;
		--head)
			[ $# -ge 2 ] || die "missing value for --head"
			_head="$2"
			shift 2
			;;
		--output-md)
			[ $# -ge 2 ] || die "missing value for --output-md"
			_output_md="$2"
			shift 2
			;;
		--allow-increase)
			_allow_increase=1
			shift
			;;
		--dry-run)
			_dry_run=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "check: unknown argument: $1" ;;
		esac
	done

	[ "$_dry_run" -eq 1 ] && _check_dry_run

	[ -n "$_base" ] || die "check: --base <sha> is required (use --dry-run to scan current tree)"

	if ! git rev-parse --verify --quiet "${_base}^{commit}" >/dev/null; then
		die "check: base ref not found in repo: $_base"
	fi
	if ! git rev-parse --verify --quiet "${_head}^{commit}" >/dev/null; then
		die "check: head ref not found in repo: $_head"
	fi

	local _base_sha _head_sha
	_base_sha=$(git rev-parse "$_base")
	_head_sha=$(git rev-parse "$_head")

	_check_regression "$_base_sha" "$_head_sha" "$_output_md" "$_allow_increase"
}

# ===========================================================================
# Dispatch
# ===========================================================================

[ $# -ge 1 ] || {
	usage
	exit 2
}

_SUBCOMMAND="$1"
shift

case "$_SUBCOMMAND" in
scan) cmd_scan "$@" ;;
diff) cmd_diff "$@" ;;
check) cmd_check "$@" ;;
-h | --help)
	usage
	exit 0
	;;
*) die "unknown subcommand: $_SUBCOMMAND (valid: scan, diff, check)" ;;
esac
