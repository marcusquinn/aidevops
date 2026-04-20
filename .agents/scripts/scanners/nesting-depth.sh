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
#   nesting-depth.sh <file>          Print max nesting depth (integer)
#   nesting-depth.sh --check <file>  Exit 1 if depth > threshold (default 8)
#   nesting-depth.sh --version       Print version
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
				sed -n '5,24p' "$0" | sed 's/^# \{0,1\}//'
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
