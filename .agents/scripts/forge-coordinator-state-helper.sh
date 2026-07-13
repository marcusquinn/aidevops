#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

restore_state() {
	local state_dir="$1"
	local repository="$2"
	local repository_id="$3"
	local artifact_id="" archive=""
	mkdir -p "$state_dir"
	artifact_id=$(gh api --paginate --slurp "repos/${repository}/actions/artifacts?per_page=100" \
		--jq "[.[] | .artifacts[]? | select((.name | startswith(\"forge-coordinator-${repository_id}-\")) and ((.expired // false) == false))] | sort_by([.created_at, .id]) | last | .id // empty") || return 1
	[[ -n "$artifact_id" ]] || return 0
	if [[ ! "$artifact_id" =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid coordinator artifact ID returned for repository %s: %q\n' "$repository" "$artifact_id" >&2
		return 1
	fi
	archive="${state_dir}/state.zip"
	gh api "repos/${repository}/actions/artifacts/${artifact_id}/zip" >"$archive" || return 1
	unzip -oq "$archive" -d "$state_dir" || return 1
	rm -f "$archive"
	return 0
}

main() {
	local command="${1:-}"
	case "$command" in
	restore) restore_state "${2:?state directory required}" "${3:?repository required}" "${4:?repository ID required}" ;;
	*)
		printf 'Usage: %s restore STATE_DIR REPOSITORY REPOSITORY_ID\n' "$0" >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
