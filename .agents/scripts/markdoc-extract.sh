#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# markdoc-extract.sh — Extract Markdoc tags from source.md to a -tags.json sidecar (t2972)
#
# Reads a Markdoc-tagged source file, extracts all tag occurrences with their
# attributes, and writes a JSON sidecar consumed by pageindex-generator.py for
# Phase-5 metadata lifting.
#
# Usage:
#   markdoc-extract.sh extract <source.md>
#       Writes <basename>-tags.json next to the input file.
#       Exits 0 on success, 1 on error.
#
#   markdoc-extract.sh extract <source.md> --stdout
#       Writes JSON to stdout instead of a sidecar file.
#
#   markdoc-extract.sh help
#       Show this help.
#
# Output format  (<basename>-tags.json):
#   JSON array of objects, one per tag occurrence:
#   [
#     {
#       "tag":          "sensitivity",
#       "attrs":        {"tier": "privileged", "scope": "file"},
#       "line":         3,
#       "is_close":     false,
#       "is_self_close":true
#     },
#     ...
#   ]
#
# Dependencies: python3, markdoc_tag_extractor.py (same directory as this script)
#
# ShellCheck: SC2034 suppressed — colour vars may be indirect-used only.
# shellcheck disable=SC2034

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- colour constants (guarded) ---
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'

_die() {
	local _msg="$1"
	printf '%b[%s] ERROR: %s%b\n' "$RED" "$SCRIPT_NAME" "$_msg" "$NC" >&2
	exit 1
	return 1
}

_info() {
	local _msg="$1"
	printf '%b[%s] %s%b\n' "$GREEN" "$SCRIPT_NAME" "$_msg" "$NC" >&2
	return 0
}

# ---------------------------------------------------------------------------
# _require_python3
# ---------------------------------------------------------------------------
_require_python3() {
	if ! command -v python3 >/dev/null 2>&1; then
		_die "python3 is required but not found in PATH"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _require_extractor_module
# ---------------------------------------------------------------------------
_require_extractor_module() {
	local _module="${SCRIPT_DIR}/markdoc_tag_extractor.py"
	if [[ ! -f "$_module" ]]; then
		_die "markdoc_tag_extractor.py not found at: $_module"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _extract_tags  <source_file> <output_path|-|--stdout>
# ---------------------------------------------------------------------------
_extract_tags() {
	local _source="$1"
	local _output="$2"

	if [[ ! -f "$_source" ]]; then
		_die "file not found: $_source"
	fi

	# Run the Python extractor inline via sys.path injection
	local _py_exit
	python3 - "$_source" "$_output" "$SCRIPT_DIR" <<'PYEOF'
import sys
import json

sys.path.insert(0, sys.argv[3])  # add script dir so markdoc_tag_extractor is importable
from markdoc_tag_extractor import extract_tags_from_lines

source_file = sys.argv[1]
output_dest = sys.argv[2]  # file path or "-" for stdout

with open(source_file, 'r', encoding='utf-8') as fh:
    lines = fh.read().splitlines()

tags = extract_tags_from_lines(lines)

output = json.dumps(tags, indent=2, ensure_ascii=False) + '\n'

if output_dest == '-':
    sys.stdout.write(output)
else:
    with open(output_dest, 'w', encoding='utf-8') as fh:
        fh.write(output)
PYEOF
	_py_exit=$?
	if [[ "$_py_exit" -eq 0 ]]; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# cmd_extract
# ---------------------------------------------------------------------------
cmd_extract() {
	local _source=""
	local _stdout=0

	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--stdout)
			_stdout=1
			;;
		-*)
			_die "Unknown option: $_key"
			;;
		*)
			if [[ -z "$_source" ]]; then
				_source="$_key"
			fi
			;;
		esac
	done

	if [[ -z "$_source" ]]; then
		_die "extract requires <source.md>"
	fi

	_require_python3
	_require_extractor_module

	local _output_path
	if [[ "$_stdout" -eq 1 ]]; then
		_output_path="-"
	else
		# Write sidecar next to source: <basename>-tags.json
		local _dir
		_dir="$(dirname "$_source")"
		local _base
		_base="$(basename "$_source" .md)"
		_output_path="${_dir}/${_base}-tags.json"
	fi

	_extract_tags "$_source" "$_output_path"

	if [[ "$_stdout" -eq 0 ]]; then
		_info "Extracted tags to: $_output_path"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------
cmd_help() {
	sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local _subcommand="${1:-help}"
	shift || true
	case "$_subcommand" in
	extract)
		cmd_extract "$@"
		;;
	help | -h | --help)
		cmd_help
		;;
	*)
		printf '%b[%s] ERROR: unknown subcommand: %s%b\n' \
			"$RED" "$SCRIPT_NAME" "$_subcommand" "$NC" >&2
		cmd_help >&2
		exit 1
		;;
	esac
	return 0
}

main "$@"
