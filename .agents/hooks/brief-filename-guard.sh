#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# brief-filename-guard.sh — git pre-commit hook (t3020).
#
# Blocks a commit that ADDS a todo/tasks/tNNN-brief.md file whose t-ID has
# never been allocated via a `chore: claim tNNN` commit anywhere in git history.
#
# This closes the bypass vector where unclaimed t-IDs appear first as brief
# FILENAMES rather than commit subjects. The commit-msg guard
# (install-task-id-guard.sh) only covers commit subjects; this hook covers the
# complementary entry point.
#
# Install: see .agents/scripts/install-pre-push-guards.sh
#   install-pre-push-guards.sh install --guard brief-filename
#
# Git pre-commit protocol: no arguments; hook reads staged index directly.
#
# Exit 0 = allow commit. Exit 1 = block commit.
#
# Environment:
#   BRIEF_FILENAME_GUARD_DISABLE=1  — bypass for this invocation
#   BRIEF_FILENAME_GUARD_DEBUG=1    — verbose stderr trace
#
# Fail-open cases (exit 0):
#   - no todo/tasks/tNNN-brief.md files are in the staged added set
#   - a staged file is being deleted (cleanup must always work)
#   - file is a modification of an existing brief (already committed previously)
#   - git is unavailable or repo is not initialised
#
# Fail-closed cases (exit 1):
#   - a brief file is ADDED (new to index) AND its t-ID has no
#     `chore: claim tNNN` commit in the full git history

set -u

GUARD_NAME="brief-filename-guard"

_log() {
	local _level="$1"
	local _msg="$2"
	printf '[%s][%s] %s\n' "$GUARD_NAME" "$_level" "$_msg" >&2
	return 0
}

_dbg() {
	local _msg="$1"
	[[ "${BRIEF_FILENAME_GUARD_DEBUG:-0}" == "1" ]] || return 0
	_log DEBUG "$_msg"
	return 0
}

if [[ "${BRIEF_FILENAME_GUARD_DISABLE:-0}" == "1" ]]; then
	_log INFO "BRIEF_FILENAME_GUARD_DISABLE=1 — bypassing"
	exit 0
fi

# ---------------------------------------------------------------------------
# Verify we are inside a git repo.
# ---------------------------------------------------------------------------
_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null
	return 0
}

REPO_ROOT=$(_repo_root)
if [[ -z "$REPO_ROOT" ]]; then
	_log WARN "not inside a git repo — fail-open"
	exit 0
fi

# ---------------------------------------------------------------------------
# Collect staged ADDED files matching the brief filename pattern.
# --diff-filter=A: Added files only. Modified/deleted files are skipped:
#   - Modified: brief already existed (t-ID was previously claimed)
#   - Deleted:  cleanup — must always pass
# ---------------------------------------------------------------------------
_raw_added=$(git diff --cached --name-only --diff-filter=A 2>/dev/null)
added_briefs=()
if [[ -n "$_raw_added" ]]; then
	while IFS= read -r _file; do
		[[ -z "$_file" ]] && continue
		if [[ "$_file" =~ ^todo/tasks/t[0-9]+-brief\.md$ ]]; then
			added_briefs+=("$_file")
		fi
	done <<< "$_raw_added"
fi

if [[ "${#added_briefs[@]}" -eq 0 ]]; then
	_dbg "no added brief files staged — pass"
	exit 0
fi

_dbg "${#added_briefs[@]} added brief file(s) staged"

# ---------------------------------------------------------------------------
# For each added brief file, extract the t-ID and verify it has a claim commit.
# A valid claim commit has the form: "chore: claim tNNN" (any subject match).
# ---------------------------------------------------------------------------
exit_code=0
for _brief_file in "${added_briefs[@]}"; do
	# Extract the t-ID from the filename
	# Pattern: todo/tasks/tNNN-brief.md → tNNN
	if [[ "$_brief_file" =~ ^todo/tasks/(t[0-9]+)-brief\.md$ ]]; then
		_tid="${BASH_REMATCH[1]}"
	else
		_dbg "  cannot extract t-ID from: $_brief_file — skip"
		continue
	fi

	_dbg "checking: $_brief_file (task ID: $_tid)"

	# Search the full history (all branches/tags) for a claim commit.
	# git log --all --grep performs a case-sensitive substring search on the
	# commit subject. The canonical claim subject is: "chore: claim tNNN"
	_claim_hit=$(git log --all --oneline --grep="chore: claim ${_tid}" 2>/dev/null | head -1)

	if [[ -n "$_claim_hit" ]]; then
		_dbg "  PASS: claim commit found: $_claim_hit"
		continue
	fi

	# No claim commit found — block with mentoring error.
	exit_code=1
	printf '\n[%s][BLOCK] Brief staged for unclaimed task ID\n\n' "$GUARD_NAME" >&2
	printf '  File:    %s\n' "$_brief_file" >&2
	printf '  Task ID: %s\n' "$_tid" >&2
	printf '  Reason:  no "chore: claim %s" commit found in git history\n' "$_tid" >&2
	printf '\n' >&2
	printf '  Remediation:\n' >&2
	printf '    1. Allocate the task ID properly:\n' >&2
	printf '         claim-task-id.sh --title "your-task-description"\n' >&2
	printf '       This creates the "chore: claim tNNN" commit that registers a valid t-ID.\n' >&2
	printf '    2. Rename the brief file to match the claimed t-ID.\n' >&2
	printf '    3. Bypass (with audit trail): BRIEF_FILENAME_GUARD_DISABLE=1 git commit ...\n' >&2
	printf '    4. Bypass (no audit trail):   git commit --no-verify\n' >&2
	printf '\n' >&2
done

exit "$exit_code"
