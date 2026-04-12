#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# main-branch-guard-post-checkout.sh — canonical repo stays on main (t1994)
#
# When a branch-level checkout/switch happens in the CANONICAL worktree
# (the one whose `.git` is the common git directory), refuse to leave
# main/master. Automatically restore main and print a loud error pointing
# at the worktree-helper.
#
# Linked worktrees are unaffected — they need branch changes to function.
#
# Install path: .git/hooks/post-checkout (managed by install-main-branch-guard.sh)
# Opt out:      AIDEVOPS_MAIN_BRANCH_GUARD=false
#
# Git post-checkout args: $1=prev_head  $2=new_head  $3=branch_flag
# branch_flag: 1 = branch checkout, 0 = file checkout. We only act on 1.

set -u

prev_head="${1:-}"
new_head="${2:-}"
branch_flag="${3:-0}"

# Opt-out env var
if [[ "${AIDEVOPS_MAIN_BRANCH_GUARD:-true}" == "false" ]]; then
	exit 0
fi

# Only act on branch checkouts (flag=1). File checkouts get flag=0 and must
# not trigger the restore. Note: `git checkout -b <new>` creates a branch
# pointer at the current commit, so prev_head == new_head but the branch
# name has still changed — we must not early-exit on that equality.
[[ "$branch_flag" != "1" ]] && exit 0

# Unused positional parameters — silence shellcheck without removing them
# from the API surface (git passes them unconditionally).
: "${prev_head}" "${new_head}"

# Only act in the canonical worktree (git-dir == git-common-dir)
git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
git_common=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
[[ -z "$git_dir" || -z "$git_common" ]] && exit 0

# Normalize to absolute paths — `git rev-parse --git-dir` returns `.git` when
# run from the canonical worktree, while `--git-common-dir` may be absolute.
# Resolve both to absolute form before comparing, or equality breaks.
abs_git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P || echo "$git_dir")
abs_git_common=$(cd "$git_common" 2>/dev/null && pwd -P || echo "$git_common")

[[ "$abs_git_dir" != "$abs_git_common" ]] && exit 0

# What branch are we on? (symbolic-ref is empty if detached HEAD)
current=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
[[ -z "$current" ]] && exit 0

# Is it main/master? Allowed.
if [[ "$current" == "main" || "$current" == "master" ]]; then
	exit 0
fi

# Drifted off main in the canonical worktree — restore.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
repo_name=$(basename "$repo_root")
worktree_slug="${current//\//-}"

# ANSI colors only if stderr is a TTY
if [[ -t 2 ]]; then
	red=$'\033[1;31m'
	yellow=$'\033[1;33m'
	cyan=$'\033[1;36m'
	bold=$'\033[1m'
	reset=$'\033[0m'
else
	red="" yellow="" cyan="" bold="" reset=""
fi

{
	printf '\n'
	printf '%s%s┌──────────────────────────────────────────────────────────────────────┐%s\n' "$red" "$bold" "$reset"
	printf '%s%s│  BLOCKED: canonical repo must stay on main                           │%s\n' "$red" "$bold" "$reset"
	printf '%s%s└──────────────────────────────────────────────────────────────────────┘%s\n' "$red" "$bold" "$reset"
	printf '\n'
	printf '  You switched to branch: %s%s%s\n' "$yellow" "$current" "$reset"
	printf '  Path:                   %s%s%s (canonical worktree)\n' "$yellow" "$repo_root" "$reset"
	printf '\n'
	printf '  The canonical worktree of a multi-worktree repo stays on main.\n'
	printf '  Branches belong in linked worktrees, not the canonical path.\n'
	printf '\n'
	printf '  %sAuto-restoring main.%s To work on %s%s%s, run:\n' "$cyan" "$reset" "$bold" "$current" "$reset"
	printf '\n'
	printf '      %swt add %s%s\n' "$cyan" "$current" "$reset"
	printf '      %scd ~/Git/%s-%s%s\n' "$cyan" "$repo_name" "$worktree_slug" "$reset"
	printf '\n'
} >&2

# Restore main. This will trigger post-checkout again, but current will be
# main/master next time so it exits early at the allowlist check.
if ! git -c advice.detachedHead=false checkout main 2>/dev/null; then
	if ! git -c advice.detachedHead=false checkout master 2>/dev/null; then
		printf '%s  FAILED to auto-restore main — run: git checkout main%s\n' "$red" "$reset" >&2
	fi
fi

exit 0
