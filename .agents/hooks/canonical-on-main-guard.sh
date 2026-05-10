#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# canonical-on-main-guard.sh — git post-checkout hook.
#
# Repairs the canonical repo directory back to the default branch when it is
# switched off default in an interactive session. Complements t1990's edit-time
# check in pre-edit-check.sh by catching the branch switch itself, not just the
# first edit that follows.
#
# Install: see .agents/scripts/install-canonical-guard.sh
#
# Git post-checkout protocol:
#   $1 = previous HEAD ref
#   $2 = new HEAD ref
#   $3 = flag (1 = branch checkout, 0 = file checkout)
#
# Environment:
#   AIDEVOPS_CANONICAL_GUARD=repair   — default: restore the default branch
#   AIDEVOPS_CANONICAL_GUARD=strict   — restore the default branch and exit 1
#   AIDEVOPS_CANONICAL_GUARD=bypass   — suppress the warning entirely
#   AIDEVOPS_CANONICAL_GUARD=warn     — warn loudly but do not restore
#
# Fail-open cases (exit 0, no warning):
#   - Headless session (FULL_LOOP_HEADLESS / AIDEVOPS_HEADLESS / OPENCODE_HEADLESS / GITHUB_ACTIONS set)
#   - File-level checkout ($3 != 1)
#   - Current working copy is a linked worktree (not canonical)
#   - Current branch is the detected default branch (not a violation)
#   - Detached HEAD
#   - repos.json missing or working copy not in initialized_repos[]

set -u

# Only fire on full branch checkouts
[[ "${3:-0}" == "1" ]] || exit 0

# Explicit bypass
if [[ "${AIDEVOPS_CANONICAL_GUARD:-repair}" == "bypass" ]]; then
	exit 0
fi

detect_default_branch() {
	local default_branch=""
	default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || default_branch=""
	default_branch="${default_branch#origin/}"
	if [[ -z "$default_branch" ]] && git show-ref --verify --quiet refs/heads/main; then
		default_branch="main"
	fi
	if [[ -z "$default_branch" ]] && git show-ref --verify --quiet refs/heads/master; then
		default_branch="master"
	fi
	if [[ -z "$default_branch" ]]; then
		default_branch="HEAD"
	fi
	printf '%s' "$default_branch"
	return 0
}

restore_default_branch() {
	local default_branch="$1"
	local status_output=""
	status_output=$(git status --porcelain -uno 2>/dev/null) || status_output=""
	if [[ -n "$status_output" ]]; then
		printf 'Refusing automatic restore because the working tree is not clean.\n' >&2
		printf 'Run: git status --short, then manually restore the canonical repo to %s.\n' "$default_branch" >&2
		return 1
	fi
	AIDEVOPS_CANONICAL_GUARD=bypass git checkout "$default_branch" --quiet 2>/dev/null
	return $?
}

# Headless session: skip the check — workers know what they're doing
if [[ "${FULL_LOOP_HEADLESS:-}" == "true" ]] ||
	[[ "${AIDEVOPS_HEADLESS:-}" == "true" ]] ||
	[[ "${OPENCODE_HEADLESS:-}" == "true" ]] ||
	[[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
	exit 0
fi

# Determine current branch
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
[[ -z "$current_branch" ]] && exit 0 # detached HEAD — not our concern

# If new branch IS the default branch, nothing to warn about
default_branch=$(detect_default_branch)
case "$current_branch" in
"$default_branch")
	exit 0
	;;
esac

# Canonical detection: git-dir == git-common-dir means we're in the main
# working copy, not a linked worktree. Worktrees are expected to be on
# non-main branches, so we don't warn there.
git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
if [[ -z "$git_dir" ]] || [[ -z "$git_common_dir" ]]; then
	exit 0 # not in a git repo — fail open
fi
# Resolve both to absolute paths to avoid false positives when one is
# relative and the other is not.
git_dir_abs=$(cd "$git_dir" 2>/dev/null && pwd) || git_dir_abs=""
git_common_abs=$(cd "$git_common_dir" 2>/dev/null && pwd) || git_common_abs=""
if [[ -z "$git_dir_abs" ]] || [[ -z "$git_common_abs" ]]; then
	exit 0 # resolution failed — fail open
fi
if [[ "$git_dir_abs" != "$git_common_abs" ]]; then
	# This is a worktree, not the canonical — no warning.
	exit 0
fi

# Cross-check against repos.json: only guard repos we explicitly manage.
# Normalise repo_root to its physical path via `cd && pwd -P` so we can
# compare against repos.json entries regardless of whether they were stored
# as logical or physical paths. On macOS /tmp is a symlink to /private/tmp,
# and `git rev-parse --show-toplevel` returns the physical form while
# `pwd` in a script may return the logical form — both must compare equal.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[[ -z "$repo_root" ]] && exit 0
repo_root_phys=$(cd "$repo_root" 2>/dev/null && pwd -P) || repo_root_phys="$repo_root"

repos_config="${HOME}/.config/aidevops/repos.json"
if [[ ! -f "$repos_config" ]]; then
	exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
	exit 0 # no jq — fail open
fi
# Match against BOTH logical and physical forms of the current repo root,
# and also against the physical form of each repos.json path. This covers
# every plausible symlink arrangement without requiring the user to know
# which form they registered.
known_canonical=$(jq -r --arg root "$repo_root" --arg root_phys "$repo_root_phys" \
	'.initialized_repos[]? | select(.path == $root or .path == $root_phys) | .path' \
	"$repos_config" 2>/dev/null)
if [[ -z "$known_canonical" ]]; then
	# Secondary check: resolve each initialized_repos path to its physical
	# form and compare. Slower but handles the "repos.json has /tmp, git has
	# /private/tmp" case symmetrically.
	while IFS= read -r registered_path; do
		[[ -z "$registered_path" ]] && continue
		registered_phys=$(cd "$registered_path" 2>/dev/null && pwd -P) || continue
		if [[ "$registered_phys" == "$repo_root_phys" ]]; then
			known_canonical="$registered_path"
			break
		fi
	done < <(jq -r '.initialized_repos[]? | .path // empty' "$repos_config" 2>/dev/null)
fi
[[ -z "$known_canonical" ]] && exit 0

# All conditions met: interactive + canonical + non-main branch.
# Warn loudly to stderr.
if [[ -t 2 ]]; then
	RED=$'\033[0;31m'
	YELLOW=$'\033[1;33m'
	NC=$'\033[0m'
else
	RED="" YELLOW="" NC=""
fi

{
	printf '\n'
	printf '%s============================================================%s\n' "$RED" "$NC"
	printf '%s[canonical-on-main-guard] WARNING (t1995)%s\n' "$RED" "$NC"
	printf '%s============================================================%s\n' "$RED" "$NC"
	printf '\n'
	printf 'The canonical repo directory %s%s%s has been switched to\n' \
		"$YELLOW" "$repo_root" "$NC"
	printf 'branch %s%s%s, which is NOT the default branch (%s%s%s).\n' \
		"$YELLOW" "$current_branch" "$NC" "$YELLOW" "$default_branch" "$NC"
	printf '\n'
	printf 'aidevops convention (t1990): canonical directories stay on main.\n'
	printf 'Worktrees are used for all non-main work.\n'
	printf '\n'
	printf 'To recover manually:\n'
	printf '  git checkout %s\n' "$default_branch"
	printf '  wt add <type>/%s        # if you want to keep the branch\n' "$current_branch"
	printf '\n'
	printf 'To bypass this warning entirely:\n'
	printf '  AIDEVOPS_CANONICAL_GUARD=bypass git checkout <branch>\n'
	printf '\n'
	printf 'To warn without restoring:\n'
	printf '  AIDEVOPS_CANONICAL_GUARD=warn git checkout <branch>\n'
	printf '\n'
	printf 'To enforce strict mode (restore, then fail the checkout):\n'
	printf '  AIDEVOPS_CANONICAL_GUARD=strict git checkout <branch>\n'
	printf '\n'
	printf '%s============================================================%s\n' "$RED" "$NC"
	printf '\n'
} >&2

case "${AIDEVOPS_CANONICAL_GUARD:-repair}" in
warn)
	exit 0
	;;
strict)
	restore_default_branch "$default_branch" || true
	exit 1
	;;
repair | *)
	if restore_default_branch "$default_branch"; then
		printf '[canonical-on-main-guard] Restored canonical repo to %s. Use a linked worktree for branch work.\n' "$default_branch" >&2
	else
		exit 1
	fi
	;;
esac

exit 0
