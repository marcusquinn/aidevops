#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# markdoc-render-gh.sh — GitHub comment renderer for Markdoc-tagged content (t2979)
#
# Strips or annotates Markdoc tags when reproducing source content in GitHub
# PR/issue threads, so raw tag syntax never leaks into human-readable output.
#
# Usage:
#   markdoc-render-gh.sh render <file> [--strip | --annotate]
#   markdoc-render-gh.sh render - [--strip | --annotate]
#   markdoc-render-gh.sh help
#
# Modes:
#   --strip (default)  Remove all Markdoc tags; preserve body content of block
#                      tags. Suitable for embedding clean prose in GH comments.
#   --annotate         Replace each tag with a compact GH-flavoured badge:
#                        {% sensitivity tier="privileged" /%} → **[PRIVILEGED]**
#                        {% draft-status status="draft" /%}   → *[DRAFT]*
#                        {% case-attach case-id="acme" /%}    → *[Case: acme]*
#                      Unknown / unrecognised tags → stripped (safe default).
#                      Block tags (open + close) → badge replaces open marker only;
#                      close marker is stripped silently.
#
# Input:
#   <file>   Path to a Markdoc-tagged source.md file.
#   -        Read from stdin.
#
# Output:
#   Rendered content on stdout. Suitable for piping into
#   `gh issue comment --body` or similar.
#
# Exit codes:
#   0 — success
#   2 — usage / invocation error
#
# Reference pattern: tag regex modelled on markdoc-extract.sh::_parse_tags.
# Badge syntax modelled on gh-signature-helper.sh comment format.

set -uo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

# --- colour constants (guarded — do not clobber shared-constants.sh exports) ---
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_die() {
	local _msg="$1"
	printf '%b[%s] ERROR: %s%b\n' "$RED" "$SCRIPT_NAME" "$_msg" "$NC" >&2
	exit 2
	# shellcheck disable=SC2317
	return 1
}

# ---------------------------------------------------------------------------
# _strip_tags_from_content <content>
# Remove all {% ... %} tag markers from stdin content.
# Block tag body content is preserved — only the markers themselves are removed.
# ---------------------------------------------------------------------------

_strip_tags_from_content() {
	local _content="$1"
	python3 - <<PYEOF
import re, sys

content = """${_content//\\/\\\\}""".replace('\\x00', '')

# Escape sequences may have landed — use the raw bytes from the shell var
import subprocess, os
# Re-read via environment variable to avoid quoting issues
content = os.environ.get('_MARKDOC_RENDER_CONTENT', '')

# Remove all {% ... %} markers (strip mode preserves body text inside block tags)
stripped = re.sub(r'\{%.*?%\}', '', content, flags=re.DOTALL)
# Collapse excessive blank lines introduced by removing block-tag markers (max 2)
stripped = re.sub(r'\n{3,}', '\n\n', stripped)
sys.stdout.write(stripped)
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# _annotate_tags_from_content
# Replace recognised Markdoc tags with GH-flavoured badge strings.
# Unknown / unrecognised tags are stripped (safe default).
# ---------------------------------------------------------------------------

_annotate_tags_from_content() {
	local _content="$1"
	python3 - <<PYEOF
import re, sys, os

content = os.environ.get('_MARKDOC_RENDER_CONTENT', '')

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

def tag_to_badge(tag_name, attrs_str):
    """Map known tag+attrs to a GH-flavoured badge string.
    Returns None to signal 'strip' for unknown tags."""
    attrs = parse_attrs(attrs_str)

    if tag_name == 'sensitivity':
        tier = attrs.get('tier', '')
        if tier:
            return '**[{}]**'.format(tier.upper())
        return '**[SENSITIVE]**'

    if tag_name == 'draft-status':
        status = attrs.get('status', '')
        if status:
            return '*[{}]*'.format(status.upper())
        return '*[DRAFT]*'

    if tag_name == 'case-attach':
        case_id = attrs.get('case-id', attrs.get('case_id', ''))
        if case_id:
            return '*[Case: {}]*'.format(case_id)
        return '*[CASE]*'

    # Unknown tag — strip (safe default)
    return None

TAG_RE = re.compile(r'\{%-?\s*(.*?)\s*-?%\}', re.DOTALL)

def process_match(m):
    inner = m.group(1).strip()

    # Closing tag {% /tag %} — strip silently
    if inner.startswith('/'):
        return ''

    # Determine self-closing vs opening block tag
    is_self = inner.endswith('/')
    if is_self:
        inner = inner[:-1].rstrip()

    tag_name = inner.split()[0] if inner.split() else ''
    attrs_str = inner[len(tag_name):].strip() if tag_name else ''

    if not tag_name or not re.match(r'^[a-zA-Z][a-zA-Z0-9_-]*$', tag_name):
        return ''

    badge = tag_to_badge(tag_name, attrs_str)
    if badge is None:
        return ''

    # For block opening tags, badge replaces the open marker;
    # the close marker is stripped by the closing-tag branch above.
    return badge

result = TAG_RE.sub(process_match, content)
# Collapse excessive blank lines
result = re.sub(r'\n{3,}', '\n\n', result)
sys.stdout.write(result)
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# cmd_render — main render entry point
# ---------------------------------------------------------------------------

cmd_render() {
	local _input=""
	local _mode="strip"

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		shift
		case "$_arg" in
		--strip)
			_mode="strip"
			;;
		--annotate)
			_mode="annotate"
			;;
		-)
			# bare '-' means stdin — treat as positional input argument
			if [[ -z "$_input" ]]; then
				_input="-"
			else
				_die "unexpected argument: ${_arg}"
			fi
			;;
		-*)
			_die "unknown option: ${_arg}"
			;;
		*)
			if [[ -z "$_input" ]]; then
				_input="$_arg"
			else
				_die "unexpected argument: ${_arg}"
			fi
			;;
		esac
	done

	[[ -z "$_input" ]] && _die "render requires a file argument or '-' for stdin"

	local _content
	if [[ "$_input" == "-" ]]; then
		_content="$(cat)"
	else
		[[ -f "$_input" ]] || _die "file not found: ${_input}"
		_content="$(cat "$_input")"
	fi

	export _MARKDOC_RENDER_CONTENT="$_content"

	case "$_mode" in
	strip)
		_strip_tags_from_content "$_content"
		;;
	annotate)
		_annotate_tags_from_content "$_content"
		;;
	esac

	unset _MARKDOC_RENDER_CONTENT
	return 0
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
markdoc-render-gh.sh — GitHub comment Markdoc renderer (t2979)

Usage:
  $SCRIPT_NAME render <file> [--strip | --annotate]
  $SCRIPT_NAME render - [--strip | --annotate]
  $SCRIPT_NAME help

Modes (default: --strip):
  --strip     Remove all {% %} tag markers; preserve enclosed body text.
              Use for embedding clean prose in GH comments.
  --annotate  Replace recognised tags with GH-flavoured badge strings:
                sensitivity tier="privileged"  → **[PRIVILEGED]**
                draft-status status="draft"    → *[DRAFT]*
                case-attach  case-id="acme"   → *[Case: acme]*
              Unknown tags are stripped (safe default).

Input:
  <file>   Path to a Markdoc-tagged file.
  -        Read from stdin.

Output:
  Rendered content on stdout.

Exit codes:
  0  success
  2  invocation error
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
	render)
		cmd_render "$@"
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
