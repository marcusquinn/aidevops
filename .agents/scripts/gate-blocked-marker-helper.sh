#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# gate-blocked-marker-helper.sh - durable per-worktree "maintainer gate blocked" marker (GH#40288).
#
# When the linked-issue maintainer gate refuses a start, the worktree it leaves
# behind must not become writable. The marker lives in the worktree's private
# git dir, so it is per worktree, never tracked, and survives session restarts.
#
# Usage:
#   gate-blocked-marker-helper.sh set <issue> <repo> [reason]
#   gate-blocked-marker-helper.sh clear
#   gate-blocked-marker-helper.sh check [workdir]
#     check exit: 0 = no marker or released, 1 = blocked (message on stdout)
#
# Release: only a VERIFIED signed approval (approval-helper.sh verify) clears the
# marker automatically during `check`; `clear` is for the gate re-run passing.

set -euo pipefail

_GBM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
_GBM_FILE_NAME="aidevops-gate-blocked"

_gbm_marker_path() {
	local workdir="${1:-.}"
	local git_dir=""
	git_dir=$(git -C "$workdir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	printf '%s/%s\n' "$git_dir" "$_GBM_FILE_NAME"
	return 0
}

_gbm_set() {
	local issue="${1:-}"
	local repo="${2:-}"
	local reason="${3:-maintainer gate blocked}"
	local marker=""
	[[ "$issue" =~ ^[0-9]+$ && -n "$repo" ]] || {
		echo "usage: set <issue> <repo> [reason]" >&2
		return 2
	}
	marker=$(_gbm_marker_path .) || return 1
	# Never mark a canonical checkout (its git dir is the common dir).
	local git_dir="" common_dir=""
	git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
	common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	[[ "$git_dir" != "$common_dir" ]] || return 0
	printf 'issue=%s\nrepo=%s\nreason=%s\n' "$issue" "$repo" "${reason//$'\n'/ }" >"$marker"
	return 0
}

_gbm_clear() {
	local marker=""
	marker=$(_gbm_marker_path .) || return 0
	rm -f "$marker"
	return 0
}

_gbm_check() {
	local workdir="${1:-.}"
	local marker="" issue="" repo="" reason="" verification=""
	marker=$(_gbm_marker_path "$workdir") || return 0
	[[ -f "$marker" ]] || return 0
	local key="" value=""
	while IFS='=' read -r key value; do
		case "$key" in
		issue) issue="$value" ;;
		repo) repo="$value" ;;
		reason) reason="$value" ;;
		esac
	done <"$marker"

	#aidevops:trust-boundary -- only a signed approval releases the marker.
	local approval_helper="${_GBM_SCRIPT_DIR}/approval-helper.sh"
	if [[ "$issue" =~ ^[0-9]+$ && -n "$repo" && -x "$approval_helper" ]]; then
		verification=$("$approval_helper" verify "$issue" "$repo" 2>/dev/null || true)
		if [[ "$verification" == "VERIFIED" ]]; then
			rm -f "$marker"
			return 0
		fi
	fi

	echo "BLOCKED: this worktree is gate-blocked for issue #${issue:-?} (${repo:-unknown repo}): ${reason:-maintainer gate blocked}"
	echo "GATE_BLOCKED_WORKTREE=true"
	echo "HINT: edits and commits stay refused until 'approval-helper.sh verify ${issue:-<N>} ${repo:-<repo>}' returns VERIFIED, or a re-run of the start passes the author check"
	return 1
}

main() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	set) _gbm_set "$@" ;;
	clear) _gbm_clear ;;
	check) _gbm_check "$@" ;;
	*)
		echo "usage: gate-blocked-marker-helper.sh {set|clear|check}" >&2
		return 2
		;;
	esac
	return $?
}

main "$@"
