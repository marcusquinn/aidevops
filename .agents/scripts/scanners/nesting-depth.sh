#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# nesting-depth.sh — compute max nesting depth of a shell file using shfmt AST
#
# Primary path: pipes the file through `shfmt --to-json` and walks the AST with
# jq, computing per-function max nesting depth. This eliminates four documented
# false-positive classes in the prior AWK regex scanner (GH#20105):
#   1. elif matching the `if` regex (net inflation per elif chain)
#   2. Prose containing bare keywords (`echo "for all users"`)
#   3. `done <<<"$X"` not matching the close regex
#   4. Global counter never resetting between functions
#
# Fallback: when shfmt is unavailable, falls back to the legacy AWK scanner
# with a warning on stderr.
#
# Usage:
#   nesting-depth.sh <file>               Print max nesting depth (integer)
#   nesting-depth.sh --check <file>       Exit 1 if depth > threshold (default 8)
#   nesting-depth.sh --batch-stdin        Read newline-separated paths from stdin;
#                                         output <path>\t<depth> lines in input order
#   nesting-depth.sh --batch <file>...    Scan listed files; output <path>\t<depth>
#                                         lines in argument order
#   nesting-depth.sh --version            Print version
#
# Batch modes use parallel background jobs (capped at 8 workers) and preserve
# input order via per-position tempfiles. Useful for whole-repo scans.
#
# Environment:
#   NESTING_DEPTH_THRESHOLD  Override the --check threshold (default: 8)
#   NESTING_DEPTH_FORCE_AWK  Set to 1 to force AWK fallback (for testing)

set -uo pipefail

_ND_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# _nd_log / _nd_warn / _nd_die
# ---------------------------------------------------------------------------
_nd_log() {
	local _msg="$1"
	printf '[nesting-depth] %s\n' "$_msg" >&2
	return 0
}

_nd_warn() {
	local _msg="$1"
	printf '[nesting-depth] WARN: %s\n' "$_msg" >&2
	return 0
}

_nd_die() {
	local _msg="$1"
	printf '[nesting-depth] ERROR: %s\n' "$_msg" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# _nd_shfmt_available — check if shfmt is on PATH
# ---------------------------------------------------------------------------
_nd_shfmt_available() {
	if [ "${NESTING_DEPTH_FORCE_AWK:-0}" = "1" ]; then
		return 1
	fi
	command -v shfmt >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _nd_jq_available — check if jq is on PATH
# ---------------------------------------------------------------------------
_nd_jq_available() {
	command -v jq >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _nd_jq_filter — returns the jq filter string for AST depth walking
#
# AST structure (shfmt 3.x):
#   - Each statement is an object with .Cmd holding the typed node
#   - FuncDecl: .Body is a stmt wrapping a Block; .Body.Cmd.Stmts = body stmts
#   - IfClause: .Then = array of stmts; .Else = object (elif if has .Cond,
#     else if no .Cond but has .Then)
#   - ForClause/WhileClause: .Do = array of stmts
#   - CaseClause: .Items[] each has .Stmts = array of stmts
#   - elif chains: Else object has .Cond + .Then + optional .Else (no .Type)
#   - else block: Else object has .Then but NO .Cond
#
# Uses a single recursive function with a mode parameter to avoid jq's
# forward-reference limitation (functions must be defined before use).
# ---------------------------------------------------------------------------
_nd_jq_filter() {
	# Mode strings are passed via jq --arg ($S=stmts, $N=stmt, $E=if_else)
	# to avoid repeated string-literal violations in the shell validator.
	cat <<'JQEOF'
def walk(mode; d; extra):
  if mode == $S then
    if . == null then d
    elif type == "array" then
      reduce .[] as $s (d; [., ($s | walk($N; d; 0))] | max)
    else d end
  elif mode == $N then
    if . == null then d
    elif type != "object" then d
    else
      (.Cmd // null) as $c |
      if $c == null then d
      elif $c.Type == "FuncDecl" then
        ($c.Body.Cmd.Stmts // $c.Body.Stmts // null | walk($S; 0; 0))
      elif $c.Type == "IfClause" then
        (d + 1) as $nd |
        [$nd, ($c.Then | walk($S; $nd; 0)),
              ($c.Else | walk($E; $nd; d))] | max
      elif $c.Type == "ForClause" then
        (d + 1) as $nd | [$nd, ($c.Do | walk($S; $nd; 0))] | max
      elif $c.Type == "WhileClause" then
        (d + 1) as $nd | [$nd, ($c.Do | walk($S; $nd; 0))] | max
      elif $c.Type == "CaseClause" then
        (d + 1) as $nd |
        if $c.Items != null then
          reduce $c.Items[] as $item ($nd;
            [., ($item.Stmts | walk($S; $nd; 0))] | max)
        else $nd end
      elif $c.Type == "Block" then ($c.Stmts | walk($S; d; 0))
      elif $c.Type == "Subshell" then ($c.Stmts | walk($S; d; 0))
      elif $c.Type == "BinaryCmd" then
        [($c.X | walk($N; d; 0)), ($c.Y | walk($N; d; 0))] | max
      else d end
    end
  elif mode == $E then
    if . == null then d
    elif type != "object" then d
    elif .Cond != null then
      (extra + 1) as $nd |
      [$nd, (.Then | walk($S; $nd; 0)),
            (.Else | walk($E; $nd; extra))] | max
    elif .Then != null then (.Then | walk($S; d; 0))
    else d end
  else d end;
.Stmts | walk($S; 0; 0)
JQEOF
	return 0
}

# ---------------------------------------------------------------------------
# _nd_scan_shfmt <file>
#
# Walk the shfmt AST to compute per-function max nesting depth. Nesting blocks
# are: IfClause, ForClause, WhileClause, CaseClause. FuncDecl boundaries reset
# the counter. elif chains are correctly handled (no double-counting).
# ---------------------------------------------------------------------------
_nd_scan_shfmt() {
	local _file="$1"

	local _json
	_json=$(shfmt --to-json <"$_file" 2>/dev/null) || {
		_nd_warn "shfmt failed to parse $_file; falling back to AWK"
		_nd_scan_awk "$_file"
		return $?
	}

	if [ -z "$_json" ]; then
		_nd_warn "shfmt produced empty output for $_file; falling back to AWK"
		_nd_scan_awk "$_file"
		return $?
	fi

	local _filter
	_filter=$(_nd_jq_filter)

	local _depth
	_depth=$(printf '%s' "$_json" | jq \
		--arg S stmts --arg N stmt --arg E if_else \
		"$_filter" 2>/dev/null) || {
		_nd_warn "jq AST walk failed for $_file; falling back to AWK"
		_nd_scan_awk "$_file"
		return $?
	}

	printf '%s\n' "${_depth:-0}"
	return 0
}

# ---------------------------------------------------------------------------
# _nd_scan_awk <file>
#
# Legacy AWK fallback — same regex as the prior scanner. Kept for graceful
# degradation when shfmt is unavailable. Known false-positive classes remain.
# ---------------------------------------------------------------------------
_nd_scan_awk() {
	local _file="$1"

	local _max_depth
	_max_depth=$(awk '
		BEGIN { depth=0; max_depth=0 }
		/^[[:space:]]*#/ { next }
		/[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if(depth>max_depth) max_depth=depth }
		/[[:space:]]*(fi|done|esac)[[:space:]]*$/ || /^[[:space:]]*(fi|done|esac)$/ { if(depth>0) depth-- }
		END { print max_depth }
	' "$_file" 2>/dev/null || echo 0)

	printf '%s\n' "${_max_depth:-0}"
	return 0
}

# ---------------------------------------------------------------------------
# _nd_scan_batch_paths <mode> [<paths...>]
#
# Scan multiple files in parallel and emit <path>\t<depth> lines preserving
# input order. mode=stdin reads newline-separated paths from stdin; mode=args
# uses the remaining positional arguments.
#
# Parallelism: background jobs capped at _ncpu (sysctl hw.ncpu / nproc, max 8).
# Order preservation: each path is assigned an index; results written to
# per-index tempfiles and emitted in ascending index order after all jobs finish.
# ---------------------------------------------------------------------------
_nd_scan_batch_paths() {
	local _mode="$1"
	shift  # remaining args are file paths when mode=args

	# Determine worker count (cap at 8)
	local _ncpu
	_ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
	if [ "$_ncpu" -gt 8 ]; then _ncpu=8; fi

	# Temp directory for indexed path/result files
	local _tmpdir
	_tmpdir=$(mktemp -d) || { _nd_die "mktemp failed for batch mode"; }

	# Collect paths into numbered temp files (avoids array append for bash 3.2)
	local _idx=0
	if [ "$_mode" = "stdin" ]; then
		while IFS= read -r _p; do
			[ -n "$_p" ] || continue
			printf '%s' "$_p" >"$_tmpdir/p.$_idx"
			_idx=$((_idx + 1))
		done
	else
		for _a in "$@"; do
			[ -n "$_a" ] || continue
			printf '%s' "$_a" >"$_tmpdir/p.$_idx"
			_idx=$((_idx + 1))
		done
	fi

	local _total="$_idx"

	if [ "$_total" -eq 0 ]; then
		rm -rf "$_tmpdir"
		return 0
	fi

	# Scan files in parallel: launch background jobs, throttle to _ncpu at a time
	local _running=0
	_idx=0
	while [ "$_idx" -lt "$_total" ]; do
		local _pfile
		_pfile=$(cat "$_tmpdir/p.$_idx")
		local _rfile="$_tmpdir/r.$_idx"
		(
			local _d=0
			if _nd_shfmt_available && _nd_jq_available; then
				_d=$(_nd_scan_shfmt "$_pfile" 2>/dev/null) || _d=0
			else
				_d=$(_nd_scan_awk "$_pfile" 2>/dev/null) || _d=0
			fi
			printf '%s' "${_d:-0}" >"$_rfile"
		) &
		_running=$((_running + 1))
		if [ "$_running" -ge "$_ncpu" ]; then
			wait
			_running=0
		fi
		_idx=$((_idx + 1))
	done
	wait  # wait for any remaining background jobs

	# Emit results in input order: <path>\t<depth>
	_idx=0
	while [ "$_idx" -lt "$_total" ]; do
		local _pfile
		_pfile=$(cat "$_tmpdir/p.$_idx")
		local _depth=0
		if [ -f "$_tmpdir/r.$_idx" ]; then
			_depth=$(cat "$_tmpdir/r.$_idx")
		fi
		printf '%s\t%s\n' "$_pfile" "${_depth:-0}"
		_idx=$((_idx + 1))
	done

	rm -rf "$_tmpdir"
	return 0
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
_nd_main() {
	local _all_args=("$@")
	local _mode="scan"
	local _file=""
	local _threshold="${NESTING_DEPTH_THRESHOLD:-8}"

	local _i=0 _arg
	while [ "$_i" -lt "${#_all_args[@]}" ]; do
		_arg="${_all_args[$_i]}"
		case "$_arg" in
			--check)
				_mode="check"
				_i=$((_i + 1))
				;;
			--batch-stdin)
				_mode="batch-stdin"
				_i=$((_i + 1))
				;;
			--batch)
				_mode="batch"
				_i=$((_i + 1))
				break  # remaining args are file paths
				;;
			--version)
				printf '%s\n' "$_ND_VERSION"
				return 0
				;;
			--threshold)
				_i=$((_i + 1))
				_threshold="${_all_args[$_i]:-8}"
				_i=$((_i + 1))
				;;
			-h | --help)
				sed -n '5,32p' "$0" | sed 's/^# \{0,1\}//'
				return 0
				;;
			-*)
				_nd_die "unknown flag: $_arg"
				;;
			*)
				_file="$_arg"
				_i=$((_i + 1))
				;;
		esac
	done

	# Batch modes: read paths from stdin or remaining args
	if [ "$_mode" = "batch-stdin" ]; then
		_nd_scan_batch_paths stdin
		return $?
	fi

	if [ "$_mode" = "batch" ]; then
		# _i is already past the --batch flag; remaining args are files
		local _batch_files=()
		while [ "$_i" -lt "${#_all_args[@]}" ]; do
			_batch_files+=("${_all_args[$_i]}")
			_i=$((_i + 1))
		done
		_nd_scan_batch_paths args "${_batch_files[@]}"
		return $?
	fi

	# Single-file scan (scan or check mode)
	if [ -z "$_file" ]; then
		_nd_die "usage: nesting-depth.sh [--check] <file>"
	fi

	if [ ! -f "$_file" ]; then
		_nd_die "file not found: $_file"
	fi

	local _depth
	if _nd_shfmt_available && _nd_jq_available; then
		_depth=$(_nd_scan_shfmt "$_file")
	else
		if ! _nd_shfmt_available; then
			_nd_warn "shfmt not found; using AWK fallback (false positives possible)"
		fi
		if ! _nd_jq_available; then
			_nd_warn "jq not found; using AWK fallback (false positives possible)"
		fi
		_depth=$(_nd_scan_awk "$_file")
	fi

	printf '%s\n' "${_depth:-0}"

	if [ "$_mode" = "check" ]; then
		if [ "${_depth:-0}" -gt "$_threshold" ] 2>/dev/null; then
			return 1
		fi
	fi

	return 0
}

# Run main only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	_nd_main "$@"
fi
