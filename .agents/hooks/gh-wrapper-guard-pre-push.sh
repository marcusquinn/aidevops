#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# gh-wrapper-guard-pre-push.sh — git pre-push hook
#
# Blocks a push if the commit range introduces raw `gh issue create` or
# `gh pr create` calls in .agents/scripts/ or .agents/hooks/ .sh files.
# These must use gh_create_issue / gh_create_pr wrappers.
#
# Install: install-hooks-helper.sh (adds to git pre-push hook chain)
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
#   GH_WRAPPER_GUARD_DISABLE=1 — bypass for this invocation
#   GH_WRAPPER_GUARD_DEBUG=1   — verbose stderr trace

set -euo pipefail

if [[ "${GH_WRAPPER_GUARD_DISABLE:-0}" == "1" ]]; then
	printf '[gh-wrapper-guard][INFO] GH_WRAPPER_GUARD_DISABLE=1 — bypassing\n' >&2
	exit 0
fi

# Locate the checker script
_resolve_self() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L "$src" ]]; do
		local dir
		dir=$(cd -P "$(dirname "$src")" && pwd)
		src=$(readlink "$src")
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd -P "$(dirname "$src")" && pwd
}

HOOK_DIR=$(_resolve_self)
GUARD_REPO="${HOOK_DIR}/../scripts/gh-wrapper-guard.sh"
GUARD_DEPLOYED="${HOME}/.aidevops/agents/scripts/gh-wrapper-guard.sh"

GUARD=""
if [[ -f "$GUARD_REPO" ]]; then
	GUARD="$GUARD_REPO"
elif [[ -f "$GUARD_DEPLOYED" ]]; then
	GUARD="$GUARD_DEPLOYED"
else
	printf '[gh-wrapper-guard][WARN] guard script not found — fail-open\n' >&2
	exit 0
fi

[[ "${GH_WRAPPER_GUARD_DEBUG:-0}" == "1" ]] && printf '[gh-wrapper-guard][INFO] using guard: %s\n' "$GUARD" >&2

# Walk each ref in the push
exit_code=0
while IFS=' ' read -r _local_ref local_sha _remote_ref remote_sha; do
	[[ -z "$local_sha" ]] && continue
	# Branch deletion (all zeros)
	if [[ "$local_sha" =~ ^0+$ ]]; then
		continue
	fi

	# For new branches, use the merge-base with main/master as the base
	base_ref="$remote_sha"
	if [[ "$remote_sha" =~ ^0+$ ]]; then
		# New branch — find a reasonable base
		base_ref=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "")
		if [[ -z "$base_ref" ]]; then
			[[ "${GH_WRAPPER_GUARD_DEBUG:-0}" == "1" ]] && printf '[gh-wrapper-guard][INFO] cannot determine base for new branch — skipping\n' >&2
			continue
		fi
	fi

	[[ "${GH_WRAPPER_GUARD_DEBUG:-0}" == "1" ]] && printf '[gh-wrapper-guard][INFO] scanning %s..%s\n' "$base_ref" "$local_sha" >&2

	if ! bash "$GUARD" check --base "$base_ref" 2>&1; then
		printf '\n[gh-wrapper-guard][BLOCK] Push contains raw gh issue/pr create calls.\n' >&2
		printf '  Use gh_create_issue / gh_create_pr wrappers instead.\n' >&2
		printf '  Bypass: GH_WRAPPER_GUARD_DISABLE=1 git push ... or git push --no-verify\n\n' >&2
		exit_code=1
	fi
done

exit "$exit_code"
