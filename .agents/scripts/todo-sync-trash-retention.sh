#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# todo-sync-trash-retention.sh — bounded retention for trashed TODO-sync clones (GH#37214).
#
# pulse-todo-sync-workspace.sh moves stale clones into recoverable trash buckets
# named aidevops-pulse-todo-sync-<identity>-<epoch>-<pid>-<rand>. Each holds a
# full clone (~1 GB), so without an owner they accumulate without bound. This
# helper is that owner. It only touches directories that are direct children of
# the trash root, match the bucket name, are not symlinks, and carry the
# producer's owner marker. Anything else is left alone.
#
# Usage:
#   todo-sync-trash-retention.sh report                     Bucket count and bytes (read-only)
#   todo-sync-trash-retention.sh prune [--apply] [--older-than-days N] [--max-count N]
#                                                           Dry run by default; --apply deletes
#   todo-sync-trash-retention.sh orphan-report              Size of aidevops-orphan-cleanup-* buckets
#                                                           (reported only; never deleted)
#
# A bucket is eligible when it is older than the cutoff, or when it is not among
# the newest max-count buckets. Newest buckets are always kept up to the cap.
#
# Environment:
#   AIDEVOPS_TODO_SYNC_TRASH_ROOT / AIDEVOPS_ORPHAN_TRASH_ROOT  Trash root (default ~/.Trash)
#   TODO_SYNC_TRASH_RETENTION_DAYS   Age cutoff in days (default 3)
#   TODO_SYNC_TRASH_MAX_COUNT        Newest buckets always kept at most (default 5)

set -uo pipefail

readonly TSTR_PREFIX="aidevops-pulse-todo-sync-"
readonly TSTR_MARKER=".aidevops-pulse-todo-sync-owner"
readonly TSTR_ORPHAN_PREFIX="aidevops-orphan-cleanup-"

_tstr_trash_root() {
	local root="${AIDEVOPS_TODO_SYNC_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}"
	if [[ -z "$root" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		root="${HOME}/.Trash"
	fi
	[[ "$root" == /* && -d "$root" ]] || return 1
	printf '%s\n' "$root"
	return 0
}

# Prints "<epoch> <path>" per valid bucket, newest first. Buckets whose name
# carries no parseable epoch are skipped (conservative).
_tstr_list_buckets() {
	local root="$1" entry="" name="" epoch=""
	for entry in "$root"/"${TSTR_PREFIX}"*; do
		[[ -d "$entry" && ! -L "$entry" && -f "${entry}/${TSTR_MARKER}" ]] || continue
		name="${entry##*/}"
		if [[ "$name" =~ -([0-9]{9,})-[0-9]+-[0-9]+$ ]]; then
			epoch="${BASH_REMATCH[1]}"
			printf '%s %s\n' "$epoch" "$entry"
		fi
	done | sort -rn
	return 0
}

_tstr_kib() {
	local path="$1" out=""
	out=$(du -sk "$path" 2>/dev/null) || true
	out="${out%%[[:space:]]*}"
	[[ "$out" =~ ^[0-9]+$ ]] || out=0
	printf '%s\n' "$out"
	return 0
}

_tstr_positive_int() {
	local value="$1" fallback="$2"
	[[ "$value" =~ ^[1-9][0-9]*$ ]] || value="$fallback"
	printf '%s\n' "$value"
	return 0
}

cmd_report() {
	local root="" line="" path="" count=0 total=0 kib=0
	root=$(_tstr_trash_root) || { printf 'todo_sync_trash buckets=0 kib=0 (no trash root)\n'; return 0; }
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		path="${line#* }"
		kib=$(_tstr_kib "$path")
		count=$((count + 1))
		total=$((total + kib))
	done < <(_tstr_list_buckets "$root")
	printf 'todo_sync_trash buckets=%s kib=%s root=%s\n' "$count" "$total" "$root"
	return 0
}

cmd_prune() {
	local apply=0 days="${TODO_SYNC_TRASH_RETENTION_DAYS:-3}" max_count="${TODO_SYNC_TRASH_MAX_COUNT:-5}"
	local arg="" root="" line="" path="" epoch="" now="" cutoff="" rank=0 kib=0
	local kept=0 eligible=0 eligible_kib=0 removed=0 removed_kib=0 failed=0 reason=""
	local -a args=("$@")
	local i=0
	while [[ "$i" -lt "${#args[@]}" ]]; do
		arg="${args[$i]}"
		i=$((i + 1))
		case "$arg" in
		--apply) apply=1 ;;
		--dry-run) apply=0 ;;
		--older-than-days) days="${args[$i]:-}"; i=$((i + 1)) ;;
		--max-count) max_count="${args[$i]:-}"; i=$((i + 1)) ;;
		*) printf 'Unknown option: %s\n' "$arg" >&2; return 1 ;;
		esac
	done
	days=$(_tstr_positive_int "$days" 3)
	max_count=$(_tstr_positive_int "$max_count" 5)
	root=$(_tstr_trash_root) || { printf 'todo_sync_trash: no trash root; nothing to do\n'; return 0; }
	now=$(date +%s) || return 1
	cutoff=$((now - days * 86400))
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		epoch="${line%% *}"
		path="${line#* }"
		rank=$((rank + 1))
		reason=""
		if [[ "$epoch" -lt "$cutoff" ]]; then
			reason="older-than-${days}d"
		elif [[ "$rank" -gt "$max_count" ]]; then
			reason="beyond-newest-${max_count}"
		fi
		if [[ -z "$reason" ]]; then
			kept=$((kept + 1))
			continue
		fi
		kib=$(_tstr_kib "$path")
		eligible=$((eligible + 1))
		eligible_kib=$((eligible_kib + kib))
		if [[ "$apply" -eq 1 ]]; then
			if rm -rf "$path" 2>/dev/null && [[ ! -e "$path" ]]; then
				removed=$((removed + 1))
				removed_kib=$((removed_kib + kib))
			else
				failed=$((failed + 1))
			fi
		else
			printf '[dry-run] would remove %s (%s KiB, %s)\n' "${path##*/}" "$kib" "$reason"
		fi
	done < <(_tstr_list_buckets "$root")
	if [[ "$apply" -eq 1 ]]; then
		printf 'todo_sync_trash outcome=applied kept=%s removed=%s reclaimed_kib=%s failed=%s\n' \
			"$kept" "$removed" "$removed_kib" "$failed"
		[[ "$failed" -eq 0 ]] || return 1
	else
		printf 'todo_sync_trash outcome=dry-run kept=%s eligible=%s eligible_kib=%s (cutoff %sd, keep newest %s)\n' \
			"$kept" "$eligible" "$eligible_kib" "$days" "$max_count"
	fi
	return 0
}

cmd_orphan_report() {
	local root="" entry="" count=0 total=0 kib=0
	root=$(_tstr_trash_root) || { printf 'orphan_cleanup_trash buckets=0 kib=0\n'; return 0; }
	for entry in "$root"/"${TSTR_ORPHAN_PREFIX}"*; do
		[[ -d "$entry" && ! -L "$entry" ]] || continue
		kib=$(_tstr_kib "$entry")
		count=$((count + 1))
		total=$((total + kib))
	done
	printf 'orphan_cleanup_trash buckets=%s kib=%s (report only; may hold unique work, never auto-deleted)\n' "$count" "$total"
	return 0
}

main() {
	local subcommand="${1:-report}"
	[[ $# -gt 0 ]] && shift
	case "$subcommand" in
	report) cmd_report ;;
	prune) cmd_prune "$@" ;;
	orphan-report) cmd_orphan_report ;;
	*) printf 'Usage: todo-sync-trash-retention.sh [report|prune [--apply] [--older-than-days N] [--max-count N]|orphan-report]\n' >&2; return 1 ;;
	esac
	return $?
}

main "$@"
