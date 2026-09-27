#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Prune stale agent-workspace scratch, never session checkpoints or live leases.
# Manual invocation is dry-run; pulse passes --force on its scheduled cycle.
set -euo pipefail

main() {
	local mode="dry-run" days="${AIDEVOPS_TMP_RETENTION_DAYS:-7}"
	local root="${AIDEVOPS_TEMP_DIR:-${HOME:?}/.aidevops/.agent-workspace/tmp}"
	local log_dir="${AIDEVOPS_LOG_DIR:-${HOME:?}/.aidevops/logs}"
	local entry="" descendants="" minutes=0
	case "${1:-}" in
	--force) mode="force" ;;
	--dry-run | "") ;;
	--help) printf 'Usage: %s [--dry-run|--force]\n' "$0"; return 0 ;;
	*) printf 'Unknown option: %s\n' "$1" >&2; return 1 ;;
	esac
	[[ $# -le 1 && "$days" =~ ^[1-9][0-9]*$ ]] || return 1
	# Never follow a redirected root, or operate on a broad/relative path.
	[[ "$root" == /*/tmp && "$root" != /tmp && ! -L "$root" ]] || return 1
	[[ -d "$root" ]] || return 0
	minutes=$((days * 1440))
	mkdir -p "$log_dir" || return 1
	while IFS= read -r -d '' entry; do
		case "${entry##*/}" in
		session-checkpoints | locks | pulse | repository-campaigns | README.md) continue ;;
		esac
		# A symlink could redirect trash to an unrelated location; only owned,
		# ordinary entries are eligible. An active session may keep a parent
		# directory old while refreshing files inside it.
		[[ ! -L "$entry" ]] || continue
		if [[ -d "$entry" ]]; then
			# A failed scan cannot establish that a directory is inactive.
			descendants=$(find "$entry" -mindepth 1 \( -mmin "-${minutes}" -o -name '*.lock' -o -name '*.lease' \) -print -quit) || return 1
			[[ -z "$descendants" ]] || continue
		fi
		if [[ "$mode" == "dry-run" ]]; then
			printf '[dry-run] Would trash: %s\n' "$entry" | tee -a "$log_dir/system-cleanup.log"
		elif command -v trash >/dev/null 2>&1 && trash "$entry"; then
			printf 'Trashed: %s\n' "$entry" | tee -a "$log_dir/system-cleanup.log"
		elif command -v gio >/dev/null 2>&1 && gio trash "$entry"; then
			printf 'Trashed: %s\n' "$entry" | tee -a "$log_dir/system-cleanup.log"
		else
			printf 'No trash backend or move failed: %s\n' "$entry" | tee -a "$log_dir/system-cleanup.log" >&2
			return 1
		fi
	done < <(find "$root" -mindepth 1 -maxdepth 1 -mmin "+${minutes}" -print0)
	return 0
}

main "$@"
