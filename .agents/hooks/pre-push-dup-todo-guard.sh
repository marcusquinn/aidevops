#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pre-push-dup-todo-guard.sh — git pre-push hook (t2745).
#
# Blocks a push when TODO.md on the pushed commit introduces a duplicate task
# ID or increases the occurrence count of a duplicate already present in the
# remote baseline. Pre-existing duplicates therefore do not block unrelated
# branches, while any regression remains fail-closed.
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
#   DUP_TODO_GUARD_DISABLE=1  — bypass for this invocation (logs warning to stderr)
#   DUP_TODO_GUARD_DEBUG=1    — verbose stderr trace
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
	[[ "${DUP_TODO_GUARD_DEBUG:-0}" == "1" ]] || return 0
	_log DEBUG "$_msg"
	return 0
}

_compute_baseline() {
	local _remote="$1"
	local _local_sha="$2"
	local _remote_sha="$3"
	local _candidate
	local _default_remote_head=""
	local _baseline=""

	if [[ -n "$_remote_sha" ]] && ! [[ "$_remote_sha" =~ $_zero_sha_pattern ]]; then
		if git cat-file -e "${_remote_sha}^{commit}" 2>/dev/null; then
			printf '%s\n' "$_remote_sha"
			return 0
		fi
	fi

	[[ -n "$_remote" ]] || _remote="origin"
	_default_remote_head=$(git symbolic-ref "refs/remotes/${_remote}/HEAD" 2>/dev/null \
		| sed "s@^refs/remotes/${_remote}/@@")
	if [[ -n "$_default_remote_head" ]]; then
		_default_remote_head="${_remote}/${_default_remote_head}"
	else
		for _candidate in "${_remote}/main" "${_remote}/master"; do
			if git rev-parse --verify "$_candidate" >/dev/null 2>&1; then
				_default_remote_head="$_candidate"
				break
			fi
		done
	fi

	[[ -n "$_default_remote_head" ]] || return 1
	_baseline=$(git merge-base "$_local_sha" "$_default_remote_head" 2>/dev/null) || return 1
	[[ -n "$_baseline" ]] || return 1
	printf '%s\n' "$_baseline"
	return 0
}

if [[ "${DUP_TODO_GUARD_DISABLE:-0}" == "1" ]]; then
	_log WARN "DUP_TODO_GUARD_DISABLE=1 — bypassing duplicate TODO check (audit trail: override active)"
	exit 0
fi

_exit_code=0

_remote_name="${1:-origin}"

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
	# Pattern: ^[whitespace]*- [x] tNNN[.N]*<space|EOL> — supports indented
	# subtasks and hierarchical IDs (e.g., t1271.1). Anchored to checkbox-and-
	# task-ID prefix to avoid matching prose that mentions a task ID.
	# BSD sed and GNU sed both support \1 backreference in basic RE.
	_task_ids=$(printf '%s\n' "$_todo_content" \
		| grep -E '^[[:space:]]*- \[.\] t[0-9]+(\.[0-9]+)*([[:space:]]|$)' \
		| sed 's/^[[:space:]]*- \[.\] \(t[0-9][0-9.]*\).*/\1/')

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

	# Compare duplicate occurrence counts with the remote baseline. This is a
	# ratchet: unchanged legacy duplicates are tolerated, but a new duplicate
	# or an increased count remains blocking. If no baseline can be resolved,
	# retain the original fail-closed full-snapshot behaviour.
	_base_task_ids=""
	_base_sha=""
	if _base_sha=$(_compute_baseline "$_remote_name" "$_local_sha" "${_remote_sha:-}"); then
		if git cat-file -e "${_base_sha}:TODO.md" 2>/dev/null; then
			_base_content=$(git show "${_base_sha}:TODO.md" 2>/dev/null) || _base_content=""
			if [[ -n "$_base_content" ]]; then
				_base_task_ids=$(printf '%s\n' "$_base_content" \
					| grep -E '^[[:space:]]*- \[.\] t[0-9]+(\.[0-9]+)*([[:space:]]|$)' \
					| sed 's/^[[:space:]]*- \[.\] \(t[0-9][0-9.]*\).*/\1/')
			fi
		fi
		_dbg "baseline for ${_local_ref}: ${_base_sha}"
	else
		_dbg "no baseline resolved for ${_local_ref} — enforcing full duplicate scan"
	fi

	_increased_duplicates=""
	while IFS= read -r _dup_id; do
		[[ -n "$_dup_id" ]] || continue
		_head_count=$(printf '%s\n' "$_task_ids" | grep -Fxc "$_dup_id" || true)
		_base_count=0
		if [[ -n "$_base_task_ids" ]]; then
			_base_count=$(printf '%s\n' "$_base_task_ids" | grep -Fxc "$_dup_id" || true)
		fi
		if [[ "$_head_count" -gt "$_base_count" ]]; then
			_increased_duplicates="${_increased_duplicates}${_increased_duplicates:+$'\n'}${_dup_id}"
		else
			_dbg "grandfathering unchanged duplicate ${_dup_id} (${_head_count} occurrences)"
		fi
	done <<<"$_duplicates"

	if [[ -z "$_increased_duplicates" ]]; then
		continue
	fi
	_duplicates="$_increased_duplicates"

	# Found duplicates — block and report line numbers for each.
	_exit_code=1
	printf '\n[%s][BLOCK] Push blocked: new or increased duplicate task IDs in TODO.md\n\n' "$GUARD_NAME" >&2

	printf '%s\n' "$_duplicates" | while IFS= read -r _dup_id; do
		[[ -z "$_dup_id" ]] && continue
		# Find line numbers of the duplicate entries (1-indexed, matching the
		# checkbox-and-ID anchor so description-only mentions are excluded).
		# Dots in the task ID must be escaped for ERE to prevent false positives.
		_dup_id_esc=$(printf '%s' "$_dup_id" | sed 's/\./\\./g')
		_line_nums=$(printf '%s\n' "$_todo_content" \
			| grep -nE '^[[:space:]]*- \[.\] '"${_dup_id_esc}"'([[:space:]]|$)' \
			| cut -d: -f1 \
			| tr '\n' ',' \
			| sed 's/,$//')
		printf '  Duplicate task ID: %s  (TODO.md lines: %s)\n' "$_dup_id" "$_line_nums" >&2
	done

	printf '\n' >&2
	printf '  Fix: remove the duplicate entry from TODO.md, amend the commit,\n' >&2
	printf '       and push again.\n' >&2
	printf '  Check: grep -n "^- \\[.\\] tNNN " TODO.md\n' >&2
	printf '  Bypass (warning logged): DUP_TODO_GUARD_DISABLE=1 git push\n' >&2
	printf '  Bypass all hooks:        git push --no-verify\n\n' >&2
done

exit "$_exit_code"
