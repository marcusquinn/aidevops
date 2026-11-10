#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh comment selector policy (GH#37406)
# =============================================================================
# `gh issue|pr comment --edit-last` picks the viewer's last comment from only
# the first 100 comments of the thread, so on longer threads it can overwrite
# an unrelated older comment. The REST fallback also drops unknown options and
# would post a new comment instead. Refuse implicit selectors everywhere and
# point to the exact-ID editor.
# Usage: source "${dir}/shared-gh-wrappers-comment-selector.sh"; side-effect
# free. Sourced by shared-gh-wrappers-create.sh and the gh PATH shim.

[[ -n "${_GH_COMMENT_SELECTOR_LIB_LOADED:-}" ]] && return 0
_GH_COMMENT_SELECTOR_LIB_LOADED=1

#######################################
# Returns 0 and prints guidance when comment args use an implicit selector;
# returns 1 when the args are safe to forward.
# Arguments: KIND (issue|pr), then the gh comment arguments.
#######################################
gh_comment_selector_refused() {
	local kind="$1"
	shift
	local arg="" skip_value=0
	for arg in "$@"; do
		if [[ "$skip_value" == 1 ]]; then
			skip_value=0
			continue
		fi
		case "$arg" in
		--body | -b | --body-file | -F | --repo | -R) skip_value=1 ;;
		--edit-last | --edit-last=* | --delete-last | --delete-last=* | --create-if-none | --create-if-none=*)
			printf '[aidevops][gh-comment][BLOCK] %s refused: gh picks "last" from only the first 100 comments and can overwrite an unrelated comment (GH#37406).\n' "${arg%%=*}" >&2
			printf 'Edit by exact ID: gh-write-helper.sh %s comment-edit <comment-id> --repo <owner/repo> --body-file <file> [--target <number>]\n' "$kind" >&2
			return 0
			;;
		esac
	done
	return 1
}
