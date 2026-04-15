#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# gh-wrapper-guard-pre-push.sh — git pre-push hook (t2113).
#
# Blocks a push if the commit range contains an ADDED line that calls
# `gh issue create` or `gh pr create` directly instead of the
# `gh_create_issue` / `gh_create_pr` wrappers in shared-constants.sh.
# The wrappers apply origin labels, auto-assign, and sub-issue linking —
# skipping them produces unlabelled, unassigned, unlinked GitHub state
# that the framework's dispatch-dedup and maintainer gates cannot see.
#
# Install: .agents/scripts/install-hooks-helper.sh install
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
#   GH_WRAPPER_GUARD_DISABLE=1  — bypass for this invocation
#   GH_WRAPPER_GUARD_DEBUG=1    — verbose stderr trace
#
# Fail-open cases (exit 0 with warning):
#   - guard helper script not found on disk
#   - git diff fails (detached / no common ancestor)

set -u

if [[ "${GH_WRAPPER_GUARD_DISABLE:-0}" == "1" ]]; then
	printf '[gh-wrapper-guard][INFO] GH_WRAPPER_GUARD_DISABLE=1 — bypassing\n' >&2
	exit 0
fi

_log() {
	[[ "${GH_WRAPPER_GUARD_DEBUG:-0}" == "1" ]] && printf '[gh-wrapper-guard][DEBUG] %s\n' "$*" >&2
	return 0
}

_warn() {
	printf '[gh-wrapper-guard][WARN] %s\n' "$*" >&2
}

# Resolve the hook's real directory so the guard helper can be located
# relative to the hook regardless of symlink install style.
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
# The hook lives in .agents/hooks/. The guard helper lives in
# .agents/scripts/ alongside shared-constants.sh. Derive the scripts dir
# by replacing the trailing `hooks` with `scripts`.
GUARD_HELPER="${HOOK_DIR%/hooks}/scripts/gh-wrapper-guard.sh"

if [[ ! -x "$GUARD_HELPER" ]]; then
	_warn "guard helper not found at $GUARD_HELPER — allowing push"
	exit 0
fi

# Protocol parsing: for each ref line on stdin, run the guard against the
# commit range (remote_sha..local_sha). Zero-ed SHAs mean new-branch pushes
# — use `origin/main` as the base so we scan everything the branch adds.
total_violations=0
violations_output=""
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
	[[ -z "${local_sha:-}" ]] && continue
	# Deletion push — nothing to scan
	if [[ "$local_sha" =~ ^0+$ ]]; then
		continue
	fi
	# New branch — compare against origin/main (or origin/master)
	if [[ "$remote_sha" =~ ^0+$ ]]; then
		if git rev-parse --verify origin/main >/dev/null 2>&1; then
			base="origin/main"
		elif git rev-parse --verify origin/master >/dev/null 2>&1; then
			base="origin/master"
		else
			_warn "cannot resolve base ref for new branch — allowing push"
			continue
		fi
	else
		base="$remote_sha"
	fi

	_log "scanning ${base}...${local_sha} for ref ${local_ref}"
	set +e
	out=$("$GUARD_HELPER" check --base "$base" --head "$local_sha" 2>&1)
	rc=$?
	set -e
	# Guard helper exit codes:
	#   0 — clean (no violations)
	#   1 — policy violations (block the push)
	#   2 — usage/git error (fail-open: warn and allow, matching the
	#       documented behaviour for diff/base-state failures)
	case "$rc" in
	0) : ;;
	1)
		violations_output+="${out}"$'\n'
		total_violations=$((total_violations + 1))
		;;
	2 | *)
		_warn "guard helper returned rc=${rc} (infrastructure error) — allowing push"
		_warn "${out}"
		;;
	esac
done

if [[ "$total_violations" -gt 0 ]]; then
	printf '\n[gh-wrapper-guard] BLOCKED — raw gh issue/pr create detected\n' >&2
	printf '%s\n' "$violations_output" >&2
	printf '\n' >&2
	printf 'Fix: replace with gh_create_issue / gh_create_pr (defined in shared-constants.sh).\n' >&2
	printf 'Rule: prompts/build.txt → "Origin labelling (MANDATORY)"\n' >&2
	printf 'Audited exception: append "# aidevops-allow: raw-gh-wrapper" to the line.\n' >&2
	printf 'Bypass for this push: GH_WRAPPER_GUARD_DISABLE=1 git push ... OR git push --no-verify\n' >&2
	exit 1
fi

exit 0
