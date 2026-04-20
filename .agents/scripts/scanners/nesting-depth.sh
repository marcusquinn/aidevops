#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# nesting-depth.sh — compute per-function max nesting depth using shfmt AST
#
# Usage:
#   nesting-depth.sh <file>
#     Prints the per-function max nesting depth for <file>.
#     Output: one integer (the file-level max depth across all functions
#     and top-level code).
#
#   nesting-depth.sh --per-function <file>
#     Prints per-function breakdown: <function>\t<depth> per line.
#
# Approach B (t2430): walks the shfmt --to-json AST depth-first, counting
# IfClause, ForClause, WhileClause, CaseClause as nesting levels. FuncDecl
# nodes give natural per-function boundaries. elif chains are correctly
# handled as same-depth (not double-counted). All four documented false-
# positive classes from the old AWK scanner are eliminated by construction:
#
#   1. elif matches if           — AST: elif is nested IfClause in .Else,
#                                  walker treats as same depth.
#   2. Prose containing keywords — AST: string content not tokenized as
#                                  control flow.
#   3. done <<<"$x" not close    — AST: WhileClause closes normally
#                                  regardless of redirect syntax.
#   4. Global counter no reset   — AST: FuncDecl nodes provide natural
#                                  per-function boundaries.
#
# Graceful degradation: when shfmt is unavailable, falls back to the legacy
# AWK scanner with a warning on stderr.
#
# Dependencies: shfmt (--to-json), jq. Both are framework dev deps
# provisioned by setup.sh.

set -uo pipefail

# ---------------------------------------------------------------------------
# JQ filter: walk the shfmt AST and compute per-function max nesting depth.
#
# Nesting types: IfClause, ForClause, WhileClause, CaseClause.
# FuncDecl gives per-function reset boundaries.
# elif handling: IfClause.Else with a Cond field = elif (same depth, not +1).
# ---------------------------------------------------------------------------
# The JQ filter below is intentionally single-quoted to prevent shell expansion
# of jq variable references ($t, $nd, $funcs, etc.). SC2016 is a false positive.
# shellcheck disable=SC2016
_FUNC_TYPE="FuncDecl"
# Build the jq filter with the function type injected, avoiding repeated literals.
JQ_NESTING_WALKER="
def func_type: \"${_FUNC_TYPE}\";
def nw(d):
  if type == \"object\" then
    (.Type // \"\") as \$t |
    if \$t == \"IfClause\" or \$t == \"ForClause\" or \$t == \"WhileClause\" or \$t == \"CaseClause\" then
      (d + 1),
      if \$t == \"IfClause\" then
        ((.Then // [])[] | nw(d + 1)),
        ((.Cond // [])[] | nw(d + 1)),
        (if .Else then
          if (.Else | has(\"Cond\")) then .Else | nw(d)
          else ((.Else.Then // [])[] | nw(d + 1))
          end
        else empty end)
      elif \$t == \"CaseClause\" then
        ((.Items // [])[] | (.Stmts // [])[] | nw(d + 1))
      else
        ((.Do // [])[] | nw(d + 1)),
        ((.Cond // [])[] | nw(d + 1))
      end
    elif \$t == func_type then
      empty
    else
      to_entries[] | .value | nw(d)
    end
  elif type == \"array\" then
    .[] | nw(d)
  else empty end;

[.. | select(.Type? == func_type)] as \$funcs |

([.Stmts // [] | .[] | select(.Cmd.Type != func_type) | nw(0)] |
  if length > 0 then max else 0 end) as \$top |

[\$funcs[] |
  {function: .Name.Value, depth: ([.Body | nw(0)] | if length > 0 then max else 0 end)}
] as \$fdepths |

([\$top, (\$fdepths | .[].depth)] | max) as \$fmax |

{
  per_function: \$fdepths,
  toplevel: \$top,
  file_max: \$fmax
}
"

# ---------------------------------------------------------------------------
# Legacy AWK fallback — identical to the old complexity-regression-helper.sh
# scanner for backward compatibility when shfmt is unavailable.
# ---------------------------------------------------------------------------
_awk_nesting_depth() {
	local _file="$1"
	awk '
		BEGIN { depth=0; max_depth=0 }
		/^[[:space:]]*#/ { next }
		/[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if(depth>max_depth) max_depth=depth }
		/[[:space:]]*(fi|done|esac)[[:space:]]*$/ || /^[[:space:]]*(fi|done|esac)$/ { if(depth>0) depth-- }
		END { print max_depth }
	' "$_file" 2>/dev/null || echo 0
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	local _per_function=false
	local _file=""

	while [ $# -gt 0 ]; do
		local _arg="$1"
		case "$_arg" in
			--per-function) _per_function=true; shift ;;
			-h|--help)
				sed -n '5,36p' "$0" | sed 's/^# \{0,1\}//'
				return 0
				;;
			-*)
				printf 'ERROR: unknown flag: %s\n' "$_arg" >&2
				return 2
				;;
			*)
				_file="$_arg"; shift ;;
		esac
	done

	if [ -z "$_file" ]; then
		printf 'ERROR: no file specified\n' >&2
		return 2
	fi

	if [ ! -f "$_file" ]; then
		printf 'ERROR: file not found: %s\n' "$_file" >&2
		return 2
	fi

	# --- shfmt path (preferred) ---
	if command -v shfmt >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
		local _json
		_json=$(shfmt --to-json < "$_file" 2>/dev/null) || {
			# shfmt parse error (e.g., POSIX-mode file, syntax error) — fall back
			printf '[nesting-depth] WARN: shfmt parse failed on %s, falling back to AWK\n' "$_file" >&2
			_awk_nesting_depth "$_file"
			return 0
		}

		if [ "$_per_function" = true ]; then
			printf '%s\n' "$_json" | jq -r "$JQ_NESTING_WALKER"' | .per_function[] | "\(.function)\t\(.depth)"'
		else
			printf '%s\n' "$_json" | jq -r "$JQ_NESTING_WALKER"' | .file_max'
		fi
		return 0
	fi

	# --- AWK fallback ---
	printf '[nesting-depth] WARN: shfmt not available, falling back to legacy AWK scanner (may produce false positives)\n' >&2
	if [ "$_per_function" = true ]; then
		printf '(global)\t%s\n' "$(_awk_nesting_depth "$_file")"
	else
		_awk_nesting_depth "$_file"
	fi
	return 0
}

main "$@"
