#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
if [[ -f "${SCRIPT_DIR}/portable-stat.sh" ]]; then
	# shellcheck source=portable-stat.sh
	source "${SCRIPT_DIR}/portable-stat.sh"
fi

BACKUP_ROOT="${AIDEVOPS_DIRTY_BACKUP_ROOT:-${HOME}/.aidevops/.agent-workspace/tmp/dirty-main-backups}"
DEFAULT_RETENTION_DAYS="${AIDEVOPS_DIRTY_BACKUP_RETENTION_DAYS:-30}"

usage() {
	cat <<'USAGE'
Usage: dirty-worktree-backup-helper.sh <command> [options]

Commands:
  backup [--repo PATH] [--reason TEXT] [--pr N] [--issue N] [--session KEY] [--task ID]
      Preserve dirty tracked diffs and untracked files without mutating the repo.
  list
      List recorded dirty-worktree backups.
  prune [--dry-run] [--force] [--retention-days N]
      Remove backups whose linked PR is closed/merged, or stale backups older than N days.

Environment:
  AIDEVOPS_DIRTY_BACKUP_ROOT            Override backup directory.
  AIDEVOPS_DIRTY_BACKUP_RETENTION_DAYS Override stale-backup retention (default: 30).
USAGE
	return 0
}

timestamp_utc() {
	date -u '+%Y%m%dT%H%M%SZ'
	return 0
}

iso_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

safe_slug() {
	local raw="$1"
	printf '%s' "$raw" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | cut -c 1-80
	return 0
}

manifest_write() {
	local manifest_path="$1"
	local key="$2"
	local value="$3"
	printf '%s\t%s\n' "$key" "$value" >>"$manifest_path"
	return 0
}

manifest_value() {
	local manifest_path="$1"
	local key="$2"
	awk -F '\t' -v wanted="$key" '$1 == wanted { print substr($0, length($1) + 2); exit }' "$manifest_path" 2>/dev/null || true
	return 0
}

repo_slug_from_remote() {
	local repo_path="$1"
	local remote_url=""
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)
	remote_url=${remote_url%.git}
	case "$remote_url" in
	https://github.com/*/*)
		printf '%s\n' "${remote_url#https://github.com/}"
		return 0
		;;
	git@github.com:*/*)
		printf '%s\n' "${remote_url#git@github.com:}"
		return 0
		;;
	esac
	return 1
}

repo_dirty() {
	local repo_path="$1"
	local status_output=""
	status_output=$(git -C "$repo_path" status --porcelain=v1 2>/dev/null || true)
	[[ -n "$status_output" ]]
	return $?
}

copy_untracked_files() {
	local repo_path="$1"
	local backup_dir="$2"
	local list_path="$backup_dir/untracked-files.txt"
	local nul_path="$backup_dir/untracked-files.nul"
	local rel_path=""
	local target_path=""

	: >"$list_path"
	git -C "$repo_path" ls-files --others --exclude-standard -z >"$nul_path"
	while IFS= read -r -d '' rel_path; do
		[[ -n "$rel_path" ]] || continue
		printf '%s\n' "$rel_path" >>"$list_path"
		target_path="$backup_dir/untracked/$rel_path"
		mkdir -p "$(dirname "$target_path")"
		cp -p "$repo_path/$rel_path" "$target_path"
	done <"$nul_path"
	return 0
}

cmd_backup() {
	local repo_path="$PWD"
	local reason="dirty worktree preservation"
	local pr_number=""
	local issue_number=""
	local session_key="${AIDEVOPS_SESSION_KEY:-${WORKER_SESSION_KEY:-}}"
	local task_id="${AIDEVOPS_TASK_ID:-${WORKER_TASK_NUMBER:-}}"
	local arg=""

	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--repo)
			repo_path="${2:-}"
			shift 2
			;;
		--reason)
			reason="${2:-}"
			shift 2
			;;
		--pr)
			pr_number="${2:-}"
			shift 2
			;;
		--issue)
			issue_number="${2:-}"
			shift 2
			;;
		--session)
			session_key="${2:-}"
			shift 2
			;;
		--task)
			task_id="${2:-}"
			shift 2
			;;
		--help | -h)
			usage
			return 0
			;;
		*)
			print_error "Unknown backup option: $arg"
			return 1
			;;
		esac
	done

	if [[ -z "$repo_path" ]] || { [[ ! -d "$repo_path/.git" ]] && [[ ! -f "$repo_path/.git" ]]; }; then
		print_error "Not a git worktree: $repo_path"
		return 1
	fi

	if ! repo_dirty "$repo_path"; then
		print_info "No dirty worktree changes to back up: $repo_path"
		return 0
	fi

	mkdir -p "$BACKUP_ROOT"

	local branch_name=""
	local repo_name=""
	local backup_id=""
	local backup_dir=""
	local manifest_path=""
	local repo_head=""
	local repo_slug=""

	branch_name=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'detached')
	repo_name=$(basename "$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$repo_path")")
	repo_head=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)
	repo_slug=$(repo_slug_from_remote "$repo_path" || true)
	backup_id="$(safe_slug "$repo_name")-$(safe_slug "$branch_name")-$(timestamp_utc)-$$"
	backup_dir="$BACKUP_ROOT/$backup_id"
	manifest_path="$backup_dir/manifest.tsv"

	mkdir -p "$backup_dir/untracked"
	: >"$manifest_path"
	manifest_write "$manifest_path" "schema" "dirty-worktree-backup-v1"
	manifest_write "$manifest_path" "created_at" "$(iso_utc)"
	manifest_write "$manifest_path" "state" "open"
	manifest_write "$manifest_path" "repo_path" "$repo_path"
	manifest_write "$manifest_path" "repo_slug" "$repo_slug"
	manifest_write "$manifest_path" "branch" "$branch_name"
	manifest_write "$manifest_path" "head" "$repo_head"
	manifest_write "$manifest_path" "session" "$session_key"
	manifest_write "$manifest_path" "task" "$task_id"
	manifest_write "$manifest_path" "pr" "$pr_number"
	manifest_write "$manifest_path" "issue" "$issue_number"
	manifest_write "$manifest_path" "reason" "$reason"

	git -C "$repo_path" status --short --branch >"$backup_dir/git-status.txt"
	git -C "$repo_path" diff --binary >"$backup_dir/tracked.patch"
	git -C "$repo_path" diff --cached --binary >"$backup_dir/staged.patch"
	copy_untracked_files "$repo_path" "$backup_dir"

	print_success "Backed up dirty worktree state: $backup_dir"
	printf '%s\n' "$backup_dir"
	return 0
}

cmd_list() {
	local backup_dir=""
	local manifest_path=""

	if [[ ! -d "$BACKUP_ROOT" ]]; then
		print_info "No dirty-worktree backups found."
		return 0
	fi

	for backup_dir in "$BACKUP_ROOT"/*; do
		[[ -d "$backup_dir" ]] || continue
		manifest_path="$backup_dir/manifest.tsv"
		if [[ -f "$manifest_path" ]]; then
			printf '%s\tstate=%s\tpr=%s\ttask=%s\treason=%s\n' \
				"$backup_dir" \
				"$(manifest_value "$manifest_path" state)" \
				"$(manifest_value "$manifest_path" pr)" \
				"$(manifest_value "$manifest_path" task)" \
				"$(manifest_value "$manifest_path" reason)"
		fi
	done
	return 0
}

backup_age_days() {
	local backup_dir="$1"
	local now_epoch=""
	local backup_epoch=""

	now_epoch=$(date +%s)
	if command -v portable_stat_mtime >/dev/null 2>&1; then
		backup_epoch=$(portable_stat_mtime "$backup_dir" 2>/dev/null || printf '%s' "$now_epoch")
	else
		backup_epoch="$now_epoch"
	fi
	if ! [[ "$backup_epoch" =~ ^[0-9]+$ ]]; then
		backup_epoch="$now_epoch"
	fi
	printf '%s\n' $(((now_epoch - backup_epoch) / 86400))
	return 0
}

pr_is_terminal() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_state=""

	[[ -n "$repo_slug" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1
	pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state // ""' 2>/dev/null || true)
	case "$pr_state" in
	CLOSED | MERGED)
		return 0
		;;
	esac
	return 1
}

remove_backup_dir() {
	local backup_dir="$1"
	local force="$2"
	local reason="$3"

	if [[ "$force" != "true" ]]; then
		print_info "[dry-run] Would remove backup ($reason): $backup_dir"
		return 0
	fi
	rm -rf "$backup_dir"
	print_info "Removed backup ($reason): $backup_dir"
	return 0
}

cmd_prune() {
	local force="false"
	local retention_days="$DEFAULT_RETENTION_DAYS"
	local arg=""

	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--force)
			force="true"
			shift
			;;
		--dry-run)
			force="false"
			shift
			;;
		--retention-days)
			retention_days="${2:-}"
			shift 2
			;;
		--help | -h)
			usage
			return 0
			;;
		*)
			print_error "Unknown prune option: $arg"
			return 1
			;;
		esac
	done

	if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then
		print_error "Retention days must be numeric: $retention_days"
		return 1
	fi

	if [[ ! -d "$BACKUP_ROOT" ]]; then
		return 0
	fi

	local backup_dir=""
	local manifest_path=""
	local repo_slug=""
	local pr_number=""
	local age_days=""

	for backup_dir in "$BACKUP_ROOT"/*; do
		[[ -d "$backup_dir" ]] || continue
		manifest_path="$backup_dir/manifest.tsv"
		[[ -f "$manifest_path" ]] || continue
		[[ -f "$backup_dir/.keep" ]] && continue

		repo_slug=$(manifest_value "$manifest_path" repo_slug)
		pr_number=$(manifest_value "$manifest_path" pr)
		if pr_is_terminal "$repo_slug" "$pr_number"; then
			remove_backup_dir "$backup_dir" "$force" "linked PR terminal"
			continue
		fi

		age_days=$(backup_age_days "$backup_dir")
		if [[ "$age_days" -ge "$retention_days" ]]; then
			remove_backup_dir "$backup_dir" "$force" "age ${age_days}d >= ${retention_days}d"
		fi
	done
	return 0
}

main() {
	local command_name="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi

	case "$command_name" in
	backup)
		cmd_backup "$@"
		return $?
		;;
	list)
		cmd_list "$@"
		return $?
		;;
	prune)
		cmd_prune "$@"
		return $?
		;;
	help | --help | -h)
		usage
		return 0
		;;
	*)
		print_error "Unknown command: $command_name"
		usage
		return 1
		;;
	esac
}

main "$@"
