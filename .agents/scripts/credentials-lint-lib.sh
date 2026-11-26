#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Credentials Lint + Safe Loader Library (GH#40479)
# =============================================================================
# credentials.sh is user-editable. Sourcing a line such as
#   export NAME=abc>def
# runs a shell redirection (creates a stray file named after the secret tail and
# truncates the value). This library parses `export NAME=VALUE` lines WITHOUT
# executing them:
#
#   credentials_lint_file FILE   Report malformed lines (name + line number only,
#                                never values). Returns 1 when any are found.
#   credentials_load_safe FILE   Export only well-formed lines; refuse malformed
#                                ones by name. Never executes file content.
#
# Usage: source "${SCRIPT_DIR}/credentials-lint-lib.sh"
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_CREDENTIALS_LINT_LIB_LOADED:-}" ]] && return 0
_CREDENTIALS_LINT_LIB_LOADED=1

# Parse result globals (set by _cred_parse_line)
_CRED_NAME=""
_CRED_VALUE=""
_CRED_REASON=""

# Decode a validated double-quoted body: \\ \" \$ \` collapse, other
# backslashes stay literal (POSIX double-quote semantics).
_cred_decode_dq() {
	local body="$1"
	local out="" ch="" next="" i=0
	local len=${#body}
	while ((i < len)); do
		ch="${body:i:1}"
		if [[ "$ch" == "\\" && $((i + 1)) -lt $len ]]; then
			next="${body:i+1:1}"
			case "$next" in
			"\\" | '"' | '$' | '`')
				out+="$next"
				i=$((i + 2))
				continue
				;;
			esac
		fi
		out+="$ch"
		i=$((i + 1))
	done
	_CRED_VALUE="$out"
	return 0
}

# Decode a validated unquoted value: backslash-escaped characters (legacy
# printf %q output) become the escaped character.
_cred_decode_unquoted() {
	local raw="$1"
	local out="" ch="" i=0
	local len=${#raw}
	while ((i < len)); do
		ch="${raw:i:1}"
		if [[ "$ch" == "\\" && $((i + 1)) -lt $len ]]; then
			i=$((i + 1))
			ch="${raw:i:1}"
		fi
		out+="$ch"
		i=$((i + 1))
	done
	_CRED_VALUE="$out"
	return 0
}

# Parse one line without executing it.
# Returns: 0 well-formed export (sets _CRED_NAME/_CRED_VALUE)
#          1 not an assignment line (skip)
#          2 malformed (sets _CRED_NAME when known, and _CRED_REASON)
_cred_parse_line() {
	local line="$1"
	local assign_re='^[[:space:]]*(export[[:space:]]+)?([^=[:space:]#]+)=(.*)$'
	local name_re='^[A-Za-z_][A-Za-z0-9_]*$'
	local plain_re='^([A-Za-z0-9_@%+=:,./^-]|\\.|[A-Za-z0-9_@%+=:,./^-]#)*$'
	local comment_re='^(.*[^[:space:]])[[:space:]]+#.*$'
	local trail_re='^[[:space:]]+#.*$|^[[:space:]]*$'
	local rest="" value=""

	_CRED_NAME=""
	_CRED_VALUE=""
	_CRED_REASON=""

	[[ "$line" =~ $assign_re ]] || return 1
	# A bare `NAME=value` is only treated as an assignment when NAME is plain.
	if [[ -z "${BASH_REMATCH[1]}" && ! "${BASH_REMATCH[2]}" =~ $name_re ]]; then
		return 1
	fi
	_CRED_NAME="${BASH_REMATCH[2]}"
	value="${BASH_REMATCH[3]}"

	if [[ ! "$_CRED_NAME" =~ $name_re ]]; then
		_CRED_NAME=""
		_CRED_REASON="invalid variable name"
		return 2
	fi

	if [[ "$value" == '"'* ]]; then
		# Double-quoted: find the closing quote, allow only a trailing comment.
		local head="" tail="" body_re='^"(([^"\\$`]|\\.)*)"(.*)$'
		if [[ "$value" =~ $body_re ]]; then
			head="${BASH_REMATCH[1]}"
			tail="${BASH_REMATCH[3]}"
			if [[ "$tail" =~ $trail_re ]]; then
				_cred_decode_dq "$head"
				return 0
			fi
			_CRED_REASON="text after closing quote"
			return 2
		fi
		_CRED_REASON="unterminated or unsafe double-quoted value (unescaped quote, \$ or backtick)"
		return 2
	fi

	if [[ "$value" == "'"* ]]; then
		local sq_body_re="^'([^']*)'(.*)\$"
		if [[ "$value" =~ $sq_body_re ]]; then
			local sq_value="${BASH_REMATCH[1]}"
			if [[ "${BASH_REMATCH[2]}" =~ $trail_re ]]; then
				_CRED_VALUE="$sq_value"
				return 0
			fi
			_CRED_REASON="text after closing quote"
			return 2
		fi
		_CRED_REASON="unterminated single-quoted value"
		return 2
	fi

	# Unquoted: strip a whitespace-separated trailing comment, then require a
	# metacharacter-free token.
	rest="$value"
	if [[ "$rest" =~ $comment_re ]]; then
		rest="${BASH_REMATCH[1]}"
	fi
	if [[ "$rest" =~ $plain_re ]]; then
		_cred_decode_unquoted "$rest"
		return 0
	fi
	_CRED_REASON="unquoted value contains a shell metacharacter or whitespace"
	return 2
}

# Report malformed lines in FILE: "line N: NAME (reason)". Never prints values.
# Output goes to stdout; returns 1 when any malformed line exists, 0 otherwise
# (including a missing file).
credentials_lint_file() {
	local file="$1"
	local line="" lineno=0 rc=0 bad=0 label=""
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))
		rc=0
		_cred_parse_line "$line" || rc=$?
		if [[ "$rc" -eq 2 ]]; then
			bad=$((bad + 1))
			label="${_CRED_NAME:-<invalid name>}"
			printf 'line %s: %s (%s)\n' "$lineno" "$label" "$_CRED_REASON"
		fi
	done <"$file"
	[[ "$bad" -eq 0 ]] || return 1
	return 0
}

# Export only well-formed lines from FILE; refuse malformed ones by name on
# stderr. Follows `source "<path>/credentials.sh"` tenant-loader lines (depth
# limited) by parsing, never sourcing. Never executes file content, so a
# malformed line cannot create files or run commands.
# Returns 1 if any line was refused, 0 otherwise.
credentials_load_safe() {
	local file="$1"
	local depth="${2:-0}"
	local input="$file"
	local line="" lineno=0 rc=0 refused=0 sub=""
	local source_re='^[[:space:]]*(source|\.)[[:space:]]+"?([^"[:space:];&|<>$`]+/credentials\.sh)"?[[:space:]]*$'
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))
		if [[ "$line" =~ $source_re ]]; then
			sub="${BASH_REMATCH[2]}"
			if [[ "$depth" -lt 2 && "$sub" != "$file" ]]; then
				credentials_load_safe "$sub" "$((depth + 1))" || refused=1
			fi
			continue
		fi
		rc=0
		_cred_parse_line "$line" || rc=$?
		case "$rc" in
		0)
			printf -v "$_CRED_NAME" '%s' "$_CRED_VALUE"
			# shellcheck disable=SC2163  # export by variable name is intended
			export "$_CRED_NAME"
			;;
		2)
			refused=1
			printf 'credentials: refused line %s: %s (%s); fix with: aidevops secret set %s\n' \
				"$lineno" "${_CRED_NAME:-<invalid name>}" "$_CRED_REASON" "${_CRED_NAME:-NAME}" >&2
			;;
		esac
	done <"$input"
	[[ "$refused" -eq 0 ]] || return 1
	return 0
}
