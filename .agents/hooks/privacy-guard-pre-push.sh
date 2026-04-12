#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# privacy-guard-pre-push.sh — git pre-push hook.
#
# Blocks a push to a public GitHub repo if the push diff introduces any
# private repo slug (from ~/.config/aidevops/repos.json) into TODO.md,
# todo/**, README.md, or .github/ISSUE_TEMPLATE/** content.
#
# Install: see .agents/scripts/install-privacy-guard.sh
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
#   PRIVACY_GUARD_DISABLE=1  — bypass for this invocation (equivalent to --no-verify)
#   PRIVACY_GUARD_DEBUG=1    — verbose stderr trace
#
# Fail-open cases (exit 0 with warning):
#   - gh CLI unavailable or unauthenticated
#   - remote URL not parseable as github.com
#   - repos.json missing or malformed

set -u

if [[ "${PRIVACY_GUARD_DISABLE:-0}" == "1" ]]; then
	printf '[privacy-guard][INFO] PRIVACY_GUARD_DISABLE=1 — bypassing\n' >&2
	exit 0
fi

# Locate the helper library. Resolve relative to the hook's real path so it
# works whether installed as a symlink in .git/hooks or copied in place.
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
HELPER_REPO="${HOOK_DIR}/../scripts/privacy-guard-helper.sh"
HELPER_DEPLOYED="${HOME}/.aidevops/agents/scripts/privacy-guard-helper.sh"

if [[ -f "$HELPER_REPO" ]]; then
	# shellcheck source=/dev/null
	source "$HELPER_REPO"
elif [[ -f "$HELPER_DEPLOYED" ]]; then
	# shellcheck source=/dev/null
	source "$HELPER_DEPLOYED"
else
	printf '[privacy-guard][WARN] helper library not found — fail-open\n' >&2
	exit 0
fi

remote_name="${1:-}"
remote_url="${2:-}"

if [[ -z "$remote_url" ]]; then
	privacy_log WARN "pre-push called with no remote URL — fail-open"
	exit 0
fi

# Fast path: target is private → nothing to guard
if ! privacy_is_target_public "$remote_url"; then
	# exit 1 = private, exit 2 = unknown — both allow the push
	[[ "${PRIVACY_GUARD_DEBUG:-0}" == "1" ]] && privacy_log INFO "target private or unknown ($remote_url) — allowing push"
	exit 0
fi

[[ "${PRIVACY_GUARD_DEBUG:-0}" == "1" ]] && privacy_log INFO "target public ($remote_url) — scanning diff"

# Enumerate private slugs once for the whole push
slugs_file=$(mktemp 2>/dev/null) || {
	privacy_log WARN "mktemp failed — fail-open"
	exit 0
}
trap 'rm -f "$slugs_file"' EXIT

if ! privacy_enumerate_private_slugs "$slugs_file"; then
	privacy_log WARN "could not enumerate private slugs — fail-open"
	exit 0
fi

if [[ ! -s "$slugs_file" ]]; then
	[[ "${PRIVACY_GUARD_DEBUG:-0}" == "1" ]] && privacy_log INFO "no private slugs to guard against"
	exit 0
fi

# Walk each ref in the push
exit_code=0
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
	[[ -z "$local_sha" ]] && continue
	# Branch deletion (local_sha is zeros) — nothing to scan
	if [[ "$local_sha" =~ ^0+$ ]]; then
		continue
	fi

	hits_output=$(privacy_scan_diff "$remote_sha" "$local_sha" "$slugs_file")
	scan_rc=$?
	if [[ "$scan_rc" -ne 0 ]]; then
		printf '\n[privacy-guard][BLOCK] Push to %s contains private repo slugs in planning/docs content:\n\n' "$remote_name" >&2
		printf '%s\n\n' "$hits_output" >&2
		printf '  Remove the private slug from the committed content and amend/rewrite the commit before pushing.\n' >&2
		printf '  To bypass (audit trail preserves the override): PRIVACY_GUARD_DISABLE=1 git push ... or git push --no-verify\n' >&2
		printf '  Private slug sources scanned: repos.json initialized_repos[] with mirror_upstream or local_only, plus ~/.aidevops/configs/privacy-guard-extra-slugs.txt\n\n' >&2
		exit_code=1
	fi
done

exit "$exit_code"
