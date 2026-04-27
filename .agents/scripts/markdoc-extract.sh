#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# markdoc-extract.sh — Markdoc tag extractor (t2970)
#
# Produces two stable artefacts from a Markdoc-tagged file:
#   1. <basename>.txt       — tag-stripped plain text ({% ... %} removed,
#                             block-tag body content preserved)
#   2. <basename>-tags.json — array of tag objects with position and attr data
#
# Optionally produces:
#   3. <basename>-tree.json — hierarchical nesting tree (--tree flag)
#
# Usage:
#   markdoc-extract.sh extract <file> [--output-dir DIR] [--tree]
#   markdoc-extract.sh help
#
# Exit codes:
#   0 — success (all artefacts written)
#   1 — validation failed (markdoc-validate.sh found schema errors)
#   2 — parse / invocation error (file not found, bad args, etc.)
#
# Environment:
#   MARKDOC_SCHEMA_DIR   — forwarded to markdoc-validate.sh (default: auto)
#   MARKDOC_VALIDATE_SH  — override path to markdoc-validate.sh

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- colour constants (guarded — do not clobber shared-constants.sh exports) ---
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Locate companion validator — same directory, or env override.
VALIDATE_SH="${MARKDOC_VALIDATE_SH:-${SCRIPT_DIR}/markdoc-validate.sh}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_die() {
	local _msg="$1"
	printf '%b[%s] ERROR: %s%b\n' "$RED" "$SCRIPT_NAME" "$_msg" "$NC" >&2
	exit 2
	# Unreachable — satisfies the return-statement gate (exit 2 terminates above).
	# shellcheck disable=SC2317
	return 1
}

_warn() {
	local _msg="$1"
	printf '%b[%s] WARNING: %s%b\n' "$YELLOW" "$SCRIPT_NAME" "$_msg" "$NC" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Tag parser — identical logic to markdoc-validate.sh::_parse_tags
#
# Prints one TSV record per tag:
#   <line> <col> <tag_name> <is_close> <is_self_close> <attrs_string>
# ---------------------------------------------------------------------------

_parse_tags() {
	local _file="$1"
	local _line_num=0
	local _line

	while IFS= read -r _line || [[ -n "$_line" ]]; do
		_line_num=$(( _line_num + 1 ))

		local _rest="$_line"
		local _col=0

		while [[ "$_rest" == *'{%'* ]]; do
			local _before="${_rest%%\{%*}"
			local _start_col=$(( _col + ${#_before} + 1 ))
			_rest="${_rest#*\{%}"
			_col=$(( _start_col + 1 ))

			if [[ "$_rest" != *'%}'* ]]; then
				break
			fi

			local _inner="${_rest%%%\}*}"
			_rest="${_rest#*\%\}}"
			_col=$(( _col + ${#_inner} + 2 ))

			_inner="${_inner#"${_inner%%[![:space:]]*}"}"
			_inner="${_inner%"${_inner##*[![:space:]]}"}"

			local _is_close=0
			local _is_self_close=0

			if [[ "$_inner" == /* ]]; then
				_is_close=1
				_inner="${_inner#/}"
				_inner="${_inner#"${_inner%%[![:space:]]*}"}"
			fi

			if [[ "$_inner" == */ ]]; then
				_is_self_close=1
				_inner="${_inner%/}"
				_inner="${_inner%"${_inner##*[![:space:]]}"}"
			fi

			local _tag_name="${_inner%% *}"
			local _attrs=""
			if [[ "$_inner" == *' '* ]]; then
				_attrs="${_inner#* }"
			fi

			[[ -z "$_tag_name" ]] && continue
			if [[ ! "$_tag_name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
				continue
			fi

			printf '%d\t%d\t%s\t%d\t%d\t%s\n' \
				"$_line_num" "$_start_col" "$_tag_name" "$_is_close" "$_is_self_close" "$_attrs"
		done
	done <"$_file"
	return 0
}

# ---------------------------------------------------------------------------
# _strip_tags <file>
# Removes all {% ... %} tag markers from file content.
# Block tag body content is PRESERVED — only the tag markers themselves
# ({% tag ... %} and {% /tag %}) are removed.
# Outputs the stripped text to stdout.
# ---------------------------------------------------------------------------

_strip_tags() {
	local _file="$1"
	# Use python3 for reliable multi-line-safe regex removal of {% ... %}.
	python3 - "$_file" <<'PYEOF'
import re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    content = f.read()
# Remove all {% ... %} including self-closing {% tag / %} and closing {% /tag %}
stripped = re.sub(r'\{%.*?%\}', '', content)
# Collapse runs of blank lines introduced by removing block tags (max 2 blank lines)
stripped = re.sub(r'\n{3,}', '\n\n', stripped)
sys.stdout.write(stripped)
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# _attrs_to_json <attrs_string>
# Converts an attrs string like: key="val" key2='v2' key3=bare
# into a JSON object string: {"key":"val","key2":"v2","key3":"bare"}
# ---------------------------------------------------------------------------

_attrs_to_json() {
	local _attrs="$1"
	python3 - "$_attrs" <<'PYEOF'
import re, sys, json
attrs = sys.argv[1]
result = {}
for m in re.finditer(r'(?:^|\s)([\w-]+)\s*=\s*(?:"([^"]*)"|\047([^\047]*)\047|([^\s"\']+))', attrs):
    key = m.group(1)
    val = m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4))
    result[key] = val
print(json.dumps(result))
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# _count_lines_in_file <file>
# Returns total line count (needed for char_end of last tag).
# ---------------------------------------------------------------------------

_count_lines_in_file() {
	local _file="$1"
	wc -l < "$_file" | tr -d ' '
	return 0
}

# ---------------------------------------------------------------------------
# _build_tags_json <file>
# Outputs a JSON array of tag objects to stdout.
# Each object: {tag, attrs, scope, char_start, char_end, line_start, line_end}
# For scope: "file" = tags at root level, "section" = inside heading block,
# "inline" = self-closing tags.
# char_start/char_end are byte offsets from the start of the file.
# ---------------------------------------------------------------------------

_build_tags_json() {
	local _file="$1"
	# Write TSV to a temp file to avoid quote-escaping issues in the Python script.
	local _tsv_file
	_tsv_file=$(mktemp)
	_parse_tags "$_file" >"$_tsv_file"

	local _py_exit=0
	python3 - "$_file" "$_tsv_file" <<'PYEOF' || _py_exit=$?
import sys, json, re

file_path = sys.argv[1]
tsv_path  = sys.argv[2]

# Read file content for char offset computation
with open(file_path, encoding='utf-8') as f:
    content = f.read()

lines = content.split('\n')

def line_col_to_char(line_num, col_num):
    """Convert 1-based line/col to 0-based char offset."""
    offset = sum(len(lines[i]) + 1 for i in range(line_num - 1))
    return offset + (col_num - 1)

# Read TSV from temp file (safe from quoting issues)
with open(tsv_path, encoding='utf-8') as f:
    tsv_data = f.read()

rows = []
for row in tsv_data.strip().split('\n'):
    if not row.strip():
        continue
    parts = row.split('\t', 5)
    if len(parts) < 6:
        parts += [''] * (6 - len(parts))
    ln, col, tag, is_close, is_self, attrs = parts
    rows.append({
        'line': int(ln),
        'col': int(col),
        'tag': tag,
        'is_close': is_close == '1',
        'is_self': is_self == '1',
        'attrs_str': attrs
    })

ATTR_RE = re.compile(
    r'(?:^|\s)([\w-]+)\s*=\s*(?:"([^"]*)"|\047([^\047]*)\047|([^\s"\']+))'
)

def parse_attrs(attrs_str):
    result = {}
    for m in ATTR_RE.finditer(attrs_str):
        key = m.group(1)
        val = (m.group(2) if m.group(2) is not None
               else m.group(3) if m.group(3) is not None
               else m.group(4))
        result[key] = val
    return result

# Build result array
results = []
open_stack = []

for row in rows:
    tag = row['tag']
    ln = row['line']
    col = row['col']
    attrs_str = row['attrs_str']
    is_close = row['is_close']
    is_self = row['is_self']

    char_pos = line_col_to_char(ln, col)

    if is_close:
        matched_idx = None
        for i in range(len(open_stack) - 1, -1, -1):
            if open_stack[i]['tag'] == tag:
                matched_idx = i
                break
        if matched_idx is not None:
            open_entry = open_stack.pop(matched_idx)
            result_idx = open_entry['result_idx']
            close_end = content.find('%}', char_pos)
            if close_end != -1:
                close_end += 2
            else:
                close_end = char_pos
            results[result_idx]['char_end'] = close_end
            results[result_idx]['line_end'] = ln
    elif is_self:
        tag_end = content.find('%}', char_pos)
        if tag_end != -1:
            tag_end += 2
        else:
            tag_end = char_pos
        results.append({
            'tag': tag,
            'attrs': parse_attrs(attrs_str),
            'scope': 'inline',
            'char_start': char_pos,
            'char_end': tag_end,
            'line_start': ln,
            'line_end': ln,
        })
    else:
        tag_end = content.find('%}', char_pos)
        if tag_end != -1:
            tag_end += 2
        else:
            tag_end = char_pos
        scope = 'section' if open_stack else 'file'
        result_idx = len(results)
        results.append({
            'tag': tag,
            'attrs': parse_attrs(attrs_str),
            'scope': scope,
            'char_start': char_pos,
            'char_end': tag_end,
            'line_start': ln,
            'line_end': ln,
        })
        open_stack.append({
            'tag': tag,
            'char_start': char_pos,
            'line_start': ln,
            'result_idx': result_idx,
        })

print(json.dumps(results, indent=2))
PYEOF

	rm -f "$_tsv_file"
	if [[ "$_py_exit" -ne 0 ]]; then
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _build_tree_json <tags_json_content>
# Produces a hierarchical nesting tree from the flat tags array.
# File-scope tags at root, section-scope as children of enclosing heading,
# inline-scope as children of enclosing section.
# ---------------------------------------------------------------------------

_build_tree_json() {
	local _tags_json="$1"
	# Write tags JSON to a temp file to avoid quoting issues in the Python script.
	local _json_file
	_json_file=$(mktemp)
	printf '%s\n' "$_tags_json" >"$_json_file"

	local _py_exit=0
	python3 - "$_json_file" <<'PYEOF' || _py_exit=$?
import sys, json

with open(sys.argv[1], encoding='utf-8') as f:
    tags = json.load(f)

def build_tree(flat):
    """Nest tags by char_start/char_end containment, adding a children array."""
    nodes = [dict(t, children=[]) for t in flat]
    roots = []
    stack = []
    for node in nodes:
        while stack and stack[-1]['char_end'] <= node['char_start']:
            stack.pop()
        if stack:
            stack[-1]['children'].append(node)
        else:
            roots.append(node)
        stack.append(node)
    return roots

tree = build_tree(tags)
print(json.dumps(tree, indent=2))
PYEOF

	rm -f "$_json_file"
	if [[ "$_py_exit" -ne 0 ]]; then
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_extract() {
	local _file=""
	local _output_dir=""
	local _tree=0

	# Parse arguments — use local _arg="$1" pattern to satisfy positional-param gate.
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		shift
		case "$_arg" in
		--output-dir)
			[[ $# -eq 0 ]] && _die "--output-dir requires a directory argument"
			local _dir_arg="$1"
			shift
			_output_dir="$_dir_arg"
			;;
		--tree)
			_tree=1
			;;
		-*)
			_die "unknown option: ${_arg}"
			;;
		*)
			if [[ -z "$_file" ]]; then
				_file="$_arg"
			else
				_die "unexpected argument: ${_arg}"
			fi
			;;
		esac
	done

	[[ -z "$_file" ]] && _die "extract requires a file argument"
	[[ -f "$_file" ]] || _die "file not found: ${_file}"

	# Validate first — never extract malformed input
	if [[ ! -x "$VALIDATE_SH" ]]; then
		_die "validator not found or not executable: ${VALIDATE_SH}"
	fi
	if ! "$VALIDATE_SH" validate "$_file" 2>&1; then
		printf '%b[%s] validation failed for %s — no artefacts written%b\n' \
			"$RED" "$SCRIPT_NAME" "$_file" "$NC" >&2
		exit 1
	fi

	# Determine output directory
	local _dir
	if [[ -n "$_output_dir" ]]; then
		[[ -d "$_output_dir" ]] || _die "output directory not found: ${_output_dir}"
		_dir="$_output_dir"
	else
		_dir="$(dirname "$_file")"
	fi

	local _basename
	_basename="$(basename "$_file")"
	_basename="${_basename%.*}"

	local _txt_out="${_dir}/${_basename}.txt"
	local _tags_out="${_dir}/${_basename}-tags.json"

	# Write stripped text
	_strip_tags "$_file" >"$_txt_out" || _die "failed to write stripped text to ${_txt_out}"

	# Write tags JSON
	local _tags_json
	_tags_json=$(_build_tags_json "$_file") || _die "failed to build tags JSON"
	printf '%s\n' "$_tags_json" >"$_tags_out" || _die "failed to write tags JSON to ${_tags_out}"

	# Optionally write tree JSON
	if [[ "$_tree" -eq 1 ]]; then
		local _tree_out="${_dir}/${_basename}-tree.json"
		local _tree_json
		_tree_json=$(_build_tree_json "$_tags_json") || _die "failed to build tree JSON"
		printf '%s\n' "$_tree_json" >"$_tree_out" || _die "failed to write tree JSON to ${_tree_out}"
		printf '%b[%s] wrote %s, %s, %s%b\n' \
			"$GREEN" "$SCRIPT_NAME" "$_txt_out" "$_tags_out" "$_tree_out" "$NC" >&2
	else
		printf '%b[%s] wrote %s, %s%b\n' \
			"$GREEN" "$SCRIPT_NAME" "$_txt_out" "$_tags_out" "$NC" >&2
	fi

	return 0
}

usage() {
	cat <<EOF
markdoc-extract.sh — Markdoc tag extractor (t2970)

Usage:
  $SCRIPT_NAME extract <file> [--output-dir DIR] [--tree]
  $SCRIPT_NAME help

Outputs (written to same directory as <file> unless --output-dir is set):
  <basename>.txt        — tag-stripped plain text
  <basename>-tags.json  — flat array of tag objects with position data
  <basename>-tree.json  — hierarchical nesting tree (with --tree only)

tags.json object fields:
  tag         — tag name string
  attrs       — object of attribute key/value pairs
  scope       — "file" | "section" | "inline"
  char_start  — byte offset of tag open marker in file
  char_end    — byte offset after tag close marker (self-closing: end of {% %})
  line_start  — 1-based line of opening tag
  line_end    — 1-based line of closing tag (same as line_start for self-closing)

Exit codes:
  0  success
  1  validation failed (see markdoc-validate.sh output)
  2  parse / invocation error

Environment:
  MARKDOC_SCHEMA_DIR   Forwarded to markdoc-validate.sh
  MARKDOC_VALIDATE_SH  Override path to markdoc-validate.sh
                       (default: <script-dir>/markdoc-validate.sh)
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local _cmd="${1:-}"
	shift || true

	case "$_cmd" in
	extract)
		cmd_extract "$@"
		;;
	help | -h | --help | "")
		usage
		exit 0
		;;
	*)
		printf '%b[%s] ERROR: unknown command: %s%b\n' \
			"$RED" "$SCRIPT_NAME" "$_cmd" "$NC" >&2
		usage >&2
		exit 2
		;;
	esac
	return 0
}

main "$@"
