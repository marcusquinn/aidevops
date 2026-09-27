#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Prune stale agent-workspace scratch, never session checkpoints or live leases.
# Manual invocation is dry-run; pulse passes --force on its scheduled cycle.
#
# Options:
#   --dry-run            Report eligible entries without moving them (default)
#   --force              Move eligible entries to the trash
#   --max-seconds N      Stop starting new work after N seconds (0 = unbounded).
#                        The pulse passes a small budget so a large backlog is
#                        drained across cycles instead of consuming the whole
#                        preflight stage timeout (GH#32485 regression).
#   --batch-size N       Paths per trash invocation (default 200). Spawning one
#                        trash process per entry made 40k-entry backlogs take
#                        hours; batching amortises the process and Finder cost.
set -euo pipefail

_sc_log_dir=""
_sc_trashed=0

# Move a batch of paths to the trash. Falls back to per-entry moves when a
# batch fails so one unmovable entry cannot hide the rest.
# Args: paths...
_sc_trash_batch() {
	local path=""
	[[ $# -gt 0 ]] || return 0
	if command -v trash >/dev/null 2>&1 && trash "$@" >/dev/null 2>&1; then
		_sc_trashed=$((_sc_trashed + $#))
		for path in "$@"; do
			printf 'Trashed: %s\n' "$path" >>"$_sc_log_dir/system-cleanup.log"
		done
		return 0
	fi
	if command -v gio >/dev/null 2>&1 && gio trash "$@" >/dev/null 2>&1; then
		_sc_trashed=$((_sc_trashed + $#))
		for path in "$@"; do
			printf 'Trashed: %s\n' "$path" >>"$_sc_log_dir/system-cleanup.log"
		done
		return 0
	fi
	if ! command -v trash >/dev/null 2>&1 && ! command -v gio >/dev/null 2>&1; then
		printf 'No trash backend available; %s entries retained\n' "$#" >>"$_sc_log_dir/system-cleanup.log"
		return 1
	fi
	# Batch failed with a backend present: retry individually so a single
	# vanished or locked entry does not block its siblings.
	for path in "$@"; do
		[[ -e "$path" ]] || continue
		if { command -v trash >/dev/null 2>&1 && trash "$path" >/dev/null 2>&1; } ||
			{ command -v gio >/dev/null 2>&1 && gio trash "$path" >/dev/null 2>&1; }; then
			_sc_trashed=$((_sc_trashed + 1))
			printf 'Trashed: %s\n' "$path" >>"$_sc_log_dir/system-cleanup.log"
		else
			printf 'Trash move failed: %s\n' "$path" >>"$_sc_log_dir/system-cleanup.log"
		fi
	done
	return 0
}

main() {
	local mode="dry-run" days="${AIDEVOPS_TMP_RETENTION_DAYS:-7}"
	local root="${AIDEVOPS_TEMP_DIR:-${HOME:?}/.aidevops/.agent-workspace/tmp}"
	local log_dir="${AIDEVOPS_LOG_DIR:-${HOME:?}/.aidevops/logs}"
	local max_seconds="${AIDEVOPS_TMP_CLEANUP_MAX_SECONDS:-0}"
	local batch_size="${AIDEVOPS_TMP_CLEANUP_BATCH_SIZE:-200}"
	local entry="" descendants="" minutes=0 start_seconds=$SECONDS
	local budget_exhausted=0 scanned=0
	local -a batch=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force) mode="force" ;;
		--dry-run) mode="dry-run" ;;
		--max-seconds)
			[[ $# -ge 2 ]] || { printf 'Missing value for --max-seconds\n' >&2; return 1; }
			max_seconds="$2"
			shift
			;;
		--batch-size)
			[[ $# -ge 2 ]] || { printf 'Missing value for --batch-size\n' >&2; return 1; }
			batch_size="$2"
			shift
			;;
		--help)
			printf 'Usage: %s [--dry-run|--force] [--max-seconds N] [--batch-size N]\n' "$0"
			return 0
			;;
		*) printf 'Unknown option: %s\n' "$1" >&2; return 1 ;;
		esac
		shift
	done
	[[ "$days" =~ ^[1-9][0-9]*$ && "$max_seconds" =~ ^[0-9]+$ && "$batch_size" =~ ^[1-9][0-9]*$ ]] || return 1
	# Never follow a redirected root, or operate on a broad/relative path.
	[[ "$root" == /*/tmp && "$root" != /tmp && ! -L "$root" ]] || return 1
	[[ -d "$root" ]] || return 0
	minutes=$((days * 1440))
	mkdir -p "$log_dir" || return 1
	_sc_log_dir="$log_dir"
	while IFS= read -r -d '' entry; do
		if [[ "$max_seconds" -gt 0 && $((SECONDS - start_seconds)) -ge "$max_seconds" ]]; then
			budget_exhausted=1
			break
		fi
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
		scanned=$((scanned + 1))
		if [[ "$mode" == "dry-run" ]]; then
			printf '[dry-run] Would trash: %s\n' "$entry" | tee -a "$log_dir/system-cleanup.log"
			continue
		fi
		batch+=("$entry")
		if [[ "${#batch[@]}" -ge "$batch_size" ]]; then
			_sc_trash_batch "${batch[@]}" || return 1
			batch=()
		fi
	done < <(find "$root" -mindepth 1 -maxdepth 1 -mmin "+${minutes}" -print0)
	if [[ "${#batch[@]}" -gt 0 ]]; then
		_sc_trash_batch "${batch[@]}" || return 1
	fi
	# One summary line for the caller's log (the pulse log) instead of one
	# line per entry; per-entry detail stays in system-cleanup.log.
	printf '[system-cleanup] mode=%s eligible=%s trashed=%s elapsed_s=%s budget_s=%s budget_exhausted=%s\n' \
		"$mode" "$scanned" "$_sc_trashed" "$((SECONDS - start_seconds))" "$max_seconds" "$budget_exhausted"
	return 0
}

main "$@"
