#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# interactive-start-helper.sh — safe interactive issue implementation entrypoint.

set -euo pipefail

_usage() {
	cat <<'EOF'
Usage: interactive-start-helper.sh --issue N --repo owner/repo --task "description" [--auto-dispatch]

Claims the issue for interactive implementation, runs the pre-edit loop check,
and starts full-loop in the current repo/worktree.
EOF
	return 0
}

main() {
	local issue=""
	local repo=""
	local task=""
	local auto_dispatch=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--issue) [[ $# -gt 0 ]] || { printf 'ERROR: --issue requires a value\n' >&2; return 2; }; local value="$1"; issue="$value"; shift ;;
			--repo) [[ $# -gt 0 ]] || { printf 'ERROR: --repo requires a value\n' >&2; return 2; }; local value="$1"; repo="$value"; shift ;;
			--task) [[ $# -gt 0 ]] || { printf 'ERROR: --task requires a value\n' >&2; return 2; }; local value="$1"; task="$value"; shift ;;
			--auto-dispatch) auto_dispatch=1 ;;
			--help|-h) _usage; return 0 ;;
			*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	if [[ -z "$issue" || -z "$repo" || -z "$task" ]]; then
		_usage >&2
		return 2
	fi
	local claim_args=(claim "$issue" "$repo")
	if [[ $auto_dispatch -eq 1 ]]; then
		claim_args+=(--implementing)
	fi
	interactive-session-helper.sh "${claim_args[@]}"
	pre-edit-check.sh --loop-mode --task "$task"
	full-loop-helper.sh start "GH#${issue} ${task}" --background
	return 0
}

main "$@"
