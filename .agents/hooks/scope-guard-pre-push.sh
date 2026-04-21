#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# scope-guard-pre-push.sh — git pre-push hook (t2445).
#
# Blocks a push if the diff contains files outside the brief's declared
# ## Files Scope (or ### Files Scope) section. Prevents silent rebase-introduced scope creep
# (root cause of GH#19808 / t2264).
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
#   SCOPE_GUARD_DISABLE=1  — bypass for this invocation (same as --no-verify)
#   SCOPE_GUARD_DEBUG=1    — verbose stderr trace
#
# Fail-open cases (exit 0 with warning):
#   - branch name does not encode a task ID
#   - brief file not found for this task
#
# Fail-closed cases (exit 1 with error):
#   - brief exists but has no ## Files Scope or ### Files Scope section (configuration error)
#   - brief has a Files Scope section but it is empty (no patterns declared)

set -u

GUARD_NAME="scope-guard"

_log() {
	local _level="$1"
	local _msg="$2"
	printf '[%s][%s] %s\n' "$GUARD_NAME" "$_level" "$_msg" >&2
	return 0
}

# Debug-only log — no-op unless SCOPE_GUARD_DEBUG=1.
# Centralises the debug flag check to avoid repeating the inline pattern.
_dbg() {
	local _msg="$1"
	[[ "${SCOPE_GUARD_DEBUG:-0}" == "1" ]] || return 0
	_log INFO "$_msg"
	return 0
}

if [[ "${SCOPE_GUARD_DISABLE:-0}" == "1" ]]; then
	_log INFO "SCOPE_GUARD_DISABLE=1 — bypassing"
	exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the repository root so we can find brief files regardless of where
# the hook is installed (symlink in .git/hooks or copied in place).
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
# Extract the task ID from the current branch name.
# Recognised patterns:
#   feature/t2445-some-description  → t2445
#   bugfix/t2445-some-description   → t2445
#   t2445-some-description          → t2445
#   (any branch component matching tNNNN)
# ---------------------------------------------------------------------------
_extract_task_id() {
	local _branch
	_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
	if [[ -z "$_branch" ]]; then
		return 1
	fi
	# Strip any type prefix (feature/, bugfix/, hotfix/, etc.)
	local _stripped="${_branch##*/}"
	# Match tNNNN at the start of the branch (after optional prefix)
	if [[ "$_stripped" =~ ^(t[0-9]+)(-|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	# Also try the full branch name in case there is no slash
	if [[ "$_branch" =~ (^|/)(t[0-9]+)(-|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

TASK_ID=""
if ! TASK_ID=$(_extract_task_id) || [[ -z "$TASK_ID" ]]; then
	_dbg "branch has no task ID — fail-open"
	exit 0
fi

_dbg "task ID: $TASK_ID"

# ---------------------------------------------------------------------------
# Locate the brief file.  Prefer the repo-local brief; fall back to a brief
# in the deployed agent workspace (rare, but present for some tasks).
# ---------------------------------------------------------------------------
BRIEF_FILE="${REPO_ROOT}/todo/tasks/${TASK_ID}-brief.md"

if [[ ! -f "$BRIEF_FILE" ]]; then
	_log WARN "brief not found: $BRIEF_FILE — fail-open"
	exit 0
fi

_dbg "brief: $BRIEF_FILE"

# ---------------------------------------------------------------------------
# Parse the Files Scope section from the brief.
# Reads every line between the first occurrence of "## Files Scope" or
# "### Files Scope" and the next level-2 heading ("## "), then filters
# for "- " prefixed lines.
# Strips the leading "- " and any surrounding backticks to get raw patterns.
# ---------------------------------------------------------------------------
_parse_files_scope() {
	local _brief="$1"
	local _in_section=0
	local _found_section=0
	local _line

	while IFS= read -r _line; do
		if [[ "$_line" =~ ^##[#]?[[:space:]]+Files[[:space:]]+Scope ]]; then
			_in_section=1
			_found_section=1
			continue
		fi
		# Next level-2 heading ends the section
		if [[ "$_in_section" -eq 1 && "$_line" =~ ^##[[:space:]] ]]; then
			_in_section=0
			continue
		fi
		if [[ "$_in_section" -eq 1 && "$_line" =~ ^-[[:space:]]+ ]]; then
			# Strip the "- " prefix
			local _pattern="${_line#- }"
			# Strip surrounding whitespace
			_pattern="${_pattern#"${_pattern%%[![:space:]]*}"}"
			_pattern="${_pattern%"${_pattern##*[![:space:]]}"}"
			# Strip surrounding backticks (e.g. `path/to/file`)
			_pattern="${_pattern#\`}"
			_pattern="${_pattern%\`}"
			# Skip empty or comment-like lines
			[[ -z "$_pattern" || "$_pattern" == "{path/to/file-or-glob}" ]] && continue
			printf '%s\n' "$_pattern"
		fi
	done < "$_brief"

	# Return non-zero if section not found, so caller can fail-closed
	[[ "$_found_section" -eq 1 ]]
	return $?
}

# Collect scope patterns into an array (Bash 3.2-compatible; no mapfile)
_raw_scope=$(_parse_files_scope "$BRIEF_FILE")
parse_rc=$?
SCOPE_PATTERNS=()
if [[ $parse_rc -eq 0 ]] && [[ -n "$_raw_scope" ]]; then
	while IFS= read -r _line; do
		SCOPE_PATTERNS+=("$_line")
	done <<< "$_raw_scope"
fi

if ! grep -qE "^##[#]? Files Scope" "$BRIEF_FILE" 2>/dev/null; then
	_log ERROR "brief exists but has no 'Files Scope' section — fail-closed"
	_log ERROR "  add a '## Files Scope' or '### Files Scope' section to $BRIEF_FILE listing the files this task may modify"
	_log ERROR "  or bypass with: SCOPE_GUARD_DISABLE=1 git push ..."
	exit 1
fi

if [[ "${#SCOPE_PATTERNS[@]}" -eq 0 ]]; then
	_log ERROR "'Files Scope' section exists but has no entries — fail-closed"
	_log ERROR "  add file paths (one per '- ' line) to the 'Files Scope' section of $BRIEF_FILE"
	_log ERROR "  or bypass with: SCOPE_GUARD_DISABLE=1 git push ..."
	exit 1
fi

if [[ "${SCOPE_GUARD_DEBUG:-0}" == "1" ]]; then
	_dbg "scope patterns (${#SCOPE_PATTERNS[@]}):"
	for _p in "${SCOPE_PATTERNS[@]}"; do
		_dbg "  pattern: $_p"
	done
fi

# ---------------------------------------------------------------------------
# Check whether a given file path matches any declared scope pattern.
# Uses bash glob expansion semantics ([[ $file == $pattern ]]).
# ---------------------------------------------------------------------------
_file_in_scope() {
	local _file="$1"
	local _pattern
	for _pattern in "${SCOPE_PATTERNS[@]}"; do
		# Intentional glob matching — patterns from Files Scope section may be globs (e.g. .agents/hooks/*.sh)
		# shellcheck disable=SC2053
		if [[ "$_file" == $_pattern ]]; then
			return 0
		fi
		# Also allow matching by basename for simple file names (no slash in pattern)
		if [[ "$_pattern" != */* && "$(basename "$_file")" == "$_pattern" ]]; then
			return 0
		fi
	done
	return 1
}

# ---------------------------------------------------------------------------
# Determine the merge-base for computing the push diff.
# Mirrors the approach in complexity-regression-pre-push.sh (GH#20045).
# ---------------------------------------------------------------------------
_compute_baseline() {
	local _remote
	_remote="${1:-origin}"
	local default_remote_head
	local baseline
	default_remote_head=$(git symbolic-ref "refs/remotes/$_remote/HEAD" 2>/dev/null \
		| sed "s@^refs/remotes/$_remote/@@")
	if [[ -z "$default_remote_head" ]]; then
		local candidate
		for candidate in "$_remote/main" "$_remote/master" "HEAD"; do
			if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
				default_remote_head="$candidate"
				break
			fi
		done
	fi
	if [[ -z "$default_remote_head" ]]; then
		printf '[%s] warning: no %s HEAD resolved; falling back to @{u}\n' \
			"$GUARD_NAME" "$_remote" >&2
		git merge-base HEAD '@{u}'
		return $?
	fi
	baseline=$(git merge-base HEAD "$default_remote_head" 2>/dev/null)
	local rc
	rc=$?
	if [[ $rc -ne 0 ]] || [[ -z "$baseline" ]]; then
		baseline="$default_remote_head"
	fi
	printf '%s\n' "$baseline"
	return $rc
}

# ---------------------------------------------------------------------------
# Walk each ref being pushed via stdin.
# ---------------------------------------------------------------------------
remote_name="${1:-}"

exit_code=0
out_of_scope_found=0

while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
	[[ -z "$local_sha" ]] && continue
	# Branch deletion (all-zero sha) — nothing to scan
	if [[ "$local_sha" =~ ^0+$ ]]; then
		continue
	fi

	# Determine the base for diffing: use remote sha when known, else merge-base
	base_sha=""
	if [[ -n "$remote_sha" ]] && ! [[ "$remote_sha" =~ ^0+$ ]]; then
		base_sha="$remote_sha"
	else
		base_sha=$(_compute_baseline "$remote_name")
	fi

	if [[ -z "$base_sha" ]]; then
		_log WARN "cannot determine base SHA for $local_ref — fail-open"
		continue
	fi

	_dbg "checking $local_ref: base=${base_sha:0:7} head=${local_sha:0:7}"

	# Get the list of changed files in this push (Bash 3.2-compatible; no mapfile)
	_raw_changed=$(git diff --name-only "$base_sha" "$local_sha" 2>/dev/null)
	changed_files=()
	if [[ -n "$_raw_changed" ]]; then
		while IFS= read -r _f; do
			changed_files+=("$_f")
		done <<< "$_raw_changed"
	fi

	if [[ "${#changed_files[@]}" -eq 0 ]]; then
		_dbg "no changed files for $local_ref"
		continue
	fi

	# Check each changed file against the scope
	out_of_scope=()
	for changed_file in "${changed_files[@]}"; do
		[[ -z "$changed_file" ]] && continue
		if ! _file_in_scope "$changed_file"; then
			out_of_scope+=("$changed_file")
		else
			_dbg "  in-scope: $changed_file"
		fi
	done

	if [[ "${#out_of_scope[@]}" -gt 0 ]]; then
		out_of_scope_found=1
		printf '\n[%s][BLOCK] Push to %s modifies files outside the declared scope for %s:\n\n' \
			"$GUARD_NAME" "${remote_name:-remote}" "$TASK_ID" >&2
		for _f in "${out_of_scope[@]}"; do
			printf '  %s\n' "$_f" >&2
		done
		printf '\n' >&2
		printf '  Declared scope (%s):\n' "$BRIEF_FILE" >&2
		for _p in "${SCOPE_PATTERNS[@]}"; do
			printf '    - %s\n' "$_p" >&2
		done
		printf '\n' >&2
		printf '  Remediation options:\n' >&2
		printf '    1. Revert the out-of-scope changes (they may be stale rebase artefacts).\n' >&2
		printf '    2. Add the file path to the Files Scope section of %s.\n' "$BRIEF_FILE" >&2
		printf '    3. Bypass (document the reason): SCOPE_GUARD_DISABLE=1 git push ...\n' >&2
		printf '    4. Bypass (no audit trail):      git push --no-verify\n' >&2
		printf '\n' >&2
		exit_code=1
	fi
done

if [[ "$out_of_scope_found" -eq 0 ]]; then
	_dbg "all changed files are in-scope — allowing push"
fi

exit "$exit_code"
