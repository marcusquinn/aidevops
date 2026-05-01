#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# gh-thread-clean-helper.sh — token-efficient GitHub issue/PR thread reader.

set -euo pipefail

_usage() {
	cat <<'EOF'
Usage: gh-thread-clean-helper.sh <command> [options]

Commands:
  view issue|pr <number> [--repo owner/repo]   Fetch and clean a GitHub thread
  clean-file <path>                            Clean a gh JSON fixture/file
  help                                         Show this help

Removes aidevops signature footers, provenance/ops/internal-state blocks,
badge images, and common bot status noise while preserving actionable text.
EOF
	return 0
}

_die() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 1
}

_clean_json_stream() {
	local input_file
	input_file="$(mktemp)"
	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '%s\n' "$line" >>"$input_file"
	done
	python3 - "$input_file" <<'PY'
import json
import re
import sys

BOT_STATUS = re.compile(r'(review skipped|review failed|quota|configuration error|badge|sonarcloud summary|codacy summary)', re.I)
BLOCKS = [
    re.compile(r'<!--\s*(?:provenance|ops|internal state)\s*:start.*?<!--\s*(?:provenance|ops|internal state)\s*:end\s*-->', re.I | re.S),
    re.compile(r'<!--\s*aidevops:sig\s*-->.*?(?=\n\n|\Z)', re.I | re.S),
]
FOOTER = re.compile(r'\n---\n.*?aidevops\.sh.*?\Z', re.I | re.S)
BADGE = re.compile(r'^\s*!\[[^\]]*\]\([^)]*\)\s*$', re.M)


def clean_body(value):
    if not value:
        return ""
    text = str(value)
    for pattern in BLOCKS:
        text = pattern.sub('', text)
    text = FOOTER.sub('', text)
    text = BADGE.sub('', text)
    lines = []
    for line in text.splitlines():
        if BOT_STATUS.search(line) and not re.search(r'\b[\w./-]+:\d+\b', line):
            continue
        lines.append(line.rstrip())
    text = '\n'.join(lines)
    text = re.sub(r'\n{3,}', '\n\n', text).strip()
    return text


def emit_record(prefix, body):
    cleaned = clean_body(body)
    if cleaned:
        print(f'## {prefix}')
        print()
        print(cleaned)
        print()


raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
if not raw.strip():
    sys.exit(0)
data = json.loads(raw)
if isinstance(data, dict):
    if 'body' in data:
        emit_record('Body', data.get('body'))
    comments = data.get('comments') or data.get('nodes') or []
elif isinstance(data, list):
    comments = data
else:
    comments = []

for index, item in enumerate(comments, 1):
    if not isinstance(item, dict):
        continue
    author = item.get('author', {}).get('login') if isinstance(item.get('author'), dict) else item.get('user', {}).get('login', 'unknown')
    body = clean_body(item.get('body', ''))
    if not body:
        continue
    if BOT_STATUS.search(body) and not re.search(r'\b[\w./-]+:\d+\b', body):
        continue
    emit_record(f'Comment {index} ({author or "unknown"})', body)
PY
	rm -f "$input_file"
	return 0
}

_cmd_clean_file() {
	local path="$1"
	if [[ ! -f "$path" ]]; then
		_die "file not found: $path"
		return 1
	fi
	_clean_json_stream <"$path"
	return 0
}

_cmd_view() {
	local kind="$1"
	local number="$2"
	shift 2
	local repo=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--repo) [[ $# -gt 0 ]] || { _die "--repo requires a value"; return 2; }; local value="$1"; repo="$value"; shift ;;
			*) _die "unknown option: $arg"; return 1 ;;
		esac
	done
	if [[ "$kind" != "issue" && "$kind" != "pr" ]]; then
		_die "kind must be issue or pr"
		return 1
	fi
	local repo_args=()
	if [[ -n "$repo" ]]; then
		repo_args=(--repo "$repo")
	fi
	if [[ "$kind" == "issue" ]]; then
		gh issue view "$number" "${repo_args[@]}" --json body,comments | _clean_json_stream
	else
		gh pr view "$number" "${repo_args[@]}" --json body,comments | _clean_json_stream
	fi
	return 0
}

main() {
	local cmd="${1:-help}"
	case "$cmd" in
		help|--help|-h) _usage ;;
		clean-file) shift; [[ $# -eq 1 ]] || { _usage >&2; return 2; }; local path="$1"; _cmd_clean_file "$path" ;;
		view) shift; [[ $# -ge 2 ]] || { _usage >&2; return 2; }; _cmd_view "$@" ;;
		*) _usage >&2; return 2 ;;
	esac
	return $?
}

main "$@"
