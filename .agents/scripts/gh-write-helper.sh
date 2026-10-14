#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
trap '_run_cleanups' EXIT
trap '_run_cleanups; exit 130' HUP INT TERM

usage() {
	printf 'Usage: gh-write-helper.sh {issue|pr} create [gh create options]\n'
	printf '       gh-write-helper.sh {issue|pr} edit <number-or-url> [gh edit options]\n'
	printf '       gh-write-helper.sh {issue|pr} comment <number-or-url> [gh comment options]\n'
	printf '       gh-write-helper.sh issue review-handoff <number> --repo <owner/repo> --pr <number>\n'
	printf '       gh-write-helper.sh batch MANIFEST.json\n'
	printf 'Bodies may use --body-file - to read stdin once through the safe wrapper.\n'
	return 0
}

# Explicit, owned PR handoff; generic issue edits never acquire this provenance.
_issue_review_handoff() {
	local number="${1:-}"
	local repo="" pr="" issue_json=""
	[[ "$number" =~ ^[1-9][0-9]*$ ]] || return 2
	shift
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--repo) repo="${2:-}"; [[ $# -ge 2 ]] || return 2; shift 2 ;;
		--pr) pr="${2:-}"; [[ $# -ge 2 ]] || return 2; shift 2 ;;
		*) return 2 ;;
		esac
	done
	_gh_verify_owned_review_handoff_pr "$repo" "$number" "$pr" || return 1
	issue_json=$(gh api "repos/${repo}/issues/${number}" 2>/dev/null) || return 1
	printf '%s\n' "$issue_json" | jq -e '
		.state == "open" and .pull_request == null
		and ([.labels[]?.name] | index("status:in-progress") != null)
		and ([.labels[]?.name] | index("status:in-review") == null)
	' >/dev/null || return 1
	# Dynamically scoped PR identifier is only a hint; the audit rechecks GitHub.
	local _GH_REVIEW_HANDOFF_PR="$pr"
	gh_issue_edit_safe "$number" --repo "$repo" \
		--remove-label status:in-progress --add-label status:in-review || return 1
	return 0
}

main() {
	local resource="${1:-}"
	local action="${2:-}"
	# Dynamically scoped for shared validation diagnostics, not exported to children.
	local _GH_WRITE_OPERATION="${resource} ${action}"
	if [[ "$resource" == "help" || "$resource" == "--help" || "$resource" == "-h" ]]; then
		usage
		return 0
	fi
	if [[ "$resource" == "batch" ]]; then
		shift
		gh_write_batch "$@"
		return $?
	fi
	if [[ "$action" != "create" && "$action" != "edit" && "$action" != "comment" && "$action" != "review-handoff" ]]; then
		usage >&2
		return 2
	fi
	shift 2
	local arg
	for arg in "$@"; do
		if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
			usage
			return 0
		fi
	done
	case "${resource}:${action}" in
	issue:create) gh_create_issue "$@" ;;
	issue:edit) gh_issue_edit_safe "$@" ;;
	issue:review-handoff) _issue_review_handoff "$@" ;;
	issue:comment) gh_issue_comment "$@" ;;
	pr:create) gh_create_pr "$@" ;;
	pr:edit) gh_pr_edit_safe "$@" ;;
	pr:comment) gh_pr_comment "$@" ;;
	*)
		usage >&2
		return 2
		;;
	esac
	return $?
}

# Keep failures inside an explicit status check so captured transport stderr is
# replayed before errexit can terminate the CLI. Preserve the original status.
main "$@" || {
	rc=$?
	printf '[aidevops][gh-write-helper][ERROR] GitHub write failed (exit %s).\n' "$rc" >&2
	exit "$rc"
}
