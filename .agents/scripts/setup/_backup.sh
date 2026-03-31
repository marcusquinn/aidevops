#!/usr/bin/env bash
set -euo pipefail
# Backup and rotation functions for setup.sh

# Create a backup with rotation (keeps last N backups)
# Usage: create_backup_with_rotation <source_path> <backup_name>
# Example: create_backup_with_rotation "$target_dir" "agents"
# Creates: ~/.aidevops/agents-backups/20251221_123456/
create_backup_with_rotation() {
	local source_path="$1"
	local backup_name="$2"
	local backup_base="$HOME/.aidevops/${backup_name}-backups"
	local backup_dir
	local backup_target
	backup_dir="$backup_base/$(date +%Y%m%d_%H%M%S)"
	backup_target="$backup_dir/$(basename "$source_path")"

	mkdir -p "$backup_dir"

	if [[ -d "$source_path" ]]; then
		mkdir -p "$backup_target"
		if command -v rsync >/dev/null 2>&1; then
			local rsync_status=0
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

	local backup_count
	backup_count=$(find "$backup_base" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l | tr -d ' ')

	if [[ $backup_count -gt $BACKUP_KEEP_COUNT ]]; then
		local to_delete=$((backup_count - BACKUP_KEEP_COUNT))
		print_info "Rotating backups: removing $to_delete old backup(s), keeping last $BACKUP_KEEP_COUNT"
		find "$backup_base" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort | head -n "$to_delete" | while read -r old_backup; do
			rm -rf "$old_backup"
		done
	fi

	return 0
}
