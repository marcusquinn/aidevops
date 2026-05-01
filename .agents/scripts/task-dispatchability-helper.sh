#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# task-dispatchability-helper.sh — brief/tier/dispatchability summary.

set -euo pipefail

_usage() {
	cat <<'EOF'
Usage: task-dispatchability-helper.sh check --task-id tNNN [--issue N] [--body-file PATH]

Checks task ID, TODO ref, brief/body worker-readiness, and likely tier hazards.
EOF
	return 0
}

_body_score() {
	local body_file="$1"
	python3 - "$body_file" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
signals = ['Task', 'Why', 'How', 'Acceptance', 'What', 'Session Origin', 'Files to modify']
score = sum(1 for s in signals if re.search(r'^##+\s+' + re.escape(s) + r'\b', text, re.I | re.M))
print(score)
PY
	return 0
}

_cmd_check() {
	local task_id=""
	local issue=""
	local body_file=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--task-id) [[ $# -gt 0 ]] || { printf 'ERROR: --task-id requires a value\n' >&2; return 2; }; local value="$1"; task_id="$value"; shift ;;
			--issue) [[ $# -gt 0 ]] || { printf 'ERROR: --issue requires a value\n' >&2; return 2; }; local value="$1"; issue="$value"; shift ;;
			--body-file) [[ $# -gt 0 ]] || { printf 'ERROR: --body-file requires a value\n' >&2; return 2; }; local value="$1"; body_file="$value"; shift ;;
			*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	if [[ -z "$task_id" ]]; then
		printf 'ERROR: --task-id is required\n' >&2
		return 2
	fi
	local failures=0
	printf 'Dispatchability check for %s\n' "$task_id"
	if grep -qE "^- \[[ xX]\] ${task_id} .*ref:(GH|GL)#" TODO.md 2>/dev/null; then
		printf '%s\n' '- TODO ref: ok'
	else
		printf '%s\n' '- TODO ref: missing'; failures=$((failures + 1))
	fi
	local brief="todo/tasks/${task_id}-brief.md"
	if [[ -f "$brief" ]]; then
		printf '%s %s\n' '- Brief file:' "$brief"
		body_file="$brief"
	elif [[ -n "$issue" && -z "$body_file" ]] && command -v gh >/dev/null 2>&1; then
		body_file="$(mktemp)"
		gh issue view "$issue" --json body --jq '.body // ""' >"$body_file" || true
		printf '%s\n' '- Brief file: absent; using issue body'
	else
		printf '%s\n' '- Brief file: missing'; failures=$((failures + 1))
	fi
	if [[ -n "$body_file" && -f "$body_file" ]]; then
		local score
		score="$(_body_score "$body_file")"
		printf '%s %s/7\n' '- Worker-ready heading score:' "$score"
		if [[ "$score" -lt 4 ]]; then
			failures=$((failures + 1))
		fi
	fi
	if [[ $failures -eq 0 ]]; then
		printf 'RESULT: dispatchable\n'
	else
		printf 'RESULT: not-dispatchable (%d issue(s))\n' "$failures"
	fi
	return 0
}

main() {
	local cmd="${1:-help}"
	case "$cmd" in
		help|--help|-h) _usage; return 0 ;;
		check) shift; _cmd_check "$@"; return $? ;;
		*) _usage >&2; return 2 ;;
	esac
	return 0
}

main "$@"
