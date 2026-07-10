#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Post-checkout invariant detector. Prevention belongs to the runtime command
# gate and Git PATH shim; this hook never attempts a recursive repair checkout.

set -u

[[ "${3:-0}" == "1" ]] || exit 0

git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
[[ -n "$git_dir" && -n "$common_dir" ]] || exit 1
[[ "$git_dir" == "$common_dir" ]] || exit 0

default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
default_branch="${default_branch#origin/}"
if [[ -z "$default_branch" ]]; then
	default_branch=$(git config --get init.defaultBranch 2>/dev/null || true)
fi
[[ -n "$default_branch" ]] || default_branch="main"

current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [[ "$current_branch" == "$default_branch" ]]; then
	exit 0
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
if [[ -z "$current_branch" ]]; then
	state="detached HEAD"
else
	state="branch '${current_branch}'"
fi
printf 'CRITICAL: canonical repository %s entered %s; expected branch %s. Further framework mutation is blocked. Use canonical-recovery-helper.sh after coordinating parallel sessions.\n' \
	"$repo_root" "$state" "$default_branch" >&2
exit 1
