#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pre-push-dup-todo-guard.sh — git pre-push hook (t2745).
#
# Blocks a push when TODO.md on the pushed commit contains two or more
# checkbox lines with the same task ID.
# Example duplicate: two lines starting with "- [ ] t2743 " or "- [x] t2743 ".
#
# Root cause this catches: _seed_orphan_todo_line (issue-sync) appends a
# minimal entry for an issue that already has a rich planning-PR entry. On
# git rebase the two entries co-exist with no merge conflict (different line
# numbers). This hook catches the duplicate before it reaches the remote.
#
# Install: see .agents/scripts/install-pre-push-guards.sh
#
# Git pre-push protocol:
#   $1 = remote name
#   $2 = remote URL
#   stdin: one line per ref being pushed:
#     <local_ref> <local_sha> <remote_ref> <remote_sha>
#
# Exit 0 = allow push. Exit 1 = block push.
#
# Environment:
#   AIDEVOPS_SKIP_DUP_TODO_GUARD=1  — bypass for this invocation (logs warning to stderr)
#   AIDEVOPS_DUP_TODO_GUARD_DEBUG=1 — verbose stderr trace
#
# Fail-open cases (exit 0 with warning):
#   - TODO.md does not exist in the pushed commit
#   - git show fails for the pushed SHA
#
# Cross-platform requirements met:
#   - POSIX ERE only ([[:space:]] not \s, no \b, no \w)
#   - Bash 3.2 compatible (no read -a, no mapfile, =~ uses variable pattern)
#   - Works with BSD grep (macOS) and GNU grep

set -u

GUARD_NAME="dup-todo-guard"

_log() {
	local _level="$1"
	local _msg="$2"
	printf '[%s][%s] %s\n' "$GUARD_NAME" "$_level" "$_msg" >&2
	return 0
}

_dbg() {
	local _msg="$1"
	[[ "${AIDEVOPS_DUP_TODO_GUARD_DEBUG:-0}" == "1" ]] || return 0
	_log DEBUG "$_msg"
	return 0
}

if [[ "${AIDEVOPS_SKIP_DUP_TODO_GUARD:-0}" == "1" ]]; then
	_log WARN "AIDEVOPS_SKIP_DUP_TODO_GUARD=1 — bypassing duplicate TODO check (audit trail: override active)"
	exit 0
fi

_exit_code=0

# Pattern for zero-SHA (branch deletion). Use a variable so [[ =~ ]] works
# consistently across Bash 3.2 (macOS default) and later versions.
_zero_sha_pattern='^[0]+$'

while IFS=' ' read -r _local_ref _local_sha _remote_ref _remote_sha; do
	[[ -z "${_local_sha:-}" ]] && continue

	# Branch deletion (all-zero SHA) — nothing to check.
	if [[ "$_local_sha" =~ $_zero_sha_pattern ]]; then
		_dbg "branch deletion detected for ${_local_ref} — skipping"
		continue
	fi

	_dbg "checking ${_local_ref} at ${_local_sha}"

	# Fast-path: is TODO.md present in this commit at all?
	if ! git cat-file -e "${_local_sha}:TODO.md" 2>/dev/null; then
		_dbg "TODO.md not in commit ${_local_sha} — skipping"
		continue
	fi

	# Read TODO.md from the pushed commit (not the working tree).
	_todo_content=""
	_todo_content=$(git show "${_local_sha}:TODO.md" 2>/dev/null) || {
		_log WARN "git show ${_local_sha}:TODO.md failed — fail-open for this ref"
		continue
	}

	# Extract task IDs from checkbox lines only.
	# Pattern: ^- [x] tNNN<space> — anchored to avoid matching prose that
	# mentions a task ID in a description or comment.
	# BSD sed and GNU sed both support \1 backreference in basic RE.
	_task_ids=$(printf '%s\n' "$_todo_content" \
		| grep -E '^- \[.\] t[0-9]+[[:space:]]' \
		| sed 's/^- \[.\] \(t[0-9]*\)[[:space:]].*/\1/')

	if [[ -z "$_task_ids" ]]; then
		_dbg "no task IDs extracted from TODO.md in ${_local_sha}"
		continue
	fi

	# Find IDs that appear more than once.
	_duplicates=$(printf '%s\n' "$_task_ids" | sort | uniq -d)

	if [[ -z "$_duplicates" ]]; then
		_dbg "no duplicate task IDs in TODO.md at ${_local_sha}"
		continue
	fi

	# Found duplicates — block and report line numbers for each.
	_exit_code=1
	printf '\n[%s][BLOCK] Push blocked: duplicate task IDs in TODO.md\n\n' "$GUARD_NAME" >&2

	printf '%s\n' "$_duplicates" | while IFS= read -r _dup_id; do
		[[ -z "$_dup_id" ]] && continue
		# Find line numbers of the duplicate entries (1-indexed, matching the
		# checkbox-and-ID anchor so description-only mentions are excluded).
		_line_nums=$(printf '%s\n' "$_todo_content" \
			| grep -n "^- \[.\] ${_dup_id}[[:space:]]" \
			| cut -d: -f1 \
			| tr '\n' ',' \
			| sed 's/,$//')
		printf '  Duplicate task ID: %s  (TODO.md lines: %s)\n' "$_dup_id" "$_line_nums" >&2
	done

	printf '\n' >&2
	printf '  Fix: remove the duplicate entry from TODO.md, amend the commit,\n' >&2
	printf '       and push again.\n' >&2
	printf '  Check: grep -n "^- \\[.\\] tNNN " TODO.md\n' >&2
	printf '  Bypass (warning logged): AIDEVOPS_SKIP_DUP_TODO_GUARD=1 git push\n' >&2
	printf '  Bypass all hooks:        git push --no-verify\n\n' >&2
done

exit "$_exit_code"
