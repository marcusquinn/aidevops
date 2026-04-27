#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# markdoc-validate.sh — Markdoc tag schema conformance checker (t2968)
#
# Validates Markdoc-tagged knowledge plane files against the JSON schemas at
# .agents/tools/markdoc/schemas/. No JS runtime required — pure regex parser.
#
# Usage:
#   markdoc-validate.sh validate <file> [<file2> ...]
#   markdoc-validate.sh validate-staged          # validate staged *.md files
#   markdoc-validate.sh list-schemas             # list known tag names
#   markdoc-validate.sh help                     # show usage
#
# Exit codes:
#   0 — valid (no errors)
#   1 — schema errors (unknown tag, missing required attr, bad enum, unclosed tag)
#   2 — parse / invocation error (file not found, schema dir missing, bad args)
#
# Output format (one per line, grep-friendly):
#   <file>:<line>:<col>: [error|warning] <message>
#
# Environment:
#   MARKDOC_SCHEMA_DIR  — path to schemas directory
#                         (default: <script-dir>/../tools/markdoc/schemas)

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- colour constants (guarded — do not clobber shared-constants.sh exports) ---
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Default schema directory — relative to script location
SCHEMA_DIR="${MARKDOC_SCHEMA_DIR:-${SCRIPT_DIR}/../tools/markdoc/schemas}"

# Counters (session-level)
TOTAL_ERRORS=0
TOTAL_WARNINGS=0

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

_log_error() {
	local _file="$1"
	local _line="$2"
	local _col="$3"
	local _msg="$4"
	printf '%s:%s:%s: error: %s\n' "$_file" "$_line" "$_col" "$_msg"
	TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
	return 0
}

_log_warning() {
	local _file="$1"
	local _line="$2"
	local _col="$3"
	local _msg="$4"
	printf '%s:%s:%s: warning: %s\n' "$_file" "$_line" "$_col" "$_msg"
	TOTAL_WARNINGS=$(( TOTAL_WARNINGS + 1 ))
	return 0
}

_die() {
	local _msg="$1"
	printf '%s[%s] ERROR: %s%s\n' "$RED" "$SCRIPT_NAME" "$_msg" "$NC" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# Schema loading — parse JSON with grep/sed (no jq required at runtime)
# ---------------------------------------------------------------------------

# _schema_exists <tag_name>
# Returns 0 if a schema file exists for the tag, 1 otherwise.
_schema_exists() {
	local _tag="$1"
	local _schema_file="${SCHEMA_DIR}/${_tag}.json"
	[[ -f "$_schema_file" ]]
	return $?
}

# _get_required_attrs <tag_name>
# Prints one required attribute name per line.
_get_required_attrs() {
	local _tag="$1"
	local _schema_file="${SCHEMA_DIR}/${_tag}.json"
	[[ -f "$_schema_file" ]] || return 0

	# Extract attrs where "required": true using grep context lines.
	# Pattern: capture attribute key names preceding a "required": true line.
	# Works for the canonical schema format (one key per line, key before required).
	python3 - "$_schema_file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    schema = json.load(f)
for attr, meta in schema.get("attributes", {}).items():
    if meta.get("required", False):
        print(attr)
PYEOF
	return 0
}

# _get_enum_values <tag_name> <attr_name>
# Prints allowed enum values one per line, or nothing if attr has no enum.
_get_enum_values() {
	local _tag="$1"
	local _attr="$2"
	local _schema_file="${SCHEMA_DIR}/${_tag}.json"
	[[ -f "$_schema_file" ]] || return 0

	python3 - "$_schema_file" "$_attr" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    schema = json.load(f)
attr_meta = schema.get("attributes", {}).get(sys.argv[2], {})
for v in attr_meta.get("enum", []):
    print(v)
PYEOF
	return 0
}

# _get_known_tags
# Prints all known tag names (one per line) from schema file basenames.
_get_known_tags() {
	local _f
	for _f in "${SCHEMA_DIR}"/*.json; do
		[[ -f "$_f" ]] || continue
		basename "$_f" .json
	done
	return 0
}

# ---------------------------------------------------------------------------
# Tag parser — extract Markdoc tags from a file with line/col info
# ---------------------------------------------------------------------------

# _parse_tags <file>
# Prints one record per line:  <line_num> <col_num> <tag_name> <is_close> <is_self_close> <attrs_string>
#   is_close:      1 = closing tag  {% /tag %}   0 = opening or self-closing
#   is_self_close: 1 = self-closing {% tag /%}   0 = opening or closing
#   attrs_string:  everything between the tag name and the closing %}
_parse_tags() {
	local _file="$1"
	local _line_num=0
	local _line

	while IFS= read -r _line || [[ -n "$_line" ]]; do
		_line_num=$(( _line_num + 1 ))

		# Find all {% ... %} patterns on this line using a loop.
		# We process the line character-by-character-ish using bash substring ops.
		local _rest="$_line"
		local _col=0

		while [[ "$_rest" == *'{%'* ]]; do
			# Find position of next {%
			local _before="${_rest%%\{%*}"
			local _start_col=$(( _col + ${#_before} + 1 ))
			_rest="${_rest#*\{%}"
			_col=$(( _start_col + 1 ))

			# Extract content up to next %}
			if [[ "$_rest" != *'%}'* ]]; then
				# No closing %} on this line — multi-line tag not supported, skip
				break
			fi

			local _inner="${_rest%%%\}*}"
			_rest="${_rest#*\%\}}"
			_col=$(( _col + ${#_inner} + 2 ))

			# Trim leading/trailing whitespace from inner
			_inner="${_inner#"${_inner%%[![:space:]]*}"}"
			_inner="${_inner%"${_inner##*[![:space:]]}"}"

			# Detect closing tag: starts with /
			local _is_close=0
			local _is_self_close=0

			if [[ "$_inner" == /* ]]; then
				_is_close=1
				_inner="${_inner#/}"
				_inner="${_inner#"${_inner%%[![:space:]]*}"}"
			fi

			# Detect self-closing: ends with /
			if [[ "$_inner" == */ ]]; then
				_is_self_close=1
				_inner="${_inner%/}"
				_inner="${_inner%"${_inner##*[![:space:]]}"}"
			fi

			# Extract tag name (first token)
			local _tag_name="${_inner%% *}"
			local _attrs=""
			if [[ "$_inner" == *' '* ]]; then
				_attrs="${_inner#* }"
			fi

			# Skip non-tag patterns (e.g. empty, comment-like)
			[[ -z "$_tag_name" ]] && continue
			# Tag names must be word chars + hyphens only
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
# Attribute parser
# ---------------------------------------------------------------------------

# _parse_attr_value <attrs_string> <attr_name>
# Prints the value of the named attribute, or exits 1 if not found.
_parse_attr_value() {
	local _attrs="$1"
	local _attr="$2"
	local _val

	# Match: attr="value"  or  attr='value'  or  attr=bare_value
	if [[ "$_attrs" =~ (^|[[:space:]])"${_attr}"=\"([^\"]*)\" ]]; then
		_val="${BASH_REMATCH[2]}"
	elif [[ "$_attrs" =~ (^|[[:space:]])"${_attr}"=\'([^\']*)\' ]]; then
		_val="${BASH_REMATCH[2]}"
	elif [[ "$_attrs" =~ (^|[[:space:]])"${_attr}"=([^[:space:]\"\']+) ]]; then
		_val="${BASH_REMATCH[2]}"
	else
		return 1
	fi
	printf '%s\n' "$_val"
	return 0
}

# _extract_attr_names <attrs_string>
# Prints all attribute names present in the attrs string.
_extract_attr_names() {
	local _attrs="$1"
	# Use python for reliability; fallback to grep
	python3 - "$_attrs" <<'PYEOF' 2>/dev/null || true
import re, sys
attrs = sys.argv[1]
for m in re.finditer(r'(?:^|\s)([\w-]+)\s*=', attrs):
    print(m.group(1))
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# Validation logic
# ---------------------------------------------------------------------------

# _validate_tag_occurrence <file> <line> <col> <tag_name> <is_close> <is_self_close> <attrs>
_validate_tag_occurrence() {
	local _file="$1"
	local _line="$2"
	local _col="$3"
	local _tag="$4"
	local _is_close="$5"
	local _is_self_close="$6"
	local _attrs="$7"
	local _errs=0

	# Check 1: unknown tag name
	if ! _schema_exists "$_tag"; then
		_log_error "$_file" "$_line" "$_col" \
			"unknown tag '${_tag}' (not in schema set at ${SCHEMA_DIR})"
		return 1
	fi

	# Closing tags and self-closing tags don't carry attributes to validate
	if [[ "$_is_close" -eq 1 ]]; then
		return 0
	fi

	# Check 2: missing required attributes
	local _req_attr
	while IFS= read -r _req_attr; do
		[[ -z "$_req_attr" ]] && continue
		if ! _parse_attr_value "$_attrs" "$_req_attr" >/dev/null 2>&1; then
			_log_error "$_file" "$_line" "$_col" \
				"tag '${_tag}': missing required attribute '${_req_attr}'"
			_errs=$(( _errs + 1 ))
		fi
	done < <(_get_required_attrs "$_tag")

	# Check 3: enum constraint validation for all present attributes
	local _present_attr
	while IFS= read -r _present_attr; do
		[[ -z "$_present_attr" ]] && continue
		local _enum_vals
		_enum_vals=$(_get_enum_values "$_tag" "$_present_attr") || continue
		[[ -z "$_enum_vals" ]] && continue

		local _actual_val
		_actual_val=$(_parse_attr_value "$_attrs" "$_present_attr") || continue

		# Check the actual value is in the enum
		local _found=0
		local _ev
		while IFS= read -r _ev; do
			[[ "$_ev" == "$_actual_val" ]] && _found=1 && break
		done <<< "$_enum_vals"

		if [[ "$_found" -eq 0 ]]; then
			local _allowed
			_allowed=$(printf '%s' "$_enum_vals" | tr '\n' '|' | sed 's/|$//')
			_log_error "$_file" "$_line" "$_col" \
				"tag '${_tag}': attribute '${_present_attr}' value '${_actual_val}' not in enum [${_allowed}]"
			_errs=$(( _errs + 1 ))
		fi
	done < <(_extract_attr_names "$_attrs")

	[[ "$_errs" -gt 0 ]] && return 1
	return 0
}

# _validate_file <file>
# Returns 0 if the file is valid, 1 if schema errors, 2 if parse errors.
_validate_file() {
	local _file="$1"
	local _file_errors=0

	if [[ ! -f "$_file" ]]; then
		_die "file not found: ${_file}"
	fi

	# Stack for open block tags: entries are "line:tag_name"
	local _open_tags=()
	local _row

	while IFS=$'\t' read -r _ln _col _tag _is_close _is_self _attrs; do
		[[ -z "$_tag" ]] && continue

		if [[ "$_is_close" -eq 1 ]]; then
			# Verify there is a matching open tag (we track the most-recent only
			# for simplicity — full nesting validation is Phase 3 territory)
			local _matched=0
			local _i
			for (( _i = ${#_open_tags[@]} - 1; _i >= 0; _i-- )); do
				local _entry="${_open_tags[$_i]}"
				local _open_tag="${_entry#*:}"
				if [[ "$_open_tag" == "$_tag" ]]; then
					# Remove matched entry
					unset '_open_tags[$_i]'
					_open_tags=("${_open_tags[@]+"${_open_tags[@]}"}")
					_matched=1
					break
				fi
			done
			if [[ "$_matched" -eq 0 ]]; then
				# Closing tag with no open tag — still validate the tag name
				if ! _schema_exists "$_tag"; then
					_log_error "$_file" "$_ln" "$_col" \
						"unknown tag '${_tag}' (not in schema set)"
					_file_errors=$(( _file_errors + 1 ))
				fi
			fi
			continue
		fi

		# Validate opening / self-closing tag
		if ! _validate_tag_occurrence "$_file" "$_ln" "$_col" "$_tag" "$_is_close" "$_is_self" "$_attrs"; then
			_file_errors=$(( _file_errors + 1 ))
		fi

		# Track open block tags (not self-closing, not closing)
		if [[ "$_is_self" -eq 0 ]]; then
			# Only track if it's a known schema tag (unknown already reported above)
			if _schema_exists "$_tag"; then
				_open_tags+=("${_ln}:${_tag}")
			fi
		fi

	done < <(_parse_tags "$_file")

	# Check 4: unclosed block tags
	local _entry
	for _entry in "${_open_tags[@]+"${_open_tags[@]}"}"; do
		local _open_line="${_entry%%:*}"
		local _open_tag="${_entry#*:}"
		_log_error "$_file" "$_open_line" "1" \
			"unclosed block tag '${_open_tag}' (no matching {% /${_open_tag} %})"
		_file_errors=$(( _file_errors + 1 ))
	done

	[[ "$_file_errors" -gt 0 ]] && return 1
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_validate() {
	if [[ $# -eq 0 ]]; then
		printf '%s[%s] ERROR: validate requires at least one file argument%s\n' \
			"$RED" "$SCRIPT_NAME" "$NC" >&2
		exit 2
	fi

	if [[ ! -d "$SCHEMA_DIR" ]]; then
		_die "schema directory not found: ${SCHEMA_DIR} (set MARKDOC_SCHEMA_DIR or run from repo root)"
	fi

	local _any_error=0
	local _f
	for _f in "$@"; do
		if ! _validate_file "$_f"; then
			_any_error=1
		fi
	done

	[[ "$_any_error" -ne 0 ]] && exit 1
	exit 0
}

cmd_validate_staged() {
	if [[ ! -d "$SCHEMA_DIR" ]]; then
		_die "schema directory not found: ${SCHEMA_DIR}"
	fi

	# Knowledge plane directories the hook watches
	local _kp_dirs=(
		"_knowledge"
		"_cases"
		"_projects"
		"_performance"
		"_feedback"
		"_campaigns"
		"_inbox"
	)

	local _staged_files=()
	local _f
	while IFS= read -r _f; do
		[[ -z "$_f" ]] && continue
		# Check if file is in a knowledge plane directory and is a .md file
		local _in_kp=0
		local _dir
		for _dir in "${_kp_dirs[@]}"; do
			if [[ "$_f" == "${_dir}/"* || "$_f" == *"/${_dir}/"* ]]; then
				_in_kp=1
				break
			fi
		done
		[[ "$_in_kp" -eq 0 ]] && continue
		[[ "$_f" != *.md ]] && continue
		[[ -f "$_f" ]] && _staged_files+=("$_f")
	done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)

	if [[ ${#_staged_files[@]} -eq 0 ]]; then
		exit 0
	fi

	printf '[%s] Validating %d staged knowledge plane file(s)...\n' \
		"$SCRIPT_NAME" "${#_staged_files[@]}" >&2

	local _any_error=0
	for _f in "${_staged_files[@]}"; do
		if ! _validate_file "$_f"; then
			_any_error=1
		fi
	done

	[[ "$_any_error" -ne 0 ]] && exit 1
	exit 0
}

cmd_list_schemas() {
	if [[ ! -d "$SCHEMA_DIR" ]]; then
		_die "schema directory not found: ${SCHEMA_DIR}"
	fi
	printf 'Known Markdoc tags (from %s):\n' "$SCHEMA_DIR"
	local _tag
	while IFS= read -r _tag; do
		printf '  %s\n' "$_tag"
	done < <(_get_known_tags)
	return 0
}

usage() {
	cat <<EOF
markdoc-validate.sh — Markdoc tag schema conformance checker (t2968)

Usage:
  $SCRIPT_NAME validate <file> [<file2> ...]   Validate one or more files
  $SCRIPT_NAME validate-staged                  Validate staged knowledge plane *.md files
  $SCRIPT_NAME list-schemas                     List known tag names
  $SCRIPT_NAME help                             Show this usage

Exit codes:
  0  valid (no errors)
  1  schema errors
  2  parse / invocation error

Output format: <file>:<line>:<col>: [error|warning] <message>

Environment:
  MARKDOC_SCHEMA_DIR   Path to schemas directory
                       (default: <script-dir>/../tools/markdoc/schemas)
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
	validate)
		cmd_validate "$@"
		;;
	validate-staged)
		cmd_validate_staged
		;;
	list-schemas)
		cmd_list_schemas
		;;
	help | -h | --help | "")
		usage
		exit 0
		;;
	*)
		printf '%s[%s] ERROR: unknown command: %s%s\n' \
			"$RED" "$SCRIPT_NAME" "$_cmd" "$NC" >&2
		usage >&2
		exit 2
		;;
	esac
}

main "$@"
