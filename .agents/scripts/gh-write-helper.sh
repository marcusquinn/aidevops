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
	printf '       gh-write-helper.sh batch MANIFEST.json\n'
	printf 'Bodies may use --body-file - to read stdin once through the safe wrapper.\n'
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
	if [[ "$action" != "create" && "$action" != "edit" && "$action" != "comment" ]]; then
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
