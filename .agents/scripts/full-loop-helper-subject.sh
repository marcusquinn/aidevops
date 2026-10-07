#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Shared producer/consumer contract for reviewed squash subjects.
_full_loop_valid_squash_subject() {
	local subject="$1"
	local task_body=""
	local conventional_ere='^(feat|fix|docs|refactor|perf|test|chore|style|build|ci|security|plan)(\([^()[:cntrl:]]+\))?!?:[[:space:]]+[^[:space:]].*$'
	local task_ere='^(t[0-9]+|GH#[0-9]+):[[:space:]]+[^[:space:]].*$'
	if [[ "$subject" =~ $task_ere ]]; then
		task_body="${subject#*:}"
		# Strip the accepted whitespace separator before checking WIP bodies.
		task_body="${task_body#"${task_body%%[![:space:]]*}"}"
	fi
	if [[ "$subject" == *$'\n'* || "$subject" == *$'\r'* ||
		"$task_body" =~ ^[Ww][Ii][Pp][[:space:]:\(] ||
		! "$subject" =~ $conventional_ere && ! "$subject" =~ $task_ere ]]; then
		return 1
	fi
	return 0
}
