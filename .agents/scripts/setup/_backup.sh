#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail
# Producer-owned backup and retention functions for setup.sh.

BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-10}"
BACKUP_MAX_AGE_DAYS="${AIDEVOPS_BACKUP_MAX_AGE_DAYS:-180}"
BACKUP_MAX_BYTES="${AIDEVOPS_BACKUP_MAX_BYTES:-4294967296}"
readonly BACKUP_RETENTION_CONFIRMATION="DELETE-STALE-AIDEVOPS-BACKUPS"

if ! declare -F _file_mtime_epoch >/dev/null 2>&1; then
	_backup_module_dir="${BASH_SOURCE[0]%/*}"
	# shellcheck source=../portable-stat.sh
	source "${_backup_module_dir}/../portable-stat.sh"
	unset _backup_module_dir
fi

_backup_policy_value() {
	local value="$1"
	local fallback="$2"
	case "$value" in
	'' | *[!0-9]*) printf '%s' "$fallback" ;;
	*) printf '%s' "$value" ;;
	esac
	return 0
}

_backup_snapshot_size_bytes() {
	local snapshot_path="$1"
	local kib=""
	local ignored=""
	IFS=$'\t ' read -r kib ignored < <(du -sk "$snapshot_path" 2>/dev/null) || return 1
	case "$kib" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s' "$((kib * 1024))"
	return 0
}

# Print a tab-delimited, oldest-first dry-run plan: path, bytes, reasons.
# Unknown, symlinked, or unmeasurable snapshots fail closed and produce no plan.
_backup_retention_plan() {
	local backup_base="$1"
	local keep_count=""
	local max_age_days=""
	local max_bytes=""
	local now_epoch=""
	local age_cutoff=""
	local snapshot_path=""
	local snapshot_size=""
	local snapshot_mtime=""
	local snapshot_count=0
	local total_bytes=0
	local remaining_count=0
	local remaining_bytes=0
	local reason=""
	local newest_snapshot=""
	local snapshot_name=""
	local -a snapshots=()
	local -a sizes=()
	local -a mtimes=()

	[[ -d "$backup_base" && ! -L "$backup_base" ]] || return 0
	keep_count=$(_backup_policy_value "$BACKUP_KEEP_COUNT" 10)
	max_age_days=$(_backup_policy_value "$BACKUP_MAX_AGE_DAYS" 180)
	max_bytes=$(_backup_policy_value "$BACKUP_MAX_BYTES" 4294967296)
	now_epoch=$(date +%s)
	age_cutoff=$((now_epoch - (max_age_days * 86400)))
	for snapshot_path in "$backup_base"/*; do
		[[ -e "$snapshot_path" || -L "$snapshot_path" ]] || continue
		snapshot_name="${snapshot_path##*/}"
		[[ "$snapshot_name" == ".retention-trash" ]] && continue
		[[ "$snapshot_name" =~ ^20[0-9]{6}_[0-9]{6}$ ]] || return 2
		[[ -d "$snapshot_path" && ! -L "$snapshot_path" ]] || return 2
	done

	while IFS= read -r snapshot_path; do
		[[ -n "$snapshot_path" ]] || continue
		if [[ "$snapshot_path" == "$backup_base/20*" && ! -e "$snapshot_path" ]]; then
			continue
		fi
		[[ -d "$snapshot_path" && ! -L "$snapshot_path" ]] || return 2
		snapshot_size=$(_backup_snapshot_size_bytes "$snapshot_path") || return 2
		snapshot_mtime=$(_file_mtime_epoch "$snapshot_path" 2>/dev/null) || return 2
		case "$snapshot_mtime" in
		'' | *[!0-9]* | 0) return 2 ;;
		esac
		snapshots+=("$snapshot_path")
		sizes+=("$snapshot_size")
		mtimes+=("$snapshot_mtime")
		total_bytes=$((total_bytes + snapshot_size))
	done < <(printf '%s\n' "$backup_base"/20* 2>/dev/null | LC_ALL=C sort)

	snapshot_count=${#snapshots[@]}
	[[ "$snapshot_count" -gt 1 ]] || return 0
	remaining_count="$snapshot_count"
	remaining_bytes="$total_bytes"
	newest_snapshot="${snapshots[$((snapshot_count - 1))]}"

	local index=0
	while [[ "$index" -lt "$snapshot_count" ]]; do
		snapshot_path="${snapshots[$index]}"
		snapshot_size="${sizes[$index]}"
		snapshot_mtime="${mtimes[$index]}"
		reason=""
		if [[ "$snapshot_path" != "$newest_snapshot" ]]; then
			[[ "$remaining_count" -gt "$keep_count" ]] && reason="count"
			if [[ "$remaining_bytes" -gt "$max_bytes" ]]; then
				reason="${reason:+${reason},}bytes"
			fi
			if [[ "$snapshot_mtime" -lt "$age_cutoff" ]]; then
				reason="${reason:+${reason},}age"
			fi
		fi
		if [[ -n "$reason" ]]; then
			printf '%s\t%s\t%s\n' "$snapshot_path" "$snapshot_size" "$reason"
			remaining_count=$((remaining_count - 1))
			remaining_bytes=$((remaining_bytes - snapshot_size))
		fi
		index=$((index + 1))
	done
	return 0
}

# Apply a previously generated plan after validating every attributable path.
# Candidates are staged in producer-local trash before exact-path removal.
_backup_retention_apply() {
	local backup_base="$1"
	local plan_file="$2"
	local confirmation="$3"
	local candidate_path=""
	local candidate_bytes=""
	local candidate_reason=""
	local candidate_name=""
	local trash_dir="${backup_base}/.retention-trash"
	local staged_path=""
	local current_plan=""
	local current_size=""
	local index=0
	local -a staged_paths=()

	[[ "$confirmation" == "$BACKUP_RETENTION_CONFIRMATION" ]] || return 1
	[[ -d "$backup_base" && ! -L "$backup_base" && -f "$plan_file" ]] || return 1
	current_plan=$(_backup_retention_plan "$backup_base") || return 1
	current_plan=$'\n'"${current_plan}"$'\n'
	mkdir -p "$trash_dir" || return 1

	while IFS=$'\t' read -r candidate_path candidate_bytes candidate_reason; do
		[[ -n "$candidate_path" ]] || continue
		candidate_name="${candidate_path##*/}"
		[[ "${candidate_path%/*}" == "$backup_base" ]] || return 1
		[[ "$candidate_name" =~ ^20[0-9]{6}_[0-9]{6}$ ]] || return 1
		[[ -d "$candidate_path" && ! -L "$candidate_path" ]] || return 1
		case "$candidate_bytes" in
		'' | *[!0-9]*) return 1 ;;
		esac
		[[ -n "$candidate_reason" ]] || return 1
		[[ "$current_plan" == *$'\n'"${candidate_path}"$'\t'"${candidate_bytes}"$'\t'"${candidate_reason}"$'\n'* ]] || return 1
		current_size=$(_backup_snapshot_size_bytes "$candidate_path") || return 1
		[[ "$current_size" == "$candidate_bytes" ]] || return 1
		staged_path="${trash_dir}/${candidate_name}-$$-${index}"
		mv "$candidate_path" "$staged_path" || return 1
		staged_paths+=("$staged_path")
		index=$((index + 1))
	done <"$plan_file"

	if [[ "${AIDEVOPS_RETENTION_TEST_INTERRUPT_AFTER_STAGE:-0}" == "1" ]]; then
		return 1
	fi
	for staged_path in "${staged_paths[@]}"; do
		rm -rf "$staged_path" || return 1
	done
	rmdir "$trash_dir" 2>/dev/null || true
	return 0
}

# Create a backup, compute the non-destructive plan, then apply that exact plan.
# Usage: create_backup_with_rotation <source_path> <backup_name>
create_backup_with_rotation() {
	local source_path="$1"
	local backup_name="$2"
	local backup_base=""
	local backup_dir=""
	local backup_target=""
	local rsync_status=0
	local retention_tmp_dir=""
	local plan_file=""
	local candidate_count=0

	[[ "$backup_name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	backup_base="$HOME/.aidevops/${backup_name}-backups"
	backup_dir="$backup_base/$(date +%Y%m%d_%H%M%S)"
	backup_target="$backup_dir/$(basename "$source_path")"
	mkdir -p "$backup_dir"

	if [[ -d "$source_path" ]]; then
		mkdir -p "$backup_target"
		if command -v rsync >/dev/null 2>&1; then
			if rsync -a "$source_path/" "$backup_target/"; then
				rsync_status=0
			else
				rsync_status=$?
			fi
			if [[ "$rsync_status" -eq 24 ]]; then
				print_warning "Backup completed with missing source entries skipped: $source_path"
			elif [[ "$rsync_status" -ne 0 ]]; then
				print_error "Backup failed for $source_path (rsync exit $rsync_status)"
				return "$rsync_status"
			fi
		else
			cp -R "$source_path" "$backup_dir/"
		fi
	elif [[ -f "$source_path" ]]; then
		cp "$source_path" "$backup_dir/"
	else
		print_warning "Source path does not exist: $source_path"
		return 1
	fi

	print_info "Backed up to $backup_dir"
	retention_tmp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$retention_tmp_dir"
	plan_file=$(mktemp "${retention_tmp_dir}/backup-retention.XXXXXX") || return 1
	if ! _backup_retention_plan "$backup_base" >"$plan_file"; then
		rm -f "$plan_file"
		print_warning "Backup retention classification unavailable; preserving every snapshot"
		return 0
	fi
	candidate_count=$(wc -l <"$plan_file" | tr -d ' ')
	if [[ "$candidate_count" -gt 0 ]]; then
		print_info "Backup retention dry run selected ${candidate_count} attributable old snapshot(s)"
		if ! _backup_retention_apply "$backup_base" "$plan_file" "$BACKUP_RETENTION_CONFIRMATION"; then
			rm -f "$plan_file"
			print_warning "Backup retention stopped safely; inspect ${backup_base}/.retention-trash"
			return 1
		fi
	fi
	rm -f "$plan_file"
	return 0
}
