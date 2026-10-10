#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# gh-thread-clean-helper.sh — token-efficient GitHub issue/PR thread reader.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
	python3 "${SCRIPT_DIR}/gh_thread_clean.py" "$input_file"
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
