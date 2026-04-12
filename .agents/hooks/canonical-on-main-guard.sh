#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# canonical-on-main-guard.sh — git post-checkout hook.
#
# Warns when the canonical repo directory is switched off main/master in an
# interactive session. Complements t1990's edit-time check in pre-edit-check.sh
# by catching the branch switch itself, not just the first edit that follows.
#
# Install: see .agents/scripts/install-canonical-guard.sh
#
# Git post-checkout protocol:
#   $1 = previous HEAD ref
#   $2 = new HEAD ref
#   $3 = flag (1 = branch checkout, 0 = file checkout)
#
# Environment:
#   AIDEVOPS_CANONICAL_GUARD=strict   — block the checkout (exit 1)
#   AIDEVOPS_CANONICAL_GUARD=bypass   — suppress the warning entirely
#   AIDEVOPS_CANONICAL_GUARD=warn     — default: warn loudly but don't block
#
# Fail-open cases (exit 0, no warning):
#   - Headless session (FULL_LOOP_HEADLESS / AIDEVOPS_HEADLESS / OPENCODE_HEADLESS / GITHUB_ACTIONS set)
#   - File-level checkout ($3 != 1)
#   - Current working copy is a linked worktree (not canonical)
#   - Current branch is main or master (not a violation)
#   - Detached HEAD
#   - repos.json missing or working copy not in initialized_repos[]

set -u

# Only fire on full branch checkouts
[[ "${3:-0}" == "1" ]] || exit 0

# Explicit bypass
if [[ "${AIDEVOPS_CANONICAL_GUARD:-warn}" == "bypass" ]]; then
	exit 0
fi

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

# If new branch IS main/master, nothing to warn about
case "$current_branch" in
main | master)
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
	printf 'branch %s%s%s, which is NOT main/master.\n' "$YELLOW" "$current_branch" "$NC"
	printf '\n'
	printf 'aidevops convention (t1990): canonical directories stay on main.\n'
	printf 'Worktrees are used for all non-main work.\n'
	printf '\n'
	printf 'To recover:\n'
	printf '  git checkout main\n'
	printf '  wt add <type>/%s        # if you want to keep the branch\n' "$current_branch"
	printf '\n'
	printf 'To bypass this warning entirely:\n'
	printf '  AIDEVOPS_CANONICAL_GUARD=bypass git checkout <branch>\n'
	printf '\n'
	printf 'To enforce strict mode (fail the checkout):\n'
	printf '  AIDEVOPS_CANONICAL_GUARD=strict git checkout <branch>\n'
	printf '\n'
	printf '%s============================================================%s\n' "$RED" "$NC"
	printf '\n'
} >&2

# Strict mode: fail the checkout
if [[ "${AIDEVOPS_CANONICAL_GUARD:-warn}" == "strict" ]]; then
	exit 1
fi

# Default: warn-only, don't block
exit 0
