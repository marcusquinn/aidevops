#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# nesting-depth.sh — per-function nesting-depth scanner using shfmt AST (GH#20105)
#
# Computes max nesting depth per function via `shfmt --to-json` AST walk.
# Falls back to AWK when shfmt is unavailable (graceful degradation).
#
# Usage:
#   nesting-depth.sh <file>
#     Prints the max nesting depth (integer) to stdout.
#     Per-function reset: each function's depth is computed independently;
#     global max across all functions (and top-level code) is reported.
#
# Exit codes:
#   0 — success
#   1 — file not readable or parse error (prints 0)
#   2 — usage error
#
# Dependencies:
#   - shfmt (preferred) — produces JSON AST; all four documented false-positive
#     classes are eliminated by construction.
#   - python3 — for walking the JSON AST (ships with macOS, available on Linux).
#   - awk (fallback) — legacy regex-based scanner, used only when shfmt or
#     python3 is unavailable.
#
# False-positive classes eliminated by shfmt AST (vs prior AWK regex):
#   1. elif matches if — elif is Else subclause, not a separate IfClause
#   2. Prose containing bare keywords — string literals are not control-flow nodes
#   3. done <<<"$X" / done | cmd — WhileClause/ForClause close normally in AST
#   4. Global counter never resets — FuncDecl gives natural function boundaries
#
set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCANNER_NAME="nesting-depth"

# ---------------------------------------------------------------------------
# _log / _die
# ---------------------------------------------------------------------------
_log() {
	local _msg="$1"
	printf '[%s] %s\n' "$_SCANNER_NAME" "$_msg" >&2
	return 0
}

_die() {
	local _msg="$1"
	printf '[%s] ERROR: %s\n' "$_SCANNER_NAME" "$_msg" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# _has_cmd <cmd>
# ---------------------------------------------------------------------------
_has_cmd() {
	local _cmd="$1"
	if command -v "$_cmd" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# _scan_shfmt <file>
#
# Parse <file> with shfmt --to-json and walk the AST with python3 to compute
# the max nesting depth. Per-function reset is built-in: FuncDecl nodes reset
# depth to 0.
# ---------------------------------------------------------------------------
_scan_shfmt() {
	local _file="$1"
	local _ast _result

	# shfmt --to-json reads from stdin only
	_ast=$(shfmt --to-json < "$_file" 2>/dev/null) || {
		_log "shfmt parse error on $_file, falling back to AWK"
		_scan_awk "$_file"
		return $?
	}

	# Walk the AST with python3
	_result=$(printf '%s' "$_ast" | python3 -c '
import json, sys

NESTING_TYPES = {"IfClause", "ForClause", "WhileClause", "CaseClause"}

def max_depth(node, depth=0):
    """Walk the shfmt JSON AST and return the max nesting depth.

    FuncDecl nodes reset depth to 0 (per-function measurement).
    elif branches are Else subclauses without a Type field — they do NOT
    increment depth, which is correct (elif is at the same nesting level).
    """
    best = depth
    if isinstance(node, dict):
        t = node.get("Type", "")
        if t == "FuncDecl":
            # Per-function reset: walk body at depth 0
            body = node.get("Body")
            if body:
                child_max = max_depth(body, 0)
                if child_max > best:
                    best = child_max
            return best
        if t in NESTING_TYPES:
            depth += 1
            if depth > best:
                best = depth
        for key, val in node.items():
            child_max = max_depth(val, depth)
            if child_max > best:
                best = child_max
    elif isinstance(node, list):
        for item in node:
            child_max = max_depth(item, depth)
            if child_max > best:
                best = child_max
    return best

try:
    ast = json.load(sys.stdin)
    print(max_depth(ast))
except Exception:
    print(0)
' 2>/dev/null) || _result=0

	printf '%s' "${_result:-0}"
	return 0
}

# ---------------------------------------------------------------------------
# _scan_awk <file>
#
# Legacy AWK-based scanner. Used as fallback when shfmt or python3 is
# unavailable. Subject to the four documented false-positive classes.
# ---------------------------------------------------------------------------
_scan_awk() {
	local _file="$1"
	local _depth

	_depth=$(awk '
		BEGIN { depth=0; max_depth=0 }
		/^[[:space:]]*#/ { next }
		/[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if(depth>max_depth) max_depth=depth }
		/[[:space:]]*(fi|done|esac)[[:space:]]*$/ || /^[[:space:]]*(fi|done|esac)$/ { if(depth>0) depth-- }
		END { print max_depth }
	' "$_file" 2>/dev/null || echo 0)

	printf '%s' "${_depth:-0}"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	if [ $# -lt 1 ]; then
		_die "usage: nesting-depth.sh <file>"
	fi

	local _file="$1"

	if [ ! -r "$_file" ]; then
		printf '0'
		return 1
	fi

	# Prefer shfmt + python3; fall back to AWK
	if _has_cmd shfmt && _has_cmd python3; then
		_scan_shfmt "$_file"
	else
		if ! _has_cmd shfmt; then
			_log "shfmt not found, using AWK fallback (false positives possible)"
		elif ! _has_cmd python3; then
			_log "python3 not found, using AWK fallback (false positives possible)"
		fi
		_scan_awk "$_file"
	fi

	return 0
}

main "$@"
